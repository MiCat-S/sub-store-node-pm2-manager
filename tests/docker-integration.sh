#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLATFORM="${TEST_PLATFORM:-linux/amd64}"
TEST_NODE_INSTALL="${TEST_NODE_INSTALL:-0}"
TEST_SMOKE_ONLY="${TEST_SMOKE_ONLY:-0}"

if [[ "$TEST_NODE_INSTALL" == 1 ]]; then
    IMAGE="ubuntu:24.04"
else
    IMAGE="node:24-bookworm"
fi

docker_args=(
    run --rm -i
    --platform "$PLATFORM"
    -e TEST_NODE_INSTALL="$TEST_NODE_INSTALL"
    -e TEST_SMOKE_ONLY="$TEST_SMOKE_ONLY"
    -v "$ROOT:/src:ro"
)
[[ -z "${GITHUB_TOKEN:-}" ]] || docker_args+=(-e GITHUB_TOKEN)

docker "${docker_args[@]}" "$IMAGE" bash -s <<'CONTAINER'
set -Eeuo pipefail

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

phase() {
    printf '\n== %s ==\n' "$1"
}

pm2_status() {
    pm2 jlist | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk).on("end", () => {
  const app = JSON.parse(input).find(item => item.name === process.argv[1]);
  process.stdout.write(app?.pm2_env?.status || "missing");
});
' "$1"
}

pm2_pid() {
    pm2 jlist | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk).on("end", () => {
  const app = JSON.parse(input).find(item => item.name === process.argv[1]);
  process.stdout.write(String(app?.pid ?? -1));
});
' "$1"
}

backup_count() {
    find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.substore-backup.*' -print 2>/dev/null | wc -l
}

assert_no_transients() {
    local residue
    residue="$(find /opt /var/lib /srv /etc/substore-manager-test /tmp \
        \( -name '.substore-install.*' -o \
           -name '.substore-update.*' -o \
           -name '.substore-backup.*' -o \
           -name '.substore-frontend-next.*' -o \
           -name '.substore-frontend-old.*' -o \
           -name '.substore-data-restore.*' -o \
           -name '.substore-data-old.*' -o \
           -name '.substore-backend.*' -o \
           -name '.substore-uninstall.*' -o \
           -name 'instance.conf.tmp.*' \) -print 2>/dev/null || true)"
    [[ -z "$residue" ]] || {
        printf 'Transient residue remains:\n%s\n' "$residue" >&2
        return 1
    }
}

if [[ "$TEST_NODE_INSTALL" == 1 ]]; then
    export SUBSTORE_MANAGER_SKIP_PACKAGES=0
else
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 procps unzip >/dev/null
    export SUBSTORE_MANAGER_SKIP_PACKAGES=1
fi

export SUBSTORE_MANAGER_STATE_DIR=/etc/substore-manager-test
export SUBSTORE_MANAGER_INSTALL_PATH=/usr/local/sbin/substore-test
export SUBSTORE_MANAGER_SKIP_PM2_STARTUP=1
export SUBSTORE_MANAGER_SKIP_AUTO_UPDATE=1
export SUBSTORE_NON_INTERACTIVE=1
export SUBSTORE_INSTALL_DIR=/opt/substore-test
export SUBSTORE_DATA_DIR=/var/lib/substore-test
export SUBSTORE_FRONTEND_DIR=/srv/substore-frontend
export SUBSTORE_PORT=39031
export SUBSTORE_PM2_NAME=sub-store-integration
export SUBSTORE_HOST=127.0.0.1
export SUBSTORE_MAGIC_PATH=/integration-path

phase 'failed install cleanup and retry'
if env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FAIL_HEALTH_ONCE=1 \
    bash /src/substore.sh install; then
    fail 'injected first install unexpectedly succeeded'
fi
test ! -e /etc/substore-manager-test/instance.conf
test ! -e /opt/substore-test
test ! -e /var/lib/substore-test
test ! -e /srv/substore-frontend
test "$(pm2_status sub-store-integration)" = missing
assert_no_transients

bash /src/substore.sh install
test -f /opt/substore-test/sub-store.bundle.js
test -f /srv/substore-frontend/index.html
test ! -e /opt/substore-test/frontend
test -f /var/lib/substore-test/root.json
grep -Fq 'SUB_STORE_BACKEND_API_PORT="39031"' /opt/substore-test/.env
grep -Fq 'SUB_STORE_FRONTEND_BACKEND_PATH="/integration-path"' /opt/substore-test/.env
grep -Fq 'SUB_STORE_FRONTEND_PATH="/srv/substore-frontend"' /opt/substore-test/.env
test "$(pm2_status sub-store-integration)" = online

mkdir -p /tmp/substore-no-network
cat >/tmp/substore-no-network/curl <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod 755 /tmp/substore-no-network/curl
backend_hash_before_repeat="$(sha256sum /opt/substore-test/sub-store.bundle.js | awk '{print $1}')"
pid_before_repeat="$(pm2_pid sub-store-integration)"
PATH="/tmp/substore-no-network:$PATH" /usr/local/sbin/substore-test install
test "$(sha256sum /opt/substore-test/sub-store.bundle.js | awk '{print $1}')" = "$backend_hash_before_repeat"
test "$(pm2_pid sub-store-integration)" = "$pid_before_repeat"

phase 'legacy frontend marker migration'
legacy_state=/etc/substore-manager-test/instance.conf
legacy_state_tmp="${legacy_state}.legacy"
install_id="$(bash -c 'source "$1"; printf "%s" "$INSTALL_ID"' _ "$legacy_state")"
rm -f -- /srv/substore-frontend/.substore-manager-frontend
awk '
    $0 == "STATE_VERSION=2" { print "STATE_VERSION=1"; next }
    $0 ~ /^FRONTEND_CREATED_BY_MANAGER=/ { next }
    { print }
' "$legacy_state" >"$legacy_state_tmp"
chmod 600 "$legacy_state_tmp"
mv -f -- "$legacy_state_tmp" "$legacy_state"
PATH="/tmp/substore-no-network:$PATH" /usr/local/sbin/substore-test install
grep -Fxq "$install_id" /srv/substore-frontend/.substore-manager-frontend
grep -Fxq 'STATE_VERSION=2' "$legacy_state"
test "$(pm2_pid sub-store-integration)" = "$pid_before_repeat"

phase 'idempotent PM2 lifecycle'
/usr/local/sbin/substore-test stop
/usr/local/sbin/substore-test stop
test "$(pm2_status sub-store-integration)" = stopped
/usr/local/sbin/substore-test start
/usr/local/sbin/substore-test start
test "$(pm2_status sub-store-integration)" = online
/usr/local/sbin/substore-test restart
test "$(pm2_status sub-store-integration)" = online

if [[ "$TEST_SMOKE_ONLY" == 1 ]]; then
    phase 'smoke update and uninstall'
    /usr/local/sbin/substore-test update
    printf 'y\nn\n' | /usr/local/sbin/substore-test uninstall
    test -d /var/lib/substore-test
    test "$(pm2_status sub-store-integration)" = missing
    assert_no_transients
    printf 'PASS: Linux smoke install, PM2 lifecycle, update and uninstall (%s)\n' "$(dpkg --print-architecture)"
    exit 0
fi

phase 'port rollback and successful port change'
if env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FAIL_HEALTH_ONCE=1 \
    /usr/local/sbin/substore-test port 39032; then
    fail 'injected port change unexpectedly succeeded'
fi
grep -Fq 'SUB_STORE_BACKEND_API_PORT="39031"' /opt/substore-test/.env
grep -Fq 'PORT=39031' /etc/substore-manager-test/instance.conf
ss -ltnH 'sport = :39031' | grep -q .

/usr/local/sbin/substore-test port 39032
grep -Fq 'SUB_STORE_BACKEND_API_PORT="39032"' /opt/substore-test/.env
ss -ltnH 'sport = :39032' | grep -q .

phase 'cross-instance conflict and second instance'
if env \
    SUBSTORE_INSTALL_DIR=/opt/substore-conflict \
    SUBSTORE_DATA_DIR=/var/lib/substore-test \
    SUBSTORE_FRONTEND_DIR=/srv/substore-conflict-frontend \
    SUBSTORE_PORT=39036 \
    SUBSTORE_PM2_NAME=sub-store-conflict \
    SUBSTORE_MAGIC_PATH=/conflict-path \
    /usr/local/sbin/substore-test --instance conflict install; then
    fail 'cross-instance shared data path was accepted'
fi
test ! -e /etc/substore-manager-test/instances/conflict/instance.conf
test ! -e /opt/substore-conflict

env \
    SUBSTORE_INSTALL_DIR=/opt/substore-second \
    SUBSTORE_DATA_DIR=/var/lib/substore-second \
    SUBSTORE_FRONTEND_DIR=/srv/substore-second-frontend \
    SUBSTORE_PORT=39033 \
    SUBSTORE_PM2_NAME=sub-store-second \
    SUBSTORE_HOST=127.0.0.1 \
    SUBSTORE_MAGIC_PATH=/second-path \
    /usr/local/sbin/substore-test --instance second install
test -f /etc/substore-manager-test/instances/second/instance.conf
test -f /srv/substore-second-frontend/index.html
printf 'second-sentinel\n' >/var/lib/substore-second/sentinel.txt
/usr/local/sbin/substore-test instances | grep -q second

printf 'persistent-sentinel\n' >/var/lib/substore-test/sentinel.txt
phase 'frontend-only update and no-op update'
frontend_pid_before="$(pm2_pid sub-store-integration)"
backups_before_frontend="$(backup_count /opt/substore-test/backups)"
env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FORCE_FRONTEND_UPDATE=1 \
    /usr/local/sbin/substore-test update
test "$(pm2_pid sub-store-integration)" = "$frontend_pid_before"
test "$(cat /var/lib/substore-test/sentinel.txt)" = persistent-sentinel
test "$(cat /var/lib/substore-second/sentinel.txt)" = second-sentinel
test "$(backup_count /opt/substore-test/backups)" -gt "$backups_before_frontend"

backups_before_noop="$(backup_count /opt/substore-test/backups)"
pid_before_noop="$(pm2_pid sub-store-integration)"
/usr/local/sbin/substore-test update
test "$(backup_count /opt/substore-test/backups)" = "$backups_before_noop"
test "$(pm2_pid sub-store-integration)" = "$pid_before_noop"

phase 'backend update and rollback failures'
pid_before_backend="$(pm2_pid sub-store-integration)"
env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FORCE_BACKEND_UPDATE=1 \
    /usr/local/sbin/substore-test update
test "$(pm2_status sub-store-integration)" = online
test "$(pm2_pid sub-store-integration)" != "$pid_before_backend"
test "$(cat /var/lib/substore-test/sentinel.txt)" = persistent-sentinel

backend_before_restart_failure="$(sha256sum /opt/substore-test/sub-store.bundle.js | awk '{print $1}')"
if env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FORCE_BACKEND_UPDATE=1 \
    SUBSTORE_MANAGER_TEST_FAIL_PM2_RESTART_ONCE=1 \
    /usr/local/sbin/substore-test update; then
    fail 'injected PM2 restart failure unexpectedly succeeded'
fi
test "$(sha256sum /opt/substore-test/sub-store.bundle.js | awk '{print $1}')" = "$backend_before_restart_failure"
test "$(pm2_status sub-store-integration)" = online
test "$(cat /var/lib/substore-test/sentinel.txt)" = persistent-sentinel

frontend_before_health_failure="$(sha256sum /srv/substore-frontend/index.html | awk '{print $1}')"
env_before_health_failure="$(sha256sum /opt/substore-test/.env | awk '{print $1}')"
if env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FORCE_FRONTEND_UPDATE=1 \
    SUBSTORE_MANAGER_TEST_FAIL_HEALTH_ONCE=1 \
    /usr/local/sbin/substore-test update; then
    fail 'injected frontend health failure unexpectedly succeeded'
fi
test "$(sha256sum /srv/substore-frontend/index.html | awk '{print $1}')" = "$frontend_before_health_failure"
test "$(sha256sum /opt/substore-test/.env | awk '{print $1}')" = "$env_before_health_failure"
test "$(pm2_status sub-store-integration)" = online

phase 'stopped-state update and marker refusal'
/usr/local/sbin/substore-test stop
env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FORCE_BACKEND_UPDATE=1 \
    /usr/local/sbin/substore-test update
test "$(pm2_status sub-store-integration)" = stopped
/usr/local/sbin/substore-test start

install_id="$(bash -c 'source "$1"; printf "%s" "$INSTALL_ID"' _ /etc/substore-manager-test/instance.conf)"
printf 'wrong-install-id\n' >/var/lib/substore-test/.substore-manager-data
if /usr/local/sbin/substore-test update; then
    fail 'update accepted mismatched data marker'
fi
test "$(pm2_status sub-store-integration)" = online
printf '%s\n' "$install_id" >/var/lib/substore-test/.substore-manager-data

phase 'import existing PM2 deployment'
manual_dir=/opt/manual-substore
manual_data=/var/lib/manual-substore
manual_frontend=/srv/manual-substore-frontend
mkdir -p "$manual_dir" "$manual_data" "$manual_frontend"
cp -a /opt/substore-test/sub-store.bundle.js "$manual_dir/"
cp -a /srv/substore-frontend/. "$manual_frontend/"
rm -f -- "$manual_frontend/.substore-manager-frontend"
printf '%s\n' \
    'SUB_STORE_BACKEND_API_PORT="39034"' \
    'SUB_STORE_BACKEND_API_HOST="127.0.0.1"' \
    'SUB_STORE_BACKEND_MERGE="true"' \
    'SUB_STORE_FRONTEND_BACKEND_PATH="/manual-path"' \
    "SUB_STORE_FRONTEND_PATH=\"$manual_frontend\"" \
    "SUB_STORE_DATA_BASE_PATH=\"$manual_data\"" \
    'SUB_STORE_CORS_ALLOWED_ORIGINS="*"' >"$manual_dir/.env"
chmod 600 "$manual_dir/.env"
pm2 start "$manual_dir/sub-store.bundle.js" \
    --name sub-store-manual \
    --interpreter "$(command -v node)" \
    --cwd "$manual_dir" >/dev/null
pm2 save >/dev/null
for _ in $(seq 1 45); do
    [[ "$(pm2_status sub-store-manual)" == online ]] && \
        ss -ltnH 'sport = :39034' | grep -q . && break
    sleep 1
done
test "$(pm2_status sub-store-manual)" = online
printf 'y\ny\n' | env SUBSTORE_NON_INTERACTIVE=0 \
    /usr/local/sbin/substore-test --instance imported install
test -f /etc/substore-manager-test/instances/imported/instance.conf
test -f "$manual_dir/.substore-manager.ecosystem.config.cjs"
test "$(pm2_status sub-store-manual)" = online
printf 'manual-sentinel\n' >"$manual_data/sentinel.txt"

phase 'delete-data and preserve-data uninstall paths'
env \
    SUBSTORE_INSTALL_DIR=/opt/substore-delete \
    SUBSTORE_DATA_DIR=/var/lib/substore-delete \
    SUBSTORE_FRONTEND_DIR=/srv/substore-delete-frontend \
    SUBSTORE_PORT=39035 \
    SUBSTORE_PM2_NAME=sub-store-delete \
    SUBSTORE_HOST=127.0.0.1 \
    SUBSTORE_MAGIC_PATH=/delete-path \
    /usr/local/sbin/substore-test --instance delete-me install
delete_id="$(bash -c 'source "$1"; printf "%s" "$INSTALL_ID"' _ /etc/substore-manager-test/instances/delete-me/instance.conf)"
printf 'delete-sentinel\n' >/var/lib/substore-delete/sentinel.txt
printf 'y\ny\nDELETE %s\n' "$delete_id" | /usr/local/sbin/substore-test --instance delete-me uninstall
test ! -e /var/lib/substore-delete
test ! -e /srv/substore-delete-frontend
test ! -e /opt/substore-delete
test "$(pm2_status sub-store-delete)" = missing

printf 'y\nn\n' | /usr/local/sbin/substore-test --instance second uninstall
test -f /var/lib/substore-second/sentinel.txt
test ! -e /srv/substore-second-frontend
test -d /opt/substore-second/backups
test "$(pm2_status sub-store-second)" = missing

printf 'y\nn\n' | /usr/local/sbin/substore-test --instance imported uninstall
test -f "$manual_dir/sub-store.bundle.js"
test -f "$manual_dir/.env"
test -f "$manual_data/sentinel.txt"
test -f "$manual_frontend/index.html"
test "$(pm2_status sub-store-manual)" = missing

phase 'failed uninstall rollback and final default uninstall'
if printf 'y\nn\n' | env \
    SUBSTORE_MANAGER_TESTING=1 \
    SUBSTORE_MANAGER_TEST_FAIL_UNINSTALL_STAGE_AT=2 \
    /usr/local/sbin/substore-test uninstall; then
    fail 'injected uninstall staging failure unexpectedly succeeded'
fi
test "$(pm2_status sub-store-integration)" = online
test -f /opt/substore-test/sub-store.bundle.js
test -f /opt/substore-test/.env
test -f /etc/substore-manager-test/instance.conf
test -f /var/lib/substore-test/.substore-manager-data

printf 'y\nn\n' | /usr/local/sbin/substore-test uninstall
test -f /var/lib/substore-test/sentinel.txt
test ! -e /srv/substore-frontend
test -d /opt/substore-test/backups
test ! -e /opt/substore-test/sub-store.bundle.js
test "$(pm2_status sub-store-integration)" = missing
command -v node >/dev/null
command -v pm2 >/dev/null

assert_no_transients
printf 'PASS: install retry, idempotence, PM2 lifecycle, updates, rollback, isolation, import and uninstall\n'
CONTAINER

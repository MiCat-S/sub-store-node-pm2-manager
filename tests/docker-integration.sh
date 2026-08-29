#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLATFORM="${TEST_PLATFORM:-linux/amd64}"
TEST_NODE_INSTALL="${TEST_NODE_INSTALL:-0}"

if [[ "$TEST_NODE_INSTALL" == 1 ]]; then
    IMAGE="ubuntu:24.04"
else
    IMAGE="node:24-bookworm"
fi

docker run --rm -i --platform "$PLATFORM" \
    -e TEST_NODE_INSTALL="$TEST_NODE_INSTALL" \
    -v "$ROOT:/src:ro" \
    "$IMAGE" \
    bash -s <<'CONTAINER'
set -Eeuo pipefail

if [[ "$TEST_NODE_INSTALL" == 1 ]]; then
    export SUBSTORE_MANAGER_SKIP_PACKAGES=0
else
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 >/dev/null
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

bash /src/substore.sh install
test -f /opt/substore-test/sub-store.bundle.js
test -f /srv/substore-frontend/index.html
test ! -e /opt/substore-test/frontend
test -f /var/lib/substore-test/root.json
grep -Fq 'SUB_STORE_BACKEND_API_PORT="39031"' /opt/substore-test/.env
grep -Fq 'SUB_STORE_FRONTEND_BACKEND_PATH="/integration-path"' /opt/substore-test/.env
grep -Fq 'SUB_STORE_FRONTEND_PATH="/srv/substore-frontend"' /opt/substore-test/.env

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
/usr/local/sbin/substore-test port 39032
grep -Fq 'SUB_STORE_BACKEND_API_PORT="39032"' /opt/substore-test/.env
ss -ltnH 'sport = :39032' | grep -q .

sed -i 's/^FRONTEND_VERSION=.*/FRONTEND_VERSION=0.0.0/' \
    /etc/substore-manager-test/instance.conf
chmod 600 /etc/substore-manager-test/instance.conf
/usr/local/sbin/substore-test update
test "$(cat /var/lib/substore-test/sentinel.txt)" = persistent-sentinel
test "$(cat /var/lib/substore-second/sentinel.txt)" = second-sentinel
test -n "$(find /opt/substore-test/backups -mindepth 1 -maxdepth 1 -type d -print -quit)"

env_before="$(sha256sum /opt/substore-test/.env | awk '{print $1}')"
frontend_before="$(sha256sum /srv/substore-frontend/index.html | awk '{print $1}')"
sed -i 's/^FRONTEND_VERSION=.*/FRONTEND_VERSION=0.0.0/' \
    /etc/substore-manager-test/instance.conf
chmod 600 /etc/substore-manager-test/instance.conf
export SUBSTORE_MANAGER_TESTING=1
export SUBSTORE_MANAGER_TEST_FAIL_HEALTH_ONCE=1
if /usr/local/sbin/substore-test update; then
    printf 'Injected update unexpectedly succeeded\n' >&2
    exit 1
fi
test "$(cat /var/lib/substore-test/sentinel.txt)" = persistent-sentinel
test "$(sha256sum /opt/substore-test/.env | awk '{print $1}')" = "$env_before"
test "$(sha256sum /srv/substore-frontend/index.html | awk '{print $1}')" = "$frontend_before"

pm2 jlist | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk).on("end", () => {
  const app = JSON.parse(input).find(item => item.name === "sub-store-integration");
  if (!app || app.pm2_env.status !== "online" || app.pm2_env.watch === true) process.exit(1);
});
'

pm2 jlist | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk).on("end", () => {
  const apps = JSON.parse(input);
  for (const name of ["sub-store-integration", "sub-store-second"]) {
    const app = apps.find(item => item.name === name);
    if (!app || app.pm2_env.status !== "online") process.exit(1);
  }
});
'

printf 'y\nn\n' | /usr/local/sbin/substore-test --instance second uninstall
test -f /var/lib/substore-second/sentinel.txt
test ! -e /srv/substore-second-frontend
if pm2 jlist | grep -q sub-store-second; then
    printf 'Second PM2 process still exists after uninstall\n' >&2
    exit 1
fi

printf 'y\nn\n' | /usr/local/sbin/substore-test uninstall
test -f /var/lib/substore-test/sentinel.txt
test ! -e /srv/substore-frontend
command -v node >/dev/null
command -v pm2 >/dev/null
if pm2 jlist | grep -q sub-store-integration; then
    printf 'Managed PM2 process still exists after uninstall\n' >&2
    exit 1
fi

printf 'PASS: install, PM2, health, port, update, rollback, persistence and uninstall\n'
CONTAINER

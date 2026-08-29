#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/substore.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

export SUBSTORE_MANAGER_LIBRARY_ONLY=1
export SUBSTORE_MANAGER_STATE_DIR="$TEST_ROOT/state"
export SUBSTORE_MANAGER_SYSTEMD_DIR="$TEST_ROOT/systemd"
export SUBSTORE_MANAGER_SKIP_STATE_SECURITY=1
source "$SCRIPT"
init_env_catalog
NODE_BIN="$(command -v node)"

ENV_FILE="$TEST_ROOT/.env"
env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT 3000
env_set "$ENV_FILE" SUB_STORE_PUSH_SERVICE 'https://example.test/token?a=1&b="x"'
[[ "$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_PORT)" == 3000 ]] || fail "env_get port"
[[ "$(env_get "$ENV_FILE" SUB_STORE_PUSH_SERVICE)" == 'https://example.test/token?a=1&b="x"' ]] || fail "env quoting"
env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT 8080
[[ "$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_PORT)" == 8080 ]] || fail "env replace"
env_delete "$ENV_FILE" SUB_STORE_PUSH_SERVICE
if env_get "$ENV_FILE" SUB_STORE_PUSH_SERVICE >/dev/null 2>&1; then fail "env delete"; fi

validate_env_value SUB_STORE_BACKEND_API_PORT 65535 || fail "valid port"
if validate_env_value SUB_STORE_BACKEND_API_PORT 65536; then fail "invalid port"; fi
validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH /abc-123 || fail "valid prefix"
validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH /api/sub-store/ || fail "valid nested prefix"
if validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH abc; then fail "invalid prefix"; fi
validate_env_value SUB_STORE_BODY_JSON_LIMIT 10mb || fail "valid body limit"
validate_env_value SUB_STORE_CORS_ALLOWED_ORIGINS 'https://a.example,http://127.0.0.1:3000' || fail "valid cors"
validate_env_value SUB_STORE_PRODUCE_CRON '0 */2 * * *,sub,a;0 */3 * * *,col,b' || fail "valid produce cron"

mkdir -p "$TEST_ROOT/frontend"
touch "$TEST_ROOT/frontend/index.html"
env_set "$ENV_FILE" SUB_STORE_BACKEND_MERGE true
env_set "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH /api/sub-store/
env_set "$ENV_FILE" SUB_STORE_FRONTEND_PATH "$TEST_ROOT/frontend"
validate_env_consistency || fail "merged frontend with nested prefix"

mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/pm2" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == jlist ]]; then
    printf '%s\n' '[{"name":"sub-store-live","pm2_env":{"SUB_STORE_FRONTEND_BACKEND_PATH":"/live/path/"}}]'
    exit 0
fi
exit 1
EOF
chmod 755 "$TEST_ROOT/bin/pm2"
PATH="$TEST_ROOT/bin:$PATH"
PM2_NAME=sub-store-live
env_delete "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH
ensure_backend_path_for_merge || fail "recover backend path from PM2"
[[ "$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH)" == /live/path/ ]] || fail "persist recovered PM2 backend path"

DEPLOY_DIR="$TEST_ROOT/deploy"
BACKEND_FILE="$DEPLOY_DIR/sub-store.bundle.js"
FRONTEND_DIR="$DEPLOY_DIR/frontend"
DATA_DIR="$DEPLOY_DIR/data"
ENV_FILE="$DEPLOY_DIR/.env"
ECOSYSTEM_FILE="$DEPLOY_DIR/ecosystem.config.cjs"
MARKER_FILE="$DEPLOY_DIR/.substore-manager-instance"
PM2_NAME="sub-store-test"
PORT=39001
HOST=127.0.0.1
BACKEND_VERSION=1.2.3
FRONTEND_VERSION=4.5.6
INSTALL_ID=0123456789abcdef
CREATED_BY_MANAGER=1
DATA_CREATED_BY_MANAGER=1
FRONTEND_CREATED_BY_MANAGER=1
INSTALLED_AT=2026-08-29T00:00:00+00:00
AUTO_UPDATE_ENABLED=1
AUTO_UPDATE_INTERVAL_MINUTES=90
mkdir -p "$DEPLOY_DIR" "$DATA_DIR"
printf '%s\n' "$INSTALL_ID" >"$MARKER_FILE"
write_ecosystem
save_state

DEPLOY_DIR=""
PM2_NAME=""
INSTALL_PRESENT=0
load_state || fail "load state"
[[ "$DEPLOY_DIR" == "$TEST_ROOT/deploy" ]] || fail "state deploy dir"
[[ "$INSTANCE_ID" == default ]] || fail "default instance id"
[[ "$PM2_NAME" == sub-store-test ]] || fail "state PM2 name"
[[ "$DATA_CREATED_BY_MANAGER" == 1 ]] || fail "state data ownership"
[[ "$FRONTEND_CREATED_BY_MANAGER" == 1 ]] || fail "state frontend ownership"
[[ "$AUTO_UPDATE_ENABLED" == 1 ]] || fail "state auto-update enabled"
[[ "$AUTO_UPDATE_INTERVAL_MINUTES" == 90 ]] || fail "state auto-update interval"
grep -Fq '"watch": false' "$ECOSYSTEM_FILE" || fail "PM2 watch disabled"
grep -Fq '"cwd":' "$ECOSYSTEM_FILE" || fail "PM2 cwd missing"

write_auto_update_units
grep -Fq 'ExecStart=/usr/local/sbin/substore update' "$TEST_ROOT/systemd/substore-manager-update.service" || fail "auto-update service command"
grep -Fq 'OnUnitActiveSec=90min' "$TEST_ROOT/systemd/substore-manager-update.timer" || fail "auto-update interval"
validate_auto_update_interval 5 || fail "minimum auto-update interval"
if validate_auto_update_interval 4; then fail "invalid auto-update interval"; fi
if SUBSTORE_INSTANCE=.. SUBSTORE_MANAGER_LIBRARY_ONLY=1 bash "$SCRIPT" >/dev/null 2>&1; then
    fail "unsafe instance name accepted"
fi

SUBSTORE_MANAGER_LIBRARY_ONLY=1 \
SUBSTORE_INSTANCE=blue \
SUBSTORE_MANAGER_STATE_DIR="$TEST_ROOT/multi-state" \
SUBSTORE_MANAGER_SYSTEMD_DIR="$TEST_ROOT/multi-systemd" \
bash -c '
set -Eeuo pipefail
source "$1"
AUTO_UPDATE_INTERVAL_MINUTES=45
MANAGER_INSTALL_PATH=/usr/local/sbin/substore
write_auto_update_units
test "$STATE_ROOT" = "'"$TEST_ROOT"'/multi-state/instances/blue"
grep -Fq "ExecStart=/usr/local/sbin/substore --instance blue update" \
  "'"$TEST_ROOT"'/multi-systemd/substore-manager-update-blue.service"
grep -Fq "OnUnitActiveSec=45min" \
  "'"$TEST_ROOT"'/multi-systemd/substore-manager-update-blue.timer"
' _ "$SCRIPT" || fail "named instance timer isolation"

printf 'PASS: env parser, validation, state persistence, PM2 config and update timer\n'

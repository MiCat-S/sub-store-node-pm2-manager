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
if validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH abc; then fail "invalid prefix"; fi
validate_env_value SUB_STORE_BODY_JSON_LIMIT 10mb || fail "valid body limit"
validate_env_value SUB_STORE_CORS_ALLOWED_ORIGINS 'https://a.example,http://127.0.0.1:3000' || fail "valid cors"
validate_env_value SUB_STORE_PRODUCE_CRON '0 */2 * * *,sub,a;0 */3 * * *,col,b' || fail "valid produce cron"

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
mkdir -p "$DEPLOY_DIR" "$DATA_DIR"
printf '%s\n' "$INSTALL_ID" >"$MARKER_FILE"
write_ecosystem
save_state

DEPLOY_DIR=""
PM2_NAME=""
INSTALL_PRESENT=0
load_state || fail "load state"
[[ "$DEPLOY_DIR" == "$TEST_ROOT/deploy" ]] || fail "state deploy dir"
[[ "$PM2_NAME" == sub-store-test ]] || fail "state PM2 name"
[[ "$DATA_CREATED_BY_MANAGER" == 1 ]] || fail "state data ownership"
[[ "$FRONTEND_CREATED_BY_MANAGER" == 1 ]] || fail "state frontend ownership"
grep -Fq '"watch": false' "$ECOSYSTEM_FILE" || fail "PM2 watch disabled"
grep -Fq '"cwd":' "$ECOSYSTEM_FILE" || fail "PM2 cwd missing"

printf 'PASS: env parser, validation, state persistence and PM2 config\n'

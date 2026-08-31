#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2317,SC2329

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/substore.sh"
TEST_ROOT="$(mktemp -d)"

test_cleanup() {
    if declare -F cleanup >/dev/null 2>&1; then
        cleanup || true
    fi
    rm -rf -- "$TEST_ROOT"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message (expected: $expected; actual: $actual)"
}

tmp_registered() {
    local candidate="$1" path
    for path in "${TMP_PATHS[@]:-}"; do
        [[ "$path" == "$candidate" ]] && return 0
    done
    return 1
}

expect_layout_failure() {
    local message="$1"
    if validate_managed_layout >/dev/null 2>&1; then
        fail "$message"
    fi
}

export SUBSTORE_MANAGER_LIBRARY_ONLY=1
export SUBSTORE_MANAGER_STATE_DIR="$TEST_ROOT/state"
export SUBSTORE_MANAGER_SYSTEMD_DIR="$TEST_ROOT/systemd"
export SUBSTORE_MANAGER_SKIP_STATE_SECURITY=1
source "$SCRIPT"
trap test_cleanup EXIT
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
set -u

if [[ "${1:-}" != jlist ]]; then
    [[ -z "${PM2_FAKE_COMMAND_LOG:-}" ]] || printf '%s\n' "$*" >>"$PM2_FAKE_COMMAND_LOG"
    exit "${PM2_FAKE_COMMAND_EXIT:-0}"
fi

case "${PM2_FAKE_MODE:-live}" in
    fail)
        exit 42
        ;;
    bad-json)
        printf '%s\n' '{not-json'
        ;;
    missing)
        printf '%s\n' '[]'
        ;;
    live)
        printf '[{"name":"%s","pm2_env":{"status":"%s","pm_exec_path":"%s","SUB_STORE_FRONTEND_BACKEND_PATH":"%s"}}]\n' \
            "${PM2_FAKE_NAME:-sub-store-live}" \
            "${PM2_FAKE_STATUS:-online}" \
            "${PM2_FAKE_EXEC_PATH:-/tmp/sub-store.bundle.js}" \
            "${PM2_FAKE_BACKEND_PATH:-/live/path/}"
        ;;
    *)
        exit 43
        ;;
esac
EOF
chmod 755 "$TEST_ROOT/bin/pm2"

cat >"$TEST_ROOT/bin/flock" <<'EOF'
#!/usr/bin/env bash
set -u

[[ -z "${FLOCK_FAKE_LOG:-}" ]] || printf '%s\n' "$*" >>"$FLOCK_FAKE_LOG"
exit "${FLOCK_FAKE_EXIT:-0}"
EOF
chmod 755 "$TEST_ROOT/bin/flock"

cat >"$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u

state_dir="${SYSTEMCTL_FAKE_STATE_DIR:?}"
command_name="${1:-}"
should_fail=0
mkdir -p "$state_dir"
[[ -z "${SYSTEMCTL_FAKE_LOG:-}" ]] || printf '%s\n' "$*" >>"$SYSTEMCTL_FAKE_LOG"
if [[ -n "${SYSTEMCTL_FAKE_FAIL_ONCE:-}" && \
      "$command_name" == "$SYSTEMCTL_FAKE_FAIL_ONCE" && \
      ! -e "$state_dir/.failed-${command_name}" ]]; then
    : >"$state_dir/.failed-${command_name}"
    should_fail=1
fi

case "$command_name" in
    is-enabled) [[ -f "$state_dir/enabled" ]] ;;
    is-active) [[ -f "$state_dir/active" ]] ;;
    daemon-reload) (( should_fail == 0 )) || exit 97 ;;
    enable)
        : >"$state_dir/enabled"
        (( should_fail == 0 )) || exit 97
        ;;
    restart)
        : >"$state_dir/active"
        (( should_fail == 0 )) || exit 97
        ;;
    stop) command rm -f -- "$state_dir/active" ;;
    disable)
        command rm -f -- "$state_dir/enabled"
        for argument in "$@"; do
            [[ "$argument" != --now ]] || command rm -f -- "$state_dir/active"
        done
        ;;
    *) exit 64 ;;
esac
EOF
chmod 755 "$TEST_ROOT/bin/systemctl"

PATH="$TEST_ROOT/bin:$PATH"
export PATH
export PM2_FAKE_MODE=live
export PM2_FAKE_NAME=sub-store-live
export PM2_FAKE_STATUS=online
export PM2_FAKE_EXEC_PATH="$TEST_ROOT/live/sub-store.bundle.js"
export PM2_FAKE_BACKEND_PATH=/live/path/
PM2_NAME=sub-store-live
env_delete "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH
ensure_backend_path_for_merge || fail "recover backend path from PM2"
[[ "$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH)" == /live/path/ ]] || fail "persist recovered PM2 backend path"

cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u

output=""
while (($#)); do
    case "$1" in
        --output|-o)
            output="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[[ -n "$output" ]] || exit 2
cat >"$output" <<'JSON'
{"tag_name":"9.8.7","assets":[{"name":"asset.bin","browser_download_url":"https://mock.invalid/asset.bin","digest":null,"size":7}]}
JSON
EOF
chmod 755 "$TEST_ROOT/bin/curl"

old_github_api_base="$GITHUB_API_BASE"
GITHUB_API_BASE=https://mock.invalid
tmp_count_before=${#TMP_PATHS[@]}
release_info test/repo asset.bin
assert_eq 9.8.7 "$RELEASE_TAG" "release tag with empty digest"
assert_eq https://mock.invalid/asset.bin "$RELEASE_URL" "release URL with empty digest"
assert_eq "" "$RELEASE_DIGEST" "empty release digest preserved"
assert_eq 7 "$RELEASE_SIZE" "release size after empty digest"
assert_eq "$tmp_count_before" "${#TMP_PATHS[@]}" "release metadata temp files unregistered"
GITHUB_API_BASE="$old_github_api_base"

TMP_PATHS=()
registered_tmp=""
make_temp_dir registered_tmp "$TEST_ROOT/tmp-parent" .registered
[[ -d "$registered_tmp" ]] || fail "make_temp_dir creates directory"
tmp_registered "$registered_tmp" || fail "make_temp_dir registers directory"
unregister_tmp_path "$registered_tmp"
[[ -d "$registered_tmp" ]] || fail "unregister_tmp_path does not remove directory"
if tmp_registered "$registered_tmp"; then fail "unregister_tmp_path removes registration"; fi
register_tmp "$registered_tmp"
cleanup_tmp_path "$registered_tmp"
[[ ! -e "$registered_tmp" ]] || fail "cleanup_tmp_path removes directory"
if tmp_registered "$registered_tmp"; then fail "cleanup_tmp_path removes registration"; fi

if ! (
    trap - EXIT
    TMP_PATHS=()
    retry_cleanup_path="$TEST_ROOT/retry-cleanup"
    mkdir -p "$retry_cleanup_path"
    register_tmp "$retry_cleanup_path"
    cleanup_rm_attempts=0
    rm() {
        ((cleanup_rm_attempts += 1))
        if (( cleanup_rm_attempts == 1 )); then
            return 74
        fi
        command rm "$@"
    }
    if cleanup_tmp_path "$retry_cleanup_path" >/dev/null 2>&1; then
        exit 1
    fi
    [[ -d "$retry_cleanup_path" ]]
    tmp_registered "$retry_cleanup_path"
    cleanup_tmp_path "$retry_cleanup_path"
    [[ ! -e "$retry_cleanup_path" ]]
    if tmp_registered "$retry_cleanup_path"; then exit 1; fi
    [[ "$cleanup_rm_attempts" == 2 ]]
); then
    fail "failed temp cleanup was not retained for retry"
fi

layout_root="$TEST_ROOT/layout"
mkdir -p "$layout_root/deploy-real" "$layout_root/data"
ln -s "$layout_root/deploy-real" "$layout_root/deploy-link"

DEPLOY_DIR="$layout_root/deploy-real"
DATA_DIR="$DEPLOY_DIR/data"
FRONTEND_DIR="$DEPLOY_DIR/frontend"
validate_managed_layout || fail "safe managed layout"

DATA_DIR="$DEPLOY_DIR"
expect_layout_failure "data directory equal to deploy directory accepted"
DATA_DIR="$layout_root"
expect_layout_failure "data directory above deploy directory accepted"
DATA_DIR="$DEPLOY_DIR/data"
FRONTEND_DIR="$DATA_DIR/frontend"
expect_layout_failure "frontend nested inside data directory accepted"
FRONTEND_DIR="$DEPLOY_DIR/backups/frontend"
expect_layout_failure "frontend inside backup directory accepted"
FRONTEND_DIR="$DEPLOY_DIR/.substore-update.payload"
expect_layout_failure "frontend using temporary directory prefix accepted"
FRONTEND_DIR="$layout_root/deploy-link"
expect_layout_failure "symlink alias of deploy directory accepted"

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
printf '%s\n' "$INSTALL_ID" >"$DATA_DIR/.substore-manager-data"
mkdir -p "$FRONTEND_DIR"
touch "$FRONTEND_DIR/index.html"
printf '%s\n' "$INSTALL_ID" >"$FRONTEND_DIR/.substore-manager-frontend"
printf '%s\n' '// SUB_STORE_BACKEND_VERSION: 1.2.3' >"$BACKEND_FILE"
env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT "$PORT"
env_set "$ENV_FILE" SUB_STORE_BACKEND_API_HOST "$HOST"
env_set "$ENV_FILE" SUB_STORE_DATA_BASE_PATH "$DATA_DIR"
env_set "$ENV_FILE" SUB_STORE_FRONTEND_PATH "$FRONTEND_DIR"
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
validate_instance_files || fail "complete instance files"
if compgen -G "${STATE_FILE}.tmp.*" >/dev/null; then fail "state temp file leaked"; fi

state_before_failed_save="$TEST_ROOT/state-before-failed-save.conf"
cp -p -- "$STATE_FILE" "$state_before_failed_save"
if (
    trap - EXIT
    PORT=59999
    printf() {
        return 91
    }
    save_state >/dev/null 2>&1
); then
    fail "state write failure reported success"
fi
cmp -s "$state_before_failed_save" "$STATE_FILE" || fail "failed state write replaced existing state"
if compgen -G "${STATE_FILE}.tmp.*" >/dev/null; then fail "failed state write leaked temp file"; fi

dangling_marker_dir="$TEST_ROOT/dangling-marker"
dangling_marker="$dangling_marker_dir/.substore-manager-frontend"
mkdir -p "$dangling_marker_dir"
ln -s "$dangling_marker_dir/missing-target" "$dangling_marker"
if manager_marker_matches "$dangling_marker"; then fail "dangling marker symlink accepted"; fi
if write_manager_marker "$dangling_marker" >/dev/null 2>&1; then fail "dangling marker symlink overwritten"; fi
[[ -L "$dangling_marker" ]] || fail "rejected dangling marker symlink was removed"

printf '%s\n' wrong-install-id >"$DATA_DIR/.substore-manager-data"
if validate_instance_files >/dev/null 2>&1; then fail "mismatched data marker accepted"; fi
printf '%s\n' "$INSTALL_ID" >"$DATA_DIR/.substore-manager-data"

safe_data_dir="$DATA_DIR"
safe_frontend_dir="$FRONTEND_DIR"
state_hash_before_invalid_env="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
env_set "$ENV_FILE" SUB_STORE_DATA_BASE_PATH "$safe_frontend_dir"
if sync_state_from_env >/dev/null 2>&1; then fail "unsafe Env directory layout synchronized into state"; fi
assert_eq "$safe_data_dir" "$DATA_DIR" "data directory restored after rejected Env sync"
assert_eq "$safe_frontend_dir" "$FRONTEND_DIR" "frontend directory restored after rejected Env sync"
assert_eq "$state_hash_before_invalid_env" "$(sha256sum "$STATE_FILE" | awk '{print $1}')" "state unchanged after rejected Env sync"
env_set "$ENV_FILE" SUB_STORE_DATA_BASE_PATH "$safe_data_dir"

original_env_hash="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
original_state_hash="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
begin_env_transaction || fail "begin env transaction"
env_backup="$ENV_TRANSACTION_BACKUP"
state_backup="$STATE_TRANSACTION_BACKUP"
[[ -f "$env_backup" && -f "$state_backup" ]] || fail "transaction backups created"
tmp_registered "$env_backup" || fail "env transaction backup registered"
tmp_registered "$state_backup" || fail "state transaction backup registered"
[[ "$UPDATE_LOCK_HELD" == 1 ]] || fail "env transaction holds update lock"

new_data="$TEST_ROOT/transaction-data"
new_frontend="$TEST_ROOT/transaction-frontend"
mkdir -p "$new_data" "$new_frontend"
printf '%s\n' "$INSTALL_ID" >"$new_data/.substore-manager-data"
printf '%s\n' "$INSTALL_ID" >"$new_frontend/.substore-manager-frontend"
DATA_DIR="$new_data"
FRONTEND_DIR="$new_frontend"
PORT=49001
env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT "$PORT"
env_set "$ENV_FILE" SUB_STORE_DATA_BASE_PATH "$DATA_DIR"
env_set "$ENV_FILE" SUB_STORE_FRONTEND_PATH "$FRONTEND_DIR"
save_state
rollback_env_transaction || fail "rollback env transaction"
assert_eq "$original_env_hash" "$(sha256sum "$ENV_FILE" | awk '{print $1}')" "env content restored"
assert_eq "$original_state_hash" "$(sha256sum "$STATE_FILE" | awk '{print $1}')" "state content restored"
assert_eq 39001 "$PORT" "state variables reloaded after rollback"
[[ ! -e "$new_data/.substore-manager-data" ]] || fail "rolled-back data marker removed"
[[ ! -e "$new_frontend/.substore-manager-frontend" ]] || fail "rolled-back frontend marker removed"
[[ ! -e "$env_backup" && ! -e "$state_backup" ]] || fail "transaction backups cleaned after rollback"
[[ "$UPDATE_LOCK_HELD" == 0 ]] || fail "env transaction lock released after rollback"

begin_env_transaction || fail "begin env transaction for commit"
env_backup="$ENV_TRANSACTION_BACKUP"
state_backup="$STATE_TRANSACTION_BACKUP"
commit_env_transaction
[[ ! -e "$env_backup" && ! -e "$state_backup" ]] || fail "transaction backups cleaned after commit"
[[ -z "$ENV_TRANSACTION_BACKUP" && -z "$STATE_TRANSACTION_BACKUP" ]] || fail "transaction backup variables cleared"
[[ "$UPDATE_LOCK_HELD" == 0 ]] || fail "env transaction lock released after commit"

flock_log="$TEST_ROOT/manager-flock.log"
: >"$flock_log"
export FLOCK_FAKE_LOG="$flock_log"
MANAGER_LOCK_HELD=0
MANAGER_LOCK_DEPTH=0
acquire_manager_lock_wait || fail "acquire manager lock"
assert_eq 1 "$MANAGER_LOCK_DEPTH" "manager lock initial depth"
acquire_manager_lock_wait || fail "reenter manager lock"
assert_eq 2 "$MANAGER_LOCK_DEPTH" "manager lock reentrant depth"
assert_eq 1 "$(wc -l <"$flock_log" | tr -d ' ')" "reentrant manager lock avoids another flock"
release_manager_lock
assert_eq 1 "$MANAGER_LOCK_DEPTH" "first manager lock release decrements depth"
[[ "$MANAGER_LOCK_HELD" == 1 ]] || fail "first manager lock release kept lock held"
if ! { : >&8; } 2>/dev/null; then fail "manager lock fd closed before final release"; fi
assert_eq 1 "$(wc -l <"$flock_log" | tr -d ' ')" "first manager lock release avoids unlock"
release_manager_lock
assert_eq 0 "$MANAGER_LOCK_DEPTH" "final manager lock release clears depth"
[[ "$MANAGER_LOCK_HELD" == 0 ]] || fail "final manager lock release clears held state"
assert_eq 2 "$(wc -l <"$flock_log" | tr -d ' ')" "final manager lock release unlocks once"
assert_eq '-n 8' "$(sed -n '1p' "$flock_log")" "manager lock acquisition flock call"
assert_eq '-u 8' "$(sed -n '2p' "$flock_log")" "manager lock release flock call"
if { : >&8; } 2>/dev/null; then fail "manager lock fd remained open after final release"; fi
[[ -f "$MANAGER_LOCK_FILE" ]] || fail "stable manager lock file removed on release"
release_manager_lock
assert_eq 2 "$(wc -l <"$flock_log" | tr -d ' ')" "extra manager lock release is idempotent"
unset FLOCK_FAKE_LOG

PM2_NAME=pm2-check
BACKEND_FILE="$TEST_ROOT/pm2-expected/sub-store.bundle.js"
export PM2_FAKE_NAME="$PM2_NAME"
export PM2_FAKE_STATUS=online
export PM2_FAKE_EXEC_PATH="$BACKEND_FILE"

export PM2_FAKE_MODE=fail
discovered_instances=sentinel
if discovered_instances="$(discover_pm2_instances 2>/dev/null)"; then
    fail "PM2 discovery accepted jlist command failure"
fi
assert_eq "" "$discovered_instances" "PM2 discovery failure emitted no instances"
if load_pm2_process_info >/dev/null 2>&1; then
    fail "PM2 jlist command failure accepted"
else
    assert_eq 2 "$?" "PM2 jlist failure status"
fi

export PM2_FAKE_MODE=bad-json
discovered_instances=sentinel
if discovered_instances="$(discover_pm2_instances 2>/dev/null)"; then
    fail "PM2 discovery accepted invalid JSON"
fi
assert_eq "" "$discovered_instances" "invalid PM2 JSON emitted no instances"
if load_pm2_process_info >/dev/null 2>&1; then
    fail "invalid PM2 JSON accepted"
else
    assert_eq 2 "$?" "invalid PM2 JSON status"
fi

export PM2_FAKE_MODE=live
load_pm2_process_info || fail "valid PM2 JSON"
assert_eq online "$PM2_STATUS" "PM2 online status"
assert_eq "$BACKEND_FILE" "$PM2_EXEC_PATH" "PM2 executable path"
pm2_process_matches_instance || fail "PM2 target matches instance"

export PM2_FAKE_EXEC_PATH="$TEST_ROOT/other/sub-store.bundle.js"
if pm2_process_matches_instance >/dev/null 2>&1; then fail "wrong PM2 entry accepted"; fi
pm2_command_log="$TEST_ROOT/pm2-command.log"
export PM2_FAKE_COMMAND_LOG="$pm2_command_log"
if start_instance >/dev/null 2>&1; then fail "start accepted PM2 name pointing elsewhere"; fi
[[ ! -s "$pm2_command_log" ]] || fail "wrong PM2 target triggered mutating command"

export PM2_FAKE_MODE=missing
load_pm2_process_info || fail "missing PM2 process parsed"
assert_eq missing "$PM2_STATUS" "missing PM2 status"
assert_eq "" "$PM2_EXEC_PATH" "missing PM2 executable path"

export PM2_FAKE_MODE=live
unset PM2_FAKE_COMMAND_LOG
load_state || fail "restore managed state after PM2 tests"

other_state_dir="$STATE_BASE/instances/other"
other_deploy="$TEST_ROOT/other-deploy"
other_data="$TEST_ROOT/shared-data"
other_frontend="$TEST_ROOT/other-frontend"
mkdir -p "$other_state_dir"
{
    printf 'DEPLOY_DIR=%q\n' "$other_deploy"
    printf 'DATA_DIR=%q\n' "$other_data"
    printf 'FRONTEND_DIR=%q\n' "$other_frontend"
    printf 'PM2_NAME=%q\n' sub-store-other
    printf 'PORT=%q\n' 49002
} >"$other_state_dir/instance.conf"
chmod 600 "$other_state_dir/instance.conf"

current_deploy="$DEPLOY_DIR"
current_data="$DATA_DIR"
current_frontend="$FRONTEND_DIR"
current_pm2="$PM2_NAME"
current_port="$PORT"

DATA_DIR="$other_data"
if assert_paths_not_managed_elsewhere >/dev/null 2>&1; then
    fail "shared data directory across instances accepted"
fi
DEPLOY_DIR="$current_deploy"
DATA_DIR="$current_data"
FRONTEND_DIR="$current_frontend"

PM2_NAME=sub-store-other
if (trap - EXIT; assert_identity_not_managed_elsewhere >/dev/null 2>&1); then
    fail "duplicate PM2 name across instances accepted"
fi
PM2_NAME="$current_pm2"
PORT=49002
if (trap - EXIT; assert_identity_not_managed_elsewhere >/dev/null 2>&1); then
    fail "duplicate port across instances accepted"
fi
PORT="$current_port"
assert_paths_not_managed_elsewhere || fail "non-conflicting instance paths"
assert_identity_not_managed_elsewhere || fail "non-conflicting instance identity"
rm -rf -- "$other_state_dir"

if ! (
    trap - EXIT
    import_deploy="$(normalize_path "$TEST_ROOT/imported-deploy")"
    DEPLOY_DIR="$import_deploy"
    BACKEND_FILE="$DEPLOY_DIR/sub-store.bundle.js"
    FRONTEND_DIR="$DEPLOY_DIR/frontend"
    DATA_DIR="$DEPLOY_DIR/data"
    ENV_FILE="$DEPLOY_DIR/.env"
    ECOSYSTEM_FILE="$DEPLOY_DIR/.substore-manager.ecosystem.config.cjs"
    MARKER_FILE="$DEPLOY_DIR/.substore-manager-instance"
    STATE_ROOT="$TEST_ROOT/imported-state"
    STATE_FILE="$STATE_ROOT/instance.conf"
    PM2_NAME=sub-store-imported
    PORT=49003
    HOST=127.0.0.1
    BACKEND_VERSION=7.8.9
    FRONTEND_VERSION=unknown
    INSTALL_ID=imported0123456789
    CREATED_BY_MANAGER=0
    DATA_CREATED_BY_MANAGER=0
    FRONTEND_CREATED_BY_MANAGER=0
    INSTALLED_AT=2026-08-31T00:00:00+00:00
    AUTO_UPDATE_ENABLED=0
    AUTO_UPDATE_INTERVAL_MINUTES=60
    BACKUP_RETENTION_COUNT=10
    LAST_BACKUP_DIR=""
    mkdir -p "$DEPLOY_DIR" "$DATA_DIR" "$FRONTEND_DIR"
    printf '%s\n' '// SUB_STORE_BACKEND_VERSION: 7.8.9' >"$BACKEND_FILE"
    printf '%s\n' '<!doctype html>' >"$FRONTEND_DIR/index.html"
    printf '%s\n' "$INSTALL_ID" >"$MARKER_FILE"
    printf '%s\n' "$INSTALL_ID" >"$DATA_DIR/.substore-manager-data"
    printf '%s\n' "$INSTALL_ID" >"$FRONTEND_DIR/.substore-manager-frontend"
    env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT "$PORT"
    env_set "$ENV_FILE" SUB_STORE_BACKEND_API_HOST "$HOST"
    env_set "$ENV_FILE" SUB_STORE_DATA_BASE_PATH "$DATA_DIR"
    env_set "$ENV_FILE" SUB_STORE_FRONTEND_PATH "$FRONTEND_DIR"
    write_ecosystem
    save_state
    create_backup imported 0 0 >/dev/null
    [[ -f "$LAST_BACKUP_DIR/files/ecosystem.config.cjs" ]]
    validate_backup "$LAST_BACKUP_DIR"
); then
    fail "imported ecosystem backup failed validation"
fi

if ! (
    trap - EXIT
    FRONTEND_DIR="$TEST_ROOT/frontend-replace-failure"
    frontend_stage="$TEST_ROOT/frontend-replace-stage"
    FRONTEND_CREATED_BY_MANAGER=1
    INSTALL_ID=frontend0123456789
    mkdir -p "$FRONTEND_DIR" "$frontend_stage"
    printf '%s\n' '<!doctype html><title>old</title>' >"$FRONTEND_DIR/index.html"
    printf '%s\n' old >"$FRONTEND_DIR/old.js"
    printf '%s\n' "$INSTALL_ID" >"$FRONTEND_DIR/.substore-manager-frontend"
    printf '%s\n' '<!doctype html><title>new</title>' >"$frontend_stage/index.html"
    cp_called=0
    cp() {
        cp_called=1
        return 28
    }
    if install_frontend_tree "$frontend_stage" >/dev/null 2>&1; then
        exit 1
    fi
    [[ "$cp_called" == 1 ]]
    manager_marker_matches "$(frontend_marker_path)"
    [[ "$(<"$(frontend_marker_path)")" == "$INSTALL_ID" ]]
); then
    fail "frontend replacement failure removed its manager marker"
fi

if ! (
    trap - EXIT
    data_restore_root="$TEST_ROOT/data-root-restore"
    DEPLOY_DIR="$data_restore_root/deploy"
    DATA_DIR="$DEPLOY_DIR"
    BACKEND_FILE="$DEPLOY_DIR/sub-store.bundle.js"
    FRONTEND_DIR="$DEPLOY_DIR/frontend"
    ENV_FILE="$DEPLOY_DIR/.env"
    ECOSYSTEM_FILE="$DEPLOY_DIR/ecosystem.config.cjs"
    MARKER_FILE="$DEPLOY_DIR/.substore-manager-instance"
    restore_stage="$data_restore_root/stage"
    mkdir -p "$DEPLOY_DIR" "$restore_stage"
    printf '%s\n' old-moved >"$DEPLOY_DIR/moved-entry"
    printf '%s\n' old-unmoved >"$DEPLOY_DIR/unmoved-entry"
    printf '%s\n' new-moved >"$restore_stage/moved-entry"
    printf '%s\n' new-unmoved >"$restore_stage/unmoved-entry"
    mv_failure_seen=0
    find() {
        if [[ "${1:-}" == "$DEPLOY_DIR" ]]; then
            printf '%s\0%s\0' "$DEPLOY_DIR/moved-entry" "$DEPLOY_DIR/unmoved-entry"
        else
            command find "$@"
        fi
    }
    mv() {
        if [[ "${1:-}" == -- && "${2:-}" == "$DEPLOY_DIR/unmoved-entry" ]]; then
            mv_failure_seen=1
            return 72
        fi
        command mv "$@"
    }
    if restore_data_root_from_stage "$restore_stage" >/dev/null 2>&1; then
        exit 1
    fi
    [[ "$mv_failure_seen" == 1 ]]
    [[ "$(<"$DEPLOY_DIR/moved-entry")" == old-moved ]]
    [[ "$(<"$DEPLOY_DIR/unmoved-entry")" == old-unmoved ]]
    [[ "$(<"$restore_stage/moved-entry")" == new-moved ]]
    [[ "$(<"$restore_stage/unmoved-entry")" == new-unmoved ]]
    if compgen -G "$data_restore_root/.substore-data-old.*" >/dev/null; then
        exit 1
    fi
); then
    fail "failed data-root move did not preserve and restore current data"
fi

setup_auto_update_test_case() {
    local case_root="$1" source_state="$2"
    STATE_ROOT="$case_root/state"
    STATE_FILE="$STATE_ROOT/instance.conf"
    SYSTEMD_DIR="$case_root/systemd"
    TMPDIR="$case_root/tmp"
    SYSTEMCTL_FAKE_STATE_DIR="$case_root/systemctl-state"
    SYSTEMCTL_FAKE_LOG="$case_root/systemctl.log"
    AUTO_TEST_EXPECTED_SERVICE="$case_root/expected.service"
    AUTO_TEST_EXPECTED_TIMER="$case_root/expected.timer"
    AUTO_TEST_EXPECTED_STATE="$case_root/expected.state"
    export TMPDIR SYSTEMCTL_FAKE_STATE_DIR SYSTEMCTL_FAKE_LOG
    mkdir -p "$STATE_ROOT" "$SYSTEMD_DIR" "$TMPDIR" "$SYSTEMCTL_FAKE_STATE_DIR" || return 1
    cp -p -- "$source_state" "$STATE_FILE" || return 1
    printf '%s\n' old-service >"$SYSTEMD_DIR/$AUTO_UPDATE_SERVICE_NAME" || return 1
    printf '%s\n' old-timer >"$SYSTEMD_DIR/$AUTO_UPDATE_TIMER_NAME" || return 1
    cp -p -- "$SYSTEMD_DIR/$AUTO_UPDATE_SERVICE_NAME" "$AUTO_TEST_EXPECTED_SERVICE" || return 1
    cp -p -- "$SYSTEMD_DIR/$AUTO_UPDATE_TIMER_NAME" "$AUTO_TEST_EXPECTED_TIMER" || return 1
    cp -p -- "$STATE_FILE" "$AUTO_TEST_EXPECTED_STATE" || return 1
    : >"$SYSTEMCTL_FAKE_LOG"
    AUTO_UPDATE_TRANSACTION_ACTIVE=0
    AUTO_UPDATE_TRANSACTION_DIR=""
    AUTO_UPDATE_SERVICE_EXISTED=0
    AUTO_UPDATE_TIMER_EXISTED=0
    AUTO_UPDATE_WAS_ENABLED=0
    AUTO_UPDATE_WAS_ACTIVE=0
    UPDATE_LOCK_HELD=0
    UPDATE_LOCK_DEPTH=0
    TMP_PATHS=()
    SUBSTORE_MANAGER_SKIP_ROOT_CHECK=1
}

assert_enable_auto_update_rollback() {
    local failure="$1" source_state="$2" case_root
    case_root="$TEST_ROOT/auto-enable-$failure"
    if ! (
        trap - EXIT
        setup_auto_update_test_case "$case_root" "$source_state" || exit 1
        SYSTEMCTL_FAKE_FAIL_ONCE="$failure"
        export SYSTEMCTL_FAKE_FAIL_ONCE
        save_state_failure_seen=0
        if [[ "$failure" == save-state ]]; then
            SYSTEMCTL_FAKE_FAIL_ONCE=""
            save_state() {
                save_state_failure_seen=1
                return 89
            }
        fi
        install_manager_command() { return 0; }
        if enable_auto_update 120 >/dev/null 2>&1; then
            exit 1
        fi
        cmp -s "$AUTO_TEST_EXPECTED_SERVICE" "$SYSTEMD_DIR/$AUTO_UPDATE_SERVICE_NAME" || exit 1
        cmp -s "$AUTO_TEST_EXPECTED_TIMER" "$SYSTEMD_DIR/$AUTO_UPDATE_TIMER_NAME" || exit 1
        cmp -s "$AUTO_TEST_EXPECTED_STATE" "$STATE_FILE" || exit 1
        [[ ! -e "$SYSTEMCTL_FAKE_STATE_DIR/enabled" && ! -e "$SYSTEMCTL_FAKE_STATE_DIR/active" ]] || exit 1
        [[ "$(grep -c '^daemon-reload$' "$SYSTEMCTL_FAKE_LOG")" == 2 ]] || exit 1
        [[ "$AUTO_UPDATE_TRANSACTION_ACTIVE" == 0 && -z "$AUTO_UPDATE_TRANSACTION_DIR" ]] || exit 1
        [[ "$UPDATE_LOCK_HELD" == 0 && "$UPDATE_LOCK_DEPTH" == 0 ]] || exit 1
        if { : >&9; } 2>/dev/null; then exit 1; fi
        if compgen -G "$TMPDIR/.substore-auto-update.*" >/dev/null; then exit 1; fi
        if [[ "$failure" == save-state ]]; then
            [[ "$save_state_failure_seen" == 1 ]] || exit 1
        else
            [[ -f "$SYSTEMCTL_FAKE_STATE_DIR/.failed-$failure" ]] || exit 1
        fi
    ); then
        fail "auto-update rollback failed after $failure failure"
    fi
}

auto_update_source_state="$STATE_FILE"
for auto_update_failure in daemon-reload enable restart save-state; do
    assert_enable_auto_update_rollback "$auto_update_failure" "$auto_update_source_state"
done

if ! (
    trap - EXIT
    remove_case_root="$TEST_ROOT/auto-remove-rm"
    setup_auto_update_test_case "$remove_case_root" "$auto_update_source_state" || exit 1
    : >"$SYSTEMCTL_FAKE_STATE_DIR/enabled"
    : >"$SYSTEMCTL_FAKE_STATE_DIR/active"
    SYSTEMCTL_FAKE_FAIL_ONCE=""
    export SYSTEMCTL_FAKE_FAIL_ONCE
    unit_rm_failure_seen=0
    rm() {
        local argument
        for argument in "$@"; do
            if [[ "$argument" == "$SYSTEMD_DIR/$AUTO_UPDATE_SERVICE_NAME" || \
                  "$argument" == "$SYSTEMD_DIR/$AUTO_UPDATE_TIMER_NAME" ]]; then
                unit_rm_failure_seen=1
                return 73
            fi
        done
        command rm "$@"
    }
    if remove_auto_update_units >/dev/null 2>&1; then
        exit 1
    fi
    [[ "$unit_rm_failure_seen" == 1 ]] || exit 1
    cmp -s "$AUTO_TEST_EXPECTED_SERVICE" "$SYSTEMD_DIR/$AUTO_UPDATE_SERVICE_NAME" || exit 1
    cmp -s "$AUTO_TEST_EXPECTED_TIMER" "$SYSTEMD_DIR/$AUTO_UPDATE_TIMER_NAME" || exit 1
    cmp -s "$AUTO_TEST_EXPECTED_STATE" "$STATE_FILE" || exit 1
    [[ -f "$SYSTEMCTL_FAKE_STATE_DIR/enabled" && -f "$SYSTEMCTL_FAKE_STATE_DIR/active" ]] || exit 1
    grep -Fxq "disable --now $AUTO_UPDATE_TIMER_NAME" "$SYSTEMCTL_FAKE_LOG" || exit 1
    grep -Fxq "enable $AUTO_UPDATE_TIMER_NAME" "$SYSTEMCTL_FAKE_LOG" || exit 1
    grep -Fxq "restart $AUTO_UPDATE_TIMER_NAME" "$SYSTEMCTL_FAKE_LOG" || exit 1
    [[ "$AUTO_UPDATE_TRANSACTION_ACTIVE" == 0 && -z "$AUTO_UPDATE_TRANSACTION_DIR" ]] || exit 1
    [[ "$UPDATE_LOCK_HELD" == 0 && "$UPDATE_LOCK_DEPTH" == 0 ]] || exit 1
    if { : >&9; } 2>/dev/null; then exit 1; fi
    if compgen -G "$TMPDIR/.substore-auto-update.*" >/dev/null; then exit 1; fi
); then
    fail "auto-update unit rm failure was not rolled back"
fi

if ! (
    trap - EXIT
    HOST=::1
    [[ "$(health_host)" == '[::1]' ]]
    HOST=2001:db8::1234
    [[ "$(health_host)" == '[2001:db8::1234]' ]]
); then
    fail "IPv6 health host formatting"
fi

write_auto_update_units
grep -Fq 'ExecStart=/usr/local/sbin/substore update' "$TEST_ROOT/systemd/substore-manager-update.service" || fail "auto-update service command"
grep -Fq 'OnUnitActiveSec=90min' "$TEST_ROOT/systemd/substore-manager-update.timer" || fail "auto-update interval"
validate_auto_update_interval 15 || fail "minimum auto-update interval"
if validate_auto_update_interval 14; then fail "invalid auto-update interval"; fi
if SUBSTORE_INSTANCE=.. SUBSTORE_MANAGER_LIBRARY_ONLY=1 "$BASH" "$SCRIPT" >/dev/null 2>&1; then
    fail "unsafe instance name accepted"
fi

SUBSTORE_MANAGER_LIBRARY_ONLY=1 \
SUBSTORE_INSTANCE=blue \
SUBSTORE_MANAGER_STATE_DIR="$TEST_ROOT/multi-state" \
SUBSTORE_MANAGER_SYSTEMD_DIR="$TEST_ROOT/multi-systemd" \
"$BASH" -c '
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

printf 'PASS: env/state/auto-update transactions, data rollback, marker safety, locks, PM2 and timer\n'

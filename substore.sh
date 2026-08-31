#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

MANAGER_VERSION="1.1.0"
MANAGER_ID="MiCat-S/sub-store-node-pm2-manager"
BACKEND_REPO="sub-store-org/Sub-Store"
FRONTEND_REPO="sub-store-org/Sub-Store-Front-End"
BACKEND_ASSET="sub-store.bundle.js"
FRONTEND_ASSET="dist.zip"
INSTANCE_ID="${SUBSTORE_INSTANCE:-default}"
if [[ "${1:-}" == --instance || "${1:-}" == -i ]]; then
    [[ -n "${2:-}" ]] || { printf '缺少实例名称\n' >&2; exit 2; }
    INSTANCE_ID="$2"
    shift 2
fi
if [[ ! "$INSTANCE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || ${#INSTANCE_ID} -gt 48 ]]; then
    printf '实例名称必须以字母或数字开头，只能包含字母、数字、点、下划线和连字符，最长 48 个字符\n' >&2
    exit 2
fi

STATE_BASE="${SUBSTORE_MANAGER_STATE_DIR:-/etc/substore-manager}"
if [[ "$INSTANCE_ID" == default ]]; then
    STATE_ROOT="$STATE_BASE"
    AUTO_UPDATE_SERVICE_NAME="substore-manager-update.service"
    AUTO_UPDATE_TIMER_NAME="substore-manager-update.timer"
else
    STATE_ROOT="${STATE_BASE}/instances/${INSTANCE_ID}"
    AUTO_UPDATE_SERVICE_NAME="substore-manager-update-${INSTANCE_ID}.service"
    AUTO_UPDATE_TIMER_NAME="substore-manager-update-${INSTANCE_ID}.timer"
fi
STATE_FILE="${STATE_ROOT}/instance.conf"
LOCK_DIR="${STATE_BASE}/locks"
INSTANCE_LOCK_FILE="${LOCK_DIR}/${INSTANCE_ID}.lock"
MANAGER_LOCK_FILE="${LOCK_DIR}/manager.lock"
MANAGER_INSTALL_PATH="${SUBSTORE_MANAGER_INSTALL_PATH:-/usr/local/sbin/substore}"
SYSTEMD_DIR="${SUBSTORE_MANAGER_SYSTEMD_DIR:-/etc/systemd/system}"
MANAGER_GITHUB_ENV_FILE="${STATE_BASE}/github.env"
GITHUB_API_BASE="${SUBSTORE_MANAGER_GITHUB_API_BASE:-https://api.github.com}"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

INSTALL_PRESENT=0
CREATED_BY_MANAGER=""
DATA_CREATED_BY_MANAGER=""
FRONTEND_CREATED_BY_MANAGER=""
INSTALL_ID=""
DEPLOY_DIR=""
BACKEND_FILE=""
FRONTEND_DIR=""
DATA_DIR=""
ENV_FILE=""
ECOSYSTEM_FILE=""
MARKER_FILE=""
PM2_NAME=""
PORT=""
HOST=""
BACKEND_VERSION=""
FRONTEND_VERSION=""
NODE_BIN=""
INSTALLED_AT=""
AUTO_UPDATE_ENABLED=0
AUTO_UPDATE_INTERVAL_MINUTES=60
BACKUP_RETENTION_COUNT=10
UPDATE_LOCK_HELD=0
UPDATE_LOCK_DEPTH=0
MANAGER_LOCK_HELD=0
MANAGER_LOCK_DEPTH=0
INSTALL_TRANSACTION_ACTIVE=0
IMPORT_TRANSACTION_ACTIVE=0
UPDATE_TRANSACTION_ACTIVE=0
UPDATE_ORIGINAL_STATUS=""
LAST_BACKUP_DIR=""
ENV_TRANSACTION_BACKUP=""
STATE_TRANSACTION_BACKUP=""
ENV_TRANSACTION_ACTIVE=0
ENV_TRANSACTION_ORIGINAL_DATA_DIR=""
ENV_TRANSACTION_ORIGINAL_FRONTEND_DIR=""
ENV_TRANSACTION_CREATED_DATA_DIR=0
AUTO_UPDATE_TRANSACTION_ACTIVE=0
AUTO_UPDATE_TRANSACTION_DIR=""
AUTO_UPDATE_SERVICE_EXISTED=0
AUTO_UPDATE_TIMER_EXISTED=0
AUTO_UPDATE_WAS_ENABLED=0
AUTO_UPDATE_WAS_ACTIVE=0
UNINSTALL_TRANSACTION_ACTIVE=0
UNINSTALL_ORIGINAL_STATUS=""
UNINSTALL_ORIGINAL_PATHS=()
UNINSTALL_STAGED_PATHS=()
DEPLOY_DIR_EXISTED=0
PM2_CREATED_BY_TRANSACTION=0
PM2_STATUS=""
PM2_EXEC_PATH=""
PM2_RESTART_FAILURE_INJECTED=0
TMP_PATHS=()

declare -a OFFICIAL_ENV_ORDER=()
declare -A ENV_DESC=()
declare -A ENV_DEFAULT=()
declare -A ENV_DEFAULT_LABEL=()
declare -A ENV_TYPE=()
declare -A ENV_SENSITIVE=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
else
    C_RESET=""
    C_BOLD=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
fi

log_info() {
    printf '%s[INFO]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

cleanup() {
    local path
    if [[ "$INSTALL_TRANSACTION_ACTIVE" == 1 ]] && declare -F rollback_incomplete_install >/dev/null 2>&1; then
        rollback_incomplete_install
    fi
    if [[ "$IMPORT_TRANSACTION_ACTIVE" == 1 ]] && declare -F rollback_incomplete_import >/dev/null 2>&1; then
        rollback_incomplete_import
    fi
    if [[ "$UNINSTALL_TRANSACTION_ACTIVE" == 1 ]] && declare -F rollback_uninstall_transaction >/dev/null 2>&1; then
        rollback_uninstall_transaction || log_error "卸载事务自动恢复失败"
    fi
    if [[ "$ENV_TRANSACTION_ACTIVE" == 1 ]] && declare -F rollback_env_transaction >/dev/null 2>&1; then
        rollback_env_transaction || log_error "Env 事务自动恢复失败"
    fi
    if [[ "$AUTO_UPDATE_TRANSACTION_ACTIVE" == 1 ]] && declare -F rollback_auto_update_transaction >/dev/null 2>&1; then
        rollback_auto_update_transaction || log_error "自动更新配置事务恢复失败"
    fi
    if [[ "$UPDATE_TRANSACTION_ACTIVE" == 1 ]] && declare -F rollback_interrupted_update >/dev/null 2>&1; then
        rollback_interrupted_update
    fi
    for path in "${TMP_PATHS[@]:-}"; do
        if [[ -n "$path" && -e "$path" ]]; then
            rm -rf -- "$path" || log_warn "临时路径清理失败：$path"
        fi
    done
}

trap cleanup EXIT

require_root() {
    if [[ "${SUBSTORE_MANAGER_SKIP_ROOT_CHECK:-0}" != 1 && "$EUID" -ne 0 ]]; then
        die "请使用 root 运行：sudo bash $SCRIPT_PATH"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

prompt() {
    local message="$1" default_value="${2:-}" value
    if [[ -n "$default_value" ]]; then
        read -r -p "$message [$default_value]: " value
        printf '%s' "${value:-$default_value}"
    else
        read -r -p "$message: " value
        printf '%s' "$value"
    fi
}

confirm() {
    local message="$1" default_answer="${2:-N}" answer suffix
    if [[ "$default_answer" == Y ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi
    read -r -p "$message $suffix: " answer
    answer="${answer:-$default_answer}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause() {
    [[ -t 0 ]] || return 0
    read -r -p "按 Enter 返回..." _
}

stat_mode() {
    stat -c '%a' "$1"
}

stat_owner() {
    stat -c '%u' "$1"
}

state_file_trusted() {
    local file="$1" mode
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "${SUBSTORE_MANAGER_SKIP_STATE_SECURITY:-0}" == 1 ]] && return 0
    [[ "$(stat_owner "$file")" == 0 ]] || return 1
    mode="$(stat_mode "$file")"
    [[ "$mode" == 600 || "$mode" == 400 ]]
}

node_command() {
    if [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]]; then
        printf '%s' "$NODE_BIN"
    else
        command -v node
    fi
}

register_tmp() {
    TMP_PATHS+=("$1")
}

cleanup_tmp_path() {
    local target="$1"
    if [[ -n "$target" && -e "$target" ]]; then
        if ! rm -rf -- "$target"; then
            log_warn "临时路径清理失败：$target"
            return 1
        fi
    fi
    unregister_tmp_path "$target"
    return 0
}

unregister_tmp_path() {
    local target="$1" index
    for index in "${!TMP_PATHS[@]}"; do
        if [[ "${TMP_PATHS[$index]}" == "$target" ]]; then
            unset 'TMP_PATHS[index]'
        fi
    done
}

make_temp_dir() {
    local output_var="$1" parent="$2" template="$3" result
    mkdir -p -- "$parent" || return 1
    result="$(mktemp -d "${parent}/${template}.XXXXXX")" || return 1
    register_tmp "$result"
    printf -v "$output_var" '%s' "$result"
}

validate_absolute_path() {
    local value="$1"
    [[ "$value" == /* && "$value" != / && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

normalize_path() {
    realpath -m -- "$1"
}

path_contains() {
    local parent child
    parent="$(normalize_path "$1")"
    child="$(normalize_path "$2")"
    [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

validate_managed_layout() {
    local backups_dir
    backups_dir="${DEPLOY_DIR}/backups"
    [[ "$DEPLOY_DIR" != "$DATA_DIR" ]] || {
        log_error "数据目录不能与部署目录相同"
        return 1
    }
    [[ "$DEPLOY_DIR" != "$FRONTEND_DIR" ]] || {
        log_error "前端目录不能与部署目录相同"
        return 1
    }
    if path_contains "$DATA_DIR" "$DEPLOY_DIR"; then
        log_error "数据目录不能是部署目录的上级目录：$DATA_DIR"
        return 1
    fi
    if path_contains "$FRONTEND_DIR" "$DEPLOY_DIR"; then
        log_error "前端目录不能是部署目录的上级目录：$FRONTEND_DIR"
        return 1
    fi
    if path_contains "$DATA_DIR" "$FRONTEND_DIR" || path_contains "$FRONTEND_DIR" "$DATA_DIR"; then
        log_error "数据目录与前端目录不能互相包含"
        return 1
    fi
    if path_contains "$backups_dir" "$DATA_DIR" || path_contains "$DATA_DIR" "$backups_dir"; then
        log_error "数据目录不能与更新备份目录重叠：$backups_dir"
        return 1
    fi
    if path_contains "$backups_dir" "$FRONTEND_DIR" || path_contains "$FRONTEND_DIR" "$backups_dir"; then
        log_error "前端目录不能与更新备份目录重叠：$backups_dir"
        return 1
    fi
    case "$DATA_DIR" in
        "${DEPLOY_DIR}/.substore-"*) log_error "数据目录不能使用管理器临时目录前缀"; return 1 ;;
    esac
    case "$FRONTEND_DIR" in
        "${DEPLOY_DIR}/.substore-"*) log_error "前端目录不能使用管理器临时目录前缀"; return 1 ;;
    esac
}

managed_top_level_path() {
    local root child relative top
    root="$(normalize_path "$1")"
    child="$(normalize_path "$2")"
    path_contains "$root" "$child" || return 1
    [[ "$child" != "$root" ]] || return 1
    relative="${child#"$root"/}"
    top="${relative%%/*}"
    printf '%s/%s' "$root" "$top"
}

deploy_dir_reusable() {
    local entry allowed_data="" allowed_frontend=""
    [[ ! -e "$DEPLOY_DIR" ]] && return 0
    [[ -d "$DEPLOY_DIR" ]] || return 1
    allowed_data="$(managed_top_level_path "$DEPLOY_DIR" "$DATA_DIR" 2>/dev/null || true)"
    allowed_frontend="$(managed_top_level_path "$DEPLOY_DIR" "$FRONTEND_DIR" 2>/dev/null || true)"
    while IFS= read -r -d '' entry; do
        [[ "$entry" == "$allowed_data" || "$entry" == "$allowed_frontend" ]] || return 1
    done < <(find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print0)
}

managed_state_files() {
    [[ -f "${STATE_BASE}/instance.conf" ]] && printf '%s\n' "${STATE_BASE}/instance.conf"
    find "${STATE_BASE}/instances" -mindepth 2 -maxdepth 2 -name instance.conf -type f -print 2>/dev/null || true
}

managed_path_conflicts_elsewhere() {
    local candidate state_path existing
    candidate="$(normalize_path "$1")"
    while IFS= read -r state_path; do
        [[ -n "$state_path" && "$state_path" != "$STATE_FILE" ]] || continue
        state_file_trusted "$state_path" || {
            log_error "发现不可信的实例状态文件：$state_path"
            return 2
        }
        while IFS= read -r existing; do
            [[ -n "$existing" ]] || continue
            existing="$(normalize_path "$existing")"
            if path_contains "$candidate" "$existing" || path_contains "$existing" "$candidate"; then
                log_error "路径与其他管理实例冲突：$candidate <-> $existing"
                return 0
            fi
        done < <(bash -c '
set -u
source "$1"
printf "%s\n%s\n%s\n" "${DEPLOY_DIR:-}" "${DATA_DIR:-}" "${FRONTEND_DIR:-}"
' _ "$state_path")
    done < <(managed_state_files)
    return 1
}

assert_paths_not_managed_elsewhere() {
    local path result
    for path in "$DEPLOY_DIR" "$DATA_DIR" "$FRONTEND_DIR"; do
        if managed_path_conflicts_elsewhere "$path"; then
            return 1
        else
            result=$?
            (( result == 1 )) || return "$result"
        fi
    done
}

assert_identity_not_managed_elsewhere() {
    local state_path values other_pm2 other_port
    while IFS= read -r state_path; do
        [[ -n "$state_path" && "$state_path" != "$STATE_FILE" ]] || continue
        state_file_trusted "$state_path" || die "发现不可信的实例状态文件：$state_path"
        values="$(bash -c '
set -u
source "$1"
printf "%s\n%s\n" "${PM2_NAME:-}" "${PORT:-}"
' _ "$state_path")"
        other_pm2="${values%%$'\n'*}"
        other_port="${values#*$'\n'}"
        [[ "$PM2_NAME" != "$other_pm2" ]] || die "PM2 名称已被其他管理实例使用：$PM2_NAME"
        [[ "$PORT" != "$other_port" ]] || die "监听端口已被其他管理实例记录：$PORT"
    done < <(managed_state_files)
}

frontend_marker_path() {
    printf '%s' "${FRONTEND_DIR}/.substore-manager-frontend"
}

manager_marker_matches() {
    local marker="$1"
    [[ -f "$marker" && ! -L "$marker" ]] && grep -Fxq "$INSTALL_ID" "$marker"
}

write_frontend_marker() {
    write_manager_marker "$(frontend_marker_path)"
}

write_manager_marker() {
    local marker="$1" temp
    mkdir -p -- "$(dirname -- "$marker")" || return 1
    if [[ -e "$marker" || -L "$marker" ]]; then
        if ! manager_marker_matches "$marker"; then
            log_error "管理标记已存在且不属于当前实例：$marker"
            return 1
        fi
    fi
    temp="$(mktemp "${marker}.tmp.XXXXXX")" || return 1
    register_tmp "$temp"
    printf '%s\n' "$INSTALL_ID" >"$temp" || { cleanup_tmp_path "$temp"; return 1; }
    chmod 600 "$temp" || { cleanup_tmp_path "$temp"; return 1; }
    mv -Tf -- "$temp" "$marker" || { cleanup_tmp_path "$temp"; return 1; }
    unregister_tmp_path "$temp"
}

assert_frontend_managed() {
    local marker
    marker="$(frontend_marker_path)"
    if ! manager_marker_matches "$marker"; then
        log_error "前端目录缺少匹配的管理标记，拒绝覆盖：$FRONTEND_DIR"
        return 1
    fi
}

init_env_catalog() {
    OFFICIAL_ENV_ORDER=(
        SUB_STORE_BACKEND_API_PORT
        SUB_STORE_BACKEND_API_HOST
        SUB_STORE_DATA_BASE_PATH
        SUB_STORE_FRONTEND_PATH
        SUB_STORE_BACKEND_MERGE
        SUB_STORE_BACKEND_PREFIX
        SUB_STORE_FRONTEND_BACKEND_PATH
        SUB_STORE_FRONTEND_PORT
        SUB_STORE_FRONTEND_HOST
        SUB_STORE_MAX_HEADER_SIZE
        SUB_STORE_BODY_JSON_LIMIT
        SUB_STORE_CORS_ALLOWED_ORIGINS
        SUB_STORE_BACKEND_DEFAULT_PROXY
        SUB_STORE_PUSH_SERVICE
        SUB_STORE_BACKEND_SYNC_CRON
        SUB_STORE_BACKEND_DOWNLOAD_CRON
        SUB_STORE_BACKEND_UPLOAD_CRON
        SUB_STORE_PRODUCE_CRON
        SUB_STORE_MMDB_COUNTRY_PATH
        SUB_STORE_MMDB_COUNTRY_URL
        SUB_STORE_MMDB_ASN_PATH
        SUB_STORE_MMDB_ASN_URL
        SUB_STORE_MMDB_CRON
        SUB_STORE_DATA_URL
        SUB_STORE_DATA_URL_POST
        SUB_STORE_BACKEND_CUSTOM_NAME
        SUB_STORE_BACKEND_CUSTOM_ICON
        SUB_STORE_X_POWERED_BY
    )

    ENV_DESC[SUB_STORE_BACKEND_API_PORT]="Node 后端监听端口"
    ENV_DESC[SUB_STORE_BACKEND_API_HOST]="Node 后端监听地址"
    ENV_DESC[SUB_STORE_DATA_BASE_PATH]="root.json、sub-store.json 等持久化数据目录"
    ENV_DESC[SUB_STORE_FRONTEND_PATH]="前端 dist 内容所在目录"
    ENV_DESC[SUB_STORE_BACKEND_MERGE]="让后端端口同时提供 API 与前端静态资源；启用时只设置 true"
    ENV_DESC[SUB_STORE_BACKEND_PREFIX]="让裸后端路由也使用 FRONTEND_BACKEND_PATH 前缀；启用时只设置 true"
    ENV_DESC[SUB_STORE_FRONTEND_BACKEND_PATH]="前端访问后端使用的路径前缀，必须以 / 开头"
    ENV_DESC[SUB_STORE_FRONTEND_PORT]="非合并模式的独立前端监听端口"
    ENV_DESC[SUB_STORE_FRONTEND_HOST]="非合并模式的独立前端监听地址"
    ENV_DESC[SUB_STORE_MAX_HEADER_SIZE]="undici 响应头大小上限，单位字节"
    ENV_DESC[SUB_STORE_BODY_JSON_LIMIT]="JSON 请求体大小上限，例如 1mb、10mb"
    ENV_DESC[SUB_STORE_CORS_ALLOWED_ORIGINS]="Node 后端 CORS allowlist，多个 Origin 用逗号分隔"
    ENV_DESC[SUB_STORE_BACKEND_DEFAULT_PROXY]="后端默认 SOCKS5、HTTP 或 HTTPS 代理"
    ENV_DESC[SUB_STORE_PUSH_SERVICE]="推送服务 URL，支持占位符 [推送标题] 与 [推送内容]"
    ENV_DESC[SUB_STORE_BACKEND_SYNC_CRON]="定时同步订阅/文件的五段 cron 表达式"
    ENV_DESC[SUB_STORE_BACKEND_DOWNLOAD_CRON]="定时从 Gist 恢复全部配置"
    ENV_DESC[SUB_STORE_BACKEND_UPLOAD_CRON]="定时向 Gist 备份全部配置"
    ENV_DESC[SUB_STORE_PRODUCE_CRON]="定时处理订阅，格式 cron,sub|col,名称；多个任务用分号连接"
    ENV_DESC[SUB_STORE_MMDB_COUNTRY_PATH]="GeoLite2 Country MMDB 本地路径"
    ENV_DESC[SUB_STORE_MMDB_COUNTRY_URL]="GeoLite2 Country MMDB 下载地址"
    ENV_DESC[SUB_STORE_MMDB_ASN_PATH]="GeoLite2 ASN MMDB 本地路径"
    ENV_DESC[SUB_STORE_MMDB_ASN_URL]="GeoLite2 ASN MMDB 下载地址"
    ENV_DESC[SUB_STORE_MMDB_CRON]="定时更新 MMDB 的五段 cron 表达式"
    ENV_DESC[SUB_STORE_DATA_URL]="启动时下载并恢复远程数据的 URL"
    ENV_DESC[SUB_STORE_DATA_URL_POST]="远程数据下载后的 JavaScript 修改表达式"
    ENV_DESC[SUB_STORE_BACKEND_CUSTOM_NAME]="前端显示的自定义后端名称"
    ENV_DESC[SUB_STORE_BACKEND_CUSTOM_ICON]="前端显示的自定义后端图标 URL"
    ENV_DESC[SUB_STORE_X_POWERED_BY]="响应头 X-Powered-By 的值"

    ENV_DEFAULT[SUB_STORE_BACKEND_API_PORT]="3000"
    ENV_DEFAULT[SUB_STORE_BACKEND_API_HOST]="::"
    ENV_DEFAULT[SUB_STORE_DATA_BASE_PATH]="."
    ENV_DEFAULT[SUB_STORE_FRONTEND_PATH]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_BACKEND_MERGE]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_BACKEND_PREFIX]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_FRONTEND_BACKEND_PATH]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_FRONTEND_PORT]="3001"
    ENV_DEFAULT[SUB_STORE_FRONTEND_HOST]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_MAX_HEADER_SIZE]="32768"
    ENV_DEFAULT[SUB_STORE_BODY_JSON_LIMIT]="1mb"
    ENV_DEFAULT[SUB_STORE_CORS_ALLOWED_ORIGINS]="*"
    ENV_DEFAULT[SUB_STORE_BACKEND_DEFAULT_PROXY]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_PUSH_SERVICE]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_BACKEND_SYNC_CRON]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_BACKEND_DOWNLOAD_CRON]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_BACKEND_UPLOAD_CRON]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_PRODUCE_CRON]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_MMDB_COUNTRY_PATH]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_MMDB_COUNTRY_URL]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_MMDB_ASN_PATH]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_MMDB_ASN_URL]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_MMDB_CRON]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_DATA_URL]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_DATA_URL_POST]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_BACKEND_CUSTOM_NAME]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_BACKEND_CUSTOM_ICON]="__UNSET__"
    ENV_DEFAULT[SUB_STORE_X_POWERED_BY]="Sub-Store"

    ENV_DEFAULT_LABEL[SUB_STORE_FRONTEND_HOST]="继承 SUB_STORE_BACKEND_API_HOST，否则 ::"
    ENV_DEFAULT_LABEL[SUB_STORE_FRONTEND_PATH]="未设置"
    ENV_DEFAULT_LABEL[SUB_STORE_BACKEND_MERGE]="未设置"
    ENV_DEFAULT_LABEL[SUB_STORE_BACKEND_PREFIX]="未设置"
    ENV_DEFAULT_LABEL[SUB_STORE_FRONTEND_BACKEND_PATH]="未设置"

    ENV_TYPE[SUB_STORE_BACKEND_API_PORT]="port"
    ENV_TYPE[SUB_STORE_BACKEND_API_HOST]="host"
    ENV_TYPE[SUB_STORE_DATA_BASE_PATH]="abs_path"
    ENV_TYPE[SUB_STORE_FRONTEND_PATH]="abs_path"
    ENV_TYPE[SUB_STORE_BACKEND_MERGE]="truthy"
    ENV_TYPE[SUB_STORE_BACKEND_PREFIX]="truthy"
    ENV_TYPE[SUB_STORE_FRONTEND_BACKEND_PATH]="prefix"
    ENV_TYPE[SUB_STORE_FRONTEND_PORT]="port"
    ENV_TYPE[SUB_STORE_FRONTEND_HOST]="host"
    ENV_TYPE[SUB_STORE_MAX_HEADER_SIZE]="positive_int"
    ENV_TYPE[SUB_STORE_BODY_JSON_LIMIT]="body_limit"
    ENV_TYPE[SUB_STORE_CORS_ALLOWED_ORIGINS]="cors"
    ENV_TYPE[SUB_STORE_BACKEND_DEFAULT_PROXY]="proxy"
    ENV_TYPE[SUB_STORE_PUSH_SERVICE]="text"
    ENV_TYPE[SUB_STORE_BACKEND_SYNC_CRON]="cron"
    ENV_TYPE[SUB_STORE_BACKEND_DOWNLOAD_CRON]="cron"
    ENV_TYPE[SUB_STORE_BACKEND_UPLOAD_CRON]="cron"
    ENV_TYPE[SUB_STORE_PRODUCE_CRON]="produce_cron"
    ENV_TYPE[SUB_STORE_MMDB_COUNTRY_PATH]="abs_path"
    ENV_TYPE[SUB_STORE_MMDB_COUNTRY_URL]="url"
    ENV_TYPE[SUB_STORE_MMDB_ASN_PATH]="abs_path"
    ENV_TYPE[SUB_STORE_MMDB_ASN_URL]="url"
    ENV_TYPE[SUB_STORE_MMDB_CRON]="cron"
    ENV_TYPE[SUB_STORE_DATA_URL]="url"
    ENV_TYPE[SUB_STORE_DATA_URL_POST]="text"
    ENV_TYPE[SUB_STORE_BACKEND_CUSTOM_NAME]="text"
    ENV_TYPE[SUB_STORE_BACKEND_CUSTOM_ICON]="url"
    ENV_TYPE[SUB_STORE_X_POWERED_BY]="text"

    ENV_SENSITIVE[SUB_STORE_PUSH_SERVICE]=1
    ENV_SENSITIVE[SUB_STORE_DATA_URL]=1
    ENV_SENSITIVE[SUB_STORE_DATA_URL_POST]=1
    ENV_SENSITIVE[SUB_STORE_FRONTEND_BACKEND_PATH]=1
}

official_env_default_label() {
    local key="$1" value
    value="${ENV_DEFAULT[$key]:-__UNSET__}"
    if [[ -n "${ENV_DEFAULT_LABEL[$key]:-}" ]]; then
        printf '%s' "${ENV_DEFAULT_LABEL[$key]}"
    elif [[ "$value" == __UNSET__ ]]; then
        printf '%s' "未设置"
    else
        printf '%s' "$value"
    fi
}

validate_env_value() {
    local key="$1" value="$2" type item cron_part kind name
    type="${ENV_TYPE[$key]:-text}"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1

    case "$type" in
        port)
            [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
            ;;
        host)
            [[ -n "$value" && "$value" != *[[:space:]/]* ]]
            ;;
        abs_path)
            validate_absolute_path "$value"
            ;;
        truthy)
            [[ "$value" == true ]]
            ;;
        prefix)
            [[ "$value" == /* ]]
            ;;
        positive_int)
            [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 ))
            ;;
        body_limit)
            [[ "$value" =~ ^[0-9]+([kKmMgG]?[bB])?$ ]]
            ;;
        cors)
            [[ "$value" == "*" ]] && return 0
            IFS=',' read -r -a origins <<<"$value"
            ((${#origins[@]} > 0)) || return 1
            for item in "${origins[@]}"; do
                item="${item#"${item%%[![:space:]]*}"}"
                item="${item%"${item##*[![:space:]]}"}"
                [[ "$item" =~ ^https?://[^/[:space:]]+(:[0-9]+)?$ ]] || return 1
            done
            ;;
        proxy)
            [[ "$value" =~ ^(socks5|http|https)://[^[:space:]]+$ ]]
            ;;
        cron)
            [[ "$(awk '{print NF}' <<<"$value")" == 5 ]]
            ;;
        produce_cron)
            IFS=';' read -r -a jobs <<<"$value"
            ((${#jobs[@]} > 0)) || return 1
            for item in "${jobs[@]}"; do
                name="${item##*,}"
                item="${item%,*}"
                kind="${item##*,}"
                cron_part="${item%,*}"
                [[ "$kind" == sub || "$kind" == col ]] || return 1
                [[ -n "$name" && "$(awk '{print NF}' <<<"$cron_part")" == 5 ]] || return 1
            done
            ;;
        url)
            [[ "$value" =~ ^https?://[^[:space:]]+$ ]]
            ;;
        text)
            [[ -n "$value" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

mask_value() {
    local value="$1" length
    length=${#value}
    if (( length <= 8 )); then
        printf '%s' '********'
    else
        printf '%s***%s' "${value:0:4}" "${value: -4}"
    fi
}

env_get() {
    local file="$1" key="$2" node_bin
    [[ -f "$file" ]] || return 1
    node_bin="$(node_command)"
    "$node_bin" - "$file" "$key" <<'NODE'
const fs = require('fs');
const [file, key] = process.argv.slice(2);
const source = fs.readFileSync(file, 'utf8').split(/\r?\n/);
for (let i = source.length - 1; i >= 0; i -= 1) {
  const match = source[i].match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!match || match[1] !== key) continue;
  let value = match[2].trim();
  if (value.startsWith('"') && value.endsWith('"')) {
    try { value = JSON.parse(value); } catch {}
  } else if (value.startsWith("'") && value.endsWith("'")) {
    value = value.slice(1, -1);
  } else {
    value = value.replace(/\s+#.*$/, '').trim();
  }
  process.stdout.write(value);
  process.exit(0);
}
process.exit(1);
NODE
}

env_set() {
    local file="$1" key="$2" value="$3" node_bin
    mkdir -p -- "$(dirname -- "$file")" || return 1
    touch "$file" || return 1
    chmod 600 "$file" || return 1
    node_bin="$(node_command)"
    "$node_bin" - "$file" "$key" "$value" <<'NODE'
const fs = require('fs');
const [file, key, value] = process.argv.slice(2);
const newline = `${key}=${JSON.stringify(value)}`;
const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
let replaced = false;
const next = [];
for (const line of lines) {
  const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/);
  if (match?.[1] === key) {
    if (!replaced) next.push(newline);
    replaced = true;
  } else {
    next.push(line);
  }
}
while (next.length && next[next.length - 1] === '') next.pop();
if (!replaced) next.push(newline);
const temp = `${file}.tmp.${process.pid}`;
try {
  fs.writeFileSync(temp, `${next.join('\n')}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
  fs.chmodSync(file, 0o600);
} finally {
  try { fs.unlinkSync(temp); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}
NODE
}

env_delete() {
    local file="$1" key="$2" node_bin
    [[ -f "$file" ]] || return 0
    node_bin="$(node_command)"
    "$node_bin" - "$file" "$key" <<'NODE'
const fs = require('fs');
const [file, key] = process.argv.slice(2);
const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
const next = lines.filter(line => {
  const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/);
  return match?.[1] !== key;
});
while (next.length && next[next.length - 1] === '') next.pop();
const temp = `${file}.tmp.${process.pid}`;
try {
  fs.writeFileSync(temp, `${next.join('\n')}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
  fs.chmodSync(file, 0o600);
} finally {
  try { fs.unlinkSync(temp); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}
NODE
}

env_list() {
    local file="$1" node_bin
    [[ -f "$file" ]] || return 0
    node_bin="$(node_command)"
    "$node_bin" - "$file" <<'NODE'
const fs = require('fs');
const [file] = process.argv.slice(2);
for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
  const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!match) continue;
  let value = match[2].trim();
  if (value.startsWith('"') && value.endsWith('"')) {
    try { value = JSON.parse(value); } catch {}
  } else if (value.startsWith("'") && value.endsWith("'")) {
    value = value.slice(1, -1);
  } else {
    value = value.replace(/\s+#.*$/, '').trim();
  }
  process.stdout.write(`${match[1]}\t${value.replace(/[\t\r\n]/g, ' ')}\n`);
}
NODE
}

save_state() {
    local temp state_fd index
    local -a entries=(
        STATE_VERSION 2
        INSTANCE_ID "$INSTANCE_ID"
        CREATED_BY_MANAGER "$CREATED_BY_MANAGER"
        DATA_CREATED_BY_MANAGER "$DATA_CREATED_BY_MANAGER"
        FRONTEND_CREATED_BY_MANAGER "$FRONTEND_CREATED_BY_MANAGER"
        INSTALL_ID "$INSTALL_ID"
        DEPLOY_DIR "$DEPLOY_DIR"
        BACKEND_FILE "$BACKEND_FILE"
        FRONTEND_DIR "$FRONTEND_DIR"
        DATA_DIR "$DATA_DIR"
        ENV_FILE "$ENV_FILE"
        ECOSYSTEM_FILE "$ECOSYSTEM_FILE"
        MARKER_FILE "$MARKER_FILE"
        PM2_NAME "$PM2_NAME"
        PORT "$PORT"
        HOST "$HOST"
        BACKEND_VERSION "$BACKEND_VERSION"
        FRONTEND_VERSION "$FRONTEND_VERSION"
        NODE_BIN "$NODE_BIN"
        INSTALLED_AT "$INSTALLED_AT"
        AUTO_UPDATE_ENABLED "$AUTO_UPDATE_ENABLED"
        AUTO_UPDATE_INTERVAL_MINUTES "$AUTO_UPDATE_INTERVAL_MINUTES"
        BACKUP_RETENTION_COUNT "$BACKUP_RETENTION_COUNT"
    )
    mkdir -p -- "$STATE_ROOT"
    chmod 700 "$STATE_ROOT"
    temp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
    register_tmp "$temp"
    exec {state_fd}>"$temp" || { cleanup_tmp_path "$temp"; return 1; }
    for ((index = 0; index < ${#entries[@]}; index += 2)); do
        if ! printf '%s=%q\n' "${entries[$index]}" "${entries[$((index + 1))]}" >&"$state_fd"; then
            exec {state_fd}>&-
            cleanup_tmp_path "$temp"
            return 1
        fi
    done
    exec {state_fd}>&- || { cleanup_tmp_path "$temp"; return 1; }
    chmod 600 "$temp" || { cleanup_tmp_path "$temp"; return 1; }
    mv -f -- "$temp" "$STATE_FILE" || { cleanup_tmp_path "$temp"; return 1; }
    unregister_tmp_path "$temp"
}

load_state() {
    local requested_instance="$INSTANCE_ID"
    INSTALL_PRESENT=0
    [[ -f "$STATE_FILE" ]] || return 1
    state_file_trusted "$STATE_FILE" || die "状态文件必须由 root 所有且权限为 600 或 400：$STATE_FILE"
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    [[ "$INSTANCE_ID" == "$requested_instance" ]] || die "状态文件实例名称不匹配：$STATE_FILE"
    DATA_CREATED_BY_MANAGER="${DATA_CREATED_BY_MANAGER:-0}"
    FRONTEND_CREATED_BY_MANAGER="${FRONTEND_CREATED_BY_MANAGER:-0}"
    AUTO_UPDATE_ENABLED="${AUTO_UPDATE_ENABLED:-0}"
    AUTO_UPDATE_INTERVAL_MINUTES="${AUTO_UPDATE_INTERVAL_MINUTES:-60}"
    BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-10}"
    [[ "$BACKUP_RETENTION_COUNT" =~ ^[0-9]+$ && "$BACKUP_RETENTION_COUNT" -ge 1 && \
        "$BACKUP_RETENTION_COUNT" -le 100 ]] || die "备份保留数量无效：$BACKUP_RETENTION_COUNT"
    [[ -n "$INSTALL_ID" && -n "$DEPLOY_DIR" && -n "$PM2_NAME" ]] || die "状态文件不完整：$STATE_FILE"
    [[ -f "$MARKER_FILE" && ! -L "$MARKER_FILE" ]] || die "实例标记不存在或不安全：$MARKER_FILE"
    grep -Fxq "$INSTALL_ID" "$MARKER_FILE" || die "实例标记与状态文件不匹配"
    INSTALL_PRESENT=1
    return 0
}

validate_instance_files() {
    [[ -f "$BACKEND_FILE" && ! -L "$BACKEND_FILE" ]] || { log_error "后端文件不存在或不安全：$BACKEND_FILE"; return 1; }
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || { log_error "Env 文件不存在或不安全：$ENV_FILE"; return 1; }
    [[ -f "$ECOSYSTEM_FILE" && ! -L "$ECOSYSTEM_FILE" ]] || { log_error "PM2 配置不存在或不安全：$ECOSYSTEM_FILE"; return 1; }
    [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] || { log_error "数据目录不存在或不安全：$DATA_DIR"; return 1; }
    [[ -d "$FRONTEND_DIR" && ! -L "$FRONTEND_DIR" ]] || { log_error "前端目录不存在或不安全：$FRONTEND_DIR"; return 1; }
    [[ -f "$FRONTEND_DIR/index.html" ]] || { log_error "前端入口不存在：$FRONTEND_DIR/index.html"; return 1; }
    if ! manager_marker_matches "${DATA_DIR}/.substore-manager-data"; then
        log_error "数据目录管理标记缺失或不匹配：$DATA_DIR"
        return 1
    fi
    assert_frontend_managed
}

random_hex() {
    local bytes="${1:-16}"
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

detect_os() {
    [[ -r /etc/os-release ]] || die "仅支持 Debian / Ubuntu"
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        debian:*|ubuntu:*|*:debian*|*:ubuntu*) ;;
        *) die "当前系统不是受支持的 Debian / Ubuntu：${PRETTY_NAME:-unknown}" ;;
    esac
    local arch
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64|arm64) ;;
        *) die "仅支持 amd64 / arm64，当前架构：$arch" ;;
    esac
}

ensure_base_packages() {
    local command_name missing=0
    if [[ "${SUBSTORE_MANAGER_SKIP_PACKAGES:-0}" == 1 ]]; then
        return 0
    fi
    for command_name in curl unzip tar ss sha256sum flock realpath; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done
    (( missing == 1 )) || return 0
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl unzip tar iproute2 util-linux coreutils
}

curl_public_args() {
    local max_time="${1:-300}"
    CURL_ARGS=(
        --fail
        --silent
        --show-error
        --location
        --retry 3
        --retry-delay 2
        --connect-timeout 10
        --max-time "$max_time"
        --header "User-Agent: substore-manager/${MANAGER_VERSION}"
    )
    if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
        CURL_ARGS+=(--retry-all-errors)
    fi
}

curl_args() {
    local max_time="${1:-300}"
    curl_public_args "$max_time"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        CURL_ARGS+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
}

http_download() {
    local url="$1" output="$2"
    curl_public_args 300
    curl "${CURL_ARGS[@]}" --output "$output" "$url"
}

official_node_version() {
    local value
    curl_public_args 60
    value="$(curl "${CURL_ARGS[@]}" "https://raw.githubusercontent.com/${BACKEND_REPO}/master/.node-version")"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法读取官方 .node-version"
    printf '%s' "$value"
}

ensure_node() {
    local official_version node_major setup_script
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        NODE_BIN="$(command -v node)"
        log_info "复用现有 Node.js $(node -v)"
        return 0
    fi

    [[ "${SUBSTORE_MANAGER_SKIP_NODE_INSTALL:-0}" != 1 ]] || die "测试模式禁止安装 Node.js"
    official_version="$(official_node_version)"
    node_major="${official_version%%.*}"
    setup_script="$(mktemp)"
    register_tmp "$setup_script"
    curl_public_args
    curl "${CURL_ARGS[@]}" "https://deb.nodesource.com/setup_${node_major}.x" -o "$setup_script"
    bash -n "$setup_script" || die "NodeSource setup_${node_major}.x 语法检查失败"
    log_info "执行 NodeSource setup_${node_major}.x 一键配置脚本"
    bash "$setup_script"
    apt-get install -y nodejs
    hash -r
    command -v node >/dev/null 2>&1 || die "NodeSource 安装完成后仍找不到 node"
    command -v npm >/dev/null 2>&1 || die "NodeSource 安装完成后仍找不到 npm"
    NODE_BIN="$(command -v node)"
    cleanup_tmp_path "$setup_script"
    log_info "已安装 Node.js $(node -v)"
}

ensure_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        npm install -g pm2@latest
        hash -r
    fi
    require_command pm2
    log_info "PM2 $(pm2 -v | tail -n 1) 可用"
}

configure_pm2_startup() {
    if [[ "${SUBSTORE_MANAGER_SKIP_PM2_STARTUP:-0}" == 1 ]]; then
        log_warn "测试模式：跳过 PM2 开机启动配置"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled pm2-root.service >/dev/null 2>&1; then
        log_info "PM2 开机启动已启用"
        return 0
    fi
    if ! pm2 startup systemd -u root --hp /root >/dev/null; then
        log_error "PM2 开机启动配置失败"
        return 1
    fi
    log_info "已配置 PM2 systemd 开机启动"
}

validate_auto_update_interval() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 15 && value <= 10080 ))
}

write_auto_update_units() {
    local service_file timer_file service_tmp timer_tmp update_command existing_file
    validate_auto_update_interval "$AUTO_UPDATE_INTERVAL_MINUTES" || \
        die "自动更新间隔必须是 15 到 10080 分钟"
    [[ "$MANAGER_INSTALL_PATH" != *$'\n'* && "$MANAGER_INSTALL_PATH" != *[[:space:]]* ]] || \
        die "自动更新要求管理器安装路径不包含空白字符"
    if [[ -e "$MANAGER_GITHUB_ENV_FILE" || -L "$MANAGER_GITHUB_ENV_FILE" ]]; then
        state_file_trusted "$MANAGER_GITHUB_ENV_FILE" || \
            die "GitHub Token 环境文件必须由 root 所有且权限为 600 或 400：$MANAGER_GITHUB_ENV_FILE"
    fi

    mkdir -p -- "$SYSTEMD_DIR"
    service_file="${SYSTEMD_DIR}/${AUTO_UPDATE_SERVICE_NAME}"
    timer_file="${SYSTEMD_DIR}/${AUTO_UPDATE_TIMER_NAME}"
    for existing_file in "$service_file" "$timer_file"; do
        if [[ -e "$existing_file" || -L "$existing_file" ]]; then
            [[ -f "$existing_file" && ! -L "$existing_file" ]] || {
                log_error "自动更新 unit 路径不是安全的普通文件：$existing_file"
                return 1
            }
        fi
    done
    service_tmp="$(mktemp "${service_file}.tmp.XXXXXX")" || return 1
    register_tmp "$service_tmp"
    timer_tmp="$(mktemp "${timer_file}.tmp.XXXXXX")" || {
        cleanup_tmp_path "$service_tmp"
        return 1
    }
    register_tmp "$timer_tmp"
    if [[ "$INSTANCE_ID" == default ]]; then
        update_command="${MANAGER_INSTALL_PATH} update"
    else
        update_command="${MANAGER_INSTALL_PATH} --instance ${INSTANCE_ID} update"
    fi

    {
        printf '%s\n' \
            '[Unit]' \
            "Description=Check and update Sub-Store instance ${INSTANCE_ID}" \
            'Wants=network-online.target' \
            'After=network-online.target' \
            '' \
            '[Service]' \
            'Type=oneshot' \
            'Environment="HOME=/root"' \
            'Environment="PM2_HOME=/root/.pm2"' \
            'Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
            "EnvironmentFile=-${MANAGER_GITHUB_ENV_FILE}" \
            "ExecStart=${update_command}" \
            'Nice=10' \
            'TimeoutStartSec=30min'
    } >"$service_tmp" || {
        cleanup_tmp_path "$service_tmp"
        cleanup_tmp_path "$timer_tmp"
        return 1
    }

    {
        printf '%s\n' \
            '[Unit]' \
            "Description=Periodic Sub-Store update check for ${INSTANCE_ID}" \
            '' \
            '[Timer]' \
            'OnBootSec=10min' \
            "OnUnitActiveSec=${AUTO_UPDATE_INTERVAL_MINUTES}min" \
            'RandomizedDelaySec=5min' \
            'AccuracySec=1min' \
            "Unit=${AUTO_UPDATE_SERVICE_NAME}" \
            '' \
            '[Install]' \
            'WantedBy=timers.target'
    } >"$timer_tmp" || {
        cleanup_tmp_path "$service_tmp"
        cleanup_tmp_path "$timer_tmp"
        return 1
    }
    chmod 644 "$service_tmp" "$timer_tmp" || {
        cleanup_tmp_path "$service_tmp"
        cleanup_tmp_path "$timer_tmp"
        return 1
    }
    mv -Tf -- "$service_tmp" "$service_file" || {
        cleanup_tmp_path "$service_tmp"
        cleanup_tmp_path "$timer_tmp"
        return 1
    }
    unregister_tmp_path "$service_tmp"
    mv -Tf -- "$timer_tmp" "$timer_file" || { cleanup_tmp_path "$timer_tmp"; return 1; }
    unregister_tmp_path "$timer_tmp"
}

begin_auto_update_transaction() {
    local service_file="${SYSTEMD_DIR}/${AUTO_UPDATE_SERVICE_NAME}"
    local timer_file="${SYSTEMD_DIR}/${AUTO_UPDATE_TIMER_NAME}"
    acquire_update_lock_wait || return 1
    load_state || { release_update_lock; return 1; }
    AUTO_UPDATE_SERVICE_EXISTED=0
    AUTO_UPDATE_TIMER_EXISTED=0
    AUTO_UPDATE_WAS_ENABLED=0
    AUTO_UPDATE_WAS_ACTIVE=0
    make_temp_dir AUTO_UPDATE_TRANSACTION_DIR "${TMPDIR:-/tmp}" .substore-auto-update || {
        release_update_lock
        return 1
    }
    if [[ -e "$service_file" || -L "$service_file" ]]; then
        [[ -f "$service_file" && ! -L "$service_file" ]] || {
            cleanup_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
            AUTO_UPDATE_TRANSACTION_DIR=""
            release_update_lock
            return 1
        }
        cp -a "$service_file" "$AUTO_UPDATE_TRANSACTION_DIR/service" || {
            cleanup_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
            AUTO_UPDATE_TRANSACTION_DIR=""
            release_update_lock
            return 1
        }
        AUTO_UPDATE_SERVICE_EXISTED=1
    fi
    if [[ -e "$timer_file" || -L "$timer_file" ]]; then
        [[ -f "$timer_file" && ! -L "$timer_file" ]] || {
            cleanup_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
            AUTO_UPDATE_TRANSACTION_DIR=""
            release_update_lock
            return 1
        }
        cp -a "$timer_file" "$AUTO_UPDATE_TRANSACTION_DIR/timer" || {
            cleanup_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
            AUTO_UPDATE_TRANSACTION_DIR=""
            release_update_lock
            return 1
        }
        AUTO_UPDATE_TIMER_EXISTED=1
    fi
    cp -a "$STATE_FILE" "$AUTO_UPDATE_TRANSACTION_DIR/state" || {
        cleanup_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
        AUTO_UPDATE_TRANSACTION_DIR=""
        release_update_lock
        return 1
    }
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1; then
            AUTO_UPDATE_WAS_ENABLED=1
        fi
        if systemctl is-active "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1; then
            AUTO_UPDATE_WAS_ACTIVE=1
        fi
    fi
    AUTO_UPDATE_TRANSACTION_ACTIVE=1
}

commit_auto_update_transaction() {
    cleanup_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
    AUTO_UPDATE_TRANSACTION_DIR=""
    AUTO_UPDATE_TRANSACTION_ACTIVE=0
    AUTO_UPDATE_SERVICE_EXISTED=0
    AUTO_UPDATE_TIMER_EXISTED=0
    AUTO_UPDATE_WAS_ENABLED=0
    AUTO_UPDATE_WAS_ACTIVE=0
    release_update_lock
}

rollback_auto_update_transaction() {
    local service_file="${SYSTEMD_DIR}/${AUTO_UPDATE_SERVICE_NAME}"
    local timer_file="${SYSTEMD_DIR}/${AUTO_UPDATE_TIMER_NAME}" result=0
    [[ "$AUTO_UPDATE_TRANSACTION_ACTIVE" == 1 && -d "$AUTO_UPDATE_TRANSACTION_DIR" ]] || return 1
    if [[ "$AUTO_UPDATE_SERVICE_EXISTED" == 1 ]]; then
        cp -a "$AUTO_UPDATE_TRANSACTION_DIR/service" "$service_file" || result=1
    else
        rm -f -- "$service_file" || result=1
    fi
    if [[ "$AUTO_UPDATE_TIMER_EXISTED" == 1 ]]; then
        cp -a "$AUTO_UPDATE_TRANSACTION_DIR/timer" "$timer_file" || result=1
    else
        rm -f -- "$timer_file" || result=1
    fi
    cp -a "$AUTO_UPDATE_TRANSACTION_DIR/state" "$STATE_FILE" || result=1
    chmod 600 "$STATE_FILE" || result=1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || result=1
        if [[ "$AUTO_UPDATE_WAS_ENABLED" == 1 ]]; then
            systemctl enable "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || result=1
            systemctl is-enabled "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || result=1
        else
            systemctl disable "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || true
            if systemctl is-enabled "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1; then
                result=1
            fi
        fi
        if [[ "$AUTO_UPDATE_WAS_ACTIVE" == 1 ]]; then
            systemctl restart "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || result=1
            systemctl is-active "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || result=1
        else
            systemctl stop "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || true
            if systemctl is-active "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1; then
                result=1
            fi
        fi
    fi
    load_state >/dev/null 2>&1 || result=1
    if (( result == 0 )); then
        cleanup_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
    else
        unregister_tmp_path "$AUTO_UPDATE_TRANSACTION_DIR"
        log_error "自动更新配置恢复不完整，事务备份保留在：$AUTO_UPDATE_TRANSACTION_DIR"
    fi
    AUTO_UPDATE_TRANSACTION_DIR=""
    AUTO_UPDATE_TRANSACTION_ACTIVE=0
    AUTO_UPDATE_SERVICE_EXISTED=0
    AUTO_UPDATE_TIMER_EXISTED=0
    AUTO_UPDATE_WAS_ENABLED=0
    AUTO_UPDATE_WAS_ACTIVE=0
    release_update_lock
    return "$result"
}

enable_auto_update() {
    local interval="${1:-$AUTO_UPDATE_INTERVAL_MINUTES}"
    require_root
    load_state || die "尚未安装或导入 Sub-Store"
    validate_auto_update_interval "$interval" || die "自动更新间隔必须是 15 到 10080 分钟"
    command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemctl，无法启用定时更新"
    AUTO_UPDATE_INTERVAL_MINUTES="$interval"
    install_manager_command || return 1
    begin_auto_update_transaction || return 1
    AUTO_UPDATE_INTERVAL_MINUTES="$interval"
    if ! write_auto_update_units || \
        ! systemctl daemon-reload || \
        ! systemctl enable "$AUTO_UPDATE_TIMER_NAME" >/dev/null || \
        ! systemctl restart "$AUTO_UPDATE_TIMER_NAME"; then
        rollback_auto_update_transaction || log_error "启用自动更新失败，且恢复旧配置不完整"
        return 1
    fi
    AUTO_UPDATE_ENABLED=1
    if ! save_state; then
        rollback_auto_update_transaction || log_error "保存自动更新状态失败，且恢复旧配置不完整"
        return 1
    fi
    commit_auto_update_transaction
    log_info "已启用自动更新：每 ${AUTO_UPDATE_INTERVAL_MINUTES} 分钟检查一次"
}

disable_auto_update() {
    require_root
    load_state || die "尚未安装或导入 Sub-Store"
    begin_auto_update_transaction || return 1
    if command -v systemctl >/dev/null 2>&1 && \
        { systemctl is-enabled "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || \
          systemctl is-active "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1; }; then
        if ! systemctl disable --now "$AUTO_UPDATE_TIMER_NAME" >/dev/null; then
            rollback_auto_update_transaction || log_error "停用自动更新失败，且恢复旧配置不完整"
            return 1
        fi
    fi
    AUTO_UPDATE_ENABLED=0
    if ! save_state; then
        rollback_auto_update_transaction || log_error "保存自动更新状态失败，且恢复旧配置不完整"
        return 1
    fi
    commit_auto_update_transaction
    log_info "自动更新已停用"
}

remove_auto_update_units() {
    local defer_commit="${1:-0}"
    begin_auto_update_transaction || return 1
    if command -v systemctl >/dev/null 2>&1 && \
        { systemctl is-enabled "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || \
          systemctl is-active "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1; }; then
        if ! systemctl disable --now "$AUTO_UPDATE_TIMER_NAME" >/dev/null; then
            rollback_auto_update_transaction || log_error "停用自动更新 timer 失败，且恢复旧配置不完整"
            return 1
        fi
    fi
    if ! rm -f -- \
        "${SYSTEMD_DIR}/${AUTO_UPDATE_SERVICE_NAME}" \
        "${SYSTEMD_DIR}/${AUTO_UPDATE_TIMER_NAME}"; then
        rollback_auto_update_transaction || log_error "删除自动更新 unit 失败，且恢复旧配置不完整"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl daemon-reload >/dev/null; then
            rollback_auto_update_transaction || log_error "刷新 systemd 失败，且恢复旧配置不完整"
            return 1
        fi
    fi
    [[ "$defer_commit" == 1 ]] || commit_auto_update_transaction
}

show_auto_update_status() {
    load_state || die "尚未安装或导入 Sub-Store"
    printf '配置状态：%s\n' "$([[ "$AUTO_UPDATE_ENABLED" == 1 ]] && printf '已启用' || printf '已停用')"
    printf '检查间隔：%s 分钟\n' "$AUTO_UPDATE_INTERVAL_MINUTES"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status "$AUTO_UPDATE_TIMER_NAME" --no-pager || true
        systemctl list-timers "$AUTO_UPDATE_TIMER_NAME" --no-pager || true
    fi
}

show_auto_update_logs() {
    command -v journalctl >/dev/null 2>&1 || die "当前系统没有 journalctl"
    journalctl -u "$AUTO_UPDATE_SERVICE_NAME" -n 100 --no-pager
}

configure_auto_update_after_install() {
    local interval
    if [[ "${SUBSTORE_MANAGER_SKIP_AUTO_UPDATE:-0}" == 1 ]]; then
        log_warn "测试模式：跳过自动更新 timer 配置"
        return 0
    fi
    if [[ "${SUBSTORE_NON_INTERACTIVE:-0}" == 1 ]]; then
        if [[ "${SUBSTORE_AUTO_UPDATE:-0}" == 1 ]]; then
            enable_auto_update "${SUBSTORE_AUTO_UPDATE_MINUTES:-60}"
        fi
        return 0
    fi
    if confirm "是否启用定时自动检查并更新前端和后端" Y; then
        interval="$(prompt '检查间隔（分钟，最小 15）' '60')"
        enable_auto_update "$interval"
    fi
}

repair_managed_installation() {
    require_command flock
    acquire_manager_lock_wait
    acquire_update_lock_wait
    load_state || { release_update_lock; release_manager_lock; die "实例状态不存在"; }
    prepare_managed_runtime
    install_manager_command || log_warn "管理命令更新失败：$MANAGER_INSTALL_PATH"
    configure_pm2_startup || log_warn "PM2 开机启动配置仍未完成"
    if [[ "$AUTO_UPDATE_ENABLED" == 1 ]]; then
        if ! command -v systemctl >/dev/null 2>&1; then
            log_warn "自动更新已配置，但当前系统没有 systemctl"
        elif ! systemctl is-enabled "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1 || \
            ! systemctl is-active "$AUTO_UPDATE_TIMER_NAME" >/dev/null 2>&1; then
            enable_auto_update "$AUTO_UPDATE_INTERVAL_MINUTES" || \
                log_warn "自动更新 timer 修复失败：$AUTO_UPDATE_TIMER_NAME"
        fi
    fi
    release_update_lock
    release_manager_lock
}

auto_update_menu() {
    local interval
    load_state || die "尚未安装或导入 Sub-Store"
    while true; do
        printf '\n%s========== 自动更新 ==========%s\n' "$C_BOLD" "$C_RESET"
        printf '1. 启用或修改检查间隔\n2. 停用自动更新\n3. 查看状态与下次执行时间\n4. 查看自动更新日志\n5. 立即检查更新\n0. 返回\n'
        case "$(prompt '请选择')" in
            1)
                interval="$(prompt '检查间隔（分钟，最小 15）' "$AUTO_UPDATE_INTERVAL_MINUTES")"
                enable_auto_update "$interval"
                pause
                ;;
            2) disable_auto_update; pause ;;
            3) show_auto_update_status; pause ;;
            4) show_auto_update_logs; pause ;;
            5) update_instance; pause ;;
            0) return ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

acquire_update_lock() {
    if [[ "$UPDATE_LOCK_HELD" == 1 ]]; then
        ((UPDATE_LOCK_DEPTH += 1))
        return 0
    fi
    mkdir -p -- "$LOCK_DIR"
    chmod 700 "$LOCK_DIR"
    exec 9>"$INSTANCE_LOCK_FILE"
    if ! flock -n 9; then
        log_warn "另一个更新任务正在运行，本次检查跳过"
        exec 9>&-
        return 1
    fi
    UPDATE_LOCK_HELD=1
    UPDATE_LOCK_DEPTH=1
}

acquire_update_lock_wait() {
    if [[ "$UPDATE_LOCK_HELD" == 1 ]]; then
        ((UPDATE_LOCK_DEPTH += 1))
        return 0
    fi
    mkdir -p -- "$LOCK_DIR"
    chmod 700 "$LOCK_DIR"
    exec 9>"$INSTANCE_LOCK_FILE"
    if flock -n 9; then
        UPDATE_LOCK_HELD=1
        UPDATE_LOCK_DEPTH=1
        return 0
    fi
    log_info "等待正在执行的更新任务结束"
    if ! flock -w 1800 9; then
        exec 9>&-
        die "等待更新任务结束超时，已取消当前操作"
    fi
    UPDATE_LOCK_HELD=1
    UPDATE_LOCK_DEPTH=1
}

release_update_lock() {
    if [[ "$UPDATE_LOCK_HELD" == 1 ]]; then
        if (( UPDATE_LOCK_DEPTH > 1 )); then
            ((UPDATE_LOCK_DEPTH -= 1))
            return 0
        fi
        flock -u 9 || true
        exec 9>&-
        UPDATE_LOCK_HELD=0
        UPDATE_LOCK_DEPTH=0
    fi
}

acquire_manager_lock_wait() {
    if [[ "$MANAGER_LOCK_HELD" == 1 ]]; then
        ((MANAGER_LOCK_DEPTH += 1))
        return 0
    fi
    mkdir -p -- "$LOCK_DIR"
    chmod 700 "$LOCK_DIR"
    exec 8>"$MANAGER_LOCK_FILE"
    if flock -n 8; then
        MANAGER_LOCK_HELD=1
        MANAGER_LOCK_DEPTH=1
        return 0
    fi
    log_info "等待其他实例的管理操作结束"
    if ! flock -w 1800 8; then
        exec 8>&-
        die "等待全局管理锁超时，已取消当前操作"
    fi
    MANAGER_LOCK_HELD=1
    MANAGER_LOCK_DEPTH=1
}

release_manager_lock() {
    if [[ "$MANAGER_LOCK_HELD" == 1 ]]; then
        if (( MANAGER_LOCK_DEPTH > 1 )); then
            ((MANAGER_LOCK_DEPTH -= 1))
            return 0
        fi
        flock -u 8 || true
        exec 8>&-
        MANAGER_LOCK_HELD=0
        MANAGER_LOCK_DEPTH=0
    fi
}

release_info() {
    local repo="$1" asset="$2" json_file parsed_file node_bin
    local -a release_fields=()
    json_file="$(mktemp)"
    register_tmp "$json_file"
    parsed_file="$(mktemp)"
    register_tmp "$parsed_file"
    curl_args 60
    curl "${CURL_ARGS[@]}" \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$json_file" \
        "${GITHUB_API_BASE}/repos/${repo}/releases/latest"
    node_bin="$(node_command)"
    if ! "$node_bin" - "$json_file" "$asset" >"$parsed_file" <<'NODE'
const fs = require('fs');
const [file, assetName] = process.argv.slice(2);
const release = JSON.parse(fs.readFileSync(file, 'utf8'));
const asset = (release.assets || []).find(item => item.name === assetName);
if (!release.tag_name) throw new Error('latest release has no tag_name');
if (!asset) throw new Error(`release ${release.tag_name} has no ${assetName}`);
process.stdout.write(`${release.tag_name}\n`);
process.stdout.write(`${asset.browser_download_url}\n`);
process.stdout.write(`${asset.digest || ''}\n`);
process.stdout.write(`${String(asset.size || '')}\n`);
NODE
    then
        cleanup_tmp_path "$json_file"
        cleanup_tmp_path "$parsed_file"
        die "GitHub Release 元数据解析失败：${repo}/${asset}"
    fi
    mapfile -t release_fields <"$parsed_file"
    cleanup_tmp_path "$json_file"
    cleanup_tmp_path "$parsed_file"
    [[ "${#release_fields[@]}" == 4 ]] || die "GitHub Release 元数据字段不完整：${repo}/${asset}"
    RELEASE_TAG="${release_fields[0]}"
    RELEASE_URL="${release_fields[1]}"
    RELEASE_DIGEST="${release_fields[2]}"
    RELEASE_SIZE="${release_fields[3]}"
    if [[ "$GITHUB_API_BASE" == https://api.github.com && \
        "$RELEASE_URL" != "https://github.com/${repo}/releases/download/"* ]]; then
        die "GitHub API 返回了非预期资产地址：$RELEASE_URL"
    fi
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

verify_download() {
    local file="$1" digest="$2" size="$3" actual
    [[ -s "$file" ]] || die "下载文件为空：$file"
    if [[ -n "$size" && "$size" != 0 ]]; then
        [[ "$(stat -c '%s' "$file")" == "$size" ]] || die "下载文件大小校验失败：$file"
    fi
    case "$digest" in
        '') log_warn "GitHub Release 未提供 SHA-256：$file" ;;
        sha256:*)
            actual="sha256:$(sha256_file "$file")"
            [[ "$actual" == "$digest" ]] || die "SHA-256 校验失败：$file"
            ;;
        *) die "GitHub Release 提供了不支持的摘要格式：$digest" ;;
    esac
}

download_backend_release() {
    local destination="$1"
    release_info "$BACKEND_REPO" "$BACKEND_ASSET"
    BACKEND_LATEST="$RELEASE_TAG"
    http_download "$RELEASE_URL" "$destination"
    verify_download "$destination" "$RELEASE_DIGEST" "$RELEASE_SIZE"
    grep -Fqx "// SUB_STORE_BACKEND_VERSION: ${BACKEND_LATEST}" < <(head -n 1 "$destination") || \
        die "后端 bundle 内嵌版本与 Release tag 不一致"
}

download_frontend_release() {
    local destination="$1"
    release_info "$FRONTEND_REPO" "$FRONTEND_ASSET"
    FRONTEND_LATEST="$RELEASE_TAG"
    http_download "$RELEASE_URL" "$destination"
    verify_download "$destination" "$RELEASE_DIGEST" "$RELEASE_SIZE"
}

extract_frontend() {
    local zip_file="$1" destination="$2" unpack_dir source_dir
    make_temp_dir unpack_dir "$(dirname -- "$destination")" .substore-frontend-unpack || return 1
    unzip -q "$zip_file" -d "$unpack_dir"
    if [[ -f "$unpack_dir/dist/index.html" ]]; then
        source_dir="$unpack_dir/dist"
    elif [[ -f "$unpack_dir/index.html" ]]; then
        source_dir="$unpack_dir"
    else
        die "前端压缩包中未找到 index.html"
    fi
    mkdir -p -- "$destination"
    cp -a "$source_dir"/. "$destination"/
    [[ -f "$destination/index.html" ]] || die "前端解压失败"
    cleanup_tmp_path "$unpack_dir"
}

backend_version_from_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    sed -n '1s|^// SUB_STORE_BACKEND_VERSION: ||p' "$file" | tr -d '\r\n'
}

install_backend_file() {
    local source="$1" target="${2:-$BACKEND_FILE}" parent temp
    [[ -f "$source" && ! -L "$source" ]] || return 1
    parent="$(dirname -- "$target")"
    mkdir -p -- "$parent" || return 1
    temp="$(mktemp "${parent}/.substore-backend.XXXXXX")" || return 1
    register_tmp "$temp"
    install -m 0644 "$source" "$temp" || { cleanup_tmp_path "$temp"; return 1; }
    cmp -s "$source" "$temp" || { cleanup_tmp_path "$temp"; return 1; }
    mv -Tf -- "$temp" "$target" || { cleanup_tmp_path "$temp"; return 1; }
    unregister_tmp_path "$temp"
}

write_ecosystem() {
    local node_bin
    [[ ! -L "$ECOSYSTEM_FILE" ]] || {
        log_error "PM2 配置不能是符号链接：$ECOSYSTEM_FILE"
        return 1
    }
    node_bin="$(node_command)"
    if ! "$node_bin" - "$ECOSYSTEM_FILE" "$PM2_NAME" "$BACKEND_FILE" "$DEPLOY_DIR" "$NODE_BIN" <<'NODE'
const fs = require('fs');
const [file, name, script, cwd, interpreter] = process.argv.slice(2);
const config = {
  apps: [{
    name,
    script,
    cwd,
    interpreter,
    exec_mode: 'fork',
    instances: 1,
    autorestart: true,
    watch: false,
    restart_delay: 3000,
    kill_timeout: 10000,
    time: true
  }]
};
const temp = `${file}.tmp.${process.pid}`;
try {
  fs.writeFileSync(temp, `module.exports = ${JSON.stringify(config, null, 2)};\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
  fs.chmodSync(file, 0o600);
} finally {
  try { fs.unlinkSync(temp); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}
NODE
    then
        return 1
    fi
    chmod 600 "$ECOSYSTEM_FILE" || return 1
}

load_pm2_process_info() {
    local process_json info
    if ! process_json="$(pm2 jlist 2>/dev/null)"; then
        log_error "无法读取 PM2 进程列表"
        return 2
    fi
    # shellcheck disable=SC2016
    if ! info="$(printf '%s' "$process_json" | "$(node_command)" -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const name = process.argv[1];
  const apps = JSON.parse(input).filter(app => app.name === name);
  if (apps.length === 0) {
    process.stdout.write("missing\n");
    return;
  }
  const statuses = [...new Set(apps.map(app => app.pm2_env?.status || "unknown"))];
  const paths = [...new Set(apps.map(app => app.pm2_env?.pm_exec_path).filter(Boolean))];
  process.stdout.write(`${statuses.length === 1 ? statuses[0] : "mixed"}\n`);
  process.stdout.write(paths.length === 1 ? paths[0] : "__multiple__");
});
' "$PM2_NAME")"; then
        log_error "PM2 进程列表解析失败"
        return 2
    fi
    PM2_STATUS="${info%%$'\n'*}"
    if [[ "$info" == *$'\n'* ]]; then
        PM2_EXEC_PATH="${info#*$'\n'}"
    else
        PM2_EXEC_PATH=""
    fi
    [[ -n "$PM2_STATUS" ]] || {
        log_error "PM2 返回空状态"
        return 2
    }
}

pm2_process_status() {
    load_pm2_process_info || return $?
    printf '%s' "$PM2_STATUS"
}

pm2_env_get() {
    local key="$1"
    pm2 jlist 2>/dev/null | "$(node_command)" -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const [name, key] = process.argv.slice(1);
  const app = JSON.parse(input).find(item => item.name === name);
  const value = app?.pm2_env?.[key];
  if (value == null || value === "") process.exit(1);
  process.stdout.write(String(value));
});
' "$PM2_NAME" "$key"
}

pm2_process_matches_instance() {
    load_pm2_process_info || return 1
    [[ "$PM2_STATUS" != missing && "$PM2_EXEC_PATH" == "$BACKEND_FILE" ]]
}

assert_pm2_target() {
    local actual_path="${1:-}"
    if [[ -z "$actual_path" ]]; then
        load_pm2_process_info || return 1
        actual_path="$PM2_EXEC_PATH"
    fi
    [[ "$actual_path" == "$BACKEND_FILE" ]] || {
        log_error "PM2 名称 $PM2_NAME 未指向当前实例后端：$BACKEND_FILE"
        return 1
    }
}

start_instance() {
    load_pm2_process_info || return 1
    case "$PM2_STATUS" in
        online)
            assert_pm2_target "$PM2_EXEC_PATH" || return 1
            log_info "PM2 进程已在运行：$PM2_NAME"
            return 0
            ;;
        missing)
            pm2 start "$ECOSYSTEM_FILE" --only "$PM2_NAME" >/dev/null || return 1
            [[ "$INSTALL_TRANSACTION_ACTIVE" == 1 ]] && PM2_CREATED_BY_TRANSACTION=1
            ;;
        *)
            assert_pm2_target "$PM2_EXEC_PATH" || return 1
            pm2 start "$PM2_NAME" >/dev/null || return 1
            ;;
    esac
    pm2 save >/dev/null || return 1
}

stop_instance() {
    local persist="${1:-1}"
    load_pm2_process_info || return 1
    case "$PM2_STATUS" in
        missing)
            log_warn "PM2 进程不存在：$PM2_NAME"
            return 0
            ;;
        stopped)
            log_info "PM2 进程已停止：$PM2_NAME"
            return 0
            ;;
        *)
            assert_pm2_target "$PM2_EXEC_PATH" || return 1
            pm2 stop "$PM2_NAME" >/dev/null || return 1
            if [[ "$persist" == 1 ]]; then
                pm2 save >/dev/null || return 1
            fi
            ;;
    esac
}

restart_instance() {
    local persist="${1:-1}"
    if [[ "${SUBSTORE_MANAGER_TESTING:-0}" == 1 && \
        "${SUBSTORE_MANAGER_TEST_FAIL_PM2_RESTART_ONCE:-0}" == 1 && \
        "$PM2_RESTART_FAILURE_INJECTED" == 0 ]]; then
        PM2_RESTART_FAILURE_INJECTED=1
        log_warn "测试模式：注入一次 PM2 重启失败"
        return 1
    fi
    load_pm2_process_info || return 1
    if [[ "$PM2_STATUS" == missing ]]; then
        pm2 start "$ECOSYSTEM_FILE" --only "$PM2_NAME" >/dev/null || return 1
    else
        assert_pm2_target "$PM2_EXEC_PATH" || return 1
        pm2 restart "$PM2_NAME" >/dev/null || return 1
    fi
    if [[ "$persist" == 1 ]]; then
        pm2 save >/dev/null || return 1
    fi
}

delete_pm2_instance() {
    load_pm2_process_info || return 1
    if [[ "$PM2_STATUS" == missing ]]; then
        pm2 save >/dev/null || return 1
        return 0
    fi
    assert_pm2_target "$PM2_EXEC_PATH" || return 1
    pm2 delete "$PM2_NAME" >/dev/null || return 1
    pm2 save >/dev/null || return 1
}

rollback_incomplete_install() {
    local frontend_marker data_marker
    [[ "$INSTALL_TRANSACTION_ACTIVE" == 1 ]] || return 0
    INSTALL_TRANSACTION_ACTIVE=0
    log_warn "安装未完成，正在清理本次创建的内容"

    if command -v pm2 >/dev/null 2>&1 && [[ -n "$PM2_NAME" ]]; then
        if [[ "$PM2_CREATED_BY_TRANSACTION" == 1 ]] && pm2_process_matches_instance >/dev/null 2>&1; then
            pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
            pm2 save >/dev/null 2>&1 || true
        fi
    fi

    rm -f -- "$STATE_FILE" 2>/dev/null || true
    rmdir -- "$STATE_ROOT" 2>/dev/null || true

    if [[ -n "$FRONTEND_DIR" && -d "$FRONTEND_DIR" ]]; then
        frontend_marker="${FRONTEND_DIR}/.substore-manager-frontend"
        if [[ -f "$frontend_marker" ]] && grep -Fxq "$INSTALL_ID" "$frontend_marker"; then
            if [[ "$FRONTEND_CREATED_BY_MANAGER" == 1 ]]; then
                rm -rf -- "$FRONTEND_DIR" 2>/dev/null || true
            else
                find "$FRONTEND_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
            fi
        fi
    fi

    if [[ -n "$DATA_DIR" && -d "$DATA_DIR" ]]; then
        data_marker="${DATA_DIR}/.substore-manager-data"
        if [[ -f "$data_marker" ]] && grep -Fxq "$INSTALL_ID" "$data_marker"; then
            if [[ "$DATA_CREATED_BY_MANAGER" == 1 ]]; then
                rm -rf -- "$DATA_DIR" 2>/dev/null || true
            else
                rm -f -- "$data_marker" 2>/dev/null || true
            fi
        fi
    fi

    if [[ -n "$DEPLOY_DIR" && -d "$DEPLOY_DIR" ]]; then
        rm -f -- "$BACKEND_FILE" "$ENV_FILE" "$ECOSYSTEM_FILE" "$MARKER_FILE" 2>/dev/null || true
        rm -rf -- "${DEPLOY_DIR}/backups" 2>/dev/null || true
        [[ "$DEPLOY_DIR_EXISTED" == 1 ]] || rmdir -- "$DEPLOY_DIR" 2>/dev/null || true
    fi
}

rollback_incomplete_import() {
    local marker
    [[ "$IMPORT_TRANSACTION_ACTIVE" == 1 ]] || return 0
    IMPORT_TRANSACTION_ACTIVE=0
    log_warn "导入未完成，正在撤回管理器创建的状态"
    rm -f -- "$STATE_FILE" "$ECOSYSTEM_FILE" 2>/dev/null || true
    rmdir -- "$STATE_ROOT" 2>/dev/null || true
    marker="${DATA_DIR}/.substore-manager-data"
    if [[ -f "$marker" ]] && grep -Fxq "$INSTALL_ID" "$marker"; then
        rm -f -- "$marker" 2>/dev/null || true
    fi
    marker="$(frontend_marker_path)"
    if [[ -f "$marker" ]] && grep -Fxq "$INSTALL_ID" "$marker"; then
        rm -f -- "$marker" 2>/dev/null || true
    fi
    rmdir -- "${DEPLOY_DIR}/backups" 2>/dev/null || true
}

health_host() {
    local host="$HOST"
    case "$HOST" in
        ::|::1) printf '%s' '[::1]' ;;
        0.0.0.0) printf '%s' '127.0.0.1' ;;
        localhost) printf '%s' '127.0.0.1' ;;
        \[*\]) printf '%s' "$HOST" ;;
        *:*)
            host="${host//%/%25}"
            printf '[%s]' "$host"
            ;;
        *) printf '%s' "$HOST" ;;
    esac
}

health_path() {
    local prefix merge backend_prefix
    prefix="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH 2>/dev/null || true)"
    merge="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_MERGE 2>/dev/null || true)"
    backend_prefix="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_PREFIX 2>/dev/null || true)"
    if [[ -n "$prefix" && "$prefix" != / && ( -n "$merge" || -n "$backend_prefix" ) ]]; then
        printf '%s/api/utils/env' "${prefix%/}"
    else
        printf '%s' '/api/utils/env'
    fi
}

wait_for_health() {
    local expected_version="${1:-}" deadline response_file url node_bin port_status
    deadline=$((SECONDS + 45))
    response_file="$(mktemp)"
    register_tmp "$response_file"
    url="http://$(health_host):${PORT}$(health_path)"
    node_bin="$(node_command)"

    if [[ "${SUBSTORE_MANAGER_TESTING:-0}" == 1 && \
        "${SUBSTORE_MANAGER_TEST_FAIL_HEALTH_ONCE:-0}" == 1 && \
        "${HEALTH_FAILURE_INJECTED:-0}" == 0 ]]; then
        HEALTH_FAILURE_INJECTED=1
        log_warn "测试模式：注入一次健康检查失败"
        return 1
    fi

    while (( SECONDS < deadline )); do
        if port_in_use "$PORT"; then
            load_pm2_process_info || {
                cleanup_tmp_path "$response_file"
                return 1
            }
            if [[ "$PM2_STATUS" == online ]]; then
                assert_pm2_target "$PM2_EXEC_PATH" || {
                    cleanup_tmp_path "$response_file"
                    return 1
                }
                break
            fi
        else
            port_status=$?
            if (( port_status == 2 )); then
                cleanup_tmp_path "$response_file"
                log_error "无法读取监听端口状态：$PORT"
                return 1
            fi
        fi
        sleep 1
    done
    if (( SECONDS >= deadline )); then
        cleanup_tmp_path "$response_file"
        log_error "PM2 或监听端口未在限定时间内就绪：$PM2_NAME / $PORT"
        return 1
    fi

    while (( SECONDS < deadline )); do
        if curl --noproxy '*' --fail --silent --show-error --max-time 5 "$url" -o "$response_file" 2>/dev/null && \
            "$node_bin" - "$response_file" "$expected_version" <<'NODE'
const fs = require('fs');
const [file, expected] = process.argv.slice(2);
try {
  const payload = JSON.parse(fs.readFileSync(file, 'utf8'));
  const value = payload?.data || payload;
  if (payload?.status && payload.status !== 'success') process.exit(1);
  if (value.backend !== 'Node') process.exit(1);
  if (expected && value.version !== expected) process.exit(1);
} catch {
  process.exit(1);
}
NODE
        then
            log_info "健康检查通过：$url"
            cleanup_tmp_path "$response_file"
            return 0
        fi
        sleep 2
    done
    cleanup_tmp_path "$response_file"
    log_error "健康检查失败：$url"
    return 1
}

write_initial_env() {
    local magic_path="$1" node_bin
    [[ ! -L "$ENV_FILE" ]] || return 1
    node_bin="$(node_command)"
    if ! "$node_bin" - "$ENV_FILE" "$PORT" "$HOST" "$magic_path" "$FRONTEND_DIR" "$DATA_DIR" <<'NODE'
const fs = require('fs');
const [file, port, host, magicPath, frontendDir, dataDir] = process.argv.slice(2);
const values = {
  SUB_STORE_BACKEND_API_PORT: port,
  SUB_STORE_BACKEND_API_HOST: host,
  SUB_STORE_BACKEND_MERGE: 'true',
  SUB_STORE_FRONTEND_BACKEND_PATH: magicPath,
  SUB_STORE_FRONTEND_PATH: frontendDir,
  SUB_STORE_DATA_BASE_PATH: dataDir,
  SUB_STORE_CORS_ALLOWED_ORIGINS: '*'
};
const temp = `${file}.tmp.${process.pid}`;
try {
  const source = Object.entries(values)
    .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
    .join('\n') + '\n';
  fs.writeFileSync(temp, source, { mode: 0o600 });
  fs.renameSync(temp, file);
  fs.chmodSync(file, 0o600);
} finally {
  try { fs.unlinkSync(temp); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}
NODE
    then
        return 1
    fi
}

resolve_config_path() {
    local value="$1" fallback="$2"
    if [[ -z "$value" ]]; then
        printf '%s' "$(normalize_path "$fallback")"
    elif [[ "$value" == /* ]]; then
        printf '%s' "$(normalize_path "$value")"
    else
        printf '%s' "$(normalize_path "${DEPLOY_DIR}/${value}")"
    fi
}

validate_runtime_layout() {
    local backups_dir="${DEPLOY_DIR}/backups" frontend_top=""
    if [[ "$DATA_DIR" != "$DEPLOY_DIR" ]]; then
        validate_managed_layout || return 1
        return 0
    fi
    [[ "$FRONTEND_DIR" != "$DEPLOY_DIR" ]] || return 1
    path_contains "$FRONTEND_DIR" "$DEPLOY_DIR" && return 1
    if path_contains "$DEPLOY_DIR" "$FRONTEND_DIR"; then
        frontend_top="$(managed_top_level_path "$DEPLOY_DIR" "$FRONTEND_DIR" 2>/dev/null || true)"
        if [[ "$frontend_top" != "$FRONTEND_DIR" ]]; then
            log_error "数据目录等于部署目录时，前端只能使用部署根的直接子目录或外部目录：$FRONTEND_DIR"
            return 1
        fi
    fi
    if path_contains "$backups_dir" "$FRONTEND_DIR" || path_contains "$FRONTEND_DIR" "$backups_dir"; then
        return 1
    fi
}

sync_state_from_env() {
    local value new_port new_host new_data new_frontend changed=0
    local old_port="$PORT" old_host="$HOST" old_data="$DATA_DIR" old_frontend="$FRONTEND_DIR"
    value="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_PORT 2>/dev/null || true)"
    new_port="${value:-3000}"
    value="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_HOST 2>/dev/null || true)"
    new_host="${value:-::}"
    value="$(env_get "$ENV_FILE" SUB_STORE_DATA_BASE_PATH 2>/dev/null || true)"
    new_data="$(resolve_config_path "$value" "$DEPLOY_DIR")"
    value="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_PATH 2>/dev/null || true)"
    new_frontend="$(resolve_config_path "$value" "${DEPLOY_DIR}/frontend")"

    validate_env_value SUB_STORE_BACKEND_API_PORT "$new_port" || {
        log_error "Env 中的后端端口无效：$new_port"
        return 1
    }
    validate_env_value SUB_STORE_BACKEND_API_HOST "$new_host" || {
        log_error "Env 中的后端监听地址无效：$new_host"
        return 1
    }

    [[ "$PORT" == "$new_port" ]] || { PORT="$new_port"; changed=1; }
    [[ "$HOST" == "$new_host" ]] || { HOST="$new_host"; changed=1; }
    [[ "$DATA_DIR" == "$new_data" ]] || { DATA_DIR="$new_data"; changed=1; }
    [[ "$FRONTEND_DIR" == "$new_frontend" ]] || { FRONTEND_DIR="$new_frontend"; changed=1; }

    if ! validate_runtime_layout || ! assert_paths_not_managed_elsewhere || \
        ! assert_identity_not_managed_elsewhere || \
        ! manager_marker_matches "${DATA_DIR}/.substore-manager-data" || \
        ! manager_marker_matches "$(frontend_marker_path)"; then
        log_error "Env 中的目录布局、跨实例占用或管理标记不安全"
        PORT="$old_port"
        HOST="$old_host"
        DATA_DIR="$old_data"
        FRONTEND_DIR="$old_frontend"
        return 1
    fi
    (( changed == 0 )) || save_state
}

port_in_use() {
    local port="$1" output
    output="$(ss -ltnH "sport = :$port" 2>/dev/null)" || return 2
    [[ -n "$output" ]]
}

validate_pm2_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

prepare_system_tools() {
    require_root
    detect_os
    ensure_base_packages
    require_command sha256sum
    require_command ss
    require_command unzip
    require_command flock
    require_command realpath
}

prepare_managed_runtime() {
    require_root
    validate_instance_files || die "实例状态存在，但安装内容不完整"
    if [[ ! -x "$NODE_BIN" ]]; then
        command -v node >/dev/null 2>&1 || die "已安装实例记录的 Node 不可用，且系统中找不到 node"
        NODE_BIN="$(command -v node)"
        write_ecosystem || die "更新 PM2 Node 路径失败"
        save_state || die "保存新的 Node 路径失败"
        log_warn "状态文件中的 Node 路径不可用，已修复为：$NODE_BIN"
    fi
    require_command pm2
    require_command curl
    require_command ss
    require_command flock
    require_command realpath
}

prepare_pm2_control_runtime() {
    require_command pm2
    if [[ ! -x "$NODE_BIN" ]]; then
        command -v node >/dev/null 2>&1 || die "无法读取 PM2 状态：找不到可用的 node"
        NODE_BIN="$(command -v node)"
    fi
}

prepare_update_tools() {
    ensure_base_packages
    require_command sha256sum
    require_command unzip
    require_command tar
}

install_manager_command() {
    local install_dir temp
    [[ "$SCRIPT_PATH" == "$MANAGER_INSTALL_PATH" ]] && return 0
    if [[ -f "$MANAGER_INSTALL_PATH" ]] && cmp -s "$SCRIPT_PATH" "$MANAGER_INSTALL_PATH"; then
        return 0
    fi
    if [[ -e "$MANAGER_INSTALL_PATH" || -L "$MANAGER_INSTALL_PATH" ]]; then
        if [[ ! -f "$MANAGER_INSTALL_PATH" || -L "$MANAGER_INSTALL_PATH" ]] || \
            { ! grep -Fqx "MANAGER_ID=\"${MANAGER_ID}\"" "$MANAGER_INSTALL_PATH" && \
              { ! grep -Fq 'BACKEND_REPO="sub-store-org/Sub-Store"' "$MANAGER_INSTALL_PATH" || \
                ! grep -Fq 'install_or_import()' "$MANAGER_INSTALL_PATH"; }; }; then
            log_error "管理命令路径已被其他文件占用：$MANAGER_INSTALL_PATH"
            log_error "请通过 SUBSTORE_MANAGER_INSTALL_PATH 指定其他路径"
            return 1
        fi
    fi
    install_dir="$(dirname -- "$MANAGER_INSTALL_PATH")"
    mkdir -p -- "$install_dir" || return 1
    temp="$(mktemp "${install_dir}/.substore-manager-command.XXXXXX")" || return 1
    register_tmp "$temp"
    install -m 0755 "$SCRIPT_PATH" "$temp" || { cleanup_tmp_path "$temp"; return 1; }
    mv -Tf -- "$temp" "$MANAGER_INSTALL_PATH" || { cleanup_tmp_path "$temp"; return 1; }
    unregister_tmp_path "$temp"
    log_info "管理命令已安装：$MANAGER_INSTALL_PATH"
}

new_install() {
    local default_deploy default_pm2 default_data default_frontend default_magic_path magic_path stage stage_parent backend_stage frontend_zip frontend_stage existing_pm2_status port_status
    if [[ "$INSTANCE_ID" == default ]]; then
        default_deploy="${SUBSTORE_INSTALL_DIR:-/opt/sub-store}"
        default_pm2="${SUBSTORE_PM2_NAME:-sub-store}"
    else
        default_deploy="${SUBSTORE_INSTALL_DIR:-/opt/sub-store-${INSTANCE_ID}}"
        default_pm2="${SUBSTORE_PM2_NAME:-sub-store-${INSTANCE_ID}}"
    fi
    default_magic_path="/$(random_hex 32)"
    BACKUP_RETENTION_COUNT="${SUBSTORE_BACKUP_RETENTION:-10}"
    [[ "$BACKUP_RETENTION_COUNT" =~ ^[0-9]+$ && "$BACKUP_RETENTION_COUNT" -ge 1 && \
        "$BACKUP_RETENTION_COUNT" -le 100 ]] || die "SUBSTORE_BACKUP_RETENTION 必须是 1 到 100"
    if [[ "${SUBSTORE_NON_INTERACTIVE:-0}" == 1 ]]; then
        DEPLOY_DIR="$default_deploy"
        PORT="${SUBSTORE_PORT:-3000}"
        PM2_NAME="$default_pm2"
        HOST="${SUBSTORE_HOST:-127.0.0.1}"
        DATA_DIR="${SUBSTORE_DATA_DIR:-${DEPLOY_DIR}/data}"
        FRONTEND_DIR="${SUBSTORE_FRONTEND_DIR:-${DEPLOY_DIR}/frontend}"
        magic_path="${SUBSTORE_MAGIC_PATH:-$default_magic_path}"
    else
        DEPLOY_DIR="$(prompt '部署目录' "$default_deploy")"
        PORT="$(prompt '监听端口' "${SUBSTORE_PORT:-3000}")"
        PM2_NAME="$(prompt 'PM2 进程名称' "$default_pm2")"
        HOST="$(prompt '监听地址（127.0.0.1 仅本机；:: 监听全部）' "${SUBSTORE_HOST:-127.0.0.1}")"
        default_data="${DEPLOY_DIR}/data"
        DATA_DIR="$(prompt '持久化数据目录' "${SUBSTORE_DATA_DIR:-$default_data}")"
        default_frontend="${DEPLOY_DIR}/frontend"
        FRONTEND_DIR="$(prompt '前端文件目录（更新后的 dist 解压位置）' "${SUBSTORE_FRONTEND_DIR:-$default_frontend}")"
        magic_path="$(prompt '后端路径前缀（SUB_STORE_FRONTEND_BACKEND_PATH）' "$default_magic_path")"
    fi

    validate_absolute_path "$DEPLOY_DIR" || die "部署目录必须是安全的绝对路径"
    validate_absolute_path "$DATA_DIR" || die "数据目录必须是安全的绝对路径"
    validate_absolute_path "$FRONTEND_DIR" || die "前端目录必须是安全的绝对路径"
    validate_env_value SUB_STORE_BACKEND_API_PORT "$PORT" || die "端口无效：$PORT"
    validate_env_value SUB_STORE_BACKEND_API_HOST "$HOST" || die "监听地址无效：$HOST"
    validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH "$magic_path" || \
        die "后端路径前缀必须以 / 开头"
    validate_pm2_name "$PM2_NAME" || die "PM2 名称只能包含字母、数字、点、下划线和连字符"

    prepare_system_tools
    DEPLOY_DIR="$(normalize_path "$DEPLOY_DIR")"
    DATA_DIR="$(normalize_path "$DATA_DIR")"
    FRONTEND_DIR="$(normalize_path "$FRONTEND_DIR")"
    validate_managed_layout || die "目录布局存在危险的包含关系"
    deploy_dir_reusable || die "部署目录包含数据/前端目录之外的现有内容：$DEPLOY_DIR"
    if [[ -e "$FRONTEND_DIR" ]] && find "$FRONTEND_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "前端目录必须不存在或为空：$FRONTEND_DIR"
    fi
    [[ ! -e "${DATA_DIR}/.substore-manager-data" && ! -L "${DATA_DIR}/.substore-manager-data" ]] || \
        die "数据目录已存在管理标记，拒绝覆盖：$DATA_DIR"

    acquire_manager_lock_wait
    assert_paths_not_managed_elsewhere || die "目录与其他管理实例冲突"
    assert_identity_not_managed_elsewhere

    ensure_node
    ensure_pm2
    acquire_update_lock_wait
    if [[ -f "$STATE_FILE" ]]; then
        release_update_lock
        release_manager_lock
        log_info "实例已由另一个安装过程完成：$INSTANCE_ID"
        return 0
    fi
    assert_paths_not_managed_elsewhere || die "目录与其他管理实例冲突"
    assert_identity_not_managed_elsewhere
    existing_pm2_status="$(pm2_process_status)" || die "无法确认 PM2 进程名称是否可用"
    if [[ "$existing_pm2_status" != missing ]]; then
        die "PM2 进程名已存在：$PM2_NAME"
    fi
    if port_in_use "$PORT"; then
        die "端口已被占用：$PORT"
    else
        port_status=$?
        (( port_status == 1 )) || die "无法确认监听端口是否可用：$PORT"
    fi

    [[ -e "$DEPLOY_DIR" ]] && DEPLOY_DIR_EXISTED=1 || DEPLOY_DIR_EXISTED=0
    BACKEND_FILE="${DEPLOY_DIR}/${BACKEND_ASSET}"
    ENV_FILE="${DEPLOY_DIR}/.env"
    ECOSYSTEM_FILE="${DEPLOY_DIR}/ecosystem.config.cjs"
    MARKER_FILE="${DEPLOY_DIR}/.substore-manager-instance"
    INSTALL_ID="$(random_hex 16)"
    CREATED_BY_MANAGER=1
    if [[ -e "$DATA_DIR" ]]; then
        DATA_CREATED_BY_MANAGER=0
    else
        DATA_CREATED_BY_MANAGER=1
    fi
    if [[ -e "$FRONTEND_DIR" ]]; then
        FRONTEND_CREATED_BY_MANAGER=0
    else
        FRONTEND_CREATED_BY_MANAGER=1
    fi
    INSTALLED_AT="$(date -Iseconds)"
    NODE_BIN="$(command -v node)"

    stage_parent="$(dirname -- "$DEPLOY_DIR")"
    make_temp_dir stage "$stage_parent" .substore-install || die "无法创建安装临时目录"
    backend_stage="${stage}/${BACKEND_ASSET}"
    frontend_zip="${stage}/${FRONTEND_ASSET}"
    frontend_stage="${stage}/frontend"
    log_info "下载官方后端 Release"
    download_backend_release "$backend_stage"
    log_info "下载官方前端 Release"
    download_frontend_release "$frontend_zip"
    extract_frontend "$frontend_zip" "$frontend_stage"

    INSTALL_TRANSACTION_ACTIVE=1
    mkdir -p -- "$DEPLOY_DIR" "$DATA_DIR" "${DEPLOY_DIR}/backups"
    [[ "$DEPLOY_DIR_EXISTED" == 1 ]] || chmod 755 "$DEPLOY_DIR"
    [[ "$DATA_CREATED_BY_MANAGER" == 0 ]] || chmod 700 "$DATA_DIR"
    chmod 700 "${DEPLOY_DIR}/backups"
    write_manager_marker "$MARKER_FILE" || die "写入实例管理标记失败"
    write_manager_marker "${DATA_DIR}/.substore-manager-data" || die "写入数据目录管理标记失败"

    install_backend_file "$backend_stage" || die "后端文件写入失败"
    mkdir -p "$FRONTEND_DIR"
    write_frontend_marker
    cp -a "$frontend_stage"/. "$FRONTEND_DIR"/
    [[ -f "$FRONTEND_DIR/index.html" ]] || die "前端文件写入失败"
    write_initial_env "$magic_path"
    write_ecosystem

    BACKEND_VERSION="$BACKEND_LATEST"
    FRONTEND_VERSION="$FRONTEND_LATEST"
    save_state

    start_instance || die "PM2 启动失败"
    if ! wait_for_health "$BACKEND_VERSION"; then
        pm2 logs "$PM2_NAME" --lines 100 --nostream >&2 || true
        die "首次启动健康检查失败"
    fi
    INSTALL_TRANSACTION_ACTIVE=0
    cleanup_tmp_path "$stage"

    configure_pm2_startup || log_warn "Sub-Store 已运行，但 PM2 开机启动配置失败"
    install_manager_command || log_warn "Sub-Store 已运行，但管理命令安装失败：$MANAGER_INSTALL_PATH"
    configure_auto_update_after_install || log_warn "Sub-Store 已运行，但自动更新配置失败"
    release_update_lock
    release_manager_lock

    log_info "Sub-Store 安装完成"
    printf '管理实例：%s\n' "$INSTANCE_ID"
    printf '部署目录：%s\n' "$DEPLOY_DIR"
    printf '数据目录：%s\n' "$DATA_DIR"
    printf 'PM2 名称：%s\n' "$PM2_NAME"
    printf '后端版本：%s\n' "$BACKEND_VERSION"
    printf '前端版本：%s\n' "$FRONTEND_VERSION"
    printf '本机健康检查：http://%s:%s%s\n' "$(health_host)" "$PORT" "$(health_path)"
}

pm2_name_managed_elsewhere() {
    local candidate="$1" state_path other_name
    while IFS= read -r state_path; do
        [[ -n "$state_path" ]] || continue
        [[ "$state_path" == "$STATE_FILE" ]] && continue
        state_file_trusted "$state_path" || die "发现不可信的实例状态文件：$state_path"
        other_name="$(bash -c '
set -u
source "$1"
printf "%s" "${PM2_NAME:-}"
' _ "$state_path")"
        [[ "$other_name" != "$candidate" ]] || return 0
    done < <(managed_state_files)
    return 1
}

discover_pm2_instances() {
    local raw line name
    # shellcheck disable=SC2016
    if ! raw="$(pm2 jlist 2>/dev/null | "$(node_command)" -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const seen = new Set();
  for (const app of JSON.parse(input)) {
    const file = app.pm2_env?.pm_exec_path || "";
    if (!/sub-store\.bundle\.js$/.test(file)) continue;
    const key = `${app.name}\t${file}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const fields = [
      app.name,
      file,
      app.pm2_env?.pm_cwd || "",
      app.pm2_env?.exec_interpreter || "node"
    ];
    if (fields.some(value => /[\t\r\n]/.test(String(value)))) {
      throw new Error(`PM2 process ${app.name} contains unsupported control characters`);
    }
    process.stdout.write(fields.join("\t") + "\n");
  }
});
')"; then
        log_error "无法读取或解析 PM2 进程列表"
        return 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%$'\t'*}"
        pm2_name_managed_elsewhere "$name" || printf '%s\n' "$line"
    done <<<"$raw"
}

validate_import_pm2_compatibility() {
    local pm2_json node_bin
    pm2_json="$(mktemp)" || return 1
    register_tmp "$pm2_json"
    pm2 jlist >"$pm2_json" 2>/dev/null || { cleanup_tmp_path "$pm2_json"; return 1; }
    node_bin="$(node_command)"
    if ! "$node_bin" - "$pm2_json" "$ENV_FILE" "$PM2_NAME" "$DEPLOY_DIR" "$NODE_BIN" "$BACKEND_FILE" <<'NODE'
const fs = require('fs');
const path = require('path');
const [pm2File, envFile, name, expectedCwd, expectedInterpreter, expectedScript] = process.argv.slice(2);
const apps = JSON.parse(fs.readFileSync(pm2File, 'utf8')).filter(app => app.name === name);
if (apps.length !== 1) throw new Error(`expected exactly one PM2 process named ${name}`);
const app = apps[0];
const actualCwd = app.pm2_env?.pm_cwd || path.dirname(app.pm2_env?.pm_exec_path || '');
if (path.resolve(actualCwd) !== path.resolve(expectedCwd)) {
  throw new Error('PM2 cwd changed during import');
}
if (path.resolve(app.pm2_env?.pm_exec_path || '') !== path.resolve(expectedScript)) {
  throw new Error('PM2 script changed during import');
}
const actualInterpreter = app.pm2_env?.exec_interpreter || 'node';
if (actualInterpreter !== 'node' && path.resolve(actualInterpreter) !== path.resolve(expectedInterpreter)) {
  throw new Error('PM2 interpreter changed during import');
}
const env = {};
for (const line of fs.readFileSync(envFile, 'utf8').split(/\r?\n/)) {
  const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!match) continue;
  let value = match[2].trim();
  if (value.startsWith('"') && value.endsWith('"')) {
    try { value = JSON.parse(value); } catch {}
  } else if (value.startsWith("'") && value.endsWith("'")) {
    value = value.slice(1, -1);
  } else {
    value = value.replace(/\s+#.*$/, '').trim();
  }
  env[match[1]] = value;
}
for (const [key, value] of Object.entries(app.pm2_env || {})) {
  if (!key.startsWith('SUB_STORE_') || value == null || value === '') continue;
  if (!(key in env) || env[key] !== String(value)) {
    throw new Error(`${key} in PM2 overrides or differs from .env`);
  }
}
const args = app.pm2_env?.args;
const nodeArgs = app.pm2_env?.node_args;
if ((Array.isArray(args) ? args.length : Boolean(args)) ||
    (Array.isArray(nodeArgs) ? nodeArgs.length : Boolean(nodeArgs))) {
  throw new Error('PM2 args or node_args are not supported for safe import');
}
NODE
    then
        cleanup_tmp_path "$pm2_json"
        log_error "现有 PM2 实例包含未持久化 Env 或额外启动参数，无法安全导入"
        return 1
    fi
    cleanup_tmp_path "$pm2_json"
}

import_existing() {
    local instances="${1:-}" line count selected name file cwd interpreter value existing_status
    prepare_system_tools
    command -v node >/dev/null 2>&1 || die "导入现有 PM2 实例需要可用的 node"
    NODE_BIN="$(command -v node)"
    require_command pm2
    [[ -n "$instances" ]] || instances="$(discover_pm2_instances)"
    [[ -n "$instances" ]] || die "没有检测到 PM2 管理的 sub-store.bundle.js"
    count="$(wc -l <<<"$instances" | tr -d ' ')"
    if (( count > 1 )); then
        printf '%s\n' "$instances" | nl -w2 -s'. '
        selected="$(prompt '选择要导入的实例编号' '1')"
        if [[ ! "$selected" =~ ^[0-9]+$ ]] || (( selected < 1 || selected > count )); then
            die "实例编号无效：$selected"
        fi
        line="$(sed -n "${selected}p" <<<"$instances")"
    else
        line="$instances"
    fi
    IFS=$'\t' read -r name file cwd interpreter <<<"$line"
    validate_pm2_name "$name" || die "PM2 名称不适合安全导入：$name"
    validate_absolute_path "$file" || die "PM2 程序路径无效：$file"
    [[ -f "$file" ]] || die "PM2 程序文件不存在：$file"
    cwd="${cwd:-$(dirname -- "$file")}"
    validate_absolute_path "$cwd" || die "PM2 工作目录无效：$cwd"

    PM2_NAME="$name"
    BACKEND_FILE="$(normalize_path "$file")"
    DEPLOY_DIR="$(normalize_path "$cwd")"
    ENV_FILE="${DEPLOY_DIR}/.env"
    [[ -f "$ENV_FILE" ]] || die "现有部署没有 ${ENV_FILE}，请先确认实际 Env 文件位置"
    value="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_PATH 2>/dev/null || true)"
    FRONTEND_DIR="$(resolve_config_path "$value" "${DEPLOY_DIR}/frontend")"
    value="$(env_get "$ENV_FILE" SUB_STORE_DATA_BASE_PATH 2>/dev/null || true)"
    DATA_DIR="$(resolve_config_path "$value" "$DEPLOY_DIR")"
    PORT="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_PORT 2>/dev/null || printf '3000')"
    HOST="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_HOST 2>/dev/null || printf '::')"
    if [[ "$interpreter" == node ]]; then
        NODE_BIN="$(command -v node)"
    elif NODE_BIN="$(command -v "$interpreter" 2>/dev/null)"; then
        :
    else
        die "PM2 Node 解释器不可用：$interpreter"
    fi
    ECOSYSTEM_FILE="${DEPLOY_DIR}/.substore-manager.ecosystem.config.cjs"
    MARKER_FILE="${DEPLOY_DIR}/.substore-manager-instance"
    validate_env_value SUB_STORE_BACKEND_API_PORT "$PORT" || die "现有部署端口无效：$PORT"
    validate_env_value SUB_STORE_BACKEND_API_HOST "$HOST" || die "现有部署监听地址无效：$HOST"
    validate_runtime_layout || die "现有部署的目录布局不适合安全管理"
    assert_paths_not_managed_elsewhere || die "现有部署路径与其他管理实例冲突"
    assert_identity_not_managed_elsewhere
    [[ -d "$DATA_DIR" ]] || die "现有数据目录不存在：$DATA_DIR"
    [[ -f "$FRONTEND_DIR/index.html" ]] || die "现有前端目录没有 index.html：$FRONTEND_DIR"
    [[ ! -e "${DATA_DIR}/.substore-manager-data" && ! -L "${DATA_DIR}/.substore-manager-data" ]] || \
        die "数据目录已存在管理标记，拒绝覆盖：$DATA_DIR"
    [[ ! -e "$(frontend_marker_path)" && ! -L "$(frontend_marker_path)" ]] || \
        die "前端目录已存在管理标记，拒绝覆盖：$FRONTEND_DIR"
    [[ ! -e "$MARKER_FILE" && ! -L "$MARKER_FILE" ]] || die "部署目录已存在管理标记：$MARKER_FILE"
    [[ ! -e "$ECOSYSTEM_FILE" && ! -L "$ECOSYSTEM_FILE" ]] || \
        die "管理器 PM2 配置路径已存在：$ECOSYSTEM_FILE"
    INSTALL_ID="$(random_hex 16)"
    CREATED_BY_MANAGER=0
    DATA_CREATED_BY_MANAGER=0
    FRONTEND_CREATED_BY_MANAGER=0
    INSTALLED_AT="$(date -Iseconds)"
    BACKEND_VERSION="$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
    FRONTEND_VERSION="unknown"

    if ! confirm "确认导入 PM2 实例 ${PM2_NAME}（${BACKEND_FILE}）" Y; then
        return 0
    fi
    acquire_manager_lock_wait
    acquire_update_lock_wait
    if [[ -f "$STATE_FILE" ]]; then
        release_update_lock
        release_manager_lock
        log_info "实例已由另一个导入过程完成：$INSTANCE_ID"
        return 0
    fi
    assert_paths_not_managed_elsewhere || die "现有部署路径在导入确认后发生冲突"
    assert_identity_not_managed_elsewhere
    validate_runtime_layout || die "现有部署目录布局在导入确认后不再安全"
    [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] || die "现有数据目录不存在或不安全：$DATA_DIR"
    [[ -f "$FRONTEND_DIR/index.html" && ! -L "$FRONTEND_DIR" ]] || \
        die "现有前端目录不存在或不安全：$FRONTEND_DIR"
    [[ ! -e "${DATA_DIR}/.substore-manager-data" && ! -L "${DATA_DIR}/.substore-manager-data" ]] || \
        die "数据目录在导入确认后出现管理标记：$DATA_DIR"
    [[ ! -e "$(frontend_marker_path)" && ! -L "$(frontend_marker_path)" ]] || \
        die "前端目录在导入确认后出现管理标记：$FRONTEND_DIR"
    [[ ! -e "$MARKER_FILE" && ! -L "$MARKER_FILE" ]] || \
        die "部署目录在导入确认后出现管理标记：$MARKER_FILE"
    [[ ! -e "$ECOSYSTEM_FILE" && ! -L "$ECOSYSTEM_FILE" ]] || \
        die "管理器 PM2 配置在导入确认后被占用：$ECOSYSTEM_FILE"
    load_pm2_process_info || die "无法重新读取待导入 PM2 实例"
    assert_pm2_target "$PM2_EXEC_PATH" || die "PM2 入口在导入确认后发生变化"
    existing_status="$PM2_STATUS"
    case "$existing_status" in
        online|stopped) ;;
        *) die "PM2 状态不适合导入：$existing_status" ;;
    esac
    validate_import_pm2_compatibility || die "请先把 PM2 中的 Sub-Store Env/参数迁移到 .env"
    if [[ "$existing_status" == online ]]; then
        if [[ "$BACKEND_VERSION" == unknown ]]; then
            wait_for_health "" || die "现有 PM2 实例未通过健康检查，已取消导入"
        else
            wait_for_health "$BACKEND_VERSION" || die "现有 PM2 实例未通过健康检查，已取消导入"
        fi
    fi
    pm2 save >/dev/null || die "保存 PM2 进程清单失败，已取消导入"
    IMPORT_TRANSACTION_ACTIVE=1
    write_manager_marker "$MARKER_FILE" || die "写入实例管理标记失败"
    mkdir -p -- "$DATA_DIR" "${DEPLOY_DIR}/backups"
    write_manager_marker "${DATA_DIR}/.substore-manager-data" || die "写入数据目录管理标记失败"
    write_frontend_marker
    write_ecosystem
    save_state
    IMPORT_TRANSACTION_ACTIVE=0
    configure_pm2_startup || log_warn "实例已导入，但 PM2 开机启动配置失败"
    install_manager_command || log_warn "实例已导入，但管理命令安装失败：$MANAGER_INSTALL_PATH"
    configure_auto_update_after_install || log_warn "实例已导入，但自动更新配置失败"
    release_update_lock
    release_manager_lock
    log_info "已导入现有实例，不修改程序、数据和 Env"
}

install_or_import() {
    local instances=""
    if load_state; then
        repair_managed_installation
        log_info "实例已纳入管理：$DEPLOY_DIR（PM2 状态：$(pm2_process_status 2>/dev/null || printf 'unknown')）"
        return 0
    fi
    if [[ "${SUBSTORE_NON_INTERACTIVE:-0}" == 1 ]]; then
        new_install
        return 0
    fi
    if command -v pm2 >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
        instances="$(discover_pm2_instances)" || die "检测现有 PM2 Sub-Store 失败"
    fi
    if [[ -n "$instances" ]]; then
        if confirm "检测到现有 PM2 Sub-Store，是否导入管理" Y; then
            import_existing "$instances"
            return 0
        fi
    fi
    new_install
}

create_data_archive() {
    local output="$1" relative_frontend=""
    local -a excludes=()
    [[ -d "$DATA_DIR" ]] || return 1
    if [[ "$DATA_DIR" == "$DEPLOY_DIR" ]]; then
        excludes=(
            --exclude='./backups'
            --exclude="./$(basename -- "$BACKEND_FILE")"
            --exclude="./$(basename -- "$ENV_FILE")"
            --exclude="./$(basename -- "$ECOSYSTEM_FILE")"
            --exclude="./$(basename -- "$MARKER_FILE")"
            --exclude='./.substore-install.*'
            --exclude='./.substore-update.*'
            --exclude='./.substore-frontend-*'
            --exclude='./.substore-data-*'
            --exclude='./.substore-backend.*'
            --exclude='./.substore-uninstall.*'
        )
        if path_contains "$DATA_DIR" "$FRONTEND_DIR" && [[ "$FRONTEND_DIR" != "$DATA_DIR" ]]; then
            relative_frontend="$(realpath --relative-to="$DATA_DIR" "$FRONTEND_DIR")"
            excludes+=(--exclude="./${relative_frontend}")
        fi
    fi
    tar -C "$DATA_DIR" "${excludes[@]}" -czf "$output" . || return 1
    tar -tzf "$output" >/dev/null || return 1
}

deploy_entry_is_managed() {
    local entry="$1" frontend_top=""
    [[ "$entry" == "${DEPLOY_DIR}/backups" || \
        "$entry" == "$BACKEND_FILE" || \
        "$entry" == "$ENV_FILE" || \
        "$entry" == "$ECOSYSTEM_FILE" || \
        "$entry" == "$MARKER_FILE" ]] && return 0
    case "$(basename -- "$entry")" in
        .substore-install.*|.substore-update.*|.substore-frontend-*|.substore-data-*|\
        .substore-backend.*|.substore-uninstall.*|.substore-backup.*) return 0 ;;
    esac
    frontend_top="$(managed_top_level_path "$DEPLOY_DIR" "$FRONTEND_DIR" 2>/dev/null || true)"
    [[ -n "$frontend_top" && "$entry" == "$frontend_top" ]]
}

restore_data_root_from_stage() {
    local restore_dir="$1" parent old_dir entry target move_failed=0 rollback_failed=0
    local -a restored_targets=()
    parent="$(dirname -- "$DEPLOY_DIR")"
    old_dir="$(mktemp -d "${parent}/.substore-data-old.XXXXXX")" || return 1

    while IFS= read -r -d '' entry; do
        target="${DEPLOY_DIR}/$(basename -- "$entry")"
        if deploy_entry_is_managed "$target"; then
            log_error "数据备份包含受保护的部署项：$target"
            rmdir -- "$old_dir" 2>/dev/null || true
            return 1
        fi
        restored_targets+=("$target")
    done < <(find "$restore_dir" -mindepth 1 -maxdepth 1 -print0)

    while IFS= read -r -d '' entry; do
        deploy_entry_is_managed "$entry" && continue
        if ! mv -- "$entry" "$old_dir/"; then
            move_failed=1
            break
        fi
    done < <(find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print0)

    if (( move_failed )); then
        while IFS= read -r -d '' entry; do
            mv -- "$entry" "$DEPLOY_DIR/" 2>/dev/null || rollback_failed=1
        done < <(find "$old_dir" -mindepth 1 -maxdepth 1 -print0)
        rmdir -- "$old_dir" 2>/dev/null || true
        if (( rollback_failed )); then
            log_error "移动现有数据失败，未能全部还原；残留位置：$old_dir"
        fi
        return 1
    fi

    if cp -a "$restore_dir"/. "$DEPLOY_DIR"/; then
        cleanup_tmp_path "$restore_dir"
        rm -rf -- "$old_dir" || log_warn "旧数据目录清理失败，请手工删除：$old_dir"
        return 0
    fi

    for target in "${restored_targets[@]}"; do
        rm -rf -- "$target" 2>/dev/null || rollback_failed=1
    done
    while IFS= read -r -d '' entry; do
        mv -- "$entry" "$DEPLOY_DIR/" 2>/dev/null || rollback_failed=1
    done < <(find "$old_dir" -mindepth 1 -maxdepth 1 -print0)
    rmdir -- "$old_dir" 2>/dev/null || true
    if (( rollback_failed )); then
        log_error "数据目录恢复失败，原数据残留位置：$old_dir"
    fi
    return 1
}

restore_data_archive() {
    local archive="$1" parent restore_dir
    parent="$(dirname -- "$DATA_DIR")"
    make_temp_dir restore_dir "$parent" .substore-data-restore || return 1
    tar -C "$restore_dir" -xzf "$archive" || { cleanup_tmp_path "$restore_dir"; return 1; }
    manager_marker_matches "$restore_dir/.substore-manager-data" || {
        cleanup_tmp_path "$restore_dir"
        log_error "数据备份中的管理标记不匹配"
        return 1
    }
    if [[ "$DATA_DIR" == "$DEPLOY_DIR" ]]; then
        restore_data_root_from_stage "$restore_dir"
        return $?
    fi
    swap_directory_tree "$restore_dir" "$DATA_DIR" data || {
        cleanup_tmp_path "$restore_dir"
        return 1
    }
}

swap_directory_tree() {
    local new_dir="$1" target="$2" label="$3" parent old_dir
    parent="$(dirname -- "$target")"
    old_dir="$(mktemp -d "${parent}/.substore-${label}-old.XXXXXX")" || return 1
    rmdir -- "$old_dir" || return 1
    if [[ -e "$target" ]]; then
        mv -- "$target" "$old_dir" || return 1
    else
        old_dir=""
    fi
    if mv -- "$new_dir" "$target"; then
        unregister_tmp_path "$new_dir"
        if [[ -n "$old_dir" ]]; then
            rm -rf -- "$old_dir" || log_warn "旧目录清理失败，请手工删除：$old_dir"
        fi
        return 0
    fi
    if [[ -n "$old_dir" ]] && ! mv -- "$old_dir" "$target"; then
        log_error "目录切换失败，原目录保留在：$old_dir"
    fi
    return 1
}

install_frontend_tree() {
    local source_dir="$1" replace_existing="${2:-0}" parent next_dir
    [[ -f "$source_dir/index.html" ]] || return 1
    if [[ -e "$FRONTEND_DIR" ]]; then
        assert_frontend_managed || return 1
    fi
    parent="$(dirname -- "$FRONTEND_DIR")"
    make_temp_dir next_dir "$parent" .substore-frontend-next || return 1
    if [[ -d "$FRONTEND_DIR" ]]; then
        chmod --reference="$FRONTEND_DIR" "$next_dir" || { cleanup_tmp_path "$next_dir"; return 1; }
        chown --reference="$FRONTEND_DIR" "$next_dir" || { cleanup_tmp_path "$next_dir"; return 1; }
        if [[ "$replace_existing" != 1 && "$FRONTEND_CREATED_BY_MANAGER" != 1 ]]; then
            cp -a "$FRONTEND_DIR"/. "$next_dir"/ || { cleanup_tmp_path "$next_dir"; return 1; }
        fi
    else
        chmod --reference="$source_dir" "$next_dir" || { cleanup_tmp_path "$next_dir"; return 1; }
        chown --reference="$source_dir" "$next_dir" || { cleanup_tmp_path "$next_dir"; return 1; }
    fi
    cp -a "$source_dir"/. "$next_dir"/ || { cleanup_tmp_path "$next_dir"; return 1; }
    write_manager_marker "$next_dir/.substore-manager-frontend" || { cleanup_tmp_path "$next_dir"; return 1; }
    [[ -f "$next_dir/index.html" ]] || { cleanup_tmp_path "$next_dir"; return 1; }
    swap_directory_tree "$next_dir" "$FRONTEND_DIR" frontend || {
        cleanup_tmp_path "$next_dir"
        return 1
    }
}

create_backup() {
    local label="$1" include_backend="$2" include_frontend="$3"
    local backup_root backup_dir partial_dir
    backup_root="${DEPLOY_DIR}/backups"
    backup_dir="${backup_root}/$(date '+%Y%m%d-%H%M%S')-${label}-$(random_hex 4)"
    mkdir -p -- "$backup_root" || return 1
    partial_dir="$(mktemp -d "${backup_root}/.substore-backup.XXXXXX")" || return 1
    register_tmp "$partial_dir"
    mkdir -p -- "$partial_dir/files" || { cleanup_tmp_path "$partial_dir"; return 1; }
    chmod 700 "$partial_dir" || { cleanup_tmp_path "$partial_dir"; return 1; }
    printf '%s\n' "$INSTALL_ID" >"$partial_dir/.install-id" || { cleanup_tmp_path "$partial_dir"; return 1; }
    chmod 600 "$partial_dir/.install-id" || { cleanup_tmp_path "$partial_dir"; return 1; }

    if [[ "$include_backend" == 1 ]]; then
        if ! manager_marker_matches "${DATA_DIR}/.substore-manager-data"; then
            cleanup_tmp_path "$partial_dir"
            log_error "数据目录管理标记不匹配：$DATA_DIR"
            return 1
        fi
        cp -a "$BACKEND_FILE" "$partial_dir/files/" || { cleanup_tmp_path "$partial_dir"; return 1; }
        create_data_archive "$partial_dir/data.tar.gz" || { cleanup_tmp_path "$partial_dir"; return 1; }
    fi
    if [[ "$include_frontend" == 1 && -d "$FRONTEND_DIR" ]]; then
        assert_frontend_managed || { cleanup_tmp_path "$partial_dir"; return 1; }
        cp -a "$FRONTEND_DIR" "$partial_dir/files/frontend" || { cleanup_tmp_path "$partial_dir"; return 1; }
    fi
    cp -a "$ENV_FILE" "$partial_dir/files/.env" || {
        cleanup_tmp_path "$partial_dir"
        return 1
    }
    cp -a "$ECOSYSTEM_FILE" "$partial_dir/files/ecosystem.config.cjs" || {
        cleanup_tmp_path "$partial_dir"
        return 1
    }
    cp -a "$STATE_FILE" "$partial_dir/files/instance.conf" || {
        cleanup_tmp_path "$partial_dir"
        return 1
    }
    {
        printf 'install_id=%s\n' "$INSTALL_ID"
        printf 'backend_version=%s\n' "$BACKEND_VERSION"
        printf 'frontend_version=%s\n' "$FRONTEND_VERSION"
        printf 'data_dir=%s\n' "$DATA_DIR"
        printf 'include_backend=%s\n' "$include_backend"
        printf 'include_frontend=%s\n' "$include_frontend"
        printf 'created_at=%s\n' "$(date -Iseconds)"
    } >"$partial_dir/manifest" || { cleanup_tmp_path "$partial_dir"; return 1; }
    chmod 600 "$partial_dir/manifest" || { cleanup_tmp_path "$partial_dir"; return 1; }
    [[ ! -f "$partial_dir/data.tar.gz" ]] || chmod 600 "$partial_dir/data.tar.gz" || {
        cleanup_tmp_path "$partial_dir"
        return 1
    }
    mv -- "$partial_dir" "$backup_dir" || { cleanup_tmp_path "$partial_dir"; return 1; }
    unregister_tmp_path "$partial_dir"
    LAST_BACKUP_DIR="$backup_dir"
    log_info "备份完成：$backup_dir"
}

backup_manifest_value() {
    local backup_dir="$1" key="$2"
    sed -n "s/^${key}=//p" "$backup_dir/manifest" | tail -n 1
}

prune_backups() {
    local backup_root="${DEPLOY_DIR}/backups" backup_dir install_id remove_count index
    local -a managed_backups=()
    [[ -d "$backup_root" ]] || return 0
    while IFS= read -r backup_dir; do
        if manager_marker_matches "$backup_dir/.install-id"; then
            rm -rf -- "$backup_dir" || return 1
            log_info "已清理未完成备份：$backup_dir"
        fi
    done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -name '.substore-backup.*' -print)
    while IFS= read -r backup_dir; do
        [[ -f "$backup_dir/manifest" ]] || continue
        install_id="$(backup_manifest_value "$backup_dir" install_id)"
        [[ "$install_id" == "$INSTALL_ID" ]] || continue
        managed_backups+=("$backup_dir")
    done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d ! -name '.substore-backup.*' -print | sort)
    remove_count=$((${#managed_backups[@]} - BACKUP_RETENTION_COUNT))
    (( remove_count > 0 )) || return 0
    for ((index = 0; index < remove_count; index += 1)); do
        backup_dir="${managed_backups[$index]}"
        path_contains "$backup_root" "$backup_dir" || return 1
        rm -rf -- "$backup_dir" || return 1
        log_info "已清理旧备份：$backup_dir"
    done
}

validate_backup() {
    local backup_dir="$1" include_backend include_frontend install_id manifest_data_dir
    [[ -d "$backup_dir/files" && -f "$backup_dir/manifest" ]] || return 1
    [[ -f "$backup_dir/files/.env" && -f "$backup_dir/files/ecosystem.config.cjs" && \
        -f "$backup_dir/files/instance.conf" ]] || return 1
    install_id="$(backup_manifest_value "$backup_dir" install_id)"
    [[ "$install_id" == "$INSTALL_ID" ]] || return 1
    manifest_data_dir="$(backup_manifest_value "$backup_dir" data_dir)"
    [[ "$(normalize_path "$manifest_data_dir")" == "$DATA_DIR" ]] || return 1
    include_backend="$(backup_manifest_value "$backup_dir" include_backend)"
    include_frontend="$(backup_manifest_value "$backup_dir" include_frontend)"
    if [[ "$include_backend" == 1 ]]; then
        [[ -f "$backup_dir/files/$BACKEND_ASSET" && -f "$backup_dir/data.tar.gz" ]] || return 1
        tar -tzf "$backup_dir/data.tar.gz" | awk '
BEGIN { unsafe = 0 }
{
    if ($0 ~ /^\//) unsafe = 1
    count = split($0, parts, "/")
    for (index = 1; index <= count; index += 1) {
        if (parts[index] == "..") unsafe = 1
    }
}
END { exit unsafe }
' || return 1
    fi
    if [[ "$include_frontend" == 1 ]]; then
        [[ -f "$backup_dir/files/frontend/index.html" ]] || return 1
    fi
}

restore_backup() {
    local backup_dir="$1" desired_status="${2:-online}"
    local include_backend include_frontend data_marker backup_backend_version backup_frontend_version health_version
    validate_backup "$backup_dir" || {
        log_error "备份不完整或校验失败：$backup_dir"
        return 1
    }
    include_backend="$(backup_manifest_value "$backup_dir" include_backend)"
    include_frontend="$(backup_manifest_value "$backup_dir" include_frontend)"
    backup_backend_version="$(backup_manifest_value "$backup_dir" backend_version)"
    backup_frontend_version="$(backup_manifest_value "$backup_dir" frontend_version)"
    if [[ "$include_backend" == 1 ]]; then
        data_marker="${DATA_DIR}/.substore-manager-data"
        if ! manager_marker_matches "$data_marker"; then
            log_error "数据目录标记不匹配，拒绝恢复：$DATA_DIR"
            return 1
        fi
    fi
    if [[ "$include_frontend" == 1 ]] && [[ -e "$FRONTEND_DIR" ]]; then
        assert_frontend_managed || return 1
    fi

    log_warn "正在恢复更新前版本"
    if [[ "$include_backend" == 1 ]]; then
        stop_instance 0 || return 1
        install_backend_file "$backup_dir/files/$BACKEND_ASSET" || return 1
    fi
    if [[ "$include_frontend" == 1 ]]; then
        install_frontend_tree "$backup_dir/files/frontend" 1 || return 1
    fi
    cp -a "$backup_dir/files/.env" "$ENV_FILE" || return 1
    cp -a "$backup_dir/files/ecosystem.config.cjs" "$ECOSYSTEM_FILE" || return 1
    if [[ "$include_backend" == 1 ]]; then
        restore_data_archive "$backup_dir/data.tar.gz" || return 1
    fi
    cp -a "$backup_dir/files/instance.conf" "$STATE_FILE" || return 1
    chmod 600 "$STATE_FILE" || return 1
    load_state || return 1
    BACKEND_VERSION="$backup_backend_version"
    FRONTEND_VERSION="$backup_frontend_version"
    save_state || return 1
    health_version="$BACKEND_VERSION"
    [[ "$health_version" != unknown ]] || health_version=""

    if [[ "$include_backend" == 1 ]]; then
        restart_instance 0 || return 1
        if ! wait_for_health "$health_version"; then
            if [[ "$desired_status" == stopped ]]; then
                stop_instance 0 >/dev/null 2>&1 || true
            fi
            return 1
        fi
        if [[ "$desired_status" == stopped ]]; then
            stop_instance 0 || return 1
        fi
    elif [[ "$desired_status" == online ]]; then
        wait_for_health "$health_version" || return 1
    fi
}

rollback_interrupted_update() {
    [[ "$UPDATE_TRANSACTION_ACTIVE" == 1 ]] || return 0
    UPDATE_TRANSACTION_ACTIVE=0
    log_warn "更新事务未完成，正在恢复原状态"
    if [[ -n "$LAST_BACKUP_DIR" && -d "$LAST_BACKUP_DIR" ]]; then
        if restore_backup "$LAST_BACKUP_DIR" "${UPDATE_ORIGINAL_STATUS:-online}"; then
            prune_backups || log_warn "自动恢复后清理旧备份失败：${DEPLOY_DIR}/backups"
        else
            log_error "自动恢复失败，请手工检查备份：$LAST_BACKUP_DIR"
        fi
    elif [[ "$UPDATE_ORIGINAL_STATUS" == online ]]; then
        start_instance || log_error "恢复原 PM2 运行状态失败：$PM2_NAME"
    fi
}

fail_update_with_rollback() {
    local recovered_message="$1" failed_message="$2"
    UPDATE_TRANSACTION_ACTIVE=0
    if restore_backup "$LAST_BACKUP_DIR" "$UPDATE_ORIGINAL_STATUS"; then
        prune_backups || log_warn "回滚后清理旧备份失败：${DEPLOY_DIR}/backups"
        die "$recovered_message"
    fi
    die "$failed_message；备份位于：$LAST_BACKUP_DIR"
}

apply_staged_update() {
    local need_backend="$1" need_frontend="$2" backend_stage="$3" frontend_stage="$4"
    if (( need_backend )); then
        install_backend_file "$backend_stage" || return 1
    fi
    if (( need_frontend )); then
        install_frontend_tree "$frontend_stage" || return 1
    fi
}

update_instance() {
    local stage backend_stage frontend_zip frontend_stage need_backend=0 need_frontend=0
    local original_status
    require_root
    load_state || die "尚未安装或导入 Sub-Store"
    require_command flock
    acquire_manager_lock_wait
    if ! acquire_update_lock; then
        release_manager_lock
        return 0
    fi
    load_state || die "实例状态在等待更新锁期间发生变化"
    prepare_managed_runtime
    sync_state_from_env || die "Env 与管理状态不一致，已拒绝更新"
    original_status="$(pm2_process_status)" || die "无法读取更新前 PM2 状态"
    case "$original_status" in
        online|stopped) ;;
        missing) die "PM2 进程不存在，请先运行 substore start 修复实例" ;;
        *) die "PM2 进程状态不适合更新：$original_status" ;;
    esac
    release_manager_lock

    BACKEND_VERSION="$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
    release_info "$BACKEND_REPO" "$BACKEND_ASSET"
    BACKEND_LATEST="$RELEASE_TAG"
    BACKEND_RELEASE_URL="$RELEASE_URL"
    BACKEND_RELEASE_DIGEST="$RELEASE_DIGEST"
    BACKEND_RELEASE_SIZE="$RELEASE_SIZE"
    release_info "$FRONTEND_REPO" "$FRONTEND_ASSET"
    FRONTEND_LATEST="$RELEASE_TAG"
    FRONTEND_RELEASE_URL="$RELEASE_URL"
    FRONTEND_RELEASE_DIGEST="$RELEASE_DIGEST"
    FRONTEND_RELEASE_SIZE="$RELEASE_SIZE"

    [[ "$BACKEND_VERSION" == "$BACKEND_LATEST" ]] || need_backend=1
    [[ "$FRONTEND_VERSION" == "$FRONTEND_LATEST" ]] || need_frontend=1
    if [[ "${SUBSTORE_MANAGER_TESTING:-0}" == 1 ]]; then
        [[ "${SUBSTORE_MANAGER_TEST_FORCE_BACKEND_UPDATE:-0}" == 1 ]] && need_backend=1
        [[ "${SUBSTORE_MANAGER_TEST_FORCE_FRONTEND_UPDATE:-0}" == 1 ]] && need_frontend=1
    fi
    printf '后端：%s -> %s\n' "$BACKEND_VERSION" "$BACKEND_LATEST"
    printf '前端：%s -> %s\n' "$FRONTEND_VERSION" "$FRONTEND_LATEST"
    if (( need_backend == 0 && need_frontend == 0 )); then
        log_info "已经是最新版本"
        release_update_lock
        return 0
    fi

    prepare_update_tools
    make_temp_dir stage "$DEPLOY_DIR" .substore-update || die "无法创建更新临时目录"
    backend_stage="${stage}/${BACKEND_ASSET}"
    frontend_zip="${stage}/${FRONTEND_ASSET}"
    frontend_stage="${stage}/frontend"
    if (( need_backend )); then
        http_download "$BACKEND_RELEASE_URL" "$backend_stage"
        verify_download "$backend_stage" "$BACKEND_RELEASE_DIGEST" "$BACKEND_RELEASE_SIZE"
        grep -Fqx "// SUB_STORE_BACKEND_VERSION: ${BACKEND_LATEST}" < <(head -n 1 "$backend_stage") || \
            die "后端 bundle 版本校验失败"
    fi
    if (( need_frontend )); then
        http_download "$FRONTEND_RELEASE_URL" "$frontend_zip"
        verify_download "$frontend_zip" "$FRONTEND_RELEASE_DIGEST" "$FRONTEND_RELEASE_SIZE"
        extract_frontend "$frontend_zip" "$frontend_stage"
    fi

    UPDATE_ORIGINAL_STATUS="$original_status"
    LAST_BACKUP_DIR=""
    UPDATE_TRANSACTION_ACTIVE=1

    if (( need_backend )) && [[ "$original_status" == online ]]; then
        stop_instance 0 || die "更新前无法停止 PM2 进程"
    fi
    if ! create_backup "${BACKEND_VERSION}-to-${BACKEND_LATEST}" "$need_backend" "$need_frontend"; then
        UPDATE_TRANSACTION_ACTIVE=0
        if [[ "$original_status" == online ]]; then
            start_instance || die "备份失败，且旧实例恢复运行失败"
        fi
        die "更新前备份失败，未修改程序文件"
    fi
    if ! apply_staged_update "$need_backend" "$need_frontend" "$backend_stage" "$frontend_stage"; then
        fail_update_with_rollback \
            "文件替换失败，已恢复旧版本" \
            "文件替换失败，且自动恢复失败"
    fi

    if (( need_backend )); then
        if ! restart_instance 0 || ! wait_for_health "$BACKEND_LATEST"; then
            fail_update_with_rollback \
                "更新失败，已恢复旧版本" \
                "更新启动或健康检查失败，且自动恢复失败"
        fi
        if [[ "$original_status" == stopped ]]; then
            stop_instance 0 || die "更新成功，但恢复原停止状态失败"
        fi
    elif [[ "$original_status" == online ]] && ! wait_for_health "$BACKEND_VERSION"; then
        fail_update_with_rollback \
            "前端更新失败，已恢复旧版本" \
            "前端更新健康检查失败，且自动恢复失败"
    fi
    BACKEND_VERSION="$BACKEND_LATEST"
    FRONTEND_VERSION="$FRONTEND_LATEST"
    save_state || die "保存更新版本状态失败"
    UPDATE_TRANSACTION_ACTIVE=0
    prune_backups || log_warn "旧备份清理失败，请检查：${DEPLOY_DIR}/backups"
    cleanup_tmp_path "$stage"
    release_update_lock
    log_info "更新完成：后端 $BACKEND_VERSION，前端 $FRONTEND_VERSION"
}

show_envs() {
    local key value display state default_label
    local -A current_values=() current_present=() custom_seen=()
    local -a custom_keys=()
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        current_values["$key"]="$value"
        current_present["$key"]=1
        if [[ -z "${ENV_DESC[$key]:-}" && -z "${custom_seen[$key]:-}" ]]; then
            custom_keys+=("$key")
            custom_seen["$key"]=1
        fi
    done < <(env_list "$ENV_FILE")

    printf '%-4s %-42s %-18s %s\n' 编号 变量 当前值 用途
    local index=1
    for key in "${OFFICIAL_ENV_ORDER[@]}"; do
        if [[ "${current_present[$key]:-0}" == 1 ]]; then
            value="${current_values[$key]}"
            state="$value"
            if [[ "${ENV_SENSITIVE[$key]:-0}" == 1 ]]; then
                state="$(mask_value "$value")"
            fi
            display="$state"
        else
            default_label="$(official_env_default_label "$key")"
            display="<未设置；官方默认 ${default_label}>"
        fi
        printf '%-4s %-42s %-28s %s\n' "$index" "$key" "$display" "${ENV_DESC[$key]}"
        ((index += 1))
    done

    printf '\n自定义 Env：\n'
    for key in "${custom_keys[@]}"; do
        value="${current_values[$key]}"
        if [[ "$key" =~ (TOKEN|SECRET|PASSWORD|KEY) ]]; then
            value="$(mask_value "$value")"
        fi
        printf '  %s=%s\n' "$key" "$value"
    done
}

begin_env_transaction() {
    acquire_manager_lock_wait || return 1
    acquire_update_lock_wait || { release_manager_lock; return 1; }
    load_state || { release_update_lock; release_manager_lock; return 1; }
    ENV_TRANSACTION_BACKUP="$(mktemp)" || { release_update_lock; release_manager_lock; return 1; }
    STATE_TRANSACTION_BACKUP="$(mktemp)" || {
        rm -f -- "$ENV_TRANSACTION_BACKUP"
        ENV_TRANSACTION_BACKUP=""
        release_update_lock
        release_manager_lock
        return 1
    }
    register_tmp "$ENV_TRANSACTION_BACKUP"
    register_tmp "$STATE_TRANSACTION_BACKUP"
    if ! cp -a "$ENV_FILE" "$ENV_TRANSACTION_BACKUP" || \
        ! cp -a "$STATE_FILE" "$STATE_TRANSACTION_BACKUP"; then
        cleanup_tmp_path "$ENV_TRANSACTION_BACKUP"
        cleanup_tmp_path "$STATE_TRANSACTION_BACKUP"
        ENV_TRANSACTION_BACKUP=""
        STATE_TRANSACTION_BACKUP=""
        release_update_lock
        release_manager_lock
        return 1
    fi
    ENV_TRANSACTION_ORIGINAL_DATA_DIR="$DATA_DIR"
    ENV_TRANSACTION_ORIGINAL_FRONTEND_DIR="$FRONTEND_DIR"
    ENV_TRANSACTION_CREATED_DATA_DIR=0
    ENV_TRANSACTION_ACTIVE=1
}

commit_env_transaction() {
    local marker
    if [[ -n "$ENV_TRANSACTION_ORIGINAL_DATA_DIR" && \
        "$ENV_TRANSACTION_ORIGINAL_DATA_DIR" != "$DATA_DIR" ]]; then
        marker="${ENV_TRANSACTION_ORIGINAL_DATA_DIR}/.substore-manager-data"
        if manager_marker_matches "$marker"; then
            rm -f -- "$marker" || log_warn "旧数据目录管理标记清理失败：$marker"
        fi
    fi
    if [[ -n "$ENV_TRANSACTION_ORIGINAL_FRONTEND_DIR" && \
        "$ENV_TRANSACTION_ORIGINAL_FRONTEND_DIR" != "$FRONTEND_DIR" ]]; then
        marker="${ENV_TRANSACTION_ORIGINAL_FRONTEND_DIR}/.substore-manager-frontend"
        if manager_marker_matches "$marker"; then
            rm -f -- "$marker" || log_warn "旧前端目录管理标记清理失败：$marker"
        fi
    fi
    cleanup_tmp_path "$ENV_TRANSACTION_BACKUP"
    cleanup_tmp_path "$STATE_TRANSACTION_BACKUP"
    ENV_TRANSACTION_BACKUP=""
    STATE_TRANSACTION_BACKUP=""
    ENV_TRANSACTION_ACTIVE=0
    ENV_TRANSACTION_ORIGINAL_DATA_DIR=""
    ENV_TRANSACTION_ORIGINAL_FRONTEND_DIR=""
    ENV_TRANSACTION_CREATED_DATA_DIR=0
    release_update_lock
    release_manager_lock
}

rollback_env_transaction() {
    local keep_locks="${1:-0}" new_data="$DATA_DIR" new_frontend="$FRONTEND_DIR" marker result=0
    if [[ ! -f "$ENV_TRANSACTION_BACKUP" || ! -f "$STATE_TRANSACTION_BACKUP" ]]; then
        result=1
    else
        cp -a "$ENV_TRANSACTION_BACKUP" "$ENV_FILE" || result=1
        cp -a "$STATE_TRANSACTION_BACKUP" "$STATE_FILE" || result=1
        chmod 600 "$ENV_FILE" "$STATE_FILE" || result=1
        if (( result == 0 )); then
            load_state || result=1
        fi
    fi

    if (( result == 0 )); then
        if [[ "$new_data" != "$DATA_DIR" ]]; then
            marker="${new_data}/.substore-manager-data"
            if manager_marker_matches "$marker"; then
                if [[ "$ENV_TRANSACTION_CREATED_DATA_DIR" == 1 ]]; then
                    rm -rf -- "$new_data" || result=1
                else
                    rm -f -- "$marker" || result=1
                fi
            fi
        fi
        if [[ "$new_frontend" != "$FRONTEND_DIR" ]]; then
            marker="${new_frontend}/.substore-manager-frontend"
            if manager_marker_matches "$marker"; then
                rm -f -- "$marker" || result=1
            fi
        fi
    fi

    if (( result == 0 )); then
        cleanup_tmp_path "$ENV_TRANSACTION_BACKUP"
        cleanup_tmp_path "$STATE_TRANSACTION_BACKUP"
    else
        unregister_tmp_path "$ENV_TRANSACTION_BACKUP"
        unregister_tmp_path "$STATE_TRANSACTION_BACKUP"
        log_error "Env 事务恢复不完整；备份保留在：$ENV_TRANSACTION_BACKUP 和 $STATE_TRANSACTION_BACKUP"
    fi
    ENV_TRANSACTION_BACKUP=""
    STATE_TRANSACTION_BACKUP=""
    ENV_TRANSACTION_ACTIVE=0
    ENV_TRANSACTION_ORIGINAL_DATA_DIR=""
    ENV_TRANSACTION_ORIGINAL_FRONTEND_DIR=""
    ENV_TRANSACTION_CREATED_DATA_DIR=0
    if [[ "$keep_locks" != 1 ]]; then
        release_update_lock
        release_manager_lock
    fi
    return "$result"
}

validate_env_consistency() {
    local merge backend_prefix magic frontend
    merge="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_MERGE 2>/dev/null || true)"
    backend_prefix="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_PREFIX 2>/dev/null || true)"
    magic="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH 2>/dev/null || true)"
    frontend="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_PATH 2>/dev/null || true)"
    if [[ -n "$merge" || -n "$backend_prefix" ]]; then
        validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH "$magic" || {
            log_error "启用 BACKEND_MERGE 或 BACKEND_PREFIX 时，必须设置有效的 SUB_STORE_FRONTEND_BACKEND_PATH"
            return 1
        }
    fi
    if [[ -n "$merge" && ( -z "$frontend" || ! -f "$frontend/index.html" ) ]]; then
        log_error "启用 BACKEND_MERGE 时，SUB_STORE_FRONTEND_PATH 必须包含 index.html"
        return 1
    fi
}

ensure_backend_path_for_merge() {
    local merge backend_prefix magic live_path entered_path
    merge="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_MERGE 2>/dev/null || true)"
    backend_prefix="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_PREFIX 2>/dev/null || true)"
    [[ -n "$merge" || -n "$backend_prefix" ]] || return 0

    magic="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH 2>/dev/null || true)"
    if validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH "$magic"; then
        return 0
    fi

    live_path="$(pm2_env_get SUB_STORE_FRONTEND_BACKEND_PATH 2>/dev/null || true)"
    if validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH "$live_path"; then
        env_set "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH "$live_path"
        log_info "已从 PM2 当前进程环境补全 SUB_STORE_FRONTEND_BACKEND_PATH"
        return 0
    fi

    read -r -p "当前 .env 缺少后端路径前缀，请输入正在使用的 SUB_STORE_FRONTEND_BACKEND_PATH（必须以 / 开头）: " entered_path
    if ! validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH "$entered_path"; then
        log_error "后端路径前缀必须以 / 开头"
        return 1
    fi
    env_set "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH "$entered_path"
}

select_official_env() {
    local index key
    for index in "${!OFFICIAL_ENV_ORDER[@]}"; do
        key="${OFFICIAL_ENV_ORDER[$index]}"
        printf '%2d. %-42s %s\n' "$((index + 1))" "$key" "${ENV_DESC[$key]}"
    done
    index="$(prompt '变量编号')"
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    (( index >= 1 && index <= ${#OFFICIAL_ENV_ORDER[@]} )) || return 1
    SELECTED_ENV="${OFFICIAL_ENV_ORDER[$((index - 1))]}"
}

restart_after_env_change() {
    local original_status
    if ! sync_state_from_env; then
        rollback_env_transaction || log_error "恢复 Env 事务失败"
        return 1
    fi
    original_status="$(pm2_process_status)" || {
        rollback_env_transaction || true
        return 1
    }
    case "$original_status" in
        online)
            if ! confirm "Env 修改需要重启才能安全生效，是否立即重启" Y; then
                log_warn "已取消修改，避免运行环境与保存状态不一致"
                rollback_env_transaction || log_error "恢复 Env 事务失败"
                return 1
            fi
            if ! restart_instance 0 || ! wait_for_health "$(backend_version_from_file "$BACKEND_FILE" || true)"; then
                log_warn "新 Env 健康检查失败，正在恢复修改前配置"
                if ! rollback_env_transaction 1; then
                    release_update_lock
                    release_manager_lock
                    return 1
                fi
                if ! restart_instance 0 || ! wait_for_health "$(backend_version_from_file "$BACKEND_FILE" || true)"; then
                    log_error "恢复旧 Env 后仍未通过健康检查，请查看 PM2 日志"
                fi
                release_update_lock
                release_manager_lock
                return 1
            fi
            ;;
        stopped)
            log_info "PM2 进程处于停止状态；Env 已保存，将在下次启动时生效"
            ;;
        *)
            log_error "PM2 状态不适合修改 Env：$original_status"
            rollback_env_transaction || log_error "恢复 Env 事务失败"
            return 1
            ;;
    esac
    commit_env_transaction
}

modify_official_env() {
    local key current value old_data candidate marker target_existed=0
    select_official_env || { log_warn "无效编号"; return; }
    key="$SELECTED_ENV"
    current="$(env_get "$ENV_FILE" "$key" 2>/dev/null || true)"
    printf '变量：%s\n用途：%s\n官方默认：%s\n当前值：%s\n' \
        "$key" "${ENV_DESC[$key]}" "$(official_env_default_label "$key")" \
        "$([[ -n "$current" ]] && { [[ "${ENV_SENSITIVE[$key]:-0}" == 1 ]] && mask_value "$current" || printf '%s' "$current"; } || printf '<未设置>')"
    if [[ "${ENV_SENSITIVE[$key]:-0}" == 1 ]]; then
        read -r -s -p "新值（输入不回显）: " value
        printf '\n'
    else
        read -r -p "新值: " value
    fi
    validate_env_value "$key" "$value" || { log_error "值格式不符合 ${ENV_TYPE[$key]} 约束"; return; }

    if [[ "$key" == SUB_STORE_BACKEND_API_PORT ]]; then
        change_port "$value"
        return
    fi

    begin_env_transaction || { log_error "无法创建 Env 事务备份"; return; }

    if [[ "$key" == SUB_STORE_FRONTEND_PATH ]] && ! ensure_backend_path_for_merge; then
        rollback_env_transaction || log_error "恢复 Env 事务失败"
        return
    fi

    if [[ "$key" == SUB_STORE_DATA_BASE_PATH && "$value" != "$DATA_DIR" ]]; then
        old_data="$DATA_DIR"
        candidate="$(normalize_path "$value")"
        [[ -e "$candidate" ]] && target_existed=1 || target_existed=0
        if (( target_existed )); then
            DATA_CREATED_BY_MANAGER=0
        else
            DATA_CREATED_BY_MANAGER=1
            ENV_TRANSACTION_CREATED_DATA_DIR=1
        fi
        DATA_DIR="$candidate"
        if ! validate_runtime_layout || ! assert_paths_not_managed_elsewhere; then
            log_error "新的数据目录布局不安全或与其他实例冲突"
            rollback_env_transaction || log_error "恢复 Env 事务失败"
            return
        fi
        marker="${DATA_DIR}/.substore-manager-data"
        if [[ -e "$marker" || -L "$marker" ]] && ! manager_marker_matches "$marker"; then
            log_error "新的数据目录已有其他管理标记：$DATA_DIR"
            rollback_env_transaction || log_error "恢复 Env 事务失败"
            return
        fi
        mkdir -p -- "$DATA_DIR" || { rollback_env_transaction; return; }
        (( target_existed )) || chmod 700 "$DATA_DIR" || { rollback_env_transaction; return; }
        if [[ -d "$old_data" ]]; then
            if (( target_existed )) && find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
                log_warn "目标数据目录非空，为避免覆盖现有文件，不执行自动复制：$DATA_DIR"
            elif confirm "是否复制现有数据到新目录 $value" Y; then
                cp -a "$old_data"/. "$DATA_DIR"/ || { rollback_env_transaction; return; }
            fi
        fi
        write_manager_marker "$marker" || { rollback_env_transaction; return; }
        value="$DATA_DIR"
    fi
    if [[ "$key" == SUB_STORE_FRONTEND_PATH ]]; then
        candidate="$(normalize_path "$value")"
        if [[ ! -f "$candidate/index.html" ]]; then
            log_error "该目录没有 index.html：$candidate"
            rollback_env_transaction || log_error "恢复 Env 事务失败"
            return
        fi
        FRONTEND_DIR="$candidate"
        FRONTEND_CREATED_BY_MANAGER=0
        if ! validate_runtime_layout || ! assert_paths_not_managed_elsewhere; then
            log_error "新的前端目录布局不安全或与其他实例冲突"
            rollback_env_transaction || log_error "恢复 Env 事务失败"
            return
        fi
        marker="$(frontend_marker_path)"
        if [[ -e "$marker" || -L "$marker" ]] && ! manager_marker_matches "$marker"; then
            log_error "新的前端目录已有其他管理标记：$FRONTEND_DIR"
            rollback_env_transaction || log_error "恢复 Env 事务失败"
            return
        fi
        write_frontend_marker || { rollback_env_transaction; return; }
        value="$FRONTEND_DIR"
    fi
    env_set "$ENV_FILE" "$key" "$value" || { rollback_env_transaction; return; }
    if ! validate_env_consistency; then
        rollback_env_transaction || log_error "恢复 Env 事务失败"
        return
    fi
    restart_after_env_change
}

add_custom_env() {
    local key value
    key="$(prompt '自定义 Env 名称')"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { log_error "Env 名称无效"; return; }
    if [[ -n "${ENV_DESC[$key]:-}" ]]; then
        log_error "这是官方 Env，请使用修改 Env功能"
        return
    fi
    read -r -p "Env 值: " value
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { log_error "不支持多行 Env"; return; }
    begin_env_transaction || { log_error "无法创建 Env 事务备份"; return; }
    env_set "$ENV_FILE" "$key" "$value" || { rollback_env_transaction; return; }
    restart_after_env_change
}

delete_env_interactive() {
    local entries count choice key value
    entries="$(env_list "$ENV_FILE")"
    [[ -n "$entries" ]] || { log_warn "当前没有 Env"; return; }
    printf '%s\n' "$entries" | cut -f1 | nl -w2 -s'. '
    count="$(wc -l <<<"$entries" | tr -d ' ')"
    choice="$(prompt '要删除的编号')"
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
        log_error "编号无效"
        return
    fi
    IFS=$'\t' read -r key value <<<"$(sed -n "${choice}p" <<<"$entries")"
    if [[ "$key" == SUB_STORE_DATA_BASE_PATH ]]; then
        log_error "管理器实例必须保留绝对数据目录；请使用修改 Env 迁移到另一个绝对路径"
        return
    fi
    if [[ "$key" == SUB_STORE_BACKEND_API_PORT ]]; then
        change_port 3000
        return
    fi
    if [[ "$key" =~ ^SUB_STORE_(BACKEND_API_PORT|DATA_BASE_PATH|FRONTEND_PATH|BACKEND_MERGE|FRONTEND_BACKEND_PATH)$ ]]; then
        confirm "删除 $key 会改变当前部署结构，确认继续" N || return
    fi
    begin_env_transaction || { log_error "无法创建 Env 事务备份"; return; }
    env_delete "$ENV_FILE" "$key" || { rollback_env_transaction; return; }
    if ! validate_env_consistency; then
        rollback_env_transaction || log_error "恢复 Env 事务失败"
        return
    fi
    restart_after_env_change
}

reset_official_env() {
    local key default
    select_official_env || { log_warn "无效编号"; return; }
    key="$SELECTED_ENV"
    default="${ENV_DEFAULT[$key]}"
    printf '%s 的官方默认值：%s\n' "$key" "$(official_env_default_label "$key")"
    if [[ "$key" == SUB_STORE_DATA_BASE_PATH ]]; then
        log_error "官方默认值 . 依赖工作目录，不适合持久化管理实例；请保留或修改为绝对路径"
        return
    fi
    confirm "确认恢复官方默认行为" N || return
    if [[ "$key" == SUB_STORE_BACKEND_API_PORT ]]; then
        change_port 3000
        return
    fi
    begin_env_transaction || { log_error "无法创建 Env 事务备份"; return; }
    if [[ "$default" == __UNSET__ ]]; then
        env_delete "$ENV_FILE" "$key" || { rollback_env_transaction; return; }
    else
        env_set "$ENV_FILE" "$key" "$default" || { rollback_env_transaction; return; }
    fi
    if ! validate_env_consistency; then
        rollback_env_transaction || log_error "恢复 Env 事务失败"
        return
    fi
    restart_after_env_change
}

env_menu() {
    require_command flock
    acquire_update_lock_wait
    load_state || die "尚未安装或导入 Sub-Store"
    prepare_managed_runtime
    release_update_lock
    while true; do
        printf '\n%s========== Env 管理 ==========%s\n' "$C_BOLD" "$C_RESET"
        printf '1. 查看当前 Env\n2. 修改 Env\n3. 新增自定义 Env\n4. 删除 Env\n5. 恢复默认值\n0. 返回\n'
        case "$(prompt '请选择')" in
            1) show_envs; pause ;;
            2) modify_official_env; pause ;;
            3) add_custom_env; pause ;;
            4) delete_env_interactive; pause ;;
            5) reset_official_env; pause ;;
            0) return ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

change_port() {
    local new_port old_port original_status port_status
    load_state || die "尚未安装或导入 Sub-Store"
    new_port="${1:-$(prompt '新监听端口' "$PORT")}"
    validate_env_value SUB_STORE_BACKEND_API_PORT "$new_port" || die "端口无效：$new_port"
    [[ "$new_port" == "$PORT" ]] && { log_info "端口未变化"; return; }
    begin_env_transaction || die "无法创建端口修改事务"
    prepare_managed_runtime
    old_port="$PORT"
    [[ "$new_port" == "$old_port" ]] && { commit_env_transaction; log_info "端口未变化"; return; }
    if port_in_use "$new_port"; then
        rollback_env_transaction
        die "端口已被占用：$new_port"
    else
        port_status=$?
        if (( port_status != 1 )); then
            rollback_env_transaction
            die "无法确认监听端口是否可用：$new_port"
        fi
    fi
    original_status="$(pm2_process_status)" || { rollback_env_transaction; die "无法读取 PM2 状态"; }
    case "$original_status" in
        online|stopped) ;;
        *) rollback_env_transaction; die "PM2 状态不适合修改端口：$original_status" ;;
    esac
    PORT="$new_port"
    assert_identity_not_managed_elsewhere
    env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT "$new_port" || {
        rollback_env_transaction
        die "写入新端口失败"
    }
    save_state || { rollback_env_transaction; die "保存新端口状态失败"; }
    if [[ "$original_status" == online ]] && \
        { ! restart_instance 0 || ! wait_for_health "$BACKEND_VERSION"; }; then
        log_warn "新端口启动失败，恢复 $old_port"
        if ! rollback_env_transaction 1; then
            release_update_lock
            release_manager_lock
            die "恢复旧端口配置失败"
        fi
        if ! restart_instance 0 || ! wait_for_health "$BACKEND_VERSION"; then
            log_error "旧端口配置已恢复，但服务未能重新上线"
        fi
        release_update_lock
        release_manager_lock
        return 1
    fi
    commit_env_transaction
    log_info "监听端口已修改为 $PORT"
}

show_config() {
    local magic_path
    load_state || die "尚未安装或导入 Sub-Store"
    magic_path="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH 2>/dev/null || true)"
    printf '管理器版本：%s\n' "$MANAGER_VERSION"
    printf '管理实例：%s\n' "$INSTANCE_ID"
    printf '安装来源：%s\n' "$([[ "$CREATED_BY_MANAGER" == 1 ]] && printf '管理器新建' || printf '导入现有部署')"
    printf '数据目录来源：%s\n' "$([[ "$DATA_CREATED_BY_MANAGER" == 1 ]] && printf '管理器创建' || printf '预先存在或导入')"
    printf '前端目录来源：%s\n' "$([[ "$FRONTEND_CREATED_BY_MANAGER" == 1 ]] && printf '管理器创建' || printf '自定义、预先存在或导入')"
    printf '部署目录：%s\n' "$DEPLOY_DIR"
    printf '后端文件：%s\n' "$BACKEND_FILE"
    printf '前端目录：%s\n' "$FRONTEND_DIR"
    printf '数据目录：%s\n' "$DATA_DIR"
    printf 'Env 文件：%s\n' "$ENV_FILE"
    printf 'PM2 名称：%s\n' "$PM2_NAME"
    printf 'Node 路径：%s\n' "$NODE_BIN"
    printf '监听地址：%s:%s\n' "$HOST" "$PORT"
    printf '后端路径：%s\n' "$([[ -n "$magic_path" ]] && mask_value "$magic_path" || printf '<未设置>')"
    printf '后端版本：%s\n' "$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
    printf '前端版本：%s\n' "$FRONTEND_VERSION"
}

print_instance_summary() {
    local instance_name="$1" state_path="$2"
    if ! state_file_trusted "$state_path"; then
        printf '%-20s %s\n' "$instance_name" '<状态文件权限不安全，已跳过>'
        return 0
    fi
    bash -c '
set -u
source "$1"
version="$(sed -n "1s|^// SUB_STORE_BACKEND_VERSION: ||p" "${BACKEND_FILE:-}" 2>/dev/null | tr -d "\\r\\n")"
printf "%-20s %-24s %-8s %-28s %s\\n" \
  "$2" "${PM2_NAME:-unknown}" "${PORT:-?}" \
  "${DEPLOY_DIR:-unknown}" "${version:-unknown}"
' _ "$state_path" "$instance_name"
}

list_instances() {
    local state_path instance_name
    local -a state_files=()
    require_root
    printf '%-20s %-24s %-8s %-28s %s\n' 实例 PM2名称 端口 部署目录 后端版本
    if [[ -f "${STATE_BASE}/instance.conf" ]]; then
        print_instance_summary default "${STATE_BASE}/instance.conf"
    fi
    shopt -s nullglob
    state_files=("${STATE_BASE}"/instances/*/instance.conf)
    shopt -u nullglob
    for state_path in "${state_files[@]}"; do
        instance_name="$(basename -- "$(dirname -- "$state_path")")"
        print_instance_summary "$instance_name" "$state_path"
    done
}

show_version() {
    load_state || die "尚未安装或导入 Sub-Store"
    printf '当前后端版本：%s\n' "$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
    printf '记录的前端版本：%s\n' "$FRONTEND_VERSION"
    if confirm "是否查询 GitHub 最新版本" Y; then
        require_command flock
        acquire_update_lock_wait
        load_state || die "实例状态不存在"
        prepare_managed_runtime
        release_info "$BACKEND_REPO" "$BACKEND_ASSET"
        printf '最新后端版本：%s\n' "$RELEASE_TAG"
        release_info "$FRONTEND_REPO" "$FRONTEND_ASSET"
        printf '最新前端版本：%s\n' "$RELEASE_TAG"
        release_update_lock
    fi
}

show_status() {
    load_state || die "尚未安装或导入 Sub-Store"
    pm2 show "$PM2_NAME"
    printf '\n监听检查：\n'
    ss -ltnp "sport = :$PORT" 2>/dev/null || true
}

show_logs() {
    load_state || die "尚未安装或导入 Sub-Store"
    pm2 logs "$PM2_NAME" --lines 100
}

start_managed_instance() {
    local original_status port_status expected_version
    require_root
    require_command flock
    acquire_update_lock_wait
    load_state || { release_update_lock; die "实例状态不存在"; }
    prepare_managed_runtime
    expected_version="$(backend_version_from_file "$BACKEND_FILE" || true)"
    original_status="$(pm2_process_status)" || { release_update_lock; return 1; }
    case "$original_status" in
        online) ;;
        missing|stopped|errored)
            if port_in_use "$PORT"; then
                release_update_lock
                log_error "端口已被其他进程占用，未启动 Sub-Store：$PORT"
                return 1
            else
                port_status=$?
                if (( port_status != 1 )); then
                    release_update_lock
                    log_error "无法确认监听端口是否可用：$PORT"
                    return 1
                fi
            fi
            ;;
        *)
            release_update_lock
            log_error "PM2 状态不适合启动：$original_status"
            return 1
            ;;
    esac
    if ! start_instance || ! wait_for_health "$expected_version"; then
        if [[ "$original_status" == missing ]]; then
            delete_pm2_instance >/dev/null 2>&1 || log_error "启动失败后清理 PM2 进程失败：$PM2_NAME"
        elif [[ "$original_status" != online ]]; then
            stop_instance 1 >/dev/null 2>&1 || log_error "启动失败后恢复停止状态失败：$PM2_NAME"
        fi
        release_update_lock
        return 1
    fi
    release_update_lock
}

stop_managed_instance() {
    require_root
    require_command flock
    acquire_update_lock_wait
    load_state || { release_update_lock; die "实例状态不存在"; }
    prepare_pm2_control_runtime
    if ! stop_instance 1; then
        release_update_lock
        return 1
    fi
    release_update_lock
}

restart_managed_instance() {
    local original_status port_status expected_version
    require_root
    require_command flock
    acquire_update_lock_wait
    load_state || { release_update_lock; die "实例状态不存在"; }
    prepare_managed_runtime
    expected_version="$(backend_version_from_file "$BACKEND_FILE" || true)"
    original_status="$(pm2_process_status)" || { release_update_lock; return 1; }
    case "$original_status" in
        online) ;;
        missing|stopped|errored)
            if port_in_use "$PORT"; then
                release_update_lock
                log_error "端口已被其他进程占用，未重启 Sub-Store：$PORT"
                return 1
            else
                port_status=$?
                if (( port_status != 1 )); then
                    release_update_lock
                    log_error "无法确认监听端口是否可用：$PORT"
                    return 1
                fi
            fi
            ;;
        *)
            release_update_lock
            log_error "PM2 状态不适合重启：$original_status"
            return 1
            ;;
    esac
    if ! restart_instance || ! wait_for_health "$expected_version"; then
        if [[ "$original_status" == missing ]]; then
            delete_pm2_instance >/dev/null 2>&1 || log_error "重启失败后清理 PM2 进程失败：$PM2_NAME"
        elif [[ "$original_status" != online ]]; then
            stop_instance 1 >/dev/null 2>&1 || log_error "重启失败后恢复停止状态失败：$PM2_NAME"
        fi
        release_update_lock
        return 1
    fi
    release_update_lock
}

auto_update_units_owned() {
    local service_file="${SYSTEMD_DIR}/${AUTO_UPDATE_SERVICE_NAME}"
    local timer_file="${SYSTEMD_DIR}/${AUTO_UPDATE_TIMER_NAME}" expected_command
    [[ ! -e "$service_file" && ! -e "$timer_file" ]] && return 0
    if [[ "$INSTANCE_ID" == default ]]; then
        expected_command="ExecStart=${MANAGER_INSTALL_PATH} update"
    else
        expected_command="ExecStart=${MANAGER_INSTALL_PATH} --instance ${INSTANCE_ID} update"
    fi
    if [[ -e "$service_file" || -L "$service_file" ]]; then
        [[ -f "$service_file" && ! -L "$service_file" ]] && \
            grep -Fxq "$expected_command" "$service_file" || return 1
    fi
    if [[ -e "$timer_file" || -L "$timer_file" ]]; then
        [[ -f "$timer_file" && ! -L "$timer_file" ]] && \
            grep -Fxq "Unit=${AUTO_UPDATE_SERVICE_NAME}" "$timer_file" || return 1
    fi
}

restore_pm2_after_failed_delete() {
    local original_status="$1" expected_version current_status
    expected_version="$(backend_version_from_file "$BACKEND_FILE" || true)"
    load_pm2_process_info || return 1
    current_status="$PM2_STATUS"
    [[ "$current_status" == missing ]] || assert_pm2_target "$PM2_EXEC_PATH" || return 1
    case "$original_status" in
        missing)
            [[ "$current_status" == missing ]] || delete_pm2_instance
            ;;
        online)
            if [[ "$current_status" != online ]]; then
                start_instance || return 1
            fi
            wait_for_health "$expected_version"
            ;;
        stopped)
            case "$current_status" in
                stopped) return 0 ;;
                missing) start_instance || return 1 ;;
            esac
            stop_instance 1
            ;;
        *) return 1 ;;
    esac
}

stage_uninstall_path() {
    local original="$1" parent staged
    [[ -e "$original" || -L "$original" ]] || return 0
    parent="$(dirname -- "$original")"
    staged="$(mktemp -d "${parent}/.substore-uninstall.XXXXXX")" || return 1
    if ! rmdir -- "$staged"; then
        rm -rf -- "$staged" 2>/dev/null || true
        return 1
    fi
    if ! mv -T -- "$original" "$staged"; then
        return 1
    fi
    UNINSTALL_ORIGINAL_PATHS+=("$original")
    UNINSTALL_STAGED_PATHS+=("$staged")
}

stage_uninstall_path_or_rollback() {
    local path="$1"
    if ! stage_uninstall_path "$path"; then
        rollback_uninstall_transaction || log_error "卸载失败后恢复原实例不完整"
        die "无法暂存待卸载路径，未提交卸载：$path"
    fi
}

rollback_uninstall_transaction() {
    local index original staged result=0
    [[ "$UNINSTALL_TRANSACTION_ACTIVE" == 1 ]] || return 0
    UNINSTALL_TRANSACTION_ACTIVE=0
    for ((index = ${#UNINSTALL_STAGED_PATHS[@]} - 1; index >= 0; index -= 1)); do
        original="${UNINSTALL_ORIGINAL_PATHS[$index]}"
        staged="${UNINSTALL_STAGED_PATHS[$index]}"
        [[ -e "$staged" || -L "$staged" ]] || continue
        if [[ -e "$original" || -L "$original" ]] || ! mv -- "$staged" "$original"; then
            log_error "卸载回滚无法恢复路径：$original（暂存：$staged）"
            result=1
        fi
    done
    if ! restore_pm2_after_failed_delete "$UNINSTALL_ORIGINAL_STATUS"; then
        log_error "卸载回滚无法恢复 PM2 状态：$PM2_NAME"
        result=1
    fi
    if [[ "$AUTO_UPDATE_TRANSACTION_ACTIVE" == 1 ]] && ! rollback_auto_update_transaction; then
        result=1
    fi
    UNINSTALL_ORIGINAL_PATHS=()
    UNINSTALL_STAGED_PATHS=()
    UNINSTALL_ORIGINAL_STATUS=""
    return "$result"
}

commit_uninstall_transaction() {
    local staged
    UNINSTALL_TRANSACTION_ACTIVE=0
    if [[ "$AUTO_UPDATE_TRANSACTION_ACTIVE" == 1 ]]; then
        commit_auto_update_transaction
    fi
    for staged in "${UNINSTALL_STAGED_PATHS[@]}"; do
        if [[ -e "$staged" || -L "$staged" ]]; then
            rm -rf -- "$staged" || log_warn "卸载内容已移出原路径，但暂存文件清理失败：$staged"
        fi
    done
    UNINSTALL_ORIGINAL_PATHS=()
    UNINSTALL_STAGED_PATHS=()
    UNINSTALL_ORIGINAL_STATUS=""
}

validate_uninstall_preconditions() {
    local remove_data="$1" status marker
    if ! validate_absolute_path "$DEPLOY_DIR" || ! validate_absolute_path "$DATA_DIR" || \
        ! validate_absolute_path "$FRONTEND_DIR"; then
        log_error "卸载状态包含不安全路径"
        return 1
    fi
    validate_runtime_layout || {
        log_error "卸载状态中的目录布局不安全"
        return 1
    }
    assert_paths_not_managed_elsewhere || return 1
    assert_identity_not_managed_elsewhere
    if ! manager_marker_matches "$MARKER_FILE"; then
        log_error "部署目录实例标记不匹配：$MARKER_FILE"
        return 1
    fi
    load_pm2_process_info || return 1
    status="$PM2_STATUS"
    case "$status" in online|stopped|missing) ;; *) log_error "PM2 状态不适合安全卸载：$status"; return 1 ;; esac
    [[ "$status" == missing ]] || assert_pm2_target "$PM2_EXEC_PATH" || return 1
    auto_update_units_owned || {
        log_error "自动更新 unit 不属于当前实例，拒绝删除"
        return 1
    }
    marker="$(frontend_marker_path)"
    if [[ "$FRONTEND_CREATED_BY_MANAGER" == 1 ]]; then
        if ! manager_marker_matches "$marker"; then
            log_error "前端目录管理标记不匹配：$FRONTEND_DIR"
            return 1
        fi
    elif [[ -e "$marker" || -L "$marker" ]] && ! manager_marker_matches "$marker"; then
        log_error "前端目录存在其他实例的管理标记：$FRONTEND_DIR"
        return 1
    fi
    if [[ "$remove_data" == 1 ]]; then
        marker="${DATA_DIR}/.substore-manager-data"
        if [[ "$DATA_CREATED_BY_MANAGER" != 1 ]] || ! manager_marker_matches "$marker"; then
            log_error "数据目录不满足安全删除条件：$DATA_DIR"
            return 1
        fi
    else
        marker="${DATA_DIR}/.substore-manager-data"
        if [[ -e "$marker" || -L "$marker" ]] && ! manager_marker_matches "$marker"; then
            log_error "数据目录存在其他实例或不安全的管理标记：$DATA_DIR"
            return 1
        fi
    fi
}

uninstall_instance() {
    local remove_data=0 data_marker frontend_marker original_status
    require_root
    load_state || die "尚未安装或导入 Sub-Store"
    printf '将卸载 PM2 实例：%s\n部署目录：%s\n前端目录：%s\n数据目录：%s\n备份目录：%s\n' \
        "$PM2_NAME" "$DEPLOY_DIR" "$FRONTEND_DIR" "$DATA_DIR" "${DEPLOY_DIR}/backups"
    if [[ "$CREATED_BY_MANAGER" != 1 ]]; then
        printf '说明：这是导入实例，卸载仍会从 PM2 删除该进程，但保留程序、Env、前端和数据。\n'
    fi
    confirm "确认卸载此实例" N || return 0
    if confirm "同时永久删除持久化数据" N; then
        read -r -p "请输入 DELETE ${INSTALL_ID} 确认: " answer
        [[ "$answer" == "DELETE ${INSTALL_ID}" ]] || die "确认文本不匹配，已取消"
        remove_data=1
    fi

    acquire_manager_lock_wait
    acquire_update_lock_wait
    load_state || die "实例状态在等待卸载锁期间发生变化"
    prepare_pm2_control_runtime
    validate_uninstall_preconditions "$remove_data" || die "卸载前安全检查失败"
    original_status="$PM2_STATUS"
    remove_auto_update_units 1 || die "停用自动更新失败，已取消卸载"
    UNINSTALL_ORIGINAL_STATUS="$original_status"
    UNINSTALL_TRANSACTION_ACTIVE=1
    if ! delete_pm2_instance; then
        rollback_uninstall_transaction || log_error "删除 PM2 后恢复原实例不完整"
        die "删除 PM2 实例失败，未删除程序和数据"
    fi

    if [[ "$CREATED_BY_MANAGER" == 1 ]]; then
        stage_uninstall_path_or_rollback "$BACKEND_FILE"
        stage_uninstall_path_or_rollback "$ENV_FILE"
        stage_uninstall_path_or_rollback "$ECOSYSTEM_FILE"
        if [[ "$FRONTEND_CREATED_BY_MANAGER" == 1 ]]; then
            stage_uninstall_path_or_rollback "$FRONTEND_DIR"
        else
            frontend_marker="$(frontend_marker_path)"
            stage_uninstall_path_or_rollback "$frontend_marker"
            log_info "自定义或预先存在的前端目录已保留：$FRONTEND_DIR"
        fi
        if (( remove_data )); then
            stage_uninstall_path_or_rollback "$DATA_DIR"
            stage_uninstall_path_or_rollback "${DEPLOY_DIR}/backups"
        elif [[ -d "${DEPLOY_DIR}/backups" ]]; then
            data_marker="${DATA_DIR}/.substore-manager-data"
            stage_uninstall_path_or_rollback "$data_marker"
            log_info "数据未删除，更新备份也已保留：${DEPLOY_DIR}/backups"
        else
            data_marker="${DATA_DIR}/.substore-manager-data"
            stage_uninstall_path_or_rollback "$data_marker"
        fi
        stage_uninstall_path_or_rollback "$MARKER_FILE"
    else
        frontend_marker="$(frontend_marker_path)"
        data_marker="${DATA_DIR}/.substore-manager-data"
        stage_uninstall_path_or_rollback "$ECOSYSTEM_FILE"
        stage_uninstall_path_or_rollback "$frontend_marker"
        stage_uninstall_path_or_rollback "$data_marker"
        stage_uninstall_path_or_rollback "$MARKER_FILE"
        log_info "导入实例的程序、Env、前端和数据均已保留"
    fi
    stage_uninstall_path_or_rollback "$STATE_FILE"
    commit_uninstall_transaction
    rmdir -- "$DEPLOY_DIR" 2>/dev/null || true
    rmdir -- "$STATE_ROOT" 2>/dev/null || true
    if [[ "$INSTANCE_ID" != default ]]; then
        rmdir -- "${STATE_BASE}/instances" 2>/dev/null || true
    fi
    release_update_lock
    release_manager_lock
    log_info "卸载完成；系统 Node.js、全局 PM2 和其他 PM2 进程未被删除"
}

manager_menu() {
    while true; do
        load_state >/dev/null 2>&1 || true
        printf '\n%s========== Sub-Store Manager ==========%s\n\n' "$C_BOLD" "$C_RESET"
        if (( INSTALL_PRESENT )); then
            printf '管理实例：%s | PM2：%s | %s:%s | 后端 %s\n\n' \
                "$INSTANCE_ID" "$PM2_NAME" "$HOST" "$PORT" "$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
        else
            printf '管理实例：%s | 当前状态：未安装或未导入\n\n' "$INSTANCE_ID"
        fi
        cat <<'EOF'
1. 安装 Sub-Store
2. 更新 Sub-Store
3. 启动 Sub-Store
4. 停止 Sub-Store
5. 重启 Sub-Store
6. 查看运行状态
7. 查看 PM2 日志
8. 修改监听端口
9. 管理 Env
10. 查看当前配置
11. 查看当前版本
12. 卸载 Sub-Store
13. 自动更新设置
14. 查看全部管理实例
0. 退出
EOF
        case "$(prompt '请选择')" in
            1) install_or_import; pause ;;
            2) update_instance; pause ;;
            3) start_managed_instance; pause ;;
            4) stop_managed_instance; pause ;;
            5) restart_managed_instance; pause ;;
            6) show_status; pause ;;
            7) show_logs ;;
            8) change_port; pause ;;
            9) env_menu ;;
            10) show_config; pause ;;
            11) show_version; pause ;;
            12) uninstall_instance; pause ;;
            13) auto_update_menu ;;
            14) list_instances; pause ;;
            0) return ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

usage() {
    cat <<EOF
Sub-Store Node.js + PM2 Manager ${MANAGER_VERSION}

Usage:
  substore.sh [--instance 名称] [命令]
  substore.sh                 default 实例的交互式管理菜单
  substore.sh --instance foo  foo 实例的交互式管理菜单
  substore.sh install         安装或导入现有实例
  substore.sh update          更新后端与前端
  substore.sh start|stop|restart
  substore.sh status|logs
  substore.sh port [新端口]
  substore.sh env             Env 管理菜单
  substore.sh config|version
  substore.sh auto            自动更新设置
  substore.sh instances       查看全部管理实例
  substore.sh uninstall
EOF
}

main() {
    init_env_catalog
    case "${1:-menu}" in
        menu) manager_menu ;;
        install) install_or_import ;;
        update) update_instance ;;
        start) start_managed_instance ;;
        stop) stop_managed_instance ;;
        restart) restart_managed_instance ;;
        status) load_state && show_status ;;
        logs) load_state && show_logs ;;
        port) require_root; change_port "${2:-}" ;;
        env) require_root; env_menu ;;
        config) show_config ;;
        version) show_version ;;
        auto) require_root; auto_update_menu ;;
        instances) list_instances ;;
        uninstall) uninstall_instance ;;
        --help|-h|help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

if [[ "${SUBSTORE_MANAGER_LIBRARY_ONLY:-0}" != 1 ]]; then
    main "$@"
fi

#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

MANAGER_VERSION="1.0.0"
BACKEND_REPO="sub-store-org/Sub-Store"
FRONTEND_REPO="sub-store-org/Sub-Store-Front-End"
BACKEND_ASSET="sub-store.bundle.js"
FRONTEND_ASSET="dist.zip"
STATE_ROOT="${SUBSTORE_MANAGER_STATE_DIR:-/etc/substore-manager}"
STATE_FILE="${STATE_ROOT}/instance.conf"
MANAGER_INSTALL_PATH="${SUBSTORE_MANAGER_INSTALL_PATH:-/usr/local/sbin/substore}"
GITHUB_API_BASE="${SUBSTORE_MANAGER_GITHUB_API_BASE:-https://api.github.com}"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

INSTALL_PRESENT=0
CREATED_BY_MANAGER=""
DATA_CREATED_BY_MANAGER=""
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
    for path in "${TMP_PATHS[@]:-}"; do
        if [[ -n "$path" && -e "$path" ]]; then
            rm -rf -- "$path"
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

shell_quote() {
    printf '%q' "$1"
}

stat_mode() {
    stat -c '%a' "$1"
}

stat_owner() {
    stat -c '%u' "$1"
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

make_temp_dir() {
    local parent="$1" template="$2" result
    mkdir -p -- "$parent"
    result="$(mktemp -d "${parent}/${template}.XXXXXX")"
    register_tmp "$result"
    printf '%s' "$result"
}

validate_absolute_path() {
    local value="$1"
    [[ "$value" == /* && "$value" != / && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

safe_remove_managed_path() {
    local path="$1" marker="$2"
    validate_absolute_path "$path" || die "拒绝删除不安全路径：$path"
    [[ -f "$marker" ]] || die "缺少管理标记，拒绝删除：$path"
    grep -Fxq "$INSTALL_ID" "$marker" || die "管理标记不匹配，拒绝删除：$path"
    rm -rf -- "$path"
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
            [[ "$value" =~ ^/[A-Za-z0-9._~-]+$ ]]
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
    mkdir -p -- "$(dirname -- "$file")"
    touch "$file"
    chmod 600 "$file"
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
fs.writeFileSync(file, `${next.join('\n')}\n`, { mode: 0o600 });
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
fs.writeFileSync(file, `${next.join('\n')}\n`, { mode: 0o600 });
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
    local temp
    mkdir -p -- "$STATE_ROOT"
    chmod 700 "$STATE_ROOT"
    temp="${STATE_FILE}.tmp.$$"
    {
        printf 'STATE_VERSION=1\n'
        printf 'CREATED_BY_MANAGER=%s\n' "$(shell_quote "$CREATED_BY_MANAGER")"
        printf 'DATA_CREATED_BY_MANAGER=%s\n' "$(shell_quote "$DATA_CREATED_BY_MANAGER")"
        printf 'INSTALL_ID=%s\n' "$(shell_quote "$INSTALL_ID")"
        printf 'DEPLOY_DIR=%s\n' "$(shell_quote "$DEPLOY_DIR")"
        printf 'BACKEND_FILE=%s\n' "$(shell_quote "$BACKEND_FILE")"
        printf 'FRONTEND_DIR=%s\n' "$(shell_quote "$FRONTEND_DIR")"
        printf 'DATA_DIR=%s\n' "$(shell_quote "$DATA_DIR")"
        printf 'ENV_FILE=%s\n' "$(shell_quote "$ENV_FILE")"
        printf 'ECOSYSTEM_FILE=%s\n' "$(shell_quote "$ECOSYSTEM_FILE")"
        printf 'MARKER_FILE=%s\n' "$(shell_quote "$MARKER_FILE")"
        printf 'PM2_NAME=%s\n' "$(shell_quote "$PM2_NAME")"
        printf 'PORT=%s\n' "$(shell_quote "$PORT")"
        printf 'HOST=%s\n' "$(shell_quote "$HOST")"
        printf 'BACKEND_VERSION=%s\n' "$(shell_quote "$BACKEND_VERSION")"
        printf 'FRONTEND_VERSION=%s\n' "$(shell_quote "$FRONTEND_VERSION")"
        printf 'NODE_BIN=%s\n' "$(shell_quote "$NODE_BIN")"
        printf 'INSTALLED_AT=%s\n' "$(shell_quote "$INSTALLED_AT")"
    } >"$temp"
    chmod 600 "$temp"
    mv -f -- "$temp" "$STATE_FILE"
}

load_state() {
    INSTALL_PRESENT=0
    [[ -f "$STATE_FILE" ]] || return 1
    if [[ "${SUBSTORE_MANAGER_SKIP_STATE_SECURITY:-0}" != 1 ]]; then
        [[ "$(stat_owner "$STATE_FILE")" == 0 ]] || die "状态文件不是 root 所有：$STATE_FILE"
        case "$(stat_mode "$STATE_FILE")" in
            600|400) ;;
            *) die "状态文件权限必须是 600 或 400：$STATE_FILE" ;;
        esac
    fi
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    DATA_CREATED_BY_MANAGER="${DATA_CREATED_BY_MANAGER:-0}"
    [[ -n "$INSTALL_ID" && -n "$DEPLOY_DIR" && -n "$PM2_NAME" ]] || die "状态文件不完整：$STATE_FILE"
    [[ -f "$MARKER_FILE" ]] || die "实例标记不存在：$MARKER_FILE"
    grep -Fxq "$INSTALL_ID" "$MARKER_FILE" || die "实例标记与状态文件不匹配"
    INSTALL_PRESENT=1
    return 0
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
    for command_name in curl gpg unzip tar xz ss ps sha256sum; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done
    (( missing == 1 )) || return 0
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        apt-transport-https ca-certificates curl gnupg unzip tar xz-utils iproute2 procps
}

curl_args() {
    CURL_ARGS=(
        --fail
        --silent
        --show-error
        --location
        --retry 3
        --retry-delay 2
        --connect-timeout 10
        --max-time 300
        --header "User-Agent: substore-manager/${MANAGER_VERSION}"
    )
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        CURL_ARGS+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
}

http_download() {
    local url="$1" output="$2"
    curl_args
    curl "${CURL_ARGS[@]}" --output "$output" "$url"
}

official_node_version() {
    local value
    value="$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/${BACKEND_REPO}/master/.node-version")"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法读取官方 .node-version"
    printf '%s' "$value"
}

ensure_node() {
    local official_version node_major installed_major setup_script
    official_version="$(official_node_version)"
    node_major="${official_version%%.*}"

    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        installed_major="$(node -p 'process.versions.node.split(".")[0]')"
        if (( installed_major == node_major )); then
            NODE_BIN="$(command -v node)"
            log_info "复用现有 Node.js $(node -v)"
            return 0
        fi
        log_warn "当前 Node.js 主版本为 ${installed_major}，将使用 NodeSource setup_${node_major}.x 配置安装通道"
    fi

    [[ "${SUBSTORE_MANAGER_SKIP_NODE_INSTALL:-0}" != 1 ]] || die "测试模式禁止安装 Node.js"
    setup_script="$(mktemp)"
    register_tmp "$setup_script"
    curl -fsSL --retry 3 "https://deb.nodesource.com/setup_${node_major}.x" -o "$setup_script"
    bash -n "$setup_script" || die "NodeSource setup_${node_major}.x 语法检查失败"
    log_info "执行 NodeSource setup_${node_major}.x 一键配置脚本"
    bash "$setup_script"
    apt-get install -y nodejs
    hash -r
    command -v node >/dev/null 2>&1 || die "NodeSource 安装完成后仍找不到 node"
    command -v npm >/dev/null 2>&1 || die "NodeSource 安装完成后仍找不到 npm"
    NODE_BIN="$(command -v node)"
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
    pm2 startup systemd -u root --hp /root >/dev/null
    log_info "已配置 PM2 systemd 开机启动"
}

release_info() {
    local repo="$1" asset="$2" json_file parsed node_bin
    json_file="$(mktemp)"
    register_tmp "$json_file"
    curl_args
    curl "${CURL_ARGS[@]}" \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$json_file" \
        "${GITHUB_API_BASE}/repos/${repo}/releases/latest"
    node_bin="$(node_command)"
    parsed="$("$node_bin" - "$json_file" "$asset" <<'NODE'
const fs = require('fs');
const [file, assetName] = process.argv.slice(2);
const release = JSON.parse(fs.readFileSync(file, 'utf8'));
const asset = (release.assets || []).find(item => item.name === assetName);
if (!release.tag_name) throw new Error('latest release has no tag_name');
if (!asset) throw new Error(`release ${release.tag_name} has no ${assetName}`);
process.stdout.write([
  release.tag_name,
  asset.browser_download_url,
  asset.digest || '',
  String(asset.size || '')
].join('\t'));
NODE
)"
    IFS=$'\t' read -r RELEASE_TAG RELEASE_URL RELEASE_DIGEST RELEASE_SIZE <<<"$parsed"
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
    if [[ "$digest" == sha256:* ]]; then
        actual="sha256:$(sha256_file "$file")"
        [[ "$actual" == "$digest" ]] || die "SHA-256 校验失败：$file"
    else
        log_warn "GitHub Release 未提供 SHA-256：$file"
    fi
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
    unpack_dir="$(make_temp_dir "$(dirname -- "$destination")" .substore-frontend-unpack)"
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
}

backend_version_from_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    sed -n '1s|^// SUB_STORE_BACKEND_VERSION: ||p' "$file" | tr -d '\r\n'
}

write_ecosystem() {
    local node_bin
    node_bin="$(node_command)"
    "$node_bin" - "$ECOSYSTEM_FILE" "$PM2_NAME" "$BACKEND_FILE" "$DEPLOY_DIR" "$NODE_BIN" <<'NODE'
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
fs.writeFileSync(file, `module.exports = ${JSON.stringify(config, null, 2)};\n`, { mode: 0o600 });
NODE
    chmod 600 "$ECOSYSTEM_FILE"
}

pm2_process_exists() {
    pm2 jlist 2>/dev/null | "$(node_command)" -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const name = process.argv[1];
  process.exit(JSON.parse(input).some(app => app.name === name) ? 0 : 1);
});
' "$PM2_NAME"
}

pm2_process_online() {
    pm2 jlist 2>/dev/null | "$(node_command)" -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const name = process.argv[1];
  const apps = JSON.parse(input).filter(app => app.name === name);
  process.exit(apps.length > 0 && apps.every(app => app.pm2_env?.status === "online") ? 0 : 1);
});
' "$PM2_NAME"
}

start_instance() {
    if pm2_process_exists; then
        pm2 start "$PM2_NAME" >/dev/null
    else
        pm2 start "$ECOSYSTEM_FILE" --only "$PM2_NAME" >/dev/null
    fi
    pm2 save >/dev/null
}

stop_instance() {
    if pm2_process_exists; then
        pm2 stop "$PM2_NAME" >/dev/null
    fi
}

restart_instance() {
    if pm2_process_exists; then
        pm2 restart "$PM2_NAME" >/dev/null
    else
        pm2 start "$ECOSYSTEM_FILE" --only "$PM2_NAME" >/dev/null
    fi
    pm2 save >/dev/null
}

delete_pm2_instance() {
    if pm2_process_exists; then
        pm2 delete "$PM2_NAME" >/dev/null
        pm2 save >/dev/null
    fi
}

health_host() {
    case "$HOST" in
        ::) printf '%s' '[::1]' ;;
        0.0.0.0) printf '%s' '127.0.0.1' ;;
        localhost) printf '%s' '127.0.0.1' ;;
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

port_is_listening() {
    ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .
}

wait_for_health() {
    local expected_version="${1:-}" deadline response_file url node_bin
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
        if pm2_process_online && port_is_listening && \
            curl --noproxy '*' --fail --silent --show-error --max-time 5 "$url" -o "$response_file" 2>/dev/null && \
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
            return 0
        fi
        sleep 1
    done
    log_error "健康检查失败：$url"
    return 1
}

write_initial_env() {
    local magic_path="$1"
    : >"$ENV_FILE"
    chmod 600 "$ENV_FILE"
    env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT "$PORT"
    env_set "$ENV_FILE" SUB_STORE_BACKEND_API_HOST "$HOST"
    env_set "$ENV_FILE" SUB_STORE_BACKEND_MERGE true
    env_set "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH "$magic_path"
    env_set "$ENV_FILE" SUB_STORE_FRONTEND_PATH "$FRONTEND_DIR"
    env_set "$ENV_FILE" SUB_STORE_DATA_BASE_PATH "$DATA_DIR"
    env_set "$ENV_FILE" SUB_STORE_CORS_ALLOWED_ORIGINS '*'
}

sync_state_from_env() {
    local value
    value="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_PORT 2>/dev/null || true)"
    PORT="${value:-3000}"
    value="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_HOST 2>/dev/null || true)"
    HOST="${value:-::}"
    value="$(env_get "$ENV_FILE" SUB_STORE_DATA_BASE_PATH 2>/dev/null || true)"
    [[ -z "$value" ]] || DATA_DIR="$value"
    value="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_PATH 2>/dev/null || true)"
    [[ -z "$value" ]] || FRONTEND_DIR="$value"
    save_state
}

port_in_use() {
    local port="$1"
    ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
}

validate_pm2_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

prepare_runtime() {
    require_root
    detect_os
    ensure_base_packages
    ensure_node
    require_command sha256sum
    require_command ss
    require_command unzip
    ensure_pm2
}

install_manager_command() {
    if [[ "$SCRIPT_PATH" != "$MANAGER_INSTALL_PATH" ]]; then
        install -m 0755 "$SCRIPT_PATH" "$MANAGER_INSTALL_PATH"
        log_info "管理命令已安装：$MANAGER_INSTALL_PATH"
    fi
}

new_install() {
    local default_deploy default_data default_magic_path magic_path stage backend_stage frontend_zip frontend_stage
    prepare_runtime

    default_deploy="${SUBSTORE_INSTALL_DIR:-/opt/sub-store}"
    default_magic_path="/$(random_hex 16)"
    if [[ "${SUBSTORE_NON_INTERACTIVE:-0}" == 1 ]]; then
        DEPLOY_DIR="$default_deploy"
        PORT="${SUBSTORE_PORT:-3000}"
        PM2_NAME="${SUBSTORE_PM2_NAME:-sub-store}"
        HOST="${SUBSTORE_HOST:-127.0.0.1}"
        DATA_DIR="${SUBSTORE_DATA_DIR:-${DEPLOY_DIR}/data}"
        magic_path="${SUBSTORE_MAGIC_PATH:-$default_magic_path}"
    else
        DEPLOY_DIR="$(prompt '部署目录' "$default_deploy")"
        PORT="$(prompt '监听端口' "${SUBSTORE_PORT:-3000}")"
        PM2_NAME="$(prompt 'PM2 进程名称' "${SUBSTORE_PM2_NAME:-sub-store}")"
        HOST="$(prompt '监听地址' "${SUBSTORE_HOST:-127.0.0.1}")"
        default_data="${DEPLOY_DIR}/data"
        DATA_DIR="$(prompt '持久化数据目录' "${SUBSTORE_DATA_DIR:-$default_data}")"
        magic_path="$(prompt '后端路径前缀（SUB_STORE_FRONTEND_BACKEND_PATH）' "$default_magic_path")"
    fi

    validate_absolute_path "$DEPLOY_DIR" || die "部署目录必须是安全的绝对路径"
    validate_absolute_path "$DATA_DIR" || die "数据目录必须是安全的绝对路径"
    validate_env_value SUB_STORE_BACKEND_API_PORT "$PORT" || die "端口无效：$PORT"
    validate_env_value SUB_STORE_BACKEND_API_HOST "$HOST" || die "监听地址无效：$HOST"
    validate_env_value SUB_STORE_FRONTEND_BACKEND_PATH "$magic_path" || \
        die "后端路径前缀必须以 / 开头，且只能包含字母、数字、点、下划线、波浪号和连字符"
    validate_pm2_name "$PM2_NAME" || die "PM2 名称只能包含字母、数字、点、下划线和连字符"

    if [[ -e "$DEPLOY_DIR" ]] && find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "部署目录非空且不属于当前管理实例：$DEPLOY_DIR"
    fi
    if pm2_process_exists; then
        die "PM2 进程名已存在：$PM2_NAME"
    fi
    if port_in_use "$PORT"; then
        die "端口已被占用：$PORT"
    fi

    BACKEND_FILE="${DEPLOY_DIR}/${BACKEND_ASSET}"
    FRONTEND_DIR="${DEPLOY_DIR}/frontend"
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
    INSTALLED_AT="$(date -Iseconds)"
    NODE_BIN="$(command -v node)"

    mkdir -p -- "$DEPLOY_DIR" "$DATA_DIR" "${DEPLOY_DIR}/backups"
    chmod 755 "$DEPLOY_DIR"
    chmod 700 "$DATA_DIR" "${DEPLOY_DIR}/backups"
    printf '%s\n' "$INSTALL_ID" >"$MARKER_FILE"
    chmod 600 "$MARKER_FILE"
    printf '%s\n' "$INSTALL_ID" >"${DATA_DIR}/.substore-manager-data"
    chmod 600 "${DATA_DIR}/.substore-manager-data"

    stage="$(make_temp_dir "$DEPLOY_DIR" .substore-install)"
    backend_stage="${stage}/${BACKEND_ASSET}"
    frontend_zip="${stage}/${FRONTEND_ASSET}"
    frontend_stage="${stage}/frontend"
    log_info "下载官方后端 Release"
    download_backend_release "$backend_stage"
    log_info "下载官方前端 Release"
    download_frontend_release "$frontend_zip"
    extract_frontend "$frontend_zip" "$frontend_stage"

    install -m 0644 "$backend_stage" "$BACKEND_FILE"
    mkdir -p "$FRONTEND_DIR"
    cp -a "$frontend_stage"/. "$FRONTEND_DIR"/
    write_initial_env "$magic_path"
    write_ecosystem

    BACKEND_VERSION="$BACKEND_LATEST"
    FRONTEND_VERSION="$FRONTEND_LATEST"
    save_state

    start_instance
    if ! wait_for_health "$BACKEND_VERSION"; then
        pm2 logs "$PM2_NAME" --lines 100 --nostream >&2 || true
        delete_pm2_instance
        die "首次启动失败，文件保留在 $DEPLOY_DIR 便于检查"
    fi
    configure_pm2_startup
    pm2 save >/dev/null
    install_manager_command

    log_info "Sub-Store 安装完成"
    printf '部署目录：%s\n' "$DEPLOY_DIR"
    printf '数据目录：%s\n' "$DATA_DIR"
    printf 'PM2 名称：%s\n' "$PM2_NAME"
    printf '后端版本：%s\n' "$BACKEND_VERSION"
    printf '前端版本：%s\n' "$FRONTEND_VERSION"
    printf '本机健康检查：http://%s:%s%s\n' "$(health_host)" "$PORT" "$(health_path)"
}

discover_pm2_instances() {
    # shellcheck disable=SC2016
    pm2 jlist 2>/dev/null | "$(node_command)" -e '
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
    process.stdout.write([
      app.name,
      file,
      app.pm2_env?.pm_cwd || "",
      app.pm2_env?.exec_interpreter || "node"
    ].join("\t") + "\n");
  }
});
'
}

import_existing() {
    local instances line count selected name file cwd interpreter value
    prepare_runtime
    instances="$(discover_pm2_instances)"
    [[ -n "$instances" ]] || die "没有检测到 PM2 管理的 sub-store.bundle.js"
    count="$(wc -l <<<"$instances" | tr -d ' ')"
    if (( count > 1 )); then
        printf '%s\n' "$instances" | nl -w2 -s'. '
        selected="$(prompt '选择要导入的实例编号' '1')"
        line="$(sed -n "${selected}p" <<<"$instances")"
    else
        line="$instances"
    fi
    IFS=$'\t' read -r name file cwd interpreter <<<"$line"
    [[ -f "$file" ]] || die "PM2 程序文件不存在：$file"
    cwd="${cwd:-$(dirname -- "$file")}"
    validate_absolute_path "$cwd" || die "PM2 工作目录无效：$cwd"

    PM2_NAME="$name"
    BACKEND_FILE="$file"
    DEPLOY_DIR="$cwd"
    ENV_FILE="${DEPLOY_DIR}/.env"
    [[ -f "$ENV_FILE" ]] || die "现有部署没有 ${ENV_FILE}，请先确认实际 Env 文件位置"
    value="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_PATH 2>/dev/null || true)"
    FRONTEND_DIR="${value:-${DEPLOY_DIR}/frontend}"
    value="$(env_get "$ENV_FILE" SUB_STORE_DATA_BASE_PATH 2>/dev/null || true)"
    DATA_DIR="${value:-$DEPLOY_DIR}"
    PORT="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_PORT 2>/dev/null || printf '3000')"
    HOST="$(env_get "$ENV_FILE" SUB_STORE_BACKEND_API_HOST 2>/dev/null || printf '::')"
    NODE_BIN="$interpreter"
    [[ "$NODE_BIN" == node ]] && NODE_BIN="$(command -v node)"
    ECOSYSTEM_FILE="${DEPLOY_DIR}/ecosystem.config.cjs"
    MARKER_FILE="${DEPLOY_DIR}/.substore-manager-instance"
    INSTALL_ID="$(random_hex 16)"
    CREATED_BY_MANAGER=0
    DATA_CREATED_BY_MANAGER=0
    INSTALLED_AT="$(date -Iseconds)"
    BACKEND_VERSION="$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
    FRONTEND_VERSION="unknown"

    if ! confirm "确认导入 PM2 实例 ${PM2_NAME}（${BACKEND_FILE}）" Y; then
        return 0
    fi
    if [[ -e "$ECOSYSTEM_FILE" ]]; then
        cp -a "$ECOSYSTEM_FILE" "${ECOSYSTEM_FILE}.before-substore-manager"
    fi
    printf '%s\n' "$INSTALL_ID" >"$MARKER_FILE"
    chmod 600 "$MARKER_FILE"
    mkdir -p -- "$DATA_DIR" "${DEPLOY_DIR}/backups"
    printf '%s\n' "$INSTALL_ID" >"${DATA_DIR}/.substore-manager-data"
    chmod 600 "${DATA_DIR}/.substore-manager-data"
    write_ecosystem
    save_state
    install_manager_command
    log_info "已导入现有实例，不修改程序、数据和 Env"
}

install_or_import() {
    if load_state; then
        log_info "已安装实例：$DEPLOY_DIR"
        return 0
    fi
    if command -v pm2 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && [[ -n "$(discover_pm2_instances 2>/dev/null || true)" ]]; then
        if confirm "检测到现有 PM2 Sub-Store，是否导入管理" Y; then
            import_existing
            return 0
        fi
    fi
    new_install
}

create_backup() {
    local label="$1" backup_dir data_parent data_name
    backup_dir="${DEPLOY_DIR}/backups/$(date '+%Y%m%d-%H%M%S')-${label}"
    mkdir -p -- "$backup_dir/files" || return 1
    chmod 700 "$backup_dir" || return 1
    cp -a "$BACKEND_FILE" "$backup_dir/files/" || return 1
    if [[ -d "$FRONTEND_DIR" ]]; then
        cp -a "$FRONTEND_DIR" "$backup_dir/files/frontend" || return 1
    fi
    cp -a "$ENV_FILE" "$ECOSYSTEM_FILE" "$STATE_FILE" "$backup_dir/files/" || return 1
    data_parent="$(dirname -- "$DATA_DIR")"
    data_name="$(basename -- "$DATA_DIR")"
    tar -C "$data_parent" -czf "$backup_dir/data.tar.gz" "$data_name" || return 1
    {
        printf 'backend_version=%s\n' "$BACKEND_VERSION"
        printf 'frontend_version=%s\n' "$FRONTEND_VERSION"
        printf 'data_dir=%s\n' "$DATA_DIR"
        printf 'created_at=%s\n' "$(date -Iseconds)"
    } >"$backup_dir/manifest" || return 1
    chmod 600 "$backup_dir/manifest" "$backup_dir/data.tar.gz" || return 1
    LAST_BACKUP_DIR="$backup_dir"
    log_info "备份完成：$backup_dir"
}

restore_backup() {
    local backup_dir="$1" data_marker data_parent
    log_warn "正在恢复更新前版本"
    stop_instance || true
    install -m 0644 "$backup_dir/files/$BACKEND_ASSET" "$BACKEND_FILE" || return 1
    if [[ -d "$backup_dir/files/frontend" ]]; then
        rm -rf -- "$FRONTEND_DIR" || return 1
        mkdir -p -- "$FRONTEND_DIR" || return 1
        cp -a "$backup_dir/files/frontend"/. "$FRONTEND_DIR"/ || return 1
    fi
    cp -a "$backup_dir/files/.env" "$ENV_FILE" || return 1
    cp -a "$backup_dir/files/ecosystem.config.cjs" "$ECOSYSTEM_FILE" || return 1
    data_marker="${DATA_DIR}/.substore-manager-data"
    if [[ ! -f "$data_marker" ]] || ! grep -Fxq "$INSTALL_ID" "$data_marker"; then
        die "数据目录标记不匹配，拒绝自动清空恢复"
    fi
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
    data_parent="$(dirname -- "$DATA_DIR")"
    tar -C "$data_parent" -xzf "$backup_dir/data.tar.gz" || return 1
    BACKEND_VERSION="$(sed -n 's/^backend_version=//p' "$backup_dir/manifest")"
    FRONTEND_VERSION="$(sed -n 's/^frontend_version=//p' "$backup_dir/manifest")"
    save_state || return 1
    restart_instance || return 1
    wait_for_health "$BACKEND_VERSION"
}

apply_staged_update() {
    local need_backend="$1" need_frontend="$2" backend_stage="$3" frontend_stage="$4"
    if (( need_backend )); then
        install -m 0644 "$backend_stage" "$BACKEND_FILE" || return 1
    fi
    if (( need_frontend )); then
        rm -rf -- "$FRONTEND_DIR" || return 1
        mkdir -p -- "$FRONTEND_DIR" || return 1
        cp -a "$frontend_stage"/. "$FRONTEND_DIR"/ || return 1
    fi
}

update_instance() {
    local stage backend_stage frontend_zip frontend_stage need_backend=0 need_frontend=0
    require_root
    load_state || die "尚未安装或导入 Sub-Store"
    prepare_runtime

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
    printf '后端：%s -> %s\n' "$BACKEND_VERSION" "$BACKEND_LATEST"
    printf '前端：%s -> %s\n' "$FRONTEND_VERSION" "$FRONTEND_LATEST"
    if (( need_backend == 0 && need_frontend == 0 )); then
        log_info "已经是最新版本"
        return 0
    fi

    stage="$(make_temp_dir "$DEPLOY_DIR" .substore-update)"
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

    stop_instance
    if ! create_backup "${BACKEND_VERSION}-to-${BACKEND_LATEST}"; then
        start_instance || true
        die "更新前备份失败，旧实例已重新启动"
    fi
    if ! apply_staged_update "$need_backend" "$need_frontend" "$backend_stage" "$frontend_stage"; then
        if ! restore_backup "$LAST_BACKUP_DIR"; then
            die "文件替换失败，且自动恢复失败，请使用备份：$LAST_BACKUP_DIR"
        fi
        die "文件替换失败，已恢复旧版本"
    fi

    restart_instance
    if ! wait_for_health "$BACKEND_LATEST"; then
        if ! restore_backup "$LAST_BACKUP_DIR"; then
            die "更新健康检查失败，且自动恢复失败，请使用备份：$LAST_BACKUP_DIR"
        fi
        die "更新失败，已尝试恢复旧版本"
    fi
    BACKEND_VERSION="$BACKEND_LATEST"
    FRONTEND_VERSION="$FRONTEND_LATEST"
    sync_state_from_env
    log_info "更新完成：后端 $BACKEND_VERSION，前端 $FRONTEND_VERSION"
}

show_envs() {
    local key value display state default_label
    printf '%-4s %-42s %-18s %s\n' 编号 变量 当前值 用途
    local index=1
    for key in "${OFFICIAL_ENV_ORDER[@]}"; do
        if value="$(env_get "$ENV_FILE" "$key" 2>/dev/null)"; then
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
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        if [[ -z "${ENV_DESC[$key]:-}" ]]; then
            if [[ "$key" =~ (TOKEN|SECRET|PASSWORD|KEY) ]]; then
                value="$(mask_value "$value")"
            fi
            printf '  %s=%s\n' "$key" "$value"
        fi
    done < <(env_list "$ENV_FILE")
}

begin_env_transaction() {
    ENV_TRANSACTION_BACKUP="$(mktemp)"
    STATE_TRANSACTION_BACKUP="$(mktemp)"
    register_tmp "$ENV_TRANSACTION_BACKUP"
    register_tmp "$STATE_TRANSACTION_BACKUP"
    cp -a "$ENV_FILE" "$ENV_TRANSACTION_BACKUP"
    cp -a "$STATE_FILE" "$STATE_TRANSACTION_BACKUP"
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
    sync_state_from_env
    if confirm "Env 已保存，是否立即重启 Sub-Store" Y; then
        restart_instance
        if ! wait_for_health "$(backend_version_from_file "$BACKEND_FILE" || true)"; then
            log_warn "新 Env 健康检查失败，正在恢复修改前配置"
            cp -a "$ENV_TRANSACTION_BACKUP" "$ENV_FILE"
            cp -a "$STATE_TRANSACTION_BACKUP" "$STATE_FILE"
            load_state
            restart_instance
            wait_for_health "$(backend_version_from_file "$BACKEND_FILE" || true)" || \
                log_error "恢复旧 Env 后仍未通过健康检查，请查看 PM2 日志"
            return 1
        fi
    fi
}

modify_official_env() {
    local key current value old_data
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

    begin_env_transaction

    if [[ "$key" == SUB_STORE_DATA_BASE_PATH && "$value" != "$DATA_DIR" ]]; then
        old_data="$DATA_DIR"
        if [[ -e "$value" ]]; then
            DATA_CREATED_BY_MANAGER=0
        else
            DATA_CREATED_BY_MANAGER=1
        fi
        mkdir -p -- "$value"
        chmod 700 "$value"
        if [[ -d "$old_data" ]] && confirm "是否复制现有数据到新目录 $value" Y; then
            cp -a "$old_data"/. "$value"/
        fi
        printf '%s\n' "$INSTALL_ID" >"${value}/.substore-manager-data"
        chmod 600 "${value}/.substore-manager-data"
    fi
    if [[ "$key" == SUB_STORE_FRONTEND_PATH && ! -f "$value/index.html" ]]; then
        log_error "该目录没有 index.html：$value"
        return
    fi
    env_set "$ENV_FILE" "$key" "$value"
    if ! validate_env_consistency; then
        cp -a "$ENV_TRANSACTION_BACKUP" "$ENV_FILE"
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
    begin_env_transaction
    env_set "$ENV_FILE" "$key" "$value"
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
    begin_env_transaction
    env_delete "$ENV_FILE" "$key"
    if ! validate_env_consistency; then
        cp -a "$ENV_TRANSACTION_BACKUP" "$ENV_FILE"
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
    begin_env_transaction
    if [[ "$default" == __UNSET__ ]]; then
        env_delete "$ENV_FILE" "$key"
    else
        env_set "$ENV_FILE" "$key" "$default"
    fi
    if ! validate_env_consistency; then
        cp -a "$ENV_TRANSACTION_BACKUP" "$ENV_FILE"
        return
    fi
    restart_after_env_change
}

env_menu() {
    load_state || die "尚未安装或导入 Sub-Store"
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
    local new_port old_port
    load_state || die "尚未安装或导入 Sub-Store"
    old_port="$PORT"
    new_port="${1:-$(prompt '新监听端口' "$PORT")}"
    validate_env_value SUB_STORE_BACKEND_API_PORT "$new_port" || die "端口无效：$new_port"
    [[ "$new_port" == "$old_port" ]] && { log_info "端口未变化"; return; }
    if port_in_use "$new_port"; then
        die "端口已被占用：$new_port"
    fi
    env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT "$new_port"
    PORT="$new_port"
    save_state
    restart_instance
    if ! wait_for_health "$BACKEND_VERSION"; then
        log_warn "新端口启动失败，恢复 $old_port"
        env_set "$ENV_FILE" SUB_STORE_BACKEND_API_PORT "$old_port"
        PORT="$old_port"
        save_state
        restart_instance
        wait_for_health "$BACKEND_VERSION" || true
        return 1
    fi
    log_info "监听端口已修改为 $PORT"
}

show_config() {
    local magic_path
    load_state || die "尚未安装或导入 Sub-Store"
    magic_path="$(env_get "$ENV_FILE" SUB_STORE_FRONTEND_BACKEND_PATH 2>/dev/null || true)"
    printf '管理器版本：%s\n' "$MANAGER_VERSION"
    printf '安装来源：%s\n' "$([[ "$CREATED_BY_MANAGER" == 1 ]] && printf '管理器新建' || printf '导入现有部署')"
    printf '数据目录来源：%s\n' "$([[ "$DATA_CREATED_BY_MANAGER" == 1 ]] && printf '管理器创建' || printf '预先存在或导入')"
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

show_version() {
    load_state || die "尚未安装或导入 Sub-Store"
    printf '当前后端版本：%s\n' "$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
    printf '记录的前端版本：%s\n' "$FRONTEND_VERSION"
    if confirm "是否查询 GitHub 最新版本" Y; then
        prepare_runtime
        release_info "$BACKEND_REPO" "$BACKEND_ASSET"
        printf '最新后端版本：%s\n' "$RELEASE_TAG"
        release_info "$FRONTEND_REPO" "$FRONTEND_ASSET"
        printf '最新前端版本：%s\n' "$RELEASE_TAG"
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

uninstall_instance() {
    local remove_data=0 data_marker
    require_root
    load_state || die "尚未安装或导入 Sub-Store"
    printf '将卸载 PM2 实例：%s\n部署目录：%s\n数据目录：%s\n' "$PM2_NAME" "$DEPLOY_DIR" "$DATA_DIR"
    confirm "确认卸载此实例" N || return 0
    if confirm "同时永久删除持久化数据" N; then
        read -r -p "请输入 DELETE ${INSTALL_ID} 确认: " answer
        [[ "$answer" == "DELETE ${INSTALL_ID}" ]] || die "确认文本不匹配，已取消"
        [[ "$DATA_CREATED_BY_MANAGER" == 1 ]] || die "数据目录不是由管理器创建，拒绝自动删除：$DATA_DIR"
        remove_data=1
    fi

    delete_pm2_instance
    if (( remove_data )); then
        data_marker="${DATA_DIR}/.substore-manager-data"
        safe_remove_managed_path "$DATA_DIR" "$data_marker"
    fi

    if [[ "$CREATED_BY_MANAGER" == 1 ]]; then
        rm -f -- "$BACKEND_FILE" "$ENV_FILE" "$ECOSYSTEM_FILE" "$MARKER_FILE"
        rm -rf -- "$FRONTEND_DIR" "${DEPLOY_DIR}/backups"
        rmdir -- "$DEPLOY_DIR" 2>/dev/null || true
    else
        rm -f -- "$ECOSYSTEM_FILE" "$MARKER_FILE"
        log_info "导入实例的程序、Env、前端和数据均已保留"
    fi
    rm -f -- "$STATE_FILE"
    rmdir -- "$STATE_ROOT" 2>/dev/null || true
    log_info "卸载完成；系统 Node.js、全局 PM2 和其他 PM2 进程未被删除"
}

manager_menu() {
    while true; do
        load_state >/dev/null 2>&1 || true
        printf '\n%s========== Sub-Store Manager ==========%s\n\n' "$C_BOLD" "$C_RESET"
        if (( INSTALL_PRESENT )); then
            printf '当前实例：%s | %s:%s | 后端 %s\n\n' \
                "$PM2_NAME" "$HOST" "$PORT" "$(backend_version_from_file "$BACKEND_FILE" || printf 'unknown')"
        else
            printf '当前状态：未纳入管理\n\n'
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
0. 退出
EOF
        case "$(prompt '请选择')" in
            1) install_or_import; pause ;;
            2) update_instance; pause ;;
            3) load_state && start_instance && wait_for_health "$BACKEND_VERSION"; pause ;;
            4) load_state && stop_instance; pause ;;
            5) load_state && restart_instance && wait_for_health "$BACKEND_VERSION"; pause ;;
            6) show_status; pause ;;
            7) show_logs ;;
            8) change_port; pause ;;
            9) env_menu ;;
            10) show_config; pause ;;
            11) show_version; pause ;;
            12) uninstall_instance; pause ;;
            0) return ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

usage() {
    cat <<EOF
Sub-Store Node.js + PM2 Manager ${MANAGER_VERSION}

Usage:
  substore.sh                 交互式管理菜单
  substore.sh install         安装或导入现有实例
  substore.sh update          更新后端与前端
  substore.sh start|stop|restart
  substore.sh status|logs
  substore.sh port [新端口]
  substore.sh env             Env 管理菜单
  substore.sh config|version
  substore.sh uninstall
EOF
}

main() {
    init_env_catalog
    case "${1:-menu}" in
        menu) manager_menu ;;
        install) install_or_import ;;
        update) update_instance ;;
        start) require_root; load_state && start_instance && wait_for_health "$BACKEND_VERSION" ;;
        stop) require_root; load_state && stop_instance ;;
        restart) require_root; load_state && restart_instance && wait_for_health "$BACKEND_VERSION" ;;
        status) load_state && show_status ;;
        logs) load_state && show_logs ;;
        port) require_root; change_port "${2:-}" ;;
        env) require_root; env_menu ;;
        config) show_config ;;
        version) show_version ;;
        uninstall) uninstall_instance ;;
        --help|-h|help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

if [[ "${SUBSTORE_MANAGER_LIBRARY_ONLY:-0}" != 1 ]]; then
    main "$@"
fi

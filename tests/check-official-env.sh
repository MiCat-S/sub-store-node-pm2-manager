#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

curl -fsSL --retry 3 \
    https://github.com/sub-store-org/Sub-Store/archive/refs/heads/master.tar.gz \
    -o "$TMP_ROOT/backend.tar.gz"
curl -fsSL --retry 3 \
    https://github.com/sub-store-org/Sub-Store-Front-End/archive/refs/heads/master.tar.gz \
    -o "$TMP_ROOT/frontend.tar.gz"
tar -xzf "$TMP_ROOT/backend.tar.gz" -C "$TMP_ROOT"
tar -xzf "$TMP_ROOT/frontend.tar.gz" -C "$TMP_ROOT"

backend_dir="$(find "$TMP_ROOT" -maxdepth 1 -type d -name 'Sub-Store-*' ! -name '*Front-End*' -print -quit)"
frontend_dir="$(find "$TMP_ROOT" -maxdepth 1 -type d -name 'Sub-Store-Front-End-*' -print -quit)"

grep -Rho 'SUB_STORE_[A-Z0-9_]\+' \
    "$backend_dir/backend/src/restful/index.js" \
    "$backend_dir/backend/src/vendor/open-api.js" \
    "$backend_dir/backend/src/vendor/express.js" \
    "$backend_dir/backend/src/utils/cors.js" \
    "$backend_dir/backend/src/utils/download.js" \
    "$backend_dir/backend/src/utils/flow.js" \
    "$backend_dir/backend/src/utils/geo.js" \
    "$backend_dir/backend/src/utils/gist.js" \
    | grep -Ev '^(SUB_STORE_BACKEND_CRON|SUB_STORE_CRON)$' \
    | sort -u >"$TMP_ROOT/source-env.txt"

grep -Rho 'SUB_STORE_BACKEND_CUSTOM_\(NAME\|ICON\)' "$frontend_dir/src" \
    | sort -u >>"$TMP_ROOT/source-env.txt"
sort -u -o "$TMP_ROOT/source-env.txt" "$TMP_ROOT/source-env.txt"

sed -n '/OFFICIAL_ENV_ORDER=(/,/^    )/p' "$ROOT/substore.sh" \
    | grep -o 'SUB_STORE_[A-Z0-9_]*' \
    | sort -u >"$TMP_ROOT/manager-env.txt"

if ! diff -u "$TMP_ROOT/source-env.txt" "$TMP_ROOT/manager-env.txt"; then
    printf 'Official Env catalog drift detected. Review upstream source and update metadata.\n' >&2
    exit 1
fi

printf 'PASS: manager Env catalog matches current official backend/frontend source\n'

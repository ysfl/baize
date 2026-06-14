#!/bin/sh
set -eu

api_base="${WEB_API_BASE_URL:-/api/v1}"
config_file="/usr/share/nginx/html/baize-api.config.js"

case "$api_base" in
  http://*|https://*|/*) ;;
  *)
    api_base="/$api_base"
    ;;
esac

case "$api_base" in
  *"'"*|*"\\"*)
    echo "[baize-web] WEB_API_BASE_URL contains unsupported quote or backslash" >&2
    exit 1
    ;;
esac

cat >"$config_file" <<EOF
window.__BAIZE_API_CONFIG__ = Object.freeze({
  apiBaseUrl: '$api_base',
});
EOF

echo "[baize-web] wrote runtime API config: $api_base"

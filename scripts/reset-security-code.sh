#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
ENV_FILE="$ROOT_DIR/.env"
NEW_CODE="${BAIZE_NEW_SECURITY_CODE:-}"
YES=0
NO_RESTART=0
LANGUAGE="${BAIZE_LANG:-}"

log() {
  echo "[reset-security-code] $*" >&2
}

die() {
  echo "[reset-security-code] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/reset-security-code.sh [选项]

选项:
  --security-code <code>  新高敏操作安全码，至少 24 个字符。不推荐在共享终端使用
  --yes                  非交互确认，适合自动化脚本
  --no-restart           只更新 .env，不立即重建中心服务
  --lang <zh|en>         提示语言，默认读取 BAIZE_LANG，未配置时为 zh
  -h, --help             显示帮助

说明:
  该脚本用于重置主机画像刷新、命令历史明文查看等高敏操作的安全码。
  脚本会在 .env 中保存安全码哈希并清空明文项，随后重建中心服务使新配置生效。

English:
  Reset the high-sensitivity operation security code. The script stores a hash
  in .env, clears the plaintext value, and recreates the control service.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --security-code)
      NEW_CODE="${2:-}"
      [[ -n "$NEW_CODE" ]] || die "--security-code 不能为空"
      shift 2
      ;;
    --yes|--non-interactive)
      YES=1
      shift
      ;;
    --no-restart)
      NO_RESTART=1
      shift
      ;;
    --lang)
      LANGUAGE="${2:-}"
      [[ -n "$LANGUAGE" ]] || die "--lang 不能为空"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

read_env() {
  baize_strip_env_quotes "$(baize_read_env "$1" "$ENV_FILE")"
}

tr_text() {
  baize_text "$LANGUAGE" "$1" "$2"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$(tr_text "缺少命令: $1" "missing command: $1")"
}

validate_security_code() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$(tr_text "安全码不能包含换行符" "security code must not contain line breaks")"
  (( ${#value} >= 24 )) || die "$(tr_text "安全码长度不足，至少 24 个字符" "security code is too short; minimum length is 24")"
}

prompt_secret_twice() {
  local label="$1"
  local first=""
  local second=""
  [[ -r /dev/tty ]] || die "$(tr_text "当前环境不可交互，请通过 BAIZE_NEW_SECURITY_CODE 并追加 --yes" "non-interactive shell; pass BAIZE_NEW_SECURITY_CODE and add --yes")"

  printf "%s: " "$label" >/dev/tty
  stty -echo </dev/tty
  IFS= read -r first </dev/tty || {
    stty echo </dev/tty
    die "$(tr_text "读取输入失败" "failed to read input")"
  }
  stty echo </dev/tty
  printf "\n" >/dev/tty

  printf "%s: " "$(tr_text "再次输入新安全码" "Repeat new security code")" >/dev/tty
  stty -echo </dev/tty
  IFS= read -r second </dev/tty || {
    stty echo </dev/tty
    die "$(tr_text "读取输入失败" "failed to read input")"
  }
  stty echo </dev/tty
  printf "\n" >/dev/tty

  [[ "$first" == "$second" ]] || die "$(tr_text "两次输入不一致" "the two security codes do not match")"
  printf '%s' "$first"
}

confirm_action() {
  local prompt="$1"
  local value=""
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "$(tr_text "当前环境不可交互，请确认后追加 --yes" "non-interactive shell; confirm by adding --yes")"
  printf "%s [y/N]: " "$prompt" >/dev/tty
  IFS= read -r value </dev/tty || die "$(tr_text "读取输入失败" "failed to read input")"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ "$value" == "y" || "$value" == "yes" || "$value" == "是" ]]
}

wait_for_postgres() {
  local timeout="${1:-120}"
  local start now
  start="$(date +%s)"
  while true; do
    if baize_compose "$DEPLOY_MODE" exec -T postgres pg_isready -U "$postgres_user" -d "$postgres_db" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      baize_compose "$DEPLOY_MODE" logs --tail=120 postgres >&2 || true
      die "$(tr_text "PostgreSQL 等待超时，无法生成安全码哈希" "timed out waiting for PostgreSQL; cannot generate the security-code hash")"
    fi
    sleep 2
  done
}

sql_literal() {
  local value="$1"
  local escaped
  escaped="$(printf '%s' "$value" | sed "s/'/''/g")"
  printf "'%s'" "$escaped"
}

env_literal_single_quoted() {
  local value="$1"
  local escaped
  escaped="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$escaped"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local tmp mode
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || die "$(tr_text "无法创建临时文件" "failed to create a temporary file")"
  mode="$(stat -f "%Lp" "$ENV_FILE" 2>/dev/null || stat -c "%a" "$ENV_FILE" 2>/dev/null || printf '600')"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ /^[[:space:]]*#/ { print; next }
    index($0, key "=") == 1 {
      print key "=" value
      done = 1
      next
    }
    { print }
    END {
      if (done == 0) {
        print key "=" value
      }
    }
  ' "$ENV_FILE" >"$tmp"
  chmod "$mode" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

cd "$ROOT_DIR"

[[ -f "$ENV_FILE" ]] || die "$(tr_text "缺少 .env，请在白泽安装目录中执行" "missing .env; run this from your Baize installation directory")"
LANGUAGE="${LANGUAGE:-$(baize_resolve_language "$ENV_FILE")}"
case "$LANGUAGE" in
  zh|en) ;;
  *) die "不支持的语言 / unsupported language: $LANGUAGE" ;;
esac

if [[ -z "$NEW_CODE" ]]; then
  NEW_CODE="$(prompt_secret_twice "$(tr_text "输入新高敏操作安全码" "Enter new security code")")"
fi
validate_security_code "$NEW_CODE"

confirm_action "$(tr_text "确认重置高敏操作安全码" "Reset the high-sensitivity operation security code")" || die "$(tr_text "已取消" "cancelled")"

require_cmd docker
docker compose version >/dev/null 2>&1 || die "$(tr_text "Docker Compose v2 不可用" "Docker Compose v2 is unavailable")"

postgres_user="$(read_env POSTGRES_USER)"
postgres_db="$(read_env POSTGRES_DB)"
[[ -n "$postgres_user" ]] || die "POSTGRES_USER $(tr_text "未配置" "is not configured")"
[[ -n "$postgres_db" ]] || die "POSTGRES_DB $(tr_text "未配置" "is not configured")"
DEPLOY_MODE="$(baize_resolve_deploy_mode "$ENV_FILE")"

log "$(tr_text "启动并等待 PostgreSQL，用于生成安全码哈希" "Starting and waiting for PostgreSQL to generate the security-code hash")"
baize_compose "$DEPLOY_MODE" up -d postgres
wait_for_postgres 120

code_sql="$(sql_literal "$NEW_CODE")"
new_hash="$(
  baize_compose "$DEPLOY_MODE" exec -T postgres psql -U "$postgres_user" -d "$postgres_db" -v ON_ERROR_STOP=1 -qAt <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT crypt($code_sql, gen_salt('bf', 12));
SQL
)"
new_hash="$(printf '%s\n' "$new_hash" | awk 'NF { value = $0 } END { print value }')"
case "$new_hash" in
  '$2a$'*|'$2b$'*|'$2y$'*) ;;
  *) die "$(tr_text "生成的安全码哈希格式不正确" "generated security-code hash has an unexpected format")" ;;
esac

set_env_value BAIZE_HOST_PROFILE_SECURITY_CODE_HASH "$(env_literal_single_quoted "$new_hash")"
set_env_value BAIZE_HOST_PROFILE_SECURITY_CODE ""

log "$(tr_text ".env 已写入安全码哈希，并清空明文安全码" "Stored the security-code hash in .env and cleared the plaintext value")"

if [[ "$NO_RESTART" == "1" ]]; then
  log "$(tr_text "已跳过重建中心服务；请稍后手动重建中心服务使新安全码生效。" "Skipped recreating the control service; recreate it later for the new code to take effect.")"
else
  log "$(tr_text "重建中心服务以加载新安全码" "Recreating the control service to load the new security code")"
  baize_compose "$DEPLOY_MODE" up -d --force-recreate server
  log "$(tr_text "安全码已重置。请只保存你刚输入的新安全码。" "Security code reset. Keep only the new code you just entered.")"
fi

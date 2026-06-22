#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
ENV_FILE="$ROOT_DIR/.env"
USERNAME=""
NEW_PASSWORD="${BAIZE_NEW_ADMIN_PASSWORD:-}"
YES=0
LANGUAGE="${BAIZE_LANG:-}"

log() {
  echo "[reset-admin-password] $*" >&2
}

die() {
  echo "[reset-admin-password] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/reset-admin-password.sh [选项]

选项:
  --username <name>      要重置的本地管理员账号，默认读取 .env 的 ADMIN_USERNAME，未配置时为 admin
  --password <password>  新密码。不推荐在共享终端使用；更建议交互输入或使用 BAIZE_NEW_ADMIN_PASSWORD
  --yes                 非交互确认，适合自动化脚本
  --lang <zh|en>        提示语言，默认读取 BAIZE_LANG，未配置时为 zh
  -h, --help            显示帮助

说明:
  该脚本用于无法登录控制台时重置本地管理员密码，并清除登录失败锁定状态。
  新密码不会写回 .env；.env 中的 ADMIN_PASSWORD 只代表首次安装时生成的初始值。

English:
  Reset a local admin password when you cannot log in to the console.
  Prefer the interactive prompt or BAIZE_NEW_ADMIN_PASSWORD over --password.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --username)
      USERNAME="${2:-}"
      [[ -n "$USERNAME" ]] || die "--username 不能为空"
      shift 2
      ;;
    --password)
      NEW_PASSWORD="${2:-}"
      [[ -n "$NEW_PASSWORD" ]] || die "--password 不能为空"
      shift 2
      ;;
    --yes|--non-interactive)
      YES=1
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

validate_secret_value() {
  local label="$1"
  local value="$2"
  local min_len="$3"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label $(tr_text "不能包含换行符" "must not contain line breaks")"
  (( ${#value} >= min_len )) || die "$label $(tr_text "长度不足，至少 ${min_len} 个字符" "is too short; minimum length is ${min_len}")"
}

prompt_secret_twice() {
  local label="$1"
  local first=""
  local second=""
  [[ -r /dev/tty ]] || die "$(tr_text "当前环境不可交互，请通过 BAIZE_NEW_ADMIN_PASSWORD 并追加 --yes" "non-interactive shell; pass BAIZE_NEW_ADMIN_PASSWORD and add --yes")"

  printf "%s: " "$label" >/dev/tty
  stty -echo </dev/tty
  IFS= read -r first </dev/tty || {
    stty echo </dev/tty
    die "$(tr_text "读取输入失败" "failed to read input")"
  }
  stty echo </dev/tty
  printf "\n" >/dev/tty

  printf "%s: " "$(tr_text "再次输入新密码" "Repeat new password")" >/dev/tty
  stty -echo </dev/tty
  IFS= read -r second </dev/tty || {
    stty echo </dev/tty
    die "$(tr_text "读取输入失败" "failed to read input")"
  }
  stty echo </dev/tty
  printf "\n" >/dev/tty

  [[ "$first" == "$second" ]] || die "$(tr_text "两次输入不一致" "the two passwords do not match")"
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
      die "$(tr_text "PostgreSQL 等待超时，无法重置密码" "timed out waiting for PostgreSQL; cannot reset the password")"
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

cd "$ROOT_DIR"

[[ -f "$ENV_FILE" ]] || die "$(tr_text "缺少 .env，请在白泽安装目录中执行" "missing .env; run this from your Baize installation directory")"
LANGUAGE="${LANGUAGE:-$(baize_resolve_language "$ENV_FILE")}"
case "$LANGUAGE" in
  zh|en) ;;
  *) die "不支持的语言 / unsupported language: $LANGUAGE" ;;
esac

USERNAME="${USERNAME:-$(read_env ADMIN_USERNAME)}"
USERNAME="${USERNAME:-admin}"
validate_secret_value "$(tr_text "管理员账号" "admin username")" "$USERNAME" 1

if [[ -z "$NEW_PASSWORD" ]]; then
  NEW_PASSWORD="$(prompt_secret_twice "$(tr_text "输入新管理员密码" "Enter new admin password")")"
fi
validate_secret_value "$(tr_text "新管理员密码" "new admin password")" "$NEW_PASSWORD" 8

confirm_action "$(tr_text "确认重置本地管理员账号 ${USERNAME} 的密码" "Reset password for local admin account ${USERNAME}")" || die "$(tr_text "已取消" "cancelled")"

require_cmd docker
docker compose version >/dev/null 2>&1 || die "$(tr_text "Docker Compose v2 不可用" "Docker Compose v2 is unavailable")"

postgres_user="$(read_env POSTGRES_USER)"
postgres_db="$(read_env POSTGRES_DB)"
[[ -n "$postgres_user" ]] || die "POSTGRES_USER $(tr_text "未配置" "is not configured")"
[[ -n "$postgres_db" ]] || die "POSTGRES_DB $(tr_text "未配置" "is not configured")"
DEPLOY_MODE="$(baize_resolve_deploy_mode "$ENV_FILE")"

log "$(tr_text "启动并等待 PostgreSQL" "Starting and waiting for PostgreSQL")"
baize_compose "$DEPLOY_MODE" up -d postgres
wait_for_postgres 120

username_sql="$(sql_literal "$USERNAME")"
password_sql="$(sql_literal "$NEW_PASSWORD")"
updated_count="$(
  baize_compose "$DEPLOY_MODE" exec -T postgres psql -U "$postgres_user" -d "$postgres_db" -v ON_ERROR_STOP=1 -qAt <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
WITH updated AS (
  UPDATE iam_users
     SET password_hash = crypt($password_sql, gen_salt('bf', 12)),
         status = 'active',
         failed_login_count = 0,
         locked_until = NULL,
         scope_version = scope_version + 1,
         updated_at = now()
   WHERE lower(username) = lower($username_sql)
     AND source = 'local'
     AND deleted_at IS NULL
   RETURNING username
)
SELECT count(*) FROM updated;
SQL
)"
updated_count="$(printf '%s' "$updated_count" | tr -d '[:space:]')"

if [[ "$updated_count" != "1" ]]; then
  die "$(tr_text "没有找到可重置的本地账号: ${USERNAME}" "no resettable local account found: ${USERNAME}")"
fi

log "$(tr_text "管理员密码已重置。请使用新密码登录控制台。" "Admin password reset. Log in to the console with the new password.")"

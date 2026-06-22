#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SCHEDULE="${BAIZE_BACKUP_CRON_SCHEDULE:-0 3 * * *}"
KEEP_DAYS="${BAIZE_BACKUP_KEEP_DAYS:-14}"
KEEP_DAYS_SET=0
BACKUP_ROOT="${BAIZE_BACKUP_DIR:-}"
YES=0

log() {
  echo "[backup-cron] $*" >&2
}

die() {
  echo "[backup-cron] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/install-backup-cron.sh [选项]

选项:
  --schedule "<cron>"   cron 表达式，默认 "0 3 * * *"
  --backup-dir <path>   备份根目录，默认读取 BAIZE_BACKUP_DIR
  --keep-days <days>    备份保留天数，默认 14
  --yes                 非交互确认
  -h, --help            显示帮助

说明:
  脚本会在当前用户 crontab 中写入白泽备份任务，日志输出到备份根目录的 cron.log。
  如需系统级定时任务，请用目标运行用户执行本脚本。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schedule)
      SCHEDULE="${2:-}"
      [[ -n "$SCHEDULE" ]] || die "--schedule 不能为空"
      shift 2
      ;;
    --backup-dir)
      BACKUP_ROOT="${2:-}"
      [[ -n "$BACKUP_ROOT" ]] || die "--backup-dir 不能为空"
      shift 2
      ;;
    --keep-days)
      KEEP_DAYS="${2:-}"
      [[ -n "$KEEP_DAYS" ]] || die "--keep-days 不能为空"
      KEEP_DAYS_SET=1
      shift 2
      ;;
    --yes|--non-interactive)
      YES=1
      shift
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

confirm() {
  local value=""
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "当前环境不可交互，请追加 --yes"
  printf "将写入当前用户 crontab，定时执行 Baize 备份，是否继续 [y/N]: " >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ "$value" == "y" || "$value" == "yes" || "$value" == "是" ]]
}

read_env() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  awk -F= -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == k {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$ENV_FILE"
}

default_backup_root() {
  local home_dir="${HOME:-$ROOT_DIR}"
  local instance_hash
  instance_hash="$(printf '%s' "$ROOT_DIR" | cksum | awk '{print $1}')"
  printf '%s/.baize/backups/baize-%s' "$home_dir" "$instance_hash"
}

resolve_path() {
  local value="$1"
  case "$value" in
    /*) printf '%s' "$value" ;;
    "~") printf '%s' "${HOME:-$ROOT_DIR}" ;;
    "~/"*) printf '%s/%s' "${HOME:-$ROOT_DIR}" "${value#~/}" ;;
    *) printf '%s/%s' "$ROOT_DIR" "$value" ;;
  esac
}

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

command -v crontab >/dev/null 2>&1 || die "当前系统没有 crontab 命令"
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "--keep-days 必须是非负整数"
if [[ -z "$BACKUP_ROOT" ]]; then
  BACKUP_ROOT="$(read_env BAIZE_BACKUP_DIR)"
fi
if [[ "$KEEP_DAYS_SET" != "1" && -z "${BAIZE_BACKUP_KEEP_DAYS:-}" ]]; then
  env_keep_days="$(read_env BAIZE_BACKUP_KEEP_DAYS)"
  if [[ -n "$env_keep_days" ]]; then
    KEEP_DAYS="$env_keep_days"
  fi
fi
if [[ -z "$BACKUP_ROOT" ]]; then
  BACKUP_ROOT="$(default_backup_root)"
fi
BACKUP_ROOT="$(resolve_path "$BACKUP_ROOT")"
confirm || die "用户取消"

mkdir -p "$BACKUP_ROOT"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

start_marker="# baize backup start"
end_marker="# baize backup end"
backup_command="cd $(shell_quote "$ROOT_DIR") && bash scripts/backup.sh --yes --backup-dir $(shell_quote "$BACKUP_ROOT") --keep-days $(shell_quote "$KEEP_DAYS") >> $(shell_quote "$BACKUP_ROOT/cron.log") 2>&1"

crontab -l 2>/dev/null | awk -v start="$start_marker" -v end="$end_marker" '
  $0 == start { skip = 1; next }
  $0 == end { skip = 0; next }
  skip != 1 { print }
' >"$tmp_file"

{
  printf '%s\n' "$start_marker"
  printf '%s %s\n' "$SCHEDULE" "$backup_command"
  printf '%s\n' "$end_marker"
} >>"$tmp_file"

crontab "$tmp_file"
log "已安装定时备份: $SCHEDULE"
log "备份根目录: $BACKUP_ROOT"
log "立即执行一次备份可运行: bash scripts/backup.sh --yes"

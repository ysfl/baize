#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
BACKUP_ROOT="${BAIZE_BACKUP_DIR:-}"
KEEP_DAYS="${BAIZE_BACKUP_KEEP_DAYS:-14}"
KEEP_DAYS_SET=0
YES=0
DRY_RUN=0
CLEAN_ALL=0

log() {
  echo "[cleanup-backups] $*" >&2
}

die() {
  echo "[cleanup-backups] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/cleanup-backups.sh [选项]

选项:
  --backup-dir <path>   备份根目录，默认读取 BAIZE_BACKUP_DIR
  --keep-days <days>    清理超过 N 天的旧备份，默认 14
  --all                 清理全部白泽备份目录；必须确认
  --dry-run             只列出会清理的目录，不删除
  --yes                 非交互确认
  -h, --help            显示帮助

说明:
  只会删除包含 backup-info.env 的白泽备份目录，避免误删用户自定义目录下的其他文件。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --all)
      CLEAN_ALL=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

confirm() {
  local prompt="$1"
  local value=""
  if [[ "$YES" == "1" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "当前环境不可交互，请追加 --yes 或先使用 --dry-run"
  printf "%s [y/N]: " "$prompt" >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ "$value" == "y" || "$value" == "yes" || "$value" == "是" ]]
}

collect_candidates() {
  if [[ "$CLEAN_ALL" == "1" ]]; then
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print
  else
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -print
  fi
}

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

[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "--keep-days 必须是非负整数: $KEEP_DAYS"
[[ -d "$BACKUP_ROOT" ]] || die "备份根目录不存在: $BACKUP_ROOT"

candidate_file="$(mktemp)"
trap 'rm -f "$candidate_file"' EXIT
collect_candidates >"$candidate_file"
if [[ ! -s "$candidate_file" ]]; then
  log "没有需要清理的备份: $BACKUP_ROOT"
  exit 0
fi

log "备份根目录: $BACKUP_ROOT"
while IFS= read -r dir; do
  if [[ -f "$dir/backup-info.env" ]]; then
    printf '%s\n' "$dir"
  else
    log "跳过非白泽备份目录: $dir"
  fi
done <"$candidate_file"

if [[ "$DRY_RUN" == "1" ]]; then
  log "dry-run 完成，未删除任何文件"
  exit 0
fi

if [[ "$CLEAN_ALL" == "1" ]]; then
  confirm "即将清理全部白泽备份目录，是否继续" || die "用户取消清理"
else
  confirm "即将清理超过 ${KEEP_DAYS} 天的白泽备份目录，是否继续" || die "用户取消清理"
fi

removed=0
while IFS= read -r dir; do
  if [[ -f "$dir/backup-info.env" ]]; then
    rm -rf -- "$dir"
    removed=$((removed + 1))
  fi
done <"$candidate_file"

log "清理完成，删除 ${removed} 个备份目录"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"

ENV_FILE="$ROOT_DIR/.env"
YES=0
BACKUP=1
REMOVE_AGENT=1
PURGE_DATA=0
PURGE_CONFIG=0
PURGE_BACKUPS=0
I_UNDERSTAND=0
LANGUAGE="${BAIZE_LANG:-}"

log() {
  echo "[uninstall] $*" >&2
}

die() {
  echo "[uninstall] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/uninstall.sh [选项]

默认行为:
  先创建备份，卸载当前宿主机上的本机连接程序，然后停止并移除白泽容器。
  默认保留数据库卷、配置文件和历史备份，方便误操作后恢复。

选项:
  --yes                         非交互确认
  --lang <zh|en>                提示语言，默认读取 BAIZE_LANG
  --no-backup                   跳过卸载前备份
  --keep-agent                  不卸载当前宿主机上的本机连接程序
  --purge-data                  同时删除 Docker 数据卷（破坏性）
  --purge-config                删除 .env 配置文件（破坏性）
  --purge-backups               删除本实例备份目录（破坏性）
  --purge-all                   等同于 --purge-data --purge-config --purge-backups
  --i-understand-data-loss      确认理解清除数据不可恢复
  -h, --help                    显示帮助

English:
  Stops and removes Baize containers. By default it creates a backup first and
  keeps Docker volumes, .env, and backup files. Use purge options only when you
  are sure you no longer need the instance data.
EOF
}

tr_text() {
  baize_text "$LANGUAGE" "$1" "$2"
}

confirm() {
  local prompt="$1"
  local value=""
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "$(tr_text "当前环境不可交互，请追加 --yes" "Non-interactive shell; add --yes")"
  printf "%s [y/N]: " "$prompt" >/dev/tty
  IFS= read -r value </dev/tty || die "$(tr_text "读取输入失败" "Failed to read input")"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ "$value" == "y" || "$value" == "yes" || "$value" == "是" ]]
}

read_env() {
  baize_read_env "$1" "$ENV_FILE"
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

default_backup_root() {
  local home_dir="${HOME:-$ROOT_DIR}"
  local instance_hash
  instance_hash="$(printf '%s' "$ROOT_DIR" | cksum | awk '{print $1}')"
  printf '%s/.baize/backups/baize-%s' "$home_dir" "$instance_hash"
}

resolve_backup_root() {
  local configured="${BAIZE_BACKUP_DIR:-}"
  if [[ -z "$configured" && -f "$ENV_FILE" ]]; then
    configured="$(read_env BAIZE_BACKUP_DIR)"
  fi
  if [[ -z "$configured" ]]; then
    configured="$(default_backup_root)"
  fi
  resolve_path "$configured"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|--non-interactive)
      YES=1
      shift
      ;;
    --lang)
      LANGUAGE="${2:-}"
      [[ -n "$LANGUAGE" ]] || die "--lang 不能为空"
      shift 2
      ;;
    --no-backup)
      BACKUP=0
      shift
      ;;
    --keep-agent)
      REMOVE_AGENT=0
      shift
      ;;
    --purge-data)
      PURGE_DATA=1
      shift
      ;;
    --purge-config)
      PURGE_CONFIG=1
      shift
      ;;
    --purge-backups)
      PURGE_BACKUPS=1
      shift
      ;;
    --purge-all)
      PURGE_DATA=1
      PURGE_CONFIG=1
      PURGE_BACKUPS=1
      shift
      ;;
    --i-understand-data-loss)
      I_UNDERSTAND=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "$(tr_text "未知参数: $1" "Unknown argument: $1")"
      ;;
  esac
done

if [[ -z "$LANGUAGE" ]]; then
  LANGUAGE="$(baize_resolve_language "$ENV_FILE")"
fi
case "$LANGUAGE" in
  zh|en) ;;
  *) die "不支持的语言 / unsupported language: $LANGUAGE" ;;
esac

cd "$ROOT_DIR"

if (( PURGE_DATA || PURGE_CONFIG || PURGE_BACKUPS )); then
  [[ "$I_UNDERSTAND" == "1" ]] || die "$(tr_text "清除数据、配置或备份前必须追加 --i-understand-data-loss" "Add --i-understand-data-loss before purging data, config, or backups")"
fi

confirm "$(tr_text "即将卸载当前白泽实例。是否继续" "Uninstall this Baize instance. Continue")" || die "$(tr_text "用户取消卸载" "Uninstall cancelled by user")"

if [[ "$BACKUP" == "1" && -f "$ENV_FILE" ]]; then
  log "$(tr_text "创建卸载前备份" "Creating backup before uninstall")"
  bash "$ROOT_DIR/scripts/backup.sh" --yes --lang "$LANGUAGE"
elif [[ "$BACKUP" == "1" ]]; then
  log "$(tr_text "未找到 .env，跳过备份" ".env not found; skipping backup")"
fi

if [[ "$REMOVE_AGENT" == "1" ]]; then
  log "$(tr_text "卸载当前宿主机上的本机连接程序" "Uninstalling local connection program on this host")"
  bash "$ROOT_DIR/scripts/install-agent.sh" --uninstall || log "$(tr_text "本机连接程序卸载失败，请稍后手动执行 scripts/install-agent.sh --uninstall" "Local connection program uninstall failed; run scripts/install-agent.sh --uninstall manually later")"
fi

if [[ -f "$ENV_FILE" ]]; then
  command -v docker >/dev/null 2>&1 || die "$(tr_text "缺少 docker，无法停止容器" "docker is required to stop containers")"
  docker compose version >/dev/null 2>&1 || die "$(tr_text "Docker Compose v2 不可用" "Docker Compose v2 is unavailable")"
  DEPLOY_MODE="$(baize_resolve_deploy_mode "$ENV_FILE")"
  if [[ "$PURGE_DATA" == "1" ]]; then
    log "$(tr_text "停止容器并删除 Docker 数据卷" "Stopping containers and deleting Docker volumes")"
    baize_compose "$DEPLOY_MODE" down -v --remove-orphans
  else
    log "$(tr_text "停止并移除容器，保留 Docker 数据卷" "Stopping and removing containers while keeping Docker volumes")"
    baize_compose "$DEPLOY_MODE" down --remove-orphans
  fi
else
  log "$(tr_text "未找到 .env，跳过容器停止步骤" ".env not found; skipping container stop")"
fi

if [[ "$PURGE_CONFIG" == "1" ]]; then
  log "$(tr_text "删除 .env 配置文件" "Deleting .env config file")"
  rm -f "$ENV_FILE"
fi

if [[ "$PURGE_BACKUPS" == "1" ]]; then
  backup_root="$(resolve_backup_root)"
  if [[ -d "$backup_root" ]]; then
    log "$(tr_text "删除本实例备份目录: $backup_root" "Deleting backup directory for this instance: $backup_root")"
    rm -rf -- "$backup_root"
  fi
fi

log "$(tr_text "卸载流程完成" "Uninstall completed")"
if [[ "$PURGE_DATA" != "1" ]]; then
  log "$(tr_text "Docker 数据卷已保留；如需彻底清除，请确认备份后重新执行 --purge-data --i-understand-data-loss" "Docker volumes were kept. To remove them, confirm backups and rerun with --purge-data --i-understand-data-loss")"
fi

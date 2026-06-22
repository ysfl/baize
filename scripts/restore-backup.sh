#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
BACKUP_DIR=""
YES=0
SKIP_ENV=0
SKIP_RESTART=0
LATEST=0
REQUIRE_DB=0
LANGUAGE="${BAIZE_LANG:-}"
RESET_VOLUMES=0
CONFIRM_DATA_LOSS=0

log() {
  echo "[restore] $*" >&2
}

die() {
  echo "[restore] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/restore-backup.sh --backup-dir runtime/backups/<timestamp> --yes

选项:
  --backup-dir <path>  备份目录，必须包含 env.backup；数据库恢复需要 postgres.dump
  --latest             从 BAIZE_BACKUP_DIR 或默认备份根目录选择最新备份
  --yes                非交互确认；恢复数据库属于破坏性操作，生产环境必须明确传入
  --lang <zh|en>       提示语言，默认读取 BAIZE_LANG，未配置时为 zh
  --skip-env           不恢复 .env，只恢复数据库
  --skip-restart       恢复后不重启中心服务和控制台
  --require-db         备份目录必须包含数据库备份文件，适合升级失败后的恢复
  --reset-volumes      恢复前删除当前 PostgreSQL/Redis 数据卷，再从备份重建
  --i-understand-data-loss
                       确认理解 --reset-volumes 会删除当前 PostgreSQL/Redis 数据卷
  -h, --help           显示帮助

说明:
  恢复会暂停中心服务和控制台，使用备份里的 PostgreSQL dump 重建当前数据库。
  这是升级失败后的兜底方案，不会自动猜测数据结构的反向回退步骤。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir)
      BACKUP_DIR="${2:-}"
      [[ -n "$BACKUP_DIR" ]] || die "--backup-dir 不能为空"
      shift 2
      ;;
    --latest)
      LATEST=1
      shift
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
    --skip-env)
      SKIP_ENV=1
      shift
      ;;
    --skip-restart)
      SKIP_RESTART=1
      shift
      ;;
    --require-db)
      REQUIRE_DB=1
      shift
      ;;
    --reset-volumes)
      RESET_VOLUMES=1
      shift
      ;;
    --i-understand-data-loss)
      CONFIRM_DATA_LOSS=1
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
  baize_read_env "$1" "$ROOT_DIR/.env"
}

tr_text() {
  baize_text "$LANGUAGE" "$1" "$2"
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

resolve_backup_root() {
  local configured="${BAIZE_BACKUP_DIR:-}"
  if [[ -z "$configured" && -f "$ROOT_DIR/.env" ]]; then
    configured="$(baize_read_env BAIZE_BACKUP_DIR "$ROOT_DIR/.env")"
  fi
  if [[ -z "$configured" ]]; then
    configured="$(default_backup_root)"
  fi
  resolve_path "$(baize_strip_env_quotes "$configured")"
}

latest_backup_dir() {
  local root="$1"
  [[ -d "$root" ]] || die "$(tr_text "备份根目录不存在: $root" "Backup root does not exist: $root")"
  find "$root" -mindepth 2 -maxdepth 2 -type f -name backup-info.env -print \
    | sed 's#/backup-info.env$##' \
    | sort \
    | tail -n 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

confirm_restore() {
  local value=""
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "恢复是破坏性操作，非交互环境必须追加 --yes"
  printf "%s " "$(tr_text "恢复会重建当前 PostgreSQL 数据库，并可能覆盖 .env。请输入 RESTORE 确认:" "Restore will recreate the current PostgreSQL database and may overwrite .env. Type RESTORE to confirm:")" >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败"
  [[ "$value" == "RESTORE" ]]
}

confirm_data_loss() {
  local value=""
  if [[ "$CONFIRM_DATA_LOSS" == "1" ]]; then
    return 0
  fi
  [[ "$YES" != "1" ]] || die "--reset-volumes 非交互执行必须追加 --i-understand-data-loss"
  [[ -r /dev/tty ]] || die "当前环境不可交互，请追加 --i-understand-data-loss"
  printf "%s " "$(tr_text "将删除当前 PostgreSQL/Redis 数据卷并从备份重建。请输入 RESET 确认:" "This will delete the current PostgreSQL/Redis volumes and rebuild from backup. Type RESET to confirm:")" >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败"
  [[ "$value" == "RESET" ]]
}

volume_name_for_mount() {
  local service="$1"
  local mount_path="$2"
  local cid
  cid="$(baize_compose "$DEPLOY_MODE" ps -q "$service" 2>/dev/null || true)"
  [[ -n "$cid" ]] || return 0
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$mount_path\"}}{{.Name}}{{end}}{{end}}" "$cid" 2>/dev/null || true
}

reset_data_volumes() {
  [[ "$RESET_VOLUMES" == "1" ]] || return 0
  [[ "$SKIP_ENV" != "1" ]] || die "$(tr_text "--reset-volumes 需要恢复备份中的 .env，不能同时使用 --skip-env" "--reset-volumes must restore .env from the backup and cannot be combined with --skip-env")"
  confirm_data_loss || die "$(tr_text "用户取消数据卷重建" "volume reset cancelled by user")"

  DEPLOY_MODE="$(baize_resolve_deploy_mode "$ROOT_DIR/.env" 2>/dev/null || printf '%s' image)"
  STACK_MODE="$(baize_resolve_stack_mode "$ROOT_DIR/.env" 2>/dev/null || printf '%s' full)"
  app_services=(server)
  if baize_stack_has_web "$STACK_MODE"; then
    app_services+=(web)
  fi
  log "$(tr_text "准备删除当前 PostgreSQL/Redis 数据卷" "Preparing to remove current PostgreSQL/Redis volumes")"
  baize_compose "$DEPLOY_MODE" up -d postgres redis >/dev/null 2>&1 || true
  postgres_volume="$(volume_name_for_mount postgres /var/lib/postgresql/data)"
  redis_volume="$(volume_name_for_mount redis /data)"
  baize_compose "$DEPLOY_MODE" stop "${app_services[@]}" postgres redis >/dev/null 2>&1 || true
  baize_compose "$DEPLOY_MODE" rm -f -s postgres redis >/dev/null 2>&1 || true
  for volume in "$postgres_volume" "$redis_volume"; do
    [[ -n "$volume" ]] || continue
    docker volume rm "$volume" >/dev/null 2>&1 || true
  done
}

wait_for_health() {
  local service="$1"
  local timeout="${2:-120}"
  local start now cid status
  start="$(date +%s)"
  while true; do
    cid="$(baize_compose "$DEPLOY_MODE" ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      if [[ "$status" == "healthy" || "$status" == "running" ]]; then
        return 0
      fi
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      baize_compose "$DEPLOY_MODE" logs --tail=120 "$service" >&2 || true
      die "${service} 等待超时，无法恢复"
    fi
    sleep 2
  done
}

cd "$ROOT_DIR"

if [[ -z "$LANGUAGE" ]]; then
  LANGUAGE="$(baize_resolve_language "$ROOT_DIR/.env")"
fi
case "$LANGUAGE" in
  zh|en) ;;
  *) die "不支持的语言 / unsupported language: $LANGUAGE" ;;
esac

if [[ "$LATEST" == "1" ]]; then
  backup_root="$(resolve_backup_root)"
  BACKUP_DIR="$(latest_backup_dir "$backup_root")"
  [[ -n "$BACKUP_DIR" ]] || die "$(tr_text "未找到可用备份: $backup_root" "No usable backup found: $backup_root")"
  log "$(tr_text "已选择最新备份: $BACKUP_DIR" "Selected latest backup: $BACKUP_DIR")"
fi

[[ -n "$BACKUP_DIR" ]] || die "$(tr_text "请通过 --backup-dir 指定备份目录，或使用 --latest" "Pass --backup-dir, or use --latest")"
[[ -d "$BACKUP_DIR" ]] || die "备份目录不存在: $BACKUP_DIR"
[[ -f "$BACKUP_DIR/env.backup" ]] || die "备份目录缺少 env.backup"
if [[ "$REQUIRE_DB" == "1" && ! -f "$BACKUP_DIR/postgres.dump" ]]; then
  die "$(tr_text "备份目录缺少 postgres.dump，不能执行数据库恢复" "Backup directory does not contain postgres.dump; database restore cannot continue")"
fi
require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 不可用"

confirm_restore || die "用户取消恢复"

mkdir -p "$ROOT_DIR/runtime/restore"
reset_data_volumes
if [[ "$SKIP_ENV" != "1" ]]; then
  if [[ -f "$ROOT_DIR/.env" ]]; then
    cp "$ROOT_DIR/.env" "$ROOT_DIR/runtime/restore/env-before-restore-$(date '+%Y%m%d-%H%M%S').backup"
  fi
  cp "$BACKUP_DIR/env.backup" "$ROOT_DIR/.env"
  chmod 600 "$ROOT_DIR/.env" 2>/dev/null || true
  log "$(tr_text "已恢复 .env。若当前 PostgreSQL 数据卷使用的是另一套密码，请先人工核对后再恢复数据库。" "Restored .env. If the current PostgreSQL volume uses different credentials, verify them before restoring the database.")"
fi

DEPLOY_MODE="$(baize_resolve_deploy_mode "$ROOT_DIR/.env")"
STACK_MODE="$(baize_resolve_stack_mode "$ROOT_DIR/.env")"
app_services=(server)
if baize_stack_has_web "$STACK_MODE"; then
  app_services+=(web)
fi

postgres_user="$(read_env POSTGRES_USER)"
postgres_db="$(read_env POSTGRES_DB)"
[[ -n "$postgres_user" ]] || die "POSTGRES_USER 未配置"
[[ -n "$postgres_db" ]] || die "POSTGRES_DB 未配置"

if baize_stack_has_web "$STACK_MODE"; then
  log "$(tr_text "暂停中心服务和控制台，避免恢复期间继续写入数据库" "Stopping the control service and console to avoid writes during restore")"
else
  log "$(tr_text "暂停中心服务，避免恢复期间继续写入数据库" "Stopping the control service to avoid writes during restore")"
fi
baize_compose "$DEPLOY_MODE" stop "${app_services[@]}" >/dev/null 2>&1 || true
baize_compose "$DEPLOY_MODE" up -d postgres redis
wait_for_health postgres 120

if [[ -f "$BACKUP_DIR/postgres.dump" ]]; then
  log "$(tr_text "重建数据库并导入备份文件" "Recreating the database and importing the backup")"
  # 数据库名来自 .env，交给 psql 变量安全转义，避免特殊字符破坏 SQL。
  baize_compose "$DEPLOY_MODE" exec -T postgres psql -U "$postgres_user" -d postgres -v ON_ERROR_STOP=1 --set=dbname="$postgres_db" >/dev/null <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'dbname'
  AND pid <> pg_backend_pid();
SQL
  baize_compose "$DEPLOY_MODE" exec -T postgres dropdb -U "$postgres_user" --if-exists "$postgres_db"
  baize_compose "$DEPLOY_MODE" exec -T postgres createdb -U "$postgres_user" "$postgres_db"
  baize_compose "$DEPLOY_MODE" exec -T postgres pg_restore -U "$postgres_user" -d "$postgres_db" --no-owner <"$BACKUP_DIR/postgres.dump"
else
  log "$(tr_text "备份目录没有 postgres.dump，跳过数据库恢复" "No postgres.dump in the backup directory; skipping database restore")"
fi

if [[ "$SKIP_RESTART" != "1" ]]; then
  if baize_stack_has_web "$STACK_MODE"; then
    log "$(tr_text "恢复后重启中心服务和控制台" "Restarting the control service and console after restore")"
  else
    log "$(tr_text "恢复后重启中心服务" "Restarting the control service after restore")"
  fi
  bash scripts/deploy-server.sh --skip-online-check
  bash scripts/check-install.sh || log "$(tr_text "在线检查失败，请查看 docker compose logs" "Online check failed. Please inspect docker compose logs")"
fi

log "$(tr_text "恢复完成" "Restore completed")"

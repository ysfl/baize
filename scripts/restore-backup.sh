#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
BACKUP_DIR=""
YES=0
SKIP_ENV=0
SKIP_RESTART=0

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
  --yes                非交互确认；恢复数据库属于破坏性操作，生产环境必须明确传入
  --skip-env           不恢复 .env，只恢复数据库
  --skip-restart       恢复后不重启中心服务和控制台
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
    --yes|--non-interactive)
      YES=1
      shift
      ;;
    --skip-env)
      SKIP_ENV=1
      shift
      ;;
    --skip-restart)
      SKIP_RESTART=1
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

confirm_restore() {
  local value=""
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "恢复是破坏性操作，非交互环境必须追加 --yes"
  printf "恢复会重建当前 PostgreSQL 数据库，并可能覆盖 .env。请输入 RESTORE 确认: " >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败"
  [[ "$value" == "RESTORE" ]]
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

[[ -n "$BACKUP_DIR" ]] || die "请通过 --backup-dir 指定备份目录"
[[ -d "$BACKUP_DIR" ]] || die "备份目录不存在: $BACKUP_DIR"
[[ -f "$BACKUP_DIR/env.backup" ]] || die "备份目录缺少 env.backup"
require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 不可用"

confirm_restore || die "用户取消恢复"

mkdir -p "$ROOT_DIR/runtime/restore"
if [[ "$SKIP_ENV" != "1" ]]; then
  if [[ -f "$ROOT_DIR/.env" ]]; then
    cp "$ROOT_DIR/.env" "$ROOT_DIR/runtime/restore/env-before-restore-$(date '+%Y%m%d-%H%M%S').backup"
  fi
  cp "$BACKUP_DIR/env.backup" "$ROOT_DIR/.env"
  chmod 600 "$ROOT_DIR/.env" 2>/dev/null || true
  log "已恢复 .env。若当前 PostgreSQL volume 使用的是另一套密码，请先人工核对后再恢复数据库。"
fi

DEPLOY_MODE="$(baize_resolve_deploy_mode "$ROOT_DIR/.env")"

postgres_user="$(read_env POSTGRES_USER)"
postgres_db="$(read_env POSTGRES_DB)"
[[ -n "$postgres_user" ]] || die "POSTGRES_USER 未配置"
[[ -n "$postgres_db" ]] || die "POSTGRES_DB 未配置"

log "暂停 server/web，避免恢复期间继续写入数据库"
baize_compose "$DEPLOY_MODE" stop server web >/dev/null 2>&1 || true
baize_compose "$DEPLOY_MODE" up -d postgres redis
wait_for_health postgres 120

if [[ -f "$BACKUP_DIR/postgres.dump" ]]; then
  log "重建数据库并导入备份 dump"
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
  log "备份目录没有 postgres.dump，跳过数据库恢复"
fi

if [[ "$SKIP_RESTART" != "1" ]]; then
  log "恢复后重启 server/web"
  bash scripts/deploy-server.sh --skip-online-check
  bash scripts/check-install.sh || log "在线检查失败，请查看 docker compose logs server web"
fi

log "恢复完成"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
ENV_FILE="$ROOT_DIR/.env"
BACKUP_ROOT=""
BACKUP_DIR=""
YES=0
SKIP_DB=0
KEEP_DAYS="${BAIZE_BACKUP_KEEP_DAYS:-14}"
KEEP_DAYS_SET=0
LANGUAGE="${BAIZE_LANG:-}"

log() {
  echo "[backup] $*" >&2
}

die() {
  echo "[backup] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/backup.sh [选项]

选项:
  --yes                  非交互确认
  --lang <zh|en>         提示语言，默认读取 BAIZE_LANG，未配置时为 zh
  --output-dir <path>    指定备份目录，默认 runtime/backups/<timestamp>
  --backup-dir <path>    指定备份根目录，默认读取 BAIZE_BACKUP_DIR
  --keep-days <days>     清理超过 N 天的旧备份，默认 14；0 表示不清理
  --skip-db              只备份配置和版本元数据，不导出 PostgreSQL
  -h, --help             显示帮助

说明:
  备份会保存 .env、发布清单、构建信息、docker compose 配置和 PostgreSQL dump。
  默认写入 .env 的 BAIZE_BACKUP_DIR；老配置缺失时回退到 ~/.baize/backups/baize-<实例哈希>。

English:
  Creates a local backup before upgrades. It includes config, release metadata,
  compose config and a PostgreSQL dump by default.
EOF
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
    --output-dir)
      BACKUP_DIR="${2:-}"
      [[ -n "$BACKUP_DIR" ]] || die "--output-dir 不能为空"
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
    --skip-db)
      SKIP_DB=1
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
  baize_read_env "$1" "$ENV_FILE"
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
  local configured="$BACKUP_ROOT"
  if [[ -z "$configured" ]]; then
    configured="${BAIZE_BACKUP_DIR:-$(read_env BAIZE_BACKUP_DIR)}"
  fi
  if [[ -z "$configured" ]]; then
    configured="$(default_backup_root)"
  fi
  resolve_path "$configured"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

confirm() {
  local prompt="$1"
  local value=""
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "当前环境不可交互，请追加 --yes"
  printf "%s [y/N]: " "$prompt" >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ "$value" == "y" || "$value" == "yes" || "$value" == "是" ]]
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
      die "${service} 等待超时，无法完成备份"
    fi
    sleep 2
  done
}

compose_psql() {
  local db_name="$1"
  shift
  baize_compose "$DEPLOY_MODE" exec -T postgres psql -U "$postgres_user" -d "$db_name" -v ON_ERROR_STOP=1 "$@"
}

backup_diagnostics() {
  local dump_status="${1:-}"
  {
    echo
    echo "$(tr_text "数据库备份诊断:" "Database backup diagnostics:")"
    echo "- ROOT_DIR=$ROOT_DIR"
    echo "- DEPLOY_MODE=$DEPLOY_MODE"
    echo "- POSTGRES_USER=$postgres_user"
    echo "- POSTGRES_DB=$postgres_db"
    echo "- BACKUP_DIR=$BACKUP_DIR"
    echo "- DUMP_EXIT_CODE=${dump_status:-unknown}"
    baize_compose "$DEPLOY_MODE" ps postgres || true
    baize_compose "$DEPLOY_MODE" exec -T postgres pg_isready -U "$postgres_user" -d "$postgres_db" || true
    baize_compose "$DEPLOY_MODE" exec -T postgres psql -U "$postgres_user" -d postgres -Atc \
      "SELECT 'database=' || datname FROM pg_database WHERE datname = '${postgres_db//\'/\'\'}';" || true
    baize_compose "$DEPLOY_MODE" exec -T postgres psql -U "$postgres_user" -d postgres -Atc \
      "SELECT 'role=' || rolname FROM pg_roles WHERE rolname = '${postgres_user//\'/\'\'}';" || true
    df -h "$BACKUP_DIR" || true
    echo "$(tr_text "常见原因：.env 中的 POSTGRES_USER/POSTGRES_DB 与已有数据卷不一致、当前目录不是原安装目录、磁盘空间不足，或 PostgreSQL 权限不足。" "Common causes: POSTGRES_USER/POSTGRES_DB in .env do not match the existing volume, this is not the original install directory, disk space is low, or PostgreSQL permissions are insufficient.")"
  } >&2
}

preflight_database_backup() {
  log "$(tr_text "检查 PostgreSQL 连接、目标库和备份目录" "Checking PostgreSQL connection, target database, and backup directory")"
  baize_compose "$DEPLOY_MODE" exec -T postgres pg_isready -U "$postgres_user" -d "$postgres_db" >/dev/null
  compose_psql postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '${postgres_db//\'/\'\'}';" | grep -qx 1
  compose_psql postgres -Atc "SELECT 1 FROM pg_roles WHERE rolname = '${postgres_user//\'/\'\'}';" | grep -qx 1
  compose_psql "$postgres_db" -Atc "SELECT 1;" | grep -qx 1
  df -Pk "$BACKUP_DIR" >/dev/null
}

copy_if_exists() {
  local source="$1"
  local target="$2"
  [[ -e "$source" ]] || return 0
  mkdir -p "$(dirname "$target")"
  cp -R "$source" "$target"
}

prune_old_backups() {
  [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "--keep-days 必须是非负整数: $KEEP_DAYS"
  (( KEEP_DAYS > 0 )) || return 0
  [[ -d "$BACKUP_ROOT" ]] || return 0
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -exec sh -c '
    for dir do
      if [ -f "$dir/backup-info.env" ]; then
        rm -rf -- "$dir"
      fi
    done
  ' sh {} +
}

cd "$ROOT_DIR"

[[ -f "$ENV_FILE" ]] || die "未找到 .env，请先完成安装配置"
require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 不可用"
if [[ -z "$LANGUAGE" ]]; then
  LANGUAGE="$(baize_resolve_language "$ENV_FILE")"
fi
case "$LANGUAGE" in
  zh|en) ;;
  *) die "不支持的语言 / unsupported language: $LANGUAGE" ;;
esac
DEPLOY_MODE="$(baize_resolve_deploy_mode "$ENV_FILE")"

BACKUP_ROOT="$(resolve_backup_root)"
if [[ "$KEEP_DAYS_SET" != "1" && -z "${BAIZE_BACKUP_KEEP_DAYS:-}" ]]; then
  env_keep_days="$(read_env BAIZE_BACKUP_KEEP_DAYS)"
  if [[ -n "$env_keep_days" ]]; then
    KEEP_DAYS="$env_keep_days"
  fi
fi

timestamp="$(date '+%Y%m%d-%H%M%S')"
if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="$BACKUP_ROOT/$timestamp"
else
  BACKUP_DIR="$(resolve_path "$BACKUP_DIR")"
fi

confirm "$(tr_text "即将创建备份到 ${BACKUP_DIR}。升级前强烈建议保留数据库备份，是否继续" "Create backup at ${BACKUP_DIR}. Keeping a database backup before upgrades is strongly recommended. Continue")" || die "$(tr_text "用户取消备份" "backup cancelled by user")"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR" 2>/dev/null || true

log "保存配置与发布元数据"
cp "$ENV_FILE" "$BACKUP_DIR/env.backup"
chmod 600 "$BACKUP_DIR/env.backup" 2>/dev/null || true
copy_if_exists "$ROOT_DIR/releases/manifest.env" "$BACKUP_DIR/releases/manifest.env"
copy_if_exists "$ROOT_DIR/releases/latest.json" "$BACKUP_DIR/releases/latest.json"
copy_if_exists "$ROOT_DIR/releases/changelog.json" "$BACKUP_DIR/releases/changelog.json"
copy_if_exists "$ROOT_DIR/server/dist/build-info.env" "$BACKUP_DIR/server-build-info.env"
copy_if_exists "$ROOT_DIR/agent/dist/build-info.env" "$BACKUP_DIR/agent-build-info.env"
baize_set_compose_args "$DEPLOY_MODE"
docker compose --env-file "$ENV_FILE" "${BAIZE_COMPOSE_ARGS[@]}" config >"$BACKUP_DIR/docker-compose.config.yaml"

if [[ -d "$ROOT_DIR/.git" ]]; then
  git rev-parse HEAD >"$BACKUP_DIR/git-head.txt" 2>/dev/null || true
  git status --short >"$BACKUP_DIR/git-status.txt" 2>/dev/null || true
fi

cat >"$BACKUP_DIR/backup-info.env" <<EOF
BACKUP_CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
BACKUP_SOURCE_DIR=$ROOT_DIR
BACKUP_SKIP_DB=$SKIP_DB
EOF

if [[ "$SKIP_DB" != "1" ]]; then
  postgres_user="$(read_env POSTGRES_USER)"
  postgres_db="$(read_env POSTGRES_DB)"
  [[ -n "$postgres_user" ]] || die "POSTGRES_USER 未配置"
  [[ -n "$postgres_db" ]] || die "POSTGRES_DB 未配置"

  log "$(tr_text "启动并等待 PostgreSQL，用 pg_dump 导出数据库" "Starting PostgreSQL and exporting the database with pg_dump")"
  baize_compose "$DEPLOY_MODE" up -d postgres
  wait_for_health postgres 120
  if ! preflight_database_backup; then
    backup_diagnostics "preflight"
    die "$(tr_text "PostgreSQL 备份预检失败，请按上方诊断修正后重试" "PostgreSQL backup preflight failed. Fix the diagnostics above and retry.")"
  fi
  set +e
  baize_compose "$DEPLOY_MODE" exec -T postgres pg_dump -U "$postgres_user" -d "$postgres_db" --format=custom --no-owner >"$BACKUP_DIR/postgres.dump"
  dump_status=$?
  set -e
  if [[ "$dump_status" != "0" ]]; then
    rm -f "$BACKUP_DIR/postgres.dump"
    backup_diagnostics "$dump_status"
    die "$(tr_text "PostgreSQL 备份失败，未生成可用数据库备份" "PostgreSQL backup failed. No usable database backup was created.")"
  fi
  [[ -s "$BACKUP_DIR/postgres.dump" ]] || die "PostgreSQL 备份文件为空"
fi

prune_old_backups
log "备份完成: $BACKUP_DIR"
printf '%s\n' "$BACKUP_DIR"

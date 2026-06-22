#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
MODE=""
YES=0
DRY_RUN=0
CONFIRM_REINIT=0
CONFIRM_DATA_LOSS=0
SKIP_BACKUP=0
CONFIRM_NO_BACKUP=0
BACKUP_ROOT="${BAIZE_BACKUP_DIR:-}"
INIT_ARGS=()

log() {
  echo "[reinit-config] $*" >&2
}

die() {
  echo "[reinit-config] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/reinit-config.sh --config-only --i-understand-reinit
  bash scripts/reinit-config.sh --reset-stack --i-understand-reinit --i-understand-data-loss

模式（二选一）:
  --config-only                 只重新生成 .env，不启动或重置容器
  --reset-stack                 备份后删除 Compose volumes，重新生成 .env 并部署全新栈

常用选项:
  --yes                         非交互确认
  --dry-run                     只打印计划，不执行
  --backup-dir <path>           备份根目录，也会写入新 .env 的 BAIZE_BACKUP_DIR
  --skip-backup                 跳过重初始化前备份；必须同时传 --yes --i-understand-no-backup
  --i-understand-reinit         确认理解会重新生成数据库、Redis、JWT、管理员和凭据密钥
  --i-understand-data-loss      确认理解 --reset-stack 会删除当前 PostgreSQL/Redis volumes
  --i-understand-no-backup      确认理解跳过备份会让数据无法恢复

配置选项:
  --public-url <url>
  --web-api-base-url <url>
  --server-public-port <port>
  --web-public-port <port>
  --postgres-public-port <port>
  --redis-public-port <port>
  --server-target-arch <arch>
  --deploy-mode <auto|image|build>
  --stack-mode <full|server-only>
  --server-image <image>
  --web-image <image>
  --version <version>

说明:
  升级场景仍然不得使用 --force-config。需要重新初始化时，请使用本脚本显式选择模式。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-only)
      MODE="config-only"
      shift
      ;;
    --reset-stack)
      MODE="reset-stack"
      shift
      ;;
    --yes|--non-interactive)
      YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --backup-dir)
      BACKUP_ROOT="${2:-}"
      [[ -n "$BACKUP_ROOT" ]] || die "--backup-dir 不能为空"
      INIT_ARGS+=("$1" "$2")
      shift 2
      ;;
    --skip-backup)
      SKIP_BACKUP=1
      shift
      ;;
    --i-understand-reinit)
      CONFIRM_REINIT=1
      shift
      ;;
    --i-understand-data-loss)
      CONFIRM_DATA_LOSS=1
      shift
      ;;
    --i-understand-no-backup)
      CONFIRM_NO_BACKUP=1
      shift
      ;;
    --public-url|--agent-public-url|--web-api-base-url|--server-public-port|--web-public-port|--postgres-public-port|--redis-public-port|--server-target-arch|--deploy-mode|--stack-mode|--server-image|--web-image|--version)
      [[ -n "${2:-}" ]] || die "$1 不能为空"
      INIT_ARGS+=("$1" "$2")
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

confirm_word() {
  local word="$1"
  local prompt="$2"
  local value=""
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] || die "当前环境不可交互，请追加 --yes 和必要的 i-understand 参数"
  printf "%s 请输入 %s 确认: " "$prompt" "$word" >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败"
  [[ "$value" == "$word" ]]
}

cd "$ROOT_DIR"
[[ -f docker-compose.yml ]] || die "请在 baize 公开发布仓运行"

case "$MODE" in
  config-only|reset-stack) ;;
  "") die "请指定 --config-only 或 --reset-stack" ;;
  *) die "未知重初始化模式: $MODE" ;;
esac

if [[ "$CONFIRM_REINIT" != "1" ]]; then
  if [[ "$YES" == "1" ]]; then
    die "非交互重初始化必须追加 --i-understand-reinit"
  fi
  confirm_word "REINIT" "重初始化会更换生产密钥，并可能导致旧 Token、Agent 通信和加密凭据失效。" || die "用户取消重初始化"
fi

if [[ "$MODE" == "reset-stack" && "$CONFIRM_DATA_LOSS" != "1" ]]; then
  die "--reset-stack 会删除当前 PostgreSQL/Redis volumes。请先备份并追加 --i-understand-data-loss。"
fi

if [[ "$SKIP_BACKUP" == "1" && ( "$YES" != "1" || "$CONFIRM_NO_BACKUP" != "1" ) ]]; then
  die "--skip-backup 必须同时传 --yes --i-understand-no-backup"
fi

log "模式: $MODE"
if [[ "$DRY_RUN" == "1" ]]; then
  log "dry-run: 将重新生成 .env，配置参数数量=${#INIT_ARGS[@]}"
  if [[ "$MODE" == "reset-stack" ]]; then
    log "dry-run: 将执行 docker compose down --volumes --remove-orphans 后重新部署"
  fi
  exit 0
fi

if [[ -f .env && "$SKIP_BACKUP" != "1" ]]; then
  log "重初始化前先创建备份"
  backup_args=(--yes)
  if [[ -n "$BACKUP_ROOT" ]]; then
    backup_args+=(--backup-dir "$BACKUP_ROOT")
  fi
  bash scripts/backup.sh "${backup_args[@]}" >/dev/null
elif [[ -f .env ]]; then
  log "已按用户要求跳过备份；这是高风险操作"
fi

if [[ "$MODE" == "config-only" ]]; then
  bash scripts/init-config.sh --force "${INIT_ARGS[@]}"
  log "已重新生成 .env。若当前 Docker volumes 仍保留旧数据库密码，请不要直接启动，先核对数据恢复方案。"
  exit 0
fi

log "停止并删除当前 Compose volumes"
if [[ -f .env ]]; then
  DEPLOY_MODE="$(baize_resolve_deploy_mode "$ROOT_DIR/.env")"
else
  DEPLOY_MODE="image"
fi
baize_compose "$DEPLOY_MODE" down --volumes --remove-orphans

log "重新生成配置并部署全新栈"
bash scripts/deploy-server.sh --force-config --i-understand-force-config "${INIT_ARGS[@]}"

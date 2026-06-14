#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
YES=0
TARGET_REF=""
ALLOW_DIRTY=0
DRY_RUN=0
NO_VERIFY=0
SKIP_BACKUP=0
CONFIRM_NO_BACKUP=0
ROLLBACK_ON_FAILURE=1
UPGRADE_MODE="${BAIZE_UPGRADE_MODE:-manual}"
LOG_DIR="$ROOT_DIR/runtime/upgrade"
STATE_FILE="$LOG_DIR/latest.env"
BACKUP_DIR=""
PREVIOUS_REF=""
FAILED_STEP=""

log() {
  echo "[upgrade] $*" >&2
}

die() {
  echo "[upgrade] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/upgrade.sh [选项]

常用:
  bash scripts/upgrade.sh
  bash scripts/upgrade.sh --yes
  bash scripts/upgrade.sh --target v0.1.20 --yes
  bash scripts/upgrade.sh --mode docker-updater --yes

选项:
  --yes                         非交互确认
  --target <git-ref>            升级到指定版本标签；高级排查时也可填写 Git ref
  --mode <manual|docker-updater|host-updater>
                                升级模式；manual 在终端执行，docker-updater 使用镜像编排，
                                host-updater 更新宿主机中心服务
  --allow-dirty                 允许存在已跟踪文件改动；默认拒绝，避免覆盖用户修改
  --dry-run                     只检查并打印计划，不实际升级
  --no-verify                   跳过升级后的在线检查
  --skip-backup                 跳过升级前自动备份；必须同时传 --yes --i-understand-no-backup
  --i-understand-no-backup      确认理解跳过备份可能导致数据库无法回滚
  --no-rollback-on-failure      失败时不自动切回旧 Git 版本
  -h, --help                    显示帮助

禁止:
  --force-config                升级场景不得使用。它会更换生产密钥，导致数据库、Token、凭据失效。

说明:
  升级流程会记录 runtime/upgrade/<timestamp>.log，并写入 runtime/upgrade/latest.env。
  数据结构更新失败或新版本不可用时，脚本会尝试切回升级前版本并重新部署；数据库回滚需要使用
  scripts/restore-backup.sh 显式从备份恢复，避免自动猜测回退步骤造成二次破坏。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|--non-interactive)
      YES=1
      shift
      ;;
    --target)
      TARGET_REF="${2:-}"
      [[ -n "$TARGET_REF" ]] || die "--target 不能为空"
      shift 2
      ;;
    --mode)
      UPGRADE_MODE="${2:-}"
      [[ -n "$UPGRADE_MODE" ]] || die "--mode 不能为空"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-verify)
      NO_VERIFY=1
      shift
      ;;
    --skip-backup)
      SKIP_BACKUP=1
      shift
      ;;
    --i-understand-no-backup)
      CONFIRM_NO_BACKUP=1
      shift
      ;;
    --no-rollback-on-failure)
      ROLLBACK_ON_FAILURE=0
      shift
      ;;
    --force-config|--i-understand-force-config)
      # 升级必须复用现有 .env。强制重建配置会更换密钥，可能让旧数据无法解密。
      die "升级场景不得使用 $1。--force-config 会覆盖 .env 并更换生产密钥；如确实要重新初始化，请退出升级流程后执行 scripts/reinit-config.sh --config-only 或 --reset-stack。"
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

case "$UPGRADE_MODE" in
  manual|docker-updater|host-updater) ;;
  *) die "--mode 仅支持 manual、docker-updater、host-updater: $UPGRADE_MODE" ;;
esac

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

write_state() {
  local status="$1"
  local step="$2"
  mkdir -p "$LOG_DIR"
  cat >"$STATE_FILE" <<EOF
UPGRADE_STATUS=$status
UPGRADE_STEP=$step
UPGRADE_UPDATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
UPGRADE_PREVIOUS_REF=$PREVIOUS_REF
UPGRADE_TARGET_REF=$TARGET_REF
UPGRADE_BACKUP_DIR=$BACKUP_DIR
UPGRADE_LOG_FILE=$LOG_FILE
EOF
}

run_step() {
  FAILED_STEP="$1"
  shift
  write_state "running" "$FAILED_STEP"
  log "步骤: $FAILED_STEP"
  "$@"
}

rollback_code() {
  [[ "$ROLLBACK_ON_FAILURE" == "1" ]] || return 0
  [[ -n "$PREVIOUS_REF" ]] || return 0
  log "尝试切回升级前 Git 版本: $PREVIOUS_REF"
  git checkout "$PREVIOUS_REF" || return 1
  deploy_current_version --skip-online-check || return 1
}

deploy_current_version() {
  case "$UPGRADE_MODE" in
    docker-updater)
      BAIZE_DEPLOY_MODE=image bash scripts/deploy-server.sh "$@"
      ;;
    host-updater)
      bash scripts/deploy-host-server.sh
      ;;
    *)
      bash scripts/deploy-server.sh "$@"
      ;;
  esac
}

handle_failure() {
  local exit_code="$1"
  write_state "failed" "$FAILED_STEP"
  log "升级失败，失败步骤: ${FAILED_STEP:-unknown}，退出码: $exit_code"
  if [[ -n "$BACKUP_DIR" ]]; then
    log "如需恢复数据库与配置，请人工确认后执行:"
    log "  bash scripts/restore-backup.sh --backup-dir '$BACKUP_DIR' --yes"
  fi
  if rollback_code; then
    log "已尝试回滚代码并重新部署旧版本。请继续检查服务状态和数据库兼容性。"
  else
    log "自动代码回滚未完成或已禁用，请查看日志: $LOG_FILE"
  fi
  exit "$exit_code"
}

main() {
  cd "$ROOT_DIR"
  [[ -f docker-compose.yml ]] || die "请在 baize 公开发布仓运行"
  [[ -f .env ]] || die "未找到 .env，请先完成安装"
  [[ -d .git ]] || die "当前目录不是 Git 安装。tar.gz/拷贝安装请先下载新版本覆盖产物，并保留 .env 与 runtime/backups 后再执行 deploy-server.sh。"

  require_cmd git
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 不可用"

  PREVIOUS_REF="$(git rev-parse HEAD)"
  dirty_count="$(git status --short --untracked-files=no | wc -l | tr -d ' ')"
  if [[ "$dirty_count" != "0" && "$ALLOW_DIRTY" != "1" ]]; then
    git status --short --untracked-files=no >&2
    die "检测到已跟踪文件存在改动。请先提交/暂存处理，或确认风险后追加 --allow-dirty。"
  fi

  if [[ "$SKIP_BACKUP" == "1" ]]; then
    if [[ "$YES" != "1" || "$CONFIRM_NO_BACKUP" != "1" ]]; then
      die "--skip-backup 必须同时传 --yes --i-understand-no-backup"
    fi
  fi

  confirm "即将升级 Baize。脚本不会使用 --force-config，并会默认备份数据库。是否继续" || die "用户取消升级"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: mode=$UPGRADE_MODE previous=当前安装版本 target=${TARGET_REF:-当前分支最新版本}"
    bash scripts/check-install.sh --offline
    return 0
  fi

  baize_ensure_host_profile_security_code "$ROOT_DIR/.env"

  # 先备份再拉取代码，保证新版本数据结构更新失败时仍有可恢复的数据库快照。
  if [[ "$SKIP_BACKUP" != "1" ]]; then
    FAILED_STEP="backup"
    write_state "running" "$FAILED_STEP"
    log "步骤: $FAILED_STEP"
    BACKUP_DIR="$(bash scripts/backup.sh --yes | tail -n 1)"
    [[ -n "$BACKUP_DIR" ]] || die "备份脚本未返回备份目录"
  fi

  run_step "git-fetch" git fetch --tags origin
  if [[ -n "$TARGET_REF" ]]; then
    run_step "git-checkout" git checkout "$TARGET_REF"
  else
    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$current_branch" == "HEAD" ]]; then
      die "当前处于 detached HEAD，请通过 --target 指定要升级到的版本标签"
    fi
    run_step "git-pull" git pull --ff-only origin "$current_branch"
    TARGET_REF="$(git rev-parse HEAD)"
  fi

  run_step "offline-check" bash scripts/check-install.sh --offline
  run_step "deploy" deploy_current_version
  if [[ "$NO_VERIFY" != "1" ]]; then
    run_step "online-check" bash scripts/check-install.sh
  fi
  run_step "version" bash scripts/version.sh
  write_state "succeeded" "completed"
  log "升级完成"
}

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/upgrade-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "升级日志: $LOG_FILE"
set +e
main
main_exit=$?
set -e
if [[ "$main_exit" != "0" ]]; then
  handle_failure "$main_exit"
fi

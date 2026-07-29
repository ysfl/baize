#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALL_ROOT="$ROOT_DIR"
AGENT_DATA_DIR="/opt/baize-agent/data"
DRY_RUN=0
UNINSTALL=0

UPDATER_DEST="/usr/local/libexec/baize/image-updater"
UNIT_DEST="/etc/systemd/system/baize-image-upgrade@.service"
CONFIG_DEST="/etc/baize/image-updater.env"

log() {
  echo "[install-image-updater] $*" >&2
}

die() {
  echo "[install-image-updater] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/install-image-updater.sh [选项]

选项:
  --root <path>             白泽安装目录，默认当前仓库目录
  --agent-data-dir <path>   本机节点组件数据目录，默认 /opt/baize-agent/data
  --dry-run                 只检查并打印安装计划
  --uninstall               移除 updater 可执行文件和 systemd 单元
  -h, --help                显示帮助

English:
  Installs the fixed systemd updater used for independent Server and Web image upgrades.
EOF
}

ORIGINAL_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      INSTALL_ROOT="${2:-}"
      [[ -n "$INSTALL_ROOT" ]] || die "--root 不能为空"
      shift 2
      ;;
    --agent-data-dir)
      AGENT_DATA_DIR="${2:-}"
      [[ -n "$AGENT_DATA_DIR" ]] || die "--agent-data-dir 不能为空"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
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

validate_safe_absolute_path() {
  local option_name="$1"
  local value="$2"
  [[ "$value" == /* && "$value" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "$option_name 只支持不含空格和特殊字符的绝对路径"
  [[ "$value" != *"//"* && "$value" != *"/./"* && "$value" != */. && "$value" != *"/../"* && "$value" != */.. ]] \
    || die "$option_name 不能包含重复分隔符或相对路径段"
}

validate_safe_absolute_path --root "$INSTALL_ROOT"
validate_safe_absolute_path --agent-data-dir "$AGENT_DATA_DIR"

[[ "$(uname -s)" == "Linux" ]] || die "自动镜像升级只支持使用 systemd 的 Linux 宿主机"
command -v systemctl >/dev/null 2>&1 || die "缺少 systemctl"
[[ -d /run/systemd/system || "$DRY_RUN" == "1" ]] || die "当前 Linux 未使用 systemd"

if [[ "${EUID:-$(id -u)}" -ne 0 && "$DRY_RUN" != "1" ]]; then
  command -v sudo >/dev/null 2>&1 || die "需要 root 权限，且当前系统没有 sudo"
  exec sudo bash "$0" "${ORIGINAL_ARGS[@]}"
fi

if [[ "$UNINSTALL" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    log "将移除 $UPDATER_DEST、$UNIT_DEST 和 $CONFIG_DEST"
    exit 0
  fi
  rm -f "$UPDATER_DEST" "$UNIT_DEST" "$CONFIG_DEST"
  systemctl daemon-reload
  log "镜像 updater 已移除；历史请求、回执和日志仍保留在 $AGENT_DATA_DIR/image-upgrade"
  exit 0
fi

[[ "$INSTALL_ROOT" == /* && -d "$INSTALL_ROOT" ]] || die "--root 必须是已存在的绝对目录"
INSTALL_ROOT="$(cd "$INSTALL_ROOT" && pwd -P)"
validate_safe_absolute_path --root "$INSTALL_ROOT"
[[ "$AGENT_DATA_DIR" == /* ]] || die "--agent-data-dir 必须是绝对路径"
[[ -f "$ROOT_DIR/scripts/image-updater.sh" ]] || die "缺少 scripts/image-updater.sh"
[[ -f "$ROOT_DIR/systemd/baize-image-upgrade@.service" ]] || die "缺少 systemd 单元模板"
[[ -f "$INSTALL_ROOT/docker-compose.yml" && -f "$INSTALL_ROOT/.env" ]] || die "目标目录缺少 docker-compose.yml 或 .env"
command -v python3 >/dev/null 2>&1 || die "缺少 python3"
command -v docker >/dev/null 2>&1 || die "缺少 Docker"
command -v timeout >/dev/null 2>&1 || die "缺少 timeout"
command -v flock >/dev/null 2>&1 || die "缺少 flock"

if [[ "$DRY_RUN" == "1" ]]; then
  log "将安装固定 updater 到 $UPDATER_DEST"
  log "将安装 systemd 单元到 $UNIT_DEST"
  log "安装目录: $INSTALL_ROOT"
  log "节点组件数据目录: $AGENT_DATA_DIR"
  exit 0
fi

escape_environment_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

install -d -m 0755 "$(dirname "$UPDATER_DEST")" "$(dirname "$CONFIG_DEST")"
install -d -m 0700 \
  "$AGENT_DATA_DIR/image-upgrade/requests" \
  "$AGENT_DATA_DIR/image-upgrade/receipts" \
  "$AGENT_DATA_DIR/image-upgrade/logs" \
  "$INSTALL_ROOT/runtime/release" \
  "$INSTALL_ROOT/runtime/image-upgrade/backups"
install -o root -g root -m 0755 "$ROOT_DIR/scripts/image-updater.sh" "$UPDATER_DEST"

escaped_root="$(escape_environment_value "$INSTALL_ROOT")"
escaped_agent_data="$(escape_environment_value "$AGENT_DATA_DIR")"
config_tmp="$(mktemp "${CONFIG_DEST}.tmp.XXXXXX")"
unit_tmp="$(mktemp "${UNIT_DEST}.tmp.XXXXXX")"
trap 'rm -f "$config_tmp" "$unit_tmp"' EXIT
{
  printf 'BAIZE_ROOT_DIR="%s"\n' "$escaped_root"
  printf 'BAIZE_AGENT_DATA_DIR="%s"\n' "$escaped_agent_data"
} >"$config_tmp"
chmod 0600 "$config_tmp"
chown root:root "$config_tmp"
mv -f "$config_tmp" "$CONFIG_DEST"

sed \
  -e "s|@@BAIZE_ROOT_DIR@@|$INSTALL_ROOT|g" \
  -e "s|@@BAIZE_AGENT_DATA_DIR@@|$AGENT_DATA_DIR|g" \
  "$ROOT_DIR/systemd/baize-image-upgrade@.service" >"$unit_tmp"
chmod 0644 "$unit_tmp"
chown root:root "$unit_tmp"
mv -f "$unit_tmp" "$UNIT_DEST"
trap - EXIT

systemctl daemon-reload
if systemctl is-active --quiet baize-agent.service; then
  systemctl restart baize-agent.service
fi
log "镜像 updater 已安装；本机节点组件重连后会公布独立镜像升级能力"

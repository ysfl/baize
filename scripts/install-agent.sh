#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/agent/dist/install.sh"
DRY_RUN=0
SERVER_URL=""
REMOTE_SCRIPT=0
UNINSTALL=0
SYSTEM_ROLE="normal"
args=()

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/install-agent.sh --server <URL> --token <TOKEN> [选项]

说明:
  在需要纳管的宿主机上安装 Baize Agent。生产环境不建议把 Agent 放进 Docker，
  否则进程、磁盘、Nginx、Docker、systemd、防火墙等宿主机数据采集会受限。

常用选项:
  --server <URL>     Agent 可访问的白泽地址，例如 http://<你的服务器IP或域名>:22501
  --token <TOKEN>    注册 Token，可在控制台创建
  --system-role <ROLE>
                    Agent 系统身份，普通节点保持 normal；仅本机执行器使用 server_host
  --force            覆盖已有 Agent
  --uninstall        卸载 Agent
  --dry-run          只检查并打印即将执行的安装命令
  -h, --help         显示帮助

English:
  Install Baize Agent on the managed host. Direct host install is recommended;
  Agent-in-Docker is only suitable for local development.
EOF
}

run_builtin_uninstall() {
  local tmp_motd=""
  echo "[install-agent] 本地未包含 agent/dist/install.sh，使用内置卸载逻辑。" >&2
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux)
      systemctl stop baize-agent 2>/dev/null || true
      systemctl disable baize-agent 2>/dev/null || true
      rm -f /etc/systemd/system/baize-agent.service
      systemctl daemon-reload 2>/dev/null || true
      rm -f /etc/profile.d/99-baize-managed.sh /etc/motd.d/99-baize-managed
      if [[ -f /etc/motd && ! -L /etc/motd ]]; then
        tmp_motd="${TMPDIR:-/tmp}/baize-motd-clean.$$"
        if awk '$0 == "[Baize Managed Notice Begin]" { in_block=1; next } $0 == "[Baize Managed Notice End]" { in_block=0; next } in_block != 1 { print }' /etc/motd > "$tmp_motd"; then
          cat "$tmp_motd" > /etc/motd || true
        fi
        rm -f "$tmp_motd"
      fi
      rm -rf /opt/baize-agent
      ;;
    darwin)
      launchctl bootout system /Library/LaunchDaemons/com.baize.agent.plist >/dev/null 2>&1 || true
      rm -f /Library/LaunchDaemons/com.baize.agent.plist
      rm -rf /usr/local/baize-agent
      ;;
    *)
      echo "[install-agent] ERROR: 当前系统不支持内置卸载，请使用对应平台的 Agent 安装器。" >&2
      exit 1
      ;;
  esac
  echo "[install-agent] Baize Agent 已卸载完成。" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      SERVER_URL="${2:-}"
      [[ -n "$SERVER_URL" ]] || {
        echo "[install-agent] ERROR: --server 不能为空" >&2
        exit 1
      }
      args+=("$1" "$2")
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      args+=("$1")
      shift
      ;;
    --system-role)
      SYSTEM_ROLE="${2:-}"
      [[ -n "$SYSTEM_ROLE" ]] || {
        echo "[install-agent] ERROR: --system-role 不能为空" >&2
        exit 1
      }
      args+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      usage
      echo ""
      if [[ -f "$INSTALL_SCRIPT" ]]; then
        bash "$INSTALL_SCRIPT" --help
      else
        echo "本地未包含 agent/dist/install.sh；安装时会从 --server 下载 /install.sh。"
      fi
      exit 0
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ "$UNINSTALL" != "1" && -z "$SERVER_URL" ]]; then
  echo "[install-agent] ERROR: 请传入 --server <URL>，该地址必须是用户自部署的白泽访问地址。" >&2
  exit 1
fi

resolve_remote_install_script() {
  local server="$1"
  local tmp_file
  command -v curl >/dev/null 2>&1 || {
    echo "[install-agent] ERROR: 本地没有 agent/dist/install.sh，且缺少 curl，无法从白泽地址下载安装脚本。" >&2
    exit 1
  }
  server="${server%/}"
  tmp_file="$(mktemp)"
  curl --max-time 20 -fsSL "$server/install.sh" -o "$tmp_file" || {
    rm -f "$tmp_file"
    echo "[install-agent] ERROR: 无法从 $server/install.sh 下载 Agent 安装脚本，请确认白泽地址可访问。" >&2
    exit 1
  }
  chmod +x "$tmp_file"
  printf '%s' "$tmp_file"
}

read_local_deploy_mode() {
  local env_file="$ROOT_DIR/.env"
  [[ -f "$env_file" ]] || return 0
  awk -F= '
    $0 !~ /^[[:space:]]*#/ && $1 == "BAIZE_DEPLOY_MODE" {
      sub(/^[^=]*=/, "")
      gsub(/^[[:space:]"'\'' ]+|[[:space:]"'\'' ]+$/, "")
      print
      exit
    }
  ' "$env_file"
}

run_privileged_script() {
  local script="$1"
  shift
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    bash "$script" "$@"
  else
    sudo bash "$script" "$@"
  fi
}

preserve_image_upgrade_history() {
  local source_dir="/opt/baize-agent/data/image-upgrade"
  local history_root="/var/lib/baize/image-upgrade-history"
  local destination="$history_root/$(date -u '+%Y%m%dT%H%M%SZ')"
  [[ "$(uname -s)" == "Linux" && -d "$source_dir" ]] || return 0
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    install -d -m 0700 "$destination"
    cp -a "$source_dir/." "$destination/"
  else
    sudo install -d -m 0700 "$destination"
    sudo cp -a "$source_dir/." "$destination/"
  fi
  echo "[install-agent] 镜像升级历史已保留到 $destination" >&2
}

manage_image_updater() {
  local action="$1"
  local updater_installer="$ROOT_DIR/scripts/install-image-updater.sh"
  [[ "$(uname -s)" == "Linux" && -f "$updater_installer" ]] || return 0
  if [[ "$action" == "install" ]]; then
    [[ "$SYSTEM_ROLE" == "server_host" ]] || return 0
    if [[ "$(read_local_deploy_mode)" != "image" ]]; then
      echo "[install-agent] 当前不是镜像部署，跳过自动镜像升级组件。" >&2
      return 0
    fi
    run_privileged_script "$updater_installer" --root "$ROOT_DIR"
    return
  fi
  if [[ -f /etc/systemd/system/baize-image-upgrade@.service || -f /usr/local/libexec/baize/image-updater ]]; then
    run_privileged_script "$updater_installer" --root "$ROOT_DIR" --uninstall
  fi
}

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
  if [[ "$UNINSTALL" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[install-agent] 本地未包含 agent/dist/install.sh，将使用内置卸载逻辑。" >&2
      exit 0
    fi
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      preserve_image_upgrade_history
      manage_image_updater uninstall
      run_builtin_uninstall
      exit 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
      echo "[install-agent] ERROR: 当前用户不是 root，且系统缺少 sudo。请切换 root 后重试。" >&2
      exit 1
    fi
    if ! sudo -n true >/dev/null 2>&1; then
      echo "[install-agent] 需要 sudo 权限卸载 systemd/launchd 服务，接下来可能要求输入当前用户密码。" >&2
    fi
    exec sudo bash "$0" --uninstall
  fi
  [[ -n "$SERVER_URL" ]] || {
    echo "[install-agent] ERROR: 本地未包含 agent/dist/install.sh。请传入 --server <URL>，脚本会从 <URL>/install.sh 下载安装器。" >&2
    exit 1
  }
  if [[ "$DRY_RUN" == "1" ]]; then
    INSTALL_SCRIPT="${SERVER_URL%/}/install.sh"
    REMOTE_SCRIPT=1
  else
    INSTALL_SCRIPT="$(resolve_remote_install_script "$SERVER_URL")"
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ "$REMOTE_SCRIPT" == "1" ]]; then
    echo "[install-agent] 将从远端下载安装脚本: $INSTALL_SCRIPT" >&2
  else
    echo "[install-agent] 安装脚本存在: $INSTALL_SCRIPT" >&2
  fi
  if [[ "$REMOTE_SCRIPT" == "1" ]]; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      printf '[install-agent] 将执行: curl -fsSL %q -o <tmp> && bash <tmp>' "$INSTALL_SCRIPT" >&2
    else
      printf '[install-agent] 将执行: curl -fsSL %q -o <tmp> && sudo bash <tmp>' "$INSTALL_SCRIPT" >&2
    fi
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf '[install-agent] 将执行: bash %q' "$INSTALL_SCRIPT" >&2
  else
    printf '[install-agent] 将执行: sudo bash %q' "$INSTALL_SCRIPT" >&2
  fi
  for arg in "${args[@]}"; do
    printf ' %q' "$arg" >&2
  done
  printf '\n' >&2
  if [[ "$(uname -s)" == "Linux" && "$SYSTEM_ROLE" == "server_host" && "$(read_local_deploy_mode)" == "image" ]]; then
    bash "$ROOT_DIR/scripts/install-image-updater.sh" --root "$ROOT_DIR" --dry-run
  fi
  exit 0
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  echo "[install-agent] ERROR: 当前用户不是 root，且系统缺少 sudo。请切换 root 后重试。" >&2
  exit 1
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! sudo -n true >/dev/null 2>&1; then
  echo "[install-agent] 需要 sudo 权限安装 systemd/launchd 服务，接下来可能要求输入当前用户密码。" >&2
fi

if [[ "$UNINSTALL" == "1" ]]; then
  preserve_image_upgrade_history
  manage_image_updater uninstall
fi

run_privileged_script "$INSTALL_SCRIPT" "${args[@]}"

if [[ "$UNINSTALL" != "1" ]]; then
  manage_image_updater install
fi

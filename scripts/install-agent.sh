#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/agent/dist/install.sh"
DRY_RUN=0
SERVER_URL=""
REMOTE_SCRIPT=0
args=()

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/install-agent.sh --server <URL> --token <TOKEN> [选项]

说明:
  在需要纳管的宿主机上安装 Baize Agent。生产环境不建议把 Agent 放进 Docker，
  否则进程、磁盘、Nginx、Docker、systemd、防火墙等宿主机数据采集会受限。

常用选项:
  --server <URL>     Agent 可访问的白泽地址，例如 https://baize.example.com
  --token <TOKEN>    注册 Token，可在控制台创建
  --force            覆盖已有 Agent
  --uninstall        卸载 Agent
  --dry-run          只检查并打印即将执行的安装命令
  -h, --help         显示帮助

English:
  Install Baize Agent on the managed host. Direct host install is recommended;
  Agent-in-Docker is only suitable for local development.
EOF
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

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
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
  exit 0
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  exec bash "$INSTALL_SCRIPT" "${args[@]}"
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "[install-agent] ERROR: 当前用户不是 root，且系统缺少 sudo。请切换 root 后重试。" >&2
  exit 1
fi

if ! sudo -n true >/dev/null 2>&1; then
  echo "[install-agent] 需要 sudo 权限安装 systemd/launchd 服务，接下来可能要求输入当前用户密码。" >&2
fi

exec sudo bash "$INSTALL_SCRIPT" "${args[@]}"

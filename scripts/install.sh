#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANGUAGE="${BAIZE_LANG:-zh}"
INTERACTIVE=0
VERIFY_AGENT=0
CONFIG_ARGS=()
DEPLOY_ARGS=()

log() {
  echo "[install] $*" >&2
}

die() {
  echo "[install] ERROR: $*" >&2
  exit 1
}

on_signal() {
  log "安装已取消；如果已经生成 .env，文件和已启动的服务都会保留，可在安装目录重新执行 bash scripts/install.sh --yes"
  exit 130
}

trap on_signal INT TERM

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/install.sh
  bash scripts/install.sh --yes --public-url http://<你的服务器IP或域名>:22501

说明:
  这是面向最终用户的一键入口。默认在 TTY 中进入交互式配置，随后部署 PostgreSQL、
  Redis、中心服务与控制台容器，并执行在线检查。

常用选项:
  --yes                         参数模式，不进入交互
  --lang <zh|en>                提示语言，默认 zh
  --public-url <url>            Agent 可访问的白泽地址
  --web-api-base-url <url>      控制台访问白泽服务的地址，默认 /api/v1
  --server-public-port <port>   中心服务宿主机端口
  --web-public-port <port>      控制台宿主机端口
  --postgres-public-port <port> PostgreSQL 宿主机端口
  --redis-public-port <port>    Redis 宿主机端口
  --server-target-arch <arch>   中心服务架构 amd64/arm64
  --deploy-mode <auto|image|build>
                                部署模式：auto 自动判断，image 拉取镜像，build 使用本地产物
  --stack-mode <full|server-only>
                                部署形态：full 启动控制台；server-only 只启动中心服务
  --server-image <image>        中心服务镜像名
  --web-image <image>           控制台镜像名
  --version <version>           镜像标签版本
  --backup-dir <path>           备份文件根目录，默认 ~/.baize/backups/baize-<实例哈希>
  --force-config                危险操作：覆盖 .env 并重新生成随机密钥
  --i-understand-force-config   确认理解 --force-config 会更换生产密钥
  --verify-agent                部署后启动临时 Agent 做本机闭环验证
  --skip-server-host-agent      跳过自动安装本机执行器
  --install-server-host-agent   非交互环境也尝试申请权限安装本机执行器
  --skip-geoip                  不自动下载可选的离线 GeoIP 数据库
  --require-geoip               缺少 GeoIP 数据库时阻止安装
  --timeout <seconds>           健康检查等待上限，默认 180
  -h, --help                    显示帮助

English:
  Run without options for an interactive installer, or use --yes with explicit
  options for automation. The default console service URL is /api/v1, which lets
  the console container proxy API and WebSocket traffic on the same origin.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|--non-interactive)
      INTERACTIVE=0
      shift
      ;;
    --interactive)
      INTERACTIVE=1
      shift
      ;;
    --verify-agent)
      VERIFY_AGENT=1
      shift
      ;;
    --lang)
      LANGUAGE="${2:-}"
      [[ -n "$LANGUAGE" ]] || die "--lang 不能为空"
      DEPLOY_ARGS+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --force-config|--i-understand-force-config|--skip-build|--skip-online-check|--skip-server-host-agent|--install-server-host-agent|--skip-geoip|--require-geoip)
      DEPLOY_ARGS+=("$1")
      shift
      ;;
    --timeout)
      [[ -n "${2:-}" ]] || die "$1 不能为空"
      DEPLOY_ARGS+=("$1" "$2")
      shift 2
      ;;
    --public-url|--agent-public-url|--web-api-base-url|--server-public-port|--web-public-port|--postgres-public-port|--redis-public-port|--server-target-arch|--deploy-mode|--stack-mode|--server-image|--web-image|--version|--backup-dir)
      [[ -n "${2:-}" ]] || die "$1 不能为空"
      CONFIG_ARGS+=("$1" "$2")
      shift 2
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

case "$LANGUAGE" in
  zh|en) ;;
  *) die "不支持的语言 / unsupported language: $LANGUAGE" ;;
esac

if [[ " ${DEPLOY_ARGS[*]} " == *" --force-config "* && " ${DEPLOY_ARGS[*]} " != *" --i-understand-force-config "* ]]; then
  die "--force-config 必须同时追加 --i-understand-force-config，避免意外更换生产密钥"
fi

if [[ ! -f "$ROOT_DIR/docker-compose.yml" ]]; then
  die "请在 baize 公开发布仓中运行 / please run inside the baize release repository"
fi

if [[ ${#CONFIG_ARGS[@]} -eq 0 && ${#DEPLOY_ARGS[@]} -eq 0 && -t 0 ]]; then
  INTERACTIVE=1
fi

if [[ "$INTERACTIVE" == "1" ]]; then
  log "进入交互式部署 / starting interactive deployment"
  init_args=(--interactive --lang "$LANGUAGE")
  if [[ " ${DEPLOY_ARGS[*]} " == *" --force-config "* ]]; then
    init_args+=(--force)
  fi
  bash "$ROOT_DIR/scripts/init-config.sh" "${init_args[@]}" "${CONFIG_ARGS[@]}"
  bash "$ROOT_DIR/scripts/deploy-server.sh" "${DEPLOY_ARGS[@]}"
else
  log "进入参数式部署 / starting non-interactive deployment"
  bash "$ROOT_DIR/scripts/deploy-server.sh" --lang "$LANGUAGE" "${CONFIG_ARGS[@]}" "${DEPLOY_ARGS[@]}"
fi

if [[ "$VERIFY_AGENT" == "1" ]]; then
  log "启动临时 Agent 做闭环验证 / running temporary Agent verification"
  bash "$ROOT_DIR/scripts/verify-local-stack.sh" --with-agent
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
PUBLIC_URL="${AGENT_PUBLIC_SERVER_URL:-}"
FORCE_CONFIG=0
CONFIRM_FORCE_CONFIG=0
SKIP_ONLINE_CHECK=0
SKIP_BUILD=0
SKIP_SERVER_HOST_AGENT=0
INIT_ARGS=()

log() {
  echo "[deploy-server] $*" >&2
}

die() {
  echo "[deploy-server] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/deploy-server.sh [选项]

选项:
  --public-url <url>             Agent 可访问的白泽地址
  --agent-public-url <url>       --public-url 的别名
  --web-api-base-url <url>       控制台访问白泽服务的地址，默认 /api/v1
  --server-public-port <port>    中心服务宿主机端口
  --web-public-port <port>       控制台宿主机端口
  --postgres-public-port <port>  PostgreSQL 宿主机端口
  --redis-public-port <port>     Redis 宿主机端口
  --server-target-arch <arch>    中心服务架构 amd64/arm64
  --deploy-mode <auto|image|build>
                                 auto 自动选择；image 拉取镜像；build 使用本地产物构建镜像
  --stack-mode <full|server-only>
                                 full 部署中心服务与控制台；server-only 只部署中心服务
  --server-image <image>         中心服务镜像名，可替换为自己的镜像仓库
  --web-image <image>            控制台镜像名，可替换为自己的镜像仓库
  --version <version>            镜像标签版本
  --backup-dir <path>            备份文件根目录，默认 ~/.baize/backups/baize-<实例哈希>
  --force-config                 危险操作：覆盖 .env 并重新生成随机密钥
  --i-understand-force-config    确认理解 --force-config 会更换生产密钥
  --skip-build                   不重新构建中心服务/控制台镜像
  --skip-online-check            启动后跳过 HTTP 在线检查
  --skip-server-host-agent       跳过自动安装本机执行器
  -h, --help                     显示帮助

English:
  Deploy PostgreSQL, Redis, Baize control service and optional console with Docker Compose.
  Pass options for automation, or run scripts/install.sh for the guided installer.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-url|--agent-public-url|--web-api-base-url|--server-public-port|--web-public-port|--postgres-public-port|--redis-public-port|--server-target-arch|--deploy-mode|--stack-mode|--server-image|--web-image|--version|--backup-dir)
      [[ -n "${2:-}" ]] || die "$1 不能为空"
      INIT_ARGS+=("$1" "$2")
      if [[ "$1" == "--public-url" || "$1" == "--agent-public-url" ]]; then
        PUBLIC_URL="$2"
      fi
      shift 2
      ;;
    --force-config)
      FORCE_CONFIG=1
      shift
      ;;
    --i-understand-force-config)
      CONFIRM_FORCE_CONFIG=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-online-check)
      SKIP_ONLINE_CHECK=1
      shift
      ;;
    --skip-server-host-agent)
      SKIP_SERVER_HOST_AGENT=1
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

json_get() {
  local expr="$1"
  python3 -c '
import json, sys
expr = sys.argv[1].split(".")
data = json.load(sys.stdin)
for key in expr:
    if key:
        data = data[key]
print(data)
' "$expr"
}

env_flag_enabled_by_default() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    false|0|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

port_is_listening() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port" && return 0
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
  fi
  return 1
}

compose_service_exists() {
  local service="$1"
  [[ -n "$(baize_compose "$DEPLOY_MODE" ps -q "$service" 2>/dev/null || true)" ]]
}

ensure_port_available() {
  local key="$1"
  local service="$2"
  local port
  port="$(read_env "$key")"
  [[ -n "$port" ]] || return
  if compose_service_exists "$service"; then
    return
  fi
  if port_is_listening "$port"; then
    die "$key=$port 已被占用。请换端口后执行 scripts/init-config.sh --force，或停止占用该端口的服务。"
  fi
}

wait_for_health() {
  local service="$1"
  local timeout="${2:-90}"
  local start now cid status
  start="$(date +%s)"
  log "等待 ${service} 健康 / waiting for ${service} health"
  while true; do
    cid="$(baize_compose "$DEPLOY_MODE" ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      if [[ "$status" == "healthy" || "$status" == "running" ]]; then
        log "${service} 已就绪 / ${service} is ready"
        return
      fi
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      baize_compose "$DEPLOY_MODE" logs --tail=120 "$service" >&2 || true
      die "${service} 等待超时 / timed out waiting for ${service}"
    fi
    sleep 2
  done
}

server_host_agent_already_installed() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux)
      [[ -f /opt/baize-agent/baize-agent || -f /opt/baize-agent/data/agent_id ]]
      ;;
    darwin)
      [[ -f /usr/local/baize-agent/baize-agent || -f /usr/local/baize-agent/data/agent_id ]]
      ;;
    *)
      return 1
      ;;
  esac
}

install_server_host_agent() {
  if [[ "$SKIP_SERVER_HOST_AGENT" == "1" ]]; then
    log "已跳过本机执行器自动安装 / skipped server-host agent"
    return
  fi

  local enabled
  enabled="$(read_env BAIZE_SERVER_HOST_AGENT_ENABLED)"
  if ! env_flag_enabled_by_default "$enabled"; then
    log "BAIZE_SERVER_HOST_AGENT_ENABLED=false，跳过本机执行器自动安装"
    return
  fi

  if server_host_agent_already_installed; then
    log "检测到本机已安装 Agent，跳过自动覆盖；如需重装请先执行 scripts/install-agent.sh --uninstall"
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "缺少 curl，跳过本机执行器自动安装；可稍后运行 scripts/install-agent.sh 手动安装"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log "缺少 python3，跳过本机执行器自动安装；可稍后运行 scripts/install-agent.sh 手动安装"
    return
  fi

  local server_port internal_url agent_server_url api_url admin_user admin_password
  server_port="$(read_env SERVER_PUBLIC_PORT)"
  internal_url="$(read_env BAIZE_SERVER_HOST_AGENT_INTERNAL_URL)"
  if [[ -z "$internal_url" ]]; then
    internal_url="http://127.0.0.1:${server_port}"
  fi
  internal_url="${internal_url%/}"
  api_url="$internal_url"
  if [[ "$api_url" != */api/v1 ]]; then
    api_url="${api_url}/api/v1"
  fi
  agent_server_url="$internal_url"
  if [[ "$agent_server_url" == */api/v1 ]]; then
    agent_server_url="${agent_server_url%/api/v1}"
  fi

  admin_user="$(read_env ADMIN_USERNAME)"
  admin_password="$(read_env ADMIN_PASSWORD)"
  if [[ -z "$admin_user" || -z "$admin_password" ]]; then
    log "缺少 ADMIN_USERNAME 或 ADMIN_PASSWORD，跳过本机执行器自动安装"
    return
  fi

  log "准备安装本机执行器 / preparing server-host agent"
  local login_body login_response auth_token
  login_body="$(python3 -c 'import json, sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))' "$admin_user" "$admin_password")"
  if ! login_response="$(curl --max-time 15 -fsS -H "Content-Type: application/json" -d "$login_body" "$api_url/auth/login")"; then
    log "管理员登录失败，跳过本机执行器自动安装；请确认 ADMIN_PASSWORD 仍是当前管理员密码"
    return
  fi
  auth_token="$(printf '%s' "$login_response" | json_get data.token 2>/dev/null || true)"
  if [[ -z "$auth_token" ]]; then
    log "登录响应缺少 token，跳过本机执行器自动安装"
    return
  fi

  local token_name token_body token_response registration_token
  token_name="server-host-$(date +%Y%m%d%H%M%S)"
  token_body="$(python3 -c 'import json, sys; print(json.dumps({"name": sys.argv[1], "type": "single", "quota": 1, "expires_in_hours": 1, "note": "server host agent bootstrap", "system_role": "server_host"}))' "$token_name")"
  if ! token_response="$(curl --max-time 15 -fsS -H "Authorization: Bearer ${auth_token}" -H "Content-Type: application/json" -d "$token_body" "$api_url/tokens")"; then
    log "创建本机执行器注册令牌失败，跳过自动安装"
    return
  fi
  registration_token="$(printf '%s' "$token_response" | json_get data.token 2>/dev/null || true)"
  if [[ -z "$registration_token" ]]; then
    log "注册令牌响应缺少明文 token，跳过本机执行器自动安装"
    return
  fi

  if bash "$ROOT_DIR/scripts/install-agent.sh" --server "$agent_server_url" --token "$registration_token" --system-role server_host; then
    log "本机执行器安装已启动 / server-host agent installation started"
  else
    log "本机执行器自动安装失败；中心服务已部署完成，可稍后运行 scripts/install-agent.sh 手动修复"
  fi
}

cd "$ROOT_DIR"

require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 不可用，请先安装 Docker Desktop 或 docker compose plugin"

if [[ "$FORCE_CONFIG" == "1" && "$CONFIRM_FORCE_CONFIG" != "1" ]]; then
  # 二次确认是刻意设计的硬门槛，防止升级或重部署时误重置生产密钥。
  die "--force-config 会覆盖 .env 并重新生成数据库、Redis、JWT、管理员和凭据密钥。生产环境不得使用，除非你知道自己在做什么；如确认要重初始化，推荐执行 scripts/reinit-config.sh --config-only 或 --reset-stack，也可在已备份并接受风险后追加 --i-understand-force-config。"
fi

if [[ ! -f .env || "$FORCE_CONFIG" == "1" ]]; then
  args=("${INIT_ARGS[@]}")
  if [[ "$FORCE_CONFIG" == "1" ]]; then
    args+=(--force)
  fi
  if [[ ${#args[@]} -eq 0 && -n "$PUBLIC_URL" ]]; then
    args+=(--public-url "$PUBLIC_URL")
  fi
  bash scripts/init-config.sh "${args[@]}"
elif [[ ${#INIT_ARGS[@]} -gt 0 ]]; then
  die ".env 已存在。为避免误改生产密钥，带配置参数部署时请显式追加 --force-config，或先手动编辑 .env。"
fi

baize_ensure_host_profile_security_code "$ROOT_DIR/.env"
bash scripts/check-install.sh --offline
DEPLOY_MODE="$(baize_resolve_deploy_mode "$ROOT_DIR/.env")"
STACK_MODE="$(baize_resolve_stack_mode "$ROOT_DIR/.env")"
if [[ "$DEPLOY_MODE" == "build" ]]; then
  baize_require_build_artifacts "$ROOT_DIR/.env" "$STACK_MODE"
fi

ensure_port_available POSTGRES_PUBLIC_PORT postgres
ensure_port_available REDIS_PUBLIC_PORT redis
ensure_port_available SERVER_PUBLIC_PORT server
if baize_stack_has_web "$STACK_MODE"; then
  ensure_port_available WEB_PUBLIC_PORT web
fi

log "启动 PostgreSQL / Redis"
baize_compose "$DEPLOY_MODE" up -d postgres redis
wait_for_health postgres 120
wait_for_health redis 90

app_services=(server)
if baize_stack_has_web "$STACK_MODE"; then
  app_services+=(web)
fi

if baize_stack_has_web "$STACK_MODE"; then
  log "启动中心服务 / 控制台"
else
  log "启动中心服务（server-only）"
fi
if [[ "$SKIP_BUILD" == "1" ]]; then
  baize_compose "$DEPLOY_MODE" up -d "${app_services[@]}"
elif [[ "$DEPLOY_MODE" == "build" ]]; then
  baize_compose "$DEPLOY_MODE" up -d --build "${app_services[@]}"
else
  if ! baize_compose "$DEPLOY_MODE" pull "${app_services[@]}"; then
    log "镜像拉取失败。请检查 BAIZE_SERVER_IMAGE / BAIZE_WEB_IMAGE，或改用 BAIZE_DEPLOY_MODE=build 并提供发布产物。"
    exit 1
  fi
  baize_compose "$DEPLOY_MODE" up -d "${app_services[@]}"
fi
wait_for_health server 120
if baize_stack_has_web "$STACK_MODE"; then
  wait_for_health web 90
fi

if [[ "$SKIP_ONLINE_CHECK" != "1" ]]; then
  bash scripts/check-install.sh
fi
install_server_host_agent

baize_compose "$DEPLOY_MODE" ps
log "部署完成 / deployment completed"
if baize_stack_has_web "$STACK_MODE"; then
  log "控制台: http://127.0.0.1:$(read_env WEB_PUBLIC_PORT)"
else
  log "部署形态: server-only（未启动控制台容器）"
fi
log "服务地址: http://127.0.0.1:$(read_env SERVER_PUBLIC_PORT)/api/v1"
log "管理员账号 admin，初始密码在 .env 的 ADMIN_PASSWORD 中。首次登录后请立即修改。"

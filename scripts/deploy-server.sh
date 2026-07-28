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
FORCE_SERVER_HOST_AGENT=0
SKIP_GEOIP=0
REQUIRE_GEOIP=0
LANGUAGE="${BAIZE_LANG:-zh}"
HEALTH_TIMEOUT_SECONDS="${BAIZE_INSTALL_TIMEOUT_SECONDS:-180}"
INIT_ARGS=()
DEPLOY_MODE=""
STACK_MODE=""
STAGE="参数解析"
INTERRUPTED=0

log() {
  echo "[deploy-server] $*" >&2
}

die() {
  echo "[deploy-server] ERROR: $*" >&2
  exit 1
}

on_signal() {
  INTERRUPTED=1
  echo "[deploy-server] 已收到中断信号，正在保留现场并输出恢复提示 / interrupted; preserving the current state" >&2
  exit 130
}

show_failure_context() {
  local exit_code="$1"
  if [[ -f "$ROOT_DIR/.env" ]]; then
    log "配置文件已保留: $ROOT_DIR/.env"
    log "可直接重试: cd '$ROOT_DIR' && bash scripts/install.sh --yes"
  else
    log "尚未生成配置文件；修复上述前置条件后，可重新执行 bash scripts/install.sh"
  fi
  if [[ -n "$DEPLOY_MODE" ]] && command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "当前容器状态 / current container state:"
    baize_compose "$DEPLOY_MODE" ps -a >&2 || true
    for service in postgres redis server web; do
      if baize_compose "$DEPLOY_MODE" ps -aq "$service" 2>/dev/null | grep -q .; then
        log "${service} 最近日志 / recent ${service} logs:"
        baize_compose "$DEPLOY_MODE" logs --tail=80 "$service" >&2 || true
      fi
    done
  fi
  log "如需查看完整状态，请执行: cd '$ROOT_DIR' && bash scripts/check-install.sh --allow-missing-geoip"
  log "失败不会自动删除数据卷；确认不再需要现场后，再使用 scripts/uninstall.sh 清理"
  return "$exit_code"
}

on_exit() {
  local exit_code="$1"
  [[ "$exit_code" == "0" ]] && return 0
  if [[ "$INTERRUPTED" == "1" || "$exit_code" == "130" || "$exit_code" == "143" ]]; then
    log "安装已取消，阶段: ${STAGE}，退出码: ${exit_code}"
  else
    log "安装未完成，阶段: ${STAGE}，退出码: ${exit_code}"
  fi
  show_failure_context "$exit_code" || true
}

trap 'on_signal' INT TERM
trap 'on_exit "$?"' EXIT

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
  --stack-mode <full|server-only>
                                 full 部署中心服务与控制台；server-only 只部署中心服务
  --server-image <image>         中心服务镜像名，可替换为自己的镜像仓库
  --web-image <image>            控制台镜像名，可替换为自己的镜像仓库
  --version <version>            镜像标签版本
  --backup-dir <path>            备份文件根目录，默认 ~/.baize/backups/baize-<实例哈希>
  --force-config                 危险操作：覆盖 .env 并重新生成随机密钥
  --i-understand-force-config    确认理解 --force-config 会更换生产密钥
  --skip-online-check            启动后跳过 HTTP 在线检查
  --skip-server-host-agent       跳过自动安装本机执行器
  --install-server-host-agent    非交互环境也尝试申请权限安装本机执行器
  --skip-geoip                   不自动下载可选的离线 GeoIP 数据库
  --require-geoip                缺少 GeoIP 数据库时阻止安装
  --timeout <seconds>            健康检查等待上限，默认 180
  --lang <zh|en>                 提示语言，默认读取 BAIZE_LANG
  --image-source <github|acr>    下载来源；中国大陆推荐 acr
  --postgres-image <image>       TimescaleDB 镜像名
  --redis-image <image>          Redis 镜像名
  -h, --help                     显示帮助

English:
  Deploy PostgreSQL, Redis, Baize control service and optional console with Docker Compose.
  Pass options for automation, or run scripts/install.sh for the guided installer.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-url|--agent-public-url|--web-api-base-url|--server-public-port|--web-public-port|--postgres-public-port|--redis-public-port|--server-target-arch|--deploy-mode|--stack-mode|--image-source|--server-image|--web-image|--postgres-image|--redis-image|--version|--backup-dir)
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
    --install-server-host-agent)
      FORCE_SERVER_HOST_AGENT=1
      shift
      ;;
    --skip-geoip)
      SKIP_GEOIP=1
      shift
      ;;
    --require-geoip)
      REQUIRE_GEOIP=1
      shift
      ;;
    --timeout)
      HEALTH_TIMEOUT_SECONDS="${2:-}"
      [[ -n "$HEALTH_TIMEOUT_SECONDS" ]] || die "--timeout 不能为空"
      shift 2
      ;;
    --lang)
      LANGUAGE="${2:-}"
      [[ -n "$LANGUAGE" ]] || die "--lang 不能为空"
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

case "$LANGUAGE" in
  zh|en) ;;
  *) die "不支持的语言 / unsupported language: $LANGUAGE" ;;
esac

[[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout 必须是数字: $HEALTH_TIMEOUT_SECONDS"
(( HEALTH_TIMEOUT_SECONDS >= 10 && HEALTH_TIMEOUT_SECONDS <= 1800 )) || die "--timeout 必须在 10 到 1800 秒之间"
if [[ "$SKIP_GEOIP" == "1" && "$REQUIRE_GEOIP" == "1" ]]; then
  die "--skip-geoip 与 --require-geoip 不能同时使用"
fi

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
    die "$key=$port 已被占用。请编辑 .env 换成未使用端口，或确认备份后执行 scripts/reinit-config.sh 重新生成配置。"
  fi
}

wait_for_health() {
  local service="$1"
  local timeout="${2:-$HEALTH_TIMEOUT_SECONDS}"
  local start now cid inspect_status state_status health_status status last_report=0
  start="$(date +%s)"
  log "等待 ${service} 健康 / waiting for ${service} health"
  while true; do
    cid="$(baize_compose "$DEPLOY_MODE" ps -aq "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      inspect_status="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
      state_status="${inspect_status%%|*}"
      health_status="${inspect_status#*|}"
      status="${state_status:-未知}"
      if [[ -n "$health_status" && "$health_status" != "none" && "$health_status" != "$inspect_status" ]]; then
        status="${status}/${health_status}"
      fi
      if [[ "$health_status" == "healthy" || ( "$health_status" == "none" && "$state_status" == "running" ) ]]; then
        log "${service} 已就绪 / ${service} is ready"
        return
      fi
      case "$state_status" in
        exited|dead|restarting)
          baize_compose "$DEPLOY_MODE" logs --tail=120 "$service" >&2 || true
          die "${service} 容器状态异常（${state_status}），请查看上面的容器日志"
          ;;
      esac
      if [[ "$health_status" == "unhealthy" ]]; then
        baize_compose "$DEPLOY_MODE" logs --tail=120 "$service" >&2 || true
        die "${service} 健康检查失败（unhealthy），请查看上面的容器日志"
      fi
    fi
    now="$(date +%s)"
    if (( now - last_report >= 10 )); then
      log "${service} 当前状态: ${status:-未创建}，已等待 $((now - start)) 秒"
      last_report="$now"
    fi
    if (( now - start >= timeout )); then
      baize_compose "$DEPLOY_MODE" logs --tail=120 "$service" >&2 || true
      die "${service} 等待超时 / timed out waiting for ${service}"
    fi
    sleep 2
  done
}

check_docker_ready() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 不可用，请先安装 Docker Compose plugin"
  if ! docker info >/dev/null 2>&1; then
    die "Docker 守护进程未运行或当前用户无权访问。请启动 Docker，再重试；Linux 可检查 systemctl status docker，macOS/Windows 请启动 Docker Desktop。"
  fi
}

geoip_files_ready() {
  local city_path asn_path
  city_path="$(baize_strip_env_quotes "$(read_env GEOIP_CITY_MMDB_PATH)")"
  asn_path="$(baize_strip_env_quotes "$(read_env GEOIP_ASN_MMDB_PATH)")"
  case "$city_path" in
    /app/runtime/*) city_path="$ROOT_DIR/runtime/${city_path#/app/runtime/}" ;;
  esac
  case "$asn_path" in
    /app/runtime/*) asn_path="$ROOT_DIR/runtime/${asn_path#/app/runtime/}" ;;
  esac
  [[ -s "$city_path" && -s "$asn_path" ]]
}

ensure_geoip() {
  local offline_only auto_install
  if [[ "$SKIP_GEOIP" == "1" ]]; then
    log "已跳过 GeoIP 自动准备；地区字段可能暂时为空"
    return
  fi
  offline_only="$(baize_strip_env_quotes "$(read_env GEOIP_OFFLINE_ONLY)")"
  case "$offline_only" in
    true|TRUE|1|yes|YES|on|ON) ;;
    *) return ;;
  esac
  if geoip_files_ready; then
    log "GeoIP 数据库已就绪"
    return
  fi
  auto_install="$(baize_strip_env_quotes "$(read_env BAIZE_AUTO_INSTALL_GEOIP)")"
  case "$auto_install" in
    false|FALSE|0|no|NO|off|OFF)
      if [[ "$REQUIRE_GEOIP" == "1" ]]; then
        die "BAIZE_AUTO_INSTALL_GEOIP=false，但 --require-geoip 要求数据库必须存在；请先手动运行 scripts/install-geoip-databases.sh，或移除严格模式"
      fi
      log "BAIZE_AUTO_INSTALL_GEOIP=false，跳过可选 GeoIP 下载"
      return
      ;;
  esac
  if ! command -v curl >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
    if [[ "$REQUIRE_GEOIP" == "1" ]]; then
      die "缺少 curl 或 gzip，无法准备 GeoIP 数据库"
    fi
    log "警告：缺少 curl 或 gzip，跳过可选 GeoIP 数据库；核心服务仍会继续安装"
    return
  fi
  STAGE="准备 GeoIP 数据库"
  log "首次安装自动准备离线 GeoIP 数据库；网络不可用时会保留核心安装流程"
  if GEOIP_DOWNLOAD_TIMEOUT_SECONDS="$HEALTH_TIMEOUT_SECONDS" bash "$ROOT_DIR/scripts/install-geoip-databases.sh"; then
    log "GeoIP 数据库准备完成"
  else
    local geoip_exit_code="$?"
    if [[ "$geoip_exit_code" == "130" || "$geoip_exit_code" == "143" ]]; then
      exit "$geoip_exit_code"
    fi
    if [[ "$REQUIRE_GEOIP" == "1" ]]; then
      die "GeoIP 数据库准备失败；请检查网络或手动放入 runtime/geoip 后重试"
    fi
    log "警告：GeoIP 数据库准备失败，核心服务仍会继续安装；稍后可执行 scripts/install-geoip-databases.sh 重试"
  fi
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

  local host_os
  host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$host_os" in
    linux)
      if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        log "当前 Linux 没有 systemd，跳过本机执行器自动安装；可在支持 systemd 的宿主机手动运行 scripts/install-agent.sh"
        return
      fi
      ;;
    darwin)
      command -v launchctl >/dev/null 2>&1 || {
        log "当前 macOS 缺少 launchctl，跳过本机执行器自动安装"
        return
      }
      ;;
    *)
      log "当前系统不支持自动安装本机执行器（仅支持 Linux systemd 或 macOS launchd）"
      return
      ;;
  esac

  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! sudo -n true >/dev/null 2>&1; then
    if [[ "$FORCE_SERVER_HOST_AGENT" != "1" || ! -r /dev/tty ]]; then
      log "当前用户没有免密 sudo，跳过需要主机权限的本机执行器安装；容器部署不受影响。完成安装后可手动运行 scripts/install-agent.sh"
      return
    fi
    log "本机执行器安装需要 sudo，后续可能提示输入当前用户密码"
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
    local agent_exit_code="$?"
    if [[ "$agent_exit_code" == "130" || "$agent_exit_code" == "143" ]]; then
      return "$agent_exit_code"
    fi
    log "本机执行器自动安装失败；中心服务已部署完成，可稍后运行 scripts/install-agent.sh 手动修复"
  fi
}

cd "$ROOT_DIR"

STAGE="检查 Docker 环境"
check_docker_ready

if [[ "$FORCE_CONFIG" == "1" && "$CONFIRM_FORCE_CONFIG" != "1" ]]; then
  # 二次确认是刻意设计的硬门槛，防止升级或重部署时误重置生产密钥。
  die "--force-config 会覆盖 .env 并重新生成数据库、Redis、JWT、管理员和凭据密钥。生产环境不得使用，除非你知道自己在做什么；如确认要重初始化，推荐执行 scripts/reinit-config.sh --config-only 或 --reset-stack，也可在已备份并接受风险后追加 --i-understand-force-config。"
fi

STAGE="生成或读取部署配置"
if [[ ! -f .env || "$FORCE_CONFIG" == "1" ]]; then
  args=("${INIT_ARGS[@]}")
  if [[ ${#args[@]} -eq 0 && -n "$PUBLIC_URL" ]]; then
    args+=(--public-url "$PUBLIC_URL")
  fi
  args+=(--lang "$LANGUAGE")
  if [[ "$FORCE_CONFIG" == "1" ]]; then
    args+=(--force)
  fi
  bash scripts/init-config.sh "${args[@]}"
elif [[ ${#INIT_ARGS[@]} -gt 0 ]]; then
  die ".env 已存在。为避免误改生产密钥，带配置参数部署时请显式追加 --force-config，或先手动编辑 .env。"
fi

STAGE="解析部署模式"
baize_ensure_host_profile_security_code "$ROOT_DIR/.env"
DEPLOY_MODE="$(baize_resolve_deploy_mode "$ROOT_DIR/.env")"
STACK_MODE="$(baize_resolve_stack_mode "$ROOT_DIR/.env")"
if [[ "$DEPLOY_MODE" == "build" ]]; then
  STAGE="检查本地发布产物"
  baize_require_build_artifacts "$ROOT_DIR/.env" "$STACK_MODE"
fi

STAGE="准备 GeoIP 数据库"
ensure_geoip

STAGE="静态安装检查"
check_args=(--offline)
if [[ "$REQUIRE_GEOIP" == "1" ]]; then
  check_args+=(--require-geoip)
else
  check_args+=(--allow-missing-geoip)
fi
bash scripts/check-install.sh "${check_args[@]}"

STAGE="检查端口"
ensure_port_available POSTGRES_PUBLIC_PORT postgres
ensure_port_available REDIS_PUBLIC_PORT redis
ensure_port_available SERVER_PUBLIC_PORT server
if baize_stack_has_web "$STACK_MODE"; then
  ensure_port_available WEB_PUBLIC_PORT web
fi

app_services=(server)
if baize_stack_has_web "$STACK_MODE"; then
  app_services+=(web)
fi

STAGE="准备应用镜像"
if [[ "$SKIP_BUILD" == "1" ]]; then
  log "已跳过应用镜像拉取/构建，将直接使用本地已有镜像"
elif [[ "$DEPLOY_MODE" == "build" ]]; then
  log "构建中心服务 / 控制台镜像"
  baize_compose "$DEPLOY_MODE" build "${app_services[@]}"
else
  log "拉取中心服务 / 控制台镜像"
  pull_succeeded=0
  for pull_attempt in 1 2 3; do
    if baize_compose "$DEPLOY_MODE" pull "${app_services[@]}"; then
      pull_succeeded=1
      break
    fi
    if (( pull_attempt < 3 )); then
      log "镜像拉取失败，将在 5 秒后重试（${pull_attempt}/3）"
      sleep 5
    fi
  done
  if [[ "$pull_succeeded" != "1" ]]; then
    die "镜像拉取失败。请检查网络、镜像下载来源和 BAIZE_SERVER_IMAGE / BAIZE_WEB_IMAGE；中国大陆可改用 --image-source acr 后重试。"
  fi
fi

STAGE="启动 PostgreSQL 和 Redis"
log "启动 PostgreSQL / Redis"
baize_compose "$DEPLOY_MODE" up -d postgres redis
wait_for_health postgres "$HEALTH_TIMEOUT_SECONDS"
wait_for_health redis "$HEALTH_TIMEOUT_SECONDS"

STAGE="启动中心服务和控制台"
if baize_stack_has_web "$STACK_MODE"; then
  log "启动中心服务 / 控制台"
else
  log "启动中心服务（server-only）"
fi
baize_compose "$DEPLOY_MODE" up -d "${app_services[@]}"
wait_for_health server "$HEALTH_TIMEOUT_SECONDS"
if baize_stack_has_web "$STACK_MODE"; then
  wait_for_health web "$HEALTH_TIMEOUT_SECONDS"
fi

STAGE="在线服务检查"
if [[ "$SKIP_ONLINE_CHECK" != "1" ]]; then
  check_args=()
  if [[ "$REQUIRE_GEOIP" == "1" ]]; then
    check_args+=(--require-geoip)
  else
    check_args+=(--allow-missing-geoip)
  fi
  bash scripts/check-install.sh "${check_args[@]}"
else
  log "已跳过在线 HTTP 检查"
fi

STAGE="安装本机执行器"
install_server_host_agent

STAGE="输出部署结果"
baize_compose "$DEPLOY_MODE" ps
log "部署完成 / deployment completed"
if baize_stack_has_web "$STACK_MODE"; then
  log "控制台: http://127.0.0.1:$(read_env WEB_PUBLIC_PORT)"
else
  log "部署形态: server-only（未启动控制台容器）"
fi
log "服务地址: http://127.0.0.1:$(read_env SERVER_PUBLIC_PORT)/api/v1"
log "Agent 访问地址: $(read_env AGENT_PUBLIC_SERVER_URL)"
log "管理员账号 admin，初始密码在 .env 的 ADMIN_PASSWORD 中。首次登录后请立即修改。"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
ENV_FILE="$ROOT_DIR/.env"
OFFLINE=0
TIMEOUT_SECONDS=12

log() {
  echo "[check-install] $*" >&2
}

die() {
  echo "[check-install] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/check-install.sh [--offline] [--timeout <seconds>]

说明:
  检查公开发布仓安装前置条件、必需产物、配置完整性和 Docker Compose 配置。
  --offline 只执行本地静态检查，不请求运行中的服务。

English:
  Check release artifacts, generated secrets, ports, Docker Compose config, and
  optionally running HTTP endpoints.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)
      OFFLINE=1
      shift
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      [[ -n "$TIMEOUT_SECONDS" ]] || die "--timeout 不能为空"
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

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "缺少文件: $path"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "缺少目录: $path"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

read_env() {
  baize_read_env "$1" "$ENV_FILE"
}

validate_non_empty() {
  local key="$1"
  local value
  value="$(read_env "$key")"
  [[ -n "$value" ]] || die "$key 未配置，请执行 scripts/init-config.sh 或手动填写 .env"
}

validate_not_placeholder() {
  local key="$1"
  local value
  value="$(read_env "$key")"
  case "$value" in
    change-me*|admin123|baize|baize123|password|secret)
      die "$key 仍是固定默认值或占位值，请改为随机强密码"
      ;;
  esac
}

validate_min_length() {
  local key="$1"
  local min="$2"
  local value
  value="$(read_env "$key")"
  (( ${#value} >= min )) || die "$key 长度不足，至少 ${min} 个字符"
}

validate_host_profile_security_code() {
  local hash code legacy_hash legacy_code
  hash="$(baize_strip_env_quotes "$(read_env BAIZE_HOST_PROFILE_SECURITY_CODE_HASH)")"
  code="$(baize_strip_env_quotes "$(read_env BAIZE_HOST_PROFILE_SECURITY_CODE)")"
  legacy_hash="$(baize_strip_env_quotes "$(read_env HOST_PROFILE_SECURITY_CODE_HASH)")"
  legacy_code="$(baize_strip_env_quotes "$(read_env HOST_PROFILE_SECURITY_CODE)")"

  if [[ -z "$hash" && -z "$code" && -z "$legacy_hash" && -z "$legacy_code" ]]; then
    die "主机画像安全码未配置，请设置 BAIZE_HOST_PROFILE_SECURITY_CODE_HASH 或 BAIZE_HOST_PROFILE_SECURITY_CODE"
  fi

  for value in "$hash" "$legacy_hash"; do
    [[ -z "$value" ]] && continue
    case "$value" in
      '$baize-argon2id$'*|'$2a$'*|'$2b$'*|'$2y$'*) ;;
      *) die "主机画像安全码哈希格式不正确，请使用 Baize Argon2id 哈希或 bcrypt 哈希" ;;
    esac
  done

  for value in "$code" "$legacy_code"; do
    [[ -z "$value" ]] && continue
    (( ${#value} >= 24 )) || die "主机画像安全码长度不足，至少 24 个字符"
  done
}

validate_port() {
  local key="$1"
  local value
  value="$(read_env "$key")"
  [[ -n "$value" ]] || return
  [[ "$value" =~ ^[0-9]+$ ]] || die "$key 必须是数字端口: $value"
  (( value >= 1 && value <= 65535 )) || die "$key 超出端口范围: $value"
}

validate_url() {
  local key="$1"
  local value
  value="$(read_env "$key")"
  [[ -n "$value" ]] || die "$key 未配置"
  case "$value" in
    http://*|https://*) ;;
    *) die "$key 必须以 http:// 或 https:// 开头: $value" ;;
  esac
}

validate_web_api_base_url() {
  local value
  value="$(read_env WEB_API_BASE_URL)"
  [[ -n "$value" ]] || die "WEB_API_BASE_URL 未配置"
  case "$value" in
    /*|http://*|https://*) ;;
    *) die "WEB_API_BASE_URL 必须是 /api/v1 这类相对路径，或 http(s):// 开头的完整地址: $value" ;;
  esac
}

validate_distinct_ports() {
  local keys=("POSTGRES_PUBLIC_PORT" "REDIS_PUBLIC_PORT" "SERVER_PUBLIC_PORT" "WEB_PUBLIC_PORT")
  local i j left_key right_key left right
  for ((i = 0; i < ${#keys[@]}; i++)); do
    left_key="${keys[$i]}"
    left="$(read_env "$left_key")"
    [[ -n "$left" ]] || continue
    for ((j = i + 1; j < ${#keys[@]}; j++)); do
      right_key="${keys[$j]}"
      right="$(read_env "$right_key")"
      [[ -n "$right" ]] || continue
      if [[ "$left" == "$right" ]]; then
        die "$left_key 与 $right_key 使用了相同宿主机端口: $left"
      fi
    done
  done
}

detect_host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) uname -m ;;
  esac
}

cd "$ROOT_DIR"

require_file "$ENV_FILE"
require_file docker-compose.yml
require_file docker-compose.build.yml
require_file server/Dockerfile
require_file web/Dockerfile
require_file web/nginx.conf.template
require_file web/docker-entrypoint.d/19-baize-web-host-guard.envsh
require_file web/docker-entrypoint.d/20-baize-api-config.sh
require_file releases/manifest.env
require_file releases/latest.json
require_file releases/changelog.json

host_arch="$(detect_host_arch)"
configured_arch="$(read_env SERVER_TARGET_ARCH)"
server_arch="${SERVER_TARGET_ARCH:-${configured_arch:-$host_arch}}"
deploy_mode="$(baize_resolve_deploy_mode "$ENV_FILE")"
if [[ "$deploy_mode" == "build" ]]; then
  baize_require_build_artifacts "$ENV_FILE"
  chmod +x "server/dist/baize-server-linux-${server_arch}" agent/dist/install.sh 2>/dev/null || true
fi

validate_non_empty POSTGRES_PASSWORD
validate_non_empty DB_PASSWORD
validate_non_empty REDIS_PASSWORD
validate_non_empty JWT_SECRET
validate_non_empty ADMIN_PASSWORD
validate_non_empty CREDENTIAL_MASTER_KEY
validate_non_empty AGENT_PUBLIC_SERVER_URL
validate_non_empty WEB_API_BASE_URL
validate_url AGENT_PUBLIC_SERVER_URL
validate_web_api_base_url

validate_not_placeholder POSTGRES_PASSWORD
validate_not_placeholder DB_PASSWORD
validate_not_placeholder REDIS_PASSWORD
validate_not_placeholder JWT_SECRET
validate_not_placeholder ADMIN_PASSWORD
validate_not_placeholder CREDENTIAL_MASTER_KEY
validate_min_length JWT_SECRET 32
validate_min_length CREDENTIAL_MASTER_KEY 32
validate_min_length ADMIN_PASSWORD 16
validate_host_profile_security_code

validate_port POSTGRES_PUBLIC_PORT
validate_port REDIS_PUBLIC_PORT
validate_port SERVER_PUBLIC_PORT
validate_port WEB_PUBLIC_PORT
validate_port SERVER_PORT
validate_port WEB_CONTAINER_PORT
validate_distinct_ports

[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout 必须是数字: $TIMEOUT_SECONDS"
(( TIMEOUT_SECONDS >= 1 && TIMEOUT_SECONDS <= 300 )) || die "--timeout 必须在 1 到 300 秒之间"

postgres_password="$(read_env POSTGRES_PASSWORD)"
db_password="$(read_env DB_PASSWORD)"
[[ "$postgres_password" == "$db_password" ]] || die "Docker 托管数据库时 DB_PASSWORD 必须与 POSTGRES_PASSWORD 一致"

require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose 不可用，请安装 Docker Compose v2"
baize_set_compose_args "$deploy_mode"
docker compose --env-file "$ENV_FILE" "${BAIZE_COMPOSE_ARGS[@]}" config >/dev/null

log "静态安装检查通过，server_arch=$server_arch deploy_mode=$deploy_mode"

if [[ "$OFFLINE" == "1" ]]; then
  exit 0
fi

server_port="$(read_env SERVER_PUBLIC_PORT)"
web_port="$(read_env WEB_PUBLIC_PORT)"

if command -v curl >/dev/null 2>&1; then
  curl_retry() {
    local description="$1"
    local url="$2"
    local start now
    start="$(date +%s)"
    while true; do
      if curl --max-time 5 -fsS "$url" >/dev/null; then
        return 0
      fi
      now="$(date +%s)"
      if (( now - start >= TIMEOUT_SECONDS )); then
        die "$description 检查失败: $url"
      fi
      sleep 2
    done
  }
  curl_retry "节点安装脚本下载" "http://127.0.0.1:${server_port}/install.sh"
  curl_retry "控制台首页" "http://127.0.0.1:${web_port}/"
  curl_retry "控制台运行时配置" "http://127.0.0.1:${web_port}/baize-api.config.js"
  curl_retry "控制台代理节点安装脚本" "http://127.0.0.1:${web_port}/install.sh"
  log "运行中服务检查通过"
else
  log "未安装 curl，跳过运行中服务 HTTP 检查"
fi

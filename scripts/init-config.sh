#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
FORCE=0
INTERACTIVE=0
LANGUAGE="${BAIZE_LANG:-zh}"
PUBLIC_URL="${AGENT_PUBLIC_SERVER_URL:-}"
WEB_API_BASE_URL="${WEB_API_BASE_URL:-/api/v1}"
SERVER_PUBLIC_PORT="${SERVER_PUBLIC_PORT:-22501}"
WEB_PUBLIC_PORT="${WEB_PUBLIC_PORT:-8088}"
POSTGRES_PUBLIC_PORT="${POSTGRES_PUBLIC_PORT:-15432}"
REDIS_PUBLIC_PORT="${REDIS_PUBLIC_PORT:-16379}"
SERVER_TARGET_ARCH="${SERVER_TARGET_ARCH:-amd64}"
SERVER_TARGET_PLATFORM="${SERVER_TARGET_PLATFORM:-linux/amd64}"
DEPLOY_MODE="${BAIZE_DEPLOY_MODE:-auto}"
BAIZE_VERSION="${BAIZE_VERSION:-0.1.31}"
SERVER_IMAGE="${BAIZE_SERVER_IMAGE:-ghcr.io/ysfl/baize-server:0.1.31}"
WEB_IMAGE="${BAIZE_WEB_IMAGE:-ghcr.io/ysfl/baize-web:0.1.31}"
BACKUP_DIR="${BAIZE_BACKUP_DIR:-}"

log() {
  echo "[init-config] $*" >&2
}

die() {
  echo "[init-config] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/init-config.sh [选项]
  scripts/init-config.sh --interactive

选项:
  --env-file <path>              写入的环境变量文件，默认 .env
  --force                        覆盖已存在的环境变量文件
  --interactive                  交互式生成配置，适合首次部署
  --lang <zh|en>                 提示语言，默认 zh
  --public-url <url>             对 Agent 暴露的白泽地址，例如 https://baize.example.com
  --agent-public-url <url>       --public-url 的别名
  --web-api-base-url <url>       控制台访问白泽服务的地址，默认 /api/v1；可填 https://api.example.com/api/v1
  --server-public-port <port>    中心服务宿主机端口，默认 22501
  --web-public-port <port>       控制台宿主机端口，默认 8088
  --postgres-public-port <port>  PostgreSQL 宿主机端口，默认 15432
  --redis-public-port <port>     Redis 宿主机端口，默认 16379
  --server-target-arch <arch>    中心服务架构，默认 amd64；需公开仓内存在对应二进制
  --deploy-mode <auto|image|build>
                                 部署模式：auto 自动判断，image 拉取镜像，build 使用本地产物构建
  --version <version>            镜像标签版本，默认 0.1.31
  --server-image <image>         中心服务镜像名，默认 ghcr.io/ysfl/baize-server:0.1.31
  --web-image <image>            控制台镜像名，默认 ghcr.io/ysfl/baize-web:0.1.31
  --backup-dir <path>            备份文件根目录，默认 ~/.baize/backups/baize-<实例哈希>
  -h, --help                     显示帮助

说明:
  脚本会生成随机数据库密码、Redis 密码、JWT 密钥、管理员初始密码、凭据主密钥和主机画像安全码。
  已存在 .env 时默认不会覆盖，防止误改生产密钥。

English:
  scripts/init-config.sh [options] or scripts/init-config.sh --interactive
  --public-url is the URL reachable by Agents. In same-origin deployments, keep
  --web-api-base-url as /api/v1 so the console container proxies API and WS.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      [[ -n "$ENV_FILE" ]] || die "--env-file 不能为空"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --interactive)
      INTERACTIVE=1
      shift
      ;;
    --lang)
      LANGUAGE="${2:-}"
      [[ -n "$LANGUAGE" ]] || die "--lang 不能为空"
      shift 2
      ;;
    --public-url)
      PUBLIC_URL="${2:-}"
      [[ -n "$PUBLIC_URL" ]] || die "--public-url 不能为空"
      shift 2
      ;;
    --agent-public-url)
      PUBLIC_URL="${2:-}"
      [[ -n "$PUBLIC_URL" ]] || die "--agent-public-url 不能为空"
      shift 2
      ;;
    --web-api-base-url)
      WEB_API_BASE_URL="${2:-}"
      [[ -n "$WEB_API_BASE_URL" ]] || die "--web-api-base-url 不能为空"
      shift 2
      ;;
    --server-public-port)
      SERVER_PUBLIC_PORT="${2:-}"
      shift 2
      ;;
    --web-public-port)
      WEB_PUBLIC_PORT="${2:-}"
      shift 2
      ;;
    --postgres-public-port)
      POSTGRES_PUBLIC_PORT="${2:-}"
      shift 2
      ;;
    --redis-public-port)
      REDIS_PUBLIC_PORT="${2:-}"
      shift 2
      ;;
    --server-target-arch)
      SERVER_TARGET_ARCH="${2:-}"
      [[ -n "$SERVER_TARGET_ARCH" ]] || die "--server-target-arch 不能为空"
      shift 2
      ;;
    --deploy-mode)
      DEPLOY_MODE="${2:-}"
      [[ -n "$DEPLOY_MODE" ]] || die "--deploy-mode 不能为空"
      shift 2
      ;;
    --version)
      BAIZE_VERSION="${2:-}"
      [[ -n "$BAIZE_VERSION" ]] || die "--version 不能为空"
      shift 2
      ;;
    --server-image)
      SERVER_IMAGE="${2:-}"
      [[ -n "$SERVER_IMAGE" ]] || die "--server-image 不能为空"
      shift 2
      ;;
    --web-image)
      WEB_IMAGE="${2:-}"
      [[ -n "$WEB_IMAGE" ]] || die "--web-image 不能为空"
      shift 2
      ;;
    --backup-dir)
      BACKUP_DIR="${2:-}"
      [[ -n "$BACKUP_DIR" ]] || die "--backup-dir 不能为空"
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

prompt_value() {
  local label_zh="$1"
  local label_en="$2"
  local default_value="$3"
  local value=""

  if [[ ! -r /dev/tty ]]; then
    die "当前环境不可交互，请改用参数模式 / non-interactive shell, please pass options explicitly"
  fi

  if [[ "$LANGUAGE" == "en" ]]; then
    printf "%s [%s]: " "$label_en" "$default_value" >/dev/tty
  else
    printf "%s [%s]: " "$label_zh" "$default_value" >/dev/tty
  fi
  IFS= read -r value </dev/tty || die "读取输入失败 / failed to read input"
  value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi
  printf '%s' "$value"
}

prompt_yes_no() {
  local label_zh="$1"
  local label_en="$2"
  local default_value="$3"
  local value=""
  local prompt_default="y/N"
  if [[ "$default_value" == "yes" ]]; then
    prompt_default="Y/n"
  fi
  if [[ "$LANGUAGE" == "en" ]]; then
    printf "%s [%s]: " "$label_en" "$prompt_default" >/dev/tty
  else
    printf "%s [%s]: " "$label_zh" "$prompt_default" >/dev/tty
  fi
  IFS= read -r value </dev/tty || die "读取输入失败 / failed to read input"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$value" ]]; then
    [[ "$default_value" == "yes" ]]
    return
  fi
  [[ "$value" == "y" || "$value" == "yes" || "$value" == "是" ]]
}

default_backup_dir() {
  local home_dir="${HOME:-$ROOT_DIR}"
  local instance_hash
  instance_hash="$(printf '%s' "$ROOT_DIR" | cksum | awk '{print $1}')"
  printf '%s/.baize/backups/baize-%s' "$home_dir" "$instance_hash"
}

if [[ "$INTERACTIVE" == "1" ]]; then
  log "交互式配置 / interactive configuration"
  if [[ -f "$ENV_FILE" && "$FORCE" != "1" ]]; then
    if prompt_yes_no "检测到 $ENV_FILE 已存在，是否覆盖并重新生成随机密钥" "Found $ENV_FILE. Overwrite and regenerate random secrets" "no"; then
      FORCE=1
    else
      log "保留现有环境变量文件: $ENV_FILE"
      exit 0
    fi
  fi

  PUBLIC_URL="$(prompt_value \
    "Agent 可访问的白泽地址，生产环境请填写公网或内网域名" \
    "Public URL reachable by Agents" \
    "${PUBLIC_URL:-http://127.0.0.1:${SERVER_PUBLIC_PORT}}")"
  WEB_API_BASE_URL="$(prompt_value \
    "控制台访问白泽服务的地址；同域部署推荐 /api/v1，分离部署填写完整服务地址" \
    "Console service URL; use /api/v1 for same-origin deployments" \
    "$WEB_API_BASE_URL")"
  SERVER_PUBLIC_PORT="$(prompt_value "中心服务宿主机端口" "Control service host port" "$SERVER_PUBLIC_PORT")"
  WEB_PUBLIC_PORT="$(prompt_value "控制台宿主机端口" "Console host port" "$WEB_PUBLIC_PORT")"
  POSTGRES_PUBLIC_PORT="$(prompt_value "PostgreSQL 宿主机端口" "PostgreSQL host port" "$POSTGRES_PUBLIC_PORT")"
  REDIS_PUBLIC_PORT="$(prompt_value "Redis 宿主机端口" "Redis host port" "$REDIS_PUBLIC_PORT")"
  SERVER_TARGET_ARCH="$(prompt_value "中心服务架构 amd64/arm64" "Control service architecture amd64/arm64" "$SERVER_TARGET_ARCH")"
  DEPLOY_MODE="$(prompt_value \
    "部署模式 auto/image/build；生产推荐 image，发布包本地构建可用 build" \
    "Deploy mode auto/image/build; image is recommended for production" \
    "$DEPLOY_MODE")"
  SERVER_IMAGE="$(prompt_value "中心服务镜像名" "Control service image" "$SERVER_IMAGE")"
  WEB_IMAGE="$(prompt_value "控制台镜像名" "Console image" "$WEB_IMAGE")"
  BACKUP_DIR="$(prompt_value \
    "备份文件根目录；建议放在仓库目录外，避免升级和 Git 工作区混乱" \
    "Backup root directory; keep it outside the repository" \
    "${BACKUP_DIR:-$(default_backup_dir)}")"
fi

validate_port() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name 必须是数字端口: $value"
  (( value >= 1 && value <= 65535 )) || die "$name 超出端口范围: $value"
}

validate_public_url() {
  local value="$1"
  [[ -n "$value" ]] || return
  case "$value" in
    http://*|https://*) ;;
    *) die "AGENT_PUBLIC_SERVER_URL 必须以 http:// 或 https:// 开头: $value" ;;
  esac
}

validate_web_api_base_url() {
  local value="$1"
  case "$value" in
    /*|http://*|https://*) ;;
    *) die "WEB_API_BASE_URL 必须是 /api/v1 这类相对路径，或 http(s):// 开头的完整地址: $value" ;;
  esac
}

validate_backup_dir() {
  local value="$1"
  [[ -n "$value" ]] || die "BAIZE_BACKUP_DIR 不能为空"
  case "$value" in
    *[[:space:]]*) die "BAIZE_BACKUP_DIR 暂不支持包含空白字符的路径: $value" ;;
  esac
}

validate_deploy_mode() {
  case "$1" in
    auto|image|build) ;;
    *) die "BAIZE_DEPLOY_MODE 仅支持 auto、image、build: $1" ;;
  esac
}

validate_image_name() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || die "$name 不能为空"
  case "$value" in
    *[[:space:]]*) die "$name 不能包含空白字符: $value" ;;
    *:*) ;;
    *) log "$name 未包含标签，Docker 会按 latest 处理: $value" ;;
  esac
}

validate_port "SERVER_PUBLIC_PORT" "$SERVER_PUBLIC_PORT"
validate_port "WEB_PUBLIC_PORT" "$WEB_PUBLIC_PORT"
validate_port "POSTGRES_PUBLIC_PORT" "$POSTGRES_PUBLIC_PORT"
validate_port "REDIS_PUBLIC_PORT" "$REDIS_PUBLIC_PORT"
validate_web_api_base_url "$WEB_API_BASE_URL"
validate_deploy_mode "$DEPLOY_MODE"
validate_image_name BAIZE_SERVER_IMAGE "$SERVER_IMAGE"
validate_image_name BAIZE_WEB_IMAGE "$WEB_IMAGE"
if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="$(default_backup_dir)"
fi
validate_backup_dir "$BACKUP_DIR"

case "$SERVER_TARGET_ARCH" in
  amd64|x86_64)
    SERVER_TARGET_ARCH=amd64
    SERVER_TARGET_PLATFORM=linux/amd64
    ;;
  arm64|aarch64)
    SERVER_TARGET_ARCH=arm64
    SERVER_TARGET_PLATFORM=linux/arm64
    ;;
  *)
    die "不支持的中心服务架构: $SERVER_TARGET_ARCH"
    ;;
esac

port_items=(
  "SERVER_PUBLIC_PORT=$SERVER_PUBLIC_PORT" \
  "WEB_PUBLIC_PORT=$WEB_PUBLIC_PORT" \
  "POSTGRES_PUBLIC_PORT=$POSTGRES_PUBLIC_PORT" \
  "REDIS_PUBLIC_PORT=$REDIS_PUBLIC_PORT"
)
for ((i = 0; i < ${#port_items[@]}; i++)); do
  left="${port_items[$i]}"
  left_name="${left%%=*}"
  left_port="${left#*=}"
  for ((j = i + 1; j < ${#port_items[@]}; j++)); do
    right="${port_items[$j]}"
    right_name="${right%%=*}"
    right_port="${right#*=}"
    if [[ "$left_port" == "$right_port" ]]; then
      die "$left_name 与 $right_name 使用了相同宿主机端口: $left_port"
    fi
  done
done

random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return
  fi
  if command -v od >/dev/null 2>&1; then
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
    return
  fi
  die "缺少 openssl 或 od，无法生成随机密钥"
}

if [[ -f "$ENV_FILE" && "$FORCE" != "1" ]]; then
  log "环境变量文件已存在，未覆盖: $ENV_FILE"
  exit 0
fi

mkdir -p "$(dirname "$ENV_FILE")"

postgres_password="$(random_hex 24)"
redis_password="$(random_hex 24)"
jwt_secret="$(random_hex 32)"
admin_password="$(random_hex 18)"
credential_master_key="$(random_hex 32)"
host_profile_security_code="$(random_hex 24)"

if [[ -z "$PUBLIC_URL" ]]; then
  PUBLIC_URL="http://127.0.0.1:${SERVER_PUBLIC_PORT}"
  log "未传入 --public-url，AGENT_PUBLIC_SERVER_URL 临时使用 ${PUBLIC_URL}；远程 Agent 接入前请改成公网或内网可达地址"
fi
validate_public_url "$PUBLIC_URL"

public_origin="$PUBLIC_URL"
public_origin="${public_origin%/}"
cors_origins="http://127.0.0.1:${WEB_PUBLIC_PORT},http://localhost:${WEB_PUBLIC_PORT}"
if [[ "$public_origin" == http://* || "$public_origin" == https://* ]]; then
  cors_origins="${cors_origins},${public_origin}"
fi

cat >"$ENV_FILE" <<EOF
# 白泽公开发布仓部署配置
# 生成时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# 重新生成会更换数据库、Redis、JWT、管理员和凭据密钥；生产环境请先备份。

POSTGRES_USER=baize
POSTGRES_PASSWORD=$postgres_password
POSTGRES_DB=baize
POSTGRES_PUBLIC_PORT=$POSTGRES_PUBLIC_PORT

REDIS_PASSWORD=$redis_password
REDIS_DB=0
REDIS_PUBLIC_PORT=$REDIS_PUBLIC_PORT

SERVER_HOST=0.0.0.0
SERVER_PORT=8080
SERVER_PUBLIC_PORT=$SERVER_PUBLIC_PORT
SERVER_MODE=release
SERVER_TARGET_ARCH=$SERVER_TARGET_ARCH
SERVER_TARGET_PLATFORM=$SERVER_TARGET_PLATFORM
BAIZE_DEPLOY_MODE=$DEPLOY_MODE
BAIZE_VERSION=$BAIZE_VERSION
BAIZE_SERVER_IMAGE=$SERVER_IMAGE
BAIZE_WEB_IMAGE=$WEB_IMAGE

WEB_PUBLIC_PORT=$WEB_PUBLIC_PORT
WEB_CONTAINER_PORT=8080
WEB_API_BASE_URL=$WEB_API_BASE_URL
WEB_CLIENT_MAX_BODY_SIZE=100m
BAIZE_SERVER_UPSTREAM=server:8080
BAIZE_WEB_DOMAIN=
BAIZE_WEB_ALLOWED_HOSTS=

DB_HOST=postgres
DB_PORT=5432
DB_USER=baize
DB_PASSWORD=$postgres_password
DB_NAME=baize
DB_SSLMODE=disable

REDIS_ADDR=redis:6379

JWT_SECRET=$jwt_secret
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$admin_password
CREDENTIAL_MASTER_KEY=$credential_master_key

BAIZE_HOST_PROFILE_SECURITY_CODE_HASH=
BAIZE_HOST_PROFILE_SECURITY_CODE=$host_profile_security_code

CORS_ENABLED=true
CORS_ALLOW_ORIGINS=$cors_origins
CORS_ALLOW_CREDENTIALS=false

TLS_ENABLED=false
TLS_CERT_FILE=
TLS_KEY_FILE=

AGENT_ARTIFACT_DIR=/app/agent/dist
AGENT_INSTALL_SCRIPT_PATH=/app/agent/dist/install.sh
AGENT_INSTALL_POWERSHELL_PATH=/app/agent/dist/install.ps1
AGENT_PUBLIC_SERVER_URL=$public_origin
AGENT_UPGRADE_AUTO_TOKEN_TTL_HOURS=24

BAIZE_RELEASE_MANIFEST_PATH=/app/releases/manifest.env
BAIZE_SERVER_BUILD_INFO_PATH=/app/server/dist/build-info.env
BAIZE_AGENT_BUILD_INFO_PATH=/app/agent/dist/build-info.env
BAIZE_LATEST_MANIFEST_URL=https://raw.githubusercontent.com/ysfl/baize/main/releases/latest.json
BAIZE_RELEASE_CHANGELOG_URL=https://raw.githubusercontent.com/ysfl/baize/main/releases/changelog.json
BAIZE_UPGRADE_MODE=manual
BAIZE_UPGRADE_COMMAND=
BAIZE_DOCKER_UPGRADE_COMMAND=cd $ROOT_DIR && BAIZE_DEPLOY_MODE=image bash scripts/upgrade.sh --yes
BAIZE_HOST_UPGRADE_COMMAND=cd $ROOT_DIR && BAIZE_DEPLOY_MODE=build bash scripts/upgrade.sh --yes
BAIZE_UPGRADE_RUNNER_ENABLED=false
BAIZE_UPGRADE_LOG_DIR=/app/data/upgrade
BAIZE_DB_AUTO_MIGRATE=true
BAIZE_BACKUP_DIR=$BACKUP_DIR
BAIZE_BACKUP_KEEP_DAYS=14

GEOIP_CITY_MMDB_PATH=/app/runtime/geoip/dbip-city-lite.mmdb
GEOIP_ASN_MMDB_PATH=/app/runtime/geoip/dbip-asn-lite.mmdb
GEOIP_OFFLINE_ONLY=true

BAIZE_RUNTIME_LOG_FILE_ENABLED=true
BAIZE_RUNTIME_LOG_DIR=/app/data/logs/baize-server
BAIZE_RUNTIME_LOG_FILE_MAX_SIZE_MB=50
BAIZE_RUNTIME_LOG_FILE_MAX_FILES=7
BAIZE_RUNTIME_LOG_INDEX_ENABLED=true
EOF

chmod 600 "$ENV_FILE"
log "已生成 $ENV_FILE"
log "管理员初始账号: admin"
log "管理员初始密码已写入 $ENV_FILE 的 ADMIN_PASSWORD；首次登录后请立即修改"
log "主机画像安全码已写入 $ENV_FILE 的 BAIZE_HOST_PROFILE_SECURITY_CODE；用于刷新主机画像和查看命令历史明文"

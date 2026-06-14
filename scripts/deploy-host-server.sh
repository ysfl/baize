#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
INSTALL_DIR="${BAIZE_INSTALL_DIR:-/opt/baize}"
SERVICE_NAME="${BAIZE_SERVICE_NAME:-baize-server}"
PUBLIC_URL="${AGENT_PUBLIC_SERVER_URL:-}"

log() {
  echo "[deploy-host-server] $*" >&2
}

die() {
  echo "[deploy-host-server] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

read_env() {
  baize_read_env "$1" "$ROOT_DIR/.env"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) die "不支持的中心服务宿主机架构: $(uname -m)" ;;
  esac
}

cd "$ROOT_DIR"
arch="$(detect_arch)"

if [[ ! -f .env ]]; then
  args=()
  if [[ -n "$PUBLIC_URL" ]]; then
    args+=(--public-url "$PUBLIC_URL")
  fi
  args+=(--server-target-arch "$arch")
  bash scripts/init-config.sh "${args[@]}"
fi

server_port="$(read_env SERVER_PORT)"
[[ -n "$server_port" ]] || server_port=8080
tmp_env="$(mktemp)"
case "$arch" in
  amd64) platform="linux/amd64" ;;
  arm64) platform="linux/arm64" ;;
  *) die "不支持的中心服务宿主机架构: $arch" ;;
esac
awk -v upstream="host.docker.internal:${server_port}" -v arch="$arch" -v platform="$platform" '
  BEGIN {
    updated_upstream = 0
    updated_arch = 0
    updated_platform = 0
  }
  /^BAIZE_SERVER_UPSTREAM=/ {
    print "BAIZE_SERVER_UPSTREAM=" upstream
    updated_upstream = 1
    next
  }
  /^SERVER_TARGET_ARCH=/ {
    print "SERVER_TARGET_ARCH=" arch
    updated_arch = 1
    next
  }
  /^SERVER_TARGET_PLATFORM=/ {
    print "SERVER_TARGET_PLATFORM=" platform
    updated_platform = 1
    next
  }
  { print }
  END {
    if (!updated_upstream) {
      print "BAIZE_SERVER_UPSTREAM=" upstream
    }
    if (!updated_arch) {
      print "SERVER_TARGET_ARCH=" arch
    }
    if (!updated_platform) {
      print "SERVER_TARGET_PLATFORM=" platform
    }
  }
' .env >"$tmp_env"
mv "$tmp_env" .env

require_cmd sudo
require_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose 不可用，请安装 Docker Compose v2"
DEPLOY_MODE="build"
baize_require_build_artifacts "$ROOT_DIR/.env"
BAIZE_DEPLOY_MODE=build bash scripts/check-install.sh --offline

server_binary="$ROOT_DIR/server/dist/baize-server-linux-${arch}"
[[ -f "$server_binary" ]] || die "缺少中心服务二进制: $server_binary"
chmod +x "$server_binary" 2>/dev/null || true
postgres_public_port="$(read_env POSTGRES_PUBLIC_PORT)"
redis_public_port="$(read_env REDIS_PUBLIC_PORT)"

sudo mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/data/logs/baize-server" "$INSTALL_DIR/agent" "$INSTALL_DIR/runtime"
sudo install -m 755 "$server_binary" "$INSTALL_DIR/bin/baize-server"
sudo cp -R "$ROOT_DIR/agent/dist" "$INSTALL_DIR/agent/"
sudo cp "$ROOT_DIR/.env" "$INSTALL_DIR/.env"
sudo chmod 600 "$INSTALL_DIR/.env"

baize_compose "$DEPLOY_MODE" up -d postgres redis
baize_compose "$DEPLOY_MODE" up -d --build web

service_file="/etc/systemd/system/${SERVICE_NAME}.service"
sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Baize Control Service
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
Environment=DB_HOST=127.0.0.1
Environment=DB_PORT=$postgres_public_port
Environment=REDIS_ADDR=127.0.0.1:$redis_public_port
Environment=AGENT_ARTIFACT_DIR=$INSTALL_DIR/agent/dist
Environment=AGENT_INSTALL_SCRIPT_PATH=$INSTALL_DIR/agent/dist/install.sh
Environment=AGENT_INSTALL_POWERSHELL_PATH=$INSTALL_DIR/agent/dist/install.ps1
Environment=BAIZE_RUNTIME_LOG_DIR=$INSTALL_DIR/data/logs/baize-server
Environment=SERVER_PORT=$server_port
ExecStart=$INSTALL_DIR/bin/baize-server
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"
sudo systemctl status "$SERVICE_NAME" --no-pager
baize_compose "$DEPLOY_MODE" ps

log "宿主机中心服务部署完成，服务名: $SERVICE_NAME"

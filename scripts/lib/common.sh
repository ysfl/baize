#!/usr/bin/env bash

BAIZE_ROOT_DIR="${BAIZE_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BAIZE_COMPOSE_ARGS=()

baize_read_env() {
  local key="$1"
  local file="${2:-$BAIZE_ROOT_DIR/.env}"
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == k {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$file"
}

baize_strip_env_quotes() {
  local value="$1"
  if [[ ${#value} -ge 2 ]]; then
    if [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      printf '%s' "${value:1:${#value}-2}"
      return
    fi
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      printf '%s' "${value:1:${#value}-2}"
      return
    fi
  fi
  printf '%s' "$value"
}

baize_random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return
  fi
  if command -v od >/dev/null 2>&1; then
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
    return
  fi
  echo "缺少 openssl 或 od，无法生成随机密钥" >&2
  return 1
}

baize_ensure_host_profile_security_code() {
  local env_file="${1:-$BAIZE_ROOT_DIR/.env}"
  [[ -f "$env_file" ]] || return 0

  local hash code legacy_hash legacy_code
  hash="$(baize_strip_env_quotes "$(baize_read_env BAIZE_HOST_PROFILE_SECURITY_CODE_HASH "$env_file")")"
  code="$(baize_strip_env_quotes "$(baize_read_env BAIZE_HOST_PROFILE_SECURITY_CODE "$env_file")")"
  legacy_hash="$(baize_strip_env_quotes "$(baize_read_env HOST_PROFILE_SECURITY_CODE_HASH "$env_file")")"
  legacy_code="$(baize_strip_env_quotes "$(baize_read_env HOST_PROFILE_SECURITY_CODE "$env_file")")"

  if [[ -n "$hash" || -n "$code" || -n "$legacy_hash" || -n "$legacy_code" ]]; then
    return 0
  fi

  code="$(baize_random_hex 24)"
  {
    printf '\n'
    printf '# 主机画像 / 命令历史高敏操作安全码。首次部署由脚本生成，请妥善保管。\n'
    printf 'BAIZE_HOST_PROFILE_SECURITY_CODE_HASH=\n'
    printf 'BAIZE_HOST_PROFILE_SECURITY_CODE=%s\n' "$code"
  } >>"$env_file"
  chmod 600 "$env_file" 2>/dev/null || true
  echo "[baize] 已为主机画像高敏操作生成安全码，并写入 $env_file 的 BAIZE_HOST_PROFILE_SECURITY_CODE" >&2
}

baize_detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) uname -m ;;
  esac
}

baize_required_server_arch() {
  local env_file="${1:-$BAIZE_ROOT_DIR/.env}"
  local host_arch configured
  host_arch="$(baize_detect_arch)"
  configured="$(baize_read_env SERVER_TARGET_ARCH "$env_file")"
  printf '%s' "${SERVER_TARGET_ARCH:-${configured:-$host_arch}}"
}

baize_has_build_artifacts() {
  local env_file="${1:-$BAIZE_ROOT_DIR/.env}"
  local arch
  arch="$(baize_required_server_arch "$env_file")"
  [[ -f "$BAIZE_ROOT_DIR/server/dist/baize-server-linux-${arch}" ]] || return 1
  [[ -f "$BAIZE_ROOT_DIR/agent/dist/install.sh" ]] || return 1
  [[ -f "$BAIZE_ROOT_DIR/agent/dist/install.ps1" ]] || return 1
  [[ -f "$BAIZE_ROOT_DIR/agent/dist/baize-agent.service" ]] || return 1
  [[ -f "$BAIZE_ROOT_DIR/web/dist/index.html" ]] || return 1
}

baize_resolve_deploy_mode() {
  local env_file="${1:-$BAIZE_ROOT_DIR/.env}"
  local configured
  configured="${BAIZE_DEPLOY_MODE:-$(baize_read_env BAIZE_DEPLOY_MODE "$env_file")}"
  [[ -n "$configured" ]] || configured="auto"
  case "$configured" in
    image|build) printf '%s' "$configured" ;;
    auto)
      if baize_has_build_artifacts "$env_file"; then
        printf '%s' "build"
      else
        printf '%s' "image"
      fi
      ;;
    *)
      echo "BAIZE_DEPLOY_MODE 仅支持 auto、image、build，当前值: $configured" >&2
      return 1
      ;;
  esac
}

baize_require_build_artifacts() {
  local env_file="${1:-$BAIZE_ROOT_DIR/.env}"
  local arch
  arch="$(baize_required_server_arch "$env_file")"
  baize_has_build_artifacts "$env_file" && return 0
  cat >&2 <<EOF
[baize] ERROR: 本地构建模式缺少发布产物。
缺少的产物通常包括:
  server/dist/baize-server-linux-${arch}
  agent/dist/install.sh
  agent/dist/install.ps1
  agent/dist/baize-agent.service
  web/dist/index.html

请改用镜像模式 BAIZE_DEPLOY_MODE=image，或从 GitHub Releases 下载对应独立产物并放入 dist 目录后重试。
EOF
  return 1
}

baize_set_compose_args() {
  local mode="${1:-}"
  BAIZE_COMPOSE_ARGS=(-f "$BAIZE_ROOT_DIR/docker-compose.yml")
  if [[ "$mode" == "build" ]]; then
    BAIZE_COMPOSE_ARGS+=(-f "$BAIZE_ROOT_DIR/docker-compose.build.yml")
  fi
}

baize_compose() {
  local mode="$1"
  shift
  baize_set_compose_args "$mode"
  docker compose "${BAIZE_COMPOSE_ARGS[@]}" "$@"
}

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAIZE_ROOT_DIR="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
ENV_FILE="$ROOT_DIR/.env"
CHECK_REMOTE=0
VERBOSE=0

log() {
  echo "[version] $*" >&2
}

die() {
  echo "[version] ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/version.sh [--check-remote] [--verbose]

说明:
  默认输出当前安装版本、发布标签、镜像、部署模式和容器状态。
  --check-remote 会读取 .env 中 BAIZE_LATEST_MANIFEST_URL，比较远端发布清单。
  --verbose 会额外输出本地 Git 与构建详情，适合排查发布来源。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-remote)
      CHECK_REMOTE=1
      shift
      ;;
    --verbose)
      VERBOSE=1
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

read_kv_file() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == k {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$file"
}

print_value() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || value="-"
  printf "%-24s %s\n" "$label" "$value"
}

cd "$ROOT_DIR"

manifest="$ROOT_DIR/releases/manifest.env"
server_build="$ROOT_DIR/server/dist/build-info.env"
agent_build="$ROOT_DIR/agent/dist/build-info.env"
latest_json="$ROOT_DIR/releases/latest.json"

echo "Baize release status"
echo "===================="
print_value "installed.version" "$(read_kv_file "$manifest" SYSTEM_VERSION)"
print_value "release.tag" "$(read_kv_file "$manifest" RELEASE_TAG)"
print_value "release.createdAt" "$(read_kv_file "$manifest" CREATED_AT)"
print_value "release.url" "$(read_kv_file "$manifest" RELEASE_URL)"
print_value "image.controlService" "$(read_kv_file "$manifest" SERVER_IMAGE)"
print_value "image.console" "$(read_kv_file "$manifest" WEB_IMAGE)"
print_value "agent.version" "$(read_kv_file "$manifest" AGENT_VERSION)"
if [[ -f "$ENV_FILE" ]]; then
  print_value "deploy.mode" "$(baize_resolve_deploy_mode "$ENV_FILE" 2>/dev/null || baize_read_env BAIZE_DEPLOY_MODE "$ENV_FILE")"
  print_value "stack.mode" "$(baize_resolve_stack_mode "$ENV_FILE" 2>/dev/null || baize_read_env BAIZE_STACK_MODE "$ENV_FILE")"
  print_value "configured.controlImage" "$(baize_read_env BAIZE_SERVER_IMAGE "$ENV_FILE")"
  print_value "configured.consoleImage" "$(baize_read_env BAIZE_WEB_IMAGE "$ENV_FILE")"
fi
print_value "latest.json" "$([[ -f "$latest_json" ]] && echo present || echo missing)"

if [[ "$VERBOSE" == "1" ]]; then
  echo
  echo "Local source details"
  echo "--------------------"
  if [[ -d .git ]]; then
    print_value "git.commit" "$(git rev-parse --short HEAD 2>/dev/null || true)"
    print_value "git.branch" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    print_value "git.tag" "$(git describe --tags --exact-match 2>/dev/null || git describe --tags --abbrev=0 2>/dev/null || true)"
    print_value "git.status" "$(git status --short --untracked-files=no 2>/dev/null | wc -l | tr -d ' ') tracked changes"
  else
    print_value "git" "not available"
  fi
  print_value "build.controlCommit" "$(read_kv_file "$server_build" SERVER_COMMIT)"
  print_value "build.controlTime" "$(read_kv_file "$server_build" SERVER_BUILD_TIME)"
  print_value "build.controlTargets" "$(read_kv_file "$server_build" SERVER_DIST_TARGETS)"
  print_value "build.agentVersion" "$(read_kv_file "$agent_build" AGENT_VERSION)"
  print_value "build.agentTargets" "$(read_kv_file "$agent_build" AGENT_TARGETS)"
  print_value "build.consoleCommit" "$(read_kv_file "$manifest" WEB_COMMIT)"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo
  echo "Compose services"
  echo "----------------"
  if [[ -f "$ENV_FILE" ]]; then
    mode="$(baize_resolve_deploy_mode "$ENV_FILE" 2>/dev/null || echo image)"
  else
    mode="image"
  fi
  baize_compose "$mode" ps
fi

if [[ "$CHECK_REMOTE" == "1" ]]; then
  [[ -f "$ENV_FILE" ]] || die "未找到 .env，无法读取 BAIZE_LATEST_MANIFEST_URL"
  latest_url="$(read_kv_file "$ENV_FILE" BAIZE_LATEST_MANIFEST_URL)"
  [[ -n "$latest_url" ]] || die "BAIZE_LATEST_MANIFEST_URL 未配置"
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法检查远端发布清单"
  tmp_manifest="$(mktemp)"
  trap 'rm -f "$tmp_manifest"' EXIT
  log "读取远端发布清单: $latest_url"
  curl --max-time 12 -fsSL "$latest_url" -o "$tmp_manifest"

  echo
  echo "Remote manifest"
  echo "---------------"
  if head -c 1 "$tmp_manifest" | grep -q '{'; then
    print_value "latest.format" "json"
    print_value "latest.version" "$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$tmp_manifest" | head -n 1)"
    print_value "latest.tag" "$(sed -nE 's/.*"tag"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$tmp_manifest" | head -n 1)"
    print_value "latest.releasedAt" "$(sed -nE 's/.*"releasedAt"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$tmp_manifest" | head -n 1)"
    print_value "latest.releaseUrl" "$(sed -nE 's/.*"releaseUrl"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$tmp_manifest" | head -n 1)"
  else
    print_value "latest.version" "$(read_kv_file "$tmp_manifest" SYSTEM_VERSION)"
    print_value "latest.tag" "$(read_kv_file "$tmp_manifest" RELEASE_TAG)"
    print_value "latest.agent.version" "$(read_kv_file "$tmp_manifest" AGENT_VERSION)"
    print_value "latest.createdAt" "$(read_kv_file "$tmp_manifest" CREATED_AT)"
    if [[ "$VERBOSE" == "1" ]]; then
      print_value "latest.controlCommit" "$(read_kv_file "$tmp_manifest" SERVER_COMMIT)"
      print_value "latest.consoleCommit" "$(read_kv_file "$tmp_manifest" WEB_COMMIT)"
    fi
  fi
fi

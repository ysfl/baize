#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
WITH_AGENT=0
KEEP_AGENT_DATA=0
TIMEOUT_SECONDS=120
AGENT_RUN_SECONDS=35
API_URL=""
WEB_URL=""
AGENT_SERVER_URL=""
TEMP_DIR=""
AGENT_PID=""

log() {
  echo "[verify-local-stack] $*" >&2
}

cleanup() {
  if [[ -n "$AGENT_PID" ]]; then
    kill "$AGENT_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEMP_DIR" && "$KEEP_AGENT_DATA" != "1" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

die() {
  echo "[verify-local-stack] ERROR: $*" >&2
  cleanup
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/verify-local-stack.sh [选项]

选项:
  --with-agent                 启动临时本机 Agent，验证注册、心跳和指标上报
  --api-url <url>              API BaseURL，默认从 .env SERVER_PUBLIC_PORT 推导
  --web-url <url>              Web URL，默认从 .env WEB_PUBLIC_PORT 推导
  --agent-server-url <url>     Agent 连接地址，默认使用 Web URL，经 /ws 反代
  --timeout <seconds>          等待超时，默认 120
  --agent-run-seconds <n>      临时 Agent 最少运行秒数，默认 35
  --keep-agent-data            保留临时 Agent 数据目录，便于排障
  -h, --help                   显示帮助

English:
  Verify console and service endpoints. With --with-agent, the script logs in as admin,
  creates a one-time registration token, starts a temporary local Agent, then
  checks Agent detail, heartbeat samples and metric families through the API.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-agent)
      WITH_AGENT=1
      shift
      ;;
    --api-url)
      API_URL="${2:-}"
      [[ -n "$API_URL" ]] || die "--api-url 不能为空"
      shift 2
      ;;
    --web-url)
      WEB_URL="${2:-}"
      [[ -n "$WEB_URL" ]] || die "--web-url 不能为空"
      shift 2
      ;;
    --agent-server-url)
      AGENT_SERVER_URL="${2:-}"
      [[ -n "$AGENT_SERVER_URL" ]] || die "--agent-server-url 不能为空"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      [[ -n "$TIMEOUT_SECONDS" ]] || die "--timeout 不能为空"
      shift 2
      ;;
    --agent-run-seconds)
      AGENT_RUN_SECONDS="${2:-}"
      [[ -n "$AGENT_RUN_SECONDS" ]] || die "--agent-run-seconds 不能为空"
      shift 2
      ;;
    --keep-agent-data)
      KEEP_AGENT_DATA=1
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
  local key="$1"
  awk -F= -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 == k {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$ENV_FILE"
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

json_total() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data.get("data", {}).get("total", 0))
'
}

json_data_total() {
  python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", {})
print(data.get("total", 0) if isinstance(data, dict) else 0)
'
}

http_get() {
  local url="$1"
  curl --max-time 15 -fsS "$url"
}

auth_get() {
  local url="$1"
  curl --max-time 15 -fsS -H "Authorization: Bearer ${AUTH_TOKEN}" "$url"
}

auth_post() {
  local url="$1"
  local body="$2"
  curl --max-time 15 -fsS \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$url"
}

normalize_ws_url() {
  local raw="$1"
  raw="${raw%/}"
  case "$raw" in
    ws://*|wss://*)
      if [[ "$raw" == */ws ]]; then
        printf '%s\n' "$raw"
      else
        printf '%s/ws\n' "$raw"
      fi
      ;;
    http://*)
      printf 'ws://%s/ws\n' "${raw#http://}"
      ;;
    https://*)
      printf 'wss://%s/ws\n' "${raw#https://}"
      ;;
    *)
      die "Agent 连接地址必须以 http(s):// 或 ws(s):// 开头: $raw"
      ;;
  esac
}

detect_agent_binary() {
  local os arch candidate
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) die "暂不支持的 Agent 本机验证架构: $arch" ;;
  esac
  case "$os" in
    darwin|linux) ;;
    *) die "暂不支持的 Agent 本机验证系统: $os" ;;
  esac
  candidate="$ROOT_DIR/agent/dist/baize-agent-${os}-${arch}"
  [[ -x "$candidate" ]] || die "缺少可执行 Agent: $candidate"
  printf '%s\n' "$candidate"
}

wait_until() {
  local description="$1"
  local command="$2"
  local start now
  start="$(date +%s)"
  while true; do
    if eval "$command"; then
      return
    fi
    if [[ -n "$AGENT_PID" ]] && ! kill -0 "$AGENT_PID" >/dev/null 2>&1; then
      if [[ -n "${agent_log:-}" && -f "$agent_log" ]]; then
        tail -n 120 "$agent_log" >&2 || true
      fi
      die "$description 前 Agent 已退出"
    fi
    now="$(date +%s)"
    if (( now - start >= TIMEOUT_SECONDS )); then
      die "$description 等待超时"
    fi
    sleep 2
  done
}

[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout 必须是数字: $TIMEOUT_SECONDS"
[[ "$AGENT_RUN_SECONDS" =~ ^[0-9]+$ ]] || die "--agent-run-seconds 必须是数字: $AGENT_RUN_SECONDS"
(( TIMEOUT_SECONDS >= 10 && TIMEOUT_SECONDS <= 600 )) || die "--timeout 必须在 10 到 600 秒之间"
(( AGENT_RUN_SECONDS >= 5 && AGENT_RUN_SECONDS <= 300 )) || die "--agent-run-seconds 必须在 5 到 300 秒之间"

[[ -f "$ENV_FILE" ]] || die "缺少 .env，请先执行 scripts/install.sh 或 scripts/deploy-server.sh"
require_cmd curl
require_cmd python3

server_port="$(read_env SERVER_PUBLIC_PORT)"
web_port="$(read_env WEB_PUBLIC_PORT)"
admin_user="$(read_env ADMIN_USERNAME)"
admin_password="$(read_env ADMIN_PASSWORD)"
web_api_base_url="$(read_env WEB_API_BASE_URL)"

WEB_URL="${WEB_URL:-http://127.0.0.1:${web_port}}"
AGENT_SERVER_URL="${AGENT_SERVER_URL:-$WEB_URL}"
WEB_URL="${WEB_URL%/}"
if [[ -z "$API_URL" ]]; then
  case "$web_api_base_url" in
    http://*|https://*)
      API_URL="$web_api_base_url"
      ;;
    /*)
      API_URL="${WEB_URL}${web_api_base_url}"
      ;;
    *)
      API_URL="http://127.0.0.1:${server_port}/api/v1"
      ;;
  esac
fi
API_URL="${API_URL%/}"

log "检查 Web 与 API 访问"
http_get "$WEB_URL/" >/dev/null || die "Web 首页不可访问: $WEB_URL/"
http_get "$WEB_URL/baize-api.config.js" >/dev/null || die "Web API 运行时配置不可访问"
http_get "${API_URL%/api/v1}/install.sh" >/dev/null || die "install.sh 不可访问，请检查 Web/Server 反代"

login_body="$(python3 -c 'import json, sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))' "$admin_user" "$admin_password")"
login_response="$(curl --max-time 15 -fsS -H "Content-Type: application/json" -d "$login_body" "$API_URL/auth/login")" || die "管理员登录失败，请检查 ADMIN_PASSWORD"
AUTH_TOKEN="$(printf '%s' "$login_response" | json_get data.token)"
[[ -n "$AUTH_TOKEN" ]] || die "登录响应未返回 token"
log "管理员登录验证通过"

agents_response="$(auth_get "$API_URL/agents?page=1&pageSize=1")"
baseline_total="$(printf '%s' "$agents_response" | json_total)"
log "Web 使用的 API 可读取 Agent 列表，当前数量: $baseline_total"

if [[ "$WITH_AGENT" != "1" ]]; then
  log "未启用 --with-agent，跳过临时 Agent 验证"
  exit 0
fi

agent_bin="$(detect_agent_binary)"
token_name="local-e2e-$(date +%s)"
token_body="$(python3 -c 'import json, sys; print(json.dumps({"name": sys.argv[1], "type": "single", "quota": 1, "expires_in_hours": 2, "note": "local e2e verification"}))' "$token_name")"
token_response="$(auth_post "$API_URL/tokens" "$token_body")" || die "创建注册 Token 失败"
registration_token="$(printf '%s' "$token_response" | json_get data.token)"
[[ -n "$registration_token" ]] || die "注册 Token 响应缺少明文 token"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/baize-agent-e2e.XXXXXX")"
agent_data="$TEMP_DIR/data"
agent_log="$TEMP_DIR/agent.log"
ws_url="$(normalize_ws_url "$AGENT_SERVER_URL")"
log "启动临时 Agent: $agent_bin -> $ws_url"
BAIZE_AGENT_BASE_AGGREGATE_WINDOW_SEC=5 \
BAIZE_AGENT_CONTROL_HEARTBEAT_INTERVAL_SEC=5 \
BAIZE_FINGERPRINT_SEED="$token_name" \
"$agent_bin" --server-url "$ws_url" --token "$registration_token" --data-dir "$agent_data" >"$agent_log" 2>&1 &
AGENT_PID="$!"

wait_until "Agent 生成本地 agent_id" "[[ -s '$agent_data/agent_id' ]]"
agent_id="$(tr -d '\r\n' < "$agent_data/agent_id")"
[[ -n "$agent_id" ]] || die "agent_id 文件为空"
log "Agent 已注册: $agent_id"

sleep "$AGENT_RUN_SECONDS"

auth_get "$API_URL/agents/$agent_id" >/dev/null || {
  tail -n 120 "$agent_log" >&2 || true
  die "控制台和服务无法读取刚注册的 Agent: $agent_id"
}

heartbeat_response="$(auth_get "$API_URL/agents/$agent_id/heartbeat-samples?page=1&pageSize=5")" || die "心跳样本查询失败"
heartbeat_total="$(printf '%s' "$heartbeat_response" | json_data_total)"
if (( heartbeat_total < 1 )); then
  tail -n 120 "$agent_log" >&2 || true
  die "未查询到 Agent 心跳样本"
fi

families_response="$(auth_get "$API_URL/agents/$agent_id/metrics/families")" || die "指标族查询失败"
families_count="$(printf '%s' "$families_response" | python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("data", {}).get("families", [])))')"
if (( families_count < 1 )); then
  tail -n 120 "$agent_log" >&2 || true
  die "未查询到 Agent 指标族"
fi

kill "$AGENT_PID" >/dev/null 2>&1 || true
AGENT_PID=""
if [[ "$KEEP_AGENT_DATA" == "1" ]]; then
  log "保留临时 Agent 数据目录: $TEMP_DIR"
else
  rm -rf "$TEMP_DIR"
  TEMP_DIR=""
fi

log "Agent 闭环验证通过：注册、心跳样本、指标族均可通过 Web API 读取"

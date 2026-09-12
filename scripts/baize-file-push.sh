#!/usr/bin/env bash
#
# baize-file-push.sh — 通过白泽（Baize）远程任务通道向受管节点推送文件
#
# 适用场景：目标节点未开放 FTP/SSH，仅有白泽受控远程任务通道时，
# 将中小文件（建议 ≤ 20MB）从本机安全推送到节点指定路径。
#
# 原理：
#   本地 gzip(可选) → base64 → 按 ~96KB 切片 → 每片作为一条受审计的远程命令任务
#   串行写盘 → 远端拼接、解码（解压）→ sha256 与本地逐字节比对 → 清理现场。
#
# 约束：
#   - 分片大小受 Linux MAX_ARG_STRLEN（128KB）限制，默认 96KB，请勿超过 120。
#   - 远端任务必须逐片确认完成后再发下一片（并发派发可能被 Agent 队列丢弃）。
#   - 远端路径仅允许 [A-Za-z0-9._/-]，不得包含空格或引号。
#   - 实用上限约 20MB；更大文件请使用制品仓库（Harbor/OSS）或 FTP 等通道。
#
# 用法：
#   baize-file-push.sh --agent <agent-uuid> --file <local-file> --remote </abs/remote/path> [选项]
#
# 选项：
#   --gzip            传输前 gzip 压缩（远端自动 gunzip；产物为 zip 等已压缩格式时可不加）
#   --chunk-kb <n>    分片大小（KB），默认 96
#   --wrap <cmd>      写盘命令包装器（受限沙箱环境），如: --wrap 'nsenter -t 1 -m sh -c'
#                     包装器以 sh -c "<内层>" 形式执行内层命令
#   --keep            验证通过后保留远端分片暂存目录（默认清理）
#   --title-prefix    远程任务标题前缀，默认 "file-push"
#   --timeout <sec>   单任务超时秒数，默认 300
#
# 凭据（环境变量，二选一）：
#   BAIZE_TOKEN                                直接使用已有 token
#   BAIZE_BASE_URL + BAIZE_USERNAME + BAIZE_PASSWORD   自动登录获取 token
#
# 退出码：
#   0 成功（sha256 一致）；非 0 失败（远端保留现场供排查，除非 --keep 未指定且失败于最后阶段）
#
set -euo pipefail

AGENT=""
LOCAL_FILE=""
REMOTE_PATH=""
USE_GZIP=0
CHUNK_KB=96
WRAP=""
KEEP=0
TITLE_PREFIX="file-push"
TASK_TIMEOUT=300

usage() { sed -n '2,50p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --file) LOCAL_FILE="$2"; shift 2 ;;
    --remote) REMOTE_PATH="$2"; shift 2 ;;
    --gzip) USE_GZIP=1; shift ;;
    --chunk-kb) CHUNK_KB="$2"; shift 2 ;;
    --wrap) WRAP="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --title-prefix) TITLE_PREFIX="$2"; shift 2 ;;
    --timeout) TASK_TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$AGENT" && -n "$LOCAL_FILE" && -n "$REMOTE_PATH" ]] || { usage; exit 64; }
[[ -f "$LOCAL_FILE" ]] || { echo "本地文件不存在: $LOCAL_FILE" >&2; exit 66; }
[[ "$REMOTE_PATH" = /* ]] || { echo "远端路径必须是绝对路径" >&2; exit 64; }
if [[ "$REMOTE_PATH" =~ [^A-Za-z0-9._/-] ]]; then
  echo "远端路径仅允许 [A-Za-z0-9._/-]（不得包含空格/引号/中文）: $REMOTE_PATH" >&2
  exit 64
fi
[[ "$CHUNK_KB" -ge 8 && "$CHUNK_KB" -le 120 ]] || { echo "--chunk-kb 必须在 8..120" >&2; exit 64; }
if [[ -n "$WRAP" && "$WRAP" =~ ['"'] ]]; then
  echo "--wrap 不允许包含双引号" >&2; exit 64
fi

BASE_URL="${BAIZE_BASE_URL:?需要 BAIZE_BASE_URL}"
BASE_URL="${BASE_URL%/}"

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT
TOKEN_FILE="$TMPDIR_LOCAL/token"
chmod 700 "$TMPDIR_LOCAL"

log() { printf '[file-push] %s\n' "$*"; }
die() { printf '[file-push] 错误: %s\n' "$*" >&2; exit 1; }

# ---------- 登录 ----------
if [[ -n "${BAIZE_TOKEN:-}" ]]; then
  printf '%s' "$BAIZE_TOKEN" > "$TOKEN_FILE"
else
  : "${BAIZE_USERNAME:?需要 BAIZE_USERNAME 或 BAIZE_TOKEN}"
  : "${BAIZE_PASSWORD:?需要 BAIZE_PASSWORD 或 BAIZE_TOKEN}"
  CODE=$(curl -s --connect-timeout 10 -o "$TMPDIR_LOCAL/login.json" -w '%{http_code}' \
    -X POST "$BASE_URL/auth/login" \
    -H 'Content-Type: application/json' \
    --data "$(printf '{"username":"%s","password":"%s"}' "$BAIZE_USERNAME" "$BAIZE_PASSWORD")")
  [[ "$CODE" =~ ^2 ]] || die "登录失败 HTTP $CODE"
  TOKEN=$(grep -o '"token":"[^"]*"' "$TMPDIR_LOCAL/login.json" | head -1 | cut -d'"' -f4)
  [[ -n "$TOKEN" ]] || die "登录响应中未找到 token"
  printf '%s' "$TOKEN" > "$TOKEN_FILE"
fi
TOKEN=$(cat "$TOKEN_FILE")

# ---------- HTTP 助手（带 429 退避） ----------
# HTTP 状态码写入 $TMPDIR_LOCAL/http_code（供命令替换子壳外读取）
baize_post() { # $1=url $2=json-file
  local attempt=0
  while :; do
    curl -s --connect-timeout 10 -o "$TMPDIR_LOCAL/resp" -w '%{http_code}' \
      -X POST "$1" -H "Authorization: Bearer $TOKEN"       -H 'Content-Type: application/json' --data-binary @"$2" \
      > "$TMPDIR_LOCAL/http_code"
    if [[ "$(cat "$TMPDIR_LOCAL/http_code")" == "429" ]]; then
      attempt=$((attempt + 1))
      [[ $attempt -ge 5 ]] && die "持续限流(429)，稍后再试"
      sleep $((attempt * 5))
      continue
    fi
    break
  done
}

baize_get() { # $1=url -> 输出 body
  curl -s --connect-timeout 10 "$1" -H "Authorization: Bearer $TOKEN"
}

# ---------- 任务助手 ----------
post_task() { # $1=title $2=command -> 输出 task id
  local title="$1" cmd="$2"
  python3 - "$title" "$cmd" "$AGENT" "$TASK_TIMEOUT" <<'PY' > "$TMPDIR_LOCAL/task.json"
import json, sys
title, cmd, agent, timeout = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
print(json.dumps({
    "taskType": "command", "title": title, "command": cmd,
    "timeoutSec": timeout, "autoDispatch": True, "metadata": {},
    "targetAgentIds": [agent],
}))
PY
  baize_post "$BASE_URL/ops/tasks" "$TMPDIR_LOCAL/task.json"
  local code
  code=$(cat "$TMPDIR_LOCAL/http_code")
  [[ "$code" =~ ^2 ]] || die "创建任务失败 HTTP $code: $(head -c 200 "$TMPDIR_LOCAL/resp")"
  local id
  id=$(grep -o '"id":"[0-9a-f-]\{36\}"' "$TMPDIR_LOCAL/resp" | head -1 | cut -d'"' -f4)
  [[ -n "$id" ]] || die "响应中未找到任务 id"
  printf '%s' "$id"
}

wait_task() { # $1=task id
  local id="$1" i status
  for i in $(seq 1 120); do
    sleep 1
    status=$(baize_get "$BASE_URL/ops/tasks/$id" | grep -o '"status":"[a-z]*"' | head -1 | cut -d'"' -f4)
    case "$status" in
      completed) return 0 ;;
      failed) return 1 ;;
    esac
  done
  return 2
}

run_remote() { # $1=title $2=command  -> 远端输出（stdout/stderr 文本）
  local id
  id=$(post_task "$1" "$2")
  if ! wait_task "$id"; then
    echo "$id" > "$TMPDIR_LOCAL/failed_task"
    return 1
  fi
  printf '%s' "$id"
}

# ---------- 远端命令构造 ----------
# 内层命令统一使用双引号，外层 wrap 用 sh -c "<inner>"。路径已校验安全字符集。
remote_exec_cmd() { # $1=inner command -> 可下发的完整命令
  if [[ -n "$WRAP" ]]; then
    printf '%s "%s"' "$WRAP" "$1"
  else
    printf '%s' "$1"
  fi
}

# ---------- 主流程 ----------
LOCAL_SIZE=$(wc -c < "$LOCAL_FILE" | tr -d ' ')
LOCAL_SHA=$(sha256sum "$LOCAL_FILE" 2>/dev/null | awk '{print $1}' \
  || shasum -a 256 "$LOCAL_FILE" | awk '{print $1}')
log "本地文件: $LOCAL_FILE ($LOCAL_SIZE 字节, sha256=$LOCAL_SHA)"

# 1) 预编码
PAYLOAD="$LOCAL_FILE"
[[ $USE_GZIP -eq 1 ]] && { gzip -9 -c "$LOCAL_FILE" > "$TMPDIR_LOCAL/payload.gz"; PAYLOAD="$TMPDIR_LOCAL/payload.gz"; }
base64 < "$PAYLOAD" > "$TMPDIR_LOCAL/payload.b64"
TOTAL_B64=$(wc -c < "$TMPDIR_LOCAL/payload.b64" | tr -d ' ')

# 2) 切片
RUN_ID="$(date +%s)$((RANDOM % 1000))"
STAGE_DIR="$(dirname "$REMOTE_PATH")/.fp-$RUN_ID"
CHUNK_PREFIX="$TMPDIR_LOCAL/part"
split -b $((CHUNK_KB * 1024)) "$TMPDIR_LOCAL/payload.b64" "$CHUNK_PREFIX"
CHUNKS=( "$CHUNK_PREFIX"* )
log "分片: ${#CHUNKS[@]} 片 × ≤${CHUNK_KB}KB（base64 共 $TOTAL_B64 字节）"

REMOTE_STAGE="$STAGE_DIR"

# 3) 逐片串行写盘
i=0
for chunk in "${CHUNKS[@]}"; do
  i=$((i + 1))
  PART_NAME="part-$(printf '%05d' "$i")"
  CHUNK_TEXT=$(cat "$chunk")
  INNER="mkdir -p \"$REMOTE_STAGE\" && printf \"%s\" \"$CHUNK_TEXT\" > \"$REMOTE_STAGE/$PART_NAME\""
  CMD=$(remote_exec_cmd "$INNER")
  if ! run_remote "$TITLE_PREFIX chunk $i/${#CHUNKS[@]}" "$CMD" >/dev/null; then
    die "分片 $i 写盘任务失败（任务记录见白泽控制台），远端现场保留于 $REMOTE_STAGE"
  fi
done
log "全部 ${#CHUNKS[@]} 片写盘完成"

# 4) 远端组装 + 校验
REMOTE_PARENT="$(dirname "$REMOTE_PATH")"
if [[ $USE_GZIP -eq 1 ]]; then
  ASSEMBLE_INNER="cat \"$REMOTE_STAGE\"/part-* | base64 -d | gunzip > \"$REMOTE_PATH\" && sha256sum \"$REMOTE_PATH\""
else
  ASSEMBLE_INNER="cat \"$REMOTE_STAGE\"/part-* | base64 -d > \"$REMOTE_PATH\" && sha256sum \"$REMOTE_PATH\""
fi
CMD=$(remote_exec_cmd "mkdir -p \"$REMOTE_PARENT\" && $ASSEMBLE_INNER")
TASK_ID=$(run_remote "$TITLE_PREFIX assemble+verify" "$CMD") \
  || die "远端组装/校验任务失败，远端现场保留于 $REMOTE_STAGE"
OUTPUT=$(baize_get "$BASE_URL/ops/tasks/$TASK_ID/output")
REMOTE_SHA=$(printf '%s' "$OUTPUT" | grep -o '[0-9a-f]\{64\}' | head -1)
[[ -n "$REMOTE_SHA" ]] || die "无法从任务输出读取远端 sha256，请到控制台查看任务 $TASK_ID"

# 5) 比对
if [[ "$REMOTE_SHA" != "$LOCAL_SHA" ]]; then
  log "校验失败: 本地=$LOCAL_SHA 远端=$REMOTE_SHA"
  log "远端现场保留于 $REMOTE_STAGE，目标文件未达到预期完整性"
  exit 1
fi
log "sha256 校验一致: $REMOTE_SHA"

# 6) 清理
if [[ $KEEP -eq 0 ]]; then
  CMD=$(remote_exec_cmd "rm -rf \"$REMOTE_STAGE\"")
  run_remote "$TITLE_PREFIX cleanup" "$CMD" >/dev/null \
    && log "远端暂存已清理" || log "警告: 清理任务失败（不影响结果），可手动删除 $REMOTE_STAGE"
fi

log "完成: $REMOTE_PATH"

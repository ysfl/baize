#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

TASK_ID="${1:-}"
ROOT_DIR="${BAIZE_ROOT_DIR:-}"
AGENT_DATA_DIR="${BAIZE_AGENT_DATA_DIR:-/opt/baize-agent/data}"
LOCK_FILE="${BAIZE_IMAGE_UPGRADE_LOCK_FILE:-/run/lock/baize-image-upgrade.lock}"
TEST_MODE="${BAIZE_IMAGE_UPDATER_TEST_MODE:-0}"

TARGET_ID=""
COMPONENT=""
TARGET_VERSION=""
TARGET_IMAGE=""
TARGET_DIGEST=""
TIMEOUT_SEC=900
PREVIOUS_VERSION=""
PREVIOUS_IMAGE=""
ENV_CHANGED=0
COMMITTED=0
FAILURE_HANDLED=0
LAST_STEP="初始化升级任务"

REQUEST_DIR="$AGENT_DATA_DIR/image-upgrade/requests"
RECEIPT_DIR="$AGENT_DATA_DIR/image-upgrade/receipts"
LOG_DIR="$AGENT_DATA_DIR/image-upgrade/logs"
REQUEST_FILE="$REQUEST_DIR/$TASK_ID.json"
RECEIPT_FILE="$RECEIPT_DIR/$TASK_ID.json"
LOG_FILE="$LOG_DIR/$TASK_ID.log"
ENV_FILE=""
ENV_SNAPSHOT=""
RUNTIME_STATE_FILE=""
BACKUP_DIR=""
DEADLINE_EPOCH=0
COMPOSE=()

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  local line
  line="$(timestamp) [image-updater] $*"
  printf '%s\n' "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

is_safe_task_id() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

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

strip_env_quotes() {
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

write_receipt() {
  local status="$1"
  local message="$2"
  local rolled_back="$3"
  local rollback_message="$4"
  local temp_file="$RECEIPT_FILE.tmp-$$"
  python3 - "$temp_file" "$LOG_FILE" "$TASK_ID" "$TARGET_ID" "$COMPONENT" "$status" \
    "$TARGET_VERSION" "$PREVIOUS_VERSION" "$message" "$rolled_back" "$rollback_message" <<'PY'
import json
import os
import sys
from pathlib import Path

(
    output_path,
    log_path,
    task_id,
    target_id,
    component,
    status,
    version,
    previous_version,
    message,
    rolled_back,
    rollback_message,
) = sys.argv[1:]

log_tail = ""
try:
    raw = Path(log_path).read_bytes()
    log_tail = raw[-32768:].decode("utf-8", errors="replace")
except OSError:
    pass

payload = {
    "taskId": task_id,
    "targetId": target_id,
    "component": component,
    "status": status,
    "version": version,
    "previousVersion": previous_version,
    "message": message,
    "logPath": log_path,
    "logTail": log_tail,
    "rolledBack": rolled_back == "true",
    "rollbackMessage": rollback_message,
}
fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
  mv -f "$temp_file" "$RECEIPT_FILE"
}

remaining_seconds() {
  local now remaining
  now="$(date +%s)"
  remaining=$((DEADLINE_EPOCH - now))
  (( remaining > 0 )) || return 1
  printf '%s' "$remaining"
}

run_with_deadline() {
  local remaining
  remaining="$(remaining_seconds)" || return 124
  timeout --signal=TERM --kill-after=10s "${remaining}s" "$@"
}

wait_for_health_until() {
  local service="$1"
  local deadline="$2"
  local cid state health status
  while (( $(date +%s) < deadline )); do
    cid="$("${COMPOSE[@]}" ps -aq "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      status="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
      state="${status%%|*}"
      health="${status#*|}"
      if [[ "$health" == "healthy" || ( "$health" == "none" && "$state" == "running" ) ]]; then
        return 0
      fi
      case "$state" in
        exited|dead)
          "${COMPOSE[@]}" logs --tail=120 "$service" >>"$LOG_FILE" 2>&1 || true
          return 1
          ;;
      esac
      if [[ "$health" == "unhealthy" ]]; then
        "${COMPOSE[@]}" logs --tail=120 "$service" >>"$LOG_FILE" 2>&1 || true
        return 1
      fi
    fi
    sleep 2
  done
  "${COMPOSE[@]}" logs --tail=120 "$service" >>"$LOG_FILE" 2>&1 || true
  return 1
}

restore_env_snapshot() {
  local temp_file="$ENV_FILE.rollback-$$"
  cp -p "$ENV_SNAPSHOT" "$temp_file"
  mv -f "$temp_file" "$ENV_FILE"
}

rollback_component() {
  [[ "$ENV_CHANGED" == "1" && "$COMMITTED" != "1" && -f "$ENV_SNAPSHOT" ]] || return 2
  log "恢复升级前配置并重新启动 $COMPONENT"
  restore_env_snapshot || return 1
  if ! timeout --signal=TERM --kill-after=10s 180s "${COMPOSE[@]}" up -d --no-deps "$COMPONENT" >>"$LOG_FILE" 2>&1; then
    return 1
  fi
  wait_for_health_until "$COMPONENT" "$(( $(date +%s) + 180 ))"
}

handle_failure() {
  local message="$1"
  local exit_code="${2:-1}"
  local rolled_back=false
  local rollback_message="未修改运行配置"
  if [[ "$FAILURE_HANDLED" == "1" ]]; then
    exit "$exit_code"
  fi
  FAILURE_HANDLED=1
  trap - ERR
  set +e
  log "失败: $message"
  if [[ "$ENV_CHANGED" == "1" && "$COMMITTED" != "1" ]]; then
    if rollback_component; then
      rolled_back=true
      rollback_message="已恢复升级前配置，旧组件健康检查通过"
      log "$rollback_message"
    else
      rollback_message="已尝试恢复升级前配置，但旧组件未通过健康检查；数据库备份和日志已保留"
      log "$rollback_message"
    fi
  fi
  write_receipt "failed" "$message" "$rolled_back" "$rollback_message" || log "失败回执写入失败"
  rm -f "$REQUEST_FILE"
  exit "$exit_code"
}

on_unexpected_error() {
  local exit_code="$1"
  local line="$2"
  handle_failure "$LAST_STEP 失败（行 ${line}，退出码 ${exit_code}）" "$exit_code"
}

trap 'on_unexpected_error "$?" "$LINENO"' ERR

parse_request() {
  local parsed_file="$1"
  python3 - "$REQUEST_FILE" "$TASK_ID" "$TEST_MODE" >"$parsed_file" <<'PY'
import json
import os
import re
import stat
import sys
import time

path, expected_task_id, test_mode = sys.argv[1:]
info = os.lstat(path)
if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
    raise SystemExit("请求文件必须是普通文件")
if test_mode != "1":
    if info.st_uid != 0:
        raise SystemExit("请求文件必须由 root 持有")
    if info.st_mode & 0o022:
        raise SystemExit("请求文件不能允许组或其他用户写入")
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

task_id = str(payload.get("taskId", "")).strip()
target_id = str(payload.get("targetId", "")).strip()
component = str(payload.get("component", "")).strip()
version = str(payload.get("targetVersion", "")).strip()
image = str(payload.get("image", "")).strip()
digest = str(payload.get("digest", "")).strip().lower()
timeout_sec = payload.get("timeoutSec")
requested_at_ms = payload.get("requestedAtMs")

uuid_pattern = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
if task_id != expected_task_id or not uuid_pattern.fullmatch(task_id) or not uuid_pattern.fullmatch(target_id):
    raise SystemExit("任务标识格式不合法")
if component not in {"server", "web"}:
    raise SystemExit("升级组件只允许 server 或 web")
if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", version):
    raise SystemExit("目标版本格式不合法")
if not re.fullmatch(r"[A-Za-z0-9._:/-]{1,512}", image):
    raise SystemExit("目标镜像格式不合法")
if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
    raise SystemExit("目标镜像摘要格式不合法")
if not isinstance(timeout_sec, int) or isinstance(timeout_sec, bool) or not 60 <= timeout_sec <= 3600:
    raise SystemExit("升级超时时间必须在 60 到 3600 秒之间")
if not isinstance(requested_at_ms, int) or isinstance(requested_at_ms, bool):
    raise SystemExit("请求时间格式不合法")
now_ms = int(time.time() * 1000)
if requested_at_ms > now_ms + 60_000 or now_ms - requested_at_ms > 300_000:
    raise SystemExit("升级请求已过期")

for value in (task_id, target_id, component, version, image, digest, str(timeout_sec), str(requested_at_ms)):
    sys.stdout.buffer.write(value.encode("utf-8") + b"\0")
PY
}

update_env_component() {
  local image_key="$1"
  local version_key="$2"
  local pinned_image="$3"
  local temp_file="$ENV_FILE.tmp-$$"
  python3 - "$ENV_FILE" "$temp_file" "$image_key" "$pinned_image" "$version_key" "$TARGET_VERSION" <<'PY'
import os
import stat
import sys

source, destination, image_key, image_value, version_key, version_value = sys.argv[1:]
source_stat = os.stat(source)
with open(source, "r", encoding="utf-8") as handle:
    lines = handle.readlines()

updates = {image_key: image_value, version_key: version_value}
seen = set()
result = []
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith("#") or "=" not in line:
        result.append(line)
        continue
    key = line.split("=", 1)[0].strip()
    if key in updates:
        result.append(f"{key}={updates[key]}\n")
        seen.add(key)
    else:
        result.append(line)
for key, value in updates.items():
    if key not in seen:
        if result and not result[-1].endswith("\n"):
            result[-1] += "\n"
        result.append(f"{key}={value}\n")

fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IMODE(source_stat.st_mode))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.writelines(result)
    handle.flush()
    os.fsync(handle.fileno())
try:
    os.chown(destination, source_stat.st_uid, source_stat.st_gid)
except PermissionError:
    pass
PY
  mv -f "$temp_file" "$ENV_FILE"
}

write_runtime_state() {
  local temp_file="$RUNTIME_STATE_FILE.tmp-$$"
  mkdir -p "$(dirname "$RUNTIME_STATE_FILE")"
  python3 - "$RUNTIME_STATE_FILE" "$temp_file" "$COMPONENT" "$TARGET_VERSION" "$TARGET_IMAGE" "$TARGET_DIGEST" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

source, destination, component, version, image, digest = sys.argv[1:]
payload = {"components": {}}
try:
    with open(source, "r", encoding="utf-8") as handle:
        current = json.load(handle)
    if isinstance(current, dict) and isinstance(current.get("components"), dict):
        payload = current
except (OSError, ValueError):
    pass
payload.setdefault("components", {})[component] = {
    "version": version,
    "image": image,
    "digest": digest,
    "updatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
  mv -f "$temp_file" "$RUNTIME_STATE_FILE"
}

backup_server_database() {
  local postgres_user postgres_db dump_file
  postgres_user="$(strip_env_quotes "$(read_env POSTGRES_USER)")"
  postgres_db="$(strip_env_quotes "$(read_env POSTGRES_DB)")"
  [[ -n "$postgres_user" ]] || postgres_user=baize
  [[ -n "$postgres_db" ]] || postgres_db=baize
  BACKUP_DIR="$ROOT_DIR/runtime/image-upgrade/backups/$TASK_ID"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  cp -p "$ENV_FILE" "$BACKUP_DIR/.env"
  cp -p "$ROOT_DIR/docker-compose.yml" "$BACKUP_DIR/docker-compose.yml"
  [[ -f "$ROOT_DIR/releases/manifest.env" ]] && cp -p "$ROOT_DIR/releases/manifest.env" "$BACKUP_DIR/manifest.env"
  [[ -f "$RUNTIME_STATE_FILE" ]] && cp -p "$RUNTIME_STATE_FILE" "$BACKUP_DIR/current.json"
  run_with_deadline "${COMPOSE[@]}" config >"$BACKUP_DIR/compose-config.yaml"
  run_with_deadline "${COMPOSE[@]}" exec -T postgres pg_isready -U "$postgres_user" -d "$postgres_db" >/dev/null
  dump_file="$BACKUP_DIR/postgres.dump.tmp"
  run_with_deadline "${COMPOSE[@]}" exec -T postgres pg_dump -U "$postgres_user" -d "$postgres_db" -Fc >"$dump_file"
  [[ -s "$dump_file" ]]
  mv -f "$dump_file" "$BACKUP_DIR/postgres.dump"
  python3 - "$BACKUP_DIR/metadata.json" "$TASK_ID" "$TARGET_VERSION" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, task_id, target_version = sys.argv[1:]
payload = {
    "schemaVersion": "baize.image-upgrade-backup.v1",
    "taskId": task_id,
    "component": "server",
    "targetVersion": target_version,
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

main() {
  if ! is_safe_task_id "$TASK_ID"; then
    printf '[image-updater] ERROR: task id is invalid\n' >&2
    exit 2
  fi
  mkdir -p "$REQUEST_DIR" "$RECEIPT_DIR" "$LOG_DIR"
  chmod 700 "$REQUEST_DIR" "$RECEIPT_DIR" "$LOG_DIR" 2>/dev/null || true
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
  log "开始处理镜像升级任务 $TASK_ID"

  command -v python3 >/dev/null 2>&1 || handle_failure "宿主机缺少 python3" 2
  command -v docker >/dev/null 2>&1 || handle_failure "宿主机缺少 Docker" 2
  command -v timeout >/dev/null 2>&1 || handle_failure "宿主机缺少 timeout" 2
  command -v flock >/dev/null 2>&1 || handle_failure "宿主机缺少 flock" 2
  [[ -f "$REQUEST_FILE" && ! -L "$REQUEST_FILE" ]] || handle_failure "升级请求文件不存在或类型不安全" 2

  LAST_STEP="校验结构化升级请求"
  local parsed_file="$LOG_DIR/$TASK_ID.request"
  if ! parse_request "$parsed_file" 2>>"$LOG_FILE"; then
    handle_failure "结构化升级请求校验失败" 2
  fi
  local fields=()
  mapfile -d '' -t fields <"$parsed_file"
  rm -f "$parsed_file"
  (( ${#fields[@]} == 8 )) || handle_failure "结构化升级请求字段不完整" 2
  TASK_ID="${fields[0]}"
  TARGET_ID="${fields[1]}"
  COMPONENT="${fields[2]}"
  TARGET_VERSION="${fields[3]}"
  TARGET_IMAGE="${fields[4]}"
  TARGET_DIGEST="${fields[5]}"
  TIMEOUT_SEC="${fields[6]}"
  DEADLINE_EPOCH=$(( $(date +%s) + TIMEOUT_SEC ))

  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || handle_failure "已有 Server 或 Web 镜像升级正在执行" 3

  [[ -n "$ROOT_DIR" && "$ROOT_DIR" == /* && -d "$ROOT_DIR" ]] || handle_failure "白泽安装目录配置无效" 2
  ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"
  ENV_FILE="$ROOT_DIR/.env"
  ENV_SNAPSHOT="$LOG_DIR/$TASK_ID.env.before"
  RUNTIME_STATE_FILE="$ROOT_DIR/runtime/release/current.json"
  [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || handle_failure "未找到安全的部署配置文件" 2
  [[ -f "$ROOT_DIR/docker-compose.yml" && ! -L "$ROOT_DIR/docker-compose.yml" ]] || handle_failure "未找到安全的 Compose 配置" 2
  docker compose version >/dev/null 2>&1 || handle_failure "Docker Compose v2 不可用" 2

  local deploy_mode stack_mode image_key version_key pinned_image
  deploy_mode="$(strip_env_quotes "$(read_env BAIZE_DEPLOY_MODE)")"
  stack_mode="$(strip_env_quotes "$(read_env BAIZE_STACK_MODE)")"
  [[ "$deploy_mode" == "image" ]] || handle_failure "当前部署不是容器镜像模式" 2
  [[ -n "$stack_mode" ]] || stack_mode=full
  if [[ "$COMPONENT" == "web" && "$stack_mode" != "full" ]]; then
    handle_failure "当前部署未运行 Web 控制台" 2
  fi

  COMPOSE=(docker compose --project-directory "$ROOT_DIR" --env-file "$ENV_FILE" -f "$ROOT_DIR/docker-compose.yml")
  if [[ "$stack_mode" == "full" ]]; then
    COMPOSE+=(--profile web)
  fi
  if [[ "$COMPONENT" == "server" ]]; then
    image_key=BAIZE_SERVER_IMAGE
    version_key=BAIZE_SERVER_VERSION
  else
    image_key=BAIZE_WEB_IMAGE
    version_key=BAIZE_WEB_VERSION
  fi
  PREVIOUS_IMAGE="$(strip_env_quotes "$(read_env "$image_key")")"
  PREVIOUS_VERSION="$(strip_env_quotes "$(read_env "$version_key")")"
  cp -p "$ENV_FILE" "$ENV_SNAPSHOT"

  if [[ "$COMPONENT" == "server" ]]; then
    LAST_STEP="创建 Server 升级前数据库备份"
    log "$LAST_STEP"
    if ! backup_server_database >>"$LOG_FILE" 2>&1; then
      handle_failure "$LAST_STEP 失败" 4
    fi
    log "数据库备份已保存到 $BACKUP_DIR"
  fi

  pinned_image="$TARGET_IMAGE@$TARGET_DIGEST"
  LAST_STEP="拉取并校验目标镜像"
  log "$LAST_STEP: $TARGET_IMAGE@$TARGET_DIGEST"
  if ! run_with_deadline docker pull "$pinned_image" >>"$LOG_FILE" 2>&1; then
    handle_failure "$LAST_STEP 失败" 5
  fi
  if ! run_with_deadline docker image inspect "$pinned_image" >/dev/null 2>&1; then
    handle_failure "目标镜像摘要校验失败" 5
  fi

  LAST_STEP="原子更新组件镜像配置"
  update_env_component "$image_key" "$version_key" "$pinned_image"
  ENV_CHANGED=1

  LAST_STEP="重建 $COMPONENT 容器"
  log "$LAST_STEP"
  if ! run_with_deadline "${COMPOSE[@]}" up -d --no-deps "$COMPONENT" >>"$LOG_FILE" 2>&1; then
    handle_failure "$LAST_STEP 失败" 6
  fi
  if ! wait_for_health_until "$COMPONENT" "$DEADLINE_EPOCH"; then
    handle_failure "$COMPONENT 健康检查未通过" 6
  fi

  local cid expected_image_id actual_image_id
  cid="$("${COMPOSE[@]}" ps -q "$COMPONENT")"
  expected_image_id="$(docker image inspect -f '{{.Id}}' "$pinned_image")"
  actual_image_id="$(docker inspect -f '{{.Image}}' "$cid")"
  [[ -n "$expected_image_id" && "$actual_image_id" == "$expected_image_id" ]] || handle_failure "运行容器未使用目标摘要镜像" 6

  LAST_STEP="写入当前组件版本状态"
  write_runtime_state
  COMMITTED=1
  log "$COMPONENT 已升级到 ${TARGET_VERSION}，健康检查和镜像摘要校验通过"
  if ! write_receipt "completed" "组件升级完成" false ""; then
    log "成功回执写入失败，保留请求文件供人工检查"
    exit 7
  fi
  rm -f "$REQUEST_FILE" "$ENV_SNAPSHOT"
}

main "$@"

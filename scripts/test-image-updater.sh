#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/baize-image-updater-test.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
BASH_BIN="$(command -v bash)"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "[test-image-updater] ERROR: $*" >&2
  exit 1
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$path" || fail "$path 缺少预期内容: $expected"
}

assert_json() {
  local path="$1"
  local expression="$2"
  python3 - "$path" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
if not eval(expression, {"__builtins__": {}}, {"data": payload}):
    raise SystemExit(f"JSON assertion failed: {expression}\n{payload!r}")
PY
}

mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --signal=*|--kill-after=*) shift ;;
    *s) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
SH

cat >"$FAKE_BIN/flock" <<'SH'
#!/usr/bin/env bash
if [[ "${BAIZE_MOCK_LOCK_CONFLICT:-0}" == "1" ]]; then
  exit 1
fi
exit 0
SH

cat >"$FAKE_BIN/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${BAIZE_MOCK_DOCKER_LOG:?}"
printf '\n' >>"$BAIZE_MOCK_DOCKER_LOG"

env_file=""
if [[ "${1:-}" == "compose" ]]; then
  shift
  if [[ "${1:-}" == "version" ]]; then
    exit 0
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-directory|-f)
        shift 2
        ;;
      --env-file)
        env_file="$2"
        shift 2
        ;;
      --profile)
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done
  command_name="${1:-}"
  shift || true
  case "$command_name" in
    config)
      printf '%s\n' 'services: {}'
      ;;
    exec)
      if [[ "$*" == *"pg_dump"* ]]; then
        printf '%s\n' 'mock-postgres-dump'
      fi
      ;;
    up)
      ;;
    ps)
      printf '%s\n' 'mock-container-id'
      ;;
    logs)
      printf '%s\n' 'mock component logs'
      ;;
    *)
      echo "unexpected docker compose command: $command_name $*" >&2
      exit 90
      ;;
  esac
  exit 0
fi

case "${1:-}" in
  pull)
    exit 0
    ;;
  image)
    [[ "${2:-}" == "inspect" ]] || exit 91
    if [[ "${BAIZE_MOCK_FAIL_DIGEST_INSPECT:-0}" == "1" && "${3:-}" != "-f" ]]; then
      exit 1
    fi
    if [[ "${3:-}" == "-f" ]]; then
      printf '%s\n' 'sha256:mock-target-image-id'
    fi
    exit 0
    ;;
  inspect)
    format="${3:-}"
    if [[ "$format" == *'.State.Status'* ]]; then
      if [[ "${BAIZE_MOCK_FAIL_TARGET_HEALTH:-0}" == "1" ]] \
        && grep -Eq '^BAIZE_(SERVER|WEB)_IMAGE=.*@sha256:' "${BAIZE_MOCK_ENV_FILE:?}"; then
        printf '%s\n' 'running|unhealthy'
      else
        printf '%s\n' 'running|healthy'
      fi
    elif [[ "$format" == *'.Image'* ]]; then
      printf '%s\n' 'sha256:mock-target-image-id'
    else
      exit 92
    fi
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 93
    ;;
esac
SH

chmod +x "$FAKE_BIN/timeout" "$FAKE_BIN/flock" "$FAKE_BIN/docker"

create_case() {
  local case_name="$1"
  local component="$2"
  local stack_mode="${3:-full}"
  local requested_at_offset_ms="${4:-0}"
  local case_dir="$TEST_ROOT/$case_name"
  local install_root="$case_dir/install"
  local agent_data="$case_dir/agent-data"
  local task_id="11111111-1111-4111-8111-111111111111"
  local target_id="22222222-2222-4222-8222-222222222222"
  local digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$install_root/releases" "$agent_data/image-upgrade/requests"
  cat >"$install_root/.env" <<ENV
BAIZE_DEPLOY_MODE=image
BAIZE_STACK_MODE=$stack_mode
BAIZE_SERVER_VERSION=0.1.0
BAIZE_SERVER_IMAGE=ghcr.io/example/baize-server:0.1.0
BAIZE_WEB_VERSION=1.0.0
BAIZE_WEB_IMAGE=ghcr.io/example/baize-web:1.0.0
POSTGRES_USER=baize
POSTGRES_DB=baize
ENV
  printf '%s\n' 'services: {}' >"$install_root/docker-compose.yml"
  printf '%s\n' 'SERVER_VERSION=0.1.0' >"$install_root/releases/manifest.env"
  python3 - "$agent_data/image-upgrade/requests/$task_id.json" "$task_id" "$target_id" "$component" "$digest" "$requested_at_offset_ms" <<'PY'
import json
import sys
import time

path, task_id, target_id, component, digest, requested_at_offset_ms = sys.argv[1:]
image = f"ghcr.io/example/baize-{component}:0.2.0" if component == "server" else "ghcr.io/example/baize-web:1.1.0"
version = "0.2.0" if component == "server" else "1.1.0"
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "taskId": task_id,
        "targetId": target_id,
        "component": component,
        "targetVersion": version,
        "image": image,
        "digest": digest,
        "timeoutSec": 120,
        "requestedAtMs": int(time.time() * 1000) + int(requested_at_offset_ms),
    }, handle)
PY
  printf '%s\n' "$case_dir" "$install_root" "$agent_data" "$task_id" "$digest"
}

run_case() {
  local fail_health="$1"
  local fail_digest="$2"
  local lock_conflict="$3"
  local case_dir="$4"
  local install_root="$5"
  local agent_data="$6"
  local task_id="$7"
  BAIZE_ROOT_DIR="$install_root" \
  BAIZE_AGENT_DATA_DIR="$agent_data" \
  BAIZE_IMAGE_UPGRADE_LOCK_FILE="$case_dir/image-upgrade.lock" \
  BAIZE_IMAGE_UPDATER_TEST_MODE=1 \
  BAIZE_MOCK_DOCKER_LOG="$case_dir/docker.log" \
  BAIZE_MOCK_ENV_FILE="$install_root/.env" \
  BAIZE_MOCK_FAIL_TARGET_HEALTH="$fail_health" \
  BAIZE_MOCK_FAIL_DIGEST_INSPECT="$fail_digest" \
  BAIZE_MOCK_LOCK_CONFLICT="$lock_conflict" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BASH_BIN" "$ROOT_DIR/scripts/image-updater.sh" "$task_id"
}

mapfile -t web_case < <(create_case web-success web)
run_case 0 0 0 "${web_case[0]}" "${web_case[1]}" "${web_case[2]}" "${web_case[3]}"
assert_file_contains "${web_case[1]}/.env" "BAIZE_WEB_VERSION=1.1.0"
assert_file_contains "${web_case[1]}/.env" "BAIZE_WEB_IMAGE=ghcr.io/example/baize-web:1.1.0@${web_case[4]}"
assert_file_contains "${web_case[1]}/.env" "BAIZE_SERVER_VERSION=0.1.0"
assert_json "${web_case[2]}/image-upgrade/receipts/${web_case[3]}.json" 'data["status"] == "completed" and data["component"] == "web"'
assert_json "${web_case[1]}/runtime/release/current.json" 'data["components"]["web"]["version"] == "1.1.0"'
[[ ! -e "${web_case[2]}/image-upgrade/requests/${web_case[3]}.json" ]] || fail "Web 成功后请求文件未清理"

mapfile -t server_case < <(create_case server-success server)
run_case 0 0 0 "${server_case[0]}" "${server_case[1]}" "${server_case[2]}" "${server_case[3]}"
backup_dir="${server_case[1]}/runtime/image-upgrade/backups/${server_case[3]}"
[[ -s "$backup_dir/postgres.dump" ]] || fail "Server 升级前数据库备份缺失"
assert_file_contains "${server_case[1]}/.env" "BAIZE_SERVER_VERSION=0.2.0"
assert_json "${server_case[2]}/image-upgrade/receipts/${server_case[3]}.json" 'data["status"] == "completed" and data["component"] == "server"'

mapfile -t rollback_case < <(create_case server-rollback server)
cp "${rollback_case[1]}/.env" "${rollback_case[0]}/expected.env"
if run_case 1 0 0 "${rollback_case[0]}" "${rollback_case[1]}" "${rollback_case[2]}" "${rollback_case[3]}"; then
  fail "健康检查失败场景应返回非零退出码"
fi
cmp -s "${rollback_case[0]}/expected.env" "${rollback_case[1]}/.env" || fail "失败后未完整恢复升级前 .env"
assert_json "${rollback_case[2]}/image-upgrade/receipts/${rollback_case[3]}.json" 'data["status"] == "failed" and data["rolledBack"] is True'
[[ -s "${rollback_case[1]}/runtime/image-upgrade/backups/${rollback_case[3]}/postgres.dump" ]] || fail "回滚场景未保留数据库备份"
[[ ! -e "${rollback_case[2]}/image-upgrade/requests/${rollback_case[3]}.json" ]] || fail "失败回执生成后请求文件未清理"

mapfile -t digest_case < <(create_case digest-mismatch web)
cp "${digest_case[1]}/.env" "${digest_case[0]}/expected.env"
if run_case 0 1 0 "${digest_case[0]}" "${digest_case[1]}" "${digest_case[2]}" "${digest_case[3]}"; then
  fail "摘要校验失败场景应返回非零退出码"
fi
cmp -s "${digest_case[0]}/expected.env" "${digest_case[1]}/.env" || fail "摘要校验失败不应修改 .env"
assert_json "${digest_case[2]}/image-upgrade/receipts/${digest_case[3]}.json" 'data["status"] == "failed" and "摘要校验失败" in data["message"]'

mapfile -t lock_case < <(create_case lock-conflict web)
if run_case 0 0 1 "${lock_case[0]}" "${lock_case[1]}" "${lock_case[2]}" "${lock_case[3]}"; then
  fail "全局锁冲突场景应返回非零退出码"
fi
assert_json "${lock_case[2]}/image-upgrade/receipts/${lock_case[3]}.json" 'data["status"] == "failed" and "正在执行" in data["message"]'

mapfile -t server_only_case < <(create_case server-only-rejects-web web server-only)
if run_case 0 0 0 "${server_only_case[0]}" "${server_only_case[1]}" "${server_only_case[2]}" "${server_only_case[3]}"; then
  fail "server-only 部署应拒绝 Web 升级"
fi
assert_json "${server_only_case[2]}/image-upgrade/receipts/${server_only_case[3]}.json" 'data["status"] == "failed" and "未运行 Web" in data["message"]'

mapfile -t expired_case < <(create_case expired-request web full -600000)
if run_case 0 0 0 "${expired_case[0]}" "${expired_case[1]}" "${expired_case[2]}" "${expired_case[3]}"; then
  fail "过期升级请求应返回非零退出码"
fi
assert_json "${expired_case[2]}/image-upgrade/receipts/${expired_case[3]}.json" 'data["status"] == "failed" and "请求校验失败" in data["message"]'
assert_file_contains "${expired_case[2]}/image-upgrade/logs/${expired_case[3]}.log" "升级请求已过期"

echo "[test-image-updater] PASS: 成功、备份、回滚、摘要、互斥锁、部署模式和请求时效均符合预期"

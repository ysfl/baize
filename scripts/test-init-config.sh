#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/baize-init-config-test.XXXXXX")"

cleanup() {
  rm -f \
    "$TEST_TMP_DIR/github.env" \
    "$TEST_TMP_DIR/acr.env" \
    "$TEST_TMP_DIR/interactive.env"
  rmdir "$TEST_TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

cd "$ROOT_DIR"

# 当前默认镜像版本跟随发布清单，避免每次发版手工同步断言。
CURRENT_SERVER_VERSION="$(sed -n 's/^SERVER_VERSION=//p' "$ROOT_DIR/releases/manifest.env" | head -1)"

assert_line() {
  local file="$1"
  local expected="$2"
  grep -Fqx "$expected" "$file" || {
    printf '断言失败: %s 中缺少 %s\n' "$file" "$expected" >&2
    exit 1
  }
}

bash "$ROOT_DIR/scripts/init-config.sh" \
  --env-file "$TEST_TMP_DIR/github.env" \
  --force \
  --lang en \
  --image-source github \
  --server-public-port 23501 \
  --public-url http://127.0.0.1:23501

assert_line "$TEST_TMP_DIR/github.env" "BAIZE_IMAGE_SOURCE=github"
assert_line "$TEST_TMP_DIR/github.env" "BAIZE_RUNTIME_RELEASE_STATE_PATH=/app/runtime/release/current.json"
assert_line "$TEST_TMP_DIR/github.env" "BAIZE_IMAGE_UPGRADE_TIMEOUT_SEC=900"
assert_line "$TEST_TMP_DIR/github.env" "BAIZE_POSTGRES_IMAGE=timescale/timescaledb:latest-pg16"
assert_line "$TEST_TMP_DIR/github.env" "BAIZE_REDIS_IMAGE=redis:7-alpine"
assert_line "$TEST_TMP_DIR/github.env" "BAIZE_SERVER_IMAGE=ghcr.io/ysfl/baize-server:$CURRENT_SERVER_VERSION"
assert_line "$TEST_TMP_DIR/github.env" "SERVER_TRUSTED_PROXIES="
assert_line "$TEST_TMP_DIR/github.env" "AGENT_PUBLIC_SERVER_URL=http://127.0.0.1:23501"
assert_line "$TEST_TMP_DIR/github.env" "BAIZE_LOGIN_NOTICE_DISCORD_URL=https://discord.gg/UMR7mnZFqh"
assert_line "$TEST_TMP_DIR/github.env" "BAIZE_LOGIN_NOTICE_TELEGRAM_URL=https://t.me/+y3n_66PfRSw0ZDRl"

bash "$ROOT_DIR/scripts/init-config.sh" \
  --env-file "$TEST_TMP_DIR/acr.env" \
  --force \
  --lang zh \
  --image-source acr \
  --server-public-port 24501 \
  --public-url http://127.0.0.1:24501

assert_line "$TEST_TMP_DIR/acr.env" "BAIZE_IMAGE_SOURCE=acr"
assert_line "$TEST_TMP_DIR/acr.env" "BAIZE_POSTGRES_IMAGE=m.daocloud.io/docker.io/timescale/timescaledb:latest-pg16"
assert_line "$TEST_TMP_DIR/acr.env" "BAIZE_REDIS_IMAGE=m.daocloud.io/docker.io/library/redis:7-alpine"
assert_line "$TEST_TMP_DIR/acr.env" "BAIZE_SERVER_IMAGE=crpi-2k5j97zcnpyukrse.cn-hangzhou.personal.cr.aliyuncs.com/ysfl/baize-server:$CURRENT_SERVER_VERSION"
assert_line "$TEST_TMP_DIR/acr.env" "BAIZE_LATEST_MANIFEST_URL=https://gitee.com/ysfl/baize/raw/main/releases/latest.json"

if command -v expect >/dev/null 2>&1; then
  EXPECT_ENV_FILE="$TEST_TMP_DIR/interactive.env" expect <<'EXPECT_EOF'
set timeout 10
log_user 0
spawn bash scripts/init-config.sh --interactive --lang zh --env-file $env(EXPECT_ENV_FILE) --force
expect "镜像下载来源*"
send "\r"
expect "部署形态*"
send "\r"
expect "中心服务宿主机端口*"
send "24001\r"
expect "PostgreSQL 宿主机端口*"
send "\r"
expect "Redis 宿主机端口*"
send "\r"
expect "控制台宿主机端口*"
send "\r"
expect "被纳管服务器访问白泽的地址*http://127.0.0.1:24001*"
send "10.0.0.8:24001\r"
expect "地址格式不正确*http://127.0.0.1:24001*请重新输入*"
expect "被纳管服务器访问白泽的地址*"
send "http://10.0.0.8:24001\r"
expect "控制台访问白泽服务的地址*"
send "\r"
expect "中心服务架构*"
send "\r"
expect "备份文件根目录*"
send "\r"
expect eof
catch wait result
exit [lindex $result 3]
EXPECT_EOF

  assert_line "$TEST_TMP_DIR/interactive.env" "BAIZE_IMAGE_SOURCE=acr"
  assert_line "$TEST_TMP_DIR/interactive.env" "SERVER_PUBLIC_PORT=24001"
  assert_line "$TEST_TMP_DIR/interactive.env" "AGENT_PUBLIC_SERVER_URL=http://10.0.0.8:24001"
else
  printf '未安装 expect，跳过交互式伪终端用例。\n'
fi

printf 'init-config 测试通过。\n'

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() {
  printf '[baize-ai-upgrade] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
白泽 AI 接入升级器（只更新 MCP 与 Skill）

该脚本会先快进更新当前 baize 公开入口，再执行 AI 接入安装器。
它不会安装或升级白泽中心服务、控制台或 Agent，也不会读取登录凭据。

用法：
  bash scripts/upgrade-ai-access.sh [安装器选项]

示例：
  bash scripts/upgrade-ai-access.sh --lang zh
  bash scripts/upgrade-ai-access.sh --mcp-version 0.1.1 --client codex
EOF
  exit 0
fi

if [[ ! -d "${REPO_ROOT}/.git" ]]; then
  die "请在通过 git clone 获取的 baize 目录中运行此脚本；这样才能同时更新 AI 接入说明和 Skill。"
fi

command -v git >/dev/null 2>&1 || die "未找到 git，请先安装 Git。"

if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=all)" ]]; then
  die "baize 目录存在本地修改。请先提交或暂存这些修改，再运行升级；脚本不会覆盖本地内容。"
fi

git -C "${REPO_ROOT}" pull --ff-only || die "公开入口更新失败。请检查网络、远端分支和本地 Git 状态后重试。"

exec "${REPO_ROOT}/scripts/install-ai-access.sh" "$@"

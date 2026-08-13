#!/usr/bin/env bash
set -euo pipefail

USER_HOME="${HOME:-}"
[[ -n "${USER_HOME}" ]] || { echo "无法确定当前用户的主目录。" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL_SOURCE_DIR="${REPO_ROOT}/skills/baize-ai"

LANGUAGE="zh"
CLIENT="auto"
SKILL_DIR=""
MCP_VERSION="latest"
SKIP_MCP=0
SKIP_SKILL=0
MCP_BIN_DIR="${BAIZE_AI_BIN_DIR:-${USER_HOME}/.local/bin}"
MCP_TMP_DIR=""
REPO="ysfl/baize-mcp"

usage() {
  cat <<'EOF'
白泽 AI 接入安装器（只安装 AI 接入组件）

该脚本不会安装白泽中心服务、控制台或 Agent，也不会要求或保存白泽地址、用户名、密码、Token。

用法：
  bash scripts/install-ai-access.sh [选项]

选项：
  --lang zh|en          输出语言，默认 zh
  --client auto|codex|claude|manual
                        安装 Skill 的客户端；默认自动选择
  --skill-dir <目录>    指定 Skill 安装目录
  --mcp-version <版本>  安装指定 MCP 版本，例如 0.1.0；默认 latest
  --skip-mcp            不安装 Baize MCP
  --skip-skill          不安装 Baize Skill
  -h, --help            显示帮助

登录白泽请在安装完成后运行 baize-mcp login。登录信息由 MCP 保存在本机配置和系统凭据存储中。
EOF
}

die() { echo "[baize-ai] ERROR: $*" >&2; exit 1; }
cleanup_mcp_temp() {
  if [[ -n "${MCP_TMP_DIR}" && -d "${MCP_TMP_DIR}" ]]; then
    rm -rf -- "${MCP_TMP_DIR}"
  fi
  MCP_TMP_DIR=""
}
say() {
  if [[ "${LANGUAGE}" == "en" ]]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$1"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)
      LANGUAGE="${2:-}"
      [[ "${LANGUAGE}" == "zh" || "${LANGUAGE}" == "en" ]] || die "--lang must be zh or en"
      shift 2
      ;;
    --client)
      CLIENT="${2:-}"
      [[ "${CLIENT}" == "auto" || "${CLIENT}" == "codex" || "${CLIENT}" == "claude" || "${CLIENT}" == "manual" ]] || die "invalid --client"
      shift 2
      ;;
    --skill-dir)
      SKILL_DIR="${2:-}"
      [[ -n "${SKILL_DIR}" ]] || die "--skill-dir cannot be empty"
      shift 2
      ;;
    --mcp-version)
      MCP_VERSION="${2:-}"
      [[ "${MCP_VERSION}" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "invalid --mcp-version"
      shift 2
      ;;
    --skip-mcp) SKIP_MCP=1; shift ;;
    --skip-skill) SKIP_SKILL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; return; fi
  command -v shasum >/dev/null 2>&1 || die "sha256sum or shasum is required"
  shasum -a 256 "$1" | awk '{print $1}'
}

release_api() {
  if [[ "${MCP_VERSION}" == "latest" ]]; then
    printf 'https://api.github.com/repos/%s/releases/latest' "${REPO}"
  else
    printf 'https://api.github.com/repos/%s/releases/tags/v%s' "${REPO}" "${MCP_VERSION}"
  fi
}

release_asset_url() {
  local metadata="$1" name="$2"
  printf '%s' "${metadata}" | python3 -c 'import json,sys; name=sys.argv[1]; data=json.load(sys.stdin); matches=[a["browser_download_url"] for a in data.get("assets",[]) if a.get("name")==name]; print(matches[0] if matches else "")' "${name}"
}

release_tag_version() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name", ""))'
}

install_mcp() {
  local os_name arch archive_format archive_name metadata archive_url sums_url tmp_dir archive_path expected actual extract_dir binary_path checksum_path version_tag installed_version
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read release metadata"
  case "$(uname -s)" in
    Linux) os_name="linux"; archive_format="tar.gz" ;;
    Darwin) os_name="darwin"; archive_format="tar.gz" ;;
    *) die "当前脚本支持 Linux 和 macOS；Windows 请运行 install-ai-access.ps1" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac

  metadata="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$(release_api)")" || die "无法读取 Baize MCP 发布信息"
  version_tag="$(release_tag_version "${metadata}")"
  [[ "${version_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "发布信息缺少有效版本"
  archive_name="baize-mcp_${version_tag#v}_${os_name}_${arch}.${archive_format}"
  archive_url="$(release_asset_url "${metadata}" "${archive_name}")"
  sums_url="$(release_asset_url "${metadata}" SHA256SUMS)"
  [[ -n "${archive_url}" && -n "${sums_url}" ]] || die "发布中没有匹配当前系统的运行文件或校验文件"

  MCP_TMP_DIR="$(mktemp -d)"
  tmp_dir="${MCP_TMP_DIR}"
  trap cleanup_mcp_temp EXIT
  archive_path="${tmp_dir}/${archive_name}"
  curl -fsSL -o "${archive_path}" "${archive_url}" || die "下载 Baize MCP 失败"
  curl -fsSL -o "${tmp_dir}/SHA256SUMS" "${sums_url}" || die "下载校验文件失败"
  expected="$(awk -v name="${archive_name}" '$2 == name {print $1; exit}' "${tmp_dir}/SHA256SUMS")"
  actual="$(sha256_file "${archive_path}")"
  [[ "${expected}" =~ ^[0-9a-fA-F]{64}$ && "${expected}" == "${actual}" ]] || die "Baize MCP 下载包校验失败"

  extract_dir="${tmp_dir}/extract"
  mkdir -p "${extract_dir}" "${MCP_BIN_DIR}"
  tar -xzf "${archive_path}" -C "${extract_dir}" || die "解压 Baize MCP 失败"
  binary_path="$(find "${extract_dir}" -type f -name baize-mcp -perm -u+x -print -quit)"
  checksum_path="$(find "${extract_dir}" -type f -name baize-mcp.sha256 -print -quit)"
  [[ -n "${binary_path}" && -n "${checksum_path}" ]] || die "发布包中缺少可执行文件或完整性文件"
  install -m 0755 "${binary_path}" "${MCP_BIN_DIR}/baize-mcp"
  install -m 0644 "${checksum_path}" "${MCP_BIN_DIR}/baize-mcp.sha256"
  installed_version="$("${MCP_BIN_DIR}/baize-mcp" version)" || die "Baize MCP 运行时完整性自检失败"
  [[ "${installed_version}" == "${version_tag#v}" ]] || die "Baize MCP 安装版本与发布版本不一致"
  cleanup_mcp_temp
  trap - EXIT
  say "已安装 Baize MCP ${version_tag#v}：${MCP_BIN_DIR}/baize-mcp" "Installed Baize MCP ${version_tag#v}: ${MCP_BIN_DIR}/baize-mcp"
}

resolve_client() {
  if [[ "${CLIENT}" != "auto" ]]; then
    return 0
  fi
  if [[ -d "${CODEX_HOME:-${USER_HOME}/.codex}" ]] || command -v codex >/dev/null 2>&1; then
    CLIENT="codex"
  elif [[ -d "${USER_HOME}/.claude" ]] || command -v claude >/dev/null 2>&1; then
    CLIENT="claude"
  else
    CLIENT="manual"
  fi
}

choose_skill_dir() {
  resolve_client
  if [[ -n "${SKILL_DIR}" ]]; then
    return 0
  fi
  case "${CLIENT}" in
    codex) SKILL_DIR="${CODEX_HOME:-${USER_HOME}/.codex}/skills/baize-ai" ;;
    claude) SKILL_DIR="${USER_HOME}/.claude/skills/baize-ai" ;;
    manual) SKILL_DIR="${USER_HOME}/.baize/skills/baize-ai" ;;
  esac
}

install_skill() {
  choose_skill_dir
  [[ -f "${SKILL_SOURCE_DIR}/SKILL.md" && -f "${SKILL_SOURCE_DIR}/agents/openai.yaml" ]] || die "当前 Baize 副本缺少 baize-ai Skill"
  mkdir -p "${SKILL_DIR}/agents"
  install -m 0644 "${SKILL_SOURCE_DIR}/SKILL.md" "${SKILL_DIR}/SKILL.md"
  install -m 0644 "${SKILL_SOURCE_DIR}/agents/openai.yaml" "${SKILL_DIR}/agents/openai.yaml"
  say "已安装 Baize Skill：${SKILL_DIR}" "Installed Baize Skill: ${SKILL_DIR}"
}

register_client() {
  if [[ "${SKIP_MCP}" != 0 ]]; then
    return 0
  fi
  resolve_client
  local binary="${MCP_BIN_DIR}/baize-mcp"
  [[ -x "${binary}" ]] || return
  local registered=0
  case "${CLIENT}" in
    codex)
      if command -v codex >/dev/null 2>&1; then
        if codex mcp list 2>/dev/null | grep -qE '(^|[[:space:]])baize([[:space:]]|$)'; then registered=1
        else codex mcp add baize -- "${binary}" serve --profile default && registered=1 || true; fi
      fi
      ;;
    claude)
      if command -v claude >/dev/null 2>&1; then
        if claude mcp list 2>/dev/null | grep -qE '(^|[[:space:]])baize([[:space:]]|$)'; then registered=1
        else claude mcp add baize -- "${binary}" serve --profile default && registered=1 || true; fi
      fi
      ;;
  esac
  if [[ "${registered}" == 1 ]]; then
    say "已尝试将 Baize MCP 注册到 ${CLIENT}。" "Baize MCP registration was added or already exists in ${CLIENT}."
  else
    say "请将下面的 MCP 配置添加到 AI 客户端（不包含白泽地址或凭据）：" "Add this MCP configuration to your AI client (it contains no Baize address or credential):"
    python3 - "${binary}" <<'PY'
import json
import sys

print(json.dumps({"mcpServers": {"baize": {"command": sys.argv[1], "args": ["serve", "--profile", "default"]}}}, indent=2))
PY
  fi
}

say "这不是白泽产品安装器，只安装 AI 接入组件（MCP 与 Skill）。" "This is not the Baize product installer; it installs only the AI access components (MCP and Skill)."
[[ "${SKIP_MCP}" == 1 ]] || install_mcp
[[ "${SKIP_SKILL}" == 1 ]] || install_skill
register_client
if [[ "${SKIP_MCP}" == 0 ]]; then
  say "下一步：运行 ${MCP_BIN_DIR}/baize-mcp login 登录你的白泽实例，再重新打开 AI 客户端。" "Next: run ${MCP_BIN_DIR}/baize-mcp login for your Baize instance, then restart your AI client."
else
  say "已跳过 MCP 安装；请确认现有 Baize MCP 已登录并已在 AI 客户端中启用。" "MCP installation was skipped; make sure your existing Baize MCP is signed in and enabled in the AI client."
fi

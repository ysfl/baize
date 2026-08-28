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
MCP_STAGE_DIR=""
MCP_BACKUP_DIR=""
REPO="ysfl/baize-mcp"

# 支持自动注册的 AI 客户端，按探测顺序排列；codex/claude/zcode/dsh 支持安装 Skill。
CLIENT_ORDER="codex claude zcode gemini qwen cursor windsurf vscode cline trae dsh"
SKILL_CAPABLE_CLIENTS="codex claude zcode dsh"
TARGET_CLIENTS=""

usage() {
  cat <<'EOF'
白泽 AI 接入安装器（只安装 AI 接入组件）

该脚本不会安装白泽中心服务、控制台或 Agent，也不会要求或保存白泽地址、用户名、密码、Token。

用法：
  bash scripts/install-ai-access.sh [选项]

选项：
  --lang zh|en          输出语言，默认 zh
  --client auto|manual|codex|claude|zcode|gemini|qwen|cursor|windsurf|vscode|cline|trae|dsh
                        注册 MCP 的客户端；auto 会注册所有已检测到的客户端，manual 不自动注册
  --skill-dir <目录>    指定 Skill 安装目录（默认随客户端自动选择）
  --mcp-version <版本>  安装指定 MCP 版本，例如 0.1.1；默认 latest
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
  if [[ -n "${MCP_STAGE_DIR}" && -d "${MCP_STAGE_DIR}" ]]; then
    rm -rf -- "${MCP_STAGE_DIR}"
  fi
  if [[ -n "${MCP_BACKUP_DIR}" && -d "${MCP_BACKUP_DIR}" ]]; then
    rm -rf -- "${MCP_BACKUP_DIR}"
  fi
  MCP_TMP_DIR=""
  MCP_STAGE_DIR=""
  MCP_BACKUP_DIR=""
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
      case "${CLIENT}" in
        auto|manual|codex|claude|zcode|gemini|qwen|cursor|windsurf|vscode|cline|trae|dsh) ;;
        *) die "invalid --client" ;;
      esac
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
  local os_name arch archive_format archive_name metadata archive_url sums_url tmp_dir archive_path expected actual extract_dir binary_path checksum_path version_tag installed_version previous_version stage_dir
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
  stage_dir="$(mktemp -d "${MCP_BIN_DIR}/.baize-mcp-install.XXXXXX")" || die "无法创建 Baize MCP 临时安装目录"
  MCP_STAGE_DIR="${stage_dir}"
  install -m 0755 "${binary_path}" "${stage_dir}/baize-mcp"
  install -m 0644 "${checksum_path}" "${stage_dir}/baize-mcp.sha256"
  installed_version="$("${stage_dir}/baize-mcp" version)" || die "Baize MCP 运行时完整性自检失败"
  if [[ "${installed_version}" != "${version_tag#v}" ]]; then
    die "Baize MCP 安装版本与发布版本不一致"
  fi
  previous_version=""
  if [[ -x "${MCP_BIN_DIR}/baize-mcp" ]]; then
    previous_version="$("${MCP_BIN_DIR}/baize-mcp" version 2>/dev/null || true)"
  fi
  replace_mcp_files "${stage_dir}" || die "替换 Baize MCP 文件失败，已保留原版本"
  cleanup_mcp_temp
  trap - EXIT
  if [[ -n "${previous_version}" && "${previous_version}" != "${installed_version}" ]]; then
    say "已将 Baize MCP 从 ${previous_version} 升级到 ${installed_version}：${MCP_BIN_DIR}/baize-mcp" "Upgraded Baize MCP from ${previous_version} to ${installed_version}: ${MCP_BIN_DIR}/baize-mcp"
  else
    say "已安装 Baize MCP ${installed_version}：${MCP_BIN_DIR}/baize-mcp" "Installed Baize MCP ${installed_version}: ${MCP_BIN_DIR}/baize-mcp"
  fi
}

replace_mcp_files() {
  local stage_dir="$1"
  local target_binary="${MCP_BIN_DIR}/baize-mcp"
  local target_checksum="${MCP_BIN_DIR}/baize-mcp.sha256"
  local backup_dir

  backup_dir="$(mktemp -d "${MCP_BIN_DIR}/.baize-mcp-backup.XXXXXX")" || return 1
  MCP_BACKUP_DIR="${backup_dir}"
  if [[ -e "${target_binary}" || -L "${target_binary}" ]]; then
    if ! mv -f "${target_binary}" "${backup_dir}/baize-mcp"; then
      rm -rf -- "${backup_dir}"
      MCP_BACKUP_DIR=""
      return 1
    fi
  fi
  if [[ -e "${target_checksum}" || -L "${target_checksum}" ]]; then
    if ! mv -f "${target_checksum}" "${backup_dir}/baize-mcp.sha256"; then
      [[ -e "${backup_dir}/baize-mcp" ]] && mv -f "${backup_dir}/baize-mcp" "${target_binary}"
      rm -rf -- "${backup_dir}"
      MCP_BACKUP_DIR=""
      return 1
    fi
  fi

  if ! mv -f "${stage_dir}/baize-mcp" "${target_binary}" ||
    ! mv -f "${stage_dir}/baize-mcp.sha256" "${target_checksum}"; then
    rm -f "${target_binary}" "${target_checksum}"
    [[ -e "${backup_dir}/baize-mcp" ]] && mv -f "${backup_dir}/baize-mcp" "${target_binary}"
    [[ -e "${backup_dir}/baize-mcp.sha256" ]] && mv -f "${backup_dir}/baize-mcp.sha256" "${target_checksum}"
    rm -rf -- "${backup_dir}" "${stage_dir}"
    MCP_BACKUP_DIR=""
    MCP_STAGE_DIR=""
    return 1
  fi

  rm -rf -- "${backup_dir}" "${stage_dir}"
  MCP_BACKUP_DIR=""
  MCP_STAGE_DIR=""
  return 0
}

vscode_user_dir() {
  case "$(uname -s)" in
    Darwin) printf '%s' "${USER_HOME}/Library/Application Support/Code/User" ;;
    *) printf '%s' "${USER_HOME}/.config/Code/User" ;;
  esac
}

cline_settings_dir() {
  printf '%s/globalStorage/saoudrizwan.claude-dev/settings' "$(vscode_user_dir)"
}

# DeepSeek Harness（DSH）主目录；DSH_HOME 环境变量优先。
dsh_home() {
  printf '%s' "${DSH_HOME:-${USER_HOME}/.dsh}"
}

# DSH 的用户插件层：home 级 cordis.patch.yml 对本机所有 profile 生效。
dsh_patch_file() {
  printf '%s/cordis.patch.yml' "$(dsh_home)"
}

client_config_file() {
  case "$1" in
    zcode) printf '%s' "${USER_HOME}/.zcode/cli/config.json" ;;
    gemini) printf '%s' "${USER_HOME}/.gemini/settings.json" ;;
    qwen) printf '%s' "${USER_HOME}/.qwen/settings.json" ;;
    cursor) printf '%s' "${USER_HOME}/.cursor/mcp.json" ;;
    windsurf) printf '%s' "${USER_HOME}/.codeium/windsurf/mcp_config.json" ;;
    vscode) printf '%s' "$(vscode_user_dir)/mcp.json" ;;
    cline) printf '%s' "$(cline_settings_dir)/cline_mcp_settings.json" ;;
    trae) printf '%s' "${USER_HOME}/.trae/mcp.json" ;;
  esac
}

client_config_shape() {
  case "$1" in
    zcode) printf 'zcode' ;;
    vscode) printf 'vscode' ;;
    *) printf 'mcpServers' ;;
  esac
}

client_detected() {
  case "$1" in
    codex) [[ -d "${CODEX_HOME:-${USER_HOME}/.codex}" ]] || command -v codex >/dev/null 2>&1 ;;
    claude) [[ -d "${USER_HOME}/.claude" ]] || command -v claude >/dev/null 2>&1 ;;
    zcode) [[ -d "${USER_HOME}/.zcode" ]] || command -v zcode >/dev/null 2>&1 ;;
    gemini) [[ -d "${USER_HOME}/.gemini" ]] || command -v gemini >/dev/null 2>&1 ;;
    qwen) [[ -d "${USER_HOME}/.qwen" ]] || command -v qwen >/dev/null 2>&1 ;;
    cursor) [[ -d "${USER_HOME}/.cursor" ]] ;;
    windsurf) [[ -d "${USER_HOME}/.codeium/windsurf" ]] ;;
    vscode) [[ -d "$(vscode_user_dir)" ]] ;;
    cline) [[ -d "$(cline_settings_dir)" ]] ;;
    trae) [[ -d "${USER_HOME}/.trae" ]] ;;
    dsh) [[ -d "$(dsh_home)" ]] || command -v dsh >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

resolve_targets() {
  TARGET_CLIENTS=""
  local client
  if [[ "${CLIENT}" == "manual" ]]; then
    return 0
  fi
  if [[ "${CLIENT}" != "auto" ]]; then
    if client_detected "${CLIENT}"; then
      TARGET_CLIENTS="${CLIENT}"
    fi
    return 0
  fi
  for client in ${CLIENT_ORDER}; do
    if client_detected "${client}"; then
      TARGET_CLIENTS="${TARGET_CLIENTS:+${TARGET_CLIENTS} }${client}"
    fi
  done
}

mcp_file_upsert() {
  local config_file="$1" shape="$2" binary="$3"
  python3 - "${config_file}" "${shape}" "${binary}" <<'PY'
import json
import os
import sys
import tempfile

config_file, shape, binary = sys.argv[1], sys.argv[2], sys.argv[3]
args = ["serve", "--profile", "default"]

try:
    with open(config_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except (ValueError, OSError):
    print("parse-error")
    sys.exit(2)


def ensure_object(container, key):
    value = container.get(key)
    if not isinstance(value, dict):
        container[key] = {}
    return container[key]


if shape == "zcode":
    servers = ensure_object(ensure_object(data, "mcp"), "servers")
    entry = {"type": "stdio", "command": binary, "args": args}
elif shape == "vscode":
    servers = ensure_object(data, "servers")
    entry = {"type": "stdio", "command": binary, "args": args}
else:
    servers = ensure_object(data, "mcpServers")
    entry = {"command": binary, "args": args}

if servers.get("baize") == entry:
    print("unchanged")
    sys.exit(0)

servers["baize"] = entry
try:
    os.makedirs(os.path.dirname(config_file), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(config_file), prefix=".baize-mcp-", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp_path, config_file)
except OSError:
    sys.exit(1)
print("updated")
PY
}

# DSH 使用 YAML 插件层（home 级 cordis.patch.yml）注册 MCP，而不是 JSON mcpServers。
# 已存在的 mcp-baize 行只在命令路径变化时原地更新，其余用户配置保持不变。
dsh_patch_upsert() {
  local patch_file="$1" binary="$2"
  python3 - "${patch_file}" "${binary}" <<'PY'
import os
import sys
import tempfile

patch_file, binary = sys.argv[1], sys.argv[2]
id_line = "    - id: mcp-baize"
escaped = binary.replace("'", "''")
block = (
    "# Baize MCP: register the local baize-mcp server for DeepSeek Harness (DSH);\n"
    "# tools appear as mcp__baize__<tool>. This file holds no Baize address or credential.\n"
    "- insert:\n"
    "    - id: mcp-baize\n"
    "      name: '@deepseek-ai/dsh-mcp-client'\n"
    "      config:\n"
    "        serverName: baize\n"
    "        transport: stdio\n"
    "        command: '{}'\n"
    "        args: [serve, --profile, default]\n".format(escaped)
)

try:
    with open(patch_file, "r", encoding="utf-8") as fh:
        content = fh.read()
except FileNotFoundError:
    content = ""

if id_line in content:
    lines = content.splitlines(keepends=True)
    for idx, line in enumerate(lines):
        if line.rstrip("\n") != id_line:
            continue
        end = idx + 1
        while end < len(lines):
            cur = lines[end].rstrip("\n")
            if cur.strip() == "" or len(cur) - len(cur.lstrip(" ")) >= 6:
                end += 1
            else:
                break
        cmd_idx = None
        for k in range(idx, end):
            if lines[k].rstrip("\n").startswith("        command:"):
                cmd_idx = k
                break
        if cmd_idx is None:
            print("parse-error")
            sys.exit(2)
        current = lines[cmd_idx].rstrip("\r\n")
        if current == "        command: '{}'".format(escaped):
            print("unchanged")
            sys.exit(0)
        eol = "\r\n" if lines[cmd_idx].endswith("\r\n") else "\n"
        lines[cmd_idx] = "        command: '{}'{}".format(escaped, eol)
        content = "".join(lines)
        break
    else:
        print("parse-error")
        sys.exit(2)
else:
    if content and not content.endswith("\n"):
        content += "\n"
    if content.strip():
        content += "\n"
    content += block

os.makedirs(os.path.dirname(os.path.abspath(patch_file)), exist_ok=True)
fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(patch_file)), prefix=".baize-dsh-", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(content)
os.replace(tmp_path, patch_file)
print("updated")
PY
}

cli_client_list_output() {
  case "$1" in
    codex) codex mcp list 2>/dev/null || true ;;
    claude) claude mcp list 2>/dev/null || true ;;
  esac
}

register_cli_client() {
  local client="$1" binary="$2" list_output configured_output
  list_output="$(cli_client_list_output "${client}")"
  case "${client}" in
    codex)
      configured_output="$(codex mcp get baize 2>/dev/null || true)"
      if [[ "${list_output}" =~ (^|[[:space:]])baize([[:space:]]|$) && "${configured_output}" == *"command: ${binary}"* ]]; then
        return 0
      fi
      if [[ "${list_output}" =~ (^|[[:space:]])baize([[:space:]]|$) ]]; then
        codex mcp remove baize >/dev/null 2>&1 || true
      fi
      codex mcp add baize -- "${binary}" serve --profile default >/dev/null 2>&1
      ;;
    claude)
      if [[ "${list_output}" =~ (^|[[:space:]])baize: && "${list_output}" == *"${binary}"* ]]; then
        return 0
      fi
      if [[ "${list_output}" =~ (^|[[:space:]])baize: ]]; then
        claude mcp remove baize >/dev/null 2>&1 || true
      fi
      claude mcp add -s user baize -- "${binary}" serve --profile default >/dev/null 2>&1
      ;;
  esac
}

skill_dirs_for_targets() {
  local dirs="" client dir
  if [[ -n "${SKILL_DIR}" ]]; then
    printf '%s\n' "${SKILL_DIR}"
    return 0
  fi
  for client in ${TARGET_CLIENTS}; do
    case "${client}" in
      codex) dir="${CODEX_HOME:-${USER_HOME}/.codex}/skills/baize-ai" ;;
      claude) dir="${USER_HOME}/.claude/skills/baize-ai" ;;
      zcode) dir="${USER_HOME}/.zcode/skills/baize-ai" ;;
      dsh) dir="$(dsh_home)/skills/baize-ai" ;;
      *) continue ;;
    esac
    case " ${dirs} " in
      *" ${dir} "*) ;;
      *) dirs="${dirs:+${dirs} }${dir}" ;;
    esac
  done
  if [[ -z "${dirs}" ]]; then
    dirs="${USER_HOME}/.baize/skills/baize-ai"
  fi
  printf '%s\n' "${dirs}" | tr ' ' '\n'
}

install_skill() {
  local skill_dir
  [[ -f "${SKILL_SOURCE_DIR}/SKILL.md" && -f "${SKILL_SOURCE_DIR}/agents/openai.yaml" ]] || die "当前 Baize 副本缺少 baize-ai Skill"
  while IFS= read -r skill_dir; do
    [[ -n "${skill_dir}" ]] || continue
    mkdir -p "${skill_dir}/agents"
    install -m 0644 "${SKILL_SOURCE_DIR}/SKILL.md" "${skill_dir}/SKILL.md"
    install -m 0644 "${SKILL_SOURCE_DIR}/agents/openai.yaml" "${skill_dir}/agents/openai.yaml"
    say "已安装 Baize Skill：${skill_dir}" "Installed Baize Skill: ${skill_dir}"
  done < <(skill_dirs_for_targets)
}

print_manual_config() {
  local binary="$1"
  say "请将下面的 MCP 配置添加到 AI 客户端（不包含白泽地址或凭据）：" "Add this MCP configuration to your AI client (it contains no Baize address or credential):"
  python3 - "${binary}" <<'PY'
import json
import sys

print(json.dumps({"mcpServers": {"baize": {"command": sys.argv[1], "args": ["serve", "--profile", "default"]}}}, indent=2))
PY
}

register_clients() {
  local binary="${MCP_BIN_DIR}/baize-mcp" client config_file upsert_result
  local registered_clients="" failed_clients=""
  if [[ "${SKIP_MCP}" != 0 ]]; then
    return 0
  fi
  [[ -x "${binary}" ]] || return 0
  if [[ "${CLIENT}" != "manual" && "${CLIENT}" != "auto" && -z "${TARGET_CLIENTS}" ]]; then
    say "未检测到 ${CLIENT}，已跳过自动注册。" "${CLIENT} was not detected; automatic registration was skipped."
    print_manual_config "${binary}"
    return 0
  fi
  for client in ${TARGET_CLIENTS}; do
    case "${client}" in
      codex|claude)
        if command -v "${client}" >/dev/null 2>&1; then
          if register_cli_client "${client}" "${binary}"; then
            say "已将 Baize MCP 注册到 ${client}。" "Registered Baize MCP with ${client}."
            registered_clients="${registered_clients:+${registered_clients} }${client}"
          else
            failed_clients="${failed_clients:+${failed_clients} }${client}"
          fi
        else
          failed_clients="${failed_clients:+${failed_clients} }${client}"
        fi
        ;;
      gemini|qwen|zcode|cursor|windsurf|vscode|cline|trae)
        config_file="$(client_config_file "${client}")"
        if upsert_result="$(mcp_file_upsert "${config_file}" "$(client_config_shape "${client}")" "${binary}")"; then
          if [[ "${upsert_result}" == "unchanged" ]]; then
            say "${client} 中已存在一致的 Baize MCP 配置。" "Baize MCP is already configured in ${client}."
          else
            say "已将 Baize MCP 注册到 ${client}（${config_file}）。" "Registered Baize MCP with ${client} (${config_file})."
          fi
          registered_clients="${registered_clients:+${registered_clients} }${client}"
        else
          failed_clients="${failed_clients:+${failed_clients} }${client}"
        fi
        ;;
      dsh)
        config_file="$(dsh_patch_file)"
        if upsert_result="$(dsh_patch_upsert "${config_file}" "${binary}")"; then
          if [[ "${upsert_result}" == "unchanged" ]]; then
            say "dsh 中已存在一致的 Baize MCP 配置。" "Baize MCP is already configured in dsh."
          else
            say "已将 Baize MCP 注册到 dsh（${config_file}）。" "Registered Baize MCP with dsh (${config_file})."
          fi
          registered_clients="${registered_clients:+${registered_clients} }${client}"
        else
          failed_clients="${failed_clients:+${failed_clients} }${client}"
        fi
        ;;
    esac
  done
  if [[ -n "${failed_clients}" ]]; then
    say "未能自动注册到 ${failed_clients}（客户端命令不可用、配置无法解析或写入失败）。下面给出手动配置；它不包含白泽地址或凭据。" "Automatic registration failed for ${failed_clients} (client command unavailable, configuration unreadable, or write failed). Use the manual configuration below; it contains no Baize address or credential."
    print_manual_config "${binary}"
  elif [[ -z "${registered_clients}" && "${CLIENT}" != "manual" ]]; then
    print_manual_config "${binary}"
  fi
}

say "这不是白泽产品安装器，只安装 AI 接入组件（MCP 与 Skill）。" "This is not the Baize product installer; it installs only the AI access components (MCP and Skill)."
resolve_targets
[[ "${SKIP_MCP}" == 1 ]] || install_mcp
[[ "${SKIP_SKILL}" == 1 ]] || install_skill
register_clients
if [[ "${SKIP_MCP}" == 0 ]]; then
  say "下一步：运行 ${MCP_BIN_DIR}/baize-mcp login 登录你的白泽实例，再重新打开 AI 客户端。" "Next: run ${MCP_BIN_DIR}/baize-mcp login for your Baize instance, then restart your AI client."
else
  say "已跳过 MCP 安装；请确认现有 Baize MCP 已登录并已在 AI 客户端中启用。" "MCP installation was skipped; make sure your existing Baize MCP is signed in and enabled in the AI client."
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIET=0
MESSAGE_FILES=()
COMMIT_IDS=()

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/check-public-copy.sh [--quiet] [--message-file <path>] [--commit <sha>]

说明:
  检查白泽当前目录中已有和新建的对外文案、版本清单、安装提示和配置样例，
  避免发布内部仓名、内部路径、内部协作语气、治理术语等对外不应出现的内容。
  传入 --message-file 或 --commit 时，会额外检查提交摘要是否只描述用户可感知的变化。
  --quiet 只输出硬性检查结果，不展示两性词复核清单。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)
      QUIET=1
      shift
      ;;
    --message-file)
      [[ -n "${2:-}" ]] || { echo "[check-public-copy] ERROR: --message-file 不能为空" >&2; exit 1; }
      MESSAGE_FILES+=("$2")
      shift 2
      ;;
    --commit)
      [[ -n "${2:-}" ]] || { echo "[check-public-copy] ERROR: --commit 不能为空" >&2; exit 1; }
      COMMIT_IDS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[check-public-copy] ERROR: 未知参数: $1" >&2
      exit 1
      ;;
  esac
done

should_check_file() {
  local file="$1"
  case "$file" in
    scripts/check-public-copy.sh) return 1 ;;
    assets/*|agent/dist/*|server/dist/*|web/dist/*|.git/*) return 1 ;;
  esac
  case "$file" in
    README.md|README.en.md|LICENSE|*.md|*.json|*.env|*.example|*.sh|*.ps1|*.yml|*.yaml|*.template|*.conf|*.txt|Dockerfile) return 0 ;;
    *) return 1 ;;
  esac
}

collect_files() {
  if [[ -d "$ROOT_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
    git -C "$ROOT_DIR" ls-files --cached --others --exclude-standard
  else
    find "$ROOT_DIR" -type f \
      ! -path "$ROOT_DIR/.git/*" \
      ! -path "$ROOT_DIR/assets/*" \
      ! -path "$ROOT_DIR/agent/dist/*" \
      ! -path "$ROOT_DIR/server/dist/*" \
      ! -path "$ROOT_DIR/web/dist/*" \
      | sed "s#^$ROOT_DIR/##"
  fi
}

hard_rule_names=(
  "内部仓库名"
  "内部发布脚本路径"
  "内部服务器路径"
  "契约真相源或内部生成口径"
  "内部协作或排障口吻"
  "内部工程分层黑话"
  "内部 Skill 或治理配置"
  "内部执行实现"
  "仓库身份或内部治理术语"
)

hard_rule_patterns=(
  "baize-server-panl|baizepanl-web|baizepanl-shared|baizepanl-app|baize-official-[[:alnum:]_-]+"
  "scripts/release/|ai-build-entry[.]sh|build-agent-dist[.]sh|build-local-bundle[.]sh"
  "/opt/baize/baize-server-panl|/www/wwwroot|/root/baize|/root/Develop"
  "契约真相源|OpenAPI[[:space:]]*真相源|Protobuf[[:space:]]*真相源|shared[[:space:]]*契约|API[[:space:]]*工厂|字段映射策略"
  "联调|临时联调|metadata[.]deploy|ProtectSystem|traceId|nextActionKey"
  "handler[[:space:]]*/[[:space:]]*service|service[[:space:]]*/[[:space:]]*repository|repository[[:space:]]+层|repository[[:space:]]+layer|goroutine|数据库迁移|反向迁移"
  "project[.]yaml|repo-map[.]yaml|commands[.]yaml|AGENTS[.]md|[.]spec-init/|[.]spec-runtime/"
  "CommandPlan|ExecTask|sensor_runner|development_post_check|validate_skills"
  "公开仓([库])?|公开部署仓|真相源|门禁|工作区|跨项目|发布依赖"
)

commit_rule_names=(
  "仓库视角用语"
  "内部治理用语"
  "具体校验命令或脚本信息"
)

commit_rule_patterns=(
  "公开仓([库])?|公开部署仓|public[[:space:]]+(repo|repository)|对外发布(内容)?|产品视角|本仓([库])?"
  "真相源|门禁|工作区|跨项目|发布依赖|原生验证|增量(检查|校验|门禁)|内部(检查|流程|规则)|验证命令|检查命令|校验命令|脚本信息"
  "scripts/[A-Za-z0-9_./-]+|((bash|python3?|git)[[:space:]]+(-[A-Za-z0-9-]+[[:space:]]+)*(scripts/|diff([[:space:]]|$)|status([[:space:]]|$)|log([[:space:]]|$)|show([[:space:]]|$)))|(docker[[:space:]]+compose)|check-public-copy|validate[_-][A-Za-z0-9_-]+|sensor_runner|task_done|(^|[^[:alnum:]_])(commit|branch)([^[:alnum:]_]|$)|<type>\(|说明用户遇到的情况|说明使用体验如何改善|概括覆盖的使用场景和结果"
)

review_patterns=(
  "Agent"
  "API"
  "Server"
  "Token"
  "Webhook"
  "UUID"
  "TTL"
  "capability"
  "接口"
  "commit"
  "branch"
)

violations=()
review_hits=()

validate_commit_text() {
  local source="$1"
  local text="$2"
  local normalized match pattern index
  normalized="$(printf '%s\n' "$text" | sed '/^[[:space:]]*#/d')"
  if [[ -z "$(printf '%s' "$normalized" | tr -d '[:space:]')" ]]; then
    violations+=("$source:提交信息为空 [提交摘要]")
    return
  fi

  for index in "${!commit_rule_patterns[@]}"; do
    pattern="${commit_rule_patterns[$index]}"
    if match="$(printf '%s\n' "$normalized" | grep -nE "$pattern" | head -n 1 || true)"; [[ -n "$match" ]]; then
      violations+=("$source:$match [${commit_rule_names[$index]}]")
    fi
  done

  if [[ "$normalized" != *优化* && "$normalized" != *修复* && "$normalized" != *增强* && "$normalized" != *改进* && "$normalized" != *提升* && "$normalized" != *安装* && "$normalized" != *升级* && "$normalized" != *体验* && "$normalized" != *稳定* && "$normalized" != *安全* && "$normalized" != *用户* ]]; then
    violations+=("$source:缺少用户可感知的变化描述 [产品化表达]")
  fi
}

while IFS= read -r file; do
  should_check_file "$file" || continue
  path="$ROOT_DIR/$file"
  [[ -f "$path" ]] || continue

  for index in "${!hard_rule_patterns[@]}"; do
    pattern="${hard_rule_patterns[$index]}"
    if match="$(grep -nE "$pattern" "$path" | head -n 1 || true)"; [[ -n "$match" ]]; then
      violations+=("$file:$match [${hard_rule_names[$index]}]")
    fi
  done

  for pattern in "${review_patterns[@]}"; do
    if match="$(grep -nE "$pattern" "$path" | head -n 1 || true)"; [[ -n "$match" ]]; then
      review_hits+=("$file:$match [$pattern]")
    fi
  done
done < <(collect_files)

for message_file in "${MESSAGE_FILES[@]}"; do
  if [[ ! -f "$message_file" ]]; then
    violations+=("$message_file:文件不存在 [提交摘要]")
    continue
  fi
  validate_commit_text "$message_file" "$(<"$message_file")"
done

for commit in "${COMMIT_IDS[@]}"; do
  if ! message="$(git -C "$ROOT_DIR" log -1 --format=%B "$commit" 2>/dev/null)"; then
    violations+=("commit:$commit:无法读取提交信息 [提交摘要]")
    continue
  fi
  validate_commit_text "commit:$commit" "$message"
done

if (( ${#violations[@]} > 0 )); then
  echo "公开内容检查失败：发现内部语义、内部路径或内部协作口吻残留。" >&2
  printf '%s\n' "${violations[@]}" >&2
  exit 1
fi

echo "公开内容硬性检查通过：未发现内部仓名、内部路径、真相源/迁移/联调等禁止内容。"

if (( QUIET == 0 && ${#review_hits[@]} > 0 )); then
  echo "两性词语义复核提示：发现 ${#review_hits[@]} 处 Agent/API/Server/Token/commit 等词，请 AI 在提交前按公开部署场景复核。"
  limit=20
  count=0
  for hit in "${review_hits[@]}"; do
    (( count >= limit )) && break
    echo "- $hit"
    count=$((count + 1))
  done
  if (( ${#review_hits[@]} > limit )); then
    echo "- 其余 $((${#review_hits[@]} - limit)) 处略。"
  fi
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIET=0

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/check-public-copy.sh [--quiet]

说明:
  检查公开部署仓中的 README、版本清单、脚本提示和配置样例，避免发布内部仓名、
  内部脚本路径、内部协作语气、真相源/迁移等对外不应出现的内容。
  --quiet 只输出硬性检查结果，不展示两性词复核清单。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)
      QUIET=1
      shift
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
    README.md|README.en.md|LICENSE|*.md|*.json|*.env|*.example|*.sh|*.yml|*.yaml|*.template|*.conf|*.txt|Dockerfile) return 0 ;;
    *) return 1 ;;
  esac
}

collect_files() {
  if [[ -d "$ROOT_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
    git -C "$ROOT_DIR" ls-files
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
)

hard_rule_patterns=(
  "baize-server-panl|baizepanl-web|baizepanl-shared|baizepanl-app|baize-official-[[:alnum:]_-]+"
  "scripts/release/|ai-build-entry[.]sh|build-agent-dist[.]sh|build-local-bundle[.]sh"
  "/opt/baize/baize-server-panl|/www/wwwroot|/root/baize|/root/Develop"
  "契约真相源|OpenAPI[[:space:]]*真相源|Protobuf[[:space:]]*真相源|shared[[:space:]]*契约|API[[:space:]]*工厂|字段映射策略"
  "联调|临时联调|metadata[.]deploy|ProtectSystem|traceId|nextActionKey"
  "handler[[:space:]]*/[[:space:]]*service|service[[:space:]]*/[[:space:]]*repository|repository[[:space:]]+层|repository[[:space:]]+layer|goroutine|数据库迁移|反向迁移"
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

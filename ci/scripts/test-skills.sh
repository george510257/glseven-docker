#!/usr/bin/env bash
# 校验 skills/ 包的格式、关键事实与凭据泄漏。无 Docker 依赖，兼容 macOS Bash 3.2。
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

[[ -d skills ]] || fail "skills/ 不存在"

check_skill_frontmatter() {
  local dir="$1" file="$2" name desc keys
  [[ -f "$file" ]] || fail "缺少 $file"
  head -n 1 "$file" | grep -qx -- '---' || fail "$file 首行必须是 ---"
  name="$(awk 'NR==1{next} /^---$/{exit} /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$file")"
  desc="$(awk 'NR==1{next} /^---$/{exit} /^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$file")"
  [[ -n "$name" ]] || fail "$file 缺少 name"
  [[ -n "$desc" ]] || fail "$file 缺少 description"
  [[ "$(basename "$dir")" == "$name" ]] || fail "$file name ($name) 与目录名不一致"
  printf '%s' "$name" | grep -Eq '^[a-z0-9-]+$' || fail "$name 不符合 ^[a-z0-9-]+$"
  keys="$(awk 'NR==1{next} /^---$/{exit} /^[A-Za-z0-9_-]+:/{sub(/:.*/, ""); print}' "$file" | sort -u | tr '\n' ' ')"
  [[ "$keys" == "description name " ]] || fail "$file frontmatter 只允许 name/description，实际: $keys"
}

check_skill_frontmatter skills/glseven-env skills/glseven-env/SKILL.md
pass "glseven-env frontmatter"

for f in endpoints.md connect-recipes.md troubleshooting.md; do
  [[ -f "skills/glseven-env/references/$f" ]] || fail "缺少 skills/glseven-env/references/$f"
done

grep -q '29092' skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未写 Kafka 宿主 29092"
grep -q 'NACOS_USERNAME' skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未写 NACOS_USERNAME"
grep -q 'REDIS_PASSWORD' skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未写 REDIS_PASSWORD"

# 凭据泄漏：从仓库现有文件动态取值，不在测试里硬编码
for secret in \
  "$(grep -h '^REDIS_PASSWORD=' .env.local.example .env.sit.example 2>/dev/null | head -n 1 | cut -d= -f2-)" \
  "$(grep -h '^NACOS_AUTH_TOKEN=' platform/env/nacos.env 2>/dev/null | head -n 1 | cut -d= -f2-)" \
  "$(grep -h '^NACOS_AUTH_IDENTITY_VALUE=' platform/env/nacos.env 2>/dev/null | head -n 1 | cut -d= -f2-)"; do
  [[ -n "$secret" ]] || continue
  if grep -R -F -q -- "$secret" skills; then
    fail "skills/ 中出现真实凭据：$secret"
  fi
done
pass "skills/ 无已知凭据"

pass "test-skills: 通过"

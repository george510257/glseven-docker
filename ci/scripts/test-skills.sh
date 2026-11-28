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

check_skill_frontmatter skills/glseven-deploy skills/glseven-deploy/SKILL.md
pass "glseven-deploy frontmatter"

for f in Dockerfile.java Dockerfile.web nginx.web.conf docker-compose.project.yml portal-project.conf gitlab-ci.project.yml env.project.example; do
  [[ -f "skills/glseven-deploy/references/templates/$f" ]] || fail "缺少模板 skills/glseven-deploy/references/templates/$f"
done

grep -q 'linux/amd64' skills/glseven-deploy/references/deploy-flow.md || fail "deploy-flow 未写 linux/amd64"
grep -q '<project>-<service>' skills/glseven-deploy/references/templates/docker-compose.project.yml || fail "compose 模板未使用 <project>-<service> 命名"
grep -q 'athena-web:80' skills/glseven-deploy/references/athena.md || fail "athena 示例未写 athena-web:80"
grep -q 'docker-hosted/athena-' skills/glseven-deploy/references/athena.md || fail "athena 示例未写单段镜像名"
if grep -Eq '^[[:space:]]*ports:' skills/glseven-deploy/references/templates/docker-compose.project.yml; then
  fail "compose 模板不得发布宿主端口"
fi

# 结构断言：compose 服务键必须带项目前缀，且不得出现无前缀服务名
grep -Eq '^  <project>-[a-z0-9-]+:' skills/glseven-deploy/references/templates/docker-compose.project.yml || fail "compose 模板缺少 <project>-<service> 服务键"
if grep -Eq '^  (auth|web|gateway|system|codegen):' skills/glseven-deploy/references/templates/docker-compose.project.yml; then
  fail "compose 模板出现无前缀服务名"
fi

# amd64 必须在 buildx 命令行里
grep -Eq 'docker buildx build [^#]*--platform linux/amd64' skills/glseven-deploy/references/deploy-flow.md || fail "deploy-flow 的 buildx 命令未带 --platform linux/amd64"

# 网关服务地址与 Nacos 客户端凭据必须成对出现
for v in SYSTEM_SERVICE_URI CODEGEN_SERVICE_URI AUTH_SERVICE_URI SPRING_CLOUD_NACOS_USERNAME SPRING_CLOUD_NACOS_PASSWORD; do
  grep -q "$v" skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未写 $v"
done

# issuer 两个变量用途不同
grep -q 'AUTH_ISSUER=http://athena.glseven.local:8080' skills/glseven-env/references/connect-recipes.md || fail "AUTH_ISSUER 未使用对外地址"
grep -q 'AUTH_ISSUER_URI=http://athena-auth:8080' skills/glseven-env/references/connect-recipes.md || fail "AUTH_ISSUER_URI 未使用服务地址"

# qiankun 生产入口与 portal 构建
grep -q '/micro/sub-auth/' skills/glseven-deploy/references/templates/nginx.web.conf || fail "nginx.web.conf 缺少 /micro/sub-* 入口"
grep -q 'dist-portal' skills/glseven-deploy/references/athena.md || fail "athena.md 未说明 dist-portal"
grep -q 'db/migration' skills/glseven-deploy/references/athena.md || fail "athena.md 未说明 Flyway 迁移"
if grep -q 'doc/athena-codegen.sql' skills/glseven-deploy/references/athena.md; then
  fail "athena.md 仍引用不存在的 doc/athena-codegen.sql"
fi

# extra_hosts 与 web 探针
grep -q '172.18.6.1' skills/glseven-deploy/references/templates/docker-compose.project.yml || fail "compose 模板缺少 extra_hosts 指向 portal"
grep -q 'wget -q -O /dev/null http://127.0.0.1/' skills/glseven-deploy/references/templates/docker-compose.project.yml || fail "compose 模板 web 探针未使用 wget"

# 密码/令牌不得通过命令行
if grep -R -n -E 'redis-cli .* -a |mvn .*-Dgh\.token' skills; then
  fail "skills 中出现通过命令行传密码/令牌的示例"
fi
grep -q 'REDISCLI_AUTH' skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未使用 REDISCLI_AUTH"

# 每个 skills/*/SKILL.md 都要校验 frontmatter
for d in skills/*/; do
  check_skill_frontmatter "${d%/}" "${d}SKILL.md"
done

pass "test-skills: 通过"

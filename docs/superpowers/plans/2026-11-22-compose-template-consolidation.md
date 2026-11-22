# Compose 公共模板收敛（批次 2）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 `common/base-service.yml` + 每文件锚点把七域 compose 的 `restart`、`common.env`、标准 healthcheck 时间参数收敛为单点维护，并用 CI 断言防止回退。

**Architecture:** 三层 `extends` 模板（`service-base` / `service-common` / `service-healthy`）承载公共字段；各域 compose 顶部定义 `x-` 锚点，服务里只写 `extends: *healthy` 等一行。风格测试 `ci/scripts/test-compose-style.sh` 按域增量纳入检查，保证每个中间提交都是绿的。

**Tech Stack:** Bash 3.2、Docker Compose v2（`extends` / YAML 锚点）、GitLab CI、nginx、Markdown。

**Spec:** docs/superpowers/specs/2026-11-22-compose-template-consolidation-design.md

## Global Constraints

- 不改任何服务的 image / ports / networks / volumes 语义 / healthcheck 命令与实际时间参数；唯一允许的 compose 语义变更是公共字段改为 `extends` 继承。
- 保持 `container_name == hostname`；保持固定 IP、`env_file` 服务项、`depends_on`、`:ro` 挂载。
- 所有脚本兼容 macOS 自带 Bash 3.2：不用 `mapfile`、关联数组、`${var,,}`、`&>>`。
- 新测试用 `set -euo pipefail`，放在 `ci/scripts/test-*.sh`（`ci/validate.sh` 自动执行）。
- `common/base-service.yml` 不得被 `*/docker-compose.yml` 通配命中。
- 所有命令在 worktree `/Users/george/project/glseven/glseven-docker/.claude/worktrees/project-config-service-reuse-71639c` 下执行。
- 本机没有 Docker CLI；`docker compose config` 与运行时等价性由 CI / 有 Docker 的机器覆盖，最终报告必须明示该缺口。

## Review Focus

- **渲染等价性**：改造后每个服务的 `env_file` 仍解析到 `common/env/common.env`，标准 healthcheck 仍是 10s/5s/10/30s；Task 6 的 CI `compose config` + Docker 主机基线比较覆盖。
- **gitlab / gitlab-runner 不新增 TZ**：二者必须用 `*base` 而非 `*healthy`；Task 4 的白名单断言覆盖。
- **portainer 不获得非法 healthcheck**：必须用 `*common`（有 `common.env`、无 `test`）；Task 3 的白名单断言覆盖。
- **既有解析器不破**：`check-consistency.sh`、`preflight.sh`、`test-devops-domain.sh` 仍能提取服务；Task 6 的对应测试覆盖。
- **新服务不能绕过模板**：缺 `extends` 或选错模板必须被 CI 阻断；Task 1/2 的风格测试覆盖。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `common/base-service.yml` | 三层公共模板；唯一公共字段数据源 |
| `ci/scripts/test-compose-style.sh` | 模板使用、锚点、key 顺序、test 格式、header 的断言 |
| `infra/docker-compose.yml` | 8 个服务改 `*healthy` |
| `observability/docker-compose.yml` | 4 个服务改 `*healthy`（filebeat 保留自定义时间） |
| `security/docker-compose.yml` | 3 个服务改 `*healthy`（keycloak 保留自定义时间） |
| `platform/docker-compose.yml` | 4 个 `*healthy` + portainer `*common` |
| `apps/docker-compose.yml` | 4 个 `*healthy`（ollama/iptv 保留自定义时间） |
| `portal/docker-compose.yml` | nginx `*healthy` |
| `devops/docker-compose.yml` | gitlab / gitlab-runner `*base` |
| `CLAUDE.md` / `AGENTS.md` / `README.md` | 模板说明、校验命令、新增服务步骤 |

---

### Task 1: 模板基座与风格测试骨架

**Files:**
- Create: `common/base-service.yml`
- Create: `ci/scripts/test-compose-style.sh`

**Interfaces:**
- Consumes: 无
- Produces: `service-base` / `service-common` / `service-healthy` 三个可被 `extends` 引用的服务；测试脚本的 `DOMAINS` 数组（Task 2–4 逐步追加）

- [ ] **Step 1: 写失败测试**

创建 `ci/scripts/test-compose-style.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/common/base-service.yml"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Task 2-4 逐步追加已转换的域，保证每个中间提交都是绿的。
DOMAINS=()

check_base() {
  [ -f "$BASE" ] || fail "缺少 common/base-service.yml"
  grep -q '^  service-base:$' "$BASE" || fail "base 缺少 service-base"
  grep -q '^  service-common:$' "$BASE" || fail "base 缺少 service-common"
  grep -q '^  service-healthy:$' "$BASE" || fail "base 缺少 service-healthy"
  grep -A2 '^  service-common:$' "$BASE" | grep -q 'extends: service-base' ||
    fail "service-common 必须继承 service-base"
  grep -A2 '^  service-healthy:$' "$BASE" | grep -q 'extends: service-common' ||
    fail "service-healthy 必须继承 service-common"
  grep -A2 '^  service-base:$' "$BASE" | grep -q 'restart: always' ||
    fail "service-base 必须提供 restart: always"
  grep -A4 '^  service-common:$' "$BASE" | grep -q 'env/common.env' ||
    fail "service-common 必须提供 env/common.env"
  for key in 'interval: 10s' 'timeout: 5s' 'retries: 10' 'start_period: 30s'; do
    grep -q "^      $key$" "$BASE" || fail "service-healthy 缺少 $key"
  done
}

check_header() {
  local file="$1" domain="$2" header
  header=$(grep -E '^# [A-Z][A-Za-z]+ 172\.18\.[1-7]\.x =+$' "$file" | head -1 || true)
  [ -n "$header" ] || fail "$domain: 域名标题注释格式不正确"
  [ "${#header}" -eq 100 ] || fail "$domain: 域名标题注释应为 100 列（当前 ${#header}）"
}

check_services() {
  local file="$1" domain="$2" svc ext ref name line
  ! grep -q '^    restart:' "$file" || fail "$domain: 不应再出现 restart:"
  ! grep -q 'common/env/common.env' "$file" || fail "$domain: 不应再引用 common.env"

  for ref in $(grep -hoE '^[[:space:]]+extends: \*[a-z-]+' "$file" | awk '{print $2}' | sort -u || true); do
    name="${ref#\*}"
    grep -q "^x-${name}: &${name}$" "$file" ||
      fail "$domain: 使用了未定义的锚点 $ref"
    grep -A2 "^x-${name}: &${name}$" "$file" | grep -q 'file: ../common/base-service.yml' ||
      fail "$domain: 锚点 $ref 未指向 common/base-service.yml"
    grep -A2 "^x-${name}: &${name}$" "$file" | grep -q "service: service-${name}" ||
      fail "$domain: 锚点 $ref 的 service 必须是 service-${name}"
  done

  while IFS= read -r line; do
    [ -z "$line" ] || fail "${line#FAIL: }"
  done < <(awk -v domain="$domain" '
    function flush() {
      if (svc == "") return
      if (ext == "") print "FAIL: " domain ": " svc " 缺少 extends"
      if (cn == "" || hn == "") print "FAIL: " domain ": " svc " 缺少 container_name/hostname"
      else if (cn != hn) print "FAIL: " domain ": " svc " container_name 与 hostname 不一致"
      if (hc && !test) print "FAIL: " domain ": " svc " healthcheck 缺少 test"
      if (test && test !~ /\["(CMD|CMD-SHELL|NONE)"/)
        print "FAIL: " domain ": " svc " test 数组格式不符合规范"
      svc = ""; ext = ""; cn = ""; hn = ""; hc = 0; test = ""
    }
    /^  [a-z0-9-]+:$/ { flush(); svc = $1; sub(/:$/, "", svc); first = 1; next }
    /^    [a-z_]+:/ && first {
      if ($1 != "extends:") print "FAIL: " domain ": " svc " 首字段必须是 extends"
      first = 0
    }
    /^    extends:/ { ext = $2; next }
    /^    container_name:/ { cn = $2; next }
    /^    hostname:/ { hn = $2; next }
    /^    healthcheck:/ { hc = 1; next }
    /^      test:/ { test = $0; next }
    END { flush() }
  ' "$file")

  for svc in $(awk '/^  [a-z0-9-]+:$/ { n=$1; sub(/:$/, "", n); print n }' "$file"); do
    ext=$(awk -v s="$svc" '
      $0 == "  " s ":" { in_svc = 1; next }
      in_svc && /^  [a-z0-9-]+:$/ { exit }
      in_svc && /^    extends:/ { print $2; exit }
    ' "$file")
    case "$svc" in
      gitlab|gitlab-runner) [ "$ext" = "*base" ] || fail "$domain: $svc 必须使用 *base" ;;
      portainer) [ "$ext" = "*common" ] || fail "$domain: $svc 必须使用 *common" ;;
      *) [ "$ext" = "*healthy" ] || fail "$domain: $svc 必须使用 *healthy" ;;
    esac
  done
}

check_base
for domain in "${DOMAINS[@]}"; do
  file="$ROOT/$domain/docker-compose.yml"
  [ -f "$file" ] || fail "缺少 $domain/docker-compose.yml"
  check_header "$file" "$domain"
  check_services "$file" "$domain"
done

printf 'compose style tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: FAIL，提示 `缺少 common/base-service.yml`。

- [ ] **Step 3: 创建 `common/base-service.yml`**

```yaml
# 公共服务模板：各域 compose 通过 extends 引用；本文件不是启动单元，
# 不参与 common/compose-list.sh 的批次。修改后请跑 ci/scripts/test-compose-style.sh。
services:
  service-base:
    restart: always

  service-common:
    extends: service-base
    env_file:
      - env/common.env

  service-healthy:
    extends: service-common
    healthcheck:
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
```

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: PASS，输出 `compose style tests: OK`。

- [ ] **Step 5: 语法检查**

Run: `bash -n ci/scripts/test-compose-style.sh`
Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add common/base-service.yml ci/scripts/test-compose-style.sh
git commit -m "feat(compose): 新增公共服务模板与风格断言骨架"
```

---

### Task 2: 转换 infra / observability / security

**Files:**
- Modify: `ci/scripts/test-compose-style.sh`（`DOMAINS`）
- Modify: `infra/docker-compose.yml`
- Modify: `observability/docker-compose.yml`
- Modify: `security/docker-compose.yml`

**Interfaces:**
- Consumes: Task 1 的 `service-healthy` 与 `x-healthy` 锚点形式
- Produces: 三个域全部服务 `extends: *healthy`；文件顶部统一代理注释；100 列域标题

- [ ] **Step 1: 把三个域加入测试**

把 `DOMAINS=()` 改为：

```bash
DOMAINS=(infra observability security)
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: FAIL，提示 `infra: mysql 缺少 extends`（或同类）。

- [ ] **Step 3: 转换三个 compose**

对每个文件：

1. 在 `networks:` 块之后、`services:` 之前加入锚点与文件顶部说明：

```yaml
# 本域服务不发布宿主端口；宿主访问统一经 portal（nginx）代理，见 portal/conf/。
# 新增或改名服务需同步 5 处，见 common/check-consistency.sh 与 README。

x-healthy: &healthy
  file: ../common/base-service.yml
  service: service-healthy
```

2. 每个服务按以下规则改写：
   - 首字段写 `extends: *healthy`；删除 `restart: always`。
   - 删除 `env_file` 中的 `../common/env/common.env`；有自己 env 的保留 `env_file: [env/<service>.env]`，没有的删除整个 `env_file` 块。
   - `healthcheck` 只保留 `test:`；删除 `interval` / `timeout` / `retries` / `start_period`。
   - 删除逐服务的「宿主访问统一经 nginx 代理」注释。
   - key 顺序：`extends → image → container_name → hostname → user/init/tty/shm_size → command → env_file → environment → volumes → depends_on → networks → ports → healthcheck → deploy`。
   - `test:` 数组去掉内边距：`[ "CMD-SHELL", "..." ]` → `["CMD-SHELL", "..."]`。
3. 异常服务：
   - `filebeat`（observability）保留完整时间参数 `30s/10s/3/30s`。
   - `keycloak`（security）保留完整时间参数 `10s/5s/10/60s`。
4. 把域标题改成 100 列，例如 infra：

```bash
header='# Infra 172.18.1.x '
printf '%s%s\n' "$header" "$(printf '=%.0s' $(seq 1 $((100 - ${#header}))))"
```

其余两个域同法（Observability 172.18.2.x、Security 172.18.3.x）。

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: PASS，输出 `compose style tests: OK`。

- [ ] **Step 5: 跑该域相关既有测试**

Run: `bash common/check-consistency.sh --strict && bash ci/scripts/test-docker-volume.sh && bash ci/scripts/test-env-config.sh`
Expected: 全部通过。

- [ ] **Step 6: 提交**

```bash
git add ci/scripts/test-compose-style.sh infra/docker-compose.yml observability/docker-compose.yml security/docker-compose.yml
git commit -m "refactor(compose): infra/observability/security 改用公共模板"
```

---

### Task 3: 转换 platform / apps / portal

**Files:**
- Modify: `ci/scripts/test-compose-style.sh`（`DOMAINS`）
- Modify: `platform/docker-compose.yml`
- Modify: `apps/docker-compose.yml`
- Modify: `portal/docker-compose.yml`

**Interfaces:**
- Consumes: Task 1 的 `service-healthy` / `service-common`
- Produces: platform 四个标准服务 `*healthy`、portainer `*common`；apps 四个 `*healthy`；nginx `*healthy`

- [ ] **Step 1: 把三个域加入测试**

```bash
DOMAINS=(infra observability security platform apps portal)
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: FAIL，提示 `platform: ... 缺少 extends`（或 portainer 模板不符）。

- [ ] **Step 3: 转换三个 compose**

按 Task 2 的同一套规则处理，差异：

- `platform/docker-compose.yml` 需要两个锚点：

```yaml
x-healthy: &healthy
  file: ../common/base-service.yml
  service: service-healthy
x-common: &common
  file: ../common/base-service.yml
  service: service-common
```

  - nacos / xxl-job-admin / nexus3 / apisix → `extends: *healthy`
  - portainer → `extends: *common`（保留「无探针」注释；删除 `restart` 与 common.env，不要加 healthcheck）
- `apps/docker-compose.yml`：
  - ollama、iptv 保留完整时间参数 `30s/10s/3/30s`；ollama 的 `tty` 与 `deploy`、iptv 的 `init` 按 key 顺序保留。
  - open-webui、moontv 标准 `*healthy`。
- `portal/docker-compose.yml`：
  - nginx → `*healthy`；`ports:` 放在 `networks` 之后；保留它是唯一持有宿主端口的注释。

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: PASS，输出 `compose style tests: OK`。

- [ ] **Step 5: 既有测试**

Run: `bash common/check-consistency.sh --strict && bash ci/scripts/test-devops-domain.sh`
Expected: 通过。

- [ ] **Step 6: 提交**

```bash
git add ci/scripts/test-compose-style.sh platform/docker-compose.yml apps/docker-compose.yml portal/docker-compose.yml
git commit -m "refactor(compose): platform/apps/portal 改用公共模板"
```

---

### Task 4: 转换 devops 并完成全量风格

**Files:**
- Modify: `ci/scripts/test-compose-style.sh`（`DOMAINS`）
- Modify: `devops/docker-compose.yml`

**Interfaces:**
- Consumes: Task 1 的 `service-base`
- Produces: devops 两个服务 `*base`；风格测试覆盖全部 7 个域

- [ ] **Step 1: 把 devops 加入测试**

```bash
DOMAINS=(infra observability security platform apps portal devops)
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: FAIL，提示 `devops: gitlab 必须使用 *base` 或缺少 extends。

- [ ] **Step 3: 转换 devops**

```yaml
x-base: &base
  file: ../common/base-service.yml
  service: service-base
```

- gitlab → `extends: *base`；保留 `environment`（GITLAB_OMNIBUS_CONFIG）、volumes、networks；healthcheck 保留 `test` 与完整时间参数 `30s/10s/20/300s`；删除 `restart`。
- gitlab-runner → `extends: *base`；保留 volumes/network；不加 healthcheck；补一条「无有意义的就绪命令」注释；删除 `restart`。
- 文件顶部加统一说明；域标题改为 100 列（Devops 172.18.7.x）。

- [ ] **Step 4: 运行全量风格测试**

Run: `bash ci/scripts/test-compose-style.sh`
Expected: PASS，输出 `compose style tests: OK`（7 个域全部检查）。

- [ ] **Step 5: 全量既有测试**

Run:

```bash
for t in ci/scripts/test-*.sh; do echo "== $t"; bash "$t" || exit 1; done
bash common/check-consistency.sh --strict
```

Expected: 全部通过。

- [ ] **Step 6: 提交**

```bash
git add ci/scripts/test-compose-style.sh devops/docker-compose.yml
git commit -m "refactor(compose): devops 改用公共模板并完成全量风格"
```

---

### Task 5: 文档更新

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: 最终模板形式与测试命令
- Produces: 文档中的模板说明、校验命令、新增服务步骤

- [ ] **Step 1: 更新 `CLAUDE.md`**

在架构要点中加入：

```markdown
**`common/base-service.yml` 是服务公共字段的唯一数据源。** 三层模板：`service-base`（`restart`）、`service-common`（+ `common.env`）、`service-healthy`（+ 标准 healthcheck 时间参数）。各域 compose 用 `x-` 锚点引用，服务里只写 `extends: *healthy`（无探针用 `*base`/`*common`）。`extends` 的映射字段（`environment`、`healthcheck`）按 key 合并；`env_file` 列表拼接，base 的相对路径会自动重定位。改公共字段只改这里，最终配置用 `docker compose config` 查看。
```

把本地校验清单加入：

```bash
bash ci/scripts/test-compose-style.sh
```

把「新增或改名服务」第 1 步补上 `extends: *healthy`（例外需说明理由）。

- [ ] **Step 2: 更新 `AGENTS.md`**

在 Build/Test 命令块加入 `bash ci/scripts/test-compose-style.sh`；在 Coding Style 段补一句：服务公共字段由 `common/base-service.yml` 的 `extends` 模板提供，新增服务不得重复写 `restart` / `common.env` / 标准 healthcheck 时间参数。

- [ ] **Step 3: 更新 `README.md`**

- 公共包说明补 `common/base-service.yml`。
- 「新增服务的同步点」第 1 步补：服务定义用 `extends: *healthy`，公共字段不要重复。
- 若 README 有目录结构树，加入 `common/base-service.yml`。

- [ ] **Step 4: 文档断言**

Run: `bash ci/scripts/test-doc-consistency.sh && bash ci/scripts/test-runbook.sh`
Expected: 通过（若新增的文档句子触发现有断言，按断言修正）。

- [ ] **Step 5: 提交**

```bash
git add CLAUDE.md AGENTS.md README.md
git commit -m "docs: 说明 compose 公共模板与新增服务写法"
```

---

### Task 6: 全量验证与最终审查

**Files:** 无新增/修改（全部改动已在 Task 1–5 提交）

- [ ] **Step 1: 全量 shell 语法**

Run: `while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')`
Expected: 无输出。

- [ ] **Step 2: 全部无 Docker 测试**

Run: `for t in ci/scripts/test-*.sh; do echo "== $t"; bash "$t" || exit 1; done`
Expected: 每个脚本 `... tests: OK`。

- [ ] **Step 3: 一致性校验**

Run: `bash common/check-consistency.sh --strict`
Expected: `consistency: OK（27 个服务的门户/代理/hosts 同步点齐全）`。

- [ ] **Step 4: 空白检查**

Run: `git diff --check`
Expected: 无输出。

- [ ] **Step 5: Compose 渲染（CI / 有 Docker 的机器）**

Run:

```bash
cp .env.local.example /tmp/glseven-verify.env
for f in */docker-compose.yml; do docker compose --env-file /tmp/glseven-verify.env -f "$f" config -q || exit 1; done
rm -f /tmp/glseven-verify.env
```

Expected: 七个文件全部无输出通过。

- [ ] **Step 6: 等价性比较（有 Docker 的机器）**

在改造前保存七份 `docker compose config --format json` 作为基线；改造后逐域渲染，比较服务名、image、container_name、hostname、ports、networks / ipv4_address、volumes、env_file 解析路径、healthcheck test 与时间参数、depends_on。重点：mysql / keycloak / gitlab 时间参数不变；gitlab / gitlab-runner 无新增 `TZ`；portainer 的 `env_file` 仍指向 `common/env/common.env`。

- [ ] **Step 7: 提交（如有验证修正）**

```bash
git status --short
# 若有修正：git add <files> && git commit -m "fix(compose): 修正模板渲染差异"
```

---

## Self-Review

- **Spec coverage:** 模板基座 → Task 1；infra/observability/security → Task 2；platform/apps/portal → Task 3；devops → Task 4；风格规则与 CI 断言 → Task 1–4；文档 → Task 5；验证 → Task 6。无遗漏。
- **Step scan:** 每个任务先改测试期望（RED）、再转换（GREEN）、再跑既有测试、再提交；没有 TBD 或未定义的函数。
- **Type consistency:** `DOMAINS`、`check_base`、`check_header`、`check_services`、锚点名 `*healthy`/`*common`/`*base` 在各任务中一致。
- **Review Focus:** 五条风险分别由 Task 6（渲染）、Task 4（base 白名单）、Task 3（common 白名单）、Task 4/6（既有测试）、Task 1–2（风格测试）覆盖。
- **Proportion:** 计划约 1.5 倍于 spec，主要是测试脚本与逐域转换规则；没有把每个服务的完整 YAML 抄进来。

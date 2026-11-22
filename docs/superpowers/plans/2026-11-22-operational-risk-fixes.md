# 运行风险与文档漂移修复（批次 1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复扫描发现的 5 类运行风险与文档漂移，为后续 compose 模板收敛腾出干净基线。

**Architecture:** 点状修改，不改变任何服务的运行时参数。脚本修复用仓库现有 bash 测试做 TDD；文档漂移用新增的 `test-doc-consistency.sh` 固化关键事实；`ci/validate.sh` 继续作为 CI 与本地共用的校验入口。

**Tech Stack:** Bash 3.2、Docker Compose v2、GitLab CI、nginx、Markdown。

**Spec:** docs/superpowers/specs/2026-11-22-operational-risk-fixes-design.md

## Global Constraints

- 所有 shell 脚本兼容 macOS 自带 Bash 3.2：不用 `mapfile`、关联数组、`${var,,}`、`&>>`。
- 新测试脚本用 `set -euo pipefail`，放在 `ci/scripts/test-*.sh`（`ci/validate.sh` 会自动执行）。
- 不改任何服务的 image / ports / networks / volumes 语义 / healthcheck 命令；唯一允许的 compose 变更是给 9 处配置挂载加 `:ro`。
- YAML 2 空格缩进，nginx 4 空格缩进；注释用中文。
- 所有提交信息用中文 + Conventional Commits 前缀。
- 所有命令在 worktree `/Users/george/project/glseven/glseven-docker/.claude/worktrees/project-config-service-reuse-71639c` 下执行，不切到主 checkout。
- 本机没有 Docker CLI；`docker compose config` 由 CI 覆盖，运行时演练在有 Docker 的机器执行。

## Review Focus

- sit → local 档案切换必须停掉 GitLab/Runner，但不能误停其他域；Task 3 的 `SHUTDOWN_GROUPS` 断言 + 运行时演练覆盖。
- 共享 `glseven` 网络被其他 project 占用时，shutdown 必须明确报告「网络保留」，不能假成功；Task 3 的横幅静态断言覆盖。
- `:ro` 挂载不能让启动时写配置的组件失败；Task 4 的挂载断言 + sit 日志检查覆盖。
- 本地执行 `ci/validate.sh` 不得修改工作区 `.env.local`；Task 1 的 `mktemp` 断言覆盖。
- smoke test 不得被宿主上其他 stack 的 unhealthy 容器拖失败；Task 2 的 network filter 断言覆盖。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `.gitignore` | 忽略 `.claude/` 本地设置 |
| `ci/validate.sh` | 临时 env 文件；忽略路径断言 |
| `ci/smoke-test.sh` | 只扫描 `glseven` 网络容器 |
| `common/compose-list.sh` | 新增 `build_shutdown_groups` |
| `shutdown.sh` | 无条件停 devops；`--remove-orphans`；网络删除结果显式汇报 |
| `startup.sh` | 删死 cache 目录；非 devops 档案下停残留 devops |
| `infra/observability/platform/docker-compose.yml` | 9 处配置挂载加 `:ro` |
| `ci/scripts/test-gitlab-ci.sh` | 断言 validate 不覆盖 `.env.local`、忽略 `.claude/` |
| `ci/scripts/test-deploy-sit.sh` | 断言 smoke 只扫 `glseven` |
| `ci/scripts/test-compose-list.sh` | 断言 shutdown 顺序与 devops 收敛、cache 已删 |
| `ci/scripts/test-readonly-mounts.sh` | 新增：9 处只读挂载断言 |
| `ci/scripts/test-doc-consistency.sh` | 新增：README/CLAUDE/runbook/portal 计数断言 |
| `README.md` / `CLAUDE.md` / `docs/runbooks/sit-cicd-bootstrap.md` | 文档漂移校正 |
| `portal/docker-compose.yml` / `portal/conf/stream-conf.d/*.conf` / `portal/html/index.html` | 注释与描述校正 |

---

### Task 1: gitignore 与 validate 硬化

**Files:**
- Modify: `.gitignore`（`.omc/` 之后）
- Modify: `ci/validate.sh:17-24`
- Test: `ci/scripts/test-gitlab-ci.sh`

**Interfaces:**
- Consumes: 无
- Produces: `ci/validate.sh` 使用 `$tmp_env` 临时文件；`.claude/` 进入仓库忽略规则

- [ ] **Step 1: 写失败断言**

在 `ci/scripts/test-gitlab-ci.sh` 的 `printf 'gitlab-ci tests: OK\n'` 之前加入：

```bash
# ci/validate.sh 不得覆盖工作区 .env.local
! grep -q 'cp \.env\.local\.example \.env\.local' "$ROOT/ci/validate.sh" ||
  fail "ci/validate.sh 不得直接覆盖 .env.local"
grep -q 'mktemp' "$ROOT/ci/validate.sh" ||
  fail "ci/validate.sh 应使用 mktemp 生成临时 env 文件"
grep -qE '^\.claude/?$' "$ROOT/.gitignore" ||
  fail ".gitignore 必须包含 .claude/"
for path in .env.local .env.sit .glseven-profile .claude/settings.local.json; do
  git -C "$ROOT" check-ignore -q "$path" || fail "$path 必须被 gitignore"
done
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-gitlab-ci.sh`
Expected: FAIL，提示 `ci/validate.sh 不得直接覆盖 .env.local`（或 `.gitignore 必须包含 .claude/`）。

- [ ] **Step 3: 实现**

`.gitignore` 在 `.omc/` 后追加：

```gitignore
# Local Claude Code settings
.claude/
```

`ci/validate.sh` 把第 17 行起的 compose 段替换为：

```bash
tmp_env="$(mktemp "${TMPDIR:-/tmp}/glseven-validate-env.XXXXXX")"
trap 'rm -f "$tmp_env"' EXIT
cp .env.local.example "$tmp_env"

for path in .env.local .env.sit .glseven-profile .claude/settings.local.json; do
  git check-ignore -q "$path" || { echo "Error: $path must be ignored" >&2; exit 1; }
done

shopt -s nullglob
files=(*/docker-compose.yml)
[[ ${#files[@]} -gt 0 ]]
for file in "${files[@]}"; do
  echo "Validating $file"
  docker compose --env-file "$tmp_env" -f "$file" config -q
done
```

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-gitlab-ci.sh`
Expected: PASS，输出 `gitlab-ci tests: OK`。

- [ ] **Step 5: 语法检查**

Run: `bash -n ci/validate.sh ci/scripts/test-gitlab-ci.sh`
Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add .gitignore ci/validate.sh ci/scripts/test-gitlab-ci.sh
git commit -m "fix(ci): validate 使用临时 env 文件并忽略 .claude"
```

---

### Task 2: smoke test 只扫 glseven 网络

**Files:**
- Modify: `ci/smoke-test.sh:15`
- Test: `ci/scripts/test-deploy-sit.sh`

**Interfaces:**
- Consumes: 无
- Produces: smoke 健康等待范围限定为 `glseven` 网络

- [ ] **Step 1: 写失败断言**

在 `ci/scripts/test-deploy-sit.sh` 的 `printf 'deploy-sit tests: OK\n'` 之前加入：

```bash
grep -Fq -- '--filter network=glseven' "$ROOT/ci/smoke-test.sh" ||
  fail "smoke-test.sh 必须只检查 glseven 网络的容器"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-deploy-sit.sh`
Expected: FAIL，提示 `smoke-test.sh 必须只检查 glseven 网络的容器`。

- [ ] **Step 3: 实现**

把 `ci/smoke-test.sh` 的容器遍历改为：

```bash
# 只看 glseven 网络：共享宿主上其他 stack 的 unhealthy 容器不应影响本编排 smoke。
for c in $(docker ps --filter network=glseven --format '{{.Names}}'); do
```

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-deploy-sit.sh`
Expected: PASS，输出 `deploy-sit tests: OK`。

- [ ] **Step 5: 语法检查**

Run: `bash -n ci/smoke-test.sh ci/scripts/test-deploy-sit.sh`
Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add ci/smoke-test.sh ci/scripts/test-deploy-sit.sh
git commit -m "fix(ci): smoke 只检查 glseven 网络容器"
```

---

### Task 3: 档案切换收敛与死 cache 目录

**Files:**
- Modify: `common/compose-list.sh`（文件末尾）
- Modify: `shutdown.sh:52-76`
- Modify: `startup.sh:113-115`（cache 行）与 `startup.sh:172-181`（devops 分支）
- Test: `ci/scripts/test-compose-list.sh`

**Interfaces:**
- Consumes: `COMPOSE_FILES_BASE` / `_DEFERRED` / `_DEVOPS` / `_PORTAL`（既有）
- Produces: `build_shutdown_groups` 设置全局数组 `SHUTDOWN_GROUPS = (infra observability security platform apps devops portal)`

- [ ] **Step 1: 更新失败断言**

把 `ci/scripts/test-compose-list.sh` 的目录循环改为（移除 `gitlab-runner/cache`）：

```bash
for dir in gitlab/config gitlab/logs gitlab/data gitlab-runner/config gitlab-runner/home; do
  grep -q "\"$dir " "$ROOT/startup.sh" || fail "DIR_SPECS 缺少 $dir"
done
```

并在其前加入：

```bash
build_shutdown_groups
[ "${SHUTDOWN_GROUPS[*]}" = "infra observability security platform apps devops portal" ] ||
  fail "shutdown 顺序必须无条件包含 devops"
grep -q -- '--remove-orphans' "$ROOT/shutdown.sh" ||
  fail "shutdown.sh 必须清理孤儿容器"
grep -q 'ps -aq' "$ROOT/startup.sh" ||
  fail "startup.sh 必须检测并停止残留 devops"
! grep -q 'gitlab-runner/cache' "$ROOT/startup.sh" ||
  fail "startup.sh 不应创建未挂载的 gitlab-runner/cache"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-compose-list.sh`
Expected: FAIL，`build_shutdown_groups: command not found`。

- [ ] **Step 3: 在 `common/compose-list.sh` 末尾实现**

```bash
# 关闭顺序：BASE + DEFERRED + DEVOPS + PORTAL。DEVOPS 无条件加入：
# 从 sit 切到 local 后仍可能残留 GitLab/Runner，跳过会占住 glseven 网络。
build_shutdown_groups() {
  SHUTDOWN_GROUPS=(
    "${COMPOSE_FILES_BASE[@]}"
    "${COMPOSE_FILES_DEFERRED[@]}"
    "${COMPOSE_FILES_DEVOPS[@]}"
    "${COMPOSE_FILES_PORTAL[@]}"
  )
}
```

- [ ] **Step 4: 修改 `shutdown.sh`**

把顶部注释（`# 按启动顺序...`）改为：

```bash
# 关闭顺序：BASE + DEFERRED + DEVOPS + PORTAL 的逆序。DEVOPS 无条件加入，
# 避免档案从 sit 切到 local 后 GitLab/Runner 残留。
```

`stop_all` 的 `down` 行改为：

```bash
compose -f "${group}/docker-compose.yml" down -t 60 --remove-orphans 2>/dev/null && echo "✓ ${group} services stopped" || echo "- ${group} not running"
```

把分组与网络段替换为：

```bash
echo "Stopping services..."
build_shutdown_groups
stop_all "${SHUTDOWN_GROUPS[@]}"

# 移除网络（幂等）。glseven 是共享网络：其他 project 仍在使用时保留并提示，
# 不能把「删不掉」误报成「全部停止」。
network_removed=false
if docker network inspect glseven &>/dev/null; then
  echo "Removing Docker network glseven..."
  if docker network rm glseven; then
    network_removed=true
    echo "✓ Network glseven removed"
  else
    occupants="$(docker network inspect glseven --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)"
    echo "WARN: network glseven is still in use (${occupants:-unknown}); leaving it in place."
  fi
else
  echo "Network glseven not found, skipping."
  network_removed=true
fi

echo "==========================================="
if $network_removed; then
  echo "所有服务已停止，网络 glseven 已移除"
else
  echo "所有编排容器已停止；网络 glseven 保留（被其他 project 占用）"
fi
echo "==========================================="
```

- [ ] **Step 5: 修改 `startup.sh`**

从 `DIR_SPECS` 删除：

```bash
  "gitlab-runner/cache 0"
```

把 devops 分支的 `else` 替换为：

```bash
else
  echo "Skipping devops services (profile: $PROFILE)"
  if [ -n "$(compose -f devops/docker-compose.yml ps -aq 2>/dev/null)" ]; then
    echo "Stopping devops services left over from another profile..."
    compose -f devops/docker-compose.yml down -t 60 --remove-orphans ||
      echo "WARN: failed to stop devops services, continuing..."
  fi
fi
```

- [ ] **Step 6: 运行确认通过**

Run: `bash ci/scripts/test-compose-list.sh`
Expected: PASS，输出 `compose-list tests: OK`。

- [ ] **Step 7: 语法检查**

Run: `bash -n startup.sh shutdown.sh common/compose-list.sh ci/scripts/test-compose-list.sh`
Expected: 无输出。

- [ ] **Step 8: 提交**

```bash
git add common/compose-list.sh shutdown.sh startup.sh ci/scripts/test-compose-list.sh
git commit -m "fix(lifecycle): 档案切换时收敛 devops 并清理死 cache 目录"
```

---

### Task 4: 配置挂载改为只读

**Files:**
- Modify: `infra/docker-compose.yml`（2 处）
- Modify: `observability/docker-compose.yml`（5 处）
- Modify: `platform/docker-compose.yml`（2 处）
- Test: `ci/scripts/test-readonly-mounts.sh`（新建）

**Interfaces:**
- Consumes: 无
- Produces: 9 处 mount 以 `:ro` 结尾；新测试纳入 `ci/validate.sh` 自动执行

- [ ] **Step 1: 新建失败测试**

创建 `ci/scripts/test-readonly-mounts.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check_mount() {
  local file="$1" mount="$2"
  grep -Fq -- "$mount" "$ROOT/$file" || fail "$file 缺少只读挂载: $mount"
}

check_mount infra/docker-compose.yml './mysql/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d:ro'
check_mount infra/docker-compose.yml './rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro'
check_mount observability/docker-compose.yml './prometheus/conf/prometheus.yml:/etc/prometheus/prometheus.yml:ro'
check_mount observability/docker-compose.yml './grafana/conf/provisioning:/etc/grafana/provisioning:ro'
check_mount observability/docker-compose.yml './grafana/conf/dashboards:/var/lib/grafana/dashboards:ro'
check_mount observability/docker-compose.yml './grafana/conf/config/grafana.ini:/etc/grafana/grafana.ini:ro'
check_mount observability/docker-compose.yml './elk/kibana/config/kibana.yml:/opt/kibana/config/kibana.yml:ro'
check_mount platform/docker-compose.yml './nacos/config/custom.properties:/home/nacos/init.d/custom.properties:ro'
check_mount platform/docker-compose.yml './xxl-job-admin/application.properties:/application.properties:ro'

printf 'readonly mount tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-readonly-mounts.sh`
Expected: FAIL，提示 `infra/docker-compose.yml 缺少只读挂载: ...`。

- [ ] **Step 3: 给 9 处挂载加 `:ro`**

按测试中的 9 个字符串，把对应 YAML 行的结尾改为 `:ro`。例如：

```yaml
      - ./mysql/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d:ro
```

其余 8 处同理，路径与测试断言完全一致。

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-readonly-mounts.sh`
Expected: PASS，输出 `readonly mount tests: OK`。

- [ ] **Step 5: 语法检查**

Run: `bash -n ci/scripts/test-readonly-mounts.sh`
Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add infra/docker-compose.yml observability/docker-compose.yml platform/docker-compose.yml ci/scripts/test-readonly-mounts.sh
git commit -m "fix(config): 配置挂载改为只读"
```

---

### Task 5: 文档与注释漂移校正

**Files:**
- Create: `ci/scripts/test-doc-consistency.sh`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/runbooks/sit-cicd-bootstrap.md`
- Modify: `portal/docker-compose.yml`
- Modify: `portal/conf/stream-conf.d/rabbitmq.conf`
- Modify: `portal/conf/stream-conf.d/kafka.conf`
- Modify: `portal/html/index.html`

**Interfaces:**
- Consumes: 无
- Produces: 文档关键事实被 `test-doc-consistency.sh` 固化

- [ ] **Step 1: 新建失败测试**

创建 `ci/scripts/test-doc-consistency.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq '7 个职能域、27 个容器' "$ROOT/README.md" || fail "README 域/容器数量未更新"
grep -Fq '七域结构与启动时序' "$ROOT/README.md" || fail "README 结构标题未更新"
grep -Fq '| devops |' "$ROOT/README.md" || fail "README 结构表缺少 devops"
grep -Fq '25 个主机名' "$ROOT/README.md" || fail "README hosts 数量未更新"
grep -Fq -- '--env-file .env.local' "$ROOT/README.md" || fail "README 命令迁移仍指向旧 .env"
! grep -Fq 'MySQL/Mongo' "$ROOT/README.md" || fail "README 仍称 Adminer 支持 MongoDB"
grep -Fq 'MySQL 管理' "$ROOT/README.md" || fail "README Adminer 描述未更新"
! grep -Fq 'MySQL / MongoDB' "$ROOT/portal/html/index.html" || fail "门户仍称 Adminer 支持 MongoDB"
grep -Fq 'MySQL 数据库管理' "$ROOT/portal/html/index.html" || fail "门户 Adminer 描述未更新"

! grep -q '四个脚本' "$ROOT/CLAUDE.md" || fail "CLAUDE.md 仍写四个脚本"
grep -Fq 'test-*.sh' "$ROOT/CLAUDE.md" || fail "CLAUDE.md 未改为所有 test-*.sh"

! grep -q 'docker-compose-devops.yml' "$ROOT/docs/runbooks/sit-cicd-bootstrap.md" ||
  fail "runbook 仍引用旧文件名"
grep -Fq 'devops/docker-compose.yml' "$ROOT/docs/runbooks/sit-cicd-bootstrap.md" ||
  fail "runbook 未指向新路径"

! grep -Fq '35672' "$ROOT/portal/conf/stream-conf.d/rabbitmq.conf" ||
  fail "RabbitMQ stream 注释仍有 35672 笔误"
! grep -Fq '见 infra/env/kafka.env' "$ROOT/portal/conf/stream-conf.d/kafka.conf" ||
  fail "Kafka stream 注释仍指向错误文件"
grep -Fq 'KAFKA_EXTERNAL_HOST' "$ROOT/portal/conf/stream-conf.d/kafka.conf" ||
  fail "Kafka stream 注释未说明 advertised 来源"

server_count=0
for f in "$ROOT"/portal/conf/conf.d/*.conf; do
  case "$f" in *.local.conf) continue ;; esac
  count=$(grep -Fc 'server {' "$f" || true)
  server_count=$((server_count + count))
done
grep -Eq "(^|[^0-9])${server_count} 个 server 块" "$ROOT/portal/docker-compose.yml" ||
  fail "portal compose 的 server 块计数与实际 ${server_count} 不一致"

printf 'doc consistency tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-doc-consistency.sh`
Expected: FAIL，提示 README 数量或 server 块计数不一致。

- [ ] **Step 3: 修改 README**

逐条替换：

- `面向开发环境的微服务基础设施 Docker Compose 编排：6 个职能域、25 个服务`
  → `面向开发环境的微服务基础设施 Docker Compose 编排：7 个职能域、27 个容器（nginx 门户 + 26 个后端服务）`
- `/etc/hosts 追加 24 个主机名` → `/etc/hosts 追加 25 个主机名`
- `脚本将 nexus3/prometheus/grafana/elk 数据目录 chown 到容器运行 uid`
  → `脚本按 DIR_SPECS 将数据目录 chown 到容器运行 uid`
- `## 六域结构与启动时序` → `## 七域结构与启动时序`
- 在 apps 表格行后插入：

```markdown
| devops | gitlab .1、gitlab-runner .2 | 172.18.7.x | DEVOPS（仅 sit） |
```

- `docker compose --env-file .env -f <域>/docker-compose.yml`
  → `docker compose --env-file .env.local -f <域>/docker-compose.yml`（sit 用 `.env.sit`）
- 把「否则根 `.env` 中的 `REDIS_PASSWORD` 不会被读取」改为「否则档案文件中的 `REDIS_PASSWORD` 不会被读取」
- `| Adminer | http://adminer.glseven.local:8080 | MySQL/Mongo 管理 |`
  → `| Adminer | http://adminer.glseven.local:8080 | MySQL 管理 |`
- `## 存量环境迁移（10 域 → 6 域，2026-09-08 重设计）`
  → `## 存量环境迁移（10 域 → 6 域，2026-09-08 重设计；devops 为 2026-11 新增的第 7 域）`

- [ ] **Step 4: 修改 CLAUDE.md / runbook / portal**

- `CLAUDE.md`：把「四个脚本」改为「所有 `test-*.sh`」，完整句子为：所有 `test-*.sh` 都必须保持 macOS 自带 Bash 3.2 兼容。
- `docs/runbooks/sit-cicd-bootstrap.md`：`docker-compose-devops.yml` → `devops/docker-compose.yml`
- `portal/docker-compose.yml`：`23 个 server 块` → `24 个 server 块`
- `portal/conf/stream-conf.d/rabbitmq.conf` 第 1 行 →
  `# stream：RabbitMQ 多协议透传（AMQP 宿主 5673 → 容器 5672）`
- `portal/conf/stream-conf.d/kafka.conf` 第 3 行 →
  `# 29092 供宿主/局域网（EXTERNAL，advertised 地址由 infra/docker-compose.yml 从当前档案的 KAFKA_EXTERNAL_HOST 渲染）`
- `portal/html/index.html`：`MySQL / MongoDB 数据库管理` → `MySQL 数据库管理`

- [ ] **Step 5: 运行确认通过**

Run: `bash ci/scripts/test-doc-consistency.sh`
Expected: PASS，输出 `doc consistency tests: OK`。

- [ ] **Step 6: 语法检查**

Run: `bash -n ci/scripts/test-doc-consistency.sh`
Expected: 无输出。

- [ ] **Step 7: 提交**

```bash
git add README.md CLAUDE.md docs/runbooks/sit-cicd-bootstrap.md portal/docker-compose.yml portal/conf/stream-conf.d/rabbitmq.conf portal/conf/stream-conf.d/kafka.conf portal/html/index.html ci/scripts/test-doc-consistency.sh
git commit -m "docs: 校正域数量、端口计数与旧文件名"
```

---

### Task 6: 全量验证与运行时演练

**Files:** 无新增/修改（全部改动已在 Task 1–5 提交）

- [ ] **Step 1: 全量 shell 语法**

Run:

```bash
while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')
```

Expected: 无输出。

- [ ] **Step 2: 全部无 Docker 测试**

Run:

```bash
for t in ci/scripts/test-*.sh; do echo "== $t"; bash "$t" || exit 1; done
```

Expected: 每个脚本输出 `... tests: OK`，最后退出码 0。

- [ ] **Step 3: 一致性校验**

Run: `bash common/check-consistency.sh --strict`
Expected: `consistency: OK（27 个服务的门户/代理/hosts 同步点齐全）`。

- [ ] **Step 4: 空白检查**

Run: `git diff --check`
Expected: 无输出。

- [ ] **Step 5: Compose 渲染（有 Docker 的机器 / CI）**

Run:

```bash
cp .env.local.example /tmp/glseven-verify.env
for f in */docker-compose.yml; do docker compose --env-file /tmp/glseven-verify.env -f "$f" config -q || exit 1; done
rm -f /tmp/glseven-verify.env
```

Expected: 七个文件全部无输出通过。

- [ ] **Step 6: 档案切换演练（有 Docker 的机器）**

Run:

```bash
bash startup.sh --profile sit
bash startup.sh --profile local
docker ps --format '{{.Names}}' | grep -E '^(gitlab|gitlab-runner)$' && echo "FAIL: devops 残留" || echo "OK: devops 已停止"
bash shutdown.sh
```

Expected: `local` 启动后没有 gitlab/gitlab-runner；shutdown 横幅与实际网络状态一致。

- [ ] **Step 7: `:ro` 冒烟（sit）**

Run:

```bash
docker inspect -f '{{.State.Health.Status}}' prometheus grafana elk nacos xxl-job-admin mysql rabbitmq
for c in grafana rabbitmq nacos elk; do
  docker logs --tail 100 "$c" 2>&1 | grep -iE 'read-only|permission denied|failed to write' && exit 1 || true
done
echo "OK: 无只读写入错误"
```

Expected: 容器 healthy；grafana / rabbitmq / nacos / elk 日志均无只读写入错误。

---

## Self-Review

- **Spec coverage:** 修复项 1 → Task 3；2 → Task 1；3 → Task 2；4 → Task 3；5 → Task 4；6 → Task 5；7 → Task 1；验证 → Task 6。无遗漏。
- **Step scan:** 每个步骤是一动作 + 可检查结果；没有 TBD、没有未定义的函数。
- **Type consistency:** `build_shutdown_groups` / `SHUTDOWN_GROUPS` 在 `compose-list.sh`、`shutdown.sh`、`test-compose-list.sh` 三处名称一致。
- **Review Focus:** 五条风险分别由 Task 3、Task 3、Task 4、Task 1、Task 2 的断言或演练覆盖。
- **Proportion:** 计划约 2 倍于 spec，主要是精确替换文本与测试代码；没有把实现体写成逐行转录。

# 按域分包重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 6 个 compose 文件、11 个服务配置目录、13 个服务 env 收进各自的域目录，根目录只留域包、`common` 共享包与入口脚本。

**Architecture:** 每域一个目录：`<域>/docker-compose.yml` + `<域>/env/<服务>.env` + 该域配置目录；`common/env/common.env` 保持唯一共享 env；根 `.env` 不动，脚本用 `--env-file` 显式传入；全部用 `git mv`，服务定义零改动。

**Tech Stack:** Docker Compose v2、Bash、git、grep/perl（无构建、无测试框架）。

**Spec:** `docs/superpowers/specs/2026-11-21-domain-packages-restructure-design.md`

## Global Constraints

- 服务定义零改动：镜像、`ports`、固定 IP、`networks`、`volumes`、`healthcheck`、env 值一律不动，只改文件位置与引用路径。
- 包内 compose 统一命名 `docker-compose.yml`；顶层 `name:` 保留。
- 服务 env 进 `<域>/env/`；`common.env` 唯一例外，留在 `common/env/common.env`。
- 根 `.env` / `.env.example` 不动；所有脚本内 `docker compose` 调用显式 `--env-file "$SCRIPT_DIR/.env"`；`shutdown.sh` 必须容忍 `.env` 缺失。
- 全部移动用 `git mv`；历史文档 `docs/superpowers/specs|plans/*` 不改。
- 脚本只依赖 docker / bash / grep / perl 等必有工具。
- 当前环境无 docker CLI（`command -v docker` 为空）且 worktree 无 `.env`：所有 `docker compose config` 步骤标为「有 docker 时执行」，没有则记录「未执行，由 CI 覆盖」。
- 全部任务完成并通过 Task 7 验证前不推送远端。

## Review Focus

1. **手工命令不带 `--env-file`**：根 `.env` 不再被自动读取，`REDIS_PASSWORD` 静默回落到默认值，redis 与 moontv 与既有容器密码不一致。测试落在 Task 6（README/CLAUDE 命令模板必须含 `--env-file .env`）。
2. **无 `.env` 时 `shutdown.sh` 失败**：新检出直接关机是常见路径。测试落在 Task 5（存在 `.env` 判断 + `bash -n`）。
3. **portal 挂载前缀漏改**：`./portal/conf` 在 compose 挪进 `portal/` 后指向不存在的 `portal/portal/conf`，`config -q` 不查路径存在性，运行时报错。测试落在 Task 4（`./portal/` 零命中、挂载只出现 `./conf` 与 `./html`）。
4. **preflight 的镜像/端口提取 glob 未更新**：grep 无输出不报错，镜像代理预拉与端口占用检查会静默失效。测试落在 Task 5（提取命令输出数 = 3 与 28）。
5. **文档残留旧路径**：用户照抄命令失败。测试落在 Task 6 与 Task 7（旧路径全仓零命中，历史 docs 除外）。

---

### Task 1: infra 包

**Files:**
- Move: `docker-compose-infra.yml` → `infra/docker-compose.yml`；`mysql/`、`rabbitmq/` → `infra/`；`common/env/{mysql,mongo,mongo-express,rabbitmq,kafka}.env` → `infra/env/`
- Modify: `infra/docker-compose.yml`（env_file 与注释）、`infra/env/kafka.env`（注释里的命令）

**Interfaces:**
- Consumes: 无（首个任务）
- Produces: 包布局模式 `<域>/docker-compose.yml` + `<域>/env/`，后续任务照此执行；`infra/env/*.env` 供后续文档任务引用

- [ ] **Step 1: 移动文件**

```bash
mkdir -p infra/env
git mv docker-compose-infra.yml infra/docker-compose.yml
git mv mysql infra/mysql
git mv rabbitmq infra/rabbitmq
git mv common/env/mysql.env infra/env/mysql.env
git mv common/env/mongo.env infra/env/mongo.env
git mv common/env/mongo-express.env infra/env/mongo-express.env
git mv common/env/rabbitmq.env infra/env/rabbitmq.env
git mv common/env/kafka.env infra/env/kafka.env
```

- [ ] **Step 2: 改 env_file 引用**

```bash
perl -pi -e 's{common/env/common\.env}{../common/env/common.env}g; s{common/env/(mysql|mongo-express|mongo|rabbitmq|kafka)\.env}{env/$1.env}g' infra/docker-compose.yml
```

- [ ] **Step 3: 改 kafka.env 注释里的命令**

把 `infra/env/kafka.env` 第 13 行的 `docker compose -f docker-compose-infra.yml up -d kafka` 改为 `docker compose --env-file .env -f infra/docker-compose.yml up -d kafka`。

- [ ] **Step 4: 静态断言（无需 docker）**

```bash
grep -c '\.\./common/env/common\.env' infra/docker-compose.yml   # 期望 8
grep -n 'common/env/' infra/docker-compose.yml                    # 期望只剩 ../common/env/common.env
grep -nE '^\s+- \./' infra/docker-compose.yml                     # 期望只有 ./mysql/... 与 ./rabbitmq/...
test ! -d mysql && test ! -d rabbitmq && echo MOVE-OK             # 期望 MOVE-OK
```

- [ ] **Step 5: 渲染校验（有 docker 时）**

```bash
[ -f .env ] || cp .env.example .env
docker compose --env-file .env -f infra/docker-compose.yml config -q && echo CONFIG-OK
```

无 docker 时记录「未执行，由 CI 覆盖」。`.env` 为 gitignored，复制不影响提交。

- [ ] **Step 6: 提交**

```bash
git add infra common/env
git commit -m "refactor(structure): infra 域收敛为独立包"
```

---

### Task 2: observability 与 security 包

**Files:**
- Move: `docker-compose-observability.yml` → `observability/docker-compose.yml`；`prometheus/`、`grafana/`、`filebeat/`、`elk/` → `observability/`
- Move: `docker-compose-security.yml` → `security/docker-compose.yml`；`openldap/` → `security/openldap/`；`common/env/{openldap,phpldapadmin,keycloak}.env` → `security/env/`
- Modify: 两个 compose 的 env_file；`security/openldap/bootstrap/admin-entry.ldif` 注释

**Interfaces:**
- Consumes: Task 1 的包布局
- Produces: `observability/`（无专属 env）、`security/env/*.env`

- [ ] **Step 1: 移动文件**

```bash
mkdir -p security/env
git mv docker-compose-observability.yml observability/docker-compose.yml
git mv prometheus grafana filebeat elk observability/
git mv docker-compose-security.yml security/docker-compose.yml
git mv openldap security/openldap
git mv common/env/openldap.env security/env/openldap.env
git mv common/env/phpldapadmin.env security/env/phpldapadmin.env
git mv common/env/keycloak.env security/env/keycloak.env
```

- [ ] **Step 2: 改 env_file 引用**

```bash
perl -pi -e 's{common/env/common\.env}{../common/env/common.env}g' observability/docker-compose.yml
perl -pi -e 's{common/env/common\.env}{../common/env/common.env}g; s{common/env/(openldap|phpldapadmin|keycloak)\.env}{env/$1.env}g' security/docker-compose.yml
```

- [ ] **Step 3: 改 admin-entry.ldif 注释**

把 `security/openldap/bootstrap/admin-entry.ldif` 第 10 行的 `common/env/openldap.env` 改为 `security/env/openldap.env`。

- [ ] **Step 4: 静态断言（无需 docker）**

```bash
grep -c '\.\./common/env/common\.env' observability/docker-compose.yml   # 期望 4
grep -c '\.\./common/env/common\.env' security/docker-compose.yml         # 期望 3
grep -nE '^\s+- \./' observability/docker-compose.yml                     # 期望 ./prometheus ./grafana ./filebeat ./elk
grep -rn 'common/env/' observability security | grep -v '\.\./common/env/common\.env' || echo CLEAN  # 期望 CLEAN
test ! -d prometheus && test ! -d openldap && echo MOVE-OK                # 期望 MOVE-OK
```

- [ ] **Step 5: 渲染校验（有 docker 时）**

```bash
docker compose --env-file .env -f observability/docker-compose.yml config -q && \
docker compose --env-file .env -f security/docker-compose.yml config -q && echo CONFIG-OK
```

无 docker 时记录未执行。

- [ ] **Step 6: 提交**

```bash
git add observability security common/env
git commit -m "refactor(structure): observability 与 security 域收敛为独立包"
```

---

### Task 3: platform 与 apps 包

**Files:**
- Move: `docker-compose-platform.yml` → `platform/docker-compose.yml`；`nacos/`、`xxl-job-admin/`、`apisix/` → `platform/`；`common/env/nacos.env` → `platform/env/`
- Move: `docker-compose-apps.yml` → `apps/docker-compose.yml`；`common/env/{ollama,open-webui,moontv,iptv}.env` → `apps/env/`
- Modify: 两个 compose 的 env_file

**Interfaces:**
- Consumes: Task 1 的包布局
- Produces: `platform/env/nacos.env`、`apps/env/*.env`

- [ ] **Step 1: 移动文件**

```bash
mkdir -p platform/env apps/env
git mv docker-compose-platform.yml platform/docker-compose.yml
git mv nacos xxl-job-admin apisix platform/
git mv common/env/nacos.env platform/env/nacos.env
git mv docker-compose-apps.yml apps/docker-compose.yml
git mv common/env/ollama.env apps/env/ollama.env
git mv common/env/open-webui.env apps/env/open-webui.env
git mv common/env/moontv.env apps/env/moontv.env
git mv common/env/iptv.env apps/env/iptv.env
```

- [ ] **Step 2: 改 env_file 引用**

```bash
perl -pi -e 's{common/env/common\.env}{../common/env/common.env}g; s{common/env/nacos\.env}{env/nacos.env}g' platform/docker-compose.yml
perl -pi -e 's{common/env/common\.env}{../common/env/common.env}g; s{common/env/(ollama|open-webui|moontv|iptv)\.env}{env/$1.env}g' apps/docker-compose.yml
```

- [ ] **Step 3: 静态断言（无需 docker）**

```bash
grep -c '\.\./common/env/common\.env' platform/docker-compose.yml   # 期望 5
grep -c '\.\./common/env/common\.env' apps/docker-compose.yml       # 期望 4
grep -nE '^\s+- \./' platform/docker-compose.yml                    # 期望 ./nacos ./xxl-job-admin ./apisix
grep -nE '^\s+- \./' apps/docker-compose.yml || echo NO-LOCAL-MOUNTS  # 期望 NO-LOCAL-MOUNTS
test ! -d nacos && test ! -d apisix && echo MOVE-OK                 # 期望 MOVE-OK
```

- [ ] **Step 4: 渲染校验（有 docker 时）**

```bash
docker compose --env-file .env -f platform/docker-compose.yml config -q && \
docker compose --env-file .env -f apps/docker-compose.yml config -q && echo CONFIG-OK
```

无 docker 时记录未执行。

- [ ] **Step 5: 提交**

```bash
git add platform apps common/env
git commit -m "refactor(structure): platform 与 apps 域收敛为独立包"
```

---

### Task 4: portal 包

**Files:**
- Move: `docker-compose-portal.yml` → `portal/docker-compose.yml`
- Modify: `portal/docker-compose.yml`（env_file、5 处挂载前缀、kafka.env 注释路径）、`portal/conf/stream-conf.d/kafka.conf`（注释路径）

**Interfaces:**
- Consumes: Task 1–3 已清空根目录其余 compose 文件
- Produces: 根目录不再有 `docker-compose-*.yml`

- [ ] **Step 1: 移动并改引用**

```bash
git mv docker-compose-portal.yml portal/docker-compose.yml
perl -pi -e 's{common/env/common\.env}{../common/env/common.env}g; s{\./portal/}{./}g; s{common/env/kafka\.env}{infra/env/kafka.env}g' portal/docker-compose.yml
```

- [ ] **Step 2: 改 stream 配置注释**

把 `portal/conf/stream-conf.d/kafka.conf` 第 3 行的 `common/env/kafka.env` 改为 `infra/env/kafka.env`。

- [ ] **Step 3: 静态断言（无需 docker）**

```bash
grep -n '\./portal/' portal/docker-compose.yml || echo NO-PORTAL-PREFIX   # 期望 NO-PORTAL-PREFIX
grep -oE '^\s+- \./[a-z-]+' portal/docker-compose.yml | sort | uniq -c    # 期望 4×./conf、1×./html
ls docker-compose-*.yml 2>/dev/null || echo ROOT-CLEAN                    # 期望 ROOT-CLEAN
grep -c '\.\./common/env/common\.env' portal/docker-compose.yml           # 期望 1
```

- [ ] **Step 4: 渲染校验（有 docker 时）**

```bash
docker compose --env-file .env -f portal/docker-compose.yml config -q && echo CONFIG-OK
```

无 docker 时记录未执行。

- [ ] **Step 5: 提交**

```bash
git add portal
git commit -m "refactor(structure): portal 域收敛为独立包"
```

---

### Task 5: 脚本、一致性检查与 CI 适配

**Files:**
- Modify: `startup.sh`（3 处 compose 调用）、`shutdown.sh`（down 调用 + `.env` 判存）、`common/preflight.sh`（2 处 glob + 2 处提示文案 + env 警告文案）、`common/check-consistency.sh`（服务提取 glob）、`.github/workflows/ci.yml`（校验 glob）

**Interfaces:**
- Consumes: Task 1–4 的 `<域>/docker-compose.yml` 布局
- Produces: 起停脚本、preflight、一致性检查、CI 全部指向新路径；`--env-file` 统一注入

- [ ] **Step 1: startup.sh**

把 3 处 `docker compose -f "docker-compose-${group}.yml" up -d || { ... }` 改为：

```bash
docker compose --env-file "$SCRIPT_DIR/.env" -f "${group}/docker-compose.yml" up -d || { echo "Error: ${group} services failed to start"; exit 1; }
```

（BASE、DEFERRED、PORTAL 三个循环各一处；preflight 已保证 `.env` 存在。）

- [ ] **Step 2: shutdown.sh**

把 `stop_all` 循环体内的 down 行改为：

```bash
    local env_args=()
    if [ -f "$SCRIPT_DIR/.env" ]; then env_args=(--env-file "$SCRIPT_DIR/.env"); fi
    docker compose "${env_args[@]}" -f "${group}/docker-compose.yml" down -t 60 2>/dev/null && echo "✓ ${group} services stopped" || echo "- ${group} not running"
```

- [ ] **Step 3: preflight.sh**

- 镜像提取：`"$SCRIPT_DIR"/docker-compose-*.yml` → `"$SCRIPT_DIR"/*/docker-compose.yml`
- 端口提取：`"$SCRIPT_DIR/docker-compose-portal.yml"` → `"$SCRIPT_DIR/portal/docker-compose.yml"`
- 提示文案：`remap the host-side port in docker-compose-portal.yml.` → `remap the host-side port in portal/docker-compose.yml.`
- env 警告文案：`common/env/*.env` → `*/env/*.env`

- [ ] **Step 4: check-consistency.sh**

`services=$(for f in docker-compose-*.yml; do` → `services=$(for f in */docker-compose.yml; do`

- [ ] **Step 5: ci.yml**

`files=(docker-compose-*.yml)` → `files=(*/docker-compose.yml)`

- [ ] **Step 6: 断言（无需 docker）**

```bash
bash -n startup.sh shutdown.sh common/preflight.sh common/check-consistency.sh common/compose-list.sh && echo SYNTAX-OK
grep -n 'docker-compose-' startup.sh shutdown.sh common/*.sh || echo NO-OLD-PATH
grep -hoE 'image:[[:space:]]*(ghcr\.io|quay\.io)/[A-Za-z0-9_./:-]+' */docker-compose.yml | wc -l   # 期望 3
grep -oE '"[0-9]+:[0-9]+"' portal/docker-compose.yml | wc -l                                      # 期望 28
bash common/check-consistency.sh | grep '\[!\]' && echo HAS-WARNINGS || echo CONSISTENCY-CLEAN
grep -n '\[ -f "$SCRIPT_DIR/.env" \]' shutdown.sh   # 期望命中一行
```

- [ ] **Step 7: 提交**

```bash
git add startup.sh shutdown.sh common/preflight.sh common/check-consistency.sh .github/workflows/ci.yml
git commit -m "refactor(scripts): 起停与校验脚本适配域包路径"
```

---

### Task 6: 文档更新

**Files:**
- Modify: `README.md`、`CLAUDE.md`、`AGENTS.md`

**Interfaces:**
- Consumes: 前面的全部新路径
- Produces: 文档中旧路径零残留

- [ ] **Step 1: README.md**

- 六域结构表：表头「域（compose 文件）」→「域（包）」，并补一句：每个域一个目录，compose 为 `<域>/docker-compose.yml`，服务 env 在 `<域>/env/`。
- `common/env/<service>.env` → `<域>/env/<service>.env`（第 84 行附近）。
- 新增服务同步点：`docker-compose-<域>.yml` → `<域>/docker-compose.yml`；`docker-compose-portal.yml` → `portal/docker-compose.yml`。
- `common/env/keycloak.env` → `security/env/keycloak.env`。
- `common/env/kafka.env` → `infra/env/kafka.env`（3 处），`docker compose -f docker-compose-infra.yml up -d kafka` → `docker compose --env-file .env -f infra/docker-compose.yml up -d kafka`。
- `docker-compose-infra.yml` → `infra/docker-compose.yml`（mongo 段），`common/env/mongo.env` → `infra/env/mongo.env`；`docker compose -f docker-compose-infra.yml up -d mongo` → `docker compose --env-file .env -f infra/docker-compose.yml up -d mongo`。
- `openldap/bootstrap/admin-entry.ldif` → `security/openldap/bootstrap/admin-entry.ldif`；`common/env/phpldapadmin.env` → `security/env/phpldapadmin.env`。
- ollama GPU 段：`docker-compose-apps.yml` → `apps/docker-compose.yml`，命令加 `--env-file .env`。
- 在「六域结构与启动时序」后补一段迁移说明：旧命令 `docker compose -f docker-compose-<域>.yml ...` 一律改为 `docker compose --env-file .env -f <域>/docker-compose.yml ...`。

- [ ] **Step 2: CLAUDE.md**

- 首段：`docker-compose-*.yml` → `<域>/docker-compose.yml`，`common/env/*.env` → `<域>/env/*.env`。
- 常用命令：两条单域 up 命令与 `config -q` 命令改为新路径并加 `--env-file .env`。
- 架构要点：「六个文件（…）一域一个」→「六个域包（`infra/` … `portal/`）一域一个，compose 为 `<域>/docker-compose.yml`」。
- 新增服务正规路径：`docker-compose-portal.yml` → `portal/docker-compose.yml`。
- env 分层：`common/env/<service>.env` → `<域>/env/<service>.env`；`common/env/kafka.env` → `infra/env/kafka.env`；`common/env/common.env` 保持不变。
- 平台限制：`openldap/bootstrap/admin-entry.ldif` → `security/openldap/bootstrap/admin-entry.ldif`。

- [ ] **Step 3: AGENTS.md**

- 第 5 行：六个域文件清单改为六个域目录（`infra/docker-compose.yml` …）；`common/env/<service>.env` → `<domain>/env/<service>.env`。
- 第 13 行：`for file in docker-compose-*.yml; do …` → `for file in */docker-compose.yml; do …`。
- 第 21 行：`docker-compose-portal.yml` → `portal/docker-compose.yml`。
- 第 38 行：`common/env/*` → `<domain>/env/*`。

- [ ] **Step 4: 断言**

```bash
grep -nE 'docker-compose-(infra|observability|security|platform|apps|portal)\.yml|common/env/(mysql|mongo|mongo-express|rabbitmq|kafka|openldap|phpldapadmin|keycloak|nacos|ollama|open-webui|moontv|iptv)\.env' README.md CLAUDE.md AGENTS.md || echo DOCS-CLEAN
grep -n -- '--env-file .env' README.md CLAUDE.md | head   # 期望至少各命中一次
```

- [ ] **Step 5: 提交**

```bash
git add README.md CLAUDE.md AGENTS.md
git commit -m "docs: 更新按域分包后的目录、路径与命令"
```

---

### Task 7: 全量验证与收尾

**Files:**
- 只读验证；如发现问题，回到对应任务修复并提交

**Interfaces:**
- Consumes: Task 1–6 的全部产物
- Produces: 可交付的分支状态

- [ ] **Step 1: 一致性检查**

```bash
bash common/check-consistency.sh
```

期望：无任何 `[!]` 行。

- [ ] **Step 2: 旧路径全仓扫描（历史 docs 除外）**

```bash
grep -rnE 'docker-compose-[a-z]+\.yml|common/env/(mysql|mongo|mongo-express|rabbitmq|kafka|openldap|phpldapadmin|keycloak|nacos|ollama|open-webui|moontv|iptv)\.env' \
  --exclude-dir=.git --exclude-dir=.claude --exclude-dir=.omc --exclude-dir=docs . || echo REPO-CLEAN
```

期望：`REPO-CLEAN`（`common/env/common.env` 是合法保留项，正则已排除）。

- [ ] **Step 3: 结构与脚本复核**

```bash
find . -maxdepth 2 -type d -not -path './.git*' -not -path './.claude*' -not -path './.omc*' | sort
bash -n startup.sh shutdown.sh common/*.sh && echo SYNTAX-OK
git status --short   # 期望为空
git log --oneline -8
```

期望目录：六个域包 + `common` + `docs`；根目录无 `docker-compose-*.yml`，无服务配置目录。

- [ ] **Step 4: 渲染校验（有 docker 时）**

```bash
[ -f .env ] || cp .env.example .env
for f in */docker-compose.yml; do docker compose --env-file .env -f "$f" config -q || exit 1; done && echo ALL-CONFIG-OK
root="$(pwd)"
for f in */docker-compose.yml; do docker compose --env-file .env -f "$f" config; done \
  | grep -oE "$root/[^\"' ]+" | sort -u | grep -vE "$root/(infra|observability|security|platform|apps|portal|common)/" && echo PATH-LEAK || echo PATHS-OK
```

无 docker 时记录「未执行，由 CI 覆盖」；对应未验证项写入交付说明。

- [ ] **Step 5: 收尾**

若前面步骤全部通过且无改动，无需新提交；若有修复，按所属任务补提交并在交付说明中记录。**不推送远端。**

---

## Self-Review 记录

- **Spec 覆盖**：目录终态、文件映射、compose 引用、`.env` 处理、脚本/CI、文档、验证清单均有对应任务；spec 中「留给实施者」的两项（提交粒度、compose-list 是否加辅助函数）已分别定为「按域分批提交」（Task 1–4）与「不加辅助函数」（Task 5 保持原结构）。
- **步骤粒度**：每步一条可执行命令或一处精确替换，均带可观察结果。
- **类型一致性**：`<域>/docker-compose.yml`、`<域>/env/<服务>.env`、`--env-file "$SCRIPT_DIR/.env"` 全文一致。
- **Review Focus**：五条风险各自有测试步骤（Task 4 / 5 / 6 / 7）。
- **比例**：计划以命令与断言为主，无实现代码转写。

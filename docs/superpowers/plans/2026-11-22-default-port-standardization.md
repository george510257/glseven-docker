# 端口标准化（门户/GitLab 8080、GitLab SSH 2222）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把门户从 8000、GitLab Web 从 8929、GitLab SSH 从 2224 改为 8080/8080/2222，其余宿主端口全部保持原生值。

**Architecture:** 纯配置变更，无应用代码。nginx 的 HTTP 侧把门户与 GitLab 两个 vhost 的 `listen` 搬到已有的 8080 共享端口（按 `server_name` 分流），stream 侧把 GitLab SSH 的监听从 2224 改为 2222；compose 只调整 `ports:`、healthcheck 和 GitLab 的 `external_url`。验证靠新增的 bash 断言脚本 + 现有 CI 脚本。

**Tech Stack:** Docker Compose、nginx（http + stream）、Bash（兼容 macOS 自带 3.2）。

**Spec:** `docs/superpowers/specs/2026-11-22-default-port-standardization-design.md`

## Global Constraints

- 端口精确值：门户 **8080**、GitLab Web **8080**、GitLab SSH **2222**。
- 其余端口一条不改：3000、8081、9000、9090、5601、9200、15672、9080、9180、1905，以及 16 条 stream（3306、6379、27017、5673、1883、15675、9092、29092、2379、389、636、8848、9848、11434、5044、5000）。
- 不改后端容器内部端口；唯一例外是 GitLab（`external_url` 决定其内部 omnibus nginx 监听 8080）。
- 不修改 `docs/superpowers/specs/` 与 `docs/superpowers/plans/` 下的历史文档。
- Bash 保持 macOS 自带 3.2 兼容；YAML/nginx 2 空格缩进；提交信息用中文 + conventional 前缀（建议 `refactor(ports): ...`）。
- Task 1 新增的 `ci/scripts/test-default-ports.sh` 在同一提交里就包含 gitlab/docs/ci 三组断言，这些组在 Task 4 之前必然 FAIL；**Task 1-4 期间不要 push**，全部完成后在 Task 5 一次 push。

## Review Focus

- **8080 上的 server_name 冲突**：门户、GitLab 加入后 8080 有 8 个 vhost；若 `server_name` 重复，nginx 启动即失败。Task 1/2 的 `nginx -t` 与断言覆盖。
- **根域/裸 IP 兜底残留旧端口**：`portal.conf` 的 301 与 `00-default-catchall.conf` 的 302 若仍指向 `:8000`，用户会被跳到已释放端口。Task 1 断言覆盖。
- **只改 nginx 未改 compose 映射**：宿主仍会暴露 8000/8929。Task 1/2 的 compose 断言覆盖。
- **GitLab external_url 与 healthcheck 不一致**：`external_url` 改 8080 而 healthcheck 仍探 8929 会让容器一直 unhealthy。Task 2 断言覆盖。
- **sit 上 Runner config.toml 未同步**：运行在数据目录、不在仓库，只能写进 runbook 提醒。Task 3 覆盖文档。

---

### Task 1: 端口断言脚本 + 门户 8000→8080

**Files:**
- Create: `ci/scripts/test-default-ports.sh`
- Modify: `portal/docker-compose.yml:29-62`
- Modify: `portal/conf/conf.d/portal.conf`
- Modify: `portal/conf/conf.d/00-default-catchall.conf`

**Interfaces:**
- Consumes: 无。
- Produces: `bash ci/scripts/test-default-ports.sh [portal|gitlab|docs|ci|all]`——逐项打印 `[OK]`/`[FAIL]`，有 FAIL 时 exit 1；后续 Task 2-4 用它做每组验证，Task 5 用 `all`。

- [ ] **Step 1: 写断言脚本**

创建 `ci/scripts/test-default-ports.sh`，内容如下（`-F` 固定字符串匹配，避免正则转义）：

```bash
#!/usr/bin/env bash
# 端口标准化断言：门户/GitLab Web 8080、GitLab SSH 2222。
# 用法：bash ci/scripts/test-default-ports.sh [portal|gitlab|docs|ci|all]
set -u

group="${1:-all}"
fail=0

pass() { printf '  [OK]   %s\n' "$*"; }
fail_check() { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }

file_has() {
  if grep -qF -- "$2" "$1"; then pass "$3"; else fail_check "$3（缺 $2）"; fi
}

file_lacks() {
  if grep -qF -- "$2" "$1"; then fail_check "$3（仍有 $2）"; else pass "$3"; fi
}

check_portal() {
  echo "portal:"
  file_has   portal/docker-compose.yml '"8080:8080"' "portal compose 发布 8080"
  file_lacks portal/docker-compose.yml '"8000:8000"' "portal compose 不再发布 8000"
  file_has   portal/docker-compose.yml '/dev/tcp/127.0.0.1/8080' "healthcheck 探 8080"
  file_has   portal/conf/conf.d/portal.conf 'listen 8080' "portal vhost listen 8080"
  file_lacks portal/conf/conf.d/portal.conf 'listen 8000' "portal vhost 不再 listen 8000"
  file_has   portal/conf/conf.d/portal.conf 'portal.glseven.local:8080' "根域 301 指向 8080"
  file_lacks portal/conf/conf.d/00-default-catchall.conf ':8000' "catchall 不再指向 8000"
  file_has   portal/conf/conf.d/00-default-catchall.conf 'portal.glseven.local:8080' "catchall 指向 8080"
}

check_gitlab() {
  echo "gitlab:"
  file_has   portal/conf/conf.d/gitlab.conf 'listen 8080' "gitlab vhost listen 8080"
  file_lacks portal/conf/conf.d/gitlab.conf '8929' "gitlab vhost 不再用 8929"
  file_has   portal/conf/conf.d/gitlab.conf 'gitlab:8080' "gitlab upstream 8080"
  file_has   portal/conf/stream-conf.d/gitlab.conf 'listen 2222' "gitlab ssh stream listen 2222"
  file_lacks portal/conf/stream-conf.d/gitlab.conf '2224' "gitlab ssh stream 不再用 2224"
  file_lacks portal/docker-compose.yml '"8929:8929"' "portal compose 不再发布 8929"
  file_has   portal/docker-compose.yml '"2222:2222"' "portal compose 发布 2222"
  file_lacks portal/docker-compose.yml '"2224:2224"' "portal compose 不再发布 2224"
  file_has   devops/docker-compose.yml "external_url 'http://gitlab.glseven.local:8080'" "GitLab external_url 8080"
  file_has   devops/docker-compose.yml "gitlab_shell_ssh_port'] = 2222" "GitLab ssh port 2222"
  file_has   devops/docker-compose.yml 'localhost:8080/-/readiness' "GitLab healthcheck 8080"
  file_lacks devops/docker-compose.yml '8929' "GitLab compose 不再用 8929"
}

check_docs() {
  echo "docs:"
  file_lacks portal/html/index.html '8929' "门户页不再有 8929"
  file_has   portal/html/index.html 'data-host="gitlab" data-port="8080"' "GitLab 卡片 8080"
  file_lacks README.md ':8000' "README 不再有 :8000"
  file_lacks README.md ':8929' "README 不再有 :8929"
  file_lacks CLAUDE.md ':8000' "CLAUDE.md 不再有 :8000"
  file_lacks CLAUDE.md ':8929' "CLAUDE.md 不再有 :8929"
  file_lacks docs/runbooks/sit-cicd-bootstrap.md '8929' "runbook 不再有 8929"
  file_lacks docs/runbooks/sit-cicd-bootstrap.md '2224' "runbook 不再有 2224"
}

check_ci() {
  echo "ci:"
  file_lacks ci/smoke-test.sh ':8000' "smoke-test 不再探 8000"
  file_lacks ci/smoke-test.sh ':8929' "smoke-test 不再探 8929"
  file_lacks ci/scripts/test-devops-domain.sh '8929' "test-devops-domain 不再断言 8929"
  file_lacks ci/scripts/test-devops-domain.sh '2224' "test-devops-domain 不再断言 2224"
  file_lacks ci/scripts/test-deploy-sit.sh '8929' "test-deploy-sit 不再用 8929"
}

case "$group" in
  portal) check_portal ;;
  gitlab) check_gitlab ;;
  docs)   check_docs ;;
  ci)     check_ci ;;
  all)    check_portal; check_gitlab; check_docs; check_ci ;;
  *) echo "usage: $0 [portal|gitlab|docs|ci|all]" >&2; exit 2 ;;
esac

if [[ "$fail" -gt 0 ]]; then
  echo "default-ports: $fail 项失败"
  exit 1
fi
echo "default-ports: OK"
```

- [ ] **Step 2: 运行 portal 组，确认失败**

Run: `bash ci/scripts/test-default-ports.sh portal`
Expected: 至少 `portal vhost 不再 listen 8000`、`healthcheck 探 8080` 等项 FAIL，exit 1。

- [ ] **Step 3: 改 `portal/docker-compose.yml`**

删除 `- "8000:8000"` 行；`8080` 行注释改为「http：共享入口（门户 + GitLab + adminer/php-ldap-admin/keycloak/nacos/xxl-job-admin/open-webui）」；healthcheck 从 `/dev/tcp/127.0.0.1/8000` 改为 `/dev/tcp/127.0.0.1/8080`，注释同步。

- [ ] **Step 4: 改 `portal/conf/conf.d/portal.conf`**

首行注释改为「静态门户（nginx 自身）：经 8080 共享入口，按 server_name 分流」。第一个 server 块：`listen 8000 default_server;` → `listen 8080;`（default_server 由 `00-default-catchall.conf` 保留），`return 301 http://portal.glseven.local:8080$request_uri;`。第二个 server 块：`listen 8000;` → `listen 8080;`。

- [ ] **Step 5: 改 `portal/conf/conf.d/00-default-catchall.conf`**

三条 302 的目标全部从 `http://portal.glseven.local:8000/` 改为 `http://portal.glseven.local:8080/`。

- [ ] **Step 6: 运行 portal 组，确认通过**

Run: `bash ci/scripts/test-default-ports.sh portal`
Expected: `default-ports: OK`，exit 0。

- [ ] **Step 7: compose 渲染校验（有 Docker 时）**

Run: `docker compose --env-file .env.local -f portal/docker-compose.yml config -q`
Expected: 无输出、exit 0（需要 `.env.local`；没有则跳过并在提交信息中注明）。

- [ ] **Step 8: Commit**

```bash
git add ci/scripts/test-default-ports.sh portal/docker-compose.yml portal/conf/conf.d/portal.conf portal/conf/conf.d/00-default-catchall.conf
git commit -m "refactor(ports): 门户 8000 迁移至 8080 共享入口"
```

---

### Task 2: GitLab Web 8929→8080 与 SSH 2224→2222

**Files:**
- Modify: `portal/conf/conf.d/gitlab.conf`
- Modify: `portal/conf/stream-conf.d/gitlab.conf`
- Modify: `portal/docker-compose.yml`（第 31 行 `8929:8929`、第 58 行 `2224:2224`）
- Modify: `devops/docker-compose.yml`
- Modify: `portal/conf/snippets/proxy.conf:9`（仅注释）

**Interfaces:**
- Consumes: Task 1 的 `ci/scripts/test-default-ports.sh`。
- Produces: 无新接口；GitLab 对外地址变为 `http://gitlab.glseven.local:8080`、`ssh://git@gitlab.glseven.local:2222`。

- [ ] **Step 1: 运行 gitlab 组，确认失败**

Run: `bash ci/scripts/test-default-ports.sh gitlab`
Expected: 多项 FAIL（8929/2224 仍在），exit 1。

- [ ] **Step 2: 改 `portal/conf/conf.d/gitlab.conf`**

注释改为「容器内原生 8080」；`listen 8929;` → `listen 8080;`；`set $gitlab_web "gitlab:8929";` → `set $gitlab_web "gitlab:8080";`。

- [ ] **Step 3: 改 `portal/conf/stream-conf.d/gitlab.conf`**

`listen 2224;` → `listen 2222;`；上游保持 `gitlab:22`；注释中的端口同步。

- [ ] **Step 4: 改 `portal/docker-compose.yml`**

删除 `- "8929:8929"` 行；`- "2224:2224"` → `- "2222:2222"`，注释改为「stream → gitlab SSH（容器 22，宿主避开 fnOS sshd，用常用替代 2222）」。

- [ ] **Step 5: 改 `devops/docker-compose.yml`**

`external_url 'http://gitlab.glseven.local:8929'` → `'http://gitlab.glseven.local:8080'`；`gitlab_rails['gitlab_shell_ssh_port'] = 2224` → `= 2222`；healthcheck `http://localhost:8929/-/readiness` → `http://localhost:8080/-/readiness`；两处注释同步（external_url 带端口 → 容器内 nginx 监听 8080）。

- [ ] **Step 6: 改 `portal/conf/snippets/proxy.conf` 注释**

第 9 行注释中的 `:8929` → `:8080`（`X-Forwarded-Host` 逻辑不变）。

- [ ] **Step 7: 运行 gitlab 组，确认通过**

Run: `bash ci/scripts/test-default-ports.sh gitlab`
Expected: `default-ports: OK`。

- [ ] **Step 8: Commit**

```bash
git add portal/conf/conf.d/gitlab.conf portal/conf/stream-conf.d/gitlab.conf portal/docker-compose.yml devops/docker-compose.yml portal/conf/snippets/proxy.conf
git commit -m "refactor(ports): GitLab Web 8929 迁 8080、SSH 2224 迁 2222"
```

---

### Task 3: 门户卡片、README、CLAUDE.md 与 runbook

**Files:**
- Modify: `portal/html/index.html`
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/runbooks/sit-cicd-bootstrap.md`

**Interfaces:**
- Consumes: Task 1/2 的端口终态。
- Produces: 无。

- [ ] **Step 1: 运行 docs 组，确认失败**

Run: `bash ci/scripts/test-default-ports.sh docs`
Expected: 多项 FAIL，exit 1。

- [ ] **Step 2: 改 `portal/html/index.html`**

GitLab 卡片：`data-port="8929"` → `"8080"`，文字 `gitlab.glseven.local:8929` → `:8080`。副标题「端口 = 容器原生端口」改为「端口 = 容器原生端口（宿主冲突时用标准替代：门户与 GitLab 为 8080）」。

- [ ] **Step 3: 改 `README.md`**

- 快速开始：`open http://portal.glseven.local:8000` → `:8080`；`glseven.local:8000` → `:8080`。
- 端口总述：30 个端口 → 28 个；「8000 门户 + 12 个原生 http 监听 + 17 条 stream」→「8080 共享入口（门户 + GitLab + 6 个原生服务）+ 10 个原生 http 监听 + 17 条 stream」。
- 服务表：门户 URL → `:8080`；GitLab URL → `:8080`。
- GitLab 段落与「已知平台限制」：`gitlab.glseven.local:8929` → `:8080`。
- TCP 端口段落中的 2224 说明改为 2222（若该行列出 SSH 端口）。

- [ ] **Step 4: 改 `CLAUDE.md`**

- 第 12 行「30 个端口 = 8000 门户 + 12 个原生 HTTP 监听 + 17 条 stream」→「28 个端口 = 8080 共享入口 + 10 个原生 HTTP 监听 + 17 条 stream」。
- 第 58 行「发布 30 个端口」同改；核心规则补一句「门户与 GitLab 因 fnOS 占用 80，统一用 8080」。
- 第 86 行「共享 HTTP 端口（3000 / 8080 / 8081）」补 8080 承载门户/GitLab。
- 第 95 行平台限制：`gitlab.glseven.local:8929` → `:8080`。

- [ ] **Step 5: 改 `docs/runbooks/sit-cicd-bootstrap.md`**

所有 `8929` → `8080`（登录地址、Runner 注册 `--url http://gitlab:8080`、`config.toml` 的 `url`、readiness 探测、排障命令）；所有 `2224` → `2222`（SSH 克隆地址与验证）。迁移提示补一条：Runner `config.toml` 在数据目录中，需手动改 `url` 后重启 runner。

- [ ] **Step 6: 运行 docs 组，确认通过**

Run: `bash ci/scripts/test-default-ports.sh docs`
Expected: `default-ports: OK`。

- [ ] **Step 7: 一致性脚本**

Run: `bash common/check-consistency.sh --strict`
Expected: `consistency: OK`，exit 0（域名清单未变，只变端口）。

- [ ] **Step 8: Commit**

```bash
git add portal/html/index.html README.md CLAUDE.md docs/runbooks/sit-cicd-bootstrap.md
git commit -m "docs(ports): 同步门户/GitLab 8080 与 SSH 2222 的入口说明"
```

---

### Task 4: CI 脚本同步

**Files:**
- Modify: `ci/smoke-test.sh:38-39`
- Modify: `ci/scripts/test-devops-domain.sh:16-25`
- Modify: `ci/scripts/test-deploy-sit.sh:6`

**Interfaces:**
- Consumes: Task 1/2 的端口终态。
- Produces: 无。

- [ ] **Step 1: 运行 ci 组，确认失败**

Run: `bash ci/scripts/test-default-ports.sh ci`
Expected: 多项 FAIL，exit 1。

- [ ] **Step 2: 改 `ci/smoke-test.sh`**

`probe "http://127.0.0.1:8000/" "portal.glseven.local"` → `:8080`；`probe "http://127.0.0.1:8929/-/readiness" "gitlab.glseven.local"` → `:8080`。Nexus 的 8081 探测保持不动。

- [ ] **Step 3: 改 `ci/scripts/test-devops-domain.sh`**

`grep_file 'listen 8929;'` → `grep_file 'listen 8080;'`；`grep_file '"8929:8929"'` → `grep_file '"8080:8080"'`；`grep_file 'listen 2224;'` → `grep_file 'listen 2222;'`；`grep_file '"2224:2224"'` → `grep_file '"2222:2222"'`。

- [ ] **Step 4: 改 `ci/scripts/test-deploy-sit.sh`**

测试用 `CI_REPOSITORY_URL="http://gitlab-ci-token:x@gitlab:8929/g/p.git"` → `:8080`。

- [ ] **Step 5: 运行 ci 组与相关脚本，确认通过**

Run: `bash ci/scripts/test-default-ports.sh ci && bash ci/scripts/test-devops-domain.sh && bash ci/scripts/test-deploy-sit.sh`
Expected: 全部 OK，exit 0。

- [ ] **Step 6: Commit**

```bash
git add ci/smoke-test.sh ci/scripts/test-devops-domain.sh ci/scripts/test-deploy-sit.sh
git commit -m "test(ci): 端口断言同步 8080/2222"
```

---

### Task 5: 全量静态验证

**Files:** 无改动（仅验证）。

**Interfaces:**
- Consumes: Task 1-4 的全部改动。
- Produces: 验证结果。

- [ ] **Step 1: 全量断言**

Run: `bash ci/scripts/test-default-ports.sh all`
Expected: `default-ports: OK`。

- [ ] **Step 2: 七个 compose 文件渲染**

Run: `for f in */docker-compose.yml; do docker compose --env-file .env.local -f "$f" config -q; done`
Expected: 无输出、exit 0（需要 `.env.local`；没有则只跑 grep 断言并注明）。

- [ ] **Step 3: 全部 Bash 语法**

Run: `while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')`
Expected: 无输出、exit 0。

- [ ] **Step 4: 全量测试脚本**

Run: `for f in ci/scripts/test-*.sh; do echo "== $f"; bash "$f" || exit 1; done`
Expected: 全部通过（`test-default-ports.sh all` 也会被执行）。

- [ ] **Step 5: 一致性校验与空白检查**

Run: `bash common/check-consistency.sh --strict && git diff --check`
Expected: `consistency: OK`，exit 0。

- [ ] **Step 6: nginx 配置校验（有 Docker 时）**

Run: `docker exec nginx nginx -t`
Expected: `syntax is ok` / `test is successful`（需要容器在运行；不可用则跳过并注明）。

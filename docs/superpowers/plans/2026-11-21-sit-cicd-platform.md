# sit 统一 CI/CD 平台（Phase 1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有编排里加入 sit 专用的 devops 域（GitLab CE + GitLab Runner），并把 glseven-docker 的校验/部署/回滚/发布迁移到 GitLab CI，使 push `develop` 自动部署 sit 并跑 smoke test。

**Architecture:** 新增 `docker-compose-devops.yml`（`172.18.7.x`），由 `common/compose-list.sh` 的 profile 门控只在 `sit` 档案启动；portal（nginx）新增 `gitlab.glseven.local:8929` HTTP vhost 与 `2224` stream 转发，均用 Docker DNS 运行时解析，保证本机 `local` 不启动 GitLab 时 nginx 照常工作。Runner 用 docker executor，deploy 作业把宿主仓库与数据目录按**宿主同路径**挂进作业容器，执行 `startup.sh --profile sit` + `nginx -t/reload` + smoke test。CI 逻辑从 `.github/workflows` 迁移到 `.gitlab-ci.yml`，脚本目录从 `.github/scripts` 机械改名为 `ci/scripts`。

**Tech Stack:** Docker Compose v2、Bash（macOS Bash 3.2 兼容）、GitLab CE omnibus 容器、GitLab Runner（docker executor）、Nexus 3（Maven/npm/Docker 仓库）、nginx（portal）。

**Spec:** `docs/superpowers/specs/2026-11-21-sit-cicd-platform-design.md`

## Global Constraints

- YAML / nginx / 组件配置一律 2 空格缩进；Bash 用 `snake_case`，变量加引号，复用现有数组与函数。
- `container_name` 必须等于 `hostname`（门户 `portal → nginx` 是唯一例外）；服务互访只用服务名。
- 宿主端口只在 `docker-compose-portal.yml` 发布；单个服务不得写 `ports:`。
- 脚本保持 macOS 自带 Bash 3.2 兼容（不用关联数组、不用 `${var,,}` 等 4.x 特性）。
- 不提交任何凭据；`.env.*`、`.glseven-profile`、`portal/conf/conf.d/*.local.conf` 已被 gitignore。
- 提交信息用中文 + Conventional Commits 前缀（如 `feat(devops): ...`）。
- 关键常量（来自设计稿）：devops 域 `172.18.7.0/24`；`gitlab` = `172.18.7.1`、`gitlab-runner` = `172.18.7.2`；GitLab Web `8929`、Git SSH 宿主 `2224`；部署目录 `/vol1/1000/glseven-docker`；数据目录 `/vol1/1000/docker_volume`；宿主 admin uid `1000`；GitLab 容器内 git uid `998`。
- 任何 Compose 改动提交前必须通过：`docker compose --env-file .env.local -f <file> config -q`、`bash common/check-consistency.sh --strict`、`bash -n` 全部脚本。

## Review Focus

- **部署作业的挂载路径**：仓库与数据目录必须以宿主原路径挂进作业容器；错挂到 `/deploy` 会让 compose 相对路径挂载（`./portal/conf/...`）全部失效并触发全量重建。Task 4 的 dry-run 测试断言出现 `/vol1/1000/glseven-docker` 且不出现 `/deploy`。
- **local 档案不得启动 devops、nginx 不得因 gitlab 缺席起不来**：Task 3 的门控测试覆盖 `PROFILE=local` 为 false；Task 2 的测试断言两个 gitlab conf 都含 `resolver 127.0.0.11`；Task 6 在宿主机上实测 `--profile local` 仍能 `nginx -t`。
- **smoke test 不得把 302 当成功**：portal 的 8081 有 default_server 302 兜底，`curl -f` 不会因 3xx 失败。Task 4 的 smoke 脚本必须显式断言 HTTP 状态码等于 200。
- **devops 文件变更不得自动部署**：部署会重启 GitLab 本体并中断承载作业。Task 4 的测试断言 `.gitlab-ci.yml` 对 `docker-compose-devops.yml` 的 changes 规则为 `when: never`。
- **GitLab 外部域名在作业容器内可解析**：`CI_REPOSITORY_URL` 使用 `gitlab.glseven.local`，Runner 必须注入 `extra_hosts`；Task 6 用一次性容器验证解析，Task 4 的部署脚本用 `CI_REPOSITORY_URL` 而不是写死地址。
- **发布 tag 必须仍是 annotated tag**：Task 4 的 release 作业用 Tags API 的 `message` 参数创建 annotated tag；Task 6 用 `git cat-file -t` 验证。

---

## 文件结构（本计划涉及）

| 文件 | 责任 |
|---|---|
| `docker-compose-devops.yml` | devops 域：gitlab、gitlab-runner |
| `common/compose-list.sh` | 批次唯一数据源；新增 devops 列表与 sit 门控函数 |
| `startup.sh` / `shutdown.sh` | 启停 devops 批次；新增 GitLab 数据目录 |
| `docker-compose-portal.yml` | 发布 8929/2224 |
| `portal/conf/conf.d/gitlab.conf` | GitLab Web vhost（运行时解析） |
| `portal/conf/stream-conf.d/gitlab.conf` | Git 的 SSH 转发（运行时解析） |
| `portal/html/index.html` | GitLab 门户卡片 |
| `common/check-consistency.sh` | `gitlab-runner` 加入内部服务豁免 |
| `.gitlab-ci.yml` | validate / deploy:sit / deploy:sit:rollback / release |
| `ci/scripts/**` | 由 `.github/scripts/**` 改名；发布说明增加 GitLab 链接 |
| `ci/deploy-sit.sh` | sit 部署脚本（可 `DRY_RUN=1`） |
| `ci/smoke-test.sh` | 部署后健康与 HTTP 探测 |
| `ci/scripts/test-devops-domain.sh` | devops 域静态断言 |
| `ci/scripts/test-compose-list.sh` | 档案门控断言 |
| `ci/scripts/test-deploy-sit.sh` | 部署脚本 dry-run 断言 |
| `README.md` / `CLAUDE.md` / `AGENTS.md` | 入口、端口数、命令路径、CI 章节 |
| `docs/runbooks/sit-cicd-bootstrap.md` | 首次引导、备份、排障 |
| `.github/workflows/` | 最终删除（Task 7，GitLab 验证后） |

---

### Task 1: CI 脚本迁移与发布说明适配

**Files:**
- Rename: `.github/scripts/` → `ci/scripts/`（`git mv`）
- Modify: `ci/scripts/release-notes.sh`（新增 `--provider`）
- Modify: `ci/scripts/test-release-scripts.sh`（新增 GitLab provider 用例）
- Modify: `.github/workflows/ci.yml`（脚本路径与测试循环）
- Modify: `CLAUDE.md:31-35`、`AGENTS.md:15-16`（命令路径）

**Interfaces:**
- Produces: `ci/scripts/release-notes.sh` 支持 `--provider github|gitlab`（默认 `github`）与服务地址环境变量 `REPO_SERVER_URL`（回退 `GITHUB_SERVER_URL`，再回退 `https://github.com`）；GitHub provider 输出保持现状。
- Produces: 所有测试脚本路径固定为 `ci/scripts/test-*.sh`。

- [ ] **Step 1: 在 `.github/scripts/test-release-scripts.sh` 写失败用例**

在 `release-notes` 用例区追加（沿用文件内 `create_repo` / `assert_contains` 辅助函数的写法；若辅助函数名不同，按文件现有风格调整）：

```bash
# GitLab provider：链接路径带 /-/ 前缀
notes="$(REPO_SERVER_URL="https://gitlab.example" \
  bash "$RELEASE_NOTES" --from v0.1.0 --to v0.2.0 \
  --repository glseven/glseven-docker --provider gitlab)"
assert_contains "$notes" "https://gitlab.example/glseven/glseven-docker/-/commit/" \
  "gitlab provider commit link"
assert_contains "$notes" "https://gitlab.example/glseven/glseven-docker/-/compare/v0.1.0...v0.2.0" \
  "gitlab provider compare link"

# 未知 provider 必须报错
status=0
bash "$RELEASE_NOTES" --to v0.2.0 --repository x/y --provider svn >/dev/null 2>&1 || status=$?
assert_eq "$status" "2" "unknown provider exit code"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash .github/scripts/test-release-scripts.sh release-notes`
Expected: FAIL（`unknown argument: --provider` 或断言失败）

- [ ] **Step 3: 实现 `--provider`**

在 `release-notes.sh` 的参数循环增加：

```bash
    --provider)
      [[ $# -ge 2 && "$2" != --* ]] || { printf 'missing value for --provider\n' >&2; exit 2; }
      provider="$2"
      shift 2
      ;;
```

初始化 `provider="github"`，校验：

```bash
case "$provider" in
  github|gitlab) ;;
  *) printf 'unknown provider: %s\n' "$provider" >&2; exit 2 ;;
esac
```

把第 66-67 行替换为：

```bash
server="${REPO_SERVER_URL:-${GITHUB_SERVER_URL:-https://github.com}}"
server="${server%/}"
case "$provider" in
  github) commit_path="/commit/"; compare_path="/compare/"; commits_path="/commits/" ;;
  gitlab) commit_path="/-/commit/"; compare_path="/-/compare/"; commits_path="/-/commits/" ;;
esac
```

`awk` 调用增加 `-v commit_path="$commit_path" -v compare_path="$compare_path" -v commits_path="$commits_path"`，并把三处 URL 拼接改为：

```awk
commit_url = server "/" repo commit_path hash
compare_url = server "/" repo compare_path from "..." to
print "- [初始版本 " to "](" server "/" repo commits_path to ")"
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .github/scripts/test-release-scripts.sh release-notes`
Expected: PASS（`release-notes tests: OK`）

- [ ] **Step 5: 改名脚本目录并更新引用**

```bash
git mv .github/scripts ci/scripts
```

`.github/workflows/ci.yml` 中 5 处 `bash .github/scripts/test-*.sh` 改为循环执行全部测试（并删除五个单独的 Test 步骤）：

```yaml
      - name: Run script tests
        shell: bash
        run: |
          set -euo pipefail
          for test_script in ci/scripts/test-*.sh; do
            echo "Running $test_script"
            bash "$test_script"
          done
```

`CLAUDE.md` 与 `AGENTS.md` 中的 `.github/scripts/` 全部替换为 `ci/scripts/`。

- [ ] **Step 6: 全量验证**

```bash
for f in $(git ls-files '*.sh'); do bash -n "$f"; done
for t in ci/scripts/test-*.sh; do bash "$t"; done
git diff --check
```

Expected: 全部 OK。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "refactor(ci): 迁移脚本目录到 ci/scripts 并支持 GitLab 发布链接"
```

---

### Task 2: devops 域与门户入口

**Files:**
- Create: `docker-compose-devops.yml`
- Create: `portal/conf/conf.d/gitlab.conf`
- Create: `portal/conf/stream-conf.d/gitlab.conf`
- Modify: `docker-compose-portal.yml:29-57`（新增两个端口）
- Modify: `portal/html/index.html`（`nexus3` 卡片之后加 GitLab 卡片）
- Modify: `README.md:15`（hosts 清单加入 `gitlab.glseven.local`）
- Modify: `common/check-consistency.sh:45`（`INTERNAL_ONLY` 增加 `gitlab-runner`）
- Test: `ci/scripts/test-devops-domain.sh`（新建）

**Interfaces:**
- Produces: 服务名 `gitlab`（172.18.7.1，容器内监听 8929/22）、`gitlab-runner`（172.18.7.2，无宿主端口）。
- Produces: 门户入口 `http://gitlab.glseven.local:8929`、`ssh://git@gitlab.glseven.local:2224`。

- [ ] **Step 1: 写失败测试 `ci/scripts/test-devops-domain.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
grep_file() { grep -q "$1" "$ROOT/$2" || fail "$2 缺少 $1"; }

[ -f "$ROOT/docker-compose-devops.yml" ] || fail "缺少 docker-compose-devops.yml"
grep_file '^  gitlab:$' docker-compose-devops.yml
grep_file '^  gitlab-runner:$' docker-compose-devops.yml
grep_file 'ipv4_address: 172.18.7.1' docker-compose-devops.yml
grep_file 'ipv4_address: 172.18.7.2' docker-compose-devops.yml
grep_file 'container_name: gitlab$' docker-compose-devops.yml
grep_file 'container_name: gitlab-runner$' docker-compose-devops.yml

[ -f "$ROOT/portal/conf/conf.d/gitlab.conf" ] || fail "缺少 conf.d/gitlab.conf"
grep_file 'listen 8929;' portal/conf/conf.d/gitlab.conf
grep_file 'server_name gitlab.glseven.local;' portal/conf/conf.d/gitlab.conf
grep_file 'resolver 127.0.0.11' portal/conf/conf.d/gitlab.conf

[ -f "$ROOT/portal/conf/stream-conf.d/gitlab.conf" ] || fail "缺少 stream-conf.d/gitlab.conf"
grep_file 'listen 2224;' portal/conf/stream-conf.d/gitlab.conf
grep_file 'resolver 127.0.0.11' portal/conf/stream-conf.d/gitlab.conf

grep_file '"8929:8929"' docker-compose-portal.yml
grep_file '"2224:2224"' docker-compose-portal.yml
grep_file 'data-host="gitlab"' portal/html/index.html
grep_file 'gitlab.glseven.local' README.md
grep_file 'INTERNAL_ONLY="filebeat gitlab-runner"' common/check-consistency.sh

printf 'devops domain tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-devops-domain.sh`
Expected: FAIL `缺少 docker-compose-devops.yml`

- [ ] **Step 3: 创建 `docker-compose-devops.yml`**

```yaml
name: devops

networks:
  glseven:
    external: true

services:

  # Devops 172.18.7.x =====================================================================================

  gitlab:
    # 平台域：GitLab CE，仅 sit 档案启动（common/compose-list.sh 门控）。
    # external_url 带端口：容器内 nginx 监听 8929，经 portal 暴露为 gitlab.glseven.local:8929。
    # 裁剪项：关闭自带 registry（制品统一走 Nexus）、Prometheus、KAS、Pages；Puma/Sidekiq 减配。
    image: gitlab/gitlab-ce:18.5.1-ce.0
    container_name: gitlab
    hostname: gitlab
    restart: always
    shm_size: 256m
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://gitlab.glseven.local:8929'
        gitlab_rails['gitlab_shell_ssh_port'] = 2224
        gitlab_rails['time_zone'] = 'Asia/Shanghai'
        puma['worker_processes'] = 2
        sidekiq['concurrency'] = 5
        prometheus_monitoring['enable'] = false
        registry['enable'] = false
        gitlab_kas['enable'] = false
        gitlab_pages['enable'] = false
    volumes:
      - ${DOCKER_VOLUME:?DOCKER_VOLUME is required (set it in the active profile)}/gitlab/config:/etc/gitlab
      - ${DOCKER_VOLUME:?DOCKER_VOLUME is required (set it in the active profile)}/gitlab/logs:/var/log/gitlab
      - ${DOCKER_VOLUME:?DOCKER_VOLUME is required (set it in the active profile)}/gitlab/data:/var/opt/gitlab
    networks:
      glseven:
        ipv4_address: 172.18.7.1
    healthcheck:
      # 官方镜像自带 curl；/-/readiness 就绪返回 200，首次 reconfigure 较慢。
      test: ["CMD", "curl", "-f", "http://localhost:8929/-/readiness"]
      interval: 30s
      timeout: 10s
      retries: 20
      start_period: 300s

  gitlab-runner:
    # 只跑 docker executor 作业；注册与 config.toml 由 bootstrap 手工完成（见 runbook）。
    image: gitlab/gitlab-runner:v18.5.1
    container_name: gitlab-runner
    hostname: gitlab-runner
    restart: always
    volumes:
      - ${DOCKER_VOLUME:?DOCKER_VOLUME is required (set it in the active profile)}/gitlab-runner/config:/etc/gitlab-runner
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      glseven:
        ipv4_address: 172.18.7.2
```

> 实现时用 Docker Hub 当前稳定版固定 tag（`gitlab/gitlab-ce:<major>.<minor>.<patch>-ce.0`，runner 同 major），不要留 `latest`。

- [ ] **Step 4: 创建 portal 配置并接通入口**

`portal/conf/conf.d/gitlab.conf`：

```nginx
# GitLab Web（容器内原生端口 8929；仅 sit 档案启动，本机缺席时用运行时解析，nginx 不因上游缺失而启动失败）
server {
    listen 8929;
    server_name gitlab.glseven.local;
    resolver 127.0.0.11 valid=10s ipv6=off;
    set $gitlab_web "gitlab:8929";
    location / {
        proxy_pass http://$gitlab_web;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

`portal/conf/stream-conf.d/gitlab.conf`：

```nginx
# stream：GitLab SSH（宿主 2224 → 容器 22；仅 sit 启动，运行时解析）
server {
    listen 2224;
    resolver 127.0.0.11 valid=10s ipv6=off;
    set $gitlab_ssh "gitlab:22";
    proxy_pass $gitlab_ssh;
}
```

`docker-compose-portal.yml` 在 `"8000:8000"` 行后加：

```yaml
      - "8929:8929"    # http → gitlab（仅 sit；外部 URL 与容器内端口一致）
```

并在 stream 段（`"1905:1905"` 之前）加：

```yaml
      - "2224:2224"    # stream → gitlab SSH（容器 22，宿主避开 fnOS sshd）
```

同时更新该文件顶部注释的端口计数：http server 块 22 → 23，stream 16 条 → 17 条。

`portal/html/index.html` 在 nexus3 卡片后加：

```html
    <a class="card" data-host="gitlab" data-port="8929" href="#"><div class="name">GitLab</div><div class="desc">代码仓库与 CI/CD</div><div class="port">gitlab.glseven.local:8929</div></a>
```

`README.md:15` 的 hosts 清单中加入 `gitlab.glseven.local`。

`common/check-consistency.sh:45` 改为：

```bash
INTERNAL_ONLY="filebeat gitlab-runner"
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bash ci/scripts/test-devops-domain.sh`
Expected: PASS

- [ ] **Step 6: 静态校验**

```bash
docker compose --env-file .env.local -f docker-compose-devops.yml config -q
docker compose --env-file .env.local -f docker-compose-portal.yml config -q
bash common/check-consistency.sh --strict
```

Expected: 全部通过（`consistency: OK`）。

- [ ] **Step 7: 提交**

```bash
git add docker-compose-devops.yml docker-compose-portal.yml portal/conf/conf.d/gitlab.conf portal/conf/stream-conf.d/gitlab.conf portal/html/index.html README.md common/check-consistency.sh ci/scripts/test-devops-domain.sh
git commit -m "feat(devops): 新增 GitLab 与 Runner 域及门户入口"
```

---

### Task 3: sit 档案门控与数据目录

**Files:**
- Modify: `common/compose-list.sh:9-11`
- Modify: `startup.sh:98-110`（DIR_SPECS）与 `startup.sh:159-164`（DEFERRED 之后）
- Modify: `shutdown.sh:52-65`
- Test: `ci/scripts/test-compose-list.sh`（新建）

**Interfaces:**
- Produces: `COMPOSE_FILES_DEVOPS=(devops)`、`profile_includes_devops()`（`PROFILE=sit` 时为真）。
- Produces: `DIR_SPECS` 新增 `gitlab/{config,logs,data}`、`gitlab-runner/{config,cache}`。

- [ ] **Step 1: 写失败测试 `ci/scripts/test-compose-list.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common/compose-list.sh
source "$ROOT/common/compose-list.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "${COMPOSE_FILES_DEVOPS[*]}" = "devops" ] || fail "COMPOSE_FILES_DEVOPS 应为 (devops)"

( PROFILE=sit; profile_includes_devops ) || fail "sit 档案必须包含 devops"
( PROFILE=local; profile_includes_devops ) && fail "local 档案不得包含 devops"
( PROFILE=''; profile_includes_devops ) && fail "未选档案不得包含 devops"
( unset PROFILE; profile_includes_devops ) && fail "PROFILE 未设置不得包含 devops"

grep -q 'profile_includes_devops' "$ROOT/startup.sh" || fail "startup.sh 未使用门控函数"
grep -q 'profile_includes_devops' "$ROOT/shutdown.sh" || fail "shutdown.sh 未使用门控函数"
for dir in gitlab/config gitlab/logs gitlab/data gitlab-runner/config gitlab-runner/cache; do
  grep -q "\"$dir " "$ROOT/startup.sh" || fail "DIR_SPECS 缺少 $dir"
done

printf 'compose-list tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-compose-list.sh`
Expected: FAIL（`COMPOSE_FILES_DEVOPS` 未定义）

- [ ] **Step 3: 实现门控与目录**

`common/compose-list.sh` 增加：

```bash
# DEVOPS：sit 专用的 CI/CD 平台（GitLab + Runner），在 DEFERRED 之后、PORTAL 之前启动；
# local 档案不启动（GitLab 重，本机无需）。
COMPOSE_FILES_DEVOPS=(devops)

profile_includes_devops() {
  [ "${PROFILE:-}" = "sit" ]
}
```

`startup.sh` 在 DEFERRED 循环之后、portal 之前插入：

```bash
# 启动 sit 专用的 CI/CD 平台（GitLab + Runner）
if profile_includes_devops; then
  echo "Starting devops services..."
  for group in "${COMPOSE_FILES_DEVOPS[@]}"; do
    start_compose_group "$group" || { echo "Error: ${group} services failed to start"; exit 1; }
    echo "✓ ${group} services started"
  done
else
  echo "Skipping devops services (profile: $PROFILE)"
fi
```

`startup.sh` 的 `DIR_SPECS` 在 `"phpldapadmin/logs 82"` 后追加：

```bash
  "gitlab/config 0"
  "gitlab/logs 998"
  "gitlab/data 998"
  "gitlab-runner/config 0"
  "gitlab-runner/cache 0"
```

并把上方注释的 uid 依据补一句：`gitlab=998`。

`shutdown.sh` 替换停止调用为：

```bash
groups=("${COMPOSE_FILES_BASE[@]}" "${COMPOSE_FILES_DEFERRED[@]}")
profile_includes_devops && groups+=("${COMPOSE_FILES_DEVOPS[@]}")
groups+=("${COMPOSE_FILES_PORTAL[@]}")
stop_all "${groups[@]}"
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash ci/scripts/test-compose-list.sh`
Expected: PASS

- [ ] **Step 5: 全量静态验证**

```bash
for f in $(git ls-files '*.sh'); do bash -n "$f"; done
for t in ci/scripts/test-*.sh; do bash "$t"; done
```

Expected: 全部 OK。

- [ ] **Step 6: 提交**

```bash
git add common/compose-list.sh startup.sh shutdown.sh ci/scripts/test-compose-list.sh
git commit -m "feat(devops): 按 sit 档案门控启动并初始化数据目录"
```

---

### Task 4: GitLab 流水线与部署/smoke 脚本

**Files:**
- Create: `.gitlab-ci.yml`
- Create: `ci/deploy-sit.sh`
- Create: `ci/smoke-test.sh`
- Test: `ci/scripts/test-deploy-sit.sh`（新建）

**Interfaces:**
- Produces: `ci/deploy-sit.sh` 环境变量 `TARGET_SHA`（必填，回退 `CI_COMMIT_SHA`）、`DEPLOY_DIR`（默认 `/vol1/1000/glseven-docker`）、`DEPLOY_UID`（默认 `1000`）、`DRY_RUN=1` 只打印命令。
- Produces: `ci/smoke-test.sh` 环境变量 `SMOKE_TIMEOUT`（默认 180）、`CURL_IMAGE`（默认 `curlimages/curl:8.10.1`）。
- Produces: `.gitlab-ci.yml` 作业名 `validate`、`deploy:sit`、`deploy:sit:rollback`、`release`。

- [ ] **Step 1: 写失败测试 `ci/scripts/test-deploy-sit.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

out="$(TARGET_SHA=abc123 CI_REPOSITORY_URL="http://gitlab-ci-token:x@gitlab:8929/g/p.git" \
  DRY_RUN=1 bash "$ROOT/ci/deploy-sit.sh")"

for expected in \
  "git -C /vol1/1000/glseven-docker fetch" \
  "checkout -f abc123" \
  "chown -R 1000:1000 /vol1/1000/glseven-docker" \
  "startup.sh --profile sit" \
  "nginx -t" \
  "nginx -s reload" \
  "ci/smoke-test.sh"; do
  [[ "$out" == *"$expected"* ]] || fail "dry-run 缺少: $expected"
done

[[ "$out" != *"/deploy"* ]] || fail "不得使用 /deploy 挂载路径"

[ -f "$ROOT/.gitlab-ci.yml" ] || fail "缺少 .gitlab-ci.yml"
grep -q 'deploy:sit' "$ROOT/.gitlab-ci.yml" || fail "缺少 deploy:sit 作业"
grep -q 'deploy:sit:rollback' "$ROOT/.gitlab-ci.yml" || fail "缺少回滚作业"
grep -q 'docker-compose-devops.yml' "$ROOT/.gitlab-ci.yml" || fail "缺少 devops changes 规则"
grep -q 'when: never' "$ROOT/.gitlab-ci.yml" || fail "devops 变更必须 when: never"

printf 'deploy-sit tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-deploy-sit.sh`
Expected: FAIL（`ci/deploy-sit.sh` 不存在）

- [ ] **Step 3: 实现 `ci/deploy-sit.sh`**

```bash
#!/usr/bin/env bash
# sit 部署：把宿主仓库切到目标提交，重放编排并验证。
# 由 GitLab CI 的 deploy:sit / deploy:sit:rollback 调用；也支持 DRY_RUN=1 本地演练。
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/vol1/1000/glseven-docker}"
DEPLOY_UID="${DEPLOY_UID:-1000}"
TARGET_SHA="${TARGET_SHA:-${CI_COMMIT_SHA:-}}"
REPO_URL="${CI_REPOSITORY_URL:-}"
DRY_RUN="${DRY_RUN:-0}"

[[ -n "$TARGET_SHA" ]] || { echo "Error: TARGET_SHA (or CI_COMMIT_SHA) is required" >&2; exit 2; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -n "$REPO_URL" ]] || { echo "Error: CI_REPOSITORY_URL is required" >&2; exit 2; }
  run git -C "$DEPLOY_DIR" fetch --prune "$REPO_URL" \
    "+refs/heads/develop:refs/remotes/origin/develop" "+refs/tags/*:refs/tags/*"
  git -C "$DEPLOY_DIR" cat-file -e "$TARGET_SHA^{commit}" ||
    { echo "Error: $TARGET_SHA is not reachable from develop or tags" >&2; exit 1; }
  run git -C "$DEPLOY_DIR" checkout -f "$TARGET_SHA"
  run chown -R "$DEPLOY_UID:$DEPLOY_UID" "$DEPLOY_DIR"
else
  run git -C "$DEPLOY_DIR" fetch --prune "$REPO_URL" \
    "+refs/heads/develop:refs/remotes/origin/develop" "+refs/tags/*:refs/tags/*"
  run git -C "$DEPLOY_DIR" checkout -f "$TARGET_SHA"
  run chown -R "$DEPLOY_UID:$DEPLOY_UID" "$DEPLOY_DIR"
fi

run bash "$DEPLOY_DIR/startup.sh" --profile sit
run docker exec nginx nginx -t
run docker exec nginx nginx -s reload
run bash "$DEPLOY_DIR/ci/smoke-test.sh"
```

- [ ] **Step 4: 实现 `ci/smoke-test.sh`**

```bash
#!/usr/bin/env bash
# 部署后 smoke：容器健康 + nginx 配置 + 宿主发布端口的真实 HTTP 路径。
set -euo pipefail

SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
CURL_HOST="--network host"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

echo "Smoke: waiting for healthy containers (timeout ${SMOKE_TIMEOUT}s)..."
deadline=$((SECONDS + SMOKE_TIMEOUT))
while :; do
  unhealthy=""
  for c in $(docker ps --format '{{.Names}}'); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || true)"
    [ -z "$status" ] && continue
    [ "$status" = "healthy" ] || unhealthy="$unhealthy $c:$status"
  done
  [ -z "$unhealthy" ] && break
  [ "$SECONDS" -lt "$deadline" ] || fail "unhealthy containers:$unhealthy"
  sleep 5
done

echo "Smoke: nginx -t"
docker exec nginx nginx -t

probe() {
  local url="$1" host="$2"
  local code
  code="$(docker run --rm $CURL_HOST "$CURL_IMAGE" \
    -sS -o /dev/null -w '%{http_code}' -H "Host: $host" "$url")"
  [ "$code" = "200" ] || fail "$url -> HTTP $code (expected 200)"
  echo "  OK $url"
}

echo "Smoke: host-published endpoints"
probe "http://127.0.0.1:8000/" "portal.glseven.local"
probe "http://127.0.0.1:8929/-/readiness" "gitlab.glseven.local"

if docker run --rm $CURL_HOST "$CURL_IMAGE" \
  -sS -o /dev/null -w '%{http_code}' -H "Host: nexus3.glseven.local" \
  "http://127.0.0.1:8081/service/rest/v1/status" | grep -qx 200; then
  echo "  OK nexus3"
else
  echo "  WARN: Nexus 未就绪（不阻断）"
fi

echo "Smoke: OK"
```

- [ ] **Step 5: 创建 `.gitlab-ci.yml`**

```yaml
stages:
  - validate
  - deploy
  - release

default:
  image: docker:cli
  before_script:
    - apk add --no-cache bash git

workflow:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "develop"'
    - if: '$CI_COMMIT_BRANCH == "main"'
    - if: '$CI_PIPELINE_SOURCE == "web"'

validate:
  stage: validate
  script:
    - |
      set -euo pipefail
      while IFS= read -r -d '' file; do bash -n "$file"; done < <(git ls-files -z '*.sh')
    - |
      set -euo pipefail
      for test_script in ci/scripts/test-*.sh; do
        echo "Running $test_script"
        bash "$test_script"
      done
    - cp .env.local.example .env.local
    - |
      set -euo pipefail
      shopt -s nullglob
      files=(docker-compose-*.yml)
      [[ ${#files[@]} -gt 0 ]]
      for file in "${files[@]}"; do
        echo "Validating $file"
        docker compose --env-file .env.local -f "$file" config -q
      done
    - bash common/check-consistency.sh --strict
    - |
      set -euo pipefail
      empty_tree="$(git hash-object -t tree /dev/null)"
      if [ -n "${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}" ]; then
        git diff --check "$CI_MERGE_REQUEST_DIFF_BASE_SHA" HEAD
      elif [ -n "${CI_COMMIT_BEFORE_SHA:-}" ] &&
        ! printf '%s' "$CI_COMMIT_BEFORE_SHA" | grep -qx '0*' &&
        git cat-file -e "$CI_COMMIT_BEFORE_SHA^{commit}" 2>/dev/null; then
        git diff --check "$CI_COMMIT_BEFORE_SHA" HEAD
      else
        git diff --check "$empty_tree" HEAD
      fi

deploy:sit:
  stage: deploy
  needs: ["validate"]
  environment:
    name: sit
  resource_group: sit
  rules:
    # devops 本体变更会重启 GitLab/Runner 并中断作业，必须宿主手工部署
    - if: '$CI_COMMIT_BRANCH == "develop"'
      changes:
        - docker-compose-devops.yml
      when: never
    - if: '$CI_COMMIT_BRANCH == "develop"'
      when: on_success
  script:
    - bash ci/deploy-sit.sh

deploy:sit:rollback:
  stage: deploy
  needs: ["validate"]
  environment:
    name: sit
  resource_group: sit
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
      when: manual
  variables:
    TARGET_SHA: "$ROLLBACK_SHA"
  script:
    - |
      set -euo pipefail
      [ -n "${ROLLBACK_SHA:-}" ] || { echo "ROLLBACK_SHA is required" >&2; exit 2; }
      bash ci/deploy-sit.sh

release:
  stage: release
  needs: ["validate"]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  variables:
    GIT_DEPTH: "0"
    REPO_SERVER_URL: "$CI_SERVER_URL"
  script:
    - |
      set -euo pipefail
      output="$(bash ci/scripts/next-version.sh)"
      printf '%s\n' "$output"
      eval "$output"
      if [ "$release" != "true" ] || [ "$tag_on_head" = "true" ]; then
        echo "No releasable Conventional Commits; skipping release."
        exit 0
      fi
      bash ci/scripts/release-notes.sh \
        --from "$previous_tag" --to "$version" \
        --repository "$CI_PROJECT_PATH" --provider gitlab \
        > /tmp/release-notes.md
      RELEASE_TOKEN="${RELEASE_TOKEN:?RELEASE_TOKEN is required}"
      curl -fsS --request POST \
        --header "PRIVATE-TOKEN: $RELEASE_TOKEN" \
        --data-urlencode "tag_name=$version" \
        --data-urlencode "ref=$CI_COMMIT_SHA" \
        --data-urlencode "message=$version" \
        "$CI_API_V4_URL/projects/$CI_PROJECT_ID/repository/tags" >/dev/null
      curl -fsS --request POST \
        --header "PRIVATE-TOKEN: $RELEASE_TOKEN" \
        --data-urlencode "name=$version" \
        --data-urlencode "tag_name=$version" \
        --data-urlencode "description@/tmp/release-notes.md" \
        "$CI_API_V4_URL/projects/$CI_PROJECT_ID/releases" >/dev/null
      echo "Released $version"
```

> 实现时把 `docker:cli` 固定到当前稳定 tag（查询 Docker Hub），与仓库其余镜像的固定 tag 习惯一致。

- [ ] **Step 6: 运行测试与解析检查**

```bash
bash ci/scripts/test-deploy-sit.sh
for f in ci/deploy-sit.sh ci/smoke-test.sh; do bash -n "$f"; done
docker run --rm docker:cli docker compose version
docker run --rm -v "$PWD:/w" mikefarah/yq:4 e '.stages' /w/.gitlab-ci.yml
```

Expected: 测试 PASS；`docker compose version` 输出 v2.x（若镜像不含 compose 插件，在 `before_script` 增加安装）；yq 输出 `- validate`、`- deploy`、`- release`。

- [ ] **Step 7: 提交**

```bash
git add .gitlab-ci.yml ci/deploy-sit.sh ci/smoke-test.sh ci/scripts/test-deploy-sit.sh
git commit -m "feat(ci): 新增 GitLab 流水线与 sit 部署/烟测脚本"
```

---

### Task 5: 文档与 runbook

**Files:**
- Modify: `README.md`（入口表、hosts、端口数、已知限制、CI 说明）
- Modify: `CLAUDE.md`（常用命令、架构要点、CI 与发布章节）
- Modify: `AGENTS.md`（结构、命令）
- Create: `docs/runbooks/sit-cicd-bootstrap.md`

**Interfaces:**
- Produces: runbook 覆盖 bootstrap、备份、排障、迁移切换清单，供 Task 6/7 执行。

- [ ] **Step 1: 更新 README**

- 服务入口表加一行：`GitLab | http://gitlab.glseven.local:8929 | 代码仓库与 CI/CD（仅 sit）`。
- 端口描述从 28 改为 30：`8000 门户 + 12 个原生 http 监听 + 17 条 stream`。
- 「已知平台限制」加一条：GitLab/Runner 仅 `sit` 档案启动；本机 `local` 访问 `gitlab.glseven.local:8929` 会 502，属预期。
- 新增「sit CI/CD」小节，指向 runbook 与 `.gitlab-ci.yml`。

- [ ] **Step 2: 更新 CLAUDE.md / AGENTS.md**

- 常用命令中的测试脚本路径改为 `ci/scripts/`。
- 架构要点补一句：devops 域（`docker-compose-devops.yml`）由 `common/compose-list.sh` 的 `profile_includes_devops` 门控，仅 sit 启动。
- CI 与发布章节改写：GitHub Actions → GitLab CI（validate / deploy:sit / rollback / release）；GitHub 仅作 push mirror。
- AGENTS.md 的域清单从六个补为七个（含 devops），命令路径同步。

- [ ] **Step 3: 写 runbook `docs/runbooks/sit-cicd-bootstrap.md`**

至少包含：

1. 前置：`/vol1/1000/glseven-docker` 手工 `git pull`；`sudo bash startup.sh --profile sit`；等 `docker inspect -f '{{.State.Health.Status}}' gitlab` 为 healthy。
2. 初始 root 密码：`docker exec gitlab cat /etc/gitlab/initial_root_password`，登录后立即修改。
3. Runner：GitLab 管理区创建实例 Runner（tag `sit`），注册命令：
   ```bash
   docker exec gitlab-runner gitlab-runner register \
     --non-interactive --url http://gitlab:8929 --token <glrt-...> \
     --executor docker --docker-image docker:cli --tag-list sit
   ```
   然后编辑 `config.toml`：`concurrent = 1`、`network_mode = "glseven"`、`extra_hosts = ["gitlab.glseven.local:172.18.7.1"]`、volumes 含 `/var/run/docker.sock`、`/vol1/1000/glseven-docker:/vol1/1000/glseven-docker`、`/vol1/1000/docker_volume:/vol1/1000/docker_volume`、缓存目录；`docker restart gitlab-runner`。
4. Nexus：确认 Maven 仓库；新建 `npm-hosted`/`npm-proxy`/`npm-group`、`docker-hosted`（HTTP 5000）。
5. 宿主 daemon：`/etc/docker/daemon.json` 增加 `"insecure-registries": ["192.168.31.100:5000"]`，重启 docker；验证 `docker pull 192.168.31.100:5000/docker-hosted/<测试镜像>`。
6. 迁移：建组 `glseven`、项目 `glseven-docker`；本地/服务器 push 全部分支与 tag；GitLab push mirror → GitHub（PAT）；本地 `origin` 切到 GitLab，GitHub 改名 `backup`。
7. 验证：一次文档提交到 develop，确认 `validate → deploy:sit → smoke` 全绿；`git -C /vol1/1000/glseven-docker cat-file -t <version>` 为 `tag`（annotated）；`docker stats` 记录内存。
8. 回滚演练：web 触发 `deploy:sit:rollback`，`ROLLBACK_SHA` 指向上一个提交，smoke 通过。
9. 备份：`docker exec gitlab gitlab-backup create` + 备份 `gitlab/config`（`gitlab-secrets.json`）。
10. 排障：作业解析不到 `gitlab.glseven.local`、挂载路径错误、内存不足、runner 离线。

- [ ] **Step 4: 验证文档一致性**

```bash
bash common/check-consistency.sh --strict
for t in ci/scripts/test-*.sh; do bash "$t"; done
git diff --check
```

Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add README.md CLAUDE.md AGENTS.md docs/runbooks/sit-cicd-bootstrap.md
git commit -m "docs: 补充 GitLab CI/CD 平台说明与 bootstrap runbook"
```

---

### Task 6: sit 运行时 bootstrap 与验收（人工，需 sudo 与 GitLab UI）

**Files:** 无代码改动；按 runbook 在 legion 上执行。

- [ ] **Step 1: 启动并确认 GitLab 就绪**

```bash
ssh legion 'cd /vol1/1000/glseven-docker && git pull --ff-only'
ssh legion 'cd /vol1/1000/glseven-docker && sudo bash startup.sh --profile sit'
ssh legion 'docker inspect -f "{{.State.Health.Status}}" gitlab'
```

Expected: `healthy`（首次可能 5-10 分钟）。

- [ ] **Step 2: 确认 local 档案不启动 devops 且门户正常（本机或任一 local 宿主）**

```bash
bash startup.sh --profile local
docker ps --format '{{.Names}}' | grep -E 'gitlab' && echo "ERROR: devops 不应启动"
docker exec nginx nginx -t
```

Expected: 无 gitlab 容器；`nginx -t` 通过。

- [ ] **Step 3: 按 runbook 完成 root 密码、Runner 注册、Nexus 仓库、insecure-registries**

验证：

```bash
ssh legion 'docker exec gitlab-runner gitlab-runner list'
ssh legion 'docker exec gitlab-runner getent hosts gitlab.glseven.local'
```

Expected: runner 已注册；域名解析到 `172.18.7.1`。

- [ ] **Step 4: 迁移仓库与镜像，跑通首条流水线**

推送一个文档提交到 GitLab 的 `develop`；在 GitLab 观察 `validate → deploy:sit`。

Expected: 两个作业通过；`environment: sit` 出现部署记录；smoke 输出 `Smoke: OK`。

- [ ] **Step 5: 验证部署结果与资源**

```bash
ssh legion 'docker inspect -f "{{.State.Health.Status}}" gitlab mysql nginx'
ssh legion 'sudo docker stats --no-stream --format "{{.Name}} {{.MemUsage}}" | head -10'
ssh legion 'free -h'
```

Expected: 全部 healthy；GitLab 常驻 ≤ 3.5 GiB；可用内存未触底、swap 无明显增长。

- [ ] **Step 6: 回滚演练与 annotated tag 验证**

在 GitLab web 触发 `deploy:sit:rollback`（`ROLLBACK_SHA`=上一个提交），确认 smoke 通过；在 `main` 推一次 `feat` 提交后确认 Release 创建，且 `git -C /vol1/1000/glseven-docker cat-file -t <version>` 输出 `tag`。

---

### Task 7: GitHub Actions 下线（前置：Task 6 全绿）

**Files:**
- Delete: `.github/workflows/ci.yml`、`.github/workflows/release.yml`
- Modify: `CLAUDE.md`（若仍有 GitHub Actions 描述）

- [ ] **Step 1: 确认 GitLab 流水线已接管**

Run: `ssh legion 'cd /vol1/1000/glseven-docker && git log --oneline -3'`
Expected: 最新提交由 GitLab 流水线部署成功（Task 6 Step 4/6 的记录）。

- [ ] **Step 2: 删除 GitHub workflows 并提交**

```bash
git rm .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "chore(ci): GitHub Actions 下线，流水线由 GitLab CI 接管"
```

- [ ] **Step 3: 验证仓库不再引用 GitHub Actions**

```bash
grep -rn '\.github/workflows' --include='*.md' --include='*.yml' . | grep -v docs/superpowers || true
```

Expected: 无输出（设计/计划文档中的历史引用除外）。

- [ ] **Step 4: 在 GitHub 仓库设置中关闭 Actions（人工）**

Expected: GitHub 侧不再对镜像推送运行任何工作流；仓库仅作只读镜像。

---

## 自检记录

- **Spec 覆盖**：devops 域（Task 2）、门控与目录（Task 3）、portal 入口（Task 2）、Nexus（Task 6）、流水线/回滚/发布（Task 4）、迁移与镜像（Task 6）、bootstrap（Task 5/6）、改动清单（Task 1-7 全覆盖）。
- **接口一致性**：`profile_includes_devops`、`COMPOSE_FILES_DEVOPS`、`TARGET_SHA`/`DEPLOY_DIR`/`DEPLOY_UID`、`SMOKE_TIMEOUT`/`CURL_IMAGE`、作业名在各任务间一致。
- **Review Focus 的测试归属**：挂载路径与 devops 规则 → Task 4 测试；local 不启动与解析器 → Task 2/3 测试；smoke 200 → Task 4 脚本；域名解析与 annotated tag → Task 6 验证。

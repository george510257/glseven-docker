# 设计：sit 统一 CI/CD 平台（GitLab + Runner + Nexus）

- **日期**：2026-11-21
- **状态**：待确认
- **范围**：Phase 1（平台 + glseven-docker 接入）；athena 等业务仓库为 Phase 2
- **已确认的决策**：平台分阶段接入；GitLab 主源 + GitHub 镜像；GitLab/Runner 作为同栈新 devops 域

## 1. 背景与目标

现状：

- CI 只在 GitHub Actions 里做静态校验（shell 语法、5 个脚本测试、compose 渲染、一致性、空白检查），main 上做语义化版本与 GitHub Release。
- **没有任何 CD**：sit 部署靠手工 `ssh legion` → `git pull` → `startup.sh --profile sit`，无记录、无回滚、失败不可见。
- athena 是 10 个独立仓库（4 个 Maven 后端、4 个 pnpm 前端、framework/shared 两个发布方、docs），私有构件目前依赖 GitHub Packages。
- GitHub 托管 runner 无法触达家庭内网（legion 192.168.31.100），这是「GitHub Actions 直接部署」走不通的硬约束。

目标：

1. 在 sit（legion）上立一套**统一 CI/CD 平台**：GitLab 存代码跑流水线、GitLab Runner 同机构建与部署、Nexus 当制品库（Maven 已有，补 npm 与 Docker）。
2. glseven-docker 首个接入：push `develop` → 校验 → 自动部署 sit → smoke test；失败可回滚、部署有记录。
3. 为 athena 的 Maven/npm 仓库留好流水线模板与制品通道（Phase 2 落地）。

失败标准（anti-goals）：

- 平台上线后部署仍需人工 ssh，等于没做。
- 为平台牺牲现有栈稳定性（内存挤爆、端口冲突、门户起不来）。
- GitHub 与 GitLab 两套流水线并存漂移。
- 平台自身无备份，legion 磁盘故障即全丢。

## 2. 非目标

- athena 各仓库的流水线与部署（Phase 2；本期只定义模板位与制品规范）。
- HTTPS/TLS、公网暴露、多用户权限体系。
- GitLab 自动备份/HA（只在 runbook 里给手工备份命令）。
- 飞书等外部通知（可选 Phase 2）。
- 现有 25 个服务的运行配置不改（仅 portal 增加 gitlab 的 vhost/stream 与两个宿主端口）。

## 3. 约束与已验证事实（2026-11-21 实测）

- legion：12 核、31 GiB 内存；**fnOS 自带 Elasticsearch 约占 11 GiB**，Logstash/Kibana 再约 3 GiB；`free` 可用约 6 GiB；swap 5 GiB（已用约 1 GiB）。
- 磁盘：`/vol1` 384 GiB，已用 234 GiB，**可用 149 GiB**。
- 现有栈已在 legion 运行：部署目录 `/vol1/1000/glseven-docker`，档案 `sit`，`DOCKER_VOLUME=/vol1/1000/docker_volume`。
- 宿主端口：80/443 被 fnOS 占用；5000 已分配给 Nexus registry（portal stream）；**8929、2224 空闲**。
- `admin` 用户不在 docker 组；部署目录的 git 仓库属主不是 admin（`dubious ownership`）。
- 所有镜像 tag 固定，无 `latest`；部署不需要考虑镜像漂移。
- `docker compose config -q` 为客户端解析，不需要 daemon（CI 校验作业无需 docker socket）。
- GitLab CE 提供 `/-/readiness` 就绪端点；首次启动的 root 密码在容器内 `/etc/gitlab/initial_root_password`。
- Nexus 已有 Web（8081）与 Docker registry 通道（portal stream 5000 → `nexus3:5000`）的编排，仓库本身是否已建需在实施时登录确认。
- compose 文件大量使用相对路径挂载（`./portal/conf/...`、`./prometheus/conf/...` 等），由 compose 客户端按文件所在目录解析后发给宿主 daemon——部署作业必须按宿主同路径挂载仓库，否则挂载失效并触发全量重建。
- `glseven` 网络内的 Docker DNS 只解析服务名，`gitlab.glseven.local` 在作业容器里需要 runner `extra_hosts` 注入。

## 4. 方案与取舍

### 4.1 平台落地：同栈新 devops 域（选定）

| 方案 | 取舍 |
|---|---|
| **同栈新 `docker-compose-devops.yml`** | 仓库仍是唯一来源，备份/门户/文档/启停时序一套体系；GitLab 重，需要 profile 门控 |
| 同机独立 compose（`/vol1/1000/ci/`，不入本仓） | CI 与栈解耦，但多一套手工维护的编排，违背单一来源 |
| fnOS 原生安装 GitLab | 少一层容器开销，但升级/备份/端口/账号全手工，与栈的运维方式割裂 |

选同栈：这是「sit 服务器做统一 CI/CD」最贴合现有仓库模型的形态。代价用门控与手动部署规则消化（§5.1、§5.6）。

### 4.2 源仓：GitLab 主源 + GitHub 推送镜像（选定）

| 方案 | 取舍 |
|---|---|
| **GitLab 主源 + GitHub push mirror** | 开发与流水线全在 GitLab；GitHub 保留异地只读备份；需一次性配置 PAT |
| 彻底迁到 GitLab | 少一层维护，但 legion 故障时没有异地副本 |
| 双仓并存 | 两套 CI 要同步维护，部署流水线跑镜像分支，容易漂移 |

GitHub Actions 随迁移停用：删除 `.github/workflows/`，CI/发布逻辑移植到 `.gitlab-ci.yml`（脚本都是 bash，可直接复用）。镜像推送由 GitLab 的 push mirror 负责，不要求 GitHub 侧再跑任何东西。

### 4.3 Runner：docker executor（选定）

- **docker executor**：构建与部署作业跑在一次性容器里；deploy 作业挂载 `docker.sock`、部署目录与缓存目录，用 `docker:cli` 镜像执行。隔离性较好，工具链随镜像固定。
- 未选 shell executor：作业直接跑在 Runner 容器里等同宿主级执行，且同样逃不掉对 docker.sock 的依赖；隔离性和可复现性都更差。
- 代价：部署时 `startup.sh` 的 preflight 在容器内降级（`sysctl`/`ip link`/`ss` 看不到宿主真值）。这些检查在首次手工部署时已在宿主上跑过，降级可接受；deploy 脚本另外显式做 `nginx -t` 与 smoke test 兜底。

### 4.4 部署方式：就地 checkout + `startup.sh`（本期选定）

glseven-docker 无构建产物，部署 = 把仓库切到目标 SHA 并重放编排。app 仓库（athena）Phase 2 才需要「构建镜像 → 推 Nexus → 部署」，模板另设计。

## 5. 设计

### 5.1 devops 域与启动时序

新增 `docker-compose-devops.yml`（`name: devops`，网络 `glseven` 外部，IP 段 `172.18.7.x`）：

| 服务 | 容器名/hostname | IP | 说明 |
|---|---|---|---|
| gitlab | gitlab | 172.18.7.1 | GitLab CE（omnibus） |
| gitlab-runner | gitlab-runner | 172.18.7.2 | GitLab Runner，docker executor |

批次调整（`common/compose-list.sh` 是唯一数据源）：

```
BASE → 等 MySQL healthy → DEFERRED → DEVOPS（仅 sit） → PORTAL
```

- `compose-list.sh` 增加 `COMPOSE_FILES_DEVOPS=(devops)` 与 `profile_includes_devops()`（`PROFILE=sit` 才为真）。
- `startup.sh` 在 DEFERRED 之后按门控启动 devops；`shutdown.sh` 把 devops 纳入逆序停止。
- devops 必须在 PORTAL 之前：portal 的 vhost 静态解析上游，GitLab 不先起会拖垮 nginx。
- 本机 `local` 不启动 devops；gitlab 的 HTTP vhost 与 stream 转发都使用 Docker DNS 运行时解析（`resolver 127.0.0.11` + 变量 `proxy_pass`），本机 nginx 不会因 GitLab 缺席而起不来。

### 5.2 端口与域名

| 用途 | 容器内端口 | 宿主端口（portal） | 访问 |
|---|---|---|---|
| GitLab Web | 8929 | 8929 | `http://gitlab.glseven.local:8929` |
| Git 的 SSH | 22 | 2224（stream） | `ssh://git@gitlab.glseven.local:2224/<group>/<project>.git` |
| Runner | 无 | 无 | 仅容器网络 |

- GitLab `external_url 'http://gitlab.glseven.local:8929'`；`gitlab_rails['gitlab_shell_ssh_port'] = 2224`。
- portal 新增 `conf.d/gitlab.conf`（listen 8929）与 `stream-conf.d/gitlab.conf`（listen 2224 → gitlab:22），两者均用运行时解析。
- portal 端口总数从 28 变为 30，README/CLAUDE.md 的描述同步更新。
- Git over HTTPS 也可用；SSH 端口是给标准 clone 流程留的，不需要时可不使用。

### 5.3 资源与裁剪

`GITLAB_OMNIBUS_CONFIG` 关键项：

```ruby
external_url 'http://gitlab.glseven.local:8929'
gitlab_rails['gitlab_shell_ssh_port'] = 2224
gitlab_rails['time_zone'] = 'Asia/Shanghai'
puma['worker_processes'] = 2
sidekiq['concurrency'] = 5
prometheus_monitoring['enable'] = false
registry['enable'] = false          # 制品统一走 Nexus
gitlab_kas['enable'] = false
gitlab_pages['enable'] = false
```

- Runner：`concurrent = 1`、`pull_policy = ["if-not-present"]`，避免并发构建叠加内存峰值。
- 目标：GitLab 常驻 ≤ 3.5 GiB，加 Runner 与单构建后仍留 ≥ 1 GiB 余量；以 `docker stats` 实测为准。
- 兜底顺序：先减小构建镜像内存（如 Maven `MAVEN_OPTS=-Xmx1g`），再调低 fnOS 自带 ES 堆（约 11 GiB → 6 GiB，可腾约 5 GiB），最后才考虑加内存。
- GitLab 首次启动（reconfigure）有明显资源峰值，bootstrap 时避免同时跑其它重活。

### 5.4 存储与目录

`startup.sh` 的 `DIR_SPECS` 增加（属主按容器实际 uid，首次实测校准）：

| 路径 | 属主 uid | 用途 |
|---|---|---|
| `gitlab/config` | 0 | `/etc/gitlab`（含 `gitlab.rb` 生成物、密钥） |
| `gitlab/logs` | 998 | `/var/log/gitlab` |
| `gitlab/data` | 998 | `/var/opt/gitlab`（仓库、数据库、制品元数据） |
| `gitlab-runner/config` | 0 | `config.toml` 与注册信息 |
| `gitlab-runner/cache` | 0 | Maven `~/.m2`、pnpm store 等构建缓存 |

- GitLab 官方镜像以 root 启动并在首次启动时自行修正内部属主；若实测某子目录权限不足，按镜像内 uid（git=998）调整。
- 所有数据落在 `/vol1`（149 GiB 可用），不进 git。
- 备份（runbook 提供命令，不自动化）：`docker exec gitlab gitlab-backup create` + 单独备份 `gitlab/config`（含 `gitlab-secrets.json`）。

### 5.5 Nexus 制品库

Phase 1 只做平台就绪，不接业务流水线：

- **Maven**：登录确认现有仓库（用户口径「Maven 服务有了」）；缺失则补 `maven-releases` / `maven-snapshots` / `maven-central` 代理 / 聚合组。
- **npm**：新建 `npm-hosted`（私有包，如 `@gls-athena-v2/auth-shared`）、`npm-proxy`（registry.npmjs.org）、`npm-group`（hosted + proxy）。
- **Docker**：新建 `docker-hosted`，绑定 HTTP 5000 连接器（portal 已预留 `5000 → nexus3:5000`）。
- 宿主 docker 需能免 TLS 访问该 registry：一次性在 `/etc/docker/daemon.json` 增加 `"insecure-registries": ["192.168.31.100:5000"]` 并重启 docker（写进 runbook；`preflight` 不代改 daemon.json）。
- 凭据（Nexus 用户、CI 变量 `NEXUS_USER` / `NEXUS_PASS`）在 Phase 2 接入业务流水线时创建。

### 5.6 glseven-docker 的 GitLab 流水线

新增 `.gitlab-ci.yml`，两个阶段：

**validate**（MR 与分支推送都跑；与现有 GitHub CI 等价）

1. `bash -n` 全部受跟踪脚本。
2. 5 个脚本测试（test-docker-volume / test-profile / test-startup-platform / test-release-scripts / test-env-config）。
3. `cp .env.local.example .env.local` 后对全部 `docker-compose-*.yml`（含 devops）执行 `docker compose config -q`。
4. `bash common/check-consistency.sh --strict`。
5. 变更行空白检查（MR 用 `CI_MERGE_REQUEST_DIFF_BASE_SHA`，分支推送用 `CI_COMMIT_BEFORE_SHA`）。
6. 作业镜像 `docker:cli`，`before_script` 安装 `bash git`；不需要 docker socket。

**deploy:sit**（仅 `develop` 分支推送自动执行）

1. `rules`：`develop` 推送且 validate 通过。改动 `docker-compose-devops.yml` 时不自动部署，也不提供手动作业——这类变更会重启 GitLab/Runner 本体，承载作业的容器随之中断，改由宿主侧手工执行（runbook 记录，与首次 bootstrap 同类）。
2. `environment: sit`，GitLab 记录每次部署的 SHA 与历史。
3. 路径约定（关键）：作业容器把宿主仓库与数据目录**按宿主同路径**挂载（`/vol1/1000/glseven-docker:/vol1/1000/glseven-docker`、`/vol1/1000/docker_volume:/vol1/1000/docker_volume`）。compose 的相对路径由 compose 客户端按文件所在目录解析后发给宿主 daemon——挂到 `/deploy` 会让 `./portal/conf/...` 等挂载全部失效并触发全量重建；同路径挂载同时保证 `DIR_SPECS`/preflight 的权限修复作用在宿主真实目录上。
4. 脚本 `ci/deploy-sit.sh`：
   ```bash
   cd /vol1/1000/glseven-docker
   git fetch --prune "$CI_REPOSITORY_URL" \
     "+refs/heads/develop:refs/remotes/origin/develop"
   git checkout -f "$CI_COMMIT_SHA"
   chown -R 1000:1000 /vol1/1000/glseven-docker   # 保持宿主 admin 可读可编辑
   bash /vol1/1000/glseven-docker/startup.sh --profile sit
   docker exec nginx nginx -t
   docker exec nginx nginx -s reload   # portal conf 是 bind mount，up -d 不会自动 reload
   bash /vol1/1000/glseven-docker/ci/smoke-test.sh
   ```
   fetch 用 `CI_REPOSITORY_URL`（内含作业令牌，不落盘）；宿主仓库的 `origin` 留给人工操作（指向 GitLab，用 admin 的 SSH key）。
5. smoke test（`ci/smoke-test.sh`）：
   - 作业容器运行在 `glseven` 网络，容器内 `127.0.0.1` 不是宿主；HTTP 探测统一用一次性 host-network 容器打宿主发布端口：`docker run --rm --network host <固定 tag 的 curl 镜像> -fsS ...`。
   - 探测项：门户 `http://127.0.0.1:8000/`（带 `Host: portal.glseven.local`）返回 200；GitLab `http://127.0.0.1:8929/-/readiness` 返回 200；Nexus `http://127.0.0.1:8081/service/rest/v1/status` 返回 200（未就绪仅告警，不阻断）。
   - 容器健康：全部带 healthcheck 的容器在超时内变为 `healthy`，失败时列出非 healthy 容器；`nginx -t` 通过。

**回滚**：手动作业 `deploy:sit:rollback`，变量 `ROLLBACK_SHA`（或 tag），用 `git fetch "$CI_REPOSITORY_URL" "$ROLLBACK_SHA"` 取目标提交后复用同一部署脚本与 smoke test；部署历史在 GitLab environment 里可查。回滚目标若改动了 `docker-compose-devops.yml`，同样只能走宿主手工部署。

**发布**：`main` 推送触发 `release` 作业——`next-version.sh` 计算版本、`release-notes.sh` 生成说明（需把 GitHub 专用的 `GITHUB_SERVER_URL` 改为可配置的服务地址）。沿用既有发布约定保留 **annotated tag**：作业用项目访问令牌（masked 变量 `RELEASE_TOKEN`，`api` + `write_repository`）调 GitLab Tags API 带 `message` 创建 annotated tag，再创建 Release；不依赖 `release:` 关键字自动生成轻量 tag。迁移前已有的 tag 没有对应 GitLab Release，属正常，不做回填。

### 5.7 仓库迁移与 GitHub 镜像

1. GitLab 建组 `glseven`，项目 `glseven-docker`（后续 athena 各仓库同组）。
2. 本地与 legion 的 clone 增加 GitLab remote，`git push --all` + `--tags` 完成首次迁移；把 GitLab 设为 `origin`，GitHub 改名 `backup`。
3. GitLab 项目设置 push mirror → GitHub（需 classic PAT，`repo` 权限）；只镜像受保护分支与 tag。
4. GitHub 侧 Actions 不再使用；`.github/workflows/` 删除，GitHub 仅作只读镜像。
5. `.github/scripts/` 机械重命名为 `ci/scripts/`（无行为变化），新增 `ci/deploy-sit.sh`、`ci/smoke-test.sh`、release-notes 适配；CLAUDE.md/AGENTS.md 的命令路径同步。

### 5.8 首次 bootstrap（手工一次，写入 runbook）

1. 在 legion 更新仓库到含 devops 域的提交（管理员手工 `git pull`），`sudo bash startup.sh --profile sit` 启动 GitLab。
2. 宿主一次性配置：`insecure-registries`（§5.5）、`usermod -aG docker admin`（可选，便于人工排查）。
3. 取初始 root 密码并改密：`docker exec gitlab cat /etc/gitlab/initial_root_password`。
4. 建组/项目、推送全部分支与 tag、配置 push mirror 到 GitHub。
5. 在 GitLab 创建 Runner，取认证 token，注册：
   ```bash
   docker exec gitlab-runner gitlab-runner register \
     --non-interactive --url http://gitlab:8929 --token <glrt-...> \
     --executor docker --docker-image docker:cli --tag-list sit
   ```
   并在 `config.toml` 写入：`concurrent = 1`；`network_mode = "glseven"`；`extra_hosts = ["gitlab.glseven.local:172.18.7.1"]`（作业容器内解析 GitLab 外部域名，`CI_REPOSITORY_URL` 才能连通）；volume 挂载 `/var/run/docker.sock:/var/run/docker.sock`、`/vol1/1000/glseven-docker:/vol1/1000/glseven-docker`、`/vol1/1000/docker_volume:/vol1/1000/docker_volume` 与缓存目录。
6. Nexus 建仓库（§5.5），记录管理员凭据。
7. 用一次无功能改动的提交（如文档）验证 `validate → deploy:sit → smoke test` 全链路。
8. 把本地开发 clone 的 `origin` 切到 GitLab。

### 5.9 改动清单

| 文件 | 改动 |
|---|---|
| `docker-compose-devops.yml` | 新增：gitlab、gitlab-runner（§5.1/5.3） |
| `common/compose-list.sh` | 新增 `COMPOSE_FILES_DEVOPS` 与 `profile_includes_devops()` |
| `startup.sh` | DEVOPS 批次（仅 sit）；`DIR_SPECS` 增加 5 个目录 |
| `shutdown.sh` | devops 纳入逆序停止 |
| `docker-compose-portal.yml` | 发布 `8929:8929`、`2224:2224` |
| `portal/conf/conf.d/gitlab.conf` | 新增：listen 8929，运行时解析上游 |
| `portal/conf/stream-conf.d/gitlab.conf` | 新增：listen 2224 → gitlab:22，运行时解析 |
| `portal/html/index.html` | GitLab 卡片（`data-host="gitlab"`） |
| `common/check-consistency.sh` | `INTERNAL_ONLY` 增加 `gitlab-runner` |
| `.gitlab-ci.yml` | 新增：validate / deploy:sit / rollback / release |
| `.github/workflows/` | 删除（GitHub 仅镜像） |
| `.github/scripts/` → `ci/scripts/` | 重命名；release-notes 适配 GitLab 链接 |
| `ci/deploy-sit.sh`、`ci/smoke-test.sh` | 新增 |
| 脚本测试（改名后） | 补充 devops 门控与 CI 路径的断言 |
| `README.md` | GitLab 入口、hosts 清单、端口数 30、sit 平台说明、已知限制 |
| `CLAUDE.md` / `AGENTS.md` | 命令路径、CI 章节、devops 域说明 |
| `docs/runbooks/sit-cicd-bootstrap.md` | 新增：bootstrap、备份、排障 |

## 6. 验证计划

静态（CI 与本地等价）：

1. `bash -n` 全部脚本；5 个脚本测试通过（含新增门控断言）。
2. 7 个 compose 文件在 `.env.local` 下 `config -q` 通过。
3. `check-consistency.sh --strict` 为 0（gitlab 的 vhost/卡片/hosts 齐全，gitlab-runner 豁免）。
4. 改动行 `git diff --check` 干净。

运行时（sit）：

5. `--profile local` 不启动 devops，门户正常；`--profile sit` 启动 gitlab + runner。
6. GitLab `/-/readiness` 200，Runner 在 GitLab 显示 online。
7. 推送一次改动到 develop：validate → deploy:sit → smoke test 全绿；GitLab environment 出现部署记录。
8. 手动回滚作业生效：把 SHA 指向上一个提交，smoke test 通过。
9. `docker stats` 记录平台常驻内存与 swap，确认未挤压既有服务。
10. 宿主 `docker pull 192.168.31.100:5000/docker-hosted/<测试镜像>` 成功（insecure-registry 生效）。

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 内存不足（可用 ~6 GiB） | 裁剪配置、并发 1、实测；不够则调低 fnOS ES 堆或加内存 |
| GitLab 首次 reconfigure 资源峰值 | bootstrap 期避免并跑构建；失败可重试 |
| 部署作业重启 GitLab 自身 | devops 文件变更不走 CI，宿主手工部署（runbook） |
| compose 相对路径挂载失效 | 仓库与数据目录按宿主同路径挂进作业容器 |
| 作业容器解析不了 GitLab 外部域名 | runner `extra_hosts` 注入 `gitlab.glseven.local → 172.18.7.1`；fetch 用 `CI_REPOSITORY_URL` |
| portal 因 GitLab 缺席起不来（local） | HTTP 与 stream 均用运行时解析 |
| preflight 在作业容器内降级 | 首次宿主手工部署已覆盖；deploy 脚本显式 `nginx -t` + smoke |
| 部署目录 git 属主/权限 | deploy 脚本 checkout 后 `chown -R 1000:1000 /deploy` |
| Nexus 仓库现状未知 | 实施前登录核对，缺什么补什么 |
| 平台单点（legion） | runbook 手工备份；GitHub 镜像保底代码 |
| Runner 持有 docker.sock | 私有仓库、单人使用；不接外部贡献者 |

## 8. Phase 2 概要（athena，不在本期实施）

- 10 个仓库迁入 GitLab `glseven` 组，分支模型沿用 develop/main。
- 后端：Maven verify → Jib 或 Dockerfile 构建镜像 → push `192.168.31.100:5000/docker-hosted/<service>:<sha>`；消费方 `settings.xml` 指向 Nexus Maven 组。
- 前端：pnpm build → nginx 静态镜像 → 同上 push；`athena-web-shared` 发布到 `npm-hosted`。
- 部署：athena 自带 compose（加入 `glseven` 网络），流水线在 runner 上 `docker compose up -d`；portal 增加 athena vhost（sit 版）。
- 发布顺序约束（framework → auth → system → codegen → gateway）用 GitLab 的 `needs`/手动门控或独立发布流水线表达。
- 部署仓库：建议单独建 `athena-deploy` 仓库放 compose 与环境模板，流水线按镜像 tag 部署；不把部署清单塞回各服务仓。
- Nacos 接入：sit 的 Nacos 已开启客户端 API 鉴权，athena 各服务需配置凭据；MySQL 表由 Flyway 启动时迁移。
- **资源前置**：4 个后端 JVM（`-Xmx512m`）+ 4 个前端 nginx 常驻约 2–2.5 GiB；叠加 GitLab/Runner 后超出当前约 6 GiB 余量，athena 上 sit 前必须先调低 fnOS 自带 ES 堆（腾约 5 GiB）或加内存。

## 9. 留给实施者的决定

- GitLab/Runner 的具体镜像 tag：实现时取 Docker Hub 当前稳定版并固定，runner 与 GitLab 大版本对齐。
- GitLab omnibus 裁剪参数微调（以实测内存为准，允许进一步关闭非必需组件）。
- Nexus 仓库命名（`npm-hosted` / `docker-hosted` 等）如与现有命名冲突，沿用现状。
- smoke test 的超时与容器清单（默认对全部带 healthcheck 的容器生效）。
- CI 作业镜像的具体选择（`docker:cli` 是否自带 compose 插件，实测后决定是否在 `before_script` 安装）。
- GitLab 备份的执行周期（runbook 给命令，暂不自动化）。
- smoke test 使用的 curl 镜像与固定 tag。
- 发布作业的 `RELEASE_TOKEN`（项目访问令牌）创建与轮换方式。

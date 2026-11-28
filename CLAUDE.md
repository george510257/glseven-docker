# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 本仓库是什么

纯配置编排仓库：7 个职能域、27 个容器（nginx 门户 + 26 个后端服务；devops 域仅 sit 档案启动），共用外部网络 `glseven`（172.18.0.0/16），数据绑定宿主目录。没有应用代码，也没有构建步骤。

改动几乎只落在 `<域>/docker-compose.yml`、`<域>/env/*.env`、`portal/conf/**`、`.gitlab-ci.yml`、`ci/**` 和各组件自身配置文件上。「测试」由三类组成：Compose 静态渲染、Bash 脚本测试、起环境后的实时探测。CI 跑前两类，因此本地提交前应执行同一组命令。

## 技能包

`skills/` 是供使用方项目消费的技能包（`glseven-env` 连接环境、`glseven-deploy` 部署项目），与 athena-skill 的 dev-flow 无关；格式与凭据泄漏由 `ci/scripts/test-skills.sh` 校验。修改技能后运行该脚本。

## 常用命令

```bash
cp .env.local.example .env.local   # local；sit 用 .env.sit.example → .env.sit
bash startup.sh --profile local [数据目录]  # 首次必须指定，之后沿用 .glseven-profile
bash shutdown.sh                           # 沿用上次档案；也可 --profile
```

单域操作（七个 compose 文件都声明 `networks.glseven.external: true`，网络必须先存在；devops 仅 sit 启动）：

```bash
docker network create --driver=bridge --subnet=172.18.0.0/16 glseven
docker compose --env-file .env.local -f apps/docker-compose.yml up -d <service>
docker compose --env-file .env.local -f apps/docker-compose.yml up -d --force-recreate <service>
```

本地校验（与 CI 等价，提交前跑）：

```bash
while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')
bash ci/scripts/test-docker-volume.sh
bash ci/scripts/test-profile.sh
bash ci/scripts/test-startup-platform.sh
bash ci/scripts/test-release-scripts.sh
bash ci/scripts/test-env-config.sh
for f in */docker-compose.yml; do docker compose --env-file .env.local -f "$f" config -q; done
bash common/check-consistency.sh --strict
git diff --check
```

`test-*.sh` 只需要 bash 与 git（发布脚本测试会在临时 git 仓库里造提交），无 Docker 也能跑；`compose config` 需要 Docker CLI 和当前档案（如 `.env.local`）。四个脚本都必须保持 macOS 自带 Bash 3.2 兼容。

运行时验证：

```bash
docker inspect -f '{{.State.Health.Status}}' <容器名>
docker exec nginx nginx -t
docker exec nginx nginx -s reload          # portal/conf 改动生效
curl -I http://<容器名>.glseven.local:<原生端口>
```

## 架构要点

**分层 Compose，不写跨 project 依赖。** 七个域包（`infra/`、`observability/`、`security/`、`platform/`、`apps/`、`devops/`、`portal/`）一域一个，compose 为 `<域>/docker-compose.yml`，各自是独立 Compose project，共用外部网络 `glseven`，每域占 `172.18.<域号>.x`。`depends_on` 只在单个文件内有效；跨域依赖被刻意省略，改由批次时序 + `restart: always` 兜底。

**`common/compose-list.sh` 是启动顺序的唯一数据源。** 它定义 `COMPOSE_FILES_BASE` / `_DEFERRED` / `_PORTAL` 与 Apple Silicon 的 observability 子集，`startup.sh`、`shutdown.sh` 共同消费。新增域只改这一个文件。时序：BASE（infra + observability）→ 等 MySQL healthy（120s 超时）→ DEFERRED（security + platform + apps）→ DEVOPS（仅 sit）→ PORTAL。

**nginx（portal）是唯一持有宿主端口的容器。** 发布 30 个端口 = 8000 门户 + 12 个原生 HTTP 监听 + 17 条 stream 透明转发；其余 26 个服务 `ports:` 一律为空。配置按容器拆分：HTTP vhost 在 `portal/conf/conf.d/<容器名>.conf`（每个有 HTTP 入口的容器一个，另有 `00-default-catchall.conf` 处理裸 IP 与共享端口兜底，`00-` 前缀不可去掉），TCP 在 `portal/conf/stream-conf.d/<容器名>.conf`（12 个文件覆盖 17 条 stream）。核心规则：**nginx 监听端口 = 容器原生端口**，客户端连接串零改动。

**stream 上游在启动期静态解析服务名**，所以 portal 必须最后一批启动；不要提前单独拉起 nginx，也不要把它从批次里拆出来。

**`startup.sh` 的职责比看起来多**：先 `source common/profile.sh` 选择档案（`--profile` > `.glseven-profile`），再 `source common/docker-volume.sh` 解析数据目录（优先级：位置参数 > 导出的 `DOCKER_VOLUME` > 当前档案 > 平台默认），再跑 `common/preflight.sh` 的 8 个幂等步骤，然后按 `DIR_SPECS` 表创建数据目录并按容器 uid chown、恢复 `chmod 755`（fnOS/trimacl 会把新目录剥成 000），最后按批次拉起。新增非 root 容器时在 `DIR_SPECS` 加一行即可。Apple Silicon 上自动跳过 `elk`/`filebeat` 并继续其余服务。

## 新增或改名服务：5 个同步点

1. 对应域的 `docker-compose-<域>.yml` 服务定义——`container_name` 必须等于 `hostname`（子域名 = 容器名的前提；不一致会被一致性脚本静默跳过，门户域名 `portal` → 容器 `nginx` 是唯一例外）
2. `portal/docker-compose.yml` 的 `ports:`（HTTP 与 stream 各一行，端口 = 容器原生端口）
3. `portal/conf/conf.d/<name>.conf` 和/或 `portal/conf/stream-conf.d/<name>.conf`
4. `portal/html/index.html` 卡片（`data-host="<name>"`；`apisix`、`elk` 有意不放卡片）
5. `README.md` 的 `/etc/hosts` 初始化清单

`common/check-consistency.sh` 机械校验这些同步点（含 `server_name` 反查容器、纯协议/内部服务豁免名单），漏改不会报配置错误，只会表现为「浏览器打不开」。它同时是 preflight 第 8 步（只告警）和 CI 的一步（`--strict` 阻断）。

## CI 与发布

- `.gitlab-ci.yml`：MR 与分支推送跑 `validate`（shell 语法、`ci/scripts/test-*.sh` 全量、`compose config --env-file .env.local`、`check-consistency --strict`、改动行空白检查）；push `develop` 自动 `deploy:sit`（改动 `devops/docker-compose.yml` 时跳过，需宿主手工部署）；手动 `deploy:sit:rollback` 回滚。
- `release` 作业在 push `main` 时由 `ci/scripts/next-version.sh` 按 Conventional Commits 计算版本，用 Tags API 创建 annotated tag 与中文 GitLab Release（notes 由 `release-notes.sh --provider gitlab` 生成）。GitHub 仓库仅作 push mirror，Actions 已下线。
- **提交类型直接决定发不发版**：`feat` → minor；`fix` / `perf` / `refactor` → patch；`<type>!:` 或正文 `BREAKING CHANGE:` → major；`docs` / `chore` / `ci` / `test` 等不触发发布。版本计算用 `git log --no-merges`：合并提交本身不计，但被合并分支上的提交计入。
- 分支模型：`develop` 集成，`main` 发布；PR 通常指向 `develop`。提交信息用中文 + conventional 前缀；PR 描述写清影响服务、可见变化和已做验证。

## 约定与坑

- **env 分层**：每服务一个 `<域>/env/<service>.env`，经 `env_file` 引用；含默认凭据的文件顶部有 `# WARNING:` 注释。**`env_file` 的值不被 Compose 插值**——凡需插值的（`${DOCKER_VOLUME}`、`${REDIS_PASSWORD}`）必须放在当前档案 `.env.<profile>`。既往踩坑记录见 `infra/env/kafka.env` 注释。`.env.*` 档案已 gitignore，preflight 会收紧为 600。
- **配置档案**：`.env.local` / `.env.sit` 承载机器相关值（`DOCKER_VOLUME`、`KAFKA_EXTERNAL_HOST`、`REDIS_PASSWORD`），由 `startup.sh --profile` 选择；直接跑 compose 必须带 `--env-file`。本机专属 vhost 用 `portal/conf/conf.d/*.local.conf`（gitignore，不参与一致性校验）。
- **服务互访一律走服务名**（Docker DNS），不硬编码 IP。固定 IP 仅用于宿主侧排查与防火墙放行。
- **共享 HTTP 端口**（3000 / 8080 / 8081）只绑定一次，按 `server_name` 分流；裸 IP 直连由 `00-default-catchall.conf` 302 到门户。
- **修改 `REDIS_PASSWORD`** 后需同时重建 `redis` 与 `moontv`（`REDIS_URL` 未做百分号编码，口令避免 `/ ? # % @ '` 和空格）。
- **healthcheck 探针必须匹配镜像实际具备的工具**（部分镜像无 curl/wget，apisix 与 nginx 用 `bash /dev/tcp`，etcd 无 shell 只能用 exec 形式）。compose 文件内的注释记录了每个探针的实测结论——改探针前先读。
- **YAML / nginx / 组件配置用 2 空格缩进；Bash 用 snake_case、变量加引号**，复用现有脚本里的数组与函数。
- **`docs/superpowers/specs/` 与 `docs/superpowers/plans/`** 保存了已确认的设计结论（nginx 统一入口、配置审计修复、CI 与语义化发布）。重新讨论某个设计选择前先查：若干「看起来更合理」的备选方案已被明确否决并记录了理由。
- `AGENTS.md` 是同一仓库的通用指南；细节与最新结论以 README 和本文件为准。

## 平台限制

以 `README.md` §「已知平台限制」为准，该节持续维护。要点：`sebp/elk` 仅 amd64，Apple Silicon 上启动即失败（`startup.sh` 自动跳过并继续其余服务）；Portainer 5 分钟未初始化会锁死，需重启容器取新 setup token；宿主 5000 端口（registry）与 macOS AirPlay Receiver 冲突；phpLDAPadmin 首次初始化后需导入一次 `security/openldap/bootstrap/admin-entry.ldif`。在新宿主上排查启动失败前，先读这一节。GitLab/Runner 仅 `sit` 档案启动，本机 `local` 访问 `gitlab.glseven.local:8929` 返回 502 属预期。

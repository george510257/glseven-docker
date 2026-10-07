# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 本仓库是什么

纯配置编排仓库：面向开发环境的微服务基础设施（6 个职能域、24 个容器），**没有应用代码、没有构建步骤、没有测试框架**。绝大多数改动落在 `docker-compose-*.yml`、`common/env/*.env`、`portal/conf/**` 或各组件自身配置文件上。产出物是「能跑起来的整套环境」，因此验证手段是静态配置校验 + 实时探测，而不是单元测试。

## 常用命令

```bash
cp .env.example .env          # 首次必需；为 DOCKER_VOLUME / REDIS_PASSWORD 插值提供来源
bash startup.sh [数据目录]     # 默认 /docker/glseven；Linux 上需 root/sudo
bash shutdown.sh              # 按启动批次逆序停止，并移除 glseven 网络
```

单域操作（六个 compose 文件均声明 `networks.glseven.external: true`，网络须先存在）：

```bash
docker network create --driver=bridge --subnet=172.18.0.0/16 glseven
docker compose -f docker-compose-apps.yml up -d <service>
docker compose -f docker-compose-apps.yml up -d --force-recreate <service>
```

验证手段（等价于本仓库的「测试」）：

```bash
docker compose -f docker-compose-<域>.yml config -q          # 静态校验
docker inspect -f '{{.State.Health.Status}}' <容器名>         # up 之后的健康状态
docker exec nginx nginx -t                                   # nginx 配置语法
docker exec nginx nginx -s reload                            # 使 portal/conf 改动生效
curl -I http://<容器名>.glseven.local:<原生端口>              # 经门户的端到端验证
```

`startup.sh` 首先执行 `common/preflight.sh`——7 个幂等前置步骤（目录权限、`.env`、`vm.max_map_count`、孤儿网桥、镜像代理拉取、发布端口占用、docker 日志轮转）。在 NAS/Linux 宿主上多数「起不来」属于 preflight 范畴，而非 compose 本身的问题。

## 架构要点

**分层 Compose，不写跨 project 依赖。** 六个文件（`infra`、`observability`、`security`、`platform`、`apps`、`portal`）一域一个，各自是独立 Compose project，共用外部网络 `glseven`（172.18.0.0/16），每域占 172.18.<域号>.x 段。`depends_on` 只在单个文件内有效；跨域依赖被刻意省略，改由批次时序 + `restart: always` 兜底。

**`common/compose-list.sh` 是启动顺序的唯一数据源。** 其中定义 `COMPOSE_FILES_BASE` / `_DEFERRED` / `_PORTAL`，startup.sh 与 shutdown.sh 共同消费。不要在别处硬编码域清单——新增域只改这一个文件。时序为：BASE（infra + observability）→ 等待 MySQL healthcheck 通过（startup.sh 内 120s 超时）→ DEFERRED（security + platform + apps）→ PORTAL。停止按拼接后的逆序执行。

**nginx（portal）是唯一持有宿主端口的容器。** 其余 23 个服务的 `ports:` 一律为空。其配置按容器拆分：HTTP 虚拟主机在 `portal/conf/conf.d/<容器名>.conf`，TCP 透传在 `portal/conf/stream-conf.d/<容器名>.conf`。核心规则是 **nginx 监听端口 = 容器原生端口**，使客户端连接串零改动。新增服务的正规路径是在 `docker-compose-portal.yml` 加 `ports:` 行并补 vhost / stream 配置文件，**绝不在服务自身写 `ports:`**。

**stream 上游为静态解析（启动期解析服务名）**，这正是 portal 必须最后一批启动的原因；不要单独提前拉起 nginx，也不要把它从批次里拆出来单独 `up`。

## 约定与坑

- **env 分层**：每服务一个 `common/env/<service>.env`，经 `env_file` 引用；含默认凭据的文件顶部有 `# WARNING:` 注释。**`env_file` 的值不被 Compose 插值**——凡需插值的（`${DOCKER_VOLUME}`、`${REDIS_PASSWORD}`）必须放在根目录 `.env`。此处既往踩坑记录见 `common/env/kafka.env` 注释。
- **服务互访一律走服务名**（Docker DNS），不硬编码固定 IP。固定 IP 仅用于宿主侧排查与防火墙放行。
- **共享 HTTP 端口**（3000 / 8080 / 8081）只绑定一次，按 `server_name`（Host 头）分流。`conf.d/00-default-catchall.conf` 将裸 IP 直连 302 到门户；`00-` 前缀不可去掉，否则 include 顺序错乱。
- **`common/env/common.env`** 被所有服务引用，目前只承载 `TZ=Asia/Shanghai`。
- **修改 `REDIS_PASSWORD`** 后需同时重建 `redis` 与 `moontv`。
- **healthcheck 探针必须匹配镜像实际具备的工具**（部分镜像无 curl/wget，apisix 与 nginx 改用 `bash /dev/tcp`）。compose 文件内的注释记录了每个探针的实测结论与时间——改探针前先读。
- **`docs/superpowers/specs/` 与 `docs/superpowers/plans/`** 保存了当前架构的设计确认结论（nginx 统一入口、配置审计修复）。重新讨论某个设计选择前先查阅：其中若干「看起来更合理」的备选方案已被明确否决并记录了理由。
- 提交信息为中文，遵循 conventional commit 前缀（`feat(portal):`、`fix(preflight):`、`docs(plan):`）。

## 平台限制

以 `README.md` §「已知平台限制」为准，该节持续维护。要点：`sebp/elk` 仅 amd64，Apple Silicon 上启动即失败；Portainer 启动后 5 分钟未初始化会锁死，需从 `docker logs` 取新的 setup token 重来；宿主 5000 端口（registry）与 macOS AirPlay Receiver 冲突；phpLDAPadmin 首次初始化后需导入一次 `openldap/bootstrap/admin-entry.ldif`。在新宿主上排查任何启动失败前，先读这一节。

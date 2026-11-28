# 设计：glseven 测试环境技能包（供使用方项目使用）

- **日期**：2026-11-28
- **状态**：已确认（2026-11-28）
- **首个使用方**：athena（10 个独立仓库：4 个后端 + 5 个前端 + 文档/工具仓）
- **相关文档**：[README](../../../README.md)、[sit CI/CD bootstrap](../runbooks/sit-cicd-bootstrap.md)、[双档案设计](2026-11-20-p0-dual-environment-design.md)

## 1. 背景与动机

`glseven-docker` 是测试环境的唯一事实源：服务目录、端点、凭据位置、网络模型和部署方式都定义在这个仓库里。但使用方项目（athena 是第一个）要用这套环境时，只能去翻整个仓库：

- 连接信息散落在 README、`*/env/*.env` 和 gitignored 的 `.env.<profile>` 里；哪些值在哪台机器上不同，没有面向使用方的说明。
- 部署完全没有既有路径：athena 目前只有 `.verify/docker-compose.yml`（MySQL + Redis）做本机验证，没有 Dockerfile、部署 compose 或部署流水线；而环境侧已经准备好的 Nexus registry、`glseven` 网络、portal 入口约定都没有写成使用方可以照做的步骤。
- 已知坑很多且都不是配置报错，而是「浏览器打不开」「连接超时」「401」这类难定位的现象：hosts 入口、Nacos 客户端鉴权、Redis 密码、Kafka 外部 listener、portal 共享端口按 `server_name` 分流、开发机 arm64 与 sit amd64 的镜像架构差异。

把这些知识做成技能包，让使用方项目里的 Claude Code 在本项目内就能拿到正确步骤和模板，是这个设计要解决的问题。

## 2. 目标

1. 使用方项目（首个 athena）能通过技能包知道如何连接测试环境的数据库与中间件（MySQL、Redis、Nacos 等），覆盖两种上下文：开发机上的进程，以及加入 `glseven` 网络的容器。
2. 使用方项目能按技能包把自身容器化并部署到 sit：构建镜像、推 Nexus、用 compose 加入 `glseven` 网络、增加 portal 入口、验证与回滚。
3. 技能包在本仓库内维护，与环境的端点/约定同版本；使用方通过符号链接接入，不复制内容。
4. SKILL.md 格式同时兼容 Claude Code 与 Athena Lite：frontmatter 仅 `name` + `description`，`name` 与目录名一致。
5. 包内提供可复用模板（Dockerfile、compose、portal vhost、CI、env 示例）和 athena 示例；技能文本不包含真实凭据。

## 3. 非目标

- 不在本仓库内纳入 athena 的 compose 或服务定义。遵守 [双档案设计](2026-11-20-p0-dual-environment-design.md) §2 的既定决定：「不把 athena 服务纳入本仓库；它与 `glseven` 网络的连接由 athena 项目自己负责」。
- 本次不实施 athena 的完整容器化与部署。技能包负责把步骤、模板和排障写清楚；用 athena 做首次实操验证属于后续任务。
- 不把 10 个 athena 仓库迁移到 sit GitLab，也不铺设多仓库流水线；只提供一份可选的 GitLab CI 模板。
- 不改变现有环境服务的启动方式、端口分配和配置语义。
- 不承诺使用方项目自动接入 Prometheus；filebeat 会自动采集容器日志，这一点在技能中说明即可。

## 4. 约束与已确认事实

- **凭据分层**：环境默认凭据在 `*/env/*.env`（文件头有 WARNING），机器相关值（sit 地址、`REDIS_PASSWORD` 等）只在 gitignored 的 `.env.local` / `.env.sit`。技能包只引用位置和变量名，不复制值。
- **portal 是唯一持有宿主端口的容器**：使用方容器不得发布宿主端口，统一经 portal 的 `resolver 127.0.0.11` + 变量上游代理。portal vhost 放 `portal/conf/conf.d/`，机器专属文件用 `*.local.conf`（已 gitignore，`common/check-consistency.sh` 跳过）。
- **共享 HTTP 端口**：3000 / 8080 / 8081 只绑定一次，按 `server_name` 分流；裸 IP 由 `00-default-catchall.conf` 302 到门户。athena 本机 vhost 的先例使用 `listen 8080`。
- **网络**：外部网络 `glseven`（172.18.0.0/16）；容器内互访走服务名；固定 IP 仅用于宿主侧排查。
- **架构差异**：开发机是 macOS arm64；sit（legion，192.168.31.100）是 amd64。使用方镜像必须以 `linux/amd64` 构建或推送；开发机推送前需把 `192.168.31.100:5000` 加入 Docker Desktop 的 `insecure-registries`，并用 Nexus 凭据 `docker login`。
- **部署机资源**：sit 上 GitLab/Runner 常驻约 3–3.5 GiB（runner 并发固定为 1），fnOS 自带 ES 约 11 GiB，`free` 可用约 6 GiB；athena 4 个后端（`-Xmx512m`）+ 前端预计 2–2.5 GiB，叠加后超出余量。athena 上 sit 前必须先调低 fnOS ES 堆（约 11 GiB → 6 GiB，腾约 5 GiB）或加内存；部署流程把 `free -h` / `docker stats` 作为硬性前置检查。
- **镜像命名**：Nexus Docker 托管仓库使用单段镜像名 `docker-hosted/<project>-<service>:<tag>`（如 `docker-hosted/athena-auth:2026-11-28`），与既有 sit 设计和 runbook 示例一致，避免多段路径在 Nexus 上的不确定性。
- **服务命名**：`glseven` 是共享网络，使用方的服务名/容器名/网络别名一律带项目前缀（如 `athena-auth`、`athena-web`），避免与其它项目的 `auth` / `web` 冲突导致 DNS 轮询到错误容器。
- **本仓库校验**：`ci/validate.sh` 会跑 shell 语法、`ci/scripts/test-*.sh`、compose 渲染、`check-consistency --strict` 和空白检查；新增脚本必须兼容 macOS Bash 3.2，且不依赖 Docker。
- **athena 事实**（来自其 CLAUDE.md 与运行验证报告）：
  - 4 个后端：gateway 8000/8001、auth 8080、system 8083、codegen 8082；5 个前端：main 5173、web-auth 5177/5178、web-codegen 5176、web-system 5179。
  - 后端配置已支持 `DB_URL` / `DB_USERNAME` / `DB_PASSWORD`、`REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD`、`NACOS_SERVER_ADDR` 等环境变量；网关路由源默认 `nacos`。
  - 构建依赖 GitHub Packages 私有构件（`.mvn/settings.xml` + PAT）；auth 必须先于 system 启动（system 启动时解析 auth 的 issuer URI）；codegen 的建表 DDL 不在 Flyway 目录，需手工执行。

## 5. 方案与取舍

### 5.1 技能包归属（选定 A）

| 方案 | 内容 | 取舍 |
|---|---|---|
| **A（选定）** | 技能包放本仓库 `skills/`，使用方在 `.claude/skills` 建符号链接 | 与环境配置同版本、单一事实源、不新增仓库；使用方机器上需要有 glseven-docker 的克隆 |
| B | 独立技能仓库（athena-skill 模式） | 分发更独立，但环境端点/凭据约定一变两边容易漂移，多维护一处 |
| C | 把使用方 compose 纳入本仓库，平台化部署 | 与「athena 不纳入本仓库」的既定决定冲突；环境仓库会变成多项目部署控制器 |

选 A 的理由：技能内容与环境事实强耦合，同仓同分支才能保证「环境改了、技能跟着改」；使用方本来就持有本仓库的克隆。

### 5.2 技能拆分（选定：两个技能 + 引用文件）

| 技能 | 回答的问题 |
|---|---|
| `glseven-env` | 怎么连、连哪里、用什么凭据、连不上怎么查 |
| `glseven-deploy` | 怎么把项目容器化并部署到 sit、怎么加入网络和 portal、怎么验证和回滚 |

不设入口技能：两个技能的 description 已能按意图触发，多一层路由只会增加一跳。`glseven-deploy` 引用 `glseven-env` 的端点矩阵，避免重复维护。

### 5.3 部署触发（选定：手动可重复，CI 模板备用）

| 方案 | 取舍 |
|---|---|
| **手动流程（选定）** | 开发机构建 jar/前端 → 构建 amd64 镜像 → 推 Nexus → ssh sit → `docker compose pull/up -d`。可重复、不依赖 athena 仓库迁移；缺点是每次手工执行 |
| GitLab CI | 与 glseven-docker 自身的 deploy 方式一致，但 athena 仓库在 GitHub，迁 GitLab 是另一件事；runner 内存紧张，10 个仓库同时铺开风险大 |

选手动流程：先让「连接 + 部署」这条链路跑通，CI 模板作为后续自动化入口写进技能，不要求本次启用。

## 6. 设计

### 6.1 目录结构

```text
skills/
├── glseven-env/
│   ├── SKILL.md
│   └── references/
│       ├── endpoints.md          # 端点矩阵：宿主入口 / 容器网络入口 / 凭据位置 / 备注
│       ├── connect-recipes.md    # 常用客户端与 athena 环境变量配方
│       └── troubleshooting.md    # 典型故障与定位顺序
└── glseven-deploy/
    ├── SKILL.md
    └── references/
        ├── deploy-flow.md        # 手动部署步骤、检查点、回滚
        ├── athena.md             # 首个使用方的完整示例
        └── templates/
            ├── Dockerfile.java
            ├── Dockerfile.web
            ├── nginx.web.conf
            ├── docker-compose.project.yml
            ├── portal-project.conf
            ├── gitlab-ci.project.yml
            └── env.project.example
```

模板中的项目名、服务名、端口、域名全部用 `<project>` / `<service>` 占位符；`athena.md` 是填充后的实例，不作为模板的一部分被其他项目直接复制。

### 6.2 `glseven-env`

**定位**：回答「某个服务从当前上下文怎么连」。

SKILL.md 的内容骨架：

1. **先判断上下文**：开发机进程 vs 加入 `glseven` 网络的容器。两者地址不同：前者走宿主入口（local `127.0.0.1` / sit `192.168.31.100` 的宿主端口或域名），后者走服务名 + 容器原生端口。
2. **环境标识**：local（本机 macOS）与 sit（legion）的差异；机器相关值只在 `.env.local` / `.env.sit`，不写进受跟踪配置。
3. **端点矩阵**（`references/endpoints.md`）：
   - 数据库/中间件：MySQL 3306、Redis 6379、Mongo 27017、RabbitMQ 5673（容器内 5672）、Kafka 外部 29092 / 容器内 9092、etcd 2379、Nacos 8848/9848、LDAP 389/636。
   - 控制台/UI：门户 8000、Adminer 8080、Nacos 8080、Nexus 8081、Kibana 5601、Grafana 3000、Prometheus 9090 等。
   - 每行标注：宿主入口（域名:端口）、容器网络入口（服务名:端口）、凭据位置、备注（如「仅容器网络内」「宿主不可用」）。
4. **凭据位置**：`infra/env/*.env`、`security/env/*.env`、`platform/env/*.env`、根 `.env.<profile>`；说明哪些是默认值、哪些是机器相关值，并提示不要提交。
5. **athena 配方**（`references/connect-recipes.md`）：
   - `DB_URL` / `DB_USERNAME` / `DB_PASSWORD`；宿主机与容器内两种 host 写法。
   - `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD`（环境启用了 `requirepass`）。
   - `NACOS_SERVER_ADDR` + 客户端用户名/密码（环境显式开启了客户端鉴权）；容器内写 `nacos:8848`，宿主写 `<host>:8848`。
   - `AUTH_ISSUER` / `AUTH_ISSUER_URI` / `AUTH_SERVICE_URI` 的取值思路：issuer 必须是解析 OIDC 元数据的后端服务可达的地址（如 `http://athena-auth:8080`）；浏览器是否需要访问取决于登录流程（athena 前端只用相对路径 `/oauth2/token`，不读 OIDC 元数据）。若选域名形式，用 `extra_hosts` 把域名指到 portal。
   - Kafka：容器内 `kafka:9092`，宿主一律 `29092`；不要用宿主 `9092`。
6. **排障**（`references/troubleshooting.md`）：`NOAUTH`、Nacos 401/403、Kafka 超时、MySQL `Access denied`、浏览器 302 到门户、`Unknown database`、Flyway 跳过 V1、hosts 未生效。每条给出「现象 → 先查什么 → 常见根因」。
7. **安全**：不把凭据写进代码或文档；使用环境变量或 gitignored 的 env 文件。

### 6.3 `glseven-deploy`

**定位**：回答「把一个项目部署到 sit」的完整路径。

SKILL.md 的内容骨架：

1. **适用前提**：项目已经能构建出可运行的产物（jar / 前端 dist）；sit 可 SSH（`ssh legion`）；Nexus registry 可用（`192.168.31.100:5000`，仓库 `docker-hosted`）；sit 宿主 Docker 已配置 insecure-registries（见 sit runbook §1.4）；开发机 Docker Desktop 也要把该地址加入 `insecure-registries` 并用 Nexus 凭据 `docker login`。若开发机无法推送，退化为在 sit 上构建（需先确认 GitHub Packages 凭据与内存余量）。
2. **部署模型**：
   - 每个使用方一个部署目录，建议 `/vol1/1000/projects/<project>/`，放 compose、env（600）和必要配置；不放进 glseven-docker。
   - 镜像推 Nexus：单段镜像名 `docker-hosted/<project>-<service>:<tag>`；开发机推 `localhost:5000/...`（local 档案）或 `192.168.31.100:5000/...`（sit）；sit 上可用 `localhost:5000`。
   - compose 加入外部网络 `glseven`，服务名/容器名/网络别名一律带项目前缀（`<project>-<service>`）；不发布宿主端口；`restart: always`；按项目自身依赖写 `depends_on` / 启动顺序。
   - portal 增加一个 `*.local.conf` vhost（机器专属、gitignored），用 `resolver` + 变量上游指向使用方 web 容器；`nginx -t` 后 reload。
3. **手动部署流程**（`references/deploy-flow.md`）：
   1. 构建后端 jar（开发机，带 GitHub Packages 凭据）。
   2. 构建镜像并推送：`docker buildx build --platform linux/amd64 --push ...`；前端静态产物同样打进 web 镜像。
   3. 先确认 sit 余量：`free -h`、`docker stats --no-stream`；可用不足 2.5–3 GiB 时先调低 fnOS 自带 ES 堆（约 11 → 6 GiB）或加内存，否则不要继续。随后准备部署目录与 `.env`（600），创建数据库/用户（Flyway 负责表结构；codegen 的 DDL 单独执行）。
   4. `docker compose pull && docker compose up -d`；观察健康状态与日志。
   5. 写 portal vhost、`nginx -t`、`nginx -s reload`；客户端 hosts/DNS 指向 sit。
   6. 验证：容器健康、登录 token、经门户的 API、Kibana 中容器日志。
   7. 回滚：镜像 tag 固定，保留上一版 compose；用上一版 tag `up -d`。
4. **athena 示例**（`references/athena.md`）：
   - 服务清单（均带 `athena-` 前缀）：`athena-auth` 8080、`athena-system` 8083、`athena-codegen` 8082、`athena-gateway` 8000/8001、`athena-web`（nginx，聚合 5 个前端 dist）。
   - 镜像命名（`docker-hosted/athena-auth:<tag>` 等）、构建命令、启动顺序（auth 先就绪 → system/codegen → gateway → web）。
   - issuer 用 `http://athena-auth:8080`（后端服务可达；前端走相对路径 `/oauth2/token`）；若用域名形式，`extra_hosts` 指到 portal。前端 `/api`、`/oauth2` 反代到 `athena-gateway:8000`。
   - Nacos 客户端凭据由环境维护者提供（控制台管理员 `nacos` 的密码在首次初始化时设置）；推荐为 athena 建独立用户，凭据放部署目录的 gitignored `.env`。Nacos 服务注册与网关路由；数据库初始化；验证 curl；回滚。
   - 现有本机 `portal/conf/conf.d/athena.local.conf` 的上游要从 `web:80` 改为 `athena-web:80`，issuer 说明同步更新。
5. **模板**（`references/templates/`）：
   - `Dockerfile.java`：`eclipse-temurin:21-jre`，非 root，复制 jar，JVM 参数与健康检查占位。
   - `Dockerfile.web`：nginx 提供多份 dist（qiankun 子应用按路径），反代 API 到网关。
   - `nginx.web.conf`：多份 dist 的路径规则与 `/api`、`/oauth2` 反代到网关。
   - `docker-compose.project.yml`：外部网络、服务名、env_file、无宿主端口、`extra_hosts` 占位。
   - `portal-project.conf`：`listen 8080`、`server_name <project>.glseven.local`、resolver + 变量上游、`snippets/proxy.conf`。
   - `gitlab-ci.project.yml`：build → docker buildx push → ssh deploy 的可选模板。
   - `env.project.example`：`DB_URL`、`DB_USERNAME`、`DB_PASSWORD`、`REDIS_*`、`NACOS_*` 占位。
6. **不要做**：不要在使用方 compose 里写宿主端口；不要给每个前端各起一个 nginx；不要把凭据提交到仓库；不要在 sit 上直接 `mvn` 构建多仓库（内存与凭据都不合适）。

### 6.4 使用方接入

- 在每个需要技能的使用方仓库根目录执行：`ln -s /path/to/glseven-docker/skills .claude/skills`（目录已存在时只软链两个技能目录）。
- 也可以放到 `~/.claude/skills` 做机器级安装，但团队共享场景推荐按仓库软链。
- 更新技能只需在 glseven-docker 里 `git pull`，使用方无需同步。

### 6.5 环境仓库内的配套改动

- `README.md`：新增「技能包（供其他项目使用）」一节，说明用途、接入命令、首个使用方 athena。
- `CLAUDE.md`：在「本仓库是什么」或「新增服务」附近补一句技能包位置与边界（只读指南 + 模板，不纳入使用方服务）。
- `ci/scripts/test-skills.sh`：新增校验，纳入 `ci/validate.sh` 的 `ci/scripts/test-*.sh` 循环：
  - 每个 `skills/*/SKILL.md` 存在，frontmatter 有 `name` 和 `description`；
  - `name` 与目录名一致，匹配 `^[a-z0-9-]+$`；
  - `glseven-deploy` 引用的模板文件存在；
  - 技能文本不含已知凭据字面量（如 `REDIS_PASSWORD` 的常见默认值、`NACOS_AUTH_TOKEN` 的实际值）；
  - 兼容 macOS Bash 3.2，不依赖 Docker。
- `common/check-consistency.sh` 不改：使用方 vhost 走 `*.local.conf`，已有跳过逻辑。
- `.gitignore` 不改：`skills/` 不在忽略范围。

### 6.6 安全

- 技能文本只用变量名和占位符，不出现真实密码/token。
- 部署目录的 `.env` 权限 600；不入库；不通过命令行参数传密码（避免 `ps`/history 泄露）。
- 使用方 compose 不发布宿主端口；只加入 `glseven` 网络。
- 镜像必须 `linux/amd64`；构建产物和基础镜像都按目标架构验证。
- 不把 `NACOS_AUTH_TOKEN` 等服务器端密钥复制给使用方；客户端只需要用户名/密码。
- filebeat 会自动采集容器日志，技能提醒不要在日志里打印凭据。

## 7. 验收

1. `skills/glseven-env` 和 `skills/glseven-deploy` 存在，frontmatter 合规；`bash ci/scripts/test-skills.sh` 通过；`ci/validate.sh` 的本地等价命令全绿。
2. 在 athena 任一仓库软链后，技能能被 Claude Code 识别；针对「怎么连 sit 的 MySQL/Redis/Nacos」和「怎么把 athena 部署到 sit」能给出与环境事实一致的步骤。
3. 模板自洽：compose 模板用示例 env 能通过 `docker compose config`（有 Docker CLI 时）；portal vhost 模板在 nginx 容器内 `nginx -t` 通过；Dockerfile 模板能构建一个最小镜像（有 Docker 时）；模板与 athena 示例中的镜像名、服务名符合「单段镜像名 + 项目前缀」约定。
4. README 的技能包章节足以让另一个项目完成接入。
5. 用 athena 做首次完整部署（后续任务）时，不需要再回来修改技能包的结构，只需补充细节。

## 8. 留给构建者决定的

- 两个 SKILL.md 的最终文案、触发词与 references 的详细程度。
- 模板的具体镜像版本、健康检查命令、JVM 参数；以项目实际技术栈为准。
- `athena.md` 中网关路由、issuer、qiankun 生产配置的精确写法（需对照 athena 仓库现状）。
- 是否增加一个 `scripts/` 辅助脚本（如渲染 vhost）；第一版默认不加。
- `glseven-deploy` 是否在 SKILL.md 内直接给出命令，还是全部放 references；以「主文件短、细节按需读取」为原则。

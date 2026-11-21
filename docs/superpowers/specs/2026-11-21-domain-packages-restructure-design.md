# 设计文档：按域分包重构（一域一包）

日期：2026-11-21

## 意图与背景

根目录现在混放三类东西：6 个 `docker-compose-<域>.yml`、11 个服务配置目录（`mysql/`、`grafana/`、`apisix/` …）、14 个 env 文件（`common/env/*.env`）。一个域的东西散在三个地方，「域」只存在于文件名里，不在目录结构里。

驱动原因（用户原话）：**根目录太乱，一个域的东西散在各处。**

目标：一个域的所有东西——compose 清单、该域 env、该域的服务配置——收在同一个目录；根目录只剩「域包 + 共享包 + 入口脚本与文档」。

## 目标 / 非目标 / 反目标

**目标**

- 六个域各成一个目录：`infra/`、`observability/`、`security/`、`platform/`、`apps/`、`portal/`。
- 服务专属 env 从 `common/env/` 分派到所属域的 `env/`；`common.env`（TZ）作为唯一共享 env 留在 `common/`。
- 域内相对路径自洽：域配置跟着 compose 走，`./mysql/...` 这类挂载写法保持不变或更短。
- 新增服务时只进对应域包（compose + env + 配置三件套在同一目录）。

**非目标**

- 不改任何服务定义：镜像、端口、固定 IP、网络、数据卷、healthcheck、env 内容一律不动。
- 不拆分或合并现有六个域。
- 不引入模板引擎、wrapper CLI、符号链接兼容层。
- 不重写历史设计文档（`docs/superpowers/specs|plans` 下的既有文件是记录性文档，保留原路径描述）。

**反目标**（做了就算失败）

- 任何容器重建后行为变化（密码、挂载、网络归属）。
- 旧的 compose 文件/配置目录以副本或符号链接形式残留在根目录。
- 脚本仍写死单个域的文件名，导致新增域要改多处。

## 约束

- 六个 compose 文件顶部已有 `name:`（`infra`、`apps` …），Compose project 名钉死；移动文件不改变容器名、project 标签、网络归属。
- 数据全部是 `${DOCKER_VOLUME:-/docker/glseven}` 下的 bind mount，无命名卷，移动目录不影响数据。
- Compose 的相对路径（bind mount 源、`env_file`）**相对 compose 文件所在目录**解析，因此配置目录必须与 compose 文件同包。
- 根 `.env` 是插值来源（`DOCKER_VOLUME`、`REDIS_PASSWORD`）。Compose 默认只在 project 目录（= compose 文件所在目录）找 `.env`；分包后根 `.env` 不会被自动读取。
- 脚本只依赖 docker / bash / grep 等必有工具（沿用 preflight 既有约束，不引入 yq/jq）。

## 方案

| 方案 | 内容 | 取舍 |
|---|---|---|
| **A（选用）** | 六个域包 + `common` 共享包，compose/env/配置全部进包 | 彻底解决「散在各处」；脚本、CI、文档需同步改 |
| B | 在 A 外再套一层 `domains/` | 根更空，但所有路径/命令多一级；域数量固定为 6，收益低 |
| C | 只把配置目录按域收拢，compose 文件留根 | 改动最小，但根目录仍散着 6 个 compose 文件，痛点只解决一半 |

选 A：用户的痛点是「一个域的东西散在各处」，compose 文件是域最核心的产物，留在根目录等于没解决。B 的额外嵌套没有对应收益。

## 目录终态

```
glseven-docker/
├── infra/
│   ├── docker-compose.yml
│   ├── env/                      # mysql mongo mongo-express rabbitmq kafka
│   ├── mysql/
│   └── rabbitmq/
├── observability/
│   ├── docker-compose.yml
│   ├── prometheus/
│   ├── grafana/
│   ├── filebeat/
│   └── elk/
├── security/
│   ├── docker-compose.yml
│   ├── env/                      # openldap phpldapadmin keycloak
│   └── openldap/
├── platform/
│   ├── docker-compose.yml
│   ├── env/                      # nacos
│   ├── nacos/
│   ├── xxl-job-admin/
│   └── apisix/
├── apps/
│   ├── docker-compose.yml
│   └── env/                      # ollama open-webui moontv iptv
├── portal/
│   ├── docker-compose.yml
│   ├── conf/
│   └── html/
├── common/
│   ├── compose-list.sh
│   ├── preflight.sh
│   ├── check-consistency.sh
│   └── env/common.env            # 唯一共享 env（TZ=Asia/Shanghai）
├── startup.sh
├── shutdown.sh
├── .env / .env.example
└── README.md  CLAUDE.md  AGENTS.md  docs/
```

说明：

- `observability/`、`portal/` 没有服务专属 env（只引用 `common.env`），因此无 `env/` 目录。
- `portal/` 原地升级为包：新增 `docker-compose.yml`，`conf/`、`html/` 不动。
- `apps/` 是纯 env 包（无配置目录）。
- 包内 compose 文件统一命名 `docker-compose.yml`：`cd infra && docker compose up` 可直接识别；脚本按 `<域>/docker-compose.yml` 拼接。

## 文件移动映射

用 `git mv` 保留历史。

| 旧路径 | 新路径 |
|---|---|
| `docker-compose-infra.yml` | `infra/docker-compose.yml` |
| `docker-compose-observability.yml` | `observability/docker-compose.yml` |
| `docker-compose-security.yml` | `security/docker-compose.yml` |
| `docker-compose-platform.yml` | `platform/docker-compose.yml` |
| `docker-compose-apps.yml` | `apps/docker-compose.yml` |
| `docker-compose-portal.yml` | `portal/docker-compose.yml` |
| `mysql/` | `infra/mysql/` |
| `rabbitmq/` | `infra/rabbitmq/` |
| `prometheus/` | `observability/prometheus/` |
| `grafana/` | `observability/grafana/` |
| `filebeat/` | `observability/filebeat/` |
| `elk/` | `observability/elk/` |
| `openldap/` | `security/openldap/` |
| `nacos/` | `platform/nacos/` |
| `xxl-job-admin/` | `platform/xxl-job-admin/` |
| `apisix/` | `platform/apisix/` |
| `portal/conf/`、`portal/html/` | 原地不变 |
| `common/env/mysql.env` | `infra/env/mysql.env` |
| `common/env/mongo.env` | `infra/env/mongo.env` |
| `common/env/mongo-express.env` | `infra/env/mongo-express.env` |
| `common/env/rabbitmq.env` | `infra/env/rabbitmq.env` |
| `common/env/kafka.env` | `infra/env/kafka.env` |
| `common/env/openldap.env` | `security/env/openldap.env` |
| `common/env/phpldapadmin.env` | `security/env/phpldapadmin.env` |
| `common/env/keycloak.env` | `security/env/keycloak.env` |
| `common/env/nacos.env` | `platform/env/nacos.env` |
| `common/env/ollama.env` | `apps/env/ollama.env` |
| `common/env/open-webui.env` | `apps/env/open-webui.env` |
| `common/env/moontv.env` | `apps/env/moontv.env` |
| `common/env/iptv.env` | `apps/env/iptv.env` |
| `common/env/common.env` | 原地不变（`common/env/common.env`） |

## compose 文件内的机械改动

- `env_file` 引用：
  - `common/env/common.env` → `../common/env/common.env`（六个文件全部）
  - `common/env/<服务>.env` → `env/<服务>.env`
- `portal/docker-compose.yml` 的挂载前缀：`./portal/conf/...` → `./conf/...`，`./portal/html` → `./html`（compose 文件进了 `portal/`，相对基准变了）。
- 其余域的配置目录跟着 compose 同包移动，`./mysql/...`、`./prometheus/...` 等写法**保持不变**。
- 注释中的路径引用：`portal/conf/...` 不变；凡出现 `docker-compose-<域>.yml` 的注释改为新路径。
- 顶层 `name:`、services 定义、ports、networks、fixed IP 一律不动。

## `.env` 插值处理（关键决策）

保持根 `.env` / `.env.example` 位置不变，作为唯一插值来源；所有脚本内 `docker compose` 调用显式传 `--env-file "$SCRIPT_DIR/.env"`：

```bash
docker compose --env-file "$SCRIPT_DIR/.env" -f "${group}/docker-compose.yml" up -d
```

理由：

- 不在每个包复制 `.env`（重复、易漂移），也不用符号链接。
- 不能用 `--project-directory .`：它会把相对路径基准改回仓库根，破坏「配置跟 compose 同包」的解析。
- 不用 `include:` / 根级汇总 compose 文件：多一层间接，且与「一域一包」方向相反。
- `shutdown.sh` 不跑 preflight，必须容忍 `.env` 不存在（新检出场景）：`.env` 缺失时不传 `--env-file`，靠 compose 插值默认值完成 `down`（`down` 按 project 标签匹配，不受插值值影响）。

README 同步给出标准手工命令模板（含 `--env-file .env`），并加一段迁移说明：旧命令 `docker compose -f docker-compose-infra.yml up -d <服务>` 改为 `docker compose --env-file .env -f infra/docker-compose.yml up -d <服务>`。

## 脚本与 CI 改动点

| 文件 | 改动 |
|---|---|
| `common/compose-list.sh` | 仍为启动顺序唯一数据源，域数组不变；注释更新（文件名为 `docker-compose-<域>.yml` 的表述改为 `<域>/docker-compose.yml`） |
| `startup.sh` | 三处 `docker compose -f "docker-compose-${group}.yml" up -d` → `docker compose --env-file "$SCRIPT_DIR/.env" -f "${group}/docker-compose.yml" up -d`；MySQL 健康闸门用 `docker inspect`，不受影响 |
| `shutdown.sh` | `down` 调用同上（`.env` 存在才传 `--env-file`），逆序逻辑不变 |
| `common/preflight.sh` | 镜像清单 glob：`"$SCRIPT_DIR"/docker-compose-*.yml` → `"$SCRIPT_DIR"/*/docker-compose.yml`；端口占用 glob：`docker-compose-portal.yml` → `portal/docker-compose.yml`；提示文案中的文件名同步；env 目录 WARN 文案 `common/env/*.env` → `*/env/*.env` |
| `common/check-consistency.sh` | 服务提取 glob：`docker-compose-*.yml` → `*/docker-compose.yml`；portal/README 检查路径不变 |
| `.github/workflows/ci.yml` | `files=(docker-compose-*.yml)` → `files=(*/docker-compose.yml)`；`check-consistency.sh` 调用不变 |
| `README.md` | 六域结构表的「compose 文件」列改为路径；4 处 `common/env/<服务>.env` 路径迁移；`openldap/bootstrap/...` → `security/openldap/bootstrap/...`；`docker-compose-apps.yml`、`docker-compose-infra.yml` 示例命令更新；新增手工命令模板与迁移说明 |
| `CLAUDE.md` | 常用命令示例、架构要点（compose 位置、env 分层）、约定中的路径同步 |
| `AGENTS.md` | 第 5/13/21/38 行的文件清单、验证命令、env 路径同步 |
| `docs/superpowers/specs|plans/*` | 不改（历史记录） |

## 验证

1. **静态渲染**（6 个包各一次，CI 同款）：
   `docker compose --env-file .env -f <域>/docker-compose.yml config -q`
2. **路径解析断言**：`docker compose ... config` 输出中，所有 bind mount 源与 `env_file` 应为绝对路径，且落在对应包目录（如 `infra/mysql/...`、`.../common/env/common.env`），无一处指向仓库根的旧目录。
3. **一致性脚本**：`bash common/check-consistency.sh` 零告警（服务 ↔ portal vhost ↔ 门户卡片 ↔ README hosts 清单）。
4. **旧路径零残留**：`git grep -nE 'docker-compose-(infra|observability|security|platform|apps|portal)\.yml|common/env/(mysql|mongo|kafka|openldap|keycloak|nacos|ollama|iptv|moontv|open-webui|mongo-express|rabbitmq|phpldapadmin)\.env'` 在代码/脚本/README/CI 中零命中（历史 docs 除外）。
5. **运行时冒烟**（有 Docker 的机器）：`bash startup.sh` 全量起来后，`docker inspect` 关键容器 healthy，`curl -I http://portal.glseven.local:8000` 正常，且 `docker compose ls` 中六个 project 名与重构前一致。
   本次执行环境无 docker CLI，运行时项由用户机器或 CI 覆盖，交付说明中明确标注「未在本机验证」。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 手工命令忘带 `--env-file`，`REDIS_PASSWORD` 静默回落到默认值 | README 标准命令模板 + 迁移说明；脚本内统一封装 |
| 用户自己的脚本/书签引用旧路径 | README 迁移说明列出旧→新命令对照；不保留兼容层（有意） |
| 搬目录时漏改某个相对路径，`config -q` 查不出（路径只在使用时解析） | 验证第 2 项：渲染结果里逐条检查绝对路径落点 |
| 大范围移动导致 git 历史断裂 | 全部用 `git mv` |
| CI 在子目录 project 下渲染差异（如 .env 缺失） | CI 与本地都用同一 `--env-file .env`；CI 已有 `.env` 生成步骤则复用，否则从 `.env.example` 复制 |

## 留给实施者的空间

- 移动与提交的粒度（一次性提交 vs 按域分批 + 最后一次引用修复）由实施计划决定；建议按域分批 `git mv` + 机械改引用，最后统一跑验证。
- `compose-list.sh` 是否增加一个构造 compose 参数的辅助函数（避免 startup/shutdown 重复拼接），由实施者按脚本整洁度决定；约束是「域清单仍只在此文件定义」。

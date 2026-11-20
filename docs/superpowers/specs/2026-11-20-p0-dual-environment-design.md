# 设计：P0 修复与 local / sit 配置档案（批次 A）

- **日期**：2026-11-20（按用户指示改为双档案制）
- **状态**：已确认（2026-11-20）
- **依据**：[配置审计报告](2026-11-20-config-audit-findings.md) 的 P0-1 ～ P0-4
- **约束来源**：同一套编排要同时支持本机（macOS / Docker Desktop）与家里测试服务器（sit）；`athena` 是本机另一个 athena 项目的前端，sit 不需要

## 1. 目标

1. 用两套显式配置档案（`.env.local` / `.env.sit`）承载机器相关值，启动时用 `--profile` 切换。
2. Kafka 宿主入口不再写死在受跟踪文件里，也不再有「某台机器的地址」成为默认值。
3. 本机专属的 athena 入口不进入主配置，且它缺席时不会拖垮门户。
4. Nacos 的客户端 API 鉴权显式开启，控制台现有鉴权不受影响。

## 2. 非目标

- 不处理审计报告中的 P1 / P2 项。
- 不设计通用的多环境框架；只支持 `local` 与 `sit` 两个档案，新增档案沿用同一机制。
- 不把 athena 服务纳入本仓库；它与 `glseven` 网络的连接由 athena 项目自己负责。
- 不保留 `.env` 的兼容层；迁移步骤见 §6。

## 3. 约束与已验证事实

- 档案文件含凭据，必须 gitignore；只提交 `*.example` 模板。
- `docker compose --env-file X` 会完全取代默认 `.env`（已实测：`.env` 中的同名变量不再生效）。
- 多个 `--env-file` 受支持（已实测），但本设计每个档案只用一个文件。
- 档案缺失时 Compose 报 `couldn't find env file: ...`，可作为快速失败。
- `${VAR:?message}` 与 `environment` 覆盖 `env_file` 均已实测。
- Docker daemon 当前未运行，运行时验证放在实施阶段。

## 4. 方案与取舍

### 4.1 配置档案（选定）

**文件**

| 文件 | 是否入库 | 内容 |
|---|---|---|
| `.env.local.example` | 是 | 本机模板：`DOCKER_VOLUME=$HOME/docker/glseven`、`KAFKA_EXTERNAL_HOST=127.0.0.1`、`REDIS_PASSWORD=...` |
| `.env.sit.example` | 是 | sit 模板：`DOCKER_VOLUME=/docker/glseven`、`KAFKA_EXTERNAL_HOST=192.168.31.100`、`REDIS_PASSWORD=...` |
| `.env.local` / `.env.sit` | 否 | 实际档案，从模板复制后按机器修改 |
| `.glseven-profile` | 否 | 最近一次选择的档案名，供 `shutdown.sh` 复用 |

**选择**

- `bash startup.sh --profile local [数据目录]`
- `bash startup.sh --profile sit [数据目录]`
- 优先级：`--profile` > `.glseven-profile` > 报错。首次必须显式指定；之后重复启动可省略。
- 档案名只允许 `[a-z0-9_-]+`，防止路径穿越。
- 数据目录优先级：位置参数 > 档案中的 `DOCKER_VOLUME` > 平台默认值。

**传递**

- `startup.sh` / `shutdown.sh` 的每次 `docker compose` 调用都带 `--env-file "$PROFILE_FILE"`。
- 启动时打印 `profile` 与解析后的 `DOCKER_VOLUME`，避免选错档案却无感知。
- `shutdown.sh` 用 `--profile` 或 `.glseven-profile`；二者都没有则报错并提示。

**未选方案**

- **单个 `.env` 里放两套注释配置**：切换时要手工改文件，容易改错、容易提交。
- **`.env` 放公共值 + `.env.local/.sit` 放差异**：需要同时维护两个文件，且 `REDIS_PASSWORD` 这类公共值要重复；多个 `--env-file` 虽支持，但增加理解成本。
- **目录外的 profile**：`--profile` 只能指向本仓库 `.env.<name>`，避免任意路径读取。

### 4.2 Kafka

- `common/env/kafka.env` 删除 `KAFKA_ADVERTISED_LISTENERS`，保留其余 listener 配置。
- `docker-compose-infra.yml` 的 kafka 服务新增：
  ```yaml
  environment:
    KAFKA_ADVERTISED_LISTENERS: "PLAINTEXT://kafka:9092,EXTERNAL://${KAFKA_EXTERNAL_HOST:-127.0.0.1}:29092"
  ```
- `KAFKA_EXTERNAL_HOST` 只存在于档案：local 为 `127.0.0.1`，sit 为 `192.168.31.100`。
- 默认值 `127.0.0.1` 只作为兜底，防止档案漏项时配置为空；不再是「某台机器的地址」。

### 4.3 athena 入口

- 文件改名为 `portal/conf/conf.d/athena.local.conf`。
- `.gitignore` 增加 `portal/conf/conf.d/*.local.conf`。
- 上游改为运行时解析，避免 athena 缺席时整个门户起不来：
  ```nginx
  resolver 127.0.0.11 valid=10s ipv6=off;
  set $athena_web "web:80";
  ...
  proxy_pass http://$athena_web;
  ```
- `common/check-consistency.sh` 的 `server_name` 反查循环跳过 `*.local.conf`，并打印跳过数量。
- README / CLAUDE.md 增加约定：本机专属 vhost 放 `*.local.conf`，不入库、不参与一致性校验。

### 4.4 DOCKER_VOLUME

- 五个 compose 文件的 25 处 `${DOCKER_VOLUME:-/docker/glseven}` 改为 `${DOCKER_VOLUME:?DOCKER_VOLUME is required (set it in the active profile)}`。
- `common/docker-volume.sh` 的 `resolve_docker_volume` 增加「从指定 env 文件读取」的参数，并展开 `~` 与 `$HOME` 前缀。
- `common/preflight.sh` 的 `ensure_env_file` 替换为 `ensure_profile_file`：档案必须已存在，且包含非空的 `DOCKER_VOLUME` 与 `REDIS_PASSWORD`；缺失时报错并给出复制模板的命令。**不再自动创建或补写**，从根上消除「把平台默认值写进文件」的风险。
- `fix_dir_permissions` 的 600 权限收紧从 `.env` 扩展到所有 `.env.*`（排除 `*.example`）。
- `shutdown.sh` 也解析并导出 `DOCKER_VOLUME`，并使用同一个 `--env-file`。`down` 同样做插值；不补这一处，升级后第一次停服会被 `:?` 拒绝，而现有脚本会把 stderr 丢弃、按「not running」处理。
- CI 的「Prepare Compose environment」改为 `cp .env.local.example .env.local`，所有 `compose config` 加 `--env-file .env.local`。

### 4.5 Nacos 鉴权

**选定：显式开启客户端 API 鉴权，保留控制台现有鉴权。**

事实（核对 3.2.4 源码与镜像 entrypoint）：

- 3.2.4 默认 `nacos.core.auth.enabled=false`（客户端 SDK / gRPC / OpenAPI），但 `nacos.core.auth.admin.enabled=true`、`nacos.core.auth.console.enabled=true`——控制台本来就要求登录。
- `NACOS_AUTH_TOKEN` / `NACOS_AUTH_IDENTITY_KEY` / `NACOS_AUTH_IDENTITY_VALUE` 是镜像 entrypoint 的硬性必填项，任一为空会 `exit 255`，与 `NACOS_AUTH_ENABLE` 无关；它们不是死配置。

改动：

- `common/env/nacos.env` 增加 `NACOS_AUTH_ENABLE=true`；token 与 identity 保持不变。
- 客户端需改用带凭据的连接方式；控制台用户名 `nacos`，密码在首次初始化时设置（`users` 表为空时控制台提示；官方 schema 不插入默认用户）。
- 回滚：只把 `NACOS_AUTH_ENABLE` 设回 `false` 并重建；**不要删除 token/identity**。完全关闭鉴权还需 `NACOS_AUTH_CONSOLE_ENABLE=false` 与 `NACOS_AUTH_ADMIN_ENABLE=false`。
- README 的措辞限定为「客户端 API 鉴权」，并说明控制台鉴权一直默认开启。

## 5. 具体改动清单

| 文件 | 改动 |
|---|---|
| `common/profile.sh`（新增） | 档案名校验、`--profile` / `.glseven-profile` 选择、档案路径解析 |
| `startup.sh` | 解析 `--profile`，source `profile.sh`，打印档案与数据目录，所有 compose 调用带 `--env-file` |
| `shutdown.sh` | 同样的档案选择，解析并导出 `DOCKER_VOLUME`，compose 调用带 `--env-file` |
| `common/docker-volume.sh` | `resolve_docker_volume` 支持指定 env 文件，展开 `~` / `$HOME` |
| `common/preflight.sh` | `ensure_env_file` → `ensure_profile_file`；600 权限覆盖 `.env.*` |
| `common/check-consistency.sh` | 跳过 `*.local.conf` |
| `docker-compose-infra.yml` | kafka `environment` 覆盖 advertised；10 处 DOCKER_VOLUME 改 `:?` |
| `docker-compose-apps.yml` / `observability` / `security` / `platform` | DOCKER_VOLUME 共 15 处改 `:?` |
| `common/env/kafka.env` | 删除 `KAFKA_ADVERTISED_LISTENERS`，注释指向档案 |
| `common/env/nacos.env` | 增加 `NACOS_AUTH_ENABLE=true`（保留 token/identity） |
| `portal/conf/conf.d/athena.conf` → `athena.local.conf` | 改名、上游改 resolver + 变量、注释说明仅本机 |
| `.env.example` → `.env.local.example` / `.env.sit.example` | 拆成两份模板，含机器相关值 |
| `.gitignore` | 忽略 `.env.*`（保留 `*.example`）、`.glseven-profile`、`portal/conf/conf.d/*.local.conf` |
| `.github/workflows/ci.yml` | `cp .env.local.example .env.local`；compose 命令加 `--env-file` |
| `.github/scripts/test-docker-volume.sh` | 适配显式 env 文件；增加 `$HOME` / `~` / 缺键用例 |
| `.github/scripts/test-profile.sh`（新增） | 档案选择优先级、非法档案名、缺失档案 |
| `README.md` | local / sit 两套启动步骤、`--profile` 说明、Nacos 初始化、`*.local.conf` 约定 |
| `CLAUDE.md` | 同步档案制命令与约定 |

## 6. 迁移与回滚

**本机 local**

1. `cp .env.local.example .env.local`；如已有 `.env`，把自定义值合并进去。
2. `bash startup.sh --profile local`。
3. 之后可直接 `bash startup.sh`（沿用 `.glseven-profile`）。

**家里服务器 sit**

1. `cp .env.sit.example .env.sit`，确认 `DOCKER_VOLUME` 指向现有数据目录、`KAFKA_EXTERNAL_HOST` 是宿主局域网 IP。
2. `bash startup.sh --profile sit`。
3. 若之前用 `bash startup.sh /data/glseven` 自定义目录，必须把同一路径写进 `.env.sit` 的 `DOCKER_VOLUME`；新机制不会猜历史值。

**单域命令**

- 带档案：`docker compose --env-file .env.local -f docker-compose-apps.yml up -d <service>`。
- 不带档案会因 `:?` 明确失败，而不是静默挂到 `/docker/glseven`。

**回滚**

- 恢复 `${DOCKER_VOLUME:-/docker/glseven}` 并改回 `.env` 即可；但 macOS 静默错挂与 Kafka 地址写死的问题会回来。
- Nacos 回滚见 §4.5；athena 回滚只需把 `*.local.conf` 改回受跟踪文件，但 sit 会重新受静态上游影响。

## 7. 验证计划

离线（无需 daemon，CI 也会跑）：

1. `bash -n` 全部受跟踪脚本。
2. 新增 `test-profile.sh` 与更新后的 `test-docker-volume.sh`。
3. 用 `.env.local` 与 `.env.sit` 分别执行六个 `docker compose --env-file ... config -q`。
4. `bash common/check-consistency.sh --strict` 为 0 项，且 `athena.local.conf` 被跳过。
5. `docker compose --env-file .env.sit -f docker-compose-infra.yml config | grep ADVERTISED` 得到 sit 地址；local 得到 `127.0.0.1`。
6. 变更行 `git diff --check`。

运行时（需 daemon，实施后补）：

1. 本机 `bash startup.sh --profile local`，确认数据目录；`bash shutdown.sh` 正常。
2. sit 上 `bash startup.sh --profile sit`，Kafka 宿主客户端 `--bootstrap-server localhost:29092` 成功。
3. `docker exec nginx nginx -t` 通过；停掉 athena 后 `nginx -s reload` 不报错。
4. Nacos 客户端 API 未带凭据返回 401/403；控制台可登录。

## 8. 风险

| 风险 | 缓解 |
|---|---|
| 首次运行忘记 `--profile`，或选错档案 | 首次强制显式；启动时打印档案名与数据目录；`.glseven-profile` 只记录最近一次 |
| 档案文件被误提交（含凭据） | `.gitignore` 的 `.env.*` + `*.example` 例外；CI 加 `git check-ignore` 断言 |
| CI 忘记 `--env-file` 导致全红 | 设计列为必改项；本地先跑 `compose config` |
| Nacos 开启客户端鉴权打断现有客户端 | 先在 sit 验证；保留只关 `NACOS_AUTH_ENABLE` 的回滚路径 |
| `--env-file` 路径含空格 | 所有调用加引号；仓库路径当前无空格 |
| `*.local.conf` 被误提交 | `.gitignore` + 一致性脚本跳过提示；提交前 `git status` |

## 9. 留给实施者的决定

- 是否为 `startup.sh` 增加 `GLSEVEN_PROFILE` 环境变量作为第三种选择方式（建议不做，`--profile` 已足够）。
- `common/profile.sh` 的函数拆分粒度；建议只放「校验 + 选择 + 路径」三件事。
- 档案模板里的示例数据目录是否保留 `$HOME/docker/glseven`（建议保留，Compose 与解析器都会展开）。
- Nacos 管理员密码在 README 中写成占位符，不记录真实值。

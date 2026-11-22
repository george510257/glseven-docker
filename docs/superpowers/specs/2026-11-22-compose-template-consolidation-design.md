# 设计文档：Compose 公共模板收敛（extends + 锚点）

日期：2026-11-22
状态：已批准（2026-11-22；批次 1 完成后恢复执行）

## 意图与背景

七个域包（infra / observability / security / platform / apps / devops / portal）共有 27 个服务，每个服务都在重复同一组模板字段：

- `restart: always` × 27
- `env_file: ../common/env/common.env` × 26
- 标准 healthcheck 时间参数（10s / 5s / 10 / 30s）× 20
- 逐服务复制的「宿主访问统一经 nginx 代理」注释 × 约 21

用户原话：**「配置重复太多，想收敛一下。」** 2026-11-20 的配置审计已把「healthcheck 与 env_file 重复」记为 P2-6，当时建议每文件加 YAML 锚点；本次在锚点基础上再引入跨文件 `extends`，把公共字段收到单点。

这里的「复用」指复用公共配置定义，不是合并服务实例：mysql / redis / mongo / rabbitmq / kafka / etcd 已是全栈共用单实例，adminer / mongo-express / php-ldap-admin 各管不同的库，Prometheus+Grafana 与 ELK 是指标与日志两条线，没有可合并的重复服务。

## 目标 / 非目标 / 反目标

**目标**

- 新增 `common/base-service.yml`，承载 `restart`、`common.env`、标准 healthcheck 时间参数三层模板。
- 七个域 compose 的每个服务改用 `extends` 引用模板；删除重复字段与逐服务 nginx 注释。
- 统一服务块 key 顺序、`test:` 数组格式、域标题注释与空行。
- 新增 `ci/scripts/test-compose-style.sh`，把模板使用与风格变成 CI 断言。
- 更新 CLAUDE.md / AGENTS.md / README.md 中的模板说明与校验命令。

**非目标**

- 不改任何服务的镜像、端口、网络、固定 IP、卷、env 值、healthcheck 命令与实际时间参数。
- 不合并服务实例，不删除服务。
- 不动门户五处同步点（`<域>/compose`、`portal` ports、vhost、门户卡片、README hosts）及其断言。
- 不动域分包结构、启动批次、CI 发布逻辑、env 分层。
- 不引入 `include:`、模板引擎、wrapper CLI、符号链接。

**反目标（做了算失败）**

- 任一容器重建后行为变化：渲染后的配置与改造前不等价。
- `docker compose config` 需要额外参数或 wrapper 才能工作。
- 公共字段仍散落在域 compose 中（`restart`、`common.env`、标准 healthcheck 时间参数）。
- 新增服务可以绕过模板而不被 CI 发现。

## 约束

- 本机没有 Docker CLI；`docker compose config` 验证在 CI 或用户机器执行。
- 既有解析器必须继续工作：
  - `common/check-consistency.sh` 用 awk 按 `^  <service>:$`、`^    container_name:`、`^    hostname:` 提取服务；
  - `common/preflight.sh` 按 `image:` 行抓 ghcr / quay 镜像，按 portal 的 `"host:container"` 抓端口；
  - `ci/scripts/test-devops-domain.sh` 按服务头、`container_name`、`ipv4_address` 断言。
- 脚本只依赖 docker / bash / grep / awk，必须兼容 macOS 自带 Bash 3.2。
- `common/base-service.yml` 不得被 `*/docker-compose.yml` 通配命中，也不参与 `compose-list.sh` 的启动批次。
- `extends` 不支持 `docker stack deploy`；本仓库不使用 Swarm，可接受。
- Compose `extends` 合并规则（官方文档）：
  - 映射（`environment`、`healthcheck`）按 key 合并，子服务覆盖同名 key；
  - `env_file` 列表拼接，子服务项在后；base 中的相对路径会重定位到仍指向同一文件；
  - `networks`、`container_name`、`hostname` 等标量由子服务覆盖；
  - `depends_on` 不会被自动导入，各服务仍自行声明。

## 方案

| 方案 | 内容 | 取舍 |
|---|---|---|
| **A（选用）** | 跨文件 `extends` + 每文件锚点 | 公共字段单点维护，净减约 100 行；多一层间接，最终配置需用 `compose config` 查看 |
| B | 仅每文件 YAML 锚点 | 无跨文件依赖；`env_file` 列表无法拼接，锚点块在 7 个文件重复，收敛不彻底 |
| C | 只统一风格 + CI 断言 | 零结构风险；重复一行不少 |

选 A：只有它能同时去掉 `restart`、`common.env`、标准 healthcheck 时间参数三类重复，并把「公共字段改哪里」变成唯一答案。B 的锚点块本身仍是 7 份重复；C 不解决痛点。C 的 CI 断言并入 A，作为防回退手段。

不选 `include:` / 根级汇总 compose：2026-11-21 域分包设计已明确否决（多一层间接、与「一域一包」方向相反）。不选模板生成（yq / gomplate）：违反「脚本只依赖 docker / bash / grep」的既有约束。

## 详细设计

### 1. 新增 `common/base-service.yml`

```yaml
# 公共服务模板：各域 compose 通过 extends 引用；本文件不是启动单元，
# 不参与 common/compose-list.sh 的批次。修改后请跑 ci/scripts/test-compose-style.sh。
services:
  service-base:
    restart: always

  service-common:
    extends: service-base
    env_file:
      - env/common.env

  service-healthy:
    extends: service-common
    healthcheck:
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
```

三层模板的理由：

- `service-base` 只带 `restart`，给 gitlab、gitlab-runner 使用——这两个服务当前没有 `env_file`，若直接继承 `common.env` 会新增 `TZ` 环境变量，属于行为变化。
- `service-common` 在 `restart` 之外只带 `common.env`，给 portainer 使用——它有 `common.env` 但没有健康探针，不能继承 `service-healthy`（healthcheck 映射缺少 `test` 是非法配置）。
- `service-healthy` 给其余 24 个标准服务使用，带 `common.env` 与标准时间参数。

`env/common.env` 相对本文件解析；Compose 在 `extends` 时会把路径重定位到引用方，渲染后仍指向 `common/env/common.env`。不把 `TZ` 改成 `environment`，是为了保持现有 env 分层约定（我的决定）。

### 2. 各域 compose 头部锚点

每个文件只定义实际用到的锚点，形式统一：

```yaml
x-healthy: &healthy
  file: ../common/base-service.yml
  service: service-healthy
```

需要时再定义：

```yaml
x-base: &base
  file: ../common/base-service.yml
  service: service-base
x-common: &common
  file: ../common/base-service.yml
  service: service-common
```

`x-` 是 Compose 扩展字段，渲染时忽略；`extends` 的值用 YAML 别名引用，服务里只占一行。

各文件锚点使用：

| 文件 | 使用的锚点 |
|---|---|
| `infra/` `observability/` `security/` `apps/` `portal/` | `*healthy` |
| `platform/` | `*healthy`（nacos / xxl-job-admin / nexus3 / apisix）、`*common`（portainer） |
| `devops/` | `*base`（gitlab / gitlab-runner） |

### 3. 服务块规范

key 顺序固定为：

```text
extends → image → container_name → hostname
→ user / init / tty / shm_size
→ command → env_file → environment
→ volumes → depends_on → networks
→ healthcheck → deploy
```

示例：

```yaml
  mysql:
    extends: *healthy
    image: mysql:9.7.2
    container_name: mysql
    hostname: mysql
    env_file:
      - env/mysql.env
    volumes:
      - ${DOCKER_VOLUME:?DOCKER_VOLUME is required (set it in the active profile)}/mysql/data:/var/lib/mysql
    networks:
      glseven:
        ipv4_address: 172.18.1.1
    healthcheck:
      test: [ "CMD-SHELL", "mysqladmin ping -h127.0.0.1 -p$$MYSQL_ROOT_PASSWORD --silent" ]
```

- 有自己 env 的服务只保留 `env/<service>.env`；`common.env` 由模板提供。渲染后的顺序仍是 `common.env` 在前、服务 env 在后，与现状一致。
- `healthcheck` 只保留 `test:`（标准时间参数继承）。异常服务保留完整显式时间参数，避免读者需要回头查模板：
  - ollama、filebeat、iptv：30s / 10s / 3 / 30s
  - gitlab：30s / 10s / 20 / 300s
  - keycloak：10s / 5s / 10 / 60s
- portainer、gitlab-runner 无健康探针：前者继续注明「镜像无 shell/curl/wget」，后者补一条「无有意义的就绪命令」注释。
- 删除逐服务的「宿主访问统一经 nginx 代理」注释；在每个域文件顶部留一条统一说明（portal 自身改为说明它是唯一持有宿主端口的容器）。
- 各服务 healthcheck 上方解释探针工具选择的注释保留，属于服务特有信息。

### 4. 风格规范

- `test:` 数组统一无内边距：`[ "CMD-SHELL", "..." ]` 改为 `["CMD-SHELL", "..."]`。
- 域标题注释统一为 100 列：`# <Domain> 172.18.<n>.x =====...`。
- 服务块之间一个空行；文件末尾一个换行；YAML 使用 2 空格缩进。
- 注释使用中文；镜像名、参数名、代码片段保持原文。不重写与本次改动无关的英文注释。
- `depends_on` 统一长语法 + `condition`。
- 端口映射加引号；`image`、`ipv4_address`、服务名不加引号。
- `${DOCKER_VOLUME:?...}` 的既有错误文案保持不变（已一致，缩短文案只会增加无意义 diff）。

### 5. CI 断言 `ci/scripts/test-compose-style.sh`

`ci/validate.sh` 会自动执行 `ci/scripts/test-*.sh`，因此无需改 `.gitlab-ci.yml`。脚本无 Docker 也能跑，失败时打印文件与行号。

检查项：

1. `common/base-service.yml` 存在，定义 `service-base`、`service-common`、`service-healthy`，且后两者分别继承前一层。
2. 每个 `*/docker-compose.yml` 的服务块都有 `extends:`，值为 `*healthy` / `*common` / `*base` 之一。
3. 域 compose 中不出现 `restart:`，也不出现 `../common/env/common.env`。
4. 锚点使用与定义匹配：每个 `*name` 在同文件有 `&name`。
5. 模板分配白名单：
   - `*base`：只允许 `gitlab`、`gitlab-runner`；
   - `*common`：只允许 `portainer`；
   - 其余服务必须使用 `*healthy`。
6. 有 `healthcheck:` 的服务必须有 `test:`；`test:` 行符合统一格式。
7. 每个服务块有 `container_name` 与 `hostname`，且值相等（与 check-consistency 的静默跳过互补）。
8. 域标题注释符合统一格式。

### 6. 文档更新

- `CLAUDE.md`：架构要点增加「`common/base-service.yml` 是服务公共字段的唯一数据源」；新增服务第 1 步改为 `extends: *healthy`（例外需说明理由）；本地校验清单加入新脚本；说明 `extends` 的合并规则与 `env_file` 重定位。
- `AGENTS.md`：验证命令加入新脚本；服务定义说明补 `extends`。
- `README.md`：公共包说明补 `base-service.yml`；「新增服务的同步点」第 1 步补 `extends`。
- 不改 `docs/superpowers/specs|plans` 下的历史文档。

## 验证

1. **静态检查**：`bash -n` 全部 shell 脚本；`bash ci/scripts/test-compose-style.sh`；全部 `ci/scripts/test-*.sh`；`bash common/check-consistency.sh --strict`；`git diff --check`。
2. **Compose 渲染**：七个文件各跑一次 `docker compose --env-file .env.local -f <域>/docker-compose.yml config -q`（CI 的 validate 已覆盖）。
3. **等价性比较**：改造前在有 Docker 的机器上保存七份 `docker compose config --format json` 输出作为基线；改造后逐域渲染，比较服务名、image、container_name、hostname、ports、networks / ipv4_address、volumes、env_file 解析路径、healthcheck test 与时间参数、depends_on。允许键顺序差异，不允许值差异。
4. **重点断言**：mysql / keycloak / gitlab 的健康检查时间参数与改造前一致；gitlab、gitlab-runner 的渲染结果中没有新增 `TZ`；portainer 的 `env_file` 仍指向 `common/env/common.env`。
5. **运行时（用户机器）**：`bash startup.sh` 后关键容器 healthy 状态与改造前一致；`curl -I http://portal.glseven.local:8000` 正常。
6. **回滚**：纯配置重构，`git revert` 即可。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| `env_file` 路径重定位与文档不符 | 等价性比较第 3 项；若失败，退化为在 `service-common` 用 `environment: {TZ: Asia/Shanghai}` 并移除 `env_file`（局部改动） |
| `healthcheck` 映射未按预期合并 | 渲染后断言 mysql / keycloak / gitlab 的时间参数 |
| 本机无 Docker，无法本地渲染 | CI validate 已跑 `compose config`；合并前在用户机器跑一次基线比较 |
| 现有 awk / grep 解析器被破坏 | 保持服务头、container_name、hostname、image、ipv4_address 的行格式与缩进；新测试断言 |
| 新服务忘写 `extends` 或选错模板 | CI 断言第 2、5 条阻断 |
| 读者排查时看不到最终配置 | 文档与文件头注释说明用 `docker compose config` 查看渲染结果 |

## 留给实施者的空间

- 七个 compose 的改造顺序（逐域分批 vs 一次性）由实施计划决定；建议先加 `common/base-service.yml` 与新测试，再逐域改，最后统一跑渲染比较。
- 风格测试用 awk 还是 grep 组合由实施者决定，约束是 Bash 3.2 兼容、无 Docker 也能跑。
- 域标题注释的具体列宽（100 列是建议值）由实施者定，约束是七个文件一致。

## 我的决定（供审阅）

- 保留 `common.env` 作为共享 env，不把 `TZ` 迁到 compose。
- 用三层模板而不是两层，确保 gitlab / gitlab-runner 不新增 `TZ`、portainer 不获得非法 healthcheck。
- 只有实际使用锚点的文件才定义锚点，不为了头部统一而定义空锚点。
- 异常探针服务保留完整时间参数，不隐藏继承关系。
- 不重命名 `security/env/phpldapadmin.env`（目录与镜像名都是 phpldapadmin，重命名只会制造新的不一致）。
- 不把 `networks` 改成 flow 风格；可读性优先于行数。

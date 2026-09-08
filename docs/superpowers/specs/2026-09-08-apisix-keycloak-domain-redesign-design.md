# GlSeven APISIX + Keycloak 接入与六域重编排 设计文档

日期：2026-09-08
状态：待用户评审
前置：2026-09-07 镜像全量升级 + Nginx 导航门户（develop @ 0dbf470）已完成，工作区干净。

## 1. 背景与目标

- 新增 APISIX（API 网关）与 Keycloak（统一身份认证）镜像（用户已确认以下前提）：
  - APISIX 定位为**独立网关组件**：代理端口 + Admin API 就绪、路由规则留空由微服务开发自行配置，与 nginx 门户及各服务端口映射互不干扰。
  - Keycloak 存储后端使用**现有 MySQL**（新建 keycloak 库），归 DEFERRED 批次。
- 域重设计（用户明确要求"重新设计现有的领域，现在分类太分散了"）：10 个 compose 文件合并为 6 个职能域，新增服务一并归组。
- 优化现有配置（用户四项全选）：补齐 healthcheck、可观测性接入、导航页更新、env 配置规范化。
- 验证方式：临时卷隔离全量拉起（沿 2026-09-07 先例），存量数据零接触。

官方调研结论来源：Docker Hub / quay.io tag 实测 + 官方发布页（2026-09-08 时点）。

## 2. 域重设计（10 文件 → 6 文件，23 服务）

### 2.1 新域结构

| 新域文件（顶层 name:） | 服务（容器名不变） | IP 段 | 启动批次 |
|---|---|---|---|
| docker-compose-infra.yml | mysql .1、redis .2、mongo .3、mongo-express .4、adminer .5、rabbitmq .6、kafka .7、**etcd .8（新）** | 172.18.**1**.x | BASE |
| docker-compose-observability.yml | prometheus .1、grafana .2、elk .3 | 172.18.**2**.x | BASE |
| docker-compose-security.yml | openldap .1、php-ldap-admin .2、**keycloak .3（新）** | 172.18.**3**.x | DEFERRED |
| docker-compose-platform.yml | nacos .1、xxl-job-admin .2、nexus3 .3、portainer .4、**apisix .5（新）** | 172.18.**4**.x | DEFERRED |
| docker-compose-apps.yml | ollama .1、open-webui .2、moontv .3 | 172.18.**5**.x | DEFERRED |
| docker-compose-portal.yml | nginx .1（仅改 IP 段） | 172.18.**6**.x | PORTAL |

### 2.2 启动批次与脚本联动

`common/compose-list.sh` 改为：

```bash
COMPOSE_FILES_BASE=(infra observability)
COMPOSE_FILES_DEFERRED=(security platform apps)
COMPOSE_FILES_PORTAL=(portal)
```

- 批次对齐依赖：security（keycloak 需 MySQL）、platform（nacos/xxl-job 需 MySQL）必须 DEFERRED；openldap 无 MySQL 依赖，随域晚启动无副作用；apps 无 MySQL 依赖，维持 DEFERRED 与现状一致。
- `startup.sh` / `shutdown.sh` **零改动**（数组来源即 compose-list.sh，关闭按逆序自动生效）。

### 2.3 IP 重编映射表（旧 → 新）

| 服务 | 旧 IP | 新 IP | | 服务 | 旧 IP | 新 IP |
|---|---|---|---|---|---|---|
| mysql | 172.18.1.1 | 172.18.1.1 | | openldap | 172.18.3.1 | 172.18.3.1 |
| redis | 172.18.1.2 | 172.18.1.2 | | php-ldap-admin | 172.18.3.2 | 172.18.3.2 |
| mongo | 172.18.1.3 | 172.18.1.3 | | nacos | 172.18.7.1 | 172.18.4.1 |
| mongo-express | 172.18.1.4 | 172.18.1.4 | | xxl-job-admin | 172.18.7.2 | 172.18.4.2 |
| adminer | 172.18.1.5 | 172.18.1.5 | | nexus3 | 172.18.6.1 | 172.18.4.3 |
| rabbitmq | 172.18.2.1 | 172.18.1.6 | | portainer | 172.18.5.1 | 172.18.4.4 |
| kafka | 172.18.2.2 | 172.18.1.7 | | ollama | 172.18.9.1 | 172.18.5.1 |
| prometheus | 172.18.4.1 | 172.18.2.1 | | open-webui | 172.18.9.2 | 172.18.5.2 |
| grafana | 172.18.4.2 | 172.18.2.2 | | moontv | 172.18.8.1 | 172.18.5.3 |
| elk | 172.18.4.3 | 172.18.2.3 | | nginx | 172.18.10.1 | 172.18.6.1 |

- 服务间互访全部走服务名（Docker DNS），重编不影响内部调用；仅外部硬编码旧 IP 的场景受影响，README 提供本映射表。
- 数据卷按 `DOCKER_VOLUME` 目录绑定，容器因 IP 变化重建但数据不丢。

### 2.4 文件增删与迁移规则

- 删除 9 个旧文件：`docker-compose-{storage,messaging,auth,monitor,manager,devops,microservices,tv,ai}.yml`。
- 新增 5 个：`docker-compose-{infra,observability,security,platform,apps}.yml`；portal 文件保留、段号注释改 172.18.6.x。
- 迁移规则：服务的 `image/container_name/hostname/restart/env_file/volumes/ports/command/healthcheck/deploy` **全部原样迁移**，仅改 `networks.glseven.ipv4_address`（按 §2.3）与文件头注释段号。
- apps.yml 迁移 tv.yml 中 libretv 下线注释，预留 IP 引用改为 172.18.5.4（端口 8899 预留不变）。

## 3. 新增服务

### 3.1 镜像版本（2026-09-08 时点，官方渠道 tag 实测存在）

| 服务 | 镜像 | 版本依据 |
|---|---|---|
| APISIX | `apache/apisix:3.18.0-debian` | 2026-08 发布最新稳定版（Docker Hub：3.18.0-debian/-ubuntu/-redhat） |
| etcd | `quay.io/coreos/etcd:v3.6.14` | 官方 quay 仓库成熟维护线；v3.7.1 已出（2026-07）但仅 2 个月，为 APISIX 互操作稳妥选 3.6（先例：nginx 选 stable 不选 mainline） |
| Keycloak | `keycloak/keycloak:26.7.3` | 2026-08-31 发布，26.7 为当前唯一活跃维护线 |

### 3.2 etcd（infra 域 172.18.1.8）

```yaml
  etcd:
    image: quay.io/coreos/etcd:v3.6.14
    container_name: etcd
    hostname: etcd
    restart: always
    env_file:
      - common/env/common.env
    command:
      - etcd
      - --name=etcd
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://etcd:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://etcd:2380
      - --initial-cluster=etcd=http://etcd:2380
      - --initial-cluster-state=new
    volumes:
      - ${DOCKER_VOLUME:-/docker/glseven}/etcd/data:/etcd-data
    networks:
      glseven:
        ipv4_address: 172.18.1.8
    healthcheck:
      # 镜像内无 shell（实测），必须用 exec 形式而非 CMD-SHELL。
      test: [ "CMD", "etcdctl", "endpoint", "health", "--endpoints=http://127.0.0.1:2379" ]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
```

- 宿主机**不映射端口**（仅容器网络内供 APISIX 与 Prometheus 访问）。
- 无必需环境变量，**不建 env 文件**（仅挂 common.env 时区），决策记录于此。
- 镜像为 distroless、无 shell；默认无认证，安全边界=glseven 容器网络，勿新增宿主端口映射（Task 1 实测确认）。

### 3.3 APISIX（platform 域 172.18.4.5）

```yaml
  apisix:
    image: apache/apisix:3.18.0-debian
    container_name: apisix
    hostname: apisix
    restart: always
    env_file:
      - common/env/common.env
    volumes:
      - ./apisix/conf/config.yaml:/usr/local/apisix/conf/config.yaml:ro
    networks:
      glseven:
        ipv4_address: 172.18.4.5
    ports:
      - "9080:9080"   # 网关数据面（路由留空，由开发自行配置）
      - "9180:9180"   # Admin API
    healthcheck:
      # 镜像内无 curl/wget（Task 1 实测），改用 bash /dev/tcp 对数据面 9080 做 TCP 存活探测。
      test: [ "CMD-SHELL", "bash -c '</dev/tcp/127.0.0.1/9080' || exit 1" ]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
```

- **不写 depends_on**：etcd 在 infra 域，跨 compose project 的 depends_on 不生效（已知坑）；由批次时序（BASE 先于 DEFERRED 且隔 MySQL 健康窗口）+ APISIX 启动重试 + `restart: always` 兜底，compose 注释说明。
- 健康探针不校验 HTTP 状态码（无路由时 9080 返回 404，TCP 连接成功即数据面就绪；etcd 不可达时 APISIX 无法完成初始化，无假阳性）。
- 9443（TLS）暂不开放，YAGNI。

**./apisix/conf/config.yaml（新增，最小覆盖式）**：APISIX 加载 conf/config-default.yaml（全部默认值：node_listen 9080、admin_listen 0.0.0.0:9180、prometheus 插件已启用）后合并 config.yaml 覆盖项，因此仅 4 处覆盖：

```yaml
deployment:
  admin:
    admin_key:
      # 实施时生成：openssl rand -hex 16；修改后需同步依赖 Admin API 的脚本/文档。
      - name: admin
        key: "<IMPLEMENTATION_GENERATED>"
etcd:
  host:
    - "http://etcd:2379"
plugin_attr:
  prometheus:
    export_addr:
      ip: "0.0.0.0"
      port: 9091
```

export_addr 改 0.0.0.0 供 Prometheus 跨容器抓取（默认仅 127.0.0.1）。

### 3.4 Keycloak（security 域 172.18.3.3）

```yaml
  keycloak:
    image: keycloak/keycloak:26.7.3
    container_name: keycloak
    hostname: keycloak
    restart: always
    command: start-dev
    env_file:
      - common/env/common.env
      - common/env/keycloak.env
    networks:
      glseven:
        ipv4_address: 172.18.3.3
    ports:
      - "48082:8080"   # Admin Console / 认证端点
    healthcheck:
      # 镜像内无 curl/wget（Task 1 实测），改用 bash /dev/tcp 对 9000 管理端口做 TCP 存活探测。
      test: [ "CMD-SHELL", "bash -c '</dev/tcp/127.0.0.1/9000' || exit 1" ]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 60s   # 首启含 Flyway 迁移，较默认延长
```

- `start-dev`：官方开发模式，免 TLS/hostname 配置。
- 端口延续 48xxx 序列（48080 xxl-job、48081 nacos、**48082 keycloak**）。
- 数据全部在 MySQL，容器无状态不挂数据卷。

**common/env/keycloak.env（新增）**：

```
# WARNING: 以下默认凭据仅用于开发环境，生产部署前必须全部修改。
KC_DB=mysql
KC_DB_URL=jdbc:mysql://mysql:3306/keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=keycloak
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=glseven_keycloak_2026
KC_HEALTH_AND_METRICS_ENABLED=true
```

- KC_BOOTSTRAP_ADMIN_* 仅首次启动生效（用于创建初始管理员）。
- 9000 管理端口由 KC_HEALTH_AND_METRICS_ENABLED=true 开启（/health + /metrics），不对宿主机映射，仅供 healthcheck 与 Prometheus 容器网络访问。

**mysql/docker-entrypoint-initdb.d/init.sql 追加**（flush privileges 之前）：

```sql
-- 创建数据库 keycloak
create database `keycloak` character set 'utf8mb4' collate 'utf8mb4_unicode_ci';
-- 创建普通用户 keycloak
create user `keycloak`@`%` identified with caching_sha2_password by 'keycloak';
grant all privileges on `keycloak`.* to `keycloak`@`%`;
```

- 存量库由用户在真实拉起前手动执行本段 SQL（写入 README，沿 2026-09-07 先例）。
- 兼容性注记：Keycloak 官方支持矩阵列到 MySQL 8.4+，9.7 未列入矩阵但 JDBC 协议兼容（与 nacos/xxl-job 跑 9.7 同一先例），开发环境接受，README 注明。

## 4. 优化项

### 4.1 healthcheck 补齐

统一沿用现有探针模板（interval 10s / timeout 5s / retries 10 / start_period 30s；keycloak 60s 特例见 §3.4）：

| 服务 | 探针 |
|---|---|
| rabbitmq | `rabbitmq-diagnostics -q ping` |
| kafka | `/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 > /dev/null 2>&1` |
| openldap | `ldapsearch -x -H ldap://127.0.0.1:389 -b '' -s base` |
| nexus3 | `curl -f http://localhost:8081/service/rest/v1/status` |
| open-webui | `curl -f http://localhost:8080/health` |
| elk | `curl -f http://localhost:9200/` |
| grafana | `curl -f http://localhost:3000/api/health` |
| mongo-express | wget 携带 basic-auth 凭据探测 :8081（$$ 展开容器内 env，凭据改 env 自动跟随） |
| adminer | `curl -f http://127.0.0.1:8080/` |
| php-ldap-admin | `curl -f http://127.0.0.1:8080/` |
| portainer | **不添加探针**——镜像为极简底座、无 shell/curl/wget（实测），compose 注释记录原因 |
| moontv | `wget -q -O /dev/null http://127.0.0.1:3000/` |

- **探针工具实测结论（Task 1）**：adminer/phpldapadmin/nexus3/open-webui/elk/grafana 有 curl；mongo-express/moontv 仅 wget；portainer 无 shell 无 HTTP 工具（不添加探针）；etcd 无 shell（exec 形式）；apisix/keycloak 无 curl/wget 但有 bash（/dev/tcp TCP 探测）。
- 已有 healthcheck 的（mysql/redis/mongo/prometheus/nacos/xxl-job/ollama）不动。
- 联动：openldap 获得探针后，php-ldap-admin 的 `depends_on` 从 `service_started` 升级为 `service_healthy`（同文件内，有效）。

### 4.2 可观测性接入（prometheus/conf/prometheus.yml 新增 4 个 job）

| job_name | 目标 | metrics_path |
|---|---|---|
| apisix | apisix:9091 | /apisix/prometheus/metrics |
| etcd | etcd:2379 | /metrics |
| keycloak | keycloak:9000 | /metrics |
| grafana | grafana:3000 | /metrics |

- 抓取目标全部走服务名，IP 重编零影响。
- 配置注释记录不接入原因：kafka（需 jmx exporter 额外组件）、elk ES（需插件）、moontv（无原生端点）。
- Grafana 数据源已 provision 无需改动；不新增 dashboard（YAGNI）。

### 4.3 导航页更新（portal/html/index.html，分组 9 → 5，卡片 13 → 15）

| 分组 | 卡片（:端口） |
|---|---|
| 基础设施 | Adminer :18080、mongo-express :18081、RabbitMQ 管理 :15672 |
| 认证与身份 | phpLDAPadmin :6080、**Keycloak :48082（新）** |
| 平台服务 | Nacos :48081、XXL-JOB :48080/xxl-job-admin/、Nexus :8081、Portainer :9000、**APISIX :9080（新）** |
| 可观测性 | Prometheus :9090、Grafana :3000、Kibana :5601 |
| 应用 | Open WebUI :8080、MoonTV (LunaTV) :3001 |

- Keycloak 卡片 desc「统一身份认证 SSO」，直链 Admin Console（start-dev 默认根路径）。
- APISIX 官方 Dashboard 项目已退役、无内置 UI：卡片指向 :9080 网关入口，desc 注明 Admin API :9180。
- `data-port` JS 动态拼接宿主机机制保持不变。

### 4.4 env 配置规范化

- 新增 `common/env/keycloak.env`（§3.4，顶部 WARNING 凭据注释，沿惯例）。
- etcd（无必需变量）、APISIX（配置在挂载的 config.yaml）**不建 env 文件**，决策记录于 §3.2/§3.3。
- config.yaml 中 Admin key 处加中文注释说明生成方式与修改影响（沿 phpldapadmin APP_KEY"实施时生成"先例）。
- `.env.example` 与存量 env 文件凭据值均不动。

## 5. 配套文档与联动

- **README.md**：新域结构表与启动批次说明、§2.3 IP 映射表、keycloak 存量库手动 SQL、真实拉起指引（IP 重编导致容器全量重建、数据卷按目录保留）、MySQL 9.7 与 Keycloak 兼容性注记、"版本升级（2026-09）"节补充新服务接入说明。
- `prometheus/conf/prometheus.yml`、`mysql/docker-entrypoint-initdb.d/init.sql`、`portal/html/index.html` 按 §4 更新。
- 删除 9 个旧 compose 文件（§2.4），git 历史可追溯。
- `startup.sh` / `shutdown.sh` 零改动。

## 6. 拉起验证方案（临时卷隔离，存量数据零接触）

1. **静态检查**：6 个 compose `docker compose config -q` 零告警；`bash -n` 校验 startup.sh/shutdown.sh；YAML 配置合法性检查（prometheus.yml 可用 promtool）。
2. **临时环境全量拉起**：`DOCKER_VOLUME=/tmp/glseven-verify COMPOSE_PROJECT_NAME=glseven-verify bash startup.sh`——bind mount 走临时目录、named volume 独立前缀、固定 IP 复用（存量停机状态）。
3. **逐组验证**：
   - BASE：infra 8 服务 + observability 3 服务状态/healthcheck 全绿，关键日志无致命错误。
   - 等 MySQL → DEFERRED：security（openldap 健康、phpldapadmin 就绪、**Keycloak 控制台用 bootstrap admin 登录成功**）、platform（nacos/xxl-job/nexus3 健康、portainer 状态 Up（无探针）、**APISIX Admin API 冒烟**：带 X-API-KEY 请求 `/apisix/admin/routes` 返回 200 JSON）、apps（ollama/open-webui/moontv 抽查）。
   - PORTAL：导航页渲染 15 张卡片，Keycloak/APISIX 卡片链接指向正确端口。
4. **可观测性验证**：Prometheus targets 全 UP（含 apisix/etcd/keycloak/grafana 四个新 job）。
5. **初始化链路验证**：keycloak 库/用户由 init.sql 自动创建；Keycloak 首启 Flyway 迁移无报错。
6. **失败处理**：单服务失败单独修复重验，不阻塞其他组；探针工具缺失类问题按 §4.1 预案处理并记录。
7. **收尾**：`DOCKER_VOLUME=/tmp/glseven-verify COMPOSE_PROJECT_NAME=glseven-verify bash shutdown.sh` + 清理临时目录；用户按 README 指引执行存量库手动 SQL 后 `bash startup.sh` 真实拉起。

## 7. 明确不做（YAGNI）

- APISIX TLS/9443 端口、预置路由规则（路由留给开发自行配置）。
- Keycloak realm 预置导入、OpenLDAP user federation、APISIX OIDC 插件与 Keycloak 的集成演示（均可后续在控制台/配置层操作）。
- APISIX 第三方控制台（官方 Dashboard 已退役，引入第三方属新增决策）。
- Grafana 新增 dashboard、kafka/elk/moontv 指标接入（需额外组件或无原生端点）。
- 存量凭据轮换（WARNING 注释机制已覆盖，用户择机自改）。
- grafana.ini / kibana.yml / provisioning 等未涉配置变更。

## 8. 执行方式

- 沿用仓库惯例：`using-git-worktrees` 创建隔离分支（建议 `apisix-keycloak-redesign`），`writing-plans` 产出任务计划，`subagent-driven-development` 执行（每任务双阶段审查），完成后按 `finishing-a-development-branch` 整合回 develop。
- 验证命令基线：6 个 compose `docker compose config -q` 零告警；脚本 `bash -n`；临时卷全量拉起验证（§6）。

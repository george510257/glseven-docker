# glseven-docker

面向开发环境的微服务基础设施 Docker Compose 编排：7 个职能域、27 个容器（nginx 门户 + 26 个后端服务），统一运行在外部网络 `glseven`（172.18.0.0/16），一键起停、固定 IP、数据落盘宿主目录。

## 快速开始

前置：Docker Compose v2+（compose 文件使用顶层 `name:` 字段）。GPU 场景默认关闭，见下方「已知平台限制」的 ollama GPU 条目。

```shell
# 1. 选择配置档案（local = 本机；sit = 家里测试服务器）
cp .env.local.example .env.local
# sit：cp .env.sit.example .env.sit，并按机器修改 DOCKER_VOLUME / KAFKA_EXTERNAL_HOST

# 2. 首次初始化（一次性，需 sudo）：/etc/hosts 追加 25 个主机名（服务二级域名 = 容器名，门户为 portal，零别名）
echo '127.0.0.1 portal.glseven.local gitlab.glseven.local mysql.glseven.local redis.glseven.local mongo.glseven.local mongo-express.glseven.local adminer.glseven.local rabbitmq.glseven.local kafka.glseven.local etcd.glseven.local prometheus.glseven.local grafana.glseven.local elk.glseven.local openldap.glseven.local php-ldap-admin.glseven.local keycloak.glseven.local nacos.glseven.local xxl-job-admin.glseven.local nexus3.glseven.local portainer.glseven.local apisix.glseven.local ollama.glseven.local open-webui.glseven.local moontv.glseven.local iptv.glseven.local' | sudo tee -a /etc/hosts

# 3. 启动：--profile 选择档案；首次必须显式指定，之后可省略（沿用 .glseven-profile）
bash startup.sh --profile local
# sit：bash startup.sh --profile sit

# 4. 全部入口聚合在导航页（nginx 为唯一持有宿主端口的容器）
open http://portal.glseven.local:8080

# 停止：沿用上次档案；也可显式 bash shutdown.sh --profile sit
bash shutdown.sh
```

两套档案都已被 gitignore，只提交模板。切换档案只需改 `--profile`；启动横幅会打印实际档案与数据目录。直接运行 `docker compose` 时必须带 `--env-file .env.local`（或 `.env.sit`），否则会因缺少 `DOCKER_VOLUME` 明确报错。本机专属的 portal vhost 放 `portal/conf/conf.d/*.local.conf`（已 gitignore，不参与一致性校验），athena 即此类。

存量环境升级时，需在 `/etc/hosts` 追加 `127.0.0.1 portal.glseven.local`。根域条目可以保留，`glseven.local:8080` 会自动 301 到新入口。

数据目录优先级为：显式数据目录参数 > 已导出的 `DOCKER_VOLUME` > 当前档案的 `DOCKER_VOLUME` > 平台默认值。平台默认值在 Linux 为 `/docker/glseven`，在 macOS 为 `$HOME/docker/glseven`（macOS 根卷只读，不能使用 `/docker`）。也可显式指定：`bash startup.sh --profile local /data/glseven`。Linux 上需 root/sudo 执行（脚本按 DIR_SPECS 将数据目录 chown 到容器运行 uid）；macOS Docker Desktop 无此要求。

修改当前档案的 `REDIS_PASSWORD` 后需同时重建 redis 与 moontv：重新执行 `bash startup.sh`（沿用上次档案）即可。

## 七域结构与启动时序

| 域（包） | 服务（容器内固定 IP 末位） | IP 段 | 启动批次 |
|---|---|---|---|
| infra | mysql .1、redis .2、mongo .3、mongo-express .4、adminer .5、rabbitmq .6、kafka .7、etcd .8 | 172.18.1.x | BASE |
| observability | prometheus .1、grafana .2、elk .3、filebeat .4 | 172.18.2.x | BASE |
| security | openldap .1、php-ldap-admin .2、keycloak .3 | 172.18.3.x | DEFERRED |
| platform | nacos .1、xxl-job-admin .2、nexus3 .3、portainer .4、apisix .5 | 172.18.4.x | DEFERRED |
| apps | ollama .1、open-webui .2、moontv .3、iptv .4 | 172.18.5.x | DEFERRED |
| devops | gitlab .1、gitlab-runner .2 | 172.18.7.x | DEVOPS（仅 sit） |
| portal | nginx .1 | 172.18.6.x | PORTAL |

每个域一个目录：compose 为 `<域>/docker-compose.yml`，该域服务 env 在 `<域>/env/`，配置目录与 compose 同包。

批次时序（`common/compose-list.sh` 是唯一数据源，startup.sh / shutdown.sh 消费）：

- **BASE**：先起数据、消息与监控底座。
- **MySQL 健康闸门**：startup.sh 等待 mysql healthcheck 通过（超时 120s）。
- **DEFERRED**：keycloak / nacos / xxl-job-admin 依赖 MySQL 完成初始化。
- **PORTAL**：最后启动导航门户（保证导航目标先就绪）。
- 跨 compose project 的依赖不写 `depends_on`（Docker 不支持跨文件引用），由批次时序 + `restart: always` 兜底。

> **命令迁移**：旧命令 `docker compose -f docker-compose-<域>.yml ...` 已改为 `docker compose --env-file .env.local -f <域>/docker-compose.yml ...`；`--env-file` 必须带，否则档案文件中的 `REDIS_PASSWORD` 不会被读取。

## 服务访问入口

**nginx（portal）是唯一持有宿主端口的容器**（28 个端口：8080 共享入口（门户 + GitLab + 6 个原生服务）+ 10 个原生 http 监听 + 17 条 stream），其余 26 个服务零宿主端口；门户端口按档案绑定：local 默认只监听 `127.0.0.1`，sit 默认监听 `0.0.0.0`，由 `PORT_BIND_IP` 覆盖。门户二级域名固定为 `portal.glseven.local`（容器名仍为 `nginx`），其余服务二级域名 = 容器名，URL 端口 = 容器原生端口（门户与 GitLab 因 fnOS 占用 80 改用 8080），需先完成 /etc/hosts 初始化。IP 直连共享端口（3000/8080/8081）由 default_server 统一 302 到门户；根域 `glseven.local:8080` 仅作兼容跳转。

| 服务 | 入口 | 说明 |
|---|---|---|
| 导航门户 | http://portal.glseven.local:8080 | 全部入口聚合（nginx 静态页） |
| Adminer | http://adminer.glseven.local:8080 | MySQL 管理 |
| mongo-express | http://mongo-express.glseven.local:8081 | MongoDB 管理（凭据见 env） |
| RabbitMQ 管理 | http://rabbitmq.glseven.local:15672 | AMQP/MQTT 走下方协议端口 |
| phpLDAPadmin | http://php-ldap-admin.glseven.local:8080 | LDAP 管理（USER ID：`admin`；完整 DN `cn=admin,dc=glseven,dc=com` 等效） |
| Keycloak | http://keycloak.glseven.local:8080 | Admin Console / 认证端点 |
| Nacos | http://nacos.glseven.local:8080 | 控制台（API/gRPC 走下方协议端口） |
| XXL-JOB | http://xxl-job-admin.glseven.local:8080/xxl-job-admin/ | 控制台（context-path 保留前缀） |
| Nexus | http://nexus3.glseven.local:8081 | Web UI（Docker Registry 走 localhost:5000） |
| GitLab | http://gitlab.glseven.local:8080 | 代码仓库与 CI/CD（仅 sit 档案启动） |
| Portainer | http://portainer.glseven.local:9000 | 容器管理 |
| APISIX | http://apisix.glseven.local:9180/ui | Dashboard / Admin API（X-API-KEY 见 profile 的 `APISIX_ADMIN_KEY`）；数据面 :9080 |
| Prometheus | http://prometheus.glseven.local:9090 | 指标（7 个抓取 job） |
| Grafana | http://grafana.glseven.local:3000 | 可视化（数据源已 provision） |
| Kibana | http://elk.glseven.local:5601 | 日志检索（ES API 同域名 :9200） |
| etcd | http://etcd.glseven.local:2379/health | 健康检查 API（`/version`、`/metrics` 可用；stream TCP 透传） |
| Ollama | http://ollama.glseven.local:11434 | API 状态页（stream TCP 透传） |
| Open WebUI | http://open-webui.glseven.local:8080 | LLM 对话 |
| MoonTV | http://moontv.glseven.local:3000 | 影视聚合 |
| iPTV | http://iptv.glseven.local:1905/admin | IPTV 直播源管理后台（M3U /interface.m3u） |

全部端点统一为「域名 + 容器原生端口」。纯 TCP 协议端口由 nginx stream 透明转发（**端口号 = 原生默认**，也可用域名形式如 `mysql.glseven.local:3306`）：
mysql 3306、redis 6379、mongo 27017、AMQP 5673（宿主为避开 NAS 自带 rabbitmq-server 的 5672，容器内仍是原生 5672）、MQTT 1883、MQTT-WS 15675、kafka 29092（宿主/局域网客户端入口，双 listener 见下方「Kafka 双 listener」）、etcd 2379、ldap 389/636、nacos 8848/9848、ollama 11434、beats 5044、registry 5000。

仅容器网络内（未代理）：keycloak 管理端口 9000、apisix prometheus 指标 9091、etcd peer 2380、filebeat 指标 5066（filebeat 是日志生产者，无用户界面，三类同步点检查中整体豁免）。kafka PLAINTEXT 9092 虽经 stream 透传宿主，但 advertised 裸名 `kafka:9092` 宿主不可解析，协议层对宿主不可用，Kafka 客户端一律走 29092（见下方「Kafka 双 listener」）。

## sit CI/CD 平台（devops 域）

`devops/docker-compose.yml` 承载 GitLab CE 与 GitLab Runner，仅在 `--profile sit` 时启动（`common/compose-list.sh` 的 `profile_includes_devops` 门控），本机 `local` 不启动；本机访问 `gitlab.glseven.local:8080` 返回 502 属预期。流水线定义在 `.gitlab-ci.yml`：`develop` 推送自动部署 sit（改动 `devops/docker-compose.yml` 时跳过，需宿主手工部署），`main` 推送创建 tag 与 Release，回滚用手动 `deploy:sit:rollback` 作业。首次引导、备份与排障见 `docs/runbooks/sit-cicd-bootstrap.md`。

## 配置约定

- **env 分层**：每个服务一个 `<域>/env/<service>.env`，compose 通过 `env_file` 引用；含默认凭据的文件顶部有 WARNING 注释，生产部署前必须修改。
- **compose 模板**：`common/base-service.yml` 提供 `service-base` / `service-common` / `service-healthy` 三层模板；各域服务用 `extends: *healthy`（无探针用 `*base`/`*common`）引用，公共字段不要重复。
- **服务互访走服务名**（Docker DNS），不硬编码 IP；固定 IP 仅用于宿主侧排查与防火墙放行。
- **配置档案**：`.env.local` / `.env.sit` 承载机器相关值（`PORT_BIND_IP`、`DOCKER_VOLUME`、`KAFKA_EXTERNAL_HOST`、`REDIS_PASSWORD`、`GRAFANA_ADMIN_PASSWORD`、`APISIX_ADMIN_KEY`、`XXL_JOB_ACCESS_TOKEN`、`KEYCLOAK_ADMIN_PASSWORD`），由 `startup.sh --profile` 选择；缺任一必填键 preflight 会直接失败。`*.local.conf` 为本机专属 vhost，二者均 gitignore。
- **监控接入**：`observability/prometheus/conf/prometheus.yml` 抓取 prometheus / rabbitmq / nacos / apisix / etcd / keycloak / grafana 共 7 个 job；kafka、elk、moontv 不接入的原因见文件内注释。Prometheus 保留 15 天 / 10GB；filebeat 自监控经 Beats monitoring 进入 Kibana Stack Monitoring（5066 是 JSON，不经 Prometheus）；Grafana 预置 Targets 面板。
- **资源上限**：ELK 的 ES 堆 1g / Logstash 512m，Kafka 512m，Nexus 768m；Redis `maxmemory 256mb` + `allkeys-lru`；未设硬 `mem_limit`。
- **日志接入**：`filebeat`（observability 域，172.18.2.4）经 Docker 容器日志接口采集，直发 `elk:5044` 的 logstash；`observability/elk/logstash/config/02-beats-input.conf` 覆盖镜像内置输入为**明文**（内置版要求 TLS）。Kibana 索引前缀为 `filebeat-`（非 `logstash-*`）。
- **新增服务的同步点**：加一个服务要改 5 处——`<域>/docker-compose.yml`（服务定义用 `extends: *healthy`）、`portal/docker-compose.yml`（ports）、`portal/conf/{conf.d,stream-conf.d}/<服务名>.conf`、`portal/html/index.html` 卡片、README 的 /etc/hosts 清单与访问矩阵。`common/check-consistency.sh`（preflight 第 8 步）会机械校验这些同步点，漏改会告警但不阻断启动。

## 容器日志轮转与 etcd 风险边界

- **日志轮转**（Linux 宿主）：preflight 第 7 步幂等写入 `/etc/docker/daemon.json`（`json-file`、max-size 50m、max-file 3；仅当文件不存在时写入，已存在但缺 `log-driver`/`log-opts` 时打印手工合并提示）。daemon 级配置对宿主上全部容器生效，且仅影响之后新建的容器（存量容器需重建才应用）。macOS Docker Desktop 在 Settings → Docker Engine 手工加同样的键。
- **etcd 无认证风险**：etcd 默认无认证且 2379 已透传宿主——宿主上任何进程可读写并改写 APISIX 路由。这是开发环境全量代理的明示决策（见 `docs/superpowers/specs/2026-09-09-nginx-unified-entry-design.md` §4.3）；不要在生产网络复用本编排的 etcd 暴露方式。

## 关键服务要点

### Keycloak 26.7.3

- `start-dev` 官方开发模式（免 TLS/hostname 配置），数据全部在 MySQL `keycloak` 库（容器无状态不挂数据卷）。
- bootstrap admin 用户名见 `security/env/keycloak.env`；口令见 profile 的 `KEYCLOAK_ADMIN_PASSWORD`（仅首次空库初始化生效）。
- 健康与指标端口 9000 由 `KC_HEALTH_ENABLED` + `KC_METRICS_ENABLED` 开启（仅容器网络内，供探针与 Prometheus 抓取）。

### APISIX 3.18.0

- 独立网关组件：数据面 :9080 + Admin API :9180，**路由留空**由微服务开发自行配置（无路由时数据面 404 为预期）。
- 内置 Dashboard 访问入口为 `/ui/`，配置与路由管理走 Admin API，`X-API-KEY` 见当前 profile 的 `APISIX_ADMIN_KEY`（`platform/apisix/conf/config.yaml` 用 `${{APISIX_ADMIN_KEY:=...}}` 读取）。
- 配置存储为 infra 域的 etcd（3.6.14 成熟线）；`allow_admin: 0.0.0.0/0` 由 X-API-KEY 守卫（无/错 key 401），取舍说明见配置文件注释。

### ELK + filebeat 日志闭环

- `sebp/elk` 提供 ES(9200)/Kibana(5601)/logstash(5044)；`filebeat` 采集容器日志发往 logstash，索引前缀 `filebeat-`。
- **`sebp/elk` 镜像不含 filebeat**（上游 Dockerfile 只装 ES/Logstash/Kibana 三件），filebeat 必须独立部署——上游仓库的 `nginx-filebeat/` 也是独立容器示例，本编排方式与其一致。
- 内置 beats 输入**要求 TLS**（镜像自签证书，上游示例 filebeat.yml 即配 `certificate_authorities`），本编排以 `observability/elk/logstash/config/02-beats-input.conf` 覆盖为明文——glseven 为隔离的开发环境网络，与全栈其余明文组件一致。恢复 TLS 的方法见该文件头注释。
- 输入类型用 `filestream` + `parsers.container`，**不是** `type: container`：后者是已弃用的 `log` 输入预设，9.0 起禁用（filebeat 9.x 上直接失效）。
- 按 `container.name` 过滤依赖 `add_docker_metadata` 从日志路径提取容器 ID，两者缺一不可；排除自身与 nginx（后者请求日志量大且已落盘轮转）。
- 探针用 `filebeat test output` 而非 `test config`：后者只校验 YAML 语法，配置对但连不上 logstash 会假报健康。

### Kafka 双 listener（4.3.1）

- 容器网络内：`PLAINTEXT://kafka:9092`（advertised 裸名），微服务客户端 bootstrap 地址写 `kafka:9092`。
- 宿主/局域网：`EXTERNAL://:29092`，经 nginx stream 透传；advertised 地址由当前档案的 `KAFKA_EXTERNAL_HOST` 渲染（local 为 `127.0.0.1`，sit 为宿主局域网 IP）。
- sit 接入：在 `.env.sit` 设置 `KAFKA_EXTERNAL_HOST` 后重建 kafka：`bash startup.sh --profile sit`，或 `docker compose --env-file .env.sit -f infra/docker-compose.yml up -d kafka`。
- 9092 的 nginx stream 透传为存量兼容保留：旧 hosts 接入路径仍可用（PLAINTEXT advertised 仍为裸名），容器网络内客户端直连 `kafka:9092`（Docker DNS，不经 nginx）——但新接入一律走 29092，hosts 路径勿再新增依赖。
- 旧「hosts 条目 `127.0.0.1 kafka`」workaround 已废弃，勿再使用。

### Nacos 客户端 API 鉴权

- 3.2.4 默认关闭客户端 SDK / gRPC / OpenAPI 鉴权；本编排通过 `NACOS_AUTH_ENABLE=true` 显式开启。
- 控制台（8080）与 admin 鉴权一直默认开启；`NACOS_AUTH_TOKEN` / `NACOS_AUTH_IDENTITY_*` 是镜像 entrypoint 的必填项，不能删除。
- 首次访问控制台时按提示初始化管理员用户 `nacos` 的密码；之后客户端需带凭据连接。
- 回滚：只把 `NACOS_AUTH_ENABLE` 设为 `false` 并重建 nacos；不要删除 token/identity。

## 存量环境迁移（10 域 → 6 域，2026-09-08 重设计；devops 为 2026-11 新增的第 7 域）

IP 变化会使容器全量重建；数据卷按 `DOCKER_VOLUME` 子目录绑定不受影响。外部若有硬编码旧 IP，按下表更新：

| 服务 | 旧 IP → 新 IP | | 服务 | 旧 IP → 新 IP |
|---|---|---|---|---|
| mysql | 172.18.1.1（不变） | | openldap | 172.18.3.1（不变） |
| redis | 172.18.1.2（不变） | | php-ldap-admin | 172.18.3.2（不变） |
| mongo | 172.18.1.3（不变） | | nacos | 172.18.7.1 → 172.18.4.1 |
| mongo-express | 172.18.1.4（不变） | | xxl-job-admin | 172.18.7.2 → 172.18.4.2 |
| adminer | 172.18.1.5（不变） | | nexus3 | 172.18.6.1 → 172.18.4.3 |
| rabbitmq | 172.18.2.1 → 172.18.1.6 | | portainer | 172.18.5.1 → 172.18.4.4 |
| kafka | 172.18.2.2 → 172.18.1.7 | | ollama | 172.18.9.1 → 172.18.5.1 |
| prometheus | 172.18.4.1 → 172.18.2.1 | | open-webui | 172.18.9.2 → 172.18.5.2 |
| grafana | 172.18.4.2 → 172.18.2.2 | | moontv | 172.18.8.1 → 172.18.5.3 |
| elk | 172.18.4.3 → 172.18.2.3 | | nginx | 172.18.10.1 → 172.18.6.1 |

### 2026-09-21 审查修复的两项存量迁移（升级前必读）

**1. mongo 启用认证 → 存量无认证卷会锁死**

`infra/docker-compose.yml` 的 mongo 新增了 `command: --auth`，让 `infra/env/mongo.env` 的
`MONGO_INITDB_ROOT_*` 真正生效（此前未启用 auth，该变量只是建了个没人用的用户）。

**但 `MONGO_INITDB_ROOT_*` 只在空数据卷首次初始化时创建用户。** 存量卷若已有数据（在无认证状态下建的），
直接拉起会进入「需要认证但没有任何用户」的状态，**任何客户端都无法登录**。二选一：

```shell
# 方案 A：保留数据——先在旧容器（未加 --auth 时）手工建 root 用户，再升级
docker exec -it mongo mongosh admin --eval '
  db.createUser({user:"root",pwd:"root",roles:[{role:"root",db:"admin"}]})'
# 确认建好后，再 docker compose --env-file .env.local -f infra/docker-compose.yml up -d mongo（sit 用 .env.sit）

# 方案 B：数据可弃——直接重建（会清空 mongo 数据）
bash shutdown.sh && sudo rm -rf "$DOCKER_VOLUME/mongo/data" && bash startup.sh
```

**2. kafka 数据开始落盘 → 存量数据在容器可写层，升级即丢**

kafka 此前未设 `KAFKA_LOG_DIRS`，数据实际写在 `/tmp/kafka-logs`（容器可写层），
每次 `shutdown.sh` 全部丢失。现已在 `infra/env/kafka.env` 补上 `KAFKA_LOG_DIRS=/var/lib/kafka/data`
与固定 `KAFKA_CLUSTER_ID`，数据开始落宿主机卷。

首次重建后角色相反：**此前容器可写层里的数据不会被迁移**，重建即丢一次（本就留不住）；
此后 `shutdown.sh` 不再丢数据。若存量环境有需要保留的消息，请在重建前自行导出。
另需确认宿主机 `$DOCKER_VOLUME/kafka/data` 属主为 1000（startup.sh 已纳入 DIR_SPECS 自动处理）。

### Keycloak 存量库 SQL（仅存量 MySQL 需手动执行一次；全新初始化由 init.sql 自动完成）

真实拉起顺序：执行本 SQL → `bash startup.sh`。

```sql
create database `keycloak` character set 'utf8mb4' collate 'utf8mb4_unicode_ci';
create user `keycloak`@`%` identified with caching_sha2_password by 'keycloak';
grant all privileges on `keycloak`.* to `keycloak`@`%`;
flush privileges;
```

### 存量数据卷升级注意（2026-09 全量镜像升级）

升级在首次 `bash startup.sh` 拉起时自动完成（MySQL 9.7 数据字典、Grafana 13 unified storage、Open WebUI DB 迁移、Elasticsearch 9.5 等均为自动且**不可逆**，拉起前请确认已有备份）：

1. **RabbitMQ**：升级前在旧容器执行一次 `docker exec rabbitmq rabbitmqctl enable_feature_flag all`（4.3 硬性前置）。
2. **nacos**（库 nacos_devtest）：init 脚本只对全新初始化生效，存量库需手动执行 `infra/mysql/docker-entrypoint-initdb.d/nacos-mysql.sql` 末尾 3 张新表 DDL（pipeline_execution / ai_resource / ai_resource_version）；不执行则 v3.2 新功能不可用，核心功能不受影响。
3. **xxl-job**（库 xxl_job）5 条 ALTER + 1 条可选索引清理：

   ```sql
   create index I_jobgroup on xxl_job_log (job_group);
   alter table xxl_job_group modify title varchar(64) not null comment '执行器名称';
   alter table xxl_job_registry modify id bigint(20) NOT NULL AUTO_INCREMENT;
   alter table xxl_job_info modify executor_param text null comment '任务参数';
   alter table xxl_job_log modify executor_param text null comment '任务参数';
   drop index i_jobid_jobgroup on xxl_job_log; -- 可选：3.4.2 已改用单列 I_jobgroup，旧复合索引可清理
   ```

4. **Kafka**（可选）：稳定后执行 `docker exec kafka /opt/kafka/bin/kafka-features.sh --bootstrap-server localhost:9092 upgrade --release-version 4.3` 固化元数据版本；不固化保持兼容模式（可回滚），固化后不可降级。
5. **下线与维持**：libretv 已下线（上游停更，MoonTV 保留）；mongo-express 与 openldap 维持旧版（上游无稳定新版），属技术债。
6. **XXL-JOB context-path**：本地保留 `/xxl-job-admin` 前缀（application.properties 自定义），执行器侧 `xxl.job.admin.addresses` 需保持带此前缀。

## 批次 3 升级清单（2026-11-22）

- **profile 追加五个键**（不要覆盖现有文件）：`PORT_BIND_IP`、`GRAFANA_ADMIN_PASSWORD`、`APISIX_ADMIN_KEY`、`XXL_JOB_ACCESS_TOKEN`、`KEYCLOAK_ADMIN_PASSWORD`；sit 宿主需同步补 `.env.sit`，否则 `deploy:sit` 会在 preflight 失败。
- **filebeat 需要重建**才能加载新的 monitoring 配置：
  `docker compose --env-file .env.sit -f observability/docker-compose.yml up -d --force-recreate filebeat`
- **Grafana 管理员口令仅首次初始化生效**：存量实例用 `docker exec grafana grafana cli admin reset-admin-password <new-password>` 重置。
- **Keycloak bootstrap 口令仅首次空库初始化生效**；存量库不受影响。

## 备份与恢复（backup.sh）

```bash
bash backup.sh --profile sit          # 或沿用 .glseven-profile
BACKUP_DIR=/path KEEP_BACKUPS=14 bash backup.sh --profile sit   # 覆盖目录/保留份数
```

- 输出到 `${BACKUP_DIR:-$DOCKER_VOLUME/backup}/<YYYYmmdd-HHMMSS>/`，目录权限 700。
- 内容：`mysql.sql`（全库）、`mongo.archive.gz`、`gitlab-config.tar.gz`（存在时）、`MANIFEST.txt`。
- 保留最近 7 份；成功后按目录名倒序裁剪。
- 不备份 Nexus blob、Kafka/ELK 数据、Prometheus 指标；GitLab 仓库数据用 `docker exec gitlab gitlab-backup create`。
- 恢复：
  - 以下命令中的 `$DOCKER_VOLUME` 指当前档案里的实际路径；普通新 shell 未导出时，先 `source .env.sit`（或 `.env.local`）或手动替换。
  - MySQL：`docker exec -i mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < mysql.sql`（建议空库/新卷）。
  - Mongo：`docker exec -i mongo sh -c 'mongorestore --archive --gzip --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' < mongo.archive.gz`（建议空库/新卷；在已有库上恢复可加 `--drop`）。
  - GitLab config：停止 gitlab 后 `tar -xzf gitlab-config.tar.gz -C "$DOCKER_VOLUME/gitlab"`。

## 已知平台限制（宿主环境，非编排缺陷）

- **elk**（sebp/elk，amd64-only 镜像）：Apple Silicon macOS 的 Rosetta 模拟层不翻译 seccomp 系统调用，Elasticsearch 9 启动即失败（错误特征 `seccomp unavailable: CONFIG_SECCOMP not compiled into kernel`）；Linux amd64 主机正常。`startup.sh` 在 Apple Silicon 上会自动跳过 `elk/filebeat`，继续启动 Prometheus、Grafana 和其余域；ELK 日志检索入口不可用。内存受限环境可通过 `ES_JAVA_OPTS` / `LS_HEAP_SIZE` 降低 JVM 堆。
- **Portainer 初始化**：创建 admin 前需从容器日志取 Setup token（`docker logs portainer 2>&1 | grep setup_token`，每次重启会刷新）；且 5 分钟未完成初始化会自动锁定（页面不可操作），需 `docker restart portainer` 后用新 token 重来。初始化请求经 nginx 时需保留原始 Host 头（已在 snippets/proxy.conf 用 `$http_host` 配置）。
- **phpLDAPadmin 登录**：登录者必须是目录内真实条目，而 osixia/openldap 只把 `cn=admin` 设为 olcRootDN（DB 级 bind 凭据，无目录条目），因此仓库附 `security/openldap/bootstrap/admin-entry.ldif`（含 `uid=admin`），首次初始化卷后需导入一次（命令见该文件头注释），导入后 USER ID 填 `admin` 登录（bind 实际走 olcRootDN，具全权）。登录后若见一次 500 页，刷新即可（登录表单闪存残留，一次性）。另：PLA 检索用户需绑定搜索账号（默认 ACL 拒匿名读），见 `security/env/phpldapadmin.env`。
- **Registry :5000**：端口绑定主体是 nginx（portal），但 macOS 上该端口仍可能被 AirPlay Receiver（ControlCenter 进程）占用导致容器启动报 `port is already allocated`，需在系统设置关闭 AirPlay Receiver（全栈唯一需宿主侧配合的端口）。
- **GitLab/Runner（devops 域）**：仅 `sit` 档案启动（`profile_includes_devops` 门控）；本机 `local` 访问 `gitlab.glseven.local:8080` 返回 502 属预期。GitLab 常驻约 3–3.5 GiB，legion 可用内存约 6 GiB 时需限制构建并发（runner `concurrent = 1`）。
- **ollama GPU**：GPU 请求默认关闭（apps/docker-compose.yml 中 `deploy.resources.reservations` 为注释块）。Linux 宿主如需 GPU 加速，取消该注释块后 `docker compose --env-file .env.local -f apps/docker-compose.yml up -d ollama`，要求 NVIDIA 驱动 ≥550（旧卡 ≥570）；macOS Docker Desktop 无 nvidia device driver，保持默认 CPU 运行。
- **open-webui 首启**：需从 HuggingFace 下载 embedding 模型，网络受限环境可用环境变量 `HF_ENDPOINT=https://hf-mirror.com` 指向镜像源。
- **filebeat 挂 docker.sock**：以 `user: root` 运行并只读挂载 `/var/run/docker.sock` 与 `/var/lib/docker/containers`（采集容器日志所需）。Docker Desktop（macOS/Windows）下这些路径由 VM 侧提供，通常可直接工作；若日志采集为空，先 `docker logs filebeat` 看是否为 socket 路径差异。该容器的 docker.sock 是**只读**挂载，不具备改写宿主 Docker 状态的能力。

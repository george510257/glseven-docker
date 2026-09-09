# glseven-docker

面向开发环境的微服务基础设施 Docker Compose 编排：6 个职能域、23 个服务，统一运行在外部网络 `glseven`（172.18.0.0/16），一键起停、固定 IP、数据落盘宿主目录。

## 快速开始

前置：Docker Compose v2+（compose 文件使用顶层 `name:` 字段）；GPU 场景要求宿主机 NVIDIA 驱动 ≥550（旧卡 ≥570）。

```shell
# 1. 准备环境变量（.env 提供 DOCKER_VOLUME / REDIS_PASSWORD 等插值，无 .env 时使用内置默认值）
cp .env.example .env

# 2. 首次初始化（一次性，需 sudo）：/etc/hosts 追加 23 个主机名（二级域名 = 容器名，零别名）
echo '127.0.0.1 glseven.local mysql.glseven.local redis.glseven.local mongo.glseven.local mongo-express.glseven.local adminer.glseven.local rabbitmq.glseven.local kafka.glseven.local etcd.glseven.local prometheus.glseven.local grafana.glseven.local elk.glseven.local openldap.glseven.local php-ldap-admin.glseven.local keycloak.glseven.local nacos.glseven.local xxl-job-admin.glseven.local nexus3.glseven.local portainer.glseven.local apisix.glseven.local ollama.glseven.local open-webui.glseven.local moontv.glseven.local' | sudo tee -a /etc/hosts

# 3. 启动：BASE 批次 → 等待 MySQL 健康 → DEFERRED 批次 → PORTAL
bash startup.sh

# 4. 全部入口聚合在导航页（nginx 为唯一持有宿主端口的容器）
open http://glseven.local:8000

# 停止：按启动逆序 down 并移除 glseven 网络
bash shutdown.sh
```

数据目录由 startup.sh 的第一个参数指定（默认 `/docker/glseven`）：`bash startup.sh /data/glseven`。Linux 上需 root/sudo 执行（脚本将 nexus3/prometheus/grafana/elk 数据目录 chown 到容器运行 uid）；macOS Docker Desktop 无此要求。

修改 `REDIS_PASSWORD` 后需同时重建 redis 与 moontv：重新执行 `bash startup.sh` 即可。

## 六域结构与启动时序

| 域（compose 文件） | 服务（容器内固定 IP 末位） | IP 段 | 启动批次 |
|---|---|---|---|
| infra | mysql .1、redis .2、mongo .3、mongo-express .4、adminer .5、rabbitmq .6、kafka .7、etcd .8 | 172.18.1.x | BASE |
| observability | prometheus .1、grafana .2、elk .3 | 172.18.2.x | BASE |
| security | openldap .1、php-ldap-admin .2、keycloak .3 | 172.18.3.x | DEFERRED |
| platform | nacos .1、xxl-job-admin .2、nexus3 .3、portainer .4、apisix .5 | 172.18.4.x | DEFERRED |
| apps | ollama .1、open-webui .2、moontv .3 | 172.18.5.x | DEFERRED |
| portal | nginx .1 | 172.18.6.x | PORTAL |

批次时序（`common/compose-list.sh` 是唯一数据源，startup.sh / shutdown.sh 消费）：

- **BASE**：先起数据、消息与监控底座。
- **MySQL 健康闸门**：startup.sh 等待 mysql healthcheck 通过（超时 120s）。
- **DEFERRED**：keycloak / nacos / xxl-job-admin 依赖 MySQL 完成初始化。
- **PORTAL**：最后启动导航门户（保证导航目标先就绪）。
- 跨 compose project 的依赖不写 `depends_on`（Docker 不支持跨文件引用），由批次时序 + `restart: always` 兜底。

## 服务访问入口

**nginx（portal）是唯一持有宿主端口的容器**（26 个端口：8000 门户 + 10 个原生 http 监听 + 15 条 stream），其余 22 个服务零宿主端口；二级域名 = 容器名，URL 端口 = 容器原生端口，需先完成 /etc/hosts 初始化。

| 服务 | 入口 | 说明 |
|---|---|---|
| 导航门户 | http://glseven.local:8000 | 全部入口聚合（nginx 静态页） |
| Adminer | http://adminer.glseven.local:8080 | MySQL/Mongo 管理 |
| mongo-express | http://mongo-express.glseven.local:8081 | MongoDB 管理（凭据见 env） |
| RabbitMQ 管理 | http://rabbitmq.glseven.local:15672 | AMQP/MQTT 走下方协议端口 |
| phpLDAPadmin | http://php-ldap-admin.glseven.local:8080 | LDAP 管理 |
| Keycloak | http://keycloak.glseven.local:8080 | Admin Console / 认证端点 |
| Nacos | http://nacos.glseven.local:8080 | 控制台（API/gRPC 走下方协议端口） |
| XXL-JOB | http://xxl-job-admin.glseven.local:8080/xxl-job-admin/ | 控制台（context-path 保留前缀） |
| Nexus | http://nexus3.glseven.local:8081 | Web UI（Docker Registry 走 localhost:5000） |
| Portainer | http://portainer.glseven.local:9000 | 容器管理 |
| APISIX | http://apisix.glseven.local:9080 | 数据面（Admin API 同域名 :9180，X-API-KEY 见 apisix/conf/config.yaml） |
| Prometheus | http://prometheus.glseven.local:9090 | 指标（7 个抓取 job） |
| Grafana | http://grafana.glseven.local:3000 | 可视化（数据源已 provision） |
| Kibana | http://elk.glseven.local:5601 | 日志检索（ES API 同域名 :9200） |
| etcd | http://etcd.glseven.local:2379 | REST/health/metrics（stream TCP 透传，curl 可用） |
| Ollama | http://ollama.glseven.local:11434 | API 状态页（stream TCP 透传） |
| Open WebUI | http://open-webui.glseven.local:8080 | LLM 对话 |
| MoonTV | http://moontv.glseven.local:3000 | 影视聚合 |

全部端点统一为「域名 + 容器原生端口」。纯 TCP 协议端口由 nginx stream 透明转发（**端口号 = 原生默认**，也可用域名形式如 `mysql.glseven.local:3306`）：
mysql 3306、redis 6379、mongo 27017、AMQP 5672（由 35672 回归默认）、MQTT 1883、MQTT-WS 15675、kafka 9092、etcd 2379、ldap 389/636、nacos 8848/9848、ollama 11434、beats 5044、registry 5000。

仅容器网络内（未代理）：keycloak 管理端口 9000、apisix prometheus 指标 9091、etcd peer 2380。

## 配置约定

- **env 分层**：每个服务一个 `common/env/<service>.env`，compose 通过 `env_file` 引用；含默认凭据的文件顶部有 WARNING 注释，生产部署前必须修改。
- **服务互访走服务名**（Docker DNS），不硬编码 IP；固定 IP 仅用于宿主侧排查与防火墙放行。
- **监控接入**：`prometheus/conf/prometheus.yml` 抓取 prometheus / rabbitmq / nacos / apisix / etcd / keycloak / grafana 共 7 个 job；kafka、elk、moontv 不接入的原因见文件内注释。

## 关键服务要点

### Keycloak 26.7.3

- `start-dev` 官方开发模式（免 TLS/hostname 配置），数据全部在 MySQL `keycloak` 库（容器无状态不挂数据卷）。
- bootstrap admin 凭据见 `common/env/keycloak.env`（仅首次启动生效；WARNING：生产前必须修改）。
- 健康与指标端口 9000 由 `KC_HEALTH_ENABLED` + `KC_METRICS_ENABLED` 开启（仅容器网络内，供探针与 Prometheus 抓取）。

### APISIX 3.18.0

- 独立网关组件：数据面 :9080 + Admin API :9180，**路由留空**由微服务开发自行配置（无路由时数据面 404 为预期）。
- 无内置 UI（官方 Dashboard 已退役），管理走 Admin API，`X-API-KEY` 见 `apisix/conf/config.yaml`。
- 配置存储为 infra 域的 etcd（3.6.14 成熟线）；`allow_admin: 0.0.0.0/0` 由 X-API-KEY 守卫（无/错 key 401），取舍说明见配置文件注释。

## 存量环境迁移（10 域 → 6 域，2026-09-08 重设计）

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
2. **nacos**（库 nacos_devtest）：init 脚本只对全新初始化生效，存量库需手动执行 `mysql/docker-entrypoint-initdb.d/nacos-mysql.sql` 末尾 3 张新表 DDL（pipeline_execution / ai_resource / ai_resource_version）；不执行则 v3.2 新功能不可用，核心功能不受影响。
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

## 已知平台限制（宿主环境，非编排缺陷）

- **elk**（sebp/elk，amd64-only 镜像）：Apple Silicon macOS 的 Rosetta 模拟层不翻译 seccomp 系统调用，Elasticsearch 9 启动即失败（错误特征 `seccomp unavailable: CONFIG_SECCOMP not compiled into kernel`）；Linux amd64 主机正常。内存受限环境可通过 `ES_JAVA_OPTS` / `LS_JAVA_OPTS` 降低 JVM 堆。
- **Registry :5000**：端口绑定主体是 nginx（portal），但 macOS 上该端口仍可能被 AirPlay Receiver（ControlCenter 进程）占用导致容器启动报 `port is already allocated`，需在系统设置关闭 AirPlay Receiver（全栈唯一需宿主侧配合的端口）。
- **ollama GPU**：`deploy.resources.reservations` 的 nvidia 设备声明仅在具备 NVIDIA 驱动的 Linux 主机生效；macOS Docker Desktop 无 nvidia device driver，容器会创建失败，验证时需临时去掉该段。
- **open-webui 首启**：需从 HuggingFace 下载 embedding 模型，网络受限环境可用环境变量 `HF_ENDPOINT=https://hf-mirror.com` 指向镜像源。

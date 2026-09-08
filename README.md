# glseven-docker

开发环境docker服务

## 使用

需 Docker Compose v2+（compose 文件使用顶层 `name:` 字段）。

```shell
# 准备环境变量（调整 DOCKER_VOLUME / REDIS_PASSWORD，无 .env 时使用内置默认值）
cp .env.example .env

# 启动：先起基础设施（infra/observability），等待 MySQL 健康后再起依赖服务（security/platform/apps）
bash startup.sh

# 停止：按启动顺序逆序 down 并移除网络
bash shutdown.sh
```

修改 REDIS_PASSWORD 后需同时重建 redis 与 moontv：`bash startup.sh` 重新执行即可。

### 六域编排结构（2026-09-08 重设计）

10 个 compose 文件合并为 6 个职能域，统一外部网络 `glseven`（172.18.0.0/16）：

| 域（compose 文件） | 服务 | IP 段 | 启动批次 |
|---|---|---|---|
| infra | mysql redis mongo mongo-express adminer rabbitmq kafka etcd | 172.18.1.x | BASE |
| observability | prometheus grafana elk | 172.18.2.x | BASE |
| security | openldap php-ldap-admin keycloak | 172.18.3.x | DEFERRED |
| platform | nacos xxl-job-admin nexus3 portainer apisix | 172.18.4.x | DEFERRED |
| apps | ollama open-webui moontv | 172.18.5.x | DEFERRED |
| portal | nginx | 172.18.6.x | PORTAL |

新增服务：etcd（APISIX 配置存储，无对外端口）、APISIX（:9080 数据面 / :9180 Admin API，路由留空由开发自行配置）、Keycloak（:48082 Admin Console，`start-dev` 模式，MySQL 存储）。

服务间互访走服务名（Docker DNS）；外部若硬编码旧 IP，按下表更新。IP 变化会使容器全量重建，数据卷按 `DOCKER_VOLUME` 子目录绑定不受影响：

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

#### Keycloak 存量库 SQL（仅存量 MySQL 需手动执行一次；全新初始化由 init.sql 自动完成）

```sql
create database `keycloak` character set 'utf8mb4' collate 'utf8mb4_unicode_ci';
create user `keycloak`@`%` identified with caching_sha2_password by 'keycloak';
grant all privileges on `keycloak`.* to `keycloak`@`%`;
flush privileges;
```

真实拉起顺序：执行本 SQL → `bash startup.sh`。

#### 新服务兼容性注记

- Keycloak 官方支持矩阵列到 MySQL 8.4+；9.7 未列入矩阵但 JDBC 协议兼容（与 nacos/xxl-job 跑 9.7 同一先例）。
- etcd 选 3.6.14 成熟线（3.7.1 已发布但仅 2 个月，优先保障 APISIX 互操作稳定）。
- APISIX 无内置 UI（官方 Dashboard 已退役）；管理走 Admin API :9180（X-API-KEY 见 `apisix/conf/config.yaml`）。
- Keycloak 默认凭据见 `common/env/keycloak.env`（WARNING：生产部署前必须修改；bootstrap admin 仅首次启动生效）。

### 导航门户

全部 Web UI 的入口聚合在导航页：`http://<宿主机>:8000`（nginx 静态页，链接自动指向当前宿主机）。

### 版本升级（2026-09）

本次将全部镜像升至最新稳定版。**存量数据卷的升级在首次 `bash startup.sh` 拉起时自动完成**（MySQL 9.7 数据字典、Grafana 13 unified storage、Open WebUI DB 迁移、Elasticsearch 9.5 等均为自动且不可逆，拉起前请确认已有备份）。

升级前后注意：

1. **RabbitMQ**：升级前在旧容器执行一次 `docker exec rabbitmq rabbitmqctl enable_feature_flag all`（4.3 硬性前置）。
2. **存量数据库手动 SQL**（init 脚本只对全新初始化生效）：
   - nacos（库 nacos_devtest）：执行 `mysql/docker-entrypoint-initdb.d/nacos-mysql.sql` 末尾 3 张新表 DDL（pipeline_execution / ai_resource / ai_resource_version）；不执行则 v3.2 新功能不可用，核心功能不受影响。
   - xxl-job（库 xxl_job）5 条 ALTER + 1 条可选索引清理：

     ```sql
     create index I_jobgroup on xxl_job_log (job_group);
     alter table xxl_job_group modify title varchar(64) not null comment '执行器名称';
     alter table xxl_job_registry modify id bigint(20) NOT NULL AUTO_INCREMENT;
     alter table xxl_job_info modify executor_param text null comment '任务参数';
     alter table xxl_job_log modify executor_param text null comment '任务参数';
     drop index i_jobid_jobgroup on xxl_job_log; -- 可选：3.4.2 已改用单列 I_jobgroup，旧复合索引可清理
     ```

3. **Kafka**（可选）：稳定后执行 `docker exec kafka /opt/kafka/bin/kafka-features.sh --bootstrap-server localhost:9092 upgrade --release-version 4.3` 固化元数据版本；不固化保持兼容模式（可回滚），固化后不可降级。
4. **Ollama**：要求宿主机 NVIDIA 驱动 ≥550（旧卡 ≥570）。
5. **下线与维持**：libretv 已下线（上游停更，MoonTV 保留）；mongo-express 与 openldap 维持旧版（上游无稳定新版），属技术债。
6. **XXL-JOB context-path**：本地保留 `/xxl-job-admin` 前缀（application.properties 自定义），执行器侧 `xxl.job.admin.addresses` 需保持带此前缀。

## kafka

```shell
# 创建broker建通信用户(或称超级用户)
./kafka-configs.sh --zookeeper zookeeper-1:2181 --alter --add-config 'SCRAM-SHA-256=[password=admin-secret],SCRAM-SHA-512=[password=admin-secret]' --entity-type users --entity-name admin

# 创建客户端用户 george
./kafka-configs.sh --zookeeper zookeeper-1:2181 --alter --add-config 'SCRAM-SHA-256=[iterations=8192,password=george-secret],SCRAM-SHA-512=[password=george-secret]' --entity-type users --entity-name george

# 查看SCRAM证书
./kafka-configs.sh --zookeeper zookeeper-1:2181 --describe --entity-type users --entity-name george
```
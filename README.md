# glseven-docker

开发环境docker服务

## 使用

需 Docker Compose v2+（compose 文件使用顶层 `name:` 字段）。

```shell
# 准备环境变量（调整 DOCKER_VOLUME / REDIS_PASSWORD，无 .env 时使用内置默认值）
cp .env.example .env

# 启动：先起基础设施（storage→tv 前置分组），等待 MySQL 健康后再起依赖服务（microservices/ai/tv）
bash startup.sh

# 停止：按启动顺序逆序 down 并移除网络
bash shutdown.sh
```

修改 REDIS_PASSWORD 后需同时重建 redis 与 moontv：`bash startup.sh` 重新执行即可。

### 导航门户

全部 Web UI 的入口聚合在导航页：`http://<宿主机>:8000`（nginx 静态页，链接自动指向当前宿主机）。

### 版本升级（2026-09）

本次将全部镜像升至最新稳定版。**存量数据卷的升级在首次 `bash startup.sh` 拉起时自动完成**（MySQL 9.7 数据字典、Grafana 13 unified storage、Open WebUI DB 迁移、Elasticsearch 9.5 等均为自动且不可逆，拉起前请确认已有备份）。

升级前后注意：

1. **RabbitMQ**：升级前在旧容器执行一次 `docker exec rabbitmq rabbitmqctl enable_feature_flag all`（4.3 硬性前置）。
2. **存量数据库手动 SQL**（init 脚本只对全新初始化生效）：
   - nacos（库 nacos_devtest）：执行 `mysql/docker-entrypoint-initdb.d/nacos-mysql.sql` 末尾 3 张新表 DDL（pipeline_execution / ai_resource / ai_resource_version）；不执行则 v3.2 新功能不可用，核心功能不受影响。
   - xxl-job（库 xxl_job）5 条 ALTER：

     ```sql
     create index I_jobgroup on xxl_job_log (job_group);
     alter table xxl_job_group modify title varchar(64) not null comment '执行器名称';
     alter table xxl_job_registry modify id bigint(20) NOT NULL AUTO_INCREMENT;
     alter table xxl_job_info modify executor_param text null comment '任务参数';
     alter table xxl_job_log modify executor_param text null comment '任务参数';
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
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

## kafka

```shell
# 创建broker建通信用户(或称超级用户)
./kafka-configs.sh --zookeeper zookeeper-1:2181 --alter --add-config 'SCRAM-SHA-256=[password=admin-secret],SCRAM-SHA-512=[password=admin-secret]' --entity-type users --entity-name admin

# 创建客户端用户 george
./kafka-configs.sh --zookeeper zookeeper-1:2181 --alter --add-config 'SCRAM-SHA-256=[iterations=8192,password=george-secret],SCRAM-SHA-512=[password=george-secret]' --entity-type users --entity-name george

# 查看SCRAM证书
./kafka-configs.sh --zookeeper zookeeper-1:2181 --describe --entity-type users --entity-name george
```
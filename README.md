# glseven-docker

开发环境docker服务

## kafka

```shell
# 创建broker建通信用户(或称超级用户)
./kafka-configs.sh --zookeeper zookeeper-1:2181 --alter --add-config 'SCRAM-SHA-256=[password=admin-secret],SCRAM-SHA-512=[password=admin-secret]' --entity-type users --entity-name admin

# 创建客户端用户 george
./kafka-configs.sh --zookeeper zookeeper-1:2181 --alter --add-config 'SCRAM-SHA-256=[iterations=8192,password=george-secret],SCRAM-SHA-512=[password=george-secret]' --entity-type users --entity-name george

# 查看SCRAM证书
./kafka-configs.sh --zookeeper zookeeper-1:2181 --describe --entity-type users --entity-name george
```
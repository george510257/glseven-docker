# 端点矩阵

`<host>` 指当前档案的宿主地址：local 为 `127.0.0.1`，sit 为 `192.168.31.100`。

## 数据库与中间件

| 服务 | 宿主入口 | 容器网络入口 | 凭据/配置位置 | 备注 |
|---|---|---|---|---|
| MySQL | `mysql.glseven.local:3306`（或 `<host>:3306`） | `mysql:3306` | `infra/env/mysql.env`（`MYSQL_ROOT_PASSWORD`，默认值仅供开发） | 库/用户需先创建 |
| Redis | `redis.glseven.local:6379`（或 `<host>:6379`） | `redis:6379` | 根 `.env.<profile>` 的 `REDIS_PASSWORD` | 已启用 `requirepass` |
| MongoDB | `mongo.glseven.local:27017` | `mongo:27017` | `infra/env/mongo.env` | 已启用 `--auth` |
| RabbitMQ | AMQP 宿主 `5673`、管理 UI `15672` | `rabbitmq:5672` | `infra/env/rabbitmq.env` | 宿主 5673 避开 NAS；容器内仍是 5672 |
| Kafka | 宿主/局域网 `29092` | `kafka:9092` | `infra/env/kafka.env` + 根 `.env.<profile>` 的 `KAFKA_EXTERNAL_HOST` | 宿主不要用 9092 |
| etcd | `etcd.glseven.local:2379` | `etcd:2379` | 无认证 | 开发环境明示风险 |
| Nacos | 控制台 `nacos.glseven.local:8080`；客户端宿主 `8848` / gRPC `9848` | `nacos:8848` / `nacos:9848` | `platform/env/nacos.env`；客户端用户名/密码由控制台初始化 | 客户端鉴权已开启 |
| OpenLDAP | `ldap.glseven.local:389/636` | `openldap:389/636` | `security/env/openldap.env` | 首次需导入 admin 条目 |

## UI / 控制台

| 入口 | 地址 |
|---|---|
| 导航门户 | `portal.glseven.local:8000` |
| Adminer | `adminer.glseven.local:8080` |
| mongo-express | `mongo-express.glseven.local:8081` |
| RabbitMQ 管理 | `rabbitmq.glseven.local:15672` |
| phpLDAPadmin | `php-ldap-admin.glseven.local:8080` |
| Keycloak | `keycloak.glseven.local:8080` |
| Nacos | `nacos.glseven.local:8080` |
| XXL-JOB | `xxl-job-admin.glseven.local:8080/xxl-job-admin/` |
| Nexus | `nexus3.glseven.local:8081` |
| GitLab | `gitlab.glseven.local:8929`（仅 sit） |
| Portainer | `portainer.glseven.local:9000` |
| APISIX | `apisix.glseven.local:9180/ui` |
| Prometheus | `prometheus.glseven.local:9090` |
| Grafana | `grafana.glseven.local:3000` |
| Kibana | `elk.glseven.local:5601` |
| Ollama | `ollama.glseven.local:11434` |
| Open WebUI | `open-webui.glseven.local:8080` |
| MoonTV | `moontv.glseven.local:3000` |
| iPTV | `iptv.glseven.local:1905/admin` |

## 解析与端口规则

- 宿主域名解析：开发机 `/etc/hosts` 指向 `127.0.0.1`（local）或 `192.168.31.100`（sit）。
- 共享端口 3000 / 8080 / 8081 只绑定一次，按 `server_name` 分流；裸 IP 会 302 到门户。
- 容器内互访用服务名，不硬编码 IP；固定 IP 仅用于宿主排查。
- 凭据文件头有 WARNING，生产部署前必须修改。

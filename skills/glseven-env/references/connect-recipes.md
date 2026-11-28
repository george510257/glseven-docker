# 连接配方

## 总则

- 优先用环境变量；不要把 host、库名、密码硬编码进代码。
- 容器内用服务名 + 原生端口；开发机用宿主机地址 + 宿主端口。
- `env_file` 里的值不会被 Compose 插值；需要 `${...}` 的变量放 `.env.<profile>` 或部署目录的 `.env`。

## athena：容器内

```dotenv
DB_URL=jdbc:mysql://mysql:3306/athena_auth?useSSL=false&serverTimezone=UTC&characterEncoding=utf8&allowPublicKeyRetrieval=true
DB_USERNAME=athena
DB_PASSWORD=<部署目录 .env>
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=<根 .env.<profile> 的 REDIS_PASSWORD>
NACOS_SERVER_ADDR=nacos:8848
NACOS_USERNAME=<Nacos 控制台创建的用户>
NACOS_PASSWORD=<部署目录 .env>
AUTH_ISSUER=http://athena-auth:8080
AUTH_ISSUER_URI=http://athena-auth:8080
AUTH_SERVICE_URI=http://athena-auth:8080
```

说明：

- `DB_URL` 按服务换库名：`athena_auth`、`athena_system`、`athena_codegen`。
- `DB_USERNAME` / `DB_PASSWORD` 用部署目录 `.env` 里的账号；`REDIS_PASSWORD` 来自 glseven-docker 根 `.env.<profile>`。
- Nacos 用户由环境维护者在控制台创建；服务器端 `NACOS_AUTH_TOKEN` 只用于服务端，不要复制给使用方。
- issuer 用服务名地址 `http://athena-auth:8080`；前端只用相对路径 `/oauth2/token`，不读 OIDC 元数据。若改用域名形式，需要给容器加 `extra_hosts` 指向 portal。

## athena：开发机

把 host 换成宿主地址：sit 用 `192.168.31.100`，local 用 `127.0.0.1`。

```dotenv
DB_URL=jdbc:mysql://192.168.31.100:3306/athena_auth?useSSL=false&serverTimezone=UTC&characterEncoding=utf8&allowPublicKeyRetrieval=true
DB_USERNAME=athena
DB_PASSWORD=<本地 .env>
REDIS_HOST=192.168.31.100
REDIS_PORT=6379
REDIS_PASSWORD=<根 .env.<profile> 的 REDIS_PASSWORD>
NACOS_SERVER_ADDR=192.168.31.100:8848
NACOS_USERNAME=<Nacos 控制台创建的用户>
NACOS_PASSWORD=<本地 .env>
AUTH_ISSUER=http://localhost:8080
AUTH_ISSUER_URI=http://localhost:8080
AUTH_SERVICE_URI=http://localhost:8080
```

## Nacos 客户端鉴权

环境显式开启了客户端鉴权。Spring Cloud Alibaba 需要：

```properties
spring.cloud.nacos.username=<user>
spring.cloud.nacos.password=<password>
```

若仍返回 401/403，再补 `spring.cloud.nacos.discovery.username/password` 与 `spring.cloud.nacos.config.username/password`。Nacos 控制台管理员 `nacos` 的密码在首次初始化时设置。

## Kafka

- 容器内：`kafka:9092`（advertised 裸名，Docker DNS 可解析）。
- 开发机/局域网：`<host>:29092`，其中 `<host>` 由当前档案的 `KAFKA_EXTERNAL_HOST` 决定。
- 不要用宿主 `9092`：它的 advertised 地址是裸名 `kafka:9092`，宿主不可解析。

## 验证命令

```bash
nc -vz 192.168.31.100 3306
mysql -h 192.168.31.100 -P 3306 -uroot -p -e 'select 1'
redis-cli -h 192.168.31.100 -p 6379 -a "$REDIS_PASSWORD" ping
curl -sS -o /dev/null -w '%{http_code}\n' http://nacos.glseven.local:8080/
```

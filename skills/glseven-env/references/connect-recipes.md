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
SPRING_CLOUD_NACOS_USERNAME=<Nacos 控制台创建的用户>
SPRING_CLOUD_NACOS_PASSWORD=<部署目录 .env>
SYSTEM_SERVICE_URI=http://athena-system:8083
CODEGEN_SERVICE_URI=http://athena-codegen:8082
AUTH_SERVICE_URI=http://athena-auth:8080
AUTH_ISSUER=http://athena.glseven.local:8080
AUTH_ISSUER_URI=http://athena-auth:8080
```

说明：

- `DB_URL` 按服务换库名：`athena_auth`、`athena_system`、`athena_codegen`；每个服务在自己的 compose `environment` 里设置。
- `DB_USERNAME` / `DB_PASSWORD` 用部署目录 `.env` 里的账号；`REDIS_PASSWORD` 来自 glseven-docker 根 `.env.<profile>`。
- **只有 `athena-gateway` 使用 Nacos**（`NACOS_SERVER_ADDR` + `SPRING_CLOUD_NACOS_USERNAME/PASSWORD`）；auth/system/codegen 显式关闭了 Nacos discovery/config，不要给它们配 Nacos。
- 网关静态路由需要三个服务地址：`AUTH_SERVICE_URI=http://athena-auth:8080`、`SYSTEM_SERVICE_URI=http://athena-system:8083`、`CODEGEN_SERVICE_URI=http://athena-codegen:8082`；缺一个就会对应前缀 502。
- `AUTH_ISSUER` 会写进 JWT 的 `iss`，用**客户端实际访问的对外地址**（`http://athena.glseven.local:8080`）；容器需要 `extra_hosts` 把该域名指到 portal `172.18.6.1`。
- `AUTH_ISSUER_URI` 是服务间拉 OIDC 元数据/JWKS 的地址，用 `http://athena-auth:8080`。两个变量不要设成同一个值。

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
SPRING_CLOUD_NACOS_USERNAME=<Nacos 控制台创建的用户>
SPRING_CLOUD_NACOS_PASSWORD=<本地 .env>
SYSTEM_SERVICE_URI=http://localhost:8083
CODEGEN_SERVICE_URI=http://localhost:8082
AUTH_SERVICE_URI=http://localhost:8080
AUTH_ISSUER=http://localhost:8080
AUTH_ISSUER_URI=http://localhost:8080
```

## Nacos 客户端鉴权

环境显式开启了客户端鉴权。Spring Cloud Alibaba 需要：

```properties
spring.cloud.nacos.username=<user>
spring.cloud.nacos.password=<password>
```

对应环境变量是 `SPRING_CLOUD_NACOS_USERNAME` / `SPRING_CLOUD_NACOS_PASSWORD`（Spring 的 relaxed binding），不是 `NACOS_USERNAME`。只有 gateway 需要；Nacos 控制台管理员 `nacos` 的密码在首次初始化时设置。

## Kafka

- 容器内：`kafka:9092`（advertised 裸名，Docker DNS 可解析）。
- 开发机/局域网：`<host>:29092`，其中 `<host>` 由当前档案的 `KAFKA_EXTERNAL_HOST` 决定。
- 不要用宿主 `9092`：它的 advertised 地址是裸名 `kafka:9092`，宿主不可解析。

## 验证命令

```bash
nc -vz 192.168.31.100 3306
mysql -h 192.168.31.100 -P 3306 -uroot -p -e 'select 1'
REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h 192.168.31.100 -p 6379 ping
curl -sS -o /dev/null -w '%{http_code}\n' http://nacos.glseven.local:8080/
```

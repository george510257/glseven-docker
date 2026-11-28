# 常见故障

| 现象 | 先查什么 | 常见根因 |
|---|---|---|
| Redis 报 `NOAUTH Authentication required` | 客户端是否设置了 `REDIS_PASSWORD`；值是否来自当前档案 | 环境启用了 `requirepass`，密码为空或用了另一台机器的档案 |
| Nacos 返回 401/403 | gateway 是否配置了 `SPRING_CLOUD_NACOS_USERNAME/PASSWORD`；控制台是否已初始化管理员 | 环境开启了客户端鉴权；只配了 `NACOS_SERVER_ADDR`；把 Nacos 配给了不使用它的 auth/system/codegen |
| Kafka 连接超时 | 宿主是否误用了 `9092`；`KAFKA_EXTERNAL_HOST` 是否为当前档案的地址 | 宿主 `9092` 的 advertised 地址是裸名，宿主不可解析；应使用 `29092` |
| MySQL 报 `Access denied` | 用户名/密码、用户 host 是否为 `%`、`DB_PASSWORD` 是否为空 | 默认密码只适用于开发；用户只允许了 `localhost`；密码环境变量未传 |
| 浏览器被 302 到门户 | 是否用域名访问；请求的 `Host` 头是否保留 | 裸 IP 命中了 `00-default-catchall.conf` 的 default_server |
| `Unknown database` | 目标库是否已创建；连接串里的库名 | 新环境只初始化了部分库；先建库再连 |
| Flyway 跳过 `V1` | `flyway_schema_history` 的 baseline 记录；`baseline-version` | 非空库上 `baseline-on-migrate` 默认把 baseline 记为 1；athena 已改为 `baseline-version: 0` |
| `/etc/hosts` 改了但域名仍不通 | 域名指向的是哪个宿主；当前用的是 local 还是 sit 档案 | 指向了 `127.0.0.1` 却要连 sit，或反之 |
| 容器内连不上宿主地址 | 容器是否在 `glseven` 网络；用的是不是服务名 | 在容器里写了 `localhost` 或宿主端口；应改用服务名 + 原生端口 |

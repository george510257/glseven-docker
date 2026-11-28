---
name: glseven-env
description: 连接或排查 glseven 测试环境的 MySQL、Redis、Nacos、Kafka 等数据库与中间件时使用。覆盖开发机与 glseven 容器网络两种上下文、端点与凭据位置、athena 的环境变量配方和常见故障。
---

# glseven 测试环境：连接与排障

## 何时使用

- 使用方项目要连测试环境的 MySQL、Redis、Nacos、Kafka 等数据库或中间件。
- 连接失败需要定位（401/403、NOAUTH、超时、302）。
- 需要确认某个服务从「开发机」或「容器内」应该用哪个地址。

## 先判断上下文

先问：代码运行在哪里？

- **开发机进程**（IDE、`mvn spring-boot:run`、`pnpm dev`）：走宿主入口。local 档案用 `127.0.0.1`，sit 用 `192.168.31.100`；域名入口需要先在 `/etc/hosts` 指向对应宿主。
- **加入 `glseven` 网络的容器**：走服务名 + 容器原生端口（Docker DNS），不写 IP、不写宿主端口。

不要把两种地址混用：`localhost` 在容器里指容器自己。

## 环境标识

- local：本机 macOS，宿主入口 `127.0.0.1`。
- sit：legion，宿主入口 `192.168.31.100`。
- 机器相关值（宿主地址、`REDIS_PASSWORD` 等）只在 glseven-docker 的 `.env.local` / `.env.sit`；受跟踪的 `*/env/*.env` 只有默认值。

## 端点速查

完整矩阵见 `references/endpoints.md`。最常用的四行：

| 服务 | 开发机（sit） | 容器内 |
|---|---|---|
| MySQL | `mysql.glseven.local:3306` 或 `192.168.31.100:3306` | `mysql:3306` |
| Redis | `redis.glseven.local:6379` 或 `192.168.31.100:6379` | `redis:6379` |
| Nacos | `192.168.31.100:8848`（控制台 `:8080`） | `nacos:8848` |
| Kafka | `192.168.31.100:29092` | `kafka:9092` |

## 凭据规则

- 默认凭据在 glseven-docker 的 `*/env/*.env`，文件头有 WARNING；生产前必须修改。
- 机器相关密码在根 `.env.<profile>`（如 `REDIS_PASSWORD`）。
- 使用方自己的密码放部署目录的 gitignored `.env`（权限 600），不要写进仓库或技能。
- Nacos 客户端用户名/密码由环境维护者在控制台初始化；不要把服务器端 `NACOS_AUTH_TOKEN` 复制给使用方。

## athena 配方

见 `references/connect-recipes.md`：数据库 URL、Redis、Nacos、issuer 与 Kafka 的变量名，以及开发机/容器内两种 host 写法。

## 排障

见 `references/troubleshooting.md`，按「现象 → 先查什么 → 常见根因」组织。

## 安全红线

- 不在代码、配置、技能或日志里写真实密码/token。
- 不把 `.env` 提交到仓库。
- 不把测试环境的默认凭据带到生产。

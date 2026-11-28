# athena 部署示例

## 服务与镜像

| 服务 | 端口 | 镜像 |
|---|---|---|
| `athena-auth` | 8080 | `192.168.31.100:5000/docker-hosted/athena-auth:<tag>` |
| `athena-system` | 8083 | `192.168.31.100:5000/docker-hosted/athena-system:<tag>` |
| `athena-codegen` | 8082 | `192.168.31.100:5000/docker-hosted/athena-codegen:<tag>` |
| `athena-gateway` | 8000/8001 | `192.168.31.100:5000/docker-hosted/athena-gateway:<tag>` |
| `athena-web` | 80 | `192.168.31.100:5000/docker-hosted/athena-web:<tag>` |

## 服务 → 必填环境变量

| 服务 | 必填 | 说明 |
|---|---|---|
| `athena-auth` | `DB_URL`（`athena_auth`）、`DB_USERNAME`、`DB_PASSWORD`、`REDIS_*`、`AUTH_ISSUER`、`AUTH_ISSUER_URI` | 不使用 Nacos |
| `athena-system` | `DB_URL`（`athena_system`）、`DB_USERNAME`、`DB_PASSWORD`、`REDIS_*`、`AUTH_ISSUER_URI` | 不使用 Nacos |
| `athena-codegen` | `DB_URL`（`athena_codegen`）、`DB_USERNAME`、`DB_PASSWORD`、`REDIS_*`、`AUTH_ISSUER_URI` | 不使用 Nacos；Flyway 自动建表 |
| `athena-gateway` | `NACOS_SERVER_ADDR`、`SPRING_CLOUD_NACOS_USERNAME`、`SPRING_CLOUD_NACOS_PASSWORD`、`AUTH_SERVICE_URI`、`SYSTEM_SERVICE_URI`、`CODEGEN_SERVICE_URI`、`AUTH_ISSUER_URI` | 唯一使用 Nacos 的服务 |
| `athena-web` | 无 | 静态产物 + 反代到 `athena-gateway:8000` |

容器内地址：MySQL `mysql:3306`、Redis `redis:6379`、Nacos `nacos:8848`；issuer 对外 `http://athena.glseven.local:8080`，服务间 `http://athena-auth:8080`。完整变量见 `../../glseven-env/references/connect-recipes.md`。

## 构建

后端四个仓库各自执行（凭据由 Maven settings 或环境变量提供，不要放在命令行）：

```bash
mvn -B -s .mvn/settings.xml -Dgh.actor=<user> verify
```

发布顺序：`athena-framework` → `athena-auth` → `athena-system` → `athena-codegen` → `athena-gateway`。

前端先构建共享包，再构建各应用：

```bash
# athena-web-shared
pnpm install && pnpm build
# athena-web-main / athena-web-auth / athena-web-codegen / athena-web-system
pnpm install && pnpm build
# 仅 athena-web-auth：独立门户站点，产物是 dist-portal/
pnpm build:portal
```

把主应用与子应用的 qiankun 产物汇总到一个构建上下文（示例）：

```bash
mkdir -p build
cp -r athena-web-main/dist/.    build/main/
cp -r athena-web-auth/dist/.    build/sub-auth/
cp -r athena-web-codegen/dist/. build/sub-codegen/
cp -r athena-web-system/dist/.  build/sub-system/
```

`athena-web-auth` 的 `dist-portal/` 是 base 为 `/` 的独立站点，单独用 nginx/vhost 托管；不要塞进 `/portal/`，否则资源路径会 404。`Dockerfile.web` 只负责主应用 + 三个 qiankun 子应用。

## 启动顺序

1. `athena-auth`：轮询 `http://athena-auth:8080/.well-known/openid-configuration` 返回 200。
2. `athena-system`、`athena-codegen`。
3. `athena-gateway`（路由源 `GATEWAY_ROUTE_SOURCE=nacos`）。
4. `athena-web`。

## 数据库初始化

```sql
CREATE DATABASE IF NOT EXISTS athena_auth DEFAULT CHARSET utf8mb4;
CREATE DATABASE IF NOT EXISTS athena_system DEFAULT CHARSET utf8mb4;
CREATE DATABASE IF NOT EXISTS athena_codegen DEFAULT CHARSET utf8mb4;
CREATE USER IF NOT EXISTS 'athena'@'%' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON athena_auth.* TO 'athena'@'%';
GRANT ALL PRIVILEGES ON athena_system.* TO 'athena'@'%';
GRANT ALL PRIVILEGES ON athena_codegen.* TO 'athena'@'%';
FLUSH PRIVILEGES;
```

codegen 的建表已改为 Flyway 自动迁移：`athena-codegen/boot/src/main/resources/db/migration/V1__code_data_source.sql`，启动时执行，无需手工建表。存量库注意 `baseline-version: 0`（否则非空库会把 baseline 记为 1 并跳过 V1）。

## Nacos

- 只有 `athena-gateway` 使用 Nacos：配置 `NACOS_SERVER_ADDR=nacos:8848` 与 `SPRING_CLOUD_NACOS_USERNAME/PASSWORD`。
- auth/system/codegen 在 `application.yml` 中显式关闭了 Nacos discovery/config，不要给它们注入 Nacos 变量。
- 网关 `GATEWAY_ROUTE_SOURCE=nacos`，路由在 Nacos 配置；服务间调用走容器名 + 静态路由。

## portal 入口

`portal/conf/conf.d/athena.local.conf`：

```nginx
server {
    listen 8080;
    server_name athena.glseven.local;

    resolver 127.0.0.11 valid=10s ipv6=off;
    set $athena_web "athena-web:80";

    client_max_body_size 64m;

    location / {
        proxy_pass http://$athena_web;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

现有本机文件的上游要从 `web:80` 改为 `athena-web:80`。访问 `http://athena.glseven.local:8080`。

`AUTH_ISSUER` 用该对外地址时，auth 与 gateway 容器需要能解析它：

```yaml
extra_hosts:
  - "athena.glseven.local:172.18.6.1"
```

## 验证（示例账号来自 athena 种子数据，按实际环境替换）

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://athena.glseven.local:8080/
curl -sS -o /dev/null -w '%{http_code}\n' http://athena.glseven.local:8080/micro/sub-auth/
curl -sS -X POST http://athena.glseven.local:8080/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'X-Tenant-Id: 0' \
  -H "Authorization: Basic $(printf 'public-client:secret' | base64)" \
  -d 'grant_type=password&username=superadmin&password=admin123&scope=message.read'
```

## 内存前置

4 个后端（`-Xmx512m`）+ 前端预计 2–2.5 GiB；叠加 GitLab/Runner 后需先调低 fnOS ES 堆（约 11 → 6 GiB）或加内存，再部署。

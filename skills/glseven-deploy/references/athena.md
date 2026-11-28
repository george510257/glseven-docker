# athena 部署示例

## 服务与镜像

| 服务 | 端口 | 镜像 |
|---|---|---|
| `athena-auth` | 8080 | `192.168.31.100:5000/docker-hosted/athena-auth:<tag>` |
| `athena-system` | 8083 | `192.168.31.100:5000/docker-hosted/athena-system:<tag>` |
| `athena-codegen` | 8082 | `192.168.31.100:5000/docker-hosted/athena-codegen:<tag>` |
| `athena-gateway` | 8000/8001 | `192.168.31.100:5000/docker-hosted/athena-gateway:<tag>` |
| `athena-web` | 80 | `192.168.31.100:5000/docker-hosted/athena-web:<tag>` |

## 构建

后端四个仓库各自执行（带 GitHub Packages 凭据）：

```bash
mvn -B -s .mvn/settings.xml -Dgh.actor=<user> -Dgh.token=<PAT> verify
```

发布顺序：`athena-framework` → `athena-auth` → `athena-system` → `athena-codegen` → `athena-gateway`。

前端先构建共享包，再构建各应用：

```bash
# athena-web-shared
pnpm install && pnpm build
# athena-web-main / athena-web-auth / athena-web-codegen / athena-web-system
pnpm install && pnpm build
```

用 `Dockerfile.web` 把 5 份 dist 打进一个 `athena-web` 镜像；`nginx.web.conf` 负责路径与 API 反代。

## 启动顺序

1. `athena-auth`：轮询 `http://athena-auth:8080/.well-known/openid-configuration` 返回 200。
2. `athena-system`、`athena-codegen`。
3. `athena-gateway`（路由源 `GATEWAY_ROUTE_SOURCE=nacos`）。
4. `athena-web`。

## 环境变量

按 `../glseven-env/references/connect-recipes.md` 的容器内配方。issuer 用 `http://athena-auth:8080`；前端只用相对路径 `/oauth2/token`，不读 OIDC 元数据。

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

codegen 的建表 DDL 不在 Flyway 目录，需手工执行一次：

```bash
mysql -h <host> -u athena -p athena_codegen < athena-codegen/boot/src/main/resources/doc/athena-codegen.sql
```

## Nacos

- 在控制台创建 athena 的客户端用户，密码写入部署 `.env`。
- 各服务注册名：`athena-auth`、`athena-system`、`athena-codegen`、`athena-gateway`。
- 网关 `GATEWAY_ROUTE_SOURCE=nacos`，路由在 Nacos 配置；没有路由时数据面 404 属预期。

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

## 验证（示例账号来自 athena 种子数据，按实际环境替换）

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://athena.glseven.local:8080/
curl -sS -X POST http://athena.glseven.local:8080/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'X-Tenant-Id: 0' \
  -H "Authorization: Basic $(printf 'public-client:secret' | base64)" \
  -d 'grant_type=password&username=superadmin&password=admin123&scope=message.read'
```

## 内存前置

4 个后端（`-Xmx512m`）+ 前端预计 2–2.5 GiB；叠加 GitLab/Runner 后需先调低 fnOS ES 堆（约 11 → 6 GiB）或加内存，再部署。

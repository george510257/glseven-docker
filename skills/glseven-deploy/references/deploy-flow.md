# 手动部署流程

以下命令以 `<project>` 和 `<service>` 为占位符；athena 的实例见 `athena.md`。

## 0. 前置检查

- `ssh legion` 可用；Nexus `192.168.31.100:5000` 可用；sit 与开发机都已配置 insecure-registries。
- 开发机 `docker login 192.168.31.100:5000` 成功。
- 资源：

```bash
ssh legion 'free -h && docker stats --no-stream'
```

可用内存不足 2.5–3 GiB 时，先调低 fnOS 自带 ES 堆（约 11 → 6 GiB）或加内存；否则不要继续。

## 1. 构建后端 jar（开发机）

```bash
cd <repo> && mvn -B -s .mvn/settings.xml -Dgh.actor=<user> -Dgh.token=<PAT> verify
```

按项目发布顺序构建；athena 是 auth → system → codegen → gateway。

## 2. 构建并推送镜像（开发机）

```bash
docker buildx build --platform linux/amd64 \
  --build-arg JAR_FILE=boot/target/<service>-boot-<version>.jar \
  -t 192.168.31.100:5000/docker-hosted/<project>-<service>:<tag> --push .
```

前端镜像同理：先用 `pnpm build` 生成 dist，再用 `Dockerfile.web` 构建并推送。

## 3. 准备 sit 部署目录

```bash
ssh legion 'sudo mkdir -p /vol1/1000/projects/<project> && sudo chown 1000:1000 /vol1/1000/projects/<project>'
```

把 compose 与模板复制到该目录；`.env` 权限 600：

```bash
chmod 600 /vol1/1000/projects/<project>/.env
```

## 4. 创建数据库/用户

```bash
ssh -t legion 'docker exec -it mysql mysql -uroot -p'
```

按项目建库、建用户并授权；Flyway 负责表结构，项目特有的手工 DDL 单独执行。

## 5. 启动

```bash
ssh legion 'cd /vol1/1000/projects/<project> && docker compose pull && docker compose up -d && docker compose ps'
```

观察健康状态；`docker logs <container>` 排查启动失败。

## 6. portal 入口

在 sit 的 `portal/conf/conf.d/<project>.local.conf` 写入 `portal-project.conf` 模板（替换占位符）：

```bash
ssh legion 'docker exec nginx nginx -t && docker exec nginx nginx -s reload'
```

`*.local.conf` 是机器专属、gitignored 的文件；glseven-docker 的 `git checkout -f` 不会删除它。

## 7. 验证

- 容器健康：`docker inspect -f '{{.State.Health.Status}}' <container>`。
- 登录 token：按 `athena.md` 的 curl。
- 经门户的 API：`curl -sS -o /dev/null -w '%{http_code}\n' http://<project>.glseven.local:8080/`。
- 日志：Kibana 按 `container.name` 过滤（filebeat 自动采集）。

## 8. 回滚

- 镜像 tag 固定；保留上一版 compose 与 `.env`。
- 把 compose 的 `image:` 改回上一版 tag，`docker compose up -d`。
- 数据库迁移不可逆时，先确认备份；不要依赖 compose 回滚恢复数据。

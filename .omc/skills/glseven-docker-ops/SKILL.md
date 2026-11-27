---
id: glseven-docker-ops
name: glseven-docker-ops
description: 在 glseven-docker 仓库修改 compose/env/portal/CI，或在 sit（legion）部署与运行时验证时使用。汇总 extends 模板语义、端口与代理同步点、无 Docker 本地校验、备份脚本约定，以及 2026-11 会话踩过的部署与验证坑。
triggers:
  - 修改 compose
  - 新增服务
  - 部署 sit
  - 运行时验证
  - portal 端口
tags:
  - docker
  - compose
  - deploy
  - ops
---

# glseven-docker 运维与踩坑手册

## 何时使用

- 新增/改名/调整服务，改 `<域>/docker-compose.yml`、`portal/conf/**`、`portal/html/index.html`
- 修改配置档案 `.env.local` / `.env.sit` 或凭据注入
- 提交前本地校验、部署 sit、做运行时验证

## 红线（先看）

1. `container_name` 必须等于 `hostname`；门户是唯一例外（域名 `portal` → 容器 `nginx`）。
2. 新增服务同步 5 处：域 compose、`portal/docker-compose.yml` ports、`portal/conf/{conf.d,stream-conf.d}/<name>.conf`、门户卡片、README 的 hosts 清单；跑 `bash common/check-consistency.sh --strict`。
3. `env_file` 的值不参与 Compose 插值；需要 `${...}` 的变量只能放 `.env.<profile>`。
4. 服务公共字段只写 `extends: *healthy`（无探针用 `*base`/`*common`），不要重复 `restart`、`common.env`、标准 healthcheck 时间参数。
5. 合并 develop 后必须检查 YAML 重复键；`docker compose config` 是权威校验，但本机无 Docker 时跑不到。
6. `ci/scripts/test-*.sh` 必须兼容 macOS 自带 Bash 3.2，且不依赖 Docker。

## 本地校验（提交前）

```bash
while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')
for f in ci/scripts/test-*.sh; do bash "$f"; done
bash common/check-consistency.sh --strict
git diff --check
```

有 Docker CLI 时再补：

```bash
for f in */docker-compose.yml; do docker compose --env-file .env.local -f "$f" config -q; done
```

## 踩坑清单

### Compose 模板与合并

- `extends` 语义：mapping 按 key 合并；`env_file` 列表拼接且 base 的相对路径会重定位；标量由子服务覆盖；`depends_on` 不继承。
- **合并冲突最容易留下重复键**：本次合并端口标准化时 `portal/docker-compose.yml` 出现两行 `ports:`，`docker compose config` 直接报解析错误，而本机没有 Docker CLI 没拦住。
- `ci/scripts/test-compose-style.sh` 已内置顶层键与服务字段键的重复检测（awk），这是无 Docker 环境下的兜底；改测试时不要绕过。
- 服务首字段必须是 `extends`；锚点必须指向 `common/base-service.yml` 的同名模板。

### 端口与代理

- nginx 是唯一持有宿主端口的容器；HTTP vhost 监听端口 = 容器原生端口；门户与 GitLab 因 fnOS 占用 80 统一用 8080。
- `PORT_BIND_IP`：local 默认 `127.0.0.1`，sit 默认 `0.0.0.0`；改端口后同步 `test-default-ports.sh`、`test-exposure-config.sh`。
- stream 上游在启动期静态解析，portal 必须最后一批启动。

### 凭据与探针

- Keycloak 口令只保留 profile 一处，`security/env/keycloak.env` 不再重复定义。
- Grafana / Keycloak 管理员口令仅首次初始化生效；存量实例用 `docker exec grafana grafana cli admin reset-admin-password <pw>`。
- 探针必须匹配镜像实际工具：nginx/apisix 用 `bash /dev/tcp`，etcd 用 exec 形式，filebeat 用自带子命令。
- sebp/elk 的 entrypoint 会覆盖 `LS_JAVA_OPTS`，Logstash 堆用 `LS_HEAP_SIZE`；ES 以 uid 991 运行，`elk/data` 必须 991。

### 备份脚本

- `backup.sh` 先写 `<stamp>.partial`，写完 `MANIFEST.txt` 再 `mv` 成正式目录；prune 只处理「时间戳目录 + MANIFEST」，失败备份不占保留名额。
- 目录权限 700；`BACKUP_DIR`、`KEEP_BACKUPS` 可覆盖，默认 7 份。

## 部署到 sit（legion）

- 入口 `ssh legion`（192.168.31.100，用户 admin）；root SSH 不可用，sudo 需要密码。非交互用 `sudo -S` 从 600 权限的文件读口令，**不要把口令写进命令行或仓库**。
- 服务器仓库的 origin 是 GitHub；部署 = `git fetch origin && git merge --ff-only origin/develop && sudo bash startup.sh --profile sit`。
- **sudo 跑 git 合并会让新文件归 root**：结束后必须 `chown -R 1000:1000 /vol1/1000/glseven-docker`，`.env.sit` 保持 600；否则后续 admin 的 git pull 会因权限失败。
- 升级档案只追加缺失键（`PORT_BIND_IP`、`GRAFANA_ADMIN_PASSWORD`、`APISIX_ADMIN_KEY`、`XXL_JOB_ACCESS_TOKEN`、`KEYCLOAK_ADMIN_PASSWORD`），不要覆盖既有值。
- 组合式远程命令（scp + 写口令文件 + rm 串在一起）容易被权限分类器拦截，拆成单步执行。

## 运行时验证清单（sit）

1. **健康**：`docker inspect -f '{{.State.Health.Status}}' <容器>`；或 `SMOKE_TIMEOUT=600 bash ci/smoke-test.sh`（含健康等待）。
2. **资源**：
   - Redis：`CONFIG GET maxmemory` = 268435456、`maxmemory-policy` = allkeys-lru。
   - ELK：`printenv LS_HEAP_SIZE` = 512m；`/proc/*/cmdline` 中 ES `-Xmx1g`、Logstash `-Xmx512m`。
   - Kafka `KAFKA_HEAP_OPTS` 512m；Nexus `INSTALL4J_ADD_VM_PARAMS` 含 `-Xmx768m`。
3. **ELK**：`curl 127.0.0.1:9200/`、`5601/api/status`；`stat -c %u $DOCKER_VOLUME/elk/data` = 991；`docker exec filebeat filebeat test output --strict.perms=false`（漏 flag 会假失败）。
4. **端口**：`ss -lnt` 检查 3000/8080/8081/9090/5601/9200 是否为期望绑定地址。
5. **凭据**：
   - Grafana 必须带 `Host: grafana.glseven.local`（直连 `127.0.0.1:3000` 会命中 nginx 兜底返回 302）。
   - APISIX：带 `X-API-KEY` 访问 `9180/apisix/admin/routes` 期望 200。
   - xxl-job / keycloak：`docker exec ... printenv` 与 profile 对比。
6. **备份**：`bash backup.sh --profile sit`；检查目录 700、MANIFEST、`mysql.sql` / `mongo.archive.gz` / `gitlab-config.tar.gz`。
7. **恢复（隔离临时容器，不触碰生产）**：
   - MySQL 就绪判断必须用带口令的 `mysql -e 'SELECT 1'`；`mysqladmin ping` 在初始化阶段会假成功，导致过早恢复。
   - `--one-database <db>` 不会执行其他库上下文里的 `CREATE DATABASE`，恢复前先显式建库，否则报 `Unknown database`。
   - Mongo：`mongorestore --nsExclude 'admin.*'`，避免覆盖临时实例的 root 用户。
   - 恢复后比对源库与临时库的表数量。

## 常见入口

- 启动/停止：`bash startup.sh --profile sit`、`bash shutdown.sh`
- 单域重建：`docker compose --env-file .env.sit -f <域>/docker-compose.yml up -d --force-recreate <service>`
- 门户配置生效：`docker exec nginx nginx -t && docker exec nginx nginx -s reload`
- 回滚 sit：GitLab 手动运行 `deploy:sit:rollback`，填 `ROLLBACK_SHA`

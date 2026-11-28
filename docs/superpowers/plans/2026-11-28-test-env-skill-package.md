# glseven 测试环境技能包 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `glseven-docker` 仓库内新增供使用方项目（首个 athena）消费的技能包：`glseven-env`（连接数据库与中间件）和 `glseven-deploy`（容器化并部署到 sit），含模板、文档与机械校验。

**Architecture:** 两个 Claude Code 技能，内容与环境事实同仓维护；使用方在自己的 `.claude/skills` 建符号链接接入。`ci/scripts/test-skills.sh` 校验 SKILL.md 格式、模板存在性、关键事实与凭据泄漏，并被现有 `ci/validate.sh` 自动收集。

**Tech Stack:** Markdown（SKILL.md + references）、Bash 3.2、Dockerfile / Docker Compose / nginx 模板、现有 CI（`ci/validate.sh`）。

**Spec:** `docs/superpowers/specs/2026-11-28-test-env-skill-package-design.md`

## Global Constraints

- SKILL.md frontmatter 只允许 `name` 与 `description`；`name` 必须与目录名一致，匹配 `^[a-z0-9-]+$`。
- 技能文本不得包含真实凭据；只引用变量名与文件位置。
- 模板镜像名为单段 `<project>-<service>`：`192.168.31.100:5000/docker-hosted/<project>-<service>:<tag>`。
- 模板服务名/容器名/网络别名一律带项目前缀（`<project>-auth`、`<project>-web` 等）。
- 使用方 compose 不得出现宿主 `ports:`；入口统一由 portal 代理。
- 部署流程必须包含 `docker buildx build --platform linux/amd64`。
- 新增 shell 兼容 macOS Bash 3.2，`bash -n` 通过，不依赖 Docker。
- 不修改 `common/check-consistency.sh`、现有 compose/env/portal 配置；只新增 `skills/`、`ci/scripts/test-skills.sh`，并在 README/CLAUDE.md 增加说明。

## Review Focus

- 使用方从宿主连 Kafka 时误用 `9092`：技能必须明确宿主 `KAFKA_EXTERNAL_HOST:29092`、容器内 `kafka:9092`；由 `test-skills.sh` 断言 `connect-recipes.md` 含 `29092`。
- 使用方在共享网络使用短服务名（`auth`/`web`）：模板与 athena 示例必须带 `<project>-` 前缀；由 `test-skills.sh` 断言 compose 模板含 `<project>-<service>`、athena 示例含 `athena-web:80`。
- 使用方在 arm64 开发机上构建出 arm64 镜像推到 amd64 sit：部署流程必须含 `--platform linux/amd64`；由 `test-skills.sh` 断言。
- 使用方 compose 发布宿主端口，绕过 portal 约定：模板不得出现 `ports:`；由 `test-skills.sh` 断言。
- Nacos 客户端鉴权未配置导致 401/403：配方必须含 `NACOS_USERNAME`/`NACOS_PASSWORD`；由 `test-skills.sh` 断言。

---

### Task 1: `glseven-env` 技能与校验脚本

**Files:**
- Create: `ci/scripts/test-skills.sh`
- Create: `skills/glseven-env/SKILL.md`
- Create: `skills/glseven-env/references/endpoints.md`
- Create: `skills/glseven-env/references/connect-recipes.md`
- Create: `skills/glseven-env/references/troubleshooting.md`

**Interfaces:**
- Consumes: 设计文档 §6.2；`README.md` 的服务访问入口；`*/env/*.env` 与 `.env.*.example`。
- Produces: 技能名 `glseven-env`；三个 references 路径；`test-skills.sh` 的 env 检查（Task 2 在其后追加 deploy 检查）。

- [ ] **Step 1: 写失败校验（`ci/scripts/test-skills.sh`）**

```bash
#!/usr/bin/env bash
# 校验 skills/ 包的格式、关键事实与凭据泄漏。无 Docker 依赖，兼容 macOS Bash 3.2。
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

[[ -d skills ]] || fail "skills/ 不存在"

check_skill_frontmatter() {
  local dir="$1" file="$2" name desc keys
  [[ -f "$file" ]] || fail "缺少 $file"
  head -n 1 "$file" | grep -qx -- '---' || fail "$file 首行必须是 ---"
  name="$(awk 'NR==1{next} /^---$/{exit} /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$file")"
  desc="$(awk 'NR==1{next} /^---$/{exit} /^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$file")"
  [[ -n "$name" ]] || fail "$file 缺少 name"
  [[ -n "$desc" ]] || fail "$file 缺少 description"
  [[ "$(basename "$dir")" == "$name" ]] || fail "$file name ($name) 与目录名不一致"
  printf '%s' "$name" | grep -Eq '^[a-z0-9-]+$' || fail "$name 不符合 ^[a-z0-9-]+$"
  keys="$(awk 'NR==1{next} /^---$/{exit} /^[A-Za-z0-9_-]+:/{sub(/:.*/, ""); print}' "$file" | sort -u | tr '\n' ' ')"
  [[ "$keys" == "description name " ]] || fail "$file frontmatter 只允许 name/description，实际: $keys"
}

check_skill_frontmatter skills/glseven-env skills/glseven-env/SKILL.md
pass "glseven-env frontmatter"

for f in endpoints.md connect-recipes.md troubleshooting.md; do
  [[ -f "skills/glseven-env/references/$f" ]] || fail "缺少 skills/glseven-env/references/$f"
done

grep -q '29092' skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未写 Kafka 宿主 29092"
grep -q 'NACOS_USERNAME' skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未写 NACOS_USERNAME"
grep -q 'REDIS_PASSWORD' skills/glseven-env/references/connect-recipes.md || fail "connect-recipes 未写 REDIS_PASSWORD"

# 凭据泄漏：从仓库现有文件动态取值，不在测试里硬编码
for secret in \
  "$(grep -h '^REDIS_PASSWORD=' .env.local.example .env.sit.example 2>/dev/null | head -n 1 | cut -d= -f2-)" \
  "$(grep -h '^NACOS_AUTH_TOKEN=' platform/env/nacos.env 2>/dev/null | head -n 1 | cut -d= -f2-)" \
  "$(grep -h '^NACOS_AUTH_IDENTITY_VALUE=' platform/env/nacos.env 2>/dev/null | head -n 1 | cut -d= -f2-)"; do
  [[ -n "$secret" ]] || continue
  if grep -R -F -q -- "$secret" skills; then
    fail "skills/ 中出现真实凭据：$secret"
  fi
done
pass "skills/ 无已知凭据"

pass "test-skills: 通过"
```

- [ ] **Step 2: 运行校验，确认失败**

Run: `bash ci/scripts/test-skills.sh`
Expected: FAIL，输出 `缺少 skills/glseven-env/SKILL.md`（或 `skills/ 不存在`）。

- [ ] **Step 3: 创建 `skills/glseven-env/SKILL.md`**

frontmatter 必须精确为：

```yaml
---
name: glseven-env
description: 连接或排查 glseven 测试环境的 MySQL、Redis、Nacos、Kafka 等数据库与中间件时使用。覆盖开发机与 glseven 容器网络两种上下文、端点与凭据位置、athena 的环境变量配方和常见故障。
---
```

正文必须包含以下小节（标题文字固定）：

- `# glseven 测试环境：连接与排障`
- `## 何时使用`
- `## 先判断上下文`：开发机进程 vs 加入 `glseven` 网络的容器；前者走宿主入口，后者走服务名 + 容器原生端口。
- `## 环境标识`：local（本机 macOS，`127.0.0.1`）与 sit（legion，`192.168.31.100`）；机器相关值只在 `.env.local` / `.env.sit`。
- `## 端点速查`：指向 `references/endpoints.md`，并列出 MySQL/Redis/Nacos/Kafka 四行最重要的入口。
- `## 凭据规则`：默认值在 `*/env/*.env`，机器相关值在根 `.env.<profile>`；不提交、不写进代码。
- `## athena 配方`：指向 `references/connect-recipes.md`。
- `## 排障`：指向 `references/troubleshooting.md`。
- `## 安全红线`：不在技能或代码中出现真实密码/token；日志不打印凭据。

- [ ] **Step 4: 创建 `references/endpoints.md`**

必须包含两张表，第一张是数据库/中间件，列固定为：`服务 | 宿主入口 | 容器网络入口 | 凭据/配置位置 | 备注`。行内容：

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

第二张是 UI/控制台入口（至少包含）：门户 `portal.glseven.local:8000`、Adminer `adminer.glseven.local:8080`、Nexus `nexus3.glseven.local:8081`、Kibana `elk.glseven.local:5601`、Grafana `grafana.glseven.local:3000`、Prometheus `prometheus.glseven.local:9090`、Portainer `portainer.glseven.local:9000`。

表后必须写清：

- 宿主域名解析：开发机 `/etc/hosts` 指向 `127.0.0.1`（local）或 `192.168.31.100`（sit）；共享端口 3000/8080/8081 按 `server_name` 分流，裸 IP 会 302 到门户。
- 容器内互访用服务名，不硬编码 IP；固定 IP 仅用于宿主排查。
- 凭据文件头有 WARNING，生产部署前必须修改。

- [ ] **Step 5: 创建 `references/connect-recipes.md`**

必须包含：

1. 总则：优先环境变量；开发机与容器内两种 host 写法；不把凭据写进配置。
2. athena 容器内配方（变量名精确）：

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

3. athena 开发机配方：把 host 改为 `192.168.31.100`（sit）或 `127.0.0.1`（local）；数据库名同上。
4. Nacos 客户端鉴权：Spring Cloud Alibaba 需要 `spring.cloud.nacos.username` / `spring.cloud.nacos.password`（或在 athena 配置中补等价项）；控制台管理员 `nacos` 的密码在首次初始化时设置。
5. Kafka：容器内 `kafka:9092`；宿主一律 `<host>:29092`，不要用宿主 `9092`。
6. 验证命令（至少）：

```bash
nc -vz 192.168.31.100 3306
mysql -h 192.168.31.100 -P 3306 -uroot -p -e 'select 1'
redis-cli -h 192.168.31.100 -p 6379 -a "$REDIS_PASSWORD" ping
curl -sS -o /dev/null -w '%{http_code}\n' http://nacos.glseven.local:8080/
```

- [ ] **Step 6: 创建 `references/troubleshooting.md`**

必须覆盖以下条目（每条写「现象 → 先查什么 → 常见根因」）：

- Redis `NOAUTH Authentication required` → 是否设置 `REDIS_PASSWORD`。
- Nacos 401/403 → 客户端用户名/密码、`NACOS_AUTH_ENABLE=true`、控制台初始化。
- Kafka 连接超时 → 宿主是否误用 9092、`KAFKA_EXTERNAL_HOST` 是否正确。
- MySQL `Access denied` → 用户 host 是否为 `%`、密码是否为空、库是否存在。
- 浏览器 302 到门户 → 是否用域名访问、`Host` 头是否保留。
- `Unknown database` → 先建库。
- Flyway 跳过 `V1` → athena 已用 `baseline-version: 0` 修复；存量库检查 `flyway_schema_history`。
- hosts 未生效 → `/etc/hosts` 指向的是当前档案的宿主地址。

- [ ] **Step 7: 运行校验，确认通过**

Run: `bash ci/scripts/test-skills.sh`
Expected: 退出码 0，最后一行 `test-skills: 通过`。

- [ ] **Step 8: shell 语法与空白检查**

Run:
```bash
bash -n ci/scripts/test-skills.sh
git diff --check
```
Expected: 均无输出、退出码 0。

- [ ] **Step 9: 提交**

```bash
git add ci/scripts/test-skills.sh skills/glseven-env \
  docs/superpowers/specs/2026-11-28-test-env-skill-package-design.md \
  docs/superpowers/plans/2026-11-28-test-env-skill-package.md
git commit -m "feat(skills): 新增 glseven-env 使用技能与设计文档"
```

### Task 2: `glseven-deploy` 技能与模板

**Files:**
- Create: `skills/glseven-deploy/SKILL.md`
- Create: `skills/glseven-deploy/references/deploy-flow.md`
- Create: `skills/glseven-deploy/references/athena.md`
- Create: `skills/glseven-deploy/references/templates/Dockerfile.java`
- Create: `skills/glseven-deploy/references/templates/Dockerfile.web`
- Create: `skills/glseven-deploy/references/templates/nginx.web.conf`
- Create: `skills/glseven-deploy/references/templates/docker-compose.project.yml`
- Create: `skills/glseven-deploy/references/templates/portal-project.conf`
- Create: `skills/glseven-deploy/references/templates/gitlab-ci.project.yml`
- Create: `skills/glseven-deploy/references/templates/env.project.example`
- Modify: `ci/scripts/test-skills.sh`（追加 deploy 检查）

**Interfaces:**
- Consumes: `skills/glseven-env/references/endpoints.md`（部署流程引用它，不重复端点表）。
- Produces: 技能名 `glseven-deploy`；七个模板路径；`test-skills.sh` 的 deploy 检查。

- [ ] **Step 1: 给 `ci/scripts/test-skills.sh` 追加 deploy 检查，确认失败**

在 `pass "test-skills: 通过"` 之前插入：

```bash
check_skill_frontmatter skills/glseven-deploy skills/glseven-deploy/SKILL.md
pass "glseven-deploy frontmatter"

for f in Dockerfile.java Dockerfile.web nginx.web.conf docker-compose.project.yml portal-project.conf gitlab-ci.project.yml env.project.example; do
  [[ -f "skills/glseven-deploy/references/templates/$f" ]] || fail "缺少模板 skills/glseven-deploy/references/templates/$f"
done

grep -q 'linux/amd64' skills/glseven-deploy/references/deploy-flow.md || fail "deploy-flow 未写 linux/amd64"
grep -q '<project>-<service>' skills/glseven-deploy/references/templates/docker-compose.project.yml || fail "compose 模板未使用 <project>-<service> 命名"
grep -q 'athena-web:80' skills/glseven-deploy/references/athena.md || fail "athena 示例未写 athena-web:80"
grep -q 'docker-hosted/athena-' skills/glseven-deploy/references/athena.md || fail "athena 示例未写单段镜像名"
if grep -Eq '^[[:space:]]*ports:' skills/glseven-deploy/references/templates/docker-compose.project.yml; then
  fail "compose 模板不得发布宿主端口"
fi
```

Run: `bash ci/scripts/test-skills.sh`
Expected: FAIL，输出 `缺少 skills/glseven-deploy/SKILL.md`。

- [ ] **Step 2: 创建 `skills/glseven-deploy/SKILL.md`**

frontmatter 必须精确为：

```yaml
---
name: glseven-deploy
description: 把使用方项目容器化并部署到 glseven 测试环境（sit）时使用。覆盖镜像构建与推 Nexus、compose 接入 glseven 网络、portal 入口、数据库/中间件配置、验证与回滚。
---
```

正文必须包含以下小节：

- `# 把项目部署到 glseven 测试环境`
- `## 何时使用`
- `## 前置条件`：SSH（`ssh legion`）；Nexus（`192.168.31.100:5000`，仓库 `docker-hosted`）；sit 宿主已配置 insecure-registries；开发机 Docker Desktop 同样配置并用 Nexus 凭据 `docker login`；sit 内存余量检查。
- `## 部署模型`：部署目录 `/vol1/1000/projects/<project>/`；单段镜像名；服务名前缀；不发布宿主端口；portal vhost 用 `*.local.conf`。
- `## 手动部署流程`：指向 `references/deploy-flow.md`。
- `## athena 示例`：指向 `references/athena.md`。
- `## 模板`：列出 `references/templates/` 七个文件及用途。
- `## 不要做`：不发布宿主端口；不给每个前端各起 nginx；不提交凭据；不在 sit 上直接 `mvn` 构建多仓库。
- `## 安全`：`.env` 600；不通过命令行传密码；镜像 `linux/amd64`；不复制服务器端密钥。

- [ ] **Step 3: 创建 `references/deploy-flow.md`**

必须包含编号步骤，命令精确：

1. 资源检查：

```bash
ssh legion 'free -h && docker stats --no-stream'
```

要求可用 ≥ 2.5–3 GiB；不足时先调低 fnOS 自带 ES 堆（约 11 → 6 GiB）或加内存，再继续。

2. 构建后端 jar（开发机，带 GitHub Packages 凭据）：

```bash
cd athena-auth && mvn -B -s .mvn/settings.xml -Dgh.actor=<user> -Dgh.token=<PAT> verify
```

其余服务按 athena 发布顺序：auth → system → codegen → gateway。

3. 构建并推送镜像（每个服务一次）：

```bash
docker buildx build --platform linux/amd64 \
  --build-arg JAR_FILE=boot/target/athena-auth-boot-1.0.0-SNAPSHOT.jar \
  -t 192.168.31.100:5000/docker-hosted/<project>-<service>:<tag> --push .
```

4. 准备 sit 部署目录与环境文件：

```bash
ssh legion 'sudo mkdir -p /vol1/1000/projects/<project> && sudo chown 1000:1000 /vol1/1000/projects/<project>'
# 复制 compose 与模板；.env 权限 600
```

5. 创建数据库/用户（MySQL 容器内执行；密码交互输入，不写在命令行）：

```bash
ssh -t legion 'docker exec -it mysql mysql -uroot -p'
```

6. 启动与检查：

```bash
ssh legion 'cd /vol1/1000/projects/<project> && docker compose pull && docker compose up -d && docker compose ps'
```

7. portal 入口：在 sit 的 `portal/conf/conf.d/<project>.local.conf` 写入 `portal-project.conf` 模板（替换占位符），然后：

```bash
ssh legion 'docker exec nginx nginx -t && docker exec nginx nginx -s reload'
```

8. 验证：容器健康；登录 token；经门户的 API；Kibana 中按 `container.name` 查日志。
9. 回滚：固定上一版镜像 tag，`docker compose up -d` 回到旧 tag；保留上一版 compose。

- [ ] **Step 4: 创建 `references/athena.md`**

必须包含：

- 服务表（均带 `athena-` 前缀）：`athena-auth` 8080、`athena-system` 8083、`athena-codegen` 8082、`athena-gateway` 8000/8001、`athena-web` 80；镜像名 `docker-hosted/athena-auth:<tag>` 等。
- 构建命令：四个后端仓各自 `mvn -B -s .mvn/settings.xml -Dgh.actor=<user> -Dgh.token=<PAT> verify`；前端 `pnpm install && pnpm build`（main / web-auth / web-codegen / web-system / web-shared，先构建 shared）。
- 启动顺序：`athena-auth` 就绪（`/.well-known/openid-configuration` 返回 200）→ `athena-system` / `athena-codegen` → `athena-gateway` → `athena-web`。
- 环境变量：按 `connect-recipes.md` 的容器内配方；issuer 用 `http://athena-auth:8080`；前端只用相对路径 `/oauth2/token`，不读 OIDC 元数据。
- 数据库初始化 SQL：

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

- codegen 额外 DDL：`athena-codegen/boot/src/main/resources/doc/athena-codegen.sql` 需手工执行一次（不在 Flyway 目录）。
- Nacos：控制台创建用户；各服务注册名 `athena-auth` 等；网关 `GATEWAY_ROUTE_SOURCE=nacos`，路由在 Nacos 配置。
- portal：`athena.local.conf` 使用 `listen 8080`、`server_name athena.glseven.local`、`set $athena_web "athena-web:80"`；现有本机文件的上游要从 `web:80` 改为 `athena-web:80`。
- 验证（示例账号来自 athena 种子数据，按实际环境替换）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://athena.glseven.local:8080/
curl -sS -X POST http://athena.glseven.local:8080/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'X-Tenant-Id: 0' \
  -H "Authorization: Basic $(printf 'public-client:secret' | base64)" \
  -d 'grant_type=password&username=superadmin&password=admin123&scope=message.read'
```

- 内存前置：4 个后端 `-Xmx512m` + 前端约 2–2.5 GiB；叠加 GitLab/Runner 后需先调低 fnOS ES 堆或加内存。

- [ ] **Step 5: 创建七个模板**

`templates/Dockerfile.java`：

```dockerfile
# 用法：docker buildx build --platform linux/amd64 \
#   --build-arg JAR_FILE=boot/target/<service>-boot-<version>.jar \
#   -t 192.168.31.100:5000/docker-hosted/<project>-<service>:<tag> --push .
FROM eclipse-temurin:21-jre
ARG JAR_FILE
WORKDIR /app
RUN useradd --system --uid 10001 app
COPY ${JAR_FILE} /app/app.jar
USER 10001
ENV JAVA_OPTS="-Xms256m -Xmx512m"
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
```

`templates/Dockerfile.web`：

```dockerfile
# 用法：先在宿主构建前端 dist，再构建本镜像；路径按项目实际产物调整。
FROM nginx:1.30.4-alpine
COPY nginx.web.conf /etc/nginx/conf.d/default.conf
COPY dist/main/ /usr/share/nginx/html/
COPY dist/sub-auth/ /usr/share/nginx/html/sub-auth/
COPY dist/sub-codegen/ /usr/share/nginx/html/sub-codegen/
COPY dist/sub-system/ /usr/share/nginx/html/sub-system/
COPY dist/portal/ /usr/share/nginx/html/portal/
EXPOSE 80
```

`templates/nginx.web.conf`：

```nginx
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # qiankun 子应用路径与 Dockerfile.web 的 COPY 目标一致。
    location /sub-auth/ { try_files $uri $uri/ /sub-auth/index.html; }
    location /sub-codegen/ { try_files $uri $uri/ /sub-codegen/index.html; }
    location /sub-system/ { try_files $uri $uri/ /sub-system/index.html; }
    location /portal/ { try_files $uri $uri/ /portal/index.html; }

    # API 与 OAuth2 反代到网关；头直接内联，避免依赖外部 snippet。
    location /api/ {
        proxy_pass http://<project>-gateway:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location /oauth2/ {
        proxy_pass http://<project>-gateway:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

`templates/docker-compose.project.yml`：

```yaml
# 服务名/容器名统一为 <project>-<service>；镜像名为 docker-hosted/<project>-<service>:<tag>。
name: <project>

networks:
  glseven:
    external: true

services:
  <project>-auth:
    image: 192.168.31.100:5000/docker-hosted/<project>-auth:<tag>
    container_name: <project>-auth
    hostname: <project>-auth
    restart: always
    env_file:
      - .env
    networks:
      - glseven
    # 不发布宿主端口：统一由 portal 代理。
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
  # 其余服务按同样结构复制：<project>-system / <project>-codegen / <project>-gateway / <project>-web
```

`templates/portal-project.conf`：

```nginx
# 使用方项目入口。文件名以 .local.conf 结尾：机器专属、gitignored、不参与一致性校验。
server {
    listen 8080;
    server_name <project>.glseven.local;

    resolver 127.0.0.11 valid=10s ipv6=off;
    set $project_web "<project>-web:80";

    client_max_body_size 64m;

    location / {
        proxy_pass http://$project_web;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

`templates/gitlab-ci.project.yml`：

```yaml
stages: [build, deploy]

variables:
  REGISTRY: 192.168.31.100:5000
  IMAGE_PREFIX: docker-hosted/<project>

build-and-push:
  stage: build
  image: docker:29.10.0-cli
  before_script:
    - echo "$NEXUS_PASSWORD" | docker login "$REGISTRY" -u "$NEXUS_USER" --password-stdin
  script:
    - docker buildx build --platform linux/amd64 --build-arg JAR_FILE=<jar> -t "$REGISTRY/$IMAGE_PREFIX-auth:$CI_COMMIT_SHA" --push .

deploy:sit:
  stage: deploy
  needs: [build-and-push]
  script:
    - ssh "$SIT_HOST" "cd /vol1/1000/projects/<project> && docker compose pull && docker compose up -d"
```

`templates/env.project.example`：

```dotenv
# 复制为部署目录的 .env，chmod 600；不要提交。
DB_USERNAME=<db-user>
DB_PASSWORD=<db-password>
REDIS_PASSWORD=<redis-password>
NACOS_USERNAME=<nacos-user>
NACOS_PASSWORD=<nacos-password>
TZ=Asia/Shanghai
```

- [ ] **Step 6: 运行校验，确认通过**

Run: `bash ci/scripts/test-skills.sh`
Expected: 退出码 0，最后一行 `test-skills: 通过`。

- [ ] **Step 7: shell 语法与空白检查**

Run:
```bash
bash -n ci/scripts/test-skills.sh
git diff --check
```
Expected: 均无输出、退出码 0。

- [ ] **Step 8: 提交**

```bash
git add ci/scripts/test-skills.sh skills/glseven-deploy
git commit -m "feat(skills): 新增 glseven-deploy 部署技能与模板"
```

### Task 3: README 与 CLAUDE.md 接入说明

**Files:**
- Modify: `README.md`（在「六域结构与启动时序」之后、「服务访问入口」之前新增一节）
- Modify: `CLAUDE.md`（在「本仓库是什么」段之后新增一节）

**Interfaces:**
- Consumes: Task 1/2 的技能目录与 `test-skills.sh`。
- Produces: 使用方可见的接入说明。

- [ ] **Step 1: README 新增「技能包（供其他项目使用）」**

内容必须包含：

````markdown
## 技能包（供其他项目使用）

`skills/` 下是给使用方项目的 Claude Code 技能包：`glseven-env`（连接测试环境的数据库与中间件）和 `glseven-deploy`（把项目容器化并部署到 sit）。技能与环境配置同仓维护，使用方在自己的仓库根目录建符号链接即可：

```bash
ln -s /path/to/glseven-docker/skills .claude/skills
```

若目标项目已有 `.claude/skills`，改为分别软链 `glseven-env`、`glseven-deploy` 两个目录。

首个使用方是 athena。技能只提供做法与模板，不把使用方服务纳入本编排（见 `docs/superpowers/specs/2026-11-28-test-env-skill-package-design.md`）。
````

- [ ] **Step 2: CLAUDE.md 新增「技能包」小节**

内容必须包含：

```markdown
## 技能包

`skills/` 是供使用方项目消费的技能包（`glseven-env` 连接环境、`glseven-deploy` 部署项目），与 athena-skill 的 dev-flow 无关；格式与凭据泄漏由 `ci/scripts/test-skills.sh` 校验。修改技能后运行该脚本。
```

- [ ] **Step 3: 验证**

Run:
```bash
bash ci/scripts/test-skills.sh
bash common/check-consistency.sh --strict
git diff --check
```
Expected: 全部通过（`check-consistency` 不涉及 README/CLAUDE.md，无新增告警）。

- [ ] **Step 4: 提交**

```bash
git add README.md CLAUDE.md
git commit -m "docs: 说明测试环境技能包与接入方式"
```

### Task 4: 全量本地验证

**Files:**
- 无新增；只运行验证命令，必要时修复前三个任务的产物。

**Interfaces:**
- Consumes: Task 1-3 的全部产物。
- Produces: 验收证据（命令与输出）。

- [ ] **Step 1: 运行仓库等价校验**

```bash
while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')
for f in ci/scripts/test-*.sh; do echo "Running $f"; bash "$f"; done
bash common/check-consistency.sh --strict
git diff --check
```

Expected: 全部退出码 0；`test-skills.sh` 输出 `test-skills: 通过`。

- [ ] **Step 2: 有 Docker 时渲染 compose 模板（可选）**

```bash
tmp="$(mktemp -d)"
sed -e 's/<project>/demo/g' -e 's/<tag>/test/g' \
  skills/glseven-deploy/references/templates/docker-compose.project.yml > "$tmp/docker-compose.yml"
printf 'DB_USERNAME=demo\nDB_PASSWORD=demo\n' > "$tmp/.env"
docker compose --env-file "$tmp/.env" -f "$tmp/docker-compose.yml" config -q
rm -rf "$tmp"
```

Expected: 无输出、退出码 0。无 Docker CLI 时跳过并记录。

- [ ] **Step 3: 有 Docker 时校验 portal vhost（可选）**

```bash
tmp="$(mktemp -d)"
mkdir -p "$tmp/conf.d" "$tmp/snippets"
sed 's/<project>/demo/g' skills/glseven-deploy/references/templates/portal-project.conf > "$tmp/conf.d/demo.conf"
printf 'events {}\nhttp { include /etc/nginx/conf.d/*.conf; }\n' > "$tmp/nginx.conf"
: > "$tmp/snippets/proxy.conf"
docker run --rm \
  -v "$tmp/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$tmp/conf.d:/etc/nginx/conf.d:ro" \
  -v "$tmp/snippets:/etc/nginx/snippets:ro" \
  nginx:1.30.4 nginx -t
rm -rf "$tmp"
```

Expected: `syntax is ok` / `test is successful`。无 Docker 时跳过并记录。

- [ ] **Step 4: 提交修复（如有）**

如果前几步发现并修复了问题：

```bash
git add -A
git commit -m "fix(skills): 修正技能包校验问题"
```

没有改动则不提交。

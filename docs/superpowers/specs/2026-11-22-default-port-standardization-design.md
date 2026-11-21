# 设计文档：端口标准化——门户与 GitLab 回归 8080

- 日期：2026-11-22
- 状态：待用户确认
- 范围：portal 与 devops 两个域的 HTTP 入口端口；不动任何 TCP stream 端口与后端容器内部端口

## 1. 背景与意图

用户诉求：「优化 docker 配置，尽量使用默认标准端口」。

现状盘点：30 个宿主端口中 26 个已是容器原生端口，容器内监听也基本是镜像默认值。真正偏离标准的只有 4 个：

| 端口 | 服务 | 原生端口 | 偏离原因 |
|---|---|---|---|
| 8000 | 门户（nginx） | 80 | fnOS 占用 80/443 |
| 8929 | GitLab Web | 80 | 同上 |
| 5673 | RabbitMQ AMQP（宿主侧） | 5672 | NAS 自带 rabbitmq-server 占用 5672 |
| 2222 | GitLab SSH（宿主侧） | 22 | fnOS sshd 占用 22 |

其中 5673/2222 已经是「原生端口 +1/+2200」式替代，符合「常用默认替代」；8000/8929 不是——它们是任意挑选的空闲端口。

用户确认：fnOS 不动（80/443 继续归它），所有服务保留镜像原生端口，只有原生端口被宿主占用时才改用**常用替代端口**。

## 2. 目标 / 非目标

**目标**

1. 门户与 GitLab 从 8000/8929 改为 **8080**——80 的业界常用替代端口（Tomcat 传统，事实标准）。
2. GitLab SSH 宿主端口从 2224 改为 **2222**——22 的常用替代端口。
3. 其余 HTTP 服务全部保留镜像原生端口（3000/5601/9200/9080/9180/8081/9000/9090/15672/1905…）。
4. 其余 16 条 TCP stream 端口不动。
5. 后端容器内部端口：除 GitLab（`external_url` 决定）外，全部不动。

**非目标（YAGNI）**

- 不引入 HTTPS/8443（开发环境明文足够，2026-09-09 已裁定）。
- 不做「全部 HTTP 收敛到 8080」：用户评估后否决——会失去「URL 端口 = 容器原生端口」的透明性，且 ELK/APISIX 多端点在同域名同端口上冲突，需要拆子域名。
- 不动 ELK 的 5601/9200、APISIX 的 9080/9180——它们是各服务原生端口且宿主不冲突。

**anti-goals**

- 不为「统一好看」重排端口号段（2026-09-09 已否决）。
- 不改任何后端服务的监听端口，避免连接串/客户端配置连锁变更。

## 3. 约束

- fnOS 占用 80/443；NAS 自带 rabbitmq-server 占用 5672；fnOS sshd 占用 22——均不可动（用户明示）。
- 8080 已是共享端口（adminer、phpLDAPadmin、Keycloak、Nacos、XXL-JOB、Open WebUI），门户与 GitLab 加入后共 8 个 vhost，按 `server_name` 分流。
- 本机 `local` 不启动 GitLab，`gitlab.conf` 必须继续用运行时 DNS 解析，不能因上游缺席导致 nginx 启动失败。
- 历史 spec/plan 保留原文，不做追溯修改；本设计取代 2026-11-21 sit-cicd 设计中「GitLab Web 用 8929」的选择。

## 4. Approaches

| 方案 | 内容 | 结果 |
|---|---|---|
| A. 全部 HTTP 走 8080 | 13 个 HTTP 服务全部改为 8080，ELK/APISIX 需拆 `es` / `apisix-admin` 子域名 | **否决**：用户评估后选择保留原生端口；多端点冲突会引入额外域名与 hosts 条目，且 grafana 等 URL 不再是镜像默认端口 |
| B. 保留原生端口，门户/GitLab 改 8080 | 仅 2 个端口变更，8080 沿用现有共享 vhost 机制 | **采纳**：改动面最小，符合「原生端口优先、冲突用常用替代」原则 |
| C. 保持现状 | 8000/8929 本身不冲突 | **否决**：不满足「常用默认替代」目标，两个非标准号继续存在 |

## 5. 端口终表

### 5.1 变更项

| 服务 | 改前 | 改后 | 说明 |
|---|---|---|---|
| 门户（nginx） | `8000:8000` + `listen 8000` | `8080:8080` + `listen 8080` | 80 被 fnOS 占，用 8080 |
| GitLab Web | `8929:8929` + `listen 8929` + `gitlab:8929` | `8080:8080` + `listen 8080` + `gitlab:8080` | `external_url` 同步改 8080，容器内 omnibus nginx 监听 8080 |
| GitLab SSH | `2224:2224` + `listen 2224` + `gitlab_shell_ssh_port = 2224` | `2222:2222` + `listen 2222` + `gitlab_shell_ssh_port = 2222` | 22 被 fnOS sshd 占，用常用替代 2222；容器内仍为 22 |

### 5.2 不变项

- HTTP 原生端口：3000（grafana/moontv）、8081（mongo-express/nexus3）、9000（portainer）、9090（prometheus）、5601（kibana）、9200（ES API）、15672（rabbitmq 管理）、9080/9180（apisix）、1905（iptv）、8080 上原有 6 个服务。
- 16 条 stream（GitLab SSH 除外）：3306、6379、27017、5673、1883、15675、9092、29092、2379、389、636、8848、9848、11434、5044、5000。
- 后端容器内部端口：全部不变（GitLab 除外）。

### 5.3 端口计数

30 → 28 条宿主映射：8080 共享入口 + 10 个原生 HTTP 监听（3000/8081/9000/9090/5601/9200/15672/9080/9180/1905）+ 17 条 stream。

## 6. 文件级改动清单

| 文件 | 改动 |
|---|---|
| `portal/docker-compose.yml` | 删除 `8000:8000`、`8929:8929`；`2224:2224` → `2222:2222`；8080 行注释改为「门户 + GitLab + 6 个原生服务」；healthcheck 8000 → 8080 |
| `portal/conf/conf.d/portal.conf` | `listen 8000 default_server` → `listen 8080`（default_server 交给 catchall）；根域 301 目标 → `:8080`；第二个 server 的 `listen` → 8080；注释更新 |
| `portal/conf/conf.d/00-default-catchall.conf` | 三条 302 目标统一 `portal.glseven.local:8080` |
| `portal/conf/conf.d/gitlab.conf` | `listen 8929` → `listen 8080`；`gitlab:8929` → `gitlab:8080`；注释更新 |
| `portal/conf/stream-conf.d/gitlab.conf` | `listen 2224` → `listen 2222`；上游目标 `gitlab:22` 不变 |
| `portal/conf/snippets/proxy.conf` | 注释中的 `:8929` → `:8080`（逻辑不变） |
| `portal/html/index.html` | GitLab 卡片 `data-port` 8929 → 8080、文字同步；副标题补充「冲突时用标准替代端口」 |
| `devops/docker-compose.yml` | `external_url` 8929 → 8080；`gitlab_shell_ssh_port` 2224 → 2222；healthcheck 8929 → 8080；注释更新 |
| `README.md` | 门户/GitLab URL、SSH 克隆地址（2224→2222）与端口计数（30→28）；「已知平台限制」中的 8929 → 8080 |
| `CLAUDE.md` | 端口计数 30→28；共享端口说明补 8080 承载门户/GitLab；平台限制 8929 → 8080 |
| `ci/smoke-test.sh` | 门户 8000 → 8080；GitLab 8929 → 8080 |
| `ci/scripts/test-devops-domain.sh` | `listen 8929;` → `listen 8080;`；`"8929:8929"` 断言 → `"8080:8080"`；`listen 2224;` 与 `"2224:2224"` → 2222 |
| `ci/scripts/test-deploy-sit.sh` | 测试用 `CI_REPOSITORY_URL` 中的 8929 → 8080 |
| `docs/runbooks/sit-cicd-bootstrap.md` | 所有 8929 → 8080、2224 → 2222，含 runner `config.toml` 的 `url` 与 readiness 探测 |

## 7. 验证

静态：

```bash
for f in */docker-compose.yml; do docker compose --env-file .env.local -f "$f" config -q; done
bash ci/scripts/test-devops-domain.sh
bash ci/scripts/test-deploy-sit.sh
bash common/check-consistency.sh --strict
git diff --check
```

运行时（有 Docker 的机器）：

- `docker exec nginx nginx -t` 通过。
- 门户 `curl -I -H 'Host: portal.glseven.local' http://127.0.0.1:8080/` 返回 200。
- 根域 `curl -I -H 'Host: glseven.local' http://127.0.0.1:8080/` 返回 301 到 `portal.glseven.local:8080`。
- 裸 IP `curl -I http://127.0.0.1:8080/` 返回 302 到门户。
- 原有 8080 vhost（adminer/keycloak/nacos/xxl-job/open-webui/php-ldap-admin）逐个 200。
- sit：GitLab `curl -I -H 'Host: gitlab.glseven.local' http://127.0.0.1:8080/-/readiness` 返回 200。
- sit：`nc -vz 127.0.0.1 2222` 可连通（stream 转发到 gitlab:22）。
- `bash ci/smoke-test.sh` 全绿。

## 8. 运行时迁移（sit 宿主）

- GitLab `external_url` 变更会触发 omnibus reconfigure，需要 `docker compose ... up -d --force-recreate gitlab`，首次启动较慢（约数分钟）。
- GitLab Runner 的 `config.toml`（数据目录 `gitlab-runner/config/config.toml`）中 `url = "http://gitlab:8929"` 需手动改为 `http://gitlab:8080`，否则 runner offline。
- 已有项目的 HTTP remote URL 需从 `:8929` 改为 `:8080`；SSH remote 需从 `:2224` 改为 `:2222`（旧端口已释放）。
- 旧书签 `portal.glseven.local:8000`、`gitlab.glseven.local:8929` 失效，无兼容跳转（端口已释放）。

## 9. 已知边界

- 8080 仍是共享端口，宿主其他进程占用会导致绑定失败（preflight 已检查并报错）。
- 2222 是常用 SSH 替代端口，若 sit 宿主已有服务占用，preflight 会报 `port is already allocated`，需换一个空闲端口。
- 8000/8929 释放后不再被 nginx 占用，宿主侧其他服务可复用。
- 5673/2222 仍为替代端口——fnOS 不动的前提下无法回归 5672/22。

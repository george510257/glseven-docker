# 配置审计报告（2026-11-20）

- **状态**：待确认（尚未改动任何配置）
- **后续**：P0 的具体修法已由 [P0 设计](2026-11-20-p0-dual-environment-design.md) 细化为 local / sit 两套配置档案；本文保留发现与证据。
- **范围**：6 个 compose 文件、25 个容器、14 个 env 文件、portal 全部 vhost 与 stream、组件配置（prometheus / grafana / apisix / filebeat / elk / openldap / xxl-job / nacos / mysql）、启停与 preflight 脚本、CI 与发布脚本
- **方法**：逐文件静态阅读；可离线执行处做了实测。Docker daemon 当前未运行，涉及运行时行为的结论标注为「未实测」。

## 0. 验证记录

| 检查 | 结果 |
|---|---|
| `bash -n` 全部受跟踪 shell 脚本 | 通过 |
| `test-docker-volume.sh` / `test-startup-platform.sh` / `test-release-scripts.sh` | 通过 |
| `docker compose config -q` 六个文件 | 通过 |
| `common/check-consistency.sh` | 1 项告警（`athena.conf` 无对应容器） |
| `git diff --check` | 通过 |
| compose 变量插值实测 | `.env` 内 `DOCKER_VOLUME=$HOME/...` 直接 compose 会展开；经 `startup.sh` 导出后不展开 |

## 1. 结论摘要

| 级别 | 数量 | 判定标准 |
|---|---|---|
| P0 | 4 | 当前就可能故障，或配置意图明确但实际未生效 |
| P1 | 11 | 长期运行会引发故障、数据/磁盘风险或安全暴露 |
| P2 | 12 | 维护性、一致性、文档漂移，不会立刻坏 |
| 待确认 | 4 | 需要镜像文档或产品判断 |

## 2. P0：当前就可能故障

### P0-1 Kafka EXTERNAL advertised 指向另一台机器

- 证据：[common/env/kafka.env:15](common/env/kafka.env:15) 为 `192.168.31.100:29092`；本机 `en0` 当前是 `10.184.6.252`；[README.md:121](README.md:121) 却写「默认 `127.0.0.1:29092`」。
- 影响：宿主或局域网客户端经 29092 bootstrap 成功后，会收到一个不可达的 broker 地址；典型表现是元数据请求挂起/超时，而不是连接被拒。
- 方向：新增 `KAFKA_EXTERNAL_HOST`，由 `.env.local` / `.env.sit` 档案注入，默认 `127.0.0.1`；sit 档案写实际 IP。同步修正 README。

### P0-2 athena.conf 会让整个门户起不来

- 证据：[portal/conf/conf.d/athena.conf:24](portal/conf/conf.d/athena.conf:24) 使用静态 `proxy_pass http://web:80;`；其余 vhost 的上游都在本编排内，只有 elk 用 `resolver` + 变量规避缺席（[elk.conf:5](portal/conf/conf.d/elk.conf:5)）。
- 影响：nginx 在配置加载期解析静态上游；`web` 不存在时会 `[emerg] host not found in upstream`，portal 容器退出，**28 个宿主端口全部不可用**，不只是 athena 一个入口。（nginx 文档行为；本机无 nginx、daemon 未运行，未实测。）
- 范围：该文件当前未跟踪。一旦提交，或在本地保留后重启/reload nginx，即触发。
- 方向：改用与 elk 相同的 `resolver 127.0.0.11 valid=10s ipv6=off` + `set $upstream`；或等 athena 服务确定加入 `glseven` 网络后再启用。

### P0-3 macOS 上按 README 做单域启动会挂到 /docker/glseven

- 证据：六个 compose 统一使用 `${DOCKER_VOLUME:-/docker/glseven}`（如 [docker-compose-infra.yml:20](docker-compose-infra.yml:20)）；[.env.example:7](.env.example:7) 默认不设置该项。实测无 `DOCKER_VOLUME` 时 `docker compose config` 渲染为 `/docker/glseven`，而 macOS 根卷只读。
- 影响：`docker compose -f docker-compose-apps.yml up -d <service>` 在 macOS 上挂载失败；而 README 把单域命令与 `startup.sh` 并列展示，未提示差异。
- 附加实测（同一问题的另一面）：若按 [.env.example:8](.env.example:8) 取消注释 `DOCKER_VOLUME=$HOME/docker/glseven`，直接 compose 会把 `$HOME` 展开为 `/Users/...`（正常）；但 `startup.sh` 的 awk 解析器返回字面量 `$HOME/...` 并导出，compose 随即报 `service "..." refers to undefined volume $HOME/docker/glseven/data`，**启动直接失败**。两条路径行为不一致，且失败信息晦涩。
- 方向：改为 `${DOCKER_VOLUME:?DOCKER_VOLUME 未设置}` 快速失败；让 `resolve_docker_volume` 展开 `~` / `$HOME`；用档案制取代 `.env` 的隐式默认值（见设计文档）。

### P0-4 Nacos 3.2.4 的客户端 API 鉴权默认关闭

- 证据：[common/env/nacos.env:12](common/env/nacos.env:12) 起设置了 `NACOS_AUTH_TOKEN` 与 `NACOS_AUTH_IDENTITY_KEY/VALUE`，但没有 `NACOS_AUTH_ENABLE`。3.2.4 的 `application.properties` 默认 `nacos.core.auth.enabled=false`（客户端），但 `nacos.core.auth.admin.enabled=true`、`nacos.core.auth.console.enabled=true`；镜像 entrypoint 要求 token/identity 必填，为空会 `exit 255`。
- 影响：客户端 SDK / gRPC / OpenAPI 无鉴权，能访问 8848 / 9848 的进程可读改配置；控制台（8080）已有登录保护，token 与 identity 也在使用中，**并非死配置**。
- 方向：显式设置 `NACOS_AUTH_ENABLE=true` 并验证客户端兼容；**保留** token/identity，README 把「无鉴权」限定为客户端 API。升级到 3.3+ 时默认值翻转，需要迁移说明。

## 3. P1：长期运行会疼

### P1-1 资源上限只覆盖 ollama

- 证据：仅 [docker-compose-apps.yml:32](docker-compose-apps.yml:32) 有 `deploy.resources.limits`（4 CPU / 8G）；其余 24 个容器无 `mem_limit` / `cpus`。
- 影响：Elasticsearch、Kafka、Nexus、MySQL、Redis 等内存大户无上限。NAS 上最先出现的通常不是「慢」，而是 OOM killer 随机带走一个容器，事后难以归因。
- 方向：至少给 ES / Kafka / Nexus 设堆上限与 `mem_limit`；Redis 设 `maxmemory` 与淘汰策略。

### P1-2 没有宿主指标，也没有告警

- 证据：[prometheus/conf/prometheus.yml:4](prometheus/conf/prometheus.yml:4) 的 7 个 job 全部是应用端点；无 node-exporter / cadvisor；无 `rule_files` 与 Alertmanager。
- 影响：磁盘、内存、容器资源都看不见；指标只存历史，不会主动报「磁盘要满了」。
- 方向：加 node-exporter（可选 cadvisor），配 3–5 条基础告警。代价是多一个组件，与本仓库「不轻易引入新组件」的既有取舍冲突，需要你裁决。

### P1-3 Prometheus 没有保留上限

- 证据：[prometheus/conf/prometheus.yml:1](prometheus/conf/prometheus.yml:1) 只有 `scrape_interval`，无 `--storage.tsdb.retention.time/size`。
- 影响：默认 15 天保留，但大小随序列数增长且没有磁盘保护；长期运行可能吃满数据卷。
- 方向：给 prometheus 命令加保留时间与大小双上限。

### P1-4 文件日志不在 Docker 轮转范围内

- 证据：preflight 只写 daemon.json（[common/preflight.sh:157](common/preflight.sh:157)），它只覆盖 stdout/stderr。以下服务把日志写进 bind mount：nacos（[platform.yml:20](docker-compose-platform.yml:20)）、xxl-job（[platform.yml:43](docker-compose-platform.yml:43)）、php-ldapadmin（[security.yml:61](docker-compose-security.yml:61)）、nexus3（数据卷内）；MySQL 的 `*.err` 也在数据卷内。
- 影响：这些日志是否轮转取决于各自 logback / 内置配置，仓库未显式约束；Nacos 日志在 NAS 上是常见的磁盘增长来源。
- 方向：逐一确认应用侧轮转策略，缺失的补上或加宿主 logrotate。**这是验证缺口，不是已证实的无限增长。**

### P1-5 门户与所有上游强耦合

- 证据：除 elk 外，`conf.d/*.conf` 与 `stream-conf.d/*.conf` 全部使用静态 `proxy_pass`（如 [grafana.conf:5](portal/conf/conf.d/grafana.conf:5)、[mysql.conf:2](portal/conf/stream-conf.d/mysql.conf:2)）。
- 影响：任一服务被 `down`（容器不存在）后，portal 重启或 reload 会因解析失败而 emerg 退出；开发中「暂时关掉 Kafka」这类操作会连带整个门户不可用。
- 方向：统一使用 `resolver` + 变量，或 nginx 1.27+ 的 `upstream ... resolve`。

### P1-6 shutdown 的孤儿容器与网络删除

- 证据：[shutdown.sh:22](shutdown.sh:22) 的 `down` 未带 `--remove-orphans`；[:30](shutdown.sh:30) 直接 `docker network rm glseven`，失败时 `set -e` 让脚本非零退出。
- 影响：服务改名后旧容器会继续占用 `glseven`；athena 等外部 project 也会占用。届时网络删不掉，脚本以错误码结束，看起来像「关不干净」。
- 方向：`down --remove-orphans`；网络删除失败降级为警告，并打印占用者（`docker network inspect`）。

### P1-7 默认凭据与开放注册（聚合项）

- 证据：mysql / mongo / rabbitmq / mongo-express / phpldapadmin / moontv 的默认口令；Grafana 没有设置 `GF_SECURITY_ADMIN_PASSWORD`（[grafana.ini:9](grafana/conf/config/grafana.ini:9) 仅有注释）；Keycloak bootstrap 口令；[open-webui.env:4](common/env/open-webui.env:4) `ENABLE_SIGNUP=true`；xxl-job 的 `default_token`；APISIX admin key 与 Nacos token 均入库。
- 影响：仓库定位是开发环境，注释也均标了 WARNING；但 28 个端口绑定 `0.0.0.0`，同一局域网内即可利用；open-webui 允许注册意味着首个访问者可能拿到管理员。
- 方向：至少补一节「信任边界」；或把 Grafana / open-webui 的管理员口令改为 `.env` 注入。

### P1-8 暴露面未收敛

- 证据：[docker-compose-portal.yml:29](docker-compose-portal.yml:29) 起 28 个端口均无 `host_ip`，即绑定全部网卡；ES 9200 无认证（[observability.yml:109](docker-compose-observability.yml:109) 注释明确 sebp/elk 默认未启用安全）。
- 影响：任何能连到宿主的设备都能读写全部日志索引；etcd 与 APISIX 的风险已有文档，ES 没有。
- 方向：确认是否真的需要局域网访问；不需要的端口改绑 `127.0.0.1:`。这是产品取舍，不是纯技术问题。

### P1-9 配置挂载半数不是只读

- 证据：未加 `:ro` 的挂载包括 [observability.yml:19](docker-compose-observability.yml:19)（prometheus.yml）、[:40-42](docker-compose-observability.yml:40)（grafana 三处）、[:100](docker-compose-observability.yml:100)（kibana.yml）、[platform.yml:21](docker-compose-platform.yml:21)（nacos custom.properties）、[:44](docker-compose-platform.yml:44)（xxl application.properties）。
- 影响：容器内进程被攻破或误操作即可改写仓库文件，进而在宿主侧形成持久化。
- 方向：统一加 `:ro`；需先确认这些组件不会回写配置（通常不会）。

### P1-10 镜像代理只覆盖 ghcr / quay

- 证据：[common/preflight.sh:28](common/preflight.sh:28) 的镜像表只有 `ghcr.io` 与 `quay.io`；`docker.io`（大多数镜像）与 `docker.elastic.co`（filebeat）无镜像兜底。`docker pull` 也没有超时（[:117](common/preflight.sh:117)）。
- 影响：国内网络或代理不稳时，Docker Hub / Elastic 镜像可能长时间卡住启动；preflight 对此没有兜底路径。
- 方向：扩展 registry 表（注意 `library/` 前缀规则），并给 pull 加 `timeout`。

### P1-11 没有备份与恢复路径

- 证据：仓库内没有 mysqldump、卷快照或恢复脚本；`shutdown.sh` 也不涉及数据导出。
- 影响：MySQL / mongo / Kafka / Nexus 的数据都只存在宿主机 bind mount 上；误删或磁盘故障即不可恢复。
- 方向：加一个 `backup.sh`（数据库 dump + 关键卷 tar + 保留 N 份），或在 README 明确「不做备份，风险自负」。

## 4. P2：维护性与一致性

### P2-1 check-consistency 的覆盖面不足

- 豁免名单失真：[check-consistency.sh:37](common/check-consistency.sh:37) 的 `NO_CARD_OK="apisix elk"`，但两者在 `portal/html/index.html` 都有卡片。将来卡片丢失不会被发现。
- 静默跳过：[:55-60](common/check-consistency.sh:55) 只收集 `container_name == hostname` 的服务；不一致的新服务会完全逃过检查，且不报警。
- 不校验端口链路：`listen` 端口、`docker-compose-portal.yml` 的 `ports`、`index.html` 的 `data-port` 三者未交叉校验。
- 不校验上游：`proxy_pass` 目标写错（如 `athena:8080`）不会被发现。
- 方向：把豁免名单改为断言、把静默跳过改为告警，补端口与上游交叉校验。

### P2-2 CI 只做语法检查

- 证据：[ci.yml:28](.github/workflows/ci.yml:28) 仅 `bash -n`；脚本里已写 `# shellcheck source=` 却没有运行 shellcheck；workflow YAML 没有 actionlint。
- 影响：未引用变量、引号错误、拼写错误都逃得过 CI。`mport` 这类问题本可由人工审查发现，但工具能更稳定地兜住。
- 方向：加 shellcheck 与 actionlint；shellcheck 会要求处理现有告警，可先 `--severity=error` 起步。

### P2-3 compose-list 不在测试保护内

- 证据：[test-startup-platform.sh:36](.github/scripts/test-startup-platform.sh:36) 只断言 Apple Silicon 子集；没有断言 `COMPOSE_FILES_BASE/DEFERRED/PORTAL` 的并集覆盖全部 `docker-compose-*.yml`。
- 影响：若有人从某个数组里删掉一个域，测试仍绿，启动会静默少起一组服务。
- 方向：断言三个数组的并集等于仓库中的 compose 文件集合，且无重复。

### P2-4 Apple Silicon 白名单需人工维护

- 证据：[common/compose-list.sh:14](common/compose-list.sh:14) 的 `COMPOSE_SERVICES_OBSERVABILITY_APPLE_SILICON=(prometheus grafana)` 是包含式白名单。
- 影响：新增 observability 服务默认不会在 Apple Silicon 启动，且没有任何提示。
- 方向：改成排除式（只排除 `elk filebeat`），新服务默认参与。

### P2-5 startup.sh 没有终态检查

- 证据：[startup.sh:133](startup.sh:133) 在 `up -d` 返回后直接打印「所有服务已启动」；`up -d` 返回 0 不代表容器健康。
- 影响：crash-loop 的容器也会被报告为已启动；排查时需人工 `docker ps`。
- 方向：结束前汇总 unhealthy / restarting 容器，或对关键服务做一次探测。

### P2-6 healthcheck 与 env_file 重复

- 证据：24 段近乎相同的 healthcheck；`common/env/common.env` 在 25 处重复引用。
- 影响：改一个探针参数要改十几处，容易漏。
- 方向：每个 compose 文件加 `x-healthcheck` / `x-common-env` 锚点（YAML 锚点不能跨文件，需逐文件定义）。

### P2-7 文档漂移

- [docker-compose-portal.yml:12](docker-compose-portal.yml:12) 写「22 个 server 块」，实际 23（不含未跟踪的 athena.conf）。
- [stream-conf.d/rabbitmq.conf:2](portal/conf/stream-conf.d/rabbitmq.conf:2) 写「35672」，疑似 `5672` 笔误。
- [README.md:121](README.md:121) 的 Kafka 默认值与 `kafka.env` 不符（同 P0-1）。
- `AGENTS.md` 未提 CI / 发布，与 `CLAUDE.md` 内容重叠。
- 方向：一次性校正；长期考虑把易漂移的数字从注释中移除。

### P2-8 .claude/ 未被忽略

- 证据：`.gitignore` 未包含 `.claude/`；`git status` 持续出现 `?? .claude/`。`settings.local.json` 通常含本机权限配置。
- 方向：忽略 `.claude/settings.local.json`（至少），是否跟踪 `settings.json` 由你决定。

### P2-9 发布 workflow 的重复逻辑

- 证据：[release.yml:50](.github/workflows/release.yml:50) 与 [:132](.github/workflows/release.yml:132) 内联了两份 `classify_release_api`，且未被 `test-release-scripts.sh` 覆盖。
- 影响：两份逻辑将来可能只改一处；workflow 内的分支无法用现有测试保护。
- 方向：抽到 `.github/scripts/` 并加测试。

### P2-10 无镜像更新与漏洞扫描

- 证据：无 Renovate / Dependabot，无 trivy / scout；镜像 tag 全靠手工 bump。
- 影响：安全补丁依赖人工记得；tag 未固定 digest，理论上可被重新推送。
- 方向：按需引入更新机器人与季度扫描；是否固定 digest 取决于你对可维护性的取舍。

### P2-11 Redis 没有内存上限

- 证据：[docker-compose-infra.yml:42](docker-compose-infra.yml:42) 只有 `--appendonly yes --requirepass`，没有 `maxmemory` / `maxmemory-policy`。
- 影响：作为缓存或队列使用时可能吃满宿主内存，且无淘汰策略。
- 方向：按用途设上限与策略（`noeviction` 或 `allkeys-lru` 需要你决定）。

### P2-12 监控面板为空

- 证据：Grafana 只 provision 了数据源（`grafana/conf/provisioning/datasources/all.yaml`），`dashboards/` 只有 `.gitkeep`；filebeat 的 5066 指标未被 Prometheus 抓取（[filebeat.yml:55](filebeat/conf/filebeat.yml:55) 注释自述）。
- 影响：Prometheus 有数据，但 Grafana 打开后没有现成面板；filebeat 自监控数据无人消费。
- 方向：补一个基础面板；决定 5066 是纳入还是关闭。

## 5. 待确认（需要镜像文档或你的决策）

1. **`common/env/iptv.env:3` 的 `mport=1905`**：镜像文档未检索到；若变量名应为 `MPORT`，当前是无效配置（默认端口恰好 1905，所以无症状）。需要看镜像 README，或启动后 `docker exec iptv env` 确认。
2. **openldap 636 是否真的提供 LDAPS**：osixia 是否自动生成自签证书未在本仓库配置中体现。建议用 `openssl s_client -connect openldap.glseven.local:636` 实测；未实测前不应在文档里承诺 LDAPS。
3. **ES 9200 无认证是否是明示取舍**：现有文档只记录了 etcd 的风险，没有 ES。若接受，补进 README 的风险节；若不接受，需要加认证或收紧绑定。
4. **athena 的归属**：它来自另一个 stack，是否计划纳入本编排？这决定 P0-2 是「修配置」还是「暂不提交该文件」。

## 6. 建议的推进方式

按 superpowers 流程，下一步不是直接改，而是从上面挑一批形成设计：

- **批次 A（当前故障）**：P0-1、P0-2、P0-3、P0-4
- **批次 B（长期稳定）**：P1-1 ～ P1-6、P1-10、P1-11
- **批次 C（安全收敛）**：P1-7、P1-8、P1-9
- **批次 D（工程化）**：P2 全部

每批单独一份设计 + 实施计划，避免一次改三十处难以验证。

## 7. 边界声明

本报告只做静态审计与可离线验证；未启动容器、未改动任何配置。运行时结论（nginx 静态上游解析、LDAPS、应用日志轮转）需在 Docker 可用时补测。

Nacos 默认值依据官方文档：<https://nacos.io/docs/latest/guide/user/auth/>。

# 设计文档：nginx 统一入口重构（宿主端口收敛 + 反向代理）

- 日期：2026-09-09
- 状态：已经用户逐节确认
- 范围：glseven-docker 六域编排（23 个服务）的宿主端口暴露方式与门户 nginx 职责升级

## 1. 背景与目标

**现状**：23 个服务中 10 个容器直接绑定约 33 个宿主端口；portal nginx 仅提供静态导航页；端口编号风格混杂（原生号、18xxx、4808x、6080 并存）；nexus3 的宿主 5000 端口与 macOS AirPlay Receiver 冲突。

**目标形态**：

1. nginx（portal 域）成为**唯一**绑定宿主端口的容器，其余 22 个服务零宿主端口。
2. 每个端点以「二级域名 + 容器原生端口」暴露（如 `http://grafana.glseven.local:3000` → grafana:3000）；HTTP 端点走 http 虚拟主机，TCP 端点走 stream 透明转发，nginx 监听端口一律等于容器原生端口。
3. TCP 协议端口通过 nginx stream 模块透明转发，**端口号与原生默认完全一致**——本地开发工具连接串零改动。
4. 端口尽量回归原生默认号：rabbitmq AMQP 由 35672 回归 5672；registry 保持 5000（经 nginx 代理，容器侧不与 AirPlay 冲突；若宿主开启 AirPlay Receiver 致 5000 绑定失败，关闭 AirPlay 即可，README 注明）。
5. 未来新增服务不再占用宿主端口，仅需在 nginx 增加转发规则。
6. 每个镜像一个二级域名（=容器名，零别名）；多端点实例同域名不同端口——HTTP 端点走同域名下原生端口的 http 虚拟主机（如 elk :5601/:9200），TCP 端点走 stream 原生端口。

## 2. 决策记录（澄清结论）

| 决策点 | 结论 | 用户原话/选择 |
|---|---|---|
| 优化方向 | 端口映射重排 + nginx 反向代理暴露服务 | 「现有端口映射不够通用，ng 体现反向代理能力去暴露服务和端口」 |
| 代理 URL 风格 | 子域名方式 | 「选A，另外使用 glseven.local 作为一级域名」 |
| 端口收敛程度 | 所有端口都走 nginx | 「可以所有端口都走ng吗」 |
| 协议端口处理 | TCP 也走 nginx stream | 直接选择 |
| 端口号规则 | 尽量使用默认原生端口 | 「所有端口尽量使用默认端口」 |
| Web 入口端口 | 8000（保持） | 方案二 |
| registry 端口 | 保持 5000 | 「nexus3:5000 不用改，也是通过 ng 代理，不会冲突」 |
| etcd 暴露 | 全量代理（stream 2379），覆盖原「纯内网」约定 | 「因为是开发环境，所有的都要代理出来」 |
| 命名规则 | 二级域名=容器名（零别名）；多端点同域名不同端口 | 「每个实例一个二级域名就好了，同域名的可以端口分开」 |
| 代理端口规则 | nginx 监听端口 = 容器原生端口；同端口多实例（8080/3000/8081）绑一次按 Host 分流 | 「ng代理的端口不要改，使用容器的原始端口。例如：grafana.glseven.local:3000 代理grafana:3000」 |
| 附带优化 | 仅 nginx 探针 + keycloak 代理头；**不做**日志轮转、资源限制 | 多选题选择 |

**已否决的备选**：路径前缀方式（open-webui 不支持子路径，各应用需改 base-path）；统一号段重排（违背“默认端口”原则）；UI 保留直连后备端口（与端口收敛目标冲突）；同实例多端点独立子域名（es、apisix-admin）——违背「每个实例一个二级域名」；单一 8000 端口集中反代全部 HTTP 端点——违背「使用容器原始端口」。

## 3. 总体架构

```
宿主机工具/浏览器
      │  (仅 nginx 容器持有宿主端口)
      ▼
┌──────────── nginx (portal, 172.18.6.1) ─────────────┐
│ http 块    → 11 个监听端口（=容器原生端口）          │
│            → 18 个 server 块按 server_name 分流      │
│ stream 块  → 15 条 TCP 透明转发（原生端口）          │
└──────────────────────────────┬──────────────────────┘
                               ▼ glseven 网络内按服务名转发
              mysql / redis / mongo / kafka / … / apisix
```

**透明性原理**：stream 转发保持「宿主端口号 == 容器原生端口号」，Kafka `advertised.listeners`、Nacos 客户端「主端口 +1000」gRPC 推导、各数据库客户端连接串均不受代理影响。

**启动时序不变**：`common/compose-list.sh` 与 startup.sh/shutdown.sh 零改动；portal 仍是最后一批启动——这同时保证 nginx 启动时全部上游服务名可解析（stream 静态 upstream 在启动期解析 DNS）。

## 4. 端口规划终表

### 4.1 stream TCP 透明转发（15 条）

| 宿主端口 | 转发目标 | 说明 |
|---|---|---|
| 3306 | mysql:3306 | |
| 6379 | redis:6379 | |
| 27017 | mongo:27017 | |
| 5672 | rabbitmq:5672 | AMQP，由 35672 回归默认 |
| 1883 | rabbitmq:1883 | MQTT |
| 15675 | rabbitmq:15675 | MQTT over WebSocket |
| 9092 | kafka:9092 | advertised.listeners 透明 |
| 2379 | etcd:2379 | HTTP REST 与 gRPC 混合端口，gRPC 不能走 http 反代，必须 TCP 透传 |
| 389 | openldap:389 | LDAP |
| 636 | openldap:636 | LDAPS，TLS 透传 |
| 8848 | nacos:8848 | Open API |
| 9848 | nacos:9848 | gRPC，客户端推导 +1000 透明 |
| 11434 | ollama:11434 | LLM API（HTTP，经 TCP 透传后 curl 照常可用） |
| 5044 | elk:5044 | Beats |
| 5000 | nexus3:5000 | Docker Registry；AirPlay 见 §9 |

### 4.2 http 虚拟主机（11 个监听端口，18 个 server 块）

nginx 监听端口 = 容器原生端口；多个容器共用同一原生端口时（8080/3000/8081）绑一次、按 server_name（Host 头）分流。

| 监听端口 | server_name | 转发目标 |
|---|---|---|
| 8000 | `glseven.local` | 静态门户 index.html（门户为 nginx 自身，8000 为约定端口） |
| 3000 | `grafana.glseven.local` | grafana:3000 |
| 3000 | `moontv.glseven.local` | moontv:3000 |
| 8080 | `adminer.glseven.local` | adminer:8080 |
| 8080 | `php-ldap-admin.glseven.local` | php-ldap-admin:8080 |
| 8080 | `keycloak.glseven.local` | keycloak:8080 |
| 8080 | `nacos.glseven.local` | nacos:8080 |
| 8080 | `xxl-job-admin.glseven.local` | xxl-job-admin:8080 |
| 8080 | `open-webui.glseven.local` | open-webui:8080 |
| 8081 | `mongo-express.glseven.local` | mongo-express:8081 |
| 8081 | `nexus3.glseven.local` | nexus3:8081 |
| 9000 | `portainer.glseven.local` | portainer:9000 |
| 9090 | `prometheus.glseven.local` | prometheus:9090 |
| 5601 | `elk.glseven.local` | elk:5601（Kibana UI） |
| 9200 | `elk.glseven.local` | elk:9200（ES API） |
| 15672 | `rabbitmq.glseven.local` | rabbitmq:15672 |
| 9080 | `apisix.glseven.local` | apisix:9080（数据面） |
| 9180 | `apisix.glseven.local` | apisix:9180（Admin API，X-API-KEY） |

**命名与端口规则**：二级域名 = 容器名（如 `nexus3`、`php-ldap-admin`、`xxl-job-admin`），**零别名**（根域 `glseven.local` 为静态门户）。**URL 端口 = 容器原生端口**：`grafana.glseven.local:3000` → grafana:3000、`keycloak.glseven.local:8080` → keycloak:8080；多端点实例同域名不同端口（`elk.glseven.local:5601` Kibana / `:9200` ES）。无 HTTP 端点的服务（mysql/redis/mongo/kafka/openldap）其二级域名仅作 DNS 解析（/etc/hosts → 127.0.0.1），配合 stream 原生端口使用；etcd/ollama 的 HTTP 访问同域名走 stream 原生端口（`etcd.glseven.local:2379`、`ollama.glseven.local:11434`）。

**配置文件按容器拆分（一容器一文件）**：http 侧 `portal/conf/conf.d/<容器名>.conf`（16 个，含根域门户 `portal.conf`；elk/apisix 多端点多 server 块同文件）；stream 侧 `portal/conf/stream-conf.d/<容器名>.conf`（11 个；rabbitmq 3 条、openldap/nacos/elk 各 2 条同文件）。WebSocket `map` 等公共指令在 `nginx.conf` 的 http 块，拆分文件仅含 server 块。

**删除的 14 个 UI 直连端口**（18081、18080、15672、9090、3000、5601、6080、48082、48081、48080、8081、9000、8080、3001）：原归属容器不再绑定，其中同号端口由 nginx 以原生号重新接管。

### 4.3 全量覆盖矩阵（22 个非 nginx 服务）

| 服务 | 代理形态 | 无宿主暴露的内部端口 |
|---|---|---|
| mysql | stream 3306 + DNS 名 | 33060 (X Protocol，已删) |
| redis | stream 6379 + DNS 名 | — |
| mongo | stream 27017 + DNS 名 | — |
| mongo-express | 子域名 :8081 | — |
| adminer | 子域名 :8080 | — |
| rabbitmq | stream 5672/1883/15675 + 子域名(15672) | 25672 (节点间) |
| kafka | stream 9092 + DNS 名 | — |
| etcd | stream 2379（HTTP/gRPC 透传，全量代理） | 2380 (peer，无客户端用途) |
| prometheus | 子域名 :9090 | — |
| grafana | 子域名 :3000 | — |
| elk | 子域名 :5601（Kibana）/ :9200（ES）+ stream 5044 | 9300 (ES 节点间) |
| openldap | stream 389/636 + DNS 名 | — |
| php-ldap-admin | 子域名 :8080 | — |
| keycloak | 子域名 :8080 | 9000 (管理端口，仅 Prometheus 抓取) |
| nacos | stream 8848/9848 + 子域名 :8080（控制台） | 7848/9849 (Raft/gRPC 内部) |
| xxl-job-admin | 子域名 :8080 | — |
| nexus3 | stream 5000 + 子域名(8081) | — |
| portainer | 子域名 :9000 | — |
| apisix | 子域名 :9080（数据面）/ :9180（Admin） | 9091 (Prometheus 抓取) |
| ollama | stream 11434 | — |
| open-webui | 子域名 :8080 | 8081 (内部) |
| moontv | 子域名 :3000 | — |

**DNS 名补充**：无 HTTP 端点的服务（mysql/redis/mongo/kafka/openldap）其二级域名仅在 /etc/hosts 解析为 127.0.0.1，配合 stream 原生端口使用（如 `mysql -h mysql.glseven.local -P 3306`），无需任何 nginx 配置。

**etcd 风险备注**：2379 无认证机制，暴露至宿主机为用户明示决策（开发环境全量代理，覆盖上一轮「勿新增宿主端口映射」约定）；2380 peer 端口无客户端用途，保持内网。

## 5. nginx 配置设计

### 5.1 文件结构（按容器拆分，一容器一文件）

- `portal/conf/nginx.conf`（**新增**，挂载覆盖 `/etc/nginx/nginx.conf`）：
  - stream 为官方镜像静态编译内置（`nginx -V: --with-stream`，modules 目录无 ngx_stream_module.so），无需 load_module
  - `http` 块：mime.types、`keepalive_timeout 65`、`client_max_body_size 512m`（nexus 制品/open-webui 文件上传）、WebSocket 升级头 `map $http_upgrade $connection_upgrade`、`include /etc/nginx/conf.d/*.conf;`
  - `stream` 块：`proxy_connect_timeout 10s` / `proxy_timeout 12h` 顶层参数、`include /etc/nginx/stream-conf.d/*.conf;`
- `portal/conf/snippets/proxy.conf`（**新增**）：反代通用参数片段，conf.d 各 vhost include
- `portal/conf/conf.d/<容器名>.conf`（**新增 ×16**）：http 虚拟主机，每容器一文件；多端点容器（elk :5601/:9200、apisix :9080/:9180）多 server 块同文件；`portal.conf` 为根域静态门户
- `portal/conf/stream-conf.d/<容器名>.conf`（**新增 ×11**）：stream 透传，每容器一文件；多协议容器多 server 块同文件（rabbitmq 3 条、openldap/nacos/elk 各 2 条）
- `portal/conf/default.conf`（**删除**）：旧单文件静态站配置，职责由 conf.d/portal.conf 承接

### 5.2 关键参数

| 参数 | 值 | 理由 |
|---|---|---|
| stream `proxy_timeout` | `12h` | 默认 10m 会切断 MySQL/LDAP/Kafka 空闲长连接 |
| stream `proxy_connect_timeout` | `10s` | 常规 |
| http `client_max_body_size` | `512m` | 制品库上传、AI 文件上传 |
| vhost 通用头 | $http_host（保留端口）、X-Real-IP、X-Forwarded-For、X-Forwarded-Proto、X-Forwarded-Host、X-Forwarded-Port | 代理链路正确性（Host/Port 供 Keycloak 重建 URL；$http_host 供 Portainer Origin/Host CSRF 校验通过） |
| WebSocket | `map $http_upgrade $connection_upgrade` + Upgrade/Connection 头 | portainer 控制台、grafana live、open-webui |
| `proxy_read_timeout` | `3600s` | LLM 长流式响应 |
| `proxy_buffering off` | vhost 通用 | open-webui SSE 流式输出平滑 |

### 5.3 nginx healthcheck

官方 nginx 镜像无 curl/wget（debian-slim 底座），沿用项目已验证的 TCP 探测模式：

```yaml
healthcheck:
  test: [ "CMD-SHELL", "bash -c '</dev/tcp/127.0.0.1/8000' || exit 1" ]
  interval: 10s
  timeout: 5s
  retries: 10
  start_period: 30s
```

## 6. /etc/hosts 初始化

macOS 解析器不支持 hosts 通配符，且浏览器仅对 `*.localhost` 免配置；`*.glseven.local` 需精确条目。23 个主机名压缩为**一行追加**（根域 + 22 个镜像名=容器名，零别名；hosts 支持一行多别名），README 提供复制即用命令（需 sudo）：

```
127.0.0.1 glseven.local mysql.glseven.local redis.glseven.local mongo.glseven.local mongo-express.glseven.local adminer.glseven.local rabbitmq.glseven.local kafka.glseven.local etcd.glseven.local prometheus.glseven.local grafana.glseven.local elk.glseven.local openldap.glseven.local php-ldap-admin.glseven.local keycloak.glseven.local nacos.glseven.local xxl-job-admin.glseven.local nexus3.glseven.local portainer.glseven.local apisix.glseven.local ollama.glseven.local open-webui.glseven.local moontv.glseven.local
```

`.local` 后缀本属 mDNS：hosts 存在精确条目时优先生效，无副作用。

## 7. 文件级改动清单

| 文件 | 改动类型 | 内容 |
|---|---|---|
| `portal/conf/nginx.conf` | 新增 | 主配置：http 块（含 WebSocket map）include conf.d；stream 块 include stream-conf.d（§5.1） |
| `portal/conf/snippets/proxy.conf` | 新增 | 反代通用参数片段 |
| `portal/conf/conf.d/*.conf` | 新增 ×16 | 每容器一文件：门户 portal.conf + 15 个服务 vhost（elk/apisix 多端点同文件） |
| `portal/conf/stream-conf.d/*.conf` | 新增 ×11 | 每容器一文件：15 条 stream 透传（rabbitmq 3 条同文件） |
| `portal/conf/default.conf` | 删除 | 旧单文件静态站配置，职责由 conf.d/portal.conf 承接 |
| `docker-compose-portal.yml` | 修改 | 挂载目录化（nginx.conf/snippets/conf.d/stream-conf.d/html）；ports 改为 26 个端口（8000 门户 + 10 个原生 http 监听 + 15 条 stream）；healthcheck 改探 8000 |
| `docker-compose-infra.yml` | 修改 | 删除 mysql/redis/mongo/mongo-express/adminer/rabbitmq/kafka 的 `ports:` |
| `docker-compose-observability.yml` | 修改 | 删除 prometheus/grafana/elk 的 `ports:` |
| `docker-compose-security.yml` | 修改 | 删除 openldap/php-ldap-admin/keycloak 的 `ports:` |
| `docker-compose-platform.yml` | 修改 | 删除 nacos/xxl-job-admin/nexus3/portainer/apisix 的 `ports:` |
| `docker-compose-apps.yml` | 修改 | 删除 ollama/open-webui/moontv 的 `ports:` |
| `common/env/keycloak.env` | 修改 | 新增 `KC_PROXY_HEADERS=xforwarded`（子域名代理下回调/重定向 URL 正确） |
| `portal/html/index.html` | 修改 | 卡片链接改为「二级域名:原生端口」URL（data-host + data-port），分组结构保留 |
| `README.md` | 修改 | 新增「首次初始化：/etc/hosts」章节 + 新访问矩阵 + AirPlay 说明 |

**保持不变**：服务名/容器名/hostname、固定 IP（172.18.x.x）、`${DOCKER_VOLUME}` 卷路径、6 域 compose 划分、`compose-list.sh` 与 startup.sh/shutdown.sh、各服务 env 文件（除 keycloak.env）、prometheus 抓取配置（容器网内按服务名抓取，与宿主端口无关）、各服务 healthcheck。

## 8. 验证方案

1. 静态校验：每个改动的 compose 文件 `docker compose config -q` 零告警；`nginx -t`（进入 nginx 容器）通过；conf.d 16 个文件、stream-conf.d 11 个文件计数正确。
2. 全量拉起（startup.sh）后：`docker ps` 仅 nginx 有端口映射；6 域 23 容器全部 healthy/running。
3. 端口连通矩阵：对 26 个宿主端口逐项 `nc -vz 127.0.0.1 <port>`（11 http 监听 + 15 stream）；mysql/redis 用真实客户端登录验证（含 `mysql -h mysql.glseven.local` 域名形式）。
4. 浏览器验证：18 个 server 块对应站点逐个访问（域名 + 原生端口），登录页/首页正常（需先完成 /etc/hosts 初始化）。
5. WebSocket：portainer 控制台可进入、grafana 面板 live 刷新。
6. SSE 流式：open-webui 对话流式输出平滑不卡顿。
7. Registry：`docker push localhost:5000/<image>`（localhost 端口自动视为 insecure；若用 `nexus3.glseven.local:5000` 需在 Docker Desktop 配置 insecure-registries）。
8. Keycloak：经 `keycloak.glseven.local` 登录 admin 控制台，回调 URL 正确（验证 KC_PROXY_HEADERS）。
9. 子域名 API 验证：`curl http://etcd.glseven.local:2379/version`、`curl http://ollama.glseven.local:11434/api/tags`（stream 透传 HTTP）、`curl http://prometheus.glseven.local:9090/-/healthy`、带 X-API-KEY 请求 `http://apisix.glseven.local:9180/apisix/admin/routes`（同域名不同端口）。
10. Kafka/Nacos 透明性：本地客户端按原生端口连接 kafka 9092（bootstrap 也可用 `kafka.glseven.local:9092`）、nacos 8848/9848 成功。

## 9. 已知边界与风险

1. **nginx 成为全栈流量单点**：`restart: always` 自愈；portal 重启期间宿主侧所有访问短暂中断（开发环境可接受）。
2. **stream 静态 upstream 启动期解析 DNS**：由 portal 最后一批启动保证；若单独先启动 portal（上游未就绪）nginx 会启动失败，属预期，README 注明；restart: always 会在上游就绪后拉起。
3. **AirPlay Receiver**：若宿主开启（macOS 默认开），宿主 5000 绑定失败——关闭 AirPlay Receiver 即可（README 注明）；不开则无影响。
4. **/etc/hosts 依赖**：新机器需执行一次性初始化命令（README 提供）。
5. **registry 5000 是默认端口原则下唯一需宿主侧配合的端口**（其余 25 个代理端口均为容器原生号，无宿主侧冲突源）。
6. **原生端口直绑宿主的固有代价**：8080/3000 等通用端口被 nginx 占用后，本机其他开发服务不能再绑定这些端口；如本机已有服务占用其中某端口，需先错开（宿主侧冲突会在拉起时报 `port is already allocated`）。

## 10. 明示不做（YAGNI）

- 日志轮转（logging max-size）——用户裁定本轮不做
- 资源限制（cpus/memory limits）——用户裁定本轮不做
- TCP 端口统一号段重排——违背「默认端口」原则
- Keycloak→openldap 用户联邦、APISIX 上游路由——保持既有定位（路由留空由微服务开发自配）
- nginx HTTPS/TLS 终结——开发环境明文足够，YAGNI

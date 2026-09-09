# 设计文档：nginx 统一入口重构（宿主端口收敛 + 反向代理）

- 日期：2026-09-09
- 状态：已经用户逐节确认
- 范围：glseven-docker 六域编排（23 个服务）的宿主端口暴露方式与门户 nginx 职责升级

## 1. 背景与目标

**现状**：23 个服务中 10 个容器直接绑定约 33 个宿主端口；portal nginx 仅提供静态导航页；端口编号风格混杂（原生号、18xxx、4808x、6080 并存）；nexus3 的宿主 5000 端口与 macOS AirPlay Receiver 冲突。

**目标形态**：

1. nginx（portal 域）成为**唯一**绑定宿主端口的容器，其余 22 个服务零宿主端口。
2. Web UI 通过子域名虚拟主机在 8000 端口暴露（如 `http://grafana.glseven.local`）。
3. TCP 协议端口通过 nginx stream 模块透明转发，**端口号与原生默认完全一致**——本地开发工具连接串零改动。
4. 端口尽量回归原生默认号：rabbitmq AMQP 由 35672 回归 5672；registry 保持 5000（经 nginx 代理，容器侧不与 AirPlay 冲突；若宿主开启 AirPlay Receiver 致 5000 绑定失败，关闭 AirPlay 即可，README 注明）。
5. 未来新增服务不再占用宿主端口，仅需在 nginx 增加转发规则。
6. 每个镜像拥有规范二级域名（=容器名）；DNS 名 + stream 原生端口覆盖无 HTTP 端点的服务，规则无一例外。

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
| etcd 暴露 | 全量代理（stream 2379 + 子域名），覆盖原「纯内网」约定 | 「因为是开发环境，所有的都要代理出来」 |
| 命名规则 | 二级域名=容器名；别名仅根域/es/apisix-admin | 「建议每个镜像都有自己的二级域名」 |
| 附带优化 | 仅 nginx 探针 + keycloak 代理头；**不做**日志轮转、资源限制 | 多选题选择 |

**已否决的备选**：路径前缀方式（open-webui 不支持子路径，各应用需改 base-path）；统一号段重排（违背"默认端口"原则）；UI 保留直连后备端口（与端口收敛目标冲突）。

## 3. 总体架构

```
宿主机工具/浏览器
      │  (仅 nginx 容器持有宿主端口)
      ▼
┌─────────────────── nginx (portal, 172.18.6.1) ───────────────────┐
│ :8000 http 块     → 20 个 server 块（根域 + 19 个服务端点 vhost）  │
│ :2379…:9180 stream → 18 条 TCP 透明转发（原生端口 → 容器原生端口）  │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼ glseven 网络内按服务名转发
              mysql / redis / mongo / kafka / … / apisix
```

**透明性原理**：stream 转发保持「宿主端口号 == 容器原生端口号」，Kafka `advertised.listeners`、Nacos 客户端「主端口 +1000」gRPC 推导、各数据库客户端连接串均不受代理影响。

**启动时序不变**：`common/compose-list.sh` 与 startup.sh/shutdown.sh 零改动；portal 仍是最后一批启动——这同时保证 nginx 启动时全部上游服务名可解析（stream 静态 upstream 在启动期解析 DNS）。

## 4. 端口规划终表

### 4.1 stream TCP 转发（18 条）

| 宿主端口 | 转发目标 | 说明 |
|---|---|---|
| 3306 | mysql:3306 | |
| 6379 | redis:6379 | |
| 27017 | mongo:27017 | |
| 5672 | rabbitmq:5672 | AMQP，由 35672 回归默认 |
| 1883 | rabbitmq:1883 | MQTT |
| 15675 | rabbitmq:15675 | MQTT over WebSocket |
| 9092 | kafka:9092 | advertised.listeners 透明 |
| 2379 | etcd:2379 | 开发环境全量代理（用户决策）；2380 peer 无客户端用途保持内网 |
| 389 | openldap:389 | LDAP |
| 636 | openldap:636 | LDAPS，TLS 透传 |
| 8848 | nacos:8848 | Open API |
| 9848 | nacos:9848 | gRPC，客户端推导 +1000 透明 |
| 11434 | ollama:11434 | LLM API |
| 9200 | elk:9200 | Elasticsearch API |
| 5044 | elk:5044 | Beats |
| 5000 | nexus3:5000 | Docker Registry；AirPlay 见 §9 |
| 9080 | apisix:9080 | APISIX 数据面 |
| 9180 | apisix:9180 | APISIX Admin API |

### 4.2 http 子域名路由（:8000，20 个 server 块）

| URL | 转发目标 | 说明 |
|---|---|---|
| `glseven.local`（根域） | 静态门户 index.html | |
| `mongo-express.glseven.local` | mongo-express:8081 | |
| `adminer.glseven.local` | adminer:8080 | |
| `rabbitmq.glseven.local` | rabbitmq:15672 | |
| `etcd.glseven.local` | etcd:2379 | REST/metrics/health |
| `prometheus.glseven.local` | prometheus:9090 | |
| `grafana.glseven.local` | grafana:3000 | |
| `elk.glseven.local` | elk:5601 | Kibana UI |
| `es.glseven.local` | elk:9200 | ES API（别名） |
| `php-ldap-admin.glseven.local` | php-ldap-admin:8080 | |
| `keycloak.glseven.local` | keycloak:8080 | |
| `nacos.glseven.local` | nacos:8080 | v3 控制台 |
| `xxl-job-admin.glseven.local` | xxl-job-admin:8080 | |
| `nexus3.glseven.local` | nexus3:8081 | |
| `portainer.glseven.local` | portainer:9000 | |
| `apisix.glseven.local` | apisix:9080 | 数据面 |
| `apisix-admin.glseven.local` | apisix:9180 | Admin API（X-API-KEY） |
| `ollama.glseven.local` | ollama:11434 | |
| `open-webui.glseven.local` | open-webui:8080 | |
| `moontv.glseven.local` | moontv:3000 | |

**命名规则**：二级域名 = 容器名（如 `nexus3`、`php-ldap-admin`、`xxl-job-admin`），无一例外；别名仅 3 个——根域 `glseven.local`（门户）、`es`（elk 镜像的 ES API 端点）、`apisix-admin`（APISIX Admin API 端点）。无 HTTP 端点的服务（mysql/redis/mongo/kafka/openldap）其二级域名仅作 DNS 解析（/etc/hosts → 127.0.0.1），配合 stream 原生端口使用，无需 nginx 配置。

**删除的 14 个 UI 直连端口**：18081、18080、15672、9090、3000、5601、6080、48082、48081、48080、8081、9000、8080、3001。

### 4.3 全量覆盖矩阵（22 个非 nginx 服务）

| 服务 | 代理形态 | 无宿主暴露的内部端口 |
|---|---|---|
| mysql | stream 3306 + DNS 名 | 33060 (X Protocol，已删) |
| redis | stream 6379 + DNS 名 | — |
| mongo | stream 27017 + DNS 名 | — |
| mongo-express | 子域名 | — |
| adminer | 子域名 | — |
| rabbitmq | stream 5672/1883/15675 + 子域名(15672) | 25672 (节点间) |
| kafka | stream 9092 + DNS 名 | — |
| etcd | stream 2379 + 子域名（全量代理） | 2380 (peer，无客户端用途) |
| prometheus | 子域名 | — |
| grafana | 子域名 | — |
| elk | 子域名(5601) + stream 9200/5044 | 9300 (ES 节点间) |
| openldap | stream 389/636 + DNS 名 | — |
| php-ldap-admin | 子域名 | — |
| keycloak | 子域名 | 9000 (管理端口，仅 Prometheus 抓取) |
| nacos | stream 8848/9848 + 子域名(控制台) | 7848/9849 (Raft/gRPC 内部) |
| xxl-job-admin | 子域名 | — |
| nexus3 | stream 5000 + 子域名(8081) | — |
| portainer | 子域名 | — |
| apisix | stream 9080/9180 | 9091 (Prometheus 抓取) |
| ollama | stream 11434 | — |
| open-webui | 子域名 | 8081 (内部) |
| moontv | 子域名 | — |

**DNS 名补充**：无 HTTP 端点的服务（mysql/redis/mongo/kafka/openldap）其二级域名仅在 /etc/hosts 解析为 127.0.0.1，配合 stream 原生端口使用（如 `mysql -h mysql.glseven.local -P 3306`），无需任何 nginx 配置。

**etcd 风险备注**：2379 无认证机制，暴露至宿主机为用户明示决策（开发环境全量代理，覆盖上一轮「勿新增宿主端口映射」约定）；2380 peer 端口无客户端用途，保持内网。

## 5. nginx 配置设计

### 5.1 文件结构

- `portal/conf/nginx.conf`（**新增**，挂载覆盖 `/etc/nginx/nginx.conf`）：
  - `load_module modules/ngx_stream_module.so;`（官方镜像内置该动态模块）
  - `http` 块：mime.types、`keepalive_timeout 65`、`client_max_body_size 512m`（nexus 制品/open-webui 文件上传）、`include /etc/nginx/conf.d/*.conf;`
  - `stream` 块：18 条 `upstream` + `server` 转发
- `portal/conf/default.conf`（**重写**）：20 个 server 块（根域静态 + 19 个服务端点 vhost）

### 5.2 关键参数

| 参数 | 值 | 理由 |
|---|---|---|
| stream `proxy_timeout` | `12h` | 默认 10m 会切断 MySQL/LDAP/Kafka 空闲长连接 |
| stream `proxy_connect_timeout` | `10s` | 常规 |
| http `client_max_body_size` | `512m` | 制品库上传、AI 文件上传 |
| vhost 通用头 | Host、X-Real-IP、X-Forwarded-For、X-Forwarded-Proto | 代理链路正确性 |
| WebSocket | `map $http_upgrade $connection_upgrade` + Upgrade/Connection 头 | portainer 控制台、grafana live、open-webui |
| `proxy_read_timeout` | `3600s` | LLM 长流式响应 |
| `proxy_buffering off` | vhost 通用 | open-webui SSE 流式输出平滑 |

### 5.3 nginx healthcheck

官方 nginx 镜像无 curl/wget（debian-slim 底座），沿用项目已验证的 TCP 探测模式：

```yaml
healthcheck:
  test: [ "CMD-SHELL", "bash -c '</dev/tcp/127.0.0.1/80' || exit 1" ]
  interval: 10s
  timeout: 5s
  retries: 10
  start_period: 30s
```

## 6. /etc/hosts 初始化

macOS 解析器不支持 hosts 通配符，且浏览器仅对 `*.localhost` 免配置；`*.glseven.local` 需精确条目。25 个主机名压缩为**一行追加**（22 个镜像名=容器名 + 3 个别名：根域、es、apisix-admin；hosts 支持一行多别名），README 提供复制即用命令（需 sudo）：

```
127.0.0.1 glseven.local mysql.glseven.local redis.glseven.local mongo.glseven.local mongo-express.glseven.local adminer.glseven.local rabbitmq.glseven.local kafka.glseven.local etcd.glseven.local prometheus.glseven.local grafana.glseven.local elk.glseven.local es.glseven.local openldap.glseven.local php-ldap-admin.glseven.local keycloak.glseven.local nacos.glseven.local xxl-job-admin.glseven.local nexus3.glseven.local portainer.glseven.local apisix.glseven.local apisix-admin.glseven.local ollama.glseven.local open-webui.glseven.local moontv.glseven.local
```

`.local` 后缀本属 mDNS：hosts 存在精确条目时优先生效，无副作用。

## 7. 文件级改动清单

| 文件 | 改动类型 | 内容 |
|---|---|---|
| `portal/conf/nginx.conf` | 新增 | 主配置：load_module + http + stream（§5.1） |
| `portal/conf/default.conf` | 重写 | 15 个子域名 vhost + 根域静态（§4.2/§5.2） |
| `docker-compose-portal.yml` | 修改 | 挂载 nginx.conf；ports 改为 8000 + 17 个 stream 端口；新增 healthcheck |
| `docker-compose-infra.yml` | 修改 | 删除 mysql/redis/mongo/mongo-express/adminer/rabbitmq/kafka 的 `ports:` |
| `docker-compose-observability.yml` | 修改 | 删除 prometheus/grafana/elk 的 `ports:` |
| `docker-compose-security.yml` | 修改 | 删除 openldap/php-ldap-admin/keycloak 的 `ports:` |
| `docker-compose-platform.yml` | 修改 | 删除 nacos/xxl-job-admin/nexus3/portainer/apisix 的 `ports:` |
| `docker-compose-apps.yml` | 修改 | 删除 ollama/open-webui/moontv 的 `ports:` |
| `common/env/keycloak.env` | 修改 | 新增 `KC_PROXY_HEADERS=xforwarded`（子域名代理下回调/重定向 URL 正确） |
| `portal/html/index.html` | 修改 | 卡片链接改为二级域名 URL（=容器名），分组结构保留 |
| `README.md` | 修改 | 新增「首次初始化：/etc/hosts」章节 + 新访问矩阵 + AirPlay 说明 |

**保持不变**：服务名/容器名/hostname、固定 IP（172.18.x.x）、`${DOCKER_VOLUME}` 卷路径、6 域 compose 划分、`compose-list.sh` 与 startup.sh/shutdown.sh、各服务 env 文件（除 keycloak.env）、prometheus 抓取配置（容器网内按服务名抓取，与宿主端口无关）、各服务 healthcheck。

## 8. 验证方案

1. 静态校验：每个改动的 compose 文件 `docker compose config -q` 零告警；`nginx -t`（进入 nginx 容器）通过。
2. 全量拉起（startup.sh）后：`docker ps` 仅 nginx 有端口映射；6 域 23 容器全部 healthy/running。
3. TCP 连通矩阵：对 18 个 stream 端口逐项 `nc -vz 127.0.0.1 <port>`；mysql/redis 用真实客户端登录验证（含 `mysql -h mysql.glseven.local` 域名形式）。
4. 浏览器验证：20 个子域名站点逐个访问，登录页/首页正常（需先完成 /etc/hosts 初始化）。
5. WebSocket：portainer 控制台可进入、grafana 面板 live 刷新。
6. SSE 流式：open-webui 对话流式输出平滑不卡顿。
7. Registry：`docker push localhost:5000/<image>`（localhost 端口自动视为 insecure；若用 `nexus3.glseven.local:5000` 需在 Docker Desktop 配置 insecure-registries）。
8. Keycloak：经 `keycloak.glseven.local` 登录 admin 控制台，回调 URL 正确（验证 KC_PROXY_HEADERS）。
9. 子域名 API 验证：`curl http://etcd.glseven.local:8000/version`、`curl http://ollama.glseven.local:8000/api/tags`、带 X-API-KEY 请求 `http://apisix-admin.glseven.local:8000/apisix/admin/routes`。
10. Kafka/Nacos 透明性：本地客户端按原生端口连接 kafka 9092（bootstrap 也可用 `kafka.glseven.local:9092`）、nacos 8848/9848 成功。

## 9. 已知边界与风险

1. **nginx 成为全栈流量单点**：`restart: always` 自愈；portal 重启期间宿主侧所有访问短暂中断（开发环境可接受）。
2. **stream 静态 upstream 启动期解析 DNS**：由 portal 最后一批启动保证；若单独先启动 portal（上游未就绪）nginx 会启动失败，属预期，README 注明；restart: always 会在上游就绪后拉起。
3. **AirPlay Receiver**：若宿主开启（macOS 默认开），宿主 5000 绑定失败——关闭 AirPlay Receiver 即可（README 注明）；不开则无影响。
4. **/etc/hosts 依赖**：新机器需执行一次性初始化命令（README 提供）。
5. **registry 5000 是默认端口原则下唯一需宿主侧配合的端口**（其余 18 条 stream 端口均无冲突风险）。

## 10. 明示不做（YAGNI）

- 日志轮转（logging max-size）——用户裁定本轮不做
- 资源限制（cpus/memory limits）——用户裁定本轮不做
- TCP 端口统一号段重排——违背「默认端口」原则
- Keycloak→openldap 用户联邦、APISIX 上游路由——保持既有定位（路由留空由微服务开发自配）
- nginx HTTPS/TLS 终结——开发环境明文足够，YAGNI

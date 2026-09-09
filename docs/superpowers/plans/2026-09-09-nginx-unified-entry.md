# nginx 统一入口重构实施计划（宿主端口收敛 + 反向代理 + 每镜像二级域名）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** nginx（portal 域）成为唯一持有宿主端口的容器（26 个宿主端口 = 11 个 http 监听 + 15 条 stream，监听端口一律等于容器原生端口），其余 22 个服务零宿主端口；每个镜像一个二级域名（=容器名，零别名）；nginx 配置按容器拆分（conf.d / stream-conf.d 各一容器一文件）。

**Architecture:** http 块监听端口 = 容器原生端口，按 server_name（Host 头）分流（18 个 server 块分布于 11 个监听端口；8080/3000/8081 为多实例共享端口）；stream 块按原生端口号透明转发（15 条，客户端连接串零改动；多端点实例同域名不同端口）。配置按容器拆分：http 侧 `conf.d/<容器名>.conf`（16 文件，含门户 portal.conf），stream 侧 `stream-conf.d/<容器名>.conf`（11 文件）。上游服务名为静态解析，依赖 portal 最后一批启动（compose-list.sh 不变）。

**Tech Stack:** Docker Compose v2、nginx:1.30.4 官方镜像（stream 静态编译内置，无需 load_module）、macOS /etc/hosts。

**规格依据:** `docs/superpowers/specs/2026-09-09-nginx-unified-entry-design.md`（已确认）

**执行方式说明:** 本仓库为纯配置编排（无单元测试框架），每个任务的"测试"= `docker compose config -q` 静态校验 / `nginx -t` / 容器内 TCP 探测。执行时可选用 superpowers:using-git-worktrees 创建隔离工作区；就地执行亦可。

---

## 文件结构总览

| 文件 | 操作 | 职责 |
|---|---|---|
| `portal/conf/nginx.conf` | 新增 | 主配置：http 块（含 WebSocket map）include conf.d；stream 块 include stream-conf.d |
| `portal/conf/snippets/proxy.conf` | 新增 | 反代通用参数片段，conf.d 各 vhost include |
| `portal/conf/stream-conf.d/<容器名>.conf` | 新增 ×11 | stream TCP 透传，每容器一文件（rabbitmq 3 条、openldap/nacos/elk 各 2 条同文件） |
| `portal/conf/conf.d/<容器名>.conf` | 新增 ×16 | http 虚拟主机，每容器一文件（elk/apisix 多端点同文件；portal.conf 为根域门户） |
| `portal/conf/default.conf` | 删除 | 旧单文件静态站，职责由 conf.d/portal.conf 承接 |
| `docker-compose-portal.yml` | 重写 | 挂载目录化（nginx.conf/snippets/conf.d/stream-conf.d/html）；ports 改为 26 个端口（8000 门户 + 10 个原生 http 监听 + 15 条 stream）；healthcheck 探 8000 |
| `docker-compose-infra.yml` | 修改 | 删除 mysql/redis/mongo/mongo-express/adminer/rabbitmq/kafka 的 ports |
| `docker-compose-observability.yml` | 修改 | 删除 prometheus/grafana/elk 的 ports |
| `docker-compose-security.yml` | 修改 | 删除 openldap/php-ldap-admin/keycloak 的 ports |
| `docker-compose-platform.yml` | 修改 | 删除 nacos/xxl-job-admin/nexus3/portainer/apisix 的 ports |
| `docker-compose-apps.yml` | 修改 | 删除 ollama/open-webui/moontv 的 ports |
| `common/env/keycloak.env` | 修改 | 新增 `KC_PROXY_HEADERS=xforwarded` |
| `portal/html/index.html` | 重写 | 卡片链接改为「二级域名:原生端口」（data-host + data-port） |
| `README.md` | 修改 | /etc/hosts 初始化 + 新访问矩阵 + AirPlay 说明更新 |

提交切分：Task 4（portal 全套）→ Task 5（infra）→ Task 6（observability/security + env）→ Task 7（platform/apps）→ Task 8（导航页）→ Task 9（README）→ Task 10 端到端验证（修复则追加 fix 提交）。

---

### Task 1: 镜像能力与环境预检

**Files:** 无（只读验证）

- [ ] **Step 1: 确认官方镜像 stream 编译方式（决定是否需要 load_module）**

Run:
```shell
docker run --rm nginx:1.30.4 sh -c 'ls /usr/lib/nginx/modules | grep stream; nginx -V 2>&1 | tr " " "\n" | grep -- --with-stream'
```
Expected: `nginx -V` 含 `--with-stream`（静态编译内置）；modules 目录**无** `ngx_stream_module.so`（2026-09-09 实测），故 nginx.conf **不得写 load_module**。

- [ ] **Step 2: 确认镜像内 bash 可用（healthcheck 依赖 /dev/tcp 探测）**

Run:
```shell
docker run --rm nginx:1.30.4 bash -c 'echo bash-ok'
```
Expected: 输出 `bash-ok`。

- [ ] **Step 3: 确认 glseven 网络存在且当前栈在运行（Task 2 的 nginx -t 需在网内解析上游名）**

Run:
```shell
docker network inspect glseven --format '{{.Name}}' && docker ps --format '{{.Names}}' | head -5
```
Expected: 输出 `glseven` 与若干容器名。若网络不存在，先执行 `bash startup.sh`（用旧配置拉起即可，Task 10 会全量重启）。

- [ ] **Step 4: 预检宿主 5000 端口占用情况（AirPlay）**

Run:
```shell
lsof -nP -iTCP:5000 -sTCP:LISTEN || echo "port 5000 free"
```
Expected: 输出 `port 5000 free`。若列出 ControlCenter 监听，说明 AirPlay Receiver 开启：Task 10 拉起时会报 5000 绑定失败，需请用户在「系统设置 → 通用 → AirDrop 与接力」关闭 AirPlay Receiver（README 已注明，不阻塞本任务）。

---

### Task 2: 新增 nginx.conf、snippets 与 stream-conf.d/（每容器一文件）

**Files:**
- Create: `portal/conf/nginx.conf`
- Create: `portal/conf/snippets/proxy.conf`
- Create: `portal/conf/stream-conf.d/*.conf`（11 个文件，见 Step 3）

- [ ] **Step 1: 创建 `portal/conf/nginx.conf`**

```nginx
# GlSeven 统一入口主配置：http 按容器拆分（conf.d/<容器名>.conf）+ stream 按容器拆分（stream-conf.d/<容器名>.conf）。
# 仅 nginx（portal 域）持有宿主端口；stream 静态上游在启动期解析服务名，
# 依赖 portal 最后一批启动（common/compose-list.sh），勿提前单独拉起本服务。

# stream 已随官方镜像静态编译内置（nginx -V: --with-stream），无需 load_module。

user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    sendfile           on;
    keepalive_timeout  65;
    # nexus 制品上传 / open-webui 文件上传
    client_max_body_size 512m;

    # WebSocket 升级头映射（供 conf.d 各 vhost include 的 snippets/proxy.conf 引用）
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # 每容器一个配置文件（含静态门户 portal.conf）
    include /etc/nginx/conf.d/*.conf;
}

stream {
    # 默认 10m 会切断 MySQL/LDAP/Kafka 空闲长连接，显式放宽（作用于全部 stream 转发）。
    proxy_connect_timeout 10s;
    proxy_timeout 12h;

    # 每容器一个配置文件（15 条转发：rabbitmq 3 条、openldap/nacos/elk 各 2 条同文件）
    include /etc/nginx/stream-conf.d/*.conf;
}
```

- [ ] **Step 2: 创建 `portal/conf/snippets/proxy.conf`**

```nginx
# 反代通用参数（conf.d 各 vhost include；compose 以目录 :ro 挂载）。
proxy_http_version 1.1;
# $http_host 保留客户端原始 Host（含端口）：$host 剥端口会让 Portainer 2.45 等做
# Origin vs Host CSRF 校验的服务报 "cross-origin request detected" 403。
proxy_set_header Host              $http_host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;        # Keycloak KC_PROXY_HEADERS=xforwarded 重建 URL 所需
proxy_set_header X-Forwarded-Port  $server_port; # $host 不含端口，端口由本头补齐
proxy_set_header Upgrade           $http_upgrade;
proxy_set_header Connection        $connection_upgrade;
proxy_read_timeout  3600s;   # LLM 长流式响应
proxy_send_timeout  3600s;
proxy_buffering     off;     # open-webui SSE 流式输出平滑
```

- [ ] **Step 3: 创建 `portal/conf/stream-conf.d/` 下 11 个文件（每容器一文件）**

**`portal/conf/stream-conf.d/mysql.conf`**
```nginx
# stream：MySQL 原生端口透传
server { listen 3306; proxy_pass mysql:3306; }
```

**`portal/conf/stream-conf.d/redis.conf`**
```nginx
# stream：Redis 原生端口透传
server { listen 6379; proxy_pass redis:6379; }
```

**`portal/conf/stream-conf.d/mongo.conf`**
```nginx
# stream：MongoDB 原生端口透传
server { listen 27017; proxy_pass mongo:27017; }
```

**`portal/conf/stream-conf.d/rabbitmq.conf`**
```nginx
# stream：RabbitMQ 多协议透传（AMQP 由 35672 回归默认）
server { listen 5672;  proxy_pass rabbitmq:5672; }   # AMQP
server { listen 1883;  proxy_pass rabbitmq:1883; }   # MQTT
server { listen 15675; proxy_pass rabbitmq:15675; }  # MQTT over WebSocket
```

**`portal/conf/stream-conf.d/kafka.conf`**
```nginx
# stream：Kafka 原生端口透传（TCP 层透明；broker advertised 地址为 kafka:9092，宿主客户端需 hosts 条目或仅容器网络内使用）
server { listen 9092; proxy_pass kafka:9092; }
```

**`portal/conf/stream-conf.d/etcd.conf`**
```nginx
# stream：etcd 客户端端口透传（HTTP REST 与 gRPC 混合端口，gRPC 不能走 http 反代；2380 peer 保持内网）
server { listen 2379; proxy_pass etcd:2379; }
```

**`portal/conf/stream-conf.d/openldap.conf`**
```nginx
# stream：OpenLDAP 透传
server { listen 389; proxy_pass openldap:389; }
server { listen 636; proxy_pass openldap:636; }   # LDAPS，TLS 透传
```

**`portal/conf/stream-conf.d/nacos.conf`**
```nginx
# stream：Nacos API/gRPC 透传（客户端按主端口+1000 推导，透明）
server { listen 8848; proxy_pass nacos:8848; }
server { listen 9848; proxy_pass nacos:9848; }
```

**`portal/conf/stream-conf.d/nexus3.conf`**
```nginx
# stream：Docker Registry 透传（AirPlay 见 README）
server { listen 5000; proxy_pass nexus3:5000; }
```

**`portal/conf/stream-conf.d/ollama.conf`**
```nginx
# stream：Ollama HTTP API 经 TCP 透传（curl 照常可用）
server { listen 11434; proxy_pass ollama:11434; }
```

**`portal/conf/stream-conf.d/elk.conf`**
```nginx
# stream：Beats 透传（ES API 9200 走 conf.d/elk.conf 的 http vhost）
server { listen 5044; proxy_pass elk:5044; }
```

- [ ] **Step 4: 语法预检（依赖 Task 1 Step 3 的栈在运行）**

Run:
```shell
docker run --rm --network glseven \
  -v "$PWD/portal/conf/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/portal/conf/snippets:/etc/nginx/snippets:ro" \
  -v "$PWD/portal/conf/conf.d:/etc/nginx/conf.d:ro" \
  -v "$PWD/portal/conf/stream-conf.d:/etc/nginx/stream-conf.d:ro" \
  nginx:1.30.4 nginx -t
```
Expected: `nginx: configuration file /etc/nginx/nginx.conf syntax is ok` + `test is successful`。
说明：此时 conf.d 目录尚未创建，docker run 会创建空目录挂载，`include` 通配无匹配不报错，本步验证主配置骨架（map/stream include）；完整验证在 Task 3 之后重跑本命令。

---

### Task 3: 删除 default.conf，按容器创建 conf.d/（16 个文件）

**Files:**
- Delete: `portal/conf/default.conf`
- Create: `portal/conf/conf.d/*.conf`（16 个文件，见 Step 2/3）

- [ ] **Step 1: 删除旧单文件静态站配置**

Run:
```shell
git rm portal/conf/default.conf
```
Expected: `rm 'portal/conf/default.conf'`。

- [ ] **Step 2: 创建门户与共享端口组文件（11 个，每容器一文件）**

**`portal/conf/conf.d/portal.conf`**（根域静态门户，nginx 自身）

```nginx
# 根域静态门户（nginx 自身）：全栈唯一非原生端口约定（宿主 8000，见 compose ports 注释）
server {
    listen 8000;
    server_name glseven.local;

    root  /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

**`portal/conf/conf.d/grafana.conf`**

```nginx
# Grafana 监控可视化（原生端口 3000）
server {
    listen 3000;
    server_name grafana.glseven.local;
    location / {
        proxy_pass http://grafana:3000;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/moontv.conf`**

```nginx
# MoonTV (LunaTV) 影视聚合（原生端口 3000，与 grafana 同端口按 Host 分流）
server {
    listen 3000;
    server_name moontv.glseven.local;
    location / {
        proxy_pass http://moontv:3000;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/mongo-express.conf`**

```nginx
# mongo-express MongoDB Web 管理（原生端口 8081）
server {
    listen 8081;
    server_name mongo-express.glseven.local;
    location / {
        proxy_pass http://mongo-express:8081;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/nexus3.conf`**

```nginx
# Nexus3 Web UI（原生端口 8081，与 mongo-express 同端口按 Host 分流；Registry 5000 走 stream）
server {
    listen 8081;
    server_name nexus3.glseven.local;
    location / {
        proxy_pass http://nexus3:8081;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/adminer.conf`**

```nginx
# Adminer 数据库管理（原生端口 8080）
server {
    listen 8080;
    server_name adminer.glseven.local;
    location / {
        proxy_pass http://adminer:8080;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/php-ldap-admin.conf`**

```nginx
# phpLDAPadmin 目录管理（原生端口 8080，8080 组按 Host 分流）
server {
    listen 8080;
    server_name php-ldap-admin.glseven.local;
    location / {
        proxy_pass http://php-ldap-admin:8080;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/keycloak.conf`**

```nginx
# Keycloak 统一身份认证（原生端口 8080；代理头由 KC_PROXY_HEADERS=xforwarded 配合）
server {
    listen 8080;
    server_name keycloak.glseven.local;
    location / {
        proxy_pass http://keycloak:8080;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/nacos.conf`**

```nginx
# Nacos v3 控制台（原生端口 8080；Open API/gRPC 8848/9848 走 stream）
server {
    listen 8080;
    server_name nacos.glseven.local;
    location / {
        proxy_pass http://nacos:8080;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/xxl-job-admin.conf`**

```nginx
# XXL-JOB 控制台（原生端口 8080；context-path 保留前缀）
server {
    listen 8080;
    server_name xxl-job-admin.glseven.local;
    location / {
        proxy_pass http://xxl-job-admin:8080;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/open-webui.conf`**

```nginx
# Open WebUI LLM 对话前端（原生端口 8080；SSE 流式由 snippets 的 proxy_buffering off 保障）
server {
    listen 8080;
    server_name open-webui.glseven.local;
    location / {
        proxy_pass http://open-webui:8080;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

- [ ] **Step 3: 创建独占端口文件（5 个）**

**`portal/conf/conf.d/portainer.conf`**

```nginx
# Portainer 容器管理（原生端口 9000；WebSocket 由 snippets Upgrade 头保障）
server {
    listen 9000;
    server_name portainer.glseven.local;
    location / {
        proxy_pass http://portainer:9000;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/prometheus.conf`**

```nginx
# Prometheus 指标查询（原生端口 9090）
server {
    listen 9090;
    server_name prometheus.glseven.local;
    location / {
        proxy_pass http://prometheus:9090;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/elk.conf`**（多端点：Kibana + ES API 同文件）

```nginx
# ELK：Kibana UI（5601）与 ES API（9200）同域名不同端口
server {
    listen 5601;
    server_name elk.glseven.local;
    location / {
        proxy_pass http://elk:5601;
        include /etc/nginx/snippets/proxy.conf;
    }
}

server {
    listen 9200;
    server_name elk.glseven.local;
    location / {
        proxy_pass http://elk:9200;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/rabbitmq.conf`**

```nginx
# RabbitMQ 管理台（原生端口 15672；AMQP/MQTT 走 stream-conf.d/rabbitmq.conf）
server {
    listen 15672;
    server_name rabbitmq.glseven.local;
    location / {
        proxy_pass http://rabbitmq:15672;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

**`portal/conf/conf.d/apisix.conf`**（多端点：数据面 + Admin API 同文件）

```nginx
# APISIX：数据面（9080）与 Admin API（9180，X-API-KEY 鉴权）同域名不同端口
server {
    listen 9080;
    server_name apisix.glseven.local;
    location / {
        proxy_pass http://apisix:9080;
        include /etc/nginx/snippets/proxy.conf;
    }
}

server {
    listen 9180;
    server_name apisix.glseven.local;
    location / {
        proxy_pass http://apisix:9180;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

- [ ] **Step 4: 重跑完整配置预检（含全部 vhost 的上游解析）**

Run: 同 Task 2 Step 4 的 docker run 命令（此时 conf.d/stream-conf.d 均已就绪）。
Expected: `syntax is ok` + `test is successful`。若报 `host not found in upstream`，确认对应容器在运行（Task 1 Step 3）。

---

### Task 4: 重写 docker-compose-portal.yml 并提交 portal 全套

**Files:**
- Modify（整体重写）: `docker-compose-portal.yml`

- [ ] **Step 1: 用以下内容完整替换 `docker-compose-portal.yml`**

```yaml
name: portal

networks:
  glseven:
    external: true

services:

  # Portal 172.18.6.x ==================================================================================================

  nginx:
    # 统一入口：http 虚拟主机（监听端口 = 容器原生端口，18 个 server 块）+ stream TCP 透明转发（15 条原生端口）。
    # 全栈唯一持有宿主端口的容器；stream 静态上游依赖 portal 最后一批启动（compose-list.sh）。
    image: nginx:1.30.4
    container_name: nginx
    hostname: nginx
    restart: always
    env_file:
      - common/env/common.env
    volumes:
      - ./portal/conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./portal/conf/snippets:/etc/nginx/snippets:ro
      - ./portal/conf/conf.d:/etc/nginx/conf.d:ro
      - ./portal/conf/stream-conf.d:/etc/nginx/stream-conf.d:ro
      - ./portal/html:/usr/share/nginx/html:ro
    networks:
      glseven:
        ipv4_address: 172.18.6.1
    ports:
      - "8000:8000"    # http：静态门户（nginx 自身约定端口，全栈唯一非原生号）
      - "3000:3000"    # http → grafana / moontv（同端口按 Host 分流）
      - "8080:8080"    # http → adminer / php-ldap-admin / keycloak / nacos / xxl-job-admin / open-webui
      - "8081:8081"    # http → mongo-express / nexus3
      - "9000:9000"    # http → portainer
      - "9090:9090"    # http → prometheus
      - "5601:5601"    # http → elk Kibana
      - "9200:9200"    # http → elk ES API
      - "15672:15672"  # http → rabbitmq 管理
      - "9080:9080"    # http → apisix 数据面
      - "9180:9180"    # http → apisix Admin API
      - "3306:3306"    # stream → mysql
      - "6379:6379"    # stream → redis
      - "27017:27017"  # stream → mongo
      - "5672:5672"    # stream → rabbitmq AMQP
      - "1883:1883"    # stream → rabbitmq MQTT
      - "15675:15675"  # stream → rabbitmq MQTT-WS
      - "9092:9092"    # stream → kafka
      - "2379:2379"    # stream → etcd（HTTP REST/gRPC 透传）
      - "389:389"      # stream → openldap
      - "636:636"      # stream → openldap LDAPS
      - "8848:8848"    # stream → nacos Open API
      - "9848:9848"    # stream → nacos gRPC
      - "11434:11434"  # stream → ollama
      - "5044:5044"    # stream → elk Beats
      - "5000:5000"    # stream → nexus3 Docker Registry（AirPlay 见 README）
    healthcheck:
      # 镜像内无 curl/wget（debian-slim 底座），沿用项目已验证的 bash /dev/tcp 探测模式；探门户监听 8000。
      test: [ "CMD-SHELL", "bash -c '</dev/tcp/127.0.0.1/8000' || exit 1" ]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
```

- [ ] **Step 2: 静态校验**

Run:
```shell
docker compose -f docker-compose-portal.yml config -q && echo COMPOSE-OK
```
Expected: 输出 `COMPOSE-OK`（无告警）。

- [ ] **Step 3: 提交 portal 全套（Task 2-4）**

```shell
git add -A portal/conf docker-compose-portal.yml
git commit -m "feat(portal): nginx unified entry (per-container conf.d/stream-conf.d, 26 native-port listeners)"
```

---

### Task 5: docker-compose-infra.yml 移除 7 个服务的 ports

**Files:**
- Modify: `docker-compose-infra.yml`

统一替换文本（每个服务的 `ports:` 块删除后，在原位置留下）：

```yaml
    # 宿主访问统一经 nginx（portal）代理：每容器一配置文件，stream 见 portal/conf/stream-conf.d/，子域名见 portal/conf/conf.d/。
```

- [ ] **Step 1: mysql —— 将以下整块替换为统一替换文本**

```yaml
    ports:
      - "3306:3306"
      # Port 33060 (MySQL X Protocol) is not used by any service; removed to reduce attack surface.
```

- [ ] **Step 2: redis —— 将以下整块替换为统一替换文本**

```yaml
    ports:
      - "6379:6379"
```

- [ ] **Step 3: mongo —— 将以下整块替换为统一替换文本**

```yaml
    ports:
      - "27017:27017"
```

- [ ] **Step 4: mongo-express —— 将以下整块替换为统一替换文本**

```yaml
    ports:
      - "18081:8081"
```

- [ ] **Step 5: adminer —— 将以下整块替换为统一替换文本**

```yaml
    ports:
      - "18080:8080"
```

- [ ] **Step 6: rabbitmq —— 将以下整块替换为统一替换文本**

```yaml
    ports:
      - "35672:5672"   # AMQP
      - "15672:15672"  # Management UI
      - "1883:1883"    # MQTT
      - "15675:15675"  # MQTT over WebSocket
```

- [ ] **Step 7: kafka —— 将以下整块替换为统一替换文本**

```yaml
    ports:
      - "9092:9092"
```

- [ ] **Step 8: 静态校验**

Run:
```shell
docker compose -f docker-compose-infra.yml config -q && echo COMPOSE-OK
grep -c "ports:" docker-compose-infra.yml
```
Expected: `COMPOSE-OK`；`grep -c` 输出 `0`。

- [ ] **Step 9: 提交**

```shell
git add docker-compose-infra.yml
git commit -m "refactor(infra): drop direct host ports (access via nginx unified entry)"
```

---

### Task 6: observability/security 移除 ports + keycloak 代理头

**Files:**
- Modify: `docker-compose-observability.yml`
- Modify: `docker-compose-security.yml`
- Modify: `common/env/keycloak.env`

统一替换文本同 Task 5。

- [ ] **Step 1: prometheus —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "9090:9090"
```

- [ ] **Step 2: grafana —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "3000:3000"
```

- [ ] **Step 3: elk —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "5601:5601"
      - "9200:9200"
      - "5044:5044"
```

- [ ] **Step 4: openldap —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "389:389"
      - "636:636"
```

- [ ] **Step 5: php-ldap-admin —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "6080:8080"
```

- [ ] **Step 6: keycloak —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "48082:8080"   # Admin Console / 认证端点
```

- [ ] **Step 7: `common/env/keycloak.env` 末尾追加**

```shell
# 经 nginx 子域名（keycloak.glseven.local）反代时保持回调/重定向 URL 正确。
KC_PROXY_HEADERS=xforwarded
```

- [ ] **Step 8: 静态校验**

Run:
```shell
docker compose -f docker-compose-observability.yml config -q \
  && docker compose -f docker-compose-security.yml config -q \
  && grep -c "ports:" docker-compose-observability.yml docker-compose-security.yml \
  && grep KC_PROXY_HEADERS common/env/keycloak.env
```
Expected: `COMPOSE-OK` 无输出报错；两个文件 `ports:` 计数均为 `0`；末行输出 `KC_PROXY_HEADERS=xforwarded`。

- [ ] **Step 9: 提交**

```shell
git add docker-compose-observability.yml docker-compose-security.yml common/env/keycloak.env
git commit -m "refactor(observability,security): drop direct host ports; keycloak x-forwarded headers"
```

---

### Task 7: platform/apps 移除 ports

**Files:**
- Modify: `docker-compose-platform.yml`
- Modify: `docker-compose-apps.yml`

统一替换文本同 Task 5。

- [ ] **Step 1: nacos —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "48081:8080"
      - "8848:8848"
      - "9848:9848"
```

- [ ] **Step 2: nacos healthcheck 注释更新（原注释提及"宿主映射 48081"）**

将：
```yaml
      # v3 控制台/就绪端点在 8080（容器内直连，宿主映射 48081）；8848 的 actuator health 在 v3 已不暴露。
```
替换为：
```yaml
      # v3 控制台/就绪端点在 8080（容器内直连，宿主经 nacos.glseven.local 代理）；8848 的 actuator health 在 v3 已不暴露。
```

- [ ] **Step 3: xxl-job-admin —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "48080:8080"
```

- [ ] **Step 4: nexus3 —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "5000:5000"   # Docker Registry
      - "8081:8081"   # Nexus Web UI
```

- [ ] **Step 5: portainer —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "9000:9000"
```

- [ ] **Step 6: apisix —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "9080:9080"   # 网关数据面（无路由时 404 为预期）
      - "9180:9180"   # Admin API（X-API-KEY 见 apisix/conf/config.yaml）
```

- [ ] **Step 7: ollama —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "11434:11434"
```

- [ ] **Step 8: open-webui —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "8080:8080"
```

- [ ] **Step 9: moontv —— 删除以下整块，替换为统一替换文本**

```yaml
    ports:
      - "3001:3000"
```

- [ ] **Step 10: 静态校验**

Run:
```shell
docker compose -f docker-compose-platform.yml config -q \
  && docker compose -f docker-compose-apps.yml config -q \
  && grep -c "ports:" docker-compose-platform.yml docker-compose-apps.yml
```
Expected: 无报错；两个文件 `ports:` 计数均为 `0`。

- [ ] **Step 11: 提交**

```shell
git add docker-compose-platform.yml docker-compose-apps.yml
git commit -m "refactor(platform,apps): drop direct host ports (access via nginx unified entry)"
```

---

### Task 8: 导航页卡片改为二级域名链接

**Files:**
- Modify（整体重写）: `portal/html/index.html`

- [ ] **Step 1: 用以下内容完整替换 `portal/html/index.html`（分组结构保留，16 张卡片每实例一张，data-host + data-port + data-path 机制，链接由脚本按「域名:原生端口」拼装）**

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>GlSeven 导航</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    background: #0f172a; color: #e2e8f0; min-height: 100vh; padding: 40px 24px;
  }
  .wrap { max-width: 1080px; margin: 0 auto; }
  h1 { font-size: 26px; margin-bottom: 6px; }
  .sub { color: #64748b; font-size: 14px; margin-bottom: 32px; }
  .group-title { font-size: 15px; color: #94a3b8; margin: 26px 0 12px; letter-spacing: 1px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 14px; }
  a.card {
    display: block; background: #1e293b; border: 1px solid #334155; border-radius: 10px;
    padding: 16px 18px; text-decoration: none; color: inherit;
    transition: transform .12s ease, border-color .12s ease;
  }
  a.card:hover { transform: translateY(-2px); border-color: #38bdf8; }
  .card .name { font-size: 16px; font-weight: 600; color: #f1f5f9; }
  .card .desc { font-size: 12.5px; color: #94a3b8; margin-top: 5px; line-height: 1.5; }
  .card .port { font-size: 12px; color: #38bdf8; margin-top: 8px; font-family: ui-monospace, monospace; }
  footer { margin-top: 48px; color: #475569; font-size: 12px; text-align: center; }
</style>
</head>
<body>
<div class="wrap">
  <h1>GlSeven 导航</h1>
  <div class="sub">统一经 nginx 代理：二级域名 = 容器名，端口 = 容器原生端口（首次使用需 /etc/hosts 初始化，见 README）</div>

  <div class="group-title">基础设施</div>
  <div class="grid">
    <a class="card" data-host="adminer" data-port="8080" href="#"><div class="name">Adminer</div><div class="desc">MySQL / MongoDB 数据库管理</div><div class="port">adminer.glseven.local:8080</div></a>
    <a class="card" data-host="mongo-express" data-port="8081" href="#"><div class="name">mongo-express</div><div class="desc">MongoDB Web 管理</div><div class="port">mongo-express.glseven.local:8081</div></a>
    <a class="card" data-host="rabbitmq" data-port="15672" href="#"><div class="name">RabbitMQ 管理</div><div class="desc">队列 / 交换机 / 连接管理台</div><div class="port">rabbitmq.glseven.local:15672</div></a>
  </div>

  <div class="group-title">认证与身份</div>
  <div class="grid">
    <a class="card" data-host="php-ldap-admin" data-port="8080" href="#"><div class="name">phpLDAPadmin</div><div class="desc">OpenLDAP 目录管理</div><div class="port">php-ldap-admin.glseven.local:8080</div></a>
    <a class="card" data-host="keycloak" data-port="8080" href="#"><div class="name">Keycloak</div><div class="desc">统一身份认证 SSO（Admin Console）</div><div class="port">keycloak.glseven.local:8080</div></a>
  </div>

  <div class="group-title">平台服务</div>
  <div class="grid">
    <a class="card" data-host="nacos" data-port="8080" href="#"><div class="name">Nacos</div><div class="desc">注册与配置中心</div><div class="port">nacos.glseven.local:8080</div></a>
    <a class="card" data-host="xxl-job-admin" data-port="8080" data-path="/xxl-job-admin/" href="#"><div class="name">XXL-JOB</div><div class="desc">分布式任务调度</div><div class="port">xxl-job-admin.glseven.local:8080/xxl-job-admin/</div></a>
    <a class="card" data-host="nexus3" data-port="8081" href="#"><div class="name">Nexus</div><div class="desc">Maven / npm 制品仓库</div><div class="port">nexus3.glseven.local:8081</div></a>
    <a class="card" data-host="portainer" data-port="9000" href="#"><div class="name">Portainer</div><div class="desc">Docker 容器管理</div><div class="port">portainer.glseven.local:9000</div></a>
    <a class="card" data-host="apisix" data-port="9080" href="#"><div class="name">APISIX</div><div class="desc">API 网关数据面（Admin API 同域名 :9180）</div><div class="port">apisix.glseven.local:9080</div></a>
  </div>

  <div class="group-title">可观测性</div>
  <div class="grid">
    <a class="card" data-host="prometheus" data-port="9090" href="#"><div class="name">Prometheus</div><div class="desc">指标采集与查询</div><div class="port">prometheus.glseven.local:9090</div></a>
    <a class="card" data-host="grafana" data-port="3000" href="#"><div class="name">Grafana</div><div class="desc">监控可视化面板</div><div class="port">grafana.glseven.local:3000</div></a>
    <a class="card" data-host="elk" data-port="5601" href="#"><div class="name">Kibana</div><div class="desc">ELK 日志检索（ES API 同域名 :9200）</div><div class="port">elk.glseven.local:5601</div></a>
  </div>

  <div class="group-title">应用</div>
  <div class="grid">
    <a class="card" data-host="open-webui" data-port="8080" href="#"><div class="name">Open WebUI</div><div class="desc">Ollama 模型对话前端</div><div class="port">open-webui.glseven.local:8080</div></a>
    <a class="card" data-host="moontv" data-port="3000" href="#"><div class="name">MoonTV (LunaTV)</div><div class="desc">影视聚合</div><div class="port">moontv.glseven.local:3000</div></a>
    <a class="card" data-host="ollama" data-port="11434" href="#"><div class="name">Ollama</div><div class="desc">模型推理 API（stream 透传）</div><div class="port">ollama.glseven.local:11434</div></a>
  </div>

  <footer>GlSeven Docker · nginx unified entry</footer>
</div>
<script>
  // 链接 = 二级域名（=容器名）+ 容器原生端口（data-port），协议端口类服务不走此处（见 README）。
  document.querySelectorAll("a[data-host]").forEach(function (a) {
    a.href = "http://" + a.dataset.host + ".glseven.local:" + a.dataset.port + (a.dataset.path || "/");
  });
</script>
</body>
</html>
```

- [ ] **Step 2: 提交**

```shell
git add portal/html/index.html
git commit -m "feat(portal): nav cards link via subdomain:native-port"
```

---

### Task 9: README 更新（hosts 初始化 + 访问矩阵 + AirPlay 说明）

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 替换「快速开始」代码块（第 9-21 行）**

将：
````markdown
```shell
# 1. 准备环境变量（.env 提供 DOCKER_VOLUME / REDIS_PASSWORD 等插值，无 .env 时使用内置默认值）
cp .env.example .env

# 2. 启动：BASE 批次 → 等待 MySQL 健康 → DEFERRED 批次 → PORTAL
bash startup.sh

# 3. 全部 Web UI 入口聚合在导航页
open http://localhost:8000

# 停止：按启动逆序 down 并移除 glseven 网络
bash shutdown.sh
```
````
替换为：
````markdown
```shell
# 1. 准备环境变量（.env 提供 DOCKER_VOLUME / REDIS_PASSWORD 等插值，无 .env 时使用内置默认值）
cp .env.example .env

# 2. 首次初始化（一次性，需 sudo）：/etc/hosts 追加 23 个主机名（二级域名 = 容器名，零别名）
echo '127.0.0.1 glseven.local mysql.glseven.local redis.glseven.local mongo.glseven.local mongo-express.glseven.local adminer.glseven.local rabbitmq.glseven.local kafka.glseven.local etcd.glseven.local prometheus.glseven.local grafana.glseven.local elk.glseven.local openldap.glseven.local php-ldap-admin.glseven.local keycloak.glseven.local nacos.glseven.local xxl-job-admin.glseven.local nexus3.glseven.local portainer.glseven.local apisix.glseven.local ollama.glseven.local open-webui.glseven.local moontv.glseven.local' | sudo tee -a /etc/hosts

# 3. 启动：BASE 批次 → 等待 MySQL 健康 → DEFERRED 批次 → PORTAL
bash startup.sh

# 4. 全部入口聚合在导航页（nginx 为唯一持有宿主端口的容器）
open http://glseven.local:8000

# 停止：按启动逆序 down 并移除 glseven 网络
bash shutdown.sh
```
````

- [ ] **Step 2: 整体替换「服务访问入口」一节（原表格及下方两行说明）**

将原「## 服务访问入口」标题下的全部内容（原 48-68 行的表格与两段文字）替换为：

````markdown
**nginx（portal）是唯一持有宿主端口的容器**（26 个端口：8000 门户 + 10 个原生 http 监听 + 15 条 stream），其余 22 个服务零宿主端口；二级域名 = 容器名，URL 端口 = 容器原生端口，需先完成 /etc/hosts 初始化。

| 服务 | 入口 | 说明 |
|---|---|---|
| 导航门户 | http://glseven.local:8000 | 全部入口聚合（nginx 静态页） |
| Adminer | http://adminer.glseven.local:8080 | MySQL/Mongo 管理 |
| mongo-express | http://mongo-express.glseven.local:8081 | MongoDB 管理（凭据见 env） |
| RabbitMQ 管理 | http://rabbitmq.glseven.local:15672 | AMQP/MQTT 走下方协议端口 |
| phpLDAPadmin | http://php-ldap-admin.glseven.local:8080 | LDAP 管理 |
| Keycloak | http://keycloak.glseven.local:8080 | Admin Console / 认证端点 |
| Nacos | http://nacos.glseven.local:8080 | 控制台（API/gRPC 走下方协议端口） |
| XXL-JOB | http://xxl-job-admin.glseven.local:8080/xxl-job-admin/ | 控制台（context-path 保留前缀） |
| Nexus | http://nexus3.glseven.local:8081 | Web UI（Docker Registry 走 localhost:5000） |
| Portainer | http://portainer.glseven.local:9000 | 容器管理 |
| APISIX | http://apisix.glseven.local:9080 | 数据面（Admin API 同域名 :9180，X-API-KEY 见 apisix/conf/config.yaml） |
| Prometheus | http://prometheus.glseven.local:9090 | 指标（7 个抓取 job） |
| Grafana | http://grafana.glseven.local:3000 | 可视化（数据源已 provision） |
| Kibana | http://elk.glseven.local:5601 | 日志检索（ES API 同域名 :9200） |
| etcd | http://etcd.glseven.local:2379 | REST/health/metrics（stream TCP 透传，curl 可用） |
| Ollama | http://ollama.glseven.local:11434 | API 状态页（stream TCP 透传） |
| Open WebUI | http://open-webui.glseven.local:8080 | LLM 对话 |
| MoonTV | http://moontv.glseven.local:3000 | 影视聚合 |

全部端点统一为「域名 + 容器原生端口」。纯 TCP 协议端口由 nginx stream 透明转发（**端口号 = 原生默认**，也可用域名形式如 `mysql.glseven.local:3306`）：
mysql 3306、redis 6379、mongo 27017、AMQP 5672（由 35672 回归默认）、MQTT 1883、MQTT-WS 15675、kafka 9092、etcd 2379、ldap 389/636、nacos 8848/9848、ollama 11434、beats 5044、registry 5000。

仅容器网络内（未代理）：keycloak 管理端口 9000、apisix prometheus 指标 9091、etcd peer 2380。
````

- [ ] **Step 3: 更新「已知平台限制」中 nexus3 条目**

将：
```markdown
- **nexus3 Registry :5000**：macOS 上该端口常被 AirPlay Receiver（ControlCenter 进程）占用，需系统设置关闭 AirPlay Receiver 或调整端口映射。
```
替换为：
```markdown
- **Registry :5000**：端口绑定主体是 nginx（portal），但 macOS 上该端口仍可能被 AirPlay Receiver（ControlCenter 进程）占用导致容器启动报 `port is already allocated`，需在系统设置关闭 AirPlay Receiver（全栈唯一需宿主侧配合的端口）。
```

- [ ] **Step 4: 提交**

```shell
git add README.md
git commit -m "docs(readme): unified entry access matrix, one-shot /etc/hosts init, AirPlay note"
```

---

### Task 10: 全栈重启与端到端验证

**Files:** 无（验证；发现问题时修复并追加 fix 提交）

- [ ] **Step 1: 全部 6 个 compose 文件静态校验**

Run:
```shell
for f in docker-compose-*.yml; do docker compose -f "$f" config -q && echo "OK $f"; done
```
Expected: 6 行 `OK docker-compose-*.yml`。

- [ ] **Step 2: 全栈重启（旧容器需重建以应用配置变化）**

Run:
```shell
bash shutdown.sh && bash startup.sh
```
Expected: 三批次依次拉起，无报错。若 nginx 启动报 `port is already allocated`（5000），按 README AirPlay 说明处理；若报 `host not found in upstream`，确认是先于其他批次单独拉起了 portal（必须用 startup.sh 全流程）。

- [ ] **Step 3: 端口面验证（仅 nginx 有映射）**

Run:
```shell
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -v '^nginx' | grep '0.0.0.0' || echo "ONLY-NGINX-HAS-PORTS"
```
Expected: 输出 `ONLY-NGINX-HAS-PORTS`。

- [ ] **Step 4: 容器内 nginx 配置最终验证（含拆分文件计数）**

Run:
```shell
docker exec nginx nginx -t
docker exec nginx sh -c 'ls /etc/nginx/conf.d/*.conf | wc -l; ls /etc/nginx/stream-conf.d/*.conf | wc -l'
```
Expected: `syntax is ok` + `test is successful`；计数两行分别为 `16`（conf.d）与 `11`（stream-conf.d）。

- [ ] **Step 5: 26 端口连通矩阵（11 http 监听 + 15 stream）**

Run:
```shell
for p in 8000 3000 8080 8081 9000 9090 5601 9200 15672 9080 9180 3306 6379 27017 5672 1883 15675 9092 2379 389 636 8848 9848 11434 5044 5000; do nc -z -w 2 127.0.0.1 $p && echo "$p OK" || echo "$p FAIL"; done
```
Expected: 26 行全部 `OK`。

- [ ] **Step 6: 子域名 http 验证（需已完成 /etc/hosts 初始化）**

Run:
```shell
curl -sf -o /dev/null -w "portal %{http_code}\n"  http://glseven.local:8000/
curl -sf -o /dev/null -w "etcd %{http_code}\n"     http://etcd.glseven.local:2379/version
curl -sf -o /dev/null -w "ollama %{http_code}\n"   http://ollama.glseven.local:11434/api/tags
curl -sf -o /dev/null -w "prometheus %{http_code}\n" http://prometheus.glseven.local:9090/-/healthy
curl -sf -o /dev/null -w "grafana %{http_code}\n"  http://grafana.glseven.local:3000/api/health
curl -sf -o /dev/null -w "keycloak %{http_code}\n" http://keycloak.glseven.local:8080/
# 同域名不同端口：APISIX Admin API（:9180）
curl -s -o /dev/null -w "apisix-admin %{http_code}\n" -H "X-API-KEY: 7705a28bc106c39a9e959427f9351c51" http://apisix.glseven.local:9180/apisix/admin/routes
```
Expected: 每行输出 `2xx`/`3xx`（keycloak 为 302 跳登录属正常）。若域名不解析，执行 Task 9 Step 1 的 hosts 初始化命令。

- [ ] **Step 7: 协议真实客户端抽查（域名 + 原生端口两种形式）**

Run（mysql 用容器内客户端经 stream 全链路验证）:
```shell
docker exec mysql mysql -h127.0.0.1 -uroot -p"$(docker exec mysql printenv MYSQL_ROOT_PASSWORD)" -e 'select 1' >/dev/null && echo "mysql direct OK"
nc -z -w 2 mysql.glseven.local 3306 && echo "mysql via domain+nginx OK"
```
Expected: 两行 OK。

- [ ] **Step 8: Registry 链路验证**

Run:
```shell
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:5000/v2/
```
Expected: `200`（匿名开）或 `401`（需鉴权）——非超时/000 即证明 nginx → nexus3 链路通。

- [ ] **Step 9: 人工验证清单（浏览器，需用户配合）**

- 逐个访问 18 个 server 块对应站点（导航页 16 张卡片 + elk :9200 / apisix :9180 端点），登录页/首页正常
- Portainer 进入某容器控制台（WebSocket）
- open-webui 发起对话，SSE 流式输出平滑
- keycloak 经子域名登录 admin 控制台（验证 KC_PROXY_HEADERS 下回调 URL 正确）

- [ ] **Step 10: 验证收尾**

若有修复：修复后重跑对应验证步骤，并提交：
```shell
git add -A
git commit -m "fix: e2e validation fixes for unified entry"
```
无修复则本任务无提交。

---

## 验收标准（对照规格 §8）

1. `docker compose config -q` 全部 6 文件零告警 ✓（Task 10 Step 1）
2. `docker ps` 仅 nginx 有端口映射 ✓（Task 10 Step 3）
3. 26 个宿主端口 `nc` 全通（11 http 监听 + 15 stream）✓（Task 10 Step 5）
4. 18 个 server 块站点可访问（域名 + 原生端口）✓（Task 10 Step 6/9）
5. WebSocket / SSE / Keycloak 回调 / Registry push 链路 ✓（Task 10 Step 6-9）
6. Kafka/Nacos 透明性（原生端口连接）✓（Task 10 Step 5/7）

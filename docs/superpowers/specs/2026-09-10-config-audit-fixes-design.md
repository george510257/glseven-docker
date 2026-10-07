# 设计文档：全量配置审计修复（Kafka 宿主接入 / preflight 加固 / 日志轮转 / 入口兜底）

## 1. 背景与目标

对六域编排全量审计后，除既往已验证项（23 个镜像 tag 真实存在、compose 渲染零告警、MySQL 初始化脚本上下文正确、README 与实际配置一致）外，确认 11 个待修问题，按严重度分三组：

- **P1**：Kafka 宿主侧客户端依赖 hosts 劫持 workaround；preflight `chmod -R` 把 `.env` 凭据放权给同机用户；preflight 镜像代理不覆盖 quay.io（etcd 拉取在 NAS 上会卡死启动）。
- **P2**：Keycloak 探针仅 TCP 端口级；容器日志无轮转上限；共享端口 IP 直连误入首个 vhost；etcd 2379 宿主可达且无认证。
- **P3**：kibana.yml 注释版本过时；`grafana/conf/dashboards/` 目录不在 git；`check_published_ports` 不覆盖 macOS；除 ollama 外无资源上限。

目标：一次性修复 P1/P2/P3 全部 11 项，不引入新组件、不推翻既有明示决策。

## 2. 决策记录

| 决策点 | 结论 | 理由 |
|---|---|---|
| 修复范围 | P1+P2+P3 全覆盖（用户裁决） | 一次性收敛 |
| Kafka 方案 | 双 listener，EXTERNAL 29092 | 摆脱 hosts workaround，本机/局域网均可正经接入 |
| 日志轮转载体 | preflight 自愈写 `/etc/docker/daemon.json` | **用户裁决：配置一律进各自配置文件，不在 compose 内联**；daemon.json 与 preflight 既有 sysctl 持久化模式同构 |
| Kafka advertised 地址载体 | 直接写 kafka.env（部署变更时改文件） | env_file 不做 compose 插值（既往坑）；遵守"不进 compose"裁决，放弃 `environment:` 覆盖与 `KAFKA_ADVERTISED_HOST` 变量方案 |
| etcd 2379 暴露 | 维持既有明示决策（规格 §4.3 全量代理），仅 README 补风险标注 | 开认证连累 APISIX 复杂化，YAGNI |
| 资源上限（P3-11） | 明示不做 | 上限值与 NAS 规格强耦合，拍值反而添乱；ollama 已有的保留 |

## 3. 变更设计

### 3.1 Kafka 双 listener（P1-1）

`common/env/kafka.env`（唯一配置落点）：

```properties
KAFKA_LISTENERS=PLAINTEXT://:9092,EXTERNAL://:29092,CONTROLLER://:9093
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT
# 宿主/局域网客户端经 nginx stream 29092 接入；EXTERNAL advertised 为部署特定值：
# 本机 Docker Desktop 用默认 127.0.0.1；NAS 局域网其他机器接入时改成 NAS IP 后重建 kafka。
KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092,EXTERNAL://127.0.0.1:29092
```

语义约束：单节点 KRaft 下 EXTERNAL listener 只影响客户端元数据；容器内客户端仍走 PLAINTEXT（advertised `kafka:9092`），互不串扰。healthcheck（localhost:9092）与 controller 仲裁（kafka:9093）不受影响。

portal 侧结构性配置（nginx/端口声明本就属这两类文件）：

- `portal/conf/stream-conf.d/kafka.conf`：追加 `server { listen 29092; proxy_pass kafka:29092; }`，注释改写为"9092 供容器网内（advertised 裸名），29092 供宿主/局域网（advertised 127.0.0.1 或部署 IP）"
- `docker-compose-portal.yml` ports：追加 `"29092:29092"`

### 3.2 日志轮转（P2-5）

`common/preflight.sh` 新增第 7 步 `ensure_docker_log_rotation`（挂入 `run_preflight`，仅 Linux）：

- `/etc/docker/daemon.json` 不存在 → 写入 `{"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"3"}}`
- 已存在但 `log-driver` 或 `log-opts` 任一键缺失 → 打印 WARN 与手工合并示例，不冒险改写既有 JSON（shell 手改 JSON 易损坏）
- 已配置 → 跳过（幂等）
- 有写入时尝试 `systemctl reload docker`，失败则 WARN"重启 docker 后对新建容器生效"
- macOS 跳过（Docker Desktop 经 GUI 配置），README 补说明

数值取 50m × 3：开发环境量级，nginx/ELK 不触顶。

### 3.3 preflight 加固（P1-2 / P1-3 / P3-10）

- `fix_dir_permissions` 末尾（chmod -R 之后）补，用 if 语句形式（`[ ] && cmd || echo` 在 .env 不存在时会误报 chmod 失败，且 set -e 下短路链返回值陷阱不可靠，见既往坑）：
  ```bash
  # .env 含全部组件凭据，不得因上面的 go+rX 递归放权被同机用户读取
  if [ -f "$SCRIPT_DIR/.env" ]; then
    chmod 600 "$SCRIPT_DIR/.env" 2>/dev/null || echo "WARN: chmod 600 .env failed, continuing..."
  fi
  ```
- `pull_ghcr_images` 改名 `pull_registry_images`，按 registry 分派镜像代理：
  ```bash
  # 格式：<registry> <mirror1> <mirror2> ...（命中即止，全失败兜底直连）
  PREFLIGHT_REGISTRY_MIRRORS=(
    "ghcr.io ghcr.m.daocloud.io ghcr.nju.edu.cn"
    "quay.io quay.m.daocloud.io"
  )
  ```
  grep 提取正则扩为 `image:[[:space:]]*(ghcr\.io|quay\.io)/...`；实施时先实测 `quay.m.daocloud.io/coreos/etcd` 可用性，不可用则换实测可用的 quay 代理，全不可用则 quay 维持直连并在注释说明。
- `check_published_ports` 增加 macOS 分支：`lsof -nP -iTCP:$port -sTCP:LISTEN` 检测，进程名含 `docker`（com.docker.backend）视为正常占用（与 Linux 分支 docker-proxy 同语义），其余占用者报错退出。

### 3.4 Keycloak 探针升级（P2-4）

`docker-compose-security.yml` keycloak healthcheck test 改为（对既有字段改值，不新增配置项）：

```yaml
test: [ "CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/9000 && printf 'GET /health/ready HTTP/1.0\r\n\r\n' >&3 && grep -q '\"status\"[[:space:]]*:[[:space:]]*\"UP\"' <&3" ]
```

实施约束：先起临时容器实测镜像内 grep 可用性与 `/health/ready` 响应格式（Quarkus 输出可能是压缩 JSON），不可用则退化 `read`+`case` 匹配；探针语义为 HTTP 200 + status UP，符合"管理端口真监听 + /health/ready UP"验证标准。

### 3.5 nginx default_server 兜底（P2-6）

新增 `portal/conf/conf.d/00-default-catchall.conf`（文件名 00- 前缀示意覆盖顺序，default_server 标志本身决定优先）：

```nginx
# 共享端口 IP 直连兜底：未带二级域名时统一跳门户，避免按文件序误入 adminer/grafana/mongo-express
server { listen 3000 default_server; server_name _; return 302 http://glseven.local:8000/; }
server { listen 8080 default_server; server_name _; return 302 http://glseven.local:8000/; }
server { listen 8081 default_server; server_name _; return 302 http://glseven.local:8000/; }
```

仅覆盖三个多 vhost 共享端口；独占端口（8000/15672/9080 等）IP 直连本就命中唯一 server，不处理。

### 3.6 P3 杂项（P3-8 / P3-9）

- `elk/kibana/config/kibana.yml`：注释链接与版本 9.3 → 9.5
- 新增 `grafana/conf/dashboards/.gitkeep`（空文件，使目录入 git，provisioning provider 指向更直观）

### 3.7 README 同步

- 端口总数 26 → 27；协议端口清单 Kafka 段重写："kafka 29092（宿主/局域网客户端入口；kafka.env 的 EXTERNAL advertised 默认 127.0.0.1，局域网部署改 NAS IP 后重建 kafka）；9092 仅供容器网内"；`127.0.0.1 kafka` hosts workaround 废弃说明
- 日志轮转说明（daemon.json 50m×3 + macOS GUI 路径）
- etcd 2379 无认证风险标注（开发边界声明）
- .env.example 不新增变量（Kafka 方案不引入变量）

## 4. 文件级改动清单

> 本节为设计时快照：实施终态与审查校准（如 kafka.conf 注释语义修正、keycloak 探针锚定模式强化）以 `docs/superpowers/plans/2026-09-10-config-audit-fixes.md` 各任务审查注记为准。

| 文件 | 改动 |
|---|---|
| `common/env/kafka.env` | listener 三条改写 + EXTERNAL 注释 |
| `docker-compose-portal.yml` | ports 追加 29092 |
| `portal/conf/stream-conf.d/kafka.conf` | 追加 29092 透传 + 注释改写 |
| `portal/conf/nginx.conf` | stream 域计数注释 15 → 16 |
| `common/preflight.sh` | +`ensure_docker_log_rotation`；`fix_dir_permissions` 补 chmod 600；`pull_registry_images` 按 registry 分派；`check_published_ports` macOS 分支 |
| `docker-compose-security.yml` | keycloak healthcheck test 改 HTTP 级 |
| `portal/conf/conf.d/00-default-catchall.conf` | 新增（3 个 default_server） |
| `elk/kibana/config/kibana.yml` | 注释版本更正 |
| `grafana/conf/dashboards/.gitkeep` | 新增 |
| `README.md` | 端口计数、Kafka 客户端说明、日志轮转、etcd 风险标注 |

## 5. 验证方案

1. 静态：六文件 `docker compose config -q` 双路径（有 .env / `env -u` 清空环境变量后）零告警
2. 探针实测：临时 keycloak 容器内验证 grep 与 `/health/ready` 格式后，再落 healthcheck
3. quay 代理实测：`docker pull quay.m.daocloud.io/coreos/etcd:v3.6.14`（失败则按 3.3 规则换/降级）
4. nginx 实机：全栈拉起后 `docker exec nginx nginx -t`（裸跑 nginx -t 因 DNS 解析必失败，不作验证手段）
5. Kafka 端到端（两段拼合，宿主无需安装 kafka CLI）：
   - 宿主侧 TCP 探测 `bash -c '</dev/tcp/127.0.0.1/29092'` 验证 nginx stream 链路通
   - 容器内 `docker exec kafka kafka-console-producer/consumer --bootstrap-server 127.0.0.1:29092` 收发一条消息，验证 EXTERNAL listener + advertised 闭环（容器内 127.0.0.1 恰好同时命中监听与 advertised，可完整验证双 listener 语义）
   - 本机装有 kafka CLI 时可另做真宿主端到端（可选）
6. 入口兜底：`curl -sI http://127.0.0.1:8080/`（无 Host 域名）应 302 → 门户
7. 日志轮转：重启后新容器 `docker inspect` 确认 LogConfig 生效
8. 幂等回归：shutdown.sh → startup.sh 两轮，preflight 全部步骤幂等、全栈健康

## 6. 已知边界与风险

- EXTERNAL advertised 为静态部署值：局域网接入需改 kafka.env 并重建 kafka 容器（README 已写明路径），不能像 `KAFKA_ADVERTISED_HOST` 变量那样免改文件——为遵守"配置进配置文件"裁决接受的取舍
- daemon.json 为宿主级配置，影响该 Docker 上全部容器（专用 NAS 场景合理）；变更需 daemon reload/重启后仅对新建容器生效
- preflight JSON 写入仅覆盖"文件不存在"分支，存在但配置不全时只提示不代改（避免 shell 手改 JSON 损坏）
- Keycloak 探针镜像内工具可用性未预验证，实施时按 3.4 约束先实测再定稿

## 7. 明示不做（YAGNI）

- etcd 开认证 / 撤 2379 透传（维持既有决策）
- 全栈资源上限（P3-11，除 ollama 既有项外）
- Kafka `KAFKA_ADVERTISED_HOST` 变量化（用户裁决不引入 compose 侧插值）
- 监控补位（mysqld/redis/mongo exporter、node-exporter、cadvisor）
- 备份策略

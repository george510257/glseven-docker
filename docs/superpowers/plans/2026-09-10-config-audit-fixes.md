# 全量配置审计修复实施计划（Kafka 双 listener / preflight 加固 / 日志轮转 / 入口兜底）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地规格 `docs/superpowers/specs/2026-09-10-config-audit-fixes-design.md`：修复审计发现的 11 项问题（P1×3 / P2×4 / P3×4）。

**Architecture:** 配置一律落在各服务自己的配置文件（用户裁决，不在 compose 内联服务配置）：Kafka 双 listener 进 `kafka.env`，日志轮转走 preflight 自愈写 `/etc/docker/daemon.json`，preflight 扩展双 registry 镜像代理与 macOS 端口预检，Keycloak 探针升级 HTTP 级，nginx 共享端口加 default_server 兜底。

**Tech Stack:** Docker Compose v2（env_file 插值边界）、nginx 1.30（stream/default_server）、bash（sourced 脚本，宿主 `set -e` 环境）、apache/kafka 4.3 双 listener、Keycloak 26.7 管理端口。

**执行环境备忘：** 本计划在 worktree `/Users/george/.qoder/worktree/glseven-docker/fUjBwD` 执行；当前栈未拉起（`docker ps` 为空）；macOS（Darwin）+ Docker Desktop；`docker compose config` 已验证六个域文件零告警。

---

## 文件结构总览

| 文件 | 动作 | 职责 |
|---|---|---|
| `common/env/kafka.env` | 修改 | Kafka 双 listener 唯一配置落点 |
| `docker-compose-portal.yml` | 修改 | ports 加 29092；顶部注释计数更新 |
| `portal/conf/nginx.conf` | 修改 | stream 转发计数注释更新 |
| `common/preflight.sh` | 修改 | .env 600 / 双 registry 代理 / macOS lsof / daemon.json 日志轮转 |
| `docker-compose-security.yml` | 修改 | Keycloak healthcheck 升 HTTP 级 |
| `portal/conf/conf.d/00-default-catchall.conf` | 新建 | 共享端口 IP 直连 302 兜底 |
| `elk/kibana/config/kibana.yml` | 修改 | 注释版本 9.3→9.5 |
| `grafana/conf/dashboards/.gitkeep` | 新建 | 空目录入 git |
| `README.md` | 修改 | 端口计数 / Kafka 双 listener / 日志轮转 / etcd 风险 |

---

### Task 1: 实证前置——Keycloak 探针工具链与 quay 代理可用性

Task 4 与 Task 3 的代码变体取决于本任务实测结论，必须先做。

**Files:** 无仓库文件改动（仅产出实证结论，记录到本任务 checkbox 后随计划提交）。

- [ ] **Step 1: 起临时 Keycloak 容器（管理端口 9000）**

```bash
docker run --rm -d --name kc-probe -e KC_HEALTH_ENABLED=true -e KC_METRICS_ENABLED=true \
  keycloak/keycloak:26.7.3 start-dev
```

Expected: 输出容器 ID，`docker ps` 显示 kc-probe 状态 Up。

- [ ] **Step 2: 轮询等待管理端口监听（最长 120s）**

```bash
for i in $(seq 1 24); do
  docker exec kc-probe bash -c '</dev/tcp/127.0.0.1/9000' 2>/dev/null && { echo "READY after ${i}x5s"; break; }
  sleep 5
done
```

Expected: `READY after Nx5s`（N ≤ 24）。超时则查 `docker logs kc-probe`，不得继续后续步骤。

- [ ] **Step 3: 验证 grep 存在性与 /health/ready 响应格式**（2026-09-10 实测：镜像内无 `which` 命令——原样命令 exit 127，改用 `command -v grep` 验证：grep 存在于 `/usr/bin/grep`（GNU grep 3.6），结论 B 不适用；body 实测格式见下方记录）

```bash
docker exec kc-probe bash -c 'which grep && grep --version 2>/dev/null | head -1'
docker exec kc-probe bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000; printf "GET /health/ready HTTP/1.0\r\n\r\n" >&3; cat <&3' | head -20
```

Expected: 第一条输出 grep 路径（如 `/usr/bin/grep`）；第二条输出 `HTTP/1.1 200 OK` 头 + JSON 体，记录 body 中 status 键的确切格式（预期 `{"status":"UP",...}` 紧凑无空格）。（实测推翻：HTTP/1.0 回显 + 4 空格缩进 pretty JSON，见下方记录）

> **2026-09-10 实测记录（keycloak/keycloak:26.7.3，start-dev，管理端口 9000）**：
> - 服务端原样回显 `HTTP/1.0 200 OK`（请求用 HTTP/1.0，服务端按请求版本回显，非 `HTTP/1.1`）；
> - **body 并非紧凑 JSON，而是 4 空格缩进多行 pretty JSON**；headers 为 CRLF，body 行尾为 LF；
> - status 键确切格式：`"status": "UP"`（冒号后 1 个空格，顶层键带 4 空格缩进）。
>
> 完整实测响应（`cat <&3` 原样输出）：
>
> ```
> HTTP/1.0 200 OK
> content-type: application/json; charset=UTF-8
> cache-control: no-store
> content-length: 345
>
> {
>     "status": "UP",
>     "checks": [
>         {
>             "name": "Graceful Shutdown",
>             "status": "UP"
>         },
>         {
>             "name": "Keycloak database connections async health check",
>             "status": "UP"
>         },
>         {
>             "name": "Keycloak Initialized",
>             "status": "UP"
>         }
>     ]
> }
> ```
>
> Task 4 校准 grep 模式以本记录为准：模式必须兼容 `"status": "UP"`（冒号后带空格）的多行 pretty JSON。**局限（代码审查复现）**：非锚定模式 `grep -q '"status"...'` 会命中子 check 行——当顶层 status 为 DOWN 而任一子 check 为 UP 时探针假阳性。故 Task 4 必须用顶层键锚定模式（顶层键 4 空格缩进，子 check 12 空格）：`grep -q '^    "status"[[:space:]]*:[[:space:]]*"UP"'`。

- [ ] **Step 4: 原样试跑完整探针命令（grep 变体）**（结论 A：grep 变体可用——原样命令输出 `PROBE_OK`、exit 0；负向探测未监听端口 9001 时正确 exit 1（仅覆盖连接失败分支；status 非 UP 分支的假阳性由 Task 4 锚定模式消除）。结论 B 不适用）

```bash
docker exec kc-probe bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000 && printf "GET /health/ready HTTP/1.0\r\n\r\n" >&3 && grep -q "\"status\"[[:space:]]*:[[:space:]]*\"UP\"" <&3 && echo PROBE_OK'
```

Expected: `PROBE_OK`（退出码 0）。
**结论 A（grep 变体）**：若本步通过 → Task 4 用 grep 变体。
**结论 B（read/case 变体）**：仅当 Step 3 显示 grep 不存在时，改用并实测：

```bash
docker exec kc-probe bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000 && printf "GET /health/ready HTTP/1.0\r\n\r\n" >&3 && while read -t 5 -u 3 line; do case "$line" in *"status":"UP"*) exit 0;; esac; done; exit 1' && echo PROBE_OK_CASE
```

- [ ] **Step 5: 清理临时容器**

```bash
docker rm -f kc-probe
```

Expected: 输出 kc-probe。

- [ ] **Step 6: 实测 quay 镜像代理（Task 3 的 quay 行依据）**（结论 C：quay.m.daocloud.io 拉取成功——`Status: Downloaded newer image`，Digest `sha256:dfd3941bf6ced5fdb700f9b2d98b22b7bca7ceee13aec16224f93ff30d9a59c4`，耗时约 1.5s，无需重试；结论 D 不适用，Task 3 保留 `"quay.io quay.m.daocloud.io"` 行）

```bash
docker pull quay.m.daocloud.io/coreos/etcd:v3.6.14
```

Expected: `Status: Downloaded newer image`。
**结论 C（quay 代理可用）**：Task 3 保留 `"quay.io quay.m.daocloud.io"` 行。
**结论 D（不可用）**：删除该行并在数组上方注释记录「quay 无可用代理，直连兜底」。
（留镜像不删，无副作用；真实 `quay.io/...` 引用由 preflight 按需拉取。）

- [ ] **Step 7: 将结论 A/B/C/D 记录进本计划文件对应 checkbox 行，然后提交**

```bash
git add docs/superpowers/plans/2026-09-10-config-audit-fixes.md
git commit -m "docs(plan): 记录实证结论（Keycloak 探针变体 / quay 代理可用性）"
```

---

### Task 2: Kafka 双 listener（P1-1）

**Files:**
- Modify: `common/env/kafka.env`（整文件重写）
- Modify: `portal/conf/stream-conf.d/kafka.conf`（整文件重写）
- Modify: `docker-compose-portal.yml`（ports 追加 1 行 + kafka 9092 行注释微调 + 顶部注释计数）
- Modify: `portal/conf/nginx.conf:46`（stream 转发计数注释）

- [ ] **Step 1: 重写 `common/env/kafka.env` 为以下完整内容**

```properties
KAFKA_NODE_ID=1
KAFKA_PROCESS_ROLES=broker,controller
# 双 listener：PLAINTEXT 供容器网内（advertised 裸名 kafka）；EXTERNAL 供宿主/局域网客户端
# 经 nginx（portal）stream 29092 透传接入。EXTERNAL advertised 为部署特定值：
# 本机 Docker Desktop 保持 127.0.0.1（客户端用 localhost:29092）；
# NAS 局域网其他机器接入时改成 NAS IP 后重建：docker compose -f docker-compose-infra.yml up -d kafka
KAFKA_LISTENERS=PLAINTEXT://:9092,EXTERNAL://:29092,CONTROLLER://:9093
KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092,EXTERNAL://127.0.0.1:29092
KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT
KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka:9093
KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1
KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1
KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1
KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0
KAFKA_NUM_PARTITIONS=3
```

- [ ] **Step 2: 重写 `portal/conf/stream-conf.d/kafka.conf` 为以下完整内容**

```nginx
# stream：Kafka 双 listener 透传——9092 供容器网内（PLAINTEXT，advertised 裸名 kafka），
# 29092 供宿主/局域网（EXTERNAL，advertised 127.0.0.1 或部署 IP，见 common/env/kafka.env）
server { listen 9092;  proxy_pass kafka:9092; }
server { listen 29092; proxy_pass kafka:29092; }
```

- [ ] **Step 3: `docker-compose-portal.yml` ports 区改 kafka 两行**

将：

```yaml
      - "9092:9092"    # stream → kafka
```

改为：

```yaml
      - "9092:9092"    # stream → kafka PLAINTEXT（容器网内，advertised 裸名）
      - "29092:29092"  # stream → kafka EXTERNAL（宿主/局域网客户端入口，advertised 见 common/env/kafka.env）
```

- [ ] **Step 4: 更新两处计数注释**

`docker-compose-portal.yml:12`（18→21 server 块为 Task 5 完成后的终态，此处先按含 catchall 终态写，避免二次改动）：

将：

```yaml
    # 统一入口：http 虚拟主机（监听端口 = 容器原生端口，18 个 server 块）+ stream TCP 透明转发（15 条原生端口）。
```

改为：

```yaml
    # 统一入口：http 虚拟主机（监听端口 = 容器原生端口，21 个 server 块，含共享端口 default_server 兜底）+ stream TCP 透明转发（16 条原生端口）。
```

`portal/conf/nginx.conf:46`：

将：

```nginx
    # 每容器一个配置文件（15 条转发：rabbitmq 3 条、openldap/nacos/elk 各 2 条同文件）
```

改为：

```nginx
    # 每容器一个配置文件（16 条转发：rabbitmq 3 条，openldap/nacos/kafka 各 2 条同文件，其余 1 条）
```

- [ ] **Step 5: 静态验证（双路径渲染 + 端口提取）**

```bash
docker compose -f docker-compose-infra.yml config -q && echo INFRA_OK
env -u DOCKER_VOLUME -u REDIS_PASSWORD docker compose -f docker-compose-portal.yml config -q && echo PORTAL_OK
grep -n "29092" docker-compose-portal.yml portal/conf/stream-conf.d/kafka.conf
```

Expected: `INFRA_OK`、`PORTAL_OK`（零告警）；grep 命中 4 行（portal yml 2 行 + kafka.conf 2 行）。
注：kafka 的 EXTERNAL advertised 是字面值（不参与 compose 插值），env_file 不做变量替换的既有坑在此不适用。

- [ ] **Step 6: Commit**

```bash
git add common/env/kafka.env portal/conf/stream-conf.d/kafka.conf docker-compose-portal.yml portal/conf/nginx.conf
git commit -m "feat(kafka): EXTERNAL listener 29092 经 nginx stream 暴露宿主/局域网客户端（双 listener，advertised 见 kafka.env）"
```

---

### Task 3: preflight 加固与日志轮转自愈（P1-2 / P1-3 / P2-5 / P3-10）

**Files:**
- Modify: `common/preflight.sh`（头注释、镜像代理常量与函数、.env 权限、端口预检双平台、新增日志轮转步骤、run_preflight、步骤编号 1/6→1/7 全量）

- [ ] **Step 1: 头注释（1-18 行）替换为以下内容**

```bash
#!/bin/bash
# 部署前置自愈与预检（由 startup.sh source 引入；全部幂等，已满足条件的项直接跳过）：
# 1. fix_dir_permissions   Linux 上修复部署/数据目录权限位（NAS 网页上传易出现 000，root 可操作
#                          但容器内非 root uid 读 bind mount 会 Permission denied）。
#                          特别保护 rabbitmq 的 .erlang.cookie（erlang 强制要求 600 且属主为容器
#                          内 rabbitmq uid=999，宽权限会导致 BOOT FAILED）。
#                          并把 .env 收紧为 600（含全部组件凭据，不得因 go+rX 递归放权泄露）。
# 2. ensure_env_file       .env 缺失时从 .env.example 生成并立即 chmod 600（本步在 1 之后执行）。
# 3. ensure_max_map_count  Linux 上保证 vm.max_map_count ≥ 262144（Elasticsearch bootstrap 硬性
#                          要求，fnOS/Debian 默认 65530），过低则 sysctl -w 并持久化 /etc/sysctl.conf。
# 4. clean_orphan_bridges  删除孤儿 docker 网桥（接口 br-<id> 存在但对应 network 已被删除）：
#                          残留的同网段直连路由会抢走在用网络的流量，导致发布端口宿主/外部均不通
#                          （特征：容器间互访正常，宿主本机与外部访问全部超时）。
# 5. pull_registry_images  ghcr.io / quay.io 镜像本地缺失时，先经国内镜像代理拉取再 retag 回原名
#                          （直连在部分网络环境稳定超时）；镜像已在本地则跳过。
# 6. check_published_ports 预检 portal 发布端口：被宿主服务（Linux: 非 docker-proxy；macOS: 非
#                          docker 自身监听）占用时提前报错，避免 nginx up 失败后才暴露。
# 7. ensure_docker_log_rotation Linux 上幂等写入 /etc/docker/daemon.json 默认日志轮转
#                          （json-file 50m × 3），防长期运行 NAS 磁盘被 docker 日志吃满。
# 平台约定：1/3/4/7 仅 Linux 执行（macOS Docker Desktop 的 bind mount 权限由 VM 侧处理，
# 且无 sysctl/ip/ss 等命令，daemon.json 走 GUI 配置）；2/5 跨平台；6 跨平台（macOS 用 lsof）。
```

- [ ] **Step 2: 镜像代理常量（20-24 行）替换为**

```bash
# 镜像代理清单：每行 "<registry> <mirror1> <mirror2> ..."，按序尝试命中即止；
# 全部失败兜底直连。均以 <mirror>/<owner>/<repo> 前缀形式代理。
# quay 行可用性依据 2026-09-10 实测（Task 1 结论 C/D）。
PREFLIGHT_REGISTRY_MIRRORS=(
  "ghcr.io ghcr.m.daocloud.io ghcr.nju.edu.cn"
  "quay.io quay.m.daocloud.io"
)

# Elasticsearch bootstrap 对 max_map_count 的最低要求
PREFLIGHT_MAX_MAP_COUNT=262144

# daemon.json 默认日志轮转参数
PREFLIGHT_LOG_MAX_SIZE=50m
PREFLIGHT_LOG_MAX_FILE=3
```

（若 Task 1 结论 D：删除 `"quay.io ..."` 行，并在注释处补一行 `# quay 无可用代理（实测），走直连兜底`。）

- [ ] **Step 3: `fix_dir_permissions` 整函数替换为**

```bash
fix_dir_permissions() {
  preflight_on_linux || return 0
  echo "Preflight 1/7: fixing permissions..."
  chmod -R u+rwX,go+rX "$SCRIPT_DIR" 2>/dev/null || echo "WARN: chmod -R $SCRIPT_DIR failed (need root?), continuing..."
  # .env 含全部组件凭据，不得因上面的 go+rX 递归放权被同机用户读取
  # 用 if 而非 [ ] && cmd || echo：.env 不存在时后者会误报 chmod 失败，且 set -e 下短路链不可靠
  if [ -f "$SCRIPT_DIR/.env" ]; then
    chmod 600 "$SCRIPT_DIR/.env" 2>/dev/null || echo "WARN: chmod 600 $SCRIPT_DIR/.env failed, continuing..."
  fi
  if [ -d "$DOCKER_VOLUME" ]; then
    chmod u+rwX,go+rX "$DOCKER_VOLUME" 2>/dev/null || echo "WARN: chmod $DOCKER_VOLUME failed, continuing..."
    local cookie="$DOCKER_VOLUME/rabbitmq/data/.erlang.cookie"
    if [ -f "$cookie" ]; then
      chown 999:999 "$cookie" 2>/dev/null || true
      chmod 600 "$cookie" 2>/dev/null || echo "WARN: chmod 600 $cookie failed, rabbitmq may fail to boot"
    fi
  fi
}
```

- [ ] **Step 4: `ensure_env_file` 整函数替换为**

```bash
# 2) .env 保障（compose 插值读取项目目录 .env；启动参数 DOCKER_VOLUME 已 export，优先级更高）
ensure_env_file() {
  if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Preflight 2/7: .env not found, generating from .env.example..."
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" || { echo "Error: failed to create $SCRIPT_DIR/.env"; exit 1; }
    # 本步在 fix_dir_permissions 之后执行，新生 .env（默认 644）需立即收紧
    chmod 600 "$SCRIPT_DIR/.env" 2>/dev/null || echo "WARN: chmod 600 $SCRIPT_DIR/.env failed, continuing..."
    echo "WARN: review $SCRIPT_DIR/.env and common/env/*.env for default credentials before production use."
  fi
}
```

- [ ] **Step 5: `ensure_max_map_count` 与 `clean_orphan_bridges` 仅改编号**

将 `echo "Preflight 3/6: ...` 改为 `echo "Preflight 3/7: ...`；
将 `echo "Preflight 4/6: ...` 改为 `echo "Preflight 4/7: ...`。
（两处均为单个 echo 行，函数其余内容不动。）

- [ ] **Step 6: `pull_ghcr_images` 整函数及其上注释（79-99 行）替换为**

```bash
# 5) ghcr.io / quay.io 镜像预拉取：从全部 compose 文件提取镜像引用，本地缺失时按
#    PREFLIGHT_REGISTRY_MIRRORS 逐代理尝试，全部失败兜底直连
pull_registry_images() {
  local img entry registry mirror mirror_img pulled
  for img in $(grep -hoE "image:[[:space:]]*(ghcr\.io|quay\.io)/[A-Za-z0-9_./:-]+" "$SCRIPT_DIR"/docker-compose-*.yml 2>/dev/null | awk '{print $2}' | sort -u); do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    echo "Preflight 5/7: $img missing locally, pulling via mirror..."
    pulled=""
    for entry in "${PREFLIGHT_REGISTRY_MIRRORS[@]}"; do
      registry=${entry%% *}
      case "$img" in "$registry"/*) ;; *) continue ;; esac
      for mirror in ${entry#* }; do
        mirror_img="$mirror/${img#*/}"
        if docker pull "$mirror_img" && docker tag "$mirror_img" "$img"; then
          echo "Pulled $img via $mirror"
          pulled=1
          break
        fi
      done
      if [ -n "$pulled" ]; then break; fi
    done
    if [ -z "$pulled" ]; then
      echo "All mirrors failed for $img, trying direct pull..."
      docker pull "$img" || { echo "Error: unable to pull $img (mirrors and direct pull all failed)"; exit 1; }
    fi
  done
}
```

- [ ] **Step 7: `check_published_ports` 整函数及其上注释（101-117 行）替换为**

```bash
# 6) portal 发布端口预检：提取宿主端口，检查占用者；docker 自身监听属正常（幂等重启场景）。
#    Linux 用 ss（占用者进程名 docker-proxy），macOS 用 lsof（com.docker.backend），语义一致。
check_published_ports() {
  local port occupier issues=0
  for port in $(grep -oE '"[0-9]+:[0-9]+"' "$SCRIPT_DIR/docker-compose-portal.yml" 2>/dev/null | cut -d'"' -f2 | cut -d: -f1 | sort -un); do
    if preflight_on_linux; then
      occupier=$(ss -tlnp 2>/dev/null | grep -E "[:.]$port[[:space:]]" | grep -oE '\(\("[a-zA-Z0-9_-]+"' | head -1 | tr -d '("')
      if [ -z "$occupier" ] || [ "$occupier" = "docker-proxy" ]; then continue; fi
    else
      if ! lsof +c0 -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then continue; fi
      # +c0 避免进程名截断（否则 com.docke… 匹配不上）；过滤 docker 自身监听
      occupier=$(lsof +c0 -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1}' | sort -u | grep -iv docker | head -1)
      if [ -z "$occupier" ]; then continue; fi
    fi
    echo "Error: host port $port is occupied by '$occupier' (nginx portal will fail to bind)."
    echo "Hint: stop the conflicting host service, or remap the host-side port in docker-compose-portal.yml."
    issues=1
  done
  if [ "$issues" -ne 0 ]; then exit 1; fi
}
```

- [ ] **Step 8: 在 `check_published_ports` 之后、`run_preflight` 之前新增函数**

```bash
# 7) Docker 日志轮转：daemon.json 缺失时写入默认策略（json-file 50m × 3）；已存在但缺键时
#    只提示不代改（shell 手改 JSON 易损坏）；已配置则跳过。对宿主上全部容器生效，
#    且仅影响之后新建的容器（存量容器需重建才应用）。macOS 走 Docker Desktop GUI 配置。
ensure_docker_log_rotation() {
  preflight_on_linux || return 0
  local daemon_conf=/etc/docker/daemon.json
  if [ -f "$daemon_conf" ]; then
    if grep -q '"log-driver"' "$daemon_conf" && grep -q '"log-opts"' "$daemon_conf"; then
      return 0
    fi
    echo "Preflight 7/7: $daemon_conf exists but lacks log-driver/log-opts; merge manually, e.g.:"
    echo "  \"log-driver\": \"json-file\", \"log-opts\": { \"max-size\": \"$PREFLIGHT_LOG_MAX_SIZE\", \"max-file\": \"$PREFLIGHT_LOG_MAX_FILE\" }"
    return 0
  fi
  echo "Preflight 7/7: writing default log rotation to $daemon_conf ..."
  mkdir -p /etc/docker 2>/dev/null || { echo "WARN: cannot create /etc/docker, skipping log rotation setup"; return 0; }
  if ! printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "%s", "max-file": "%s" }\n}\n' \
       "$PREFLIGHT_LOG_MAX_SIZE" "$PREFLIGHT_LOG_MAX_FILE" > "$daemon_conf" 2>/dev/null; then
    echo "WARN: failed to write $daemon_conf (need root?), skipping"
    return 0
  fi
  echo "Log rotation written; reloading docker (applies to containers created afterwards)..."
  systemctl reload docker 2>/dev/null || echo "WARN: systemctl reload docker failed; restart docker to apply"
}
```

- [ ] **Step 9: `run_preflight` 整函数替换为**

```bash
run_preflight() {
  echo "-------------------------------------------"
  echo "Preflight: permissions / env / sysctl / bridges / registry images / ports / log rotation"
  echo "-------------------------------------------"
  fix_dir_permissions
  ensure_env_file
  ensure_max_map_count
  clean_orphan_bridges
  pull_registry_images
  check_published_ports
  ensure_docker_log_rotation
  echo "Preflight passed."
}
```

- [ ] **Step 10: 语法与行为验证**

```bash
bash -n common/preflight.sh && echo SYNTAX_OK
# 镜像提取流水线（ghcr 2 个 + quay 1 个，tag 不丢——既往冒号坑回归）
grep -hoE "image:[[:space:]]*(ghcr\.io|quay\.io)/[A-Za-z0-9_./:-]+" docker-compose-*.yml | awk '{print $2}' | sort -u
# pull 流程单测（mock docker；验证 registry 分派与 mirror_img 推导，不产生真实拉取）
bash -c '
  SCRIPT_DIR='"$PWD"';
  source '"$PWD"'/common/preflight.sh;
  docker() {
    case "$1 $2" in
      "image inspect") return 1 ;;
      pull) return 0 ;;
      tag) return 0 ;;
      *) return 0 ;;
    esac
  }
  pull_registry_images
' | grep -E "Pulled|missing"
```

Expected: `SYNTAX_OK`；提取流水线输出 3 行（`ghcr.io/moontechlab/lunatv:v100.1.3`、`ghcr.io/open-webui/open-webui:v0.11.3`、`quay.io/coreos/etcd:v3.6.14`）；mock 测试输出含 `missing locally` 与 3 行 `Pulled <原名> via <镜像>`（ghcr 走 daocloud 命中即止，quay 走其配置行）。

```bash
# macOS 平台行为：Linux-only 函数静默跳过、返回 0
bash -c 'source '"$PWD"'/common/preflight.sh; ensure_docker_log_rotation; echo "ROTATION_EXIT=$?"'
```

Expected: 无 Preflight 7/7 输出（macOS 提前 return），`ROTATION_EXIT=0`。

```bash
# .env 权限行为（macOS 用函数注入模拟 Linux 分支；.env 由 .env.example 生成，保留在原地供后续使用）
cp .env.example .env && chmod 644 .env
bash -c '
  SCRIPT_DIR='"$PWD"'; DOCKER_VOLUME=/tmp/glseven-preflight-test;
  source '"$PWD"'/common/preflight.sh;
  preflight_on_linux() { true; };
  fix_dir_permissions >/dev/null 2>&1;
  stat -f "%Lp" '"$PWD"'/.env
'
```

Expected: `600`。若输出非 600，检查 chmod 行与函数注入顺序，不得进入 Task 4。

- [ ] **Step 11: Commit**

```bash
git add common/preflight.sh
git commit -m "feat(preflight): .env 600 收紧；双 registry 镜像代理（ghcr/quay）；macOS lsof 端口预检；daemon.json 日志轮转自愈"
```

---

### Task 4: Keycloak 探针升级 HTTP 级（P2-4）

**Files:**
- Modify: `docker-compose-security.yml:75-80`（keycloak healthcheck；实际变更落点 75-80，注释扩为 4 行）

- [ ] **Step 1: 按任务 1 结论替换 healthcheck**

将：

```yaml
    healthcheck:
      # 镜像内无 curl/wget（Task 1 实测），改用 bash /dev/tcp 对 9000 管理端口做 TCP 存活探测。
      # 9000 管理端口由 KC_HEALTH_ENABLED/KC_METRICS_ENABLED 开启；探针工具按 Task 1 验证结果。
      test: [ "CMD-SHELL", "bash -c '</dev/tcp/127.0.0.1/9000' || exit 1" ]
```

改为（结论 A：grep 存在；`\\r\\n` 为 YAML 双引号转义，到 shell 是字面 `\r\n`，由 printf 解释成 CRLF；grep 模式用 `^    "status"` 锚定顶层键——Task 1 实测顶层 status 键 4 空格缩进、子 check 12 空格，非锚定模式在顶层 DOWN 而子 check UP 时会假阳性，代码审查已复现）：

```yaml
    healthcheck:
      # 镜像内无 curl/wget，用 bash /dev/tcp 对 9000 管理端口发 HTTP 请求探测 /health/ready
      # （端口监听 ≠ 就绪；顶层 status UP 判定即既往验证标准）。9000 由 KC_HEALTH_ENABLED/KC_METRICS_ENABLED 开启。
      # grep 锚定顶层键（^ + 恰 4 空格缩进，Task 1 实测顶层 4 空格/子 check 12 空格），
      # 避免命中子 check 的 "status": "UP" 行——顶层 DOWN 而子 check UP 时非锚定模式会假阳性（审查已复现）。
      test: [ "CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/9000 && printf 'GET /health/ready HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q '^    \"status\"[[:space:]]*:[[:space:]]*\"UP\"' <&3" ]
```

（仅当 Task 1 结论 B 时改用：`test: [ "CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/9000 && printf 'GET /health/ready HTTP/1.0\\r\\n\\r\\n' >&3 && while read -t 5 -u 3 line; do case "$line" in '    "status"'*'"UP"'*) exit 0;; esac; done; exit 1" ]`——case 模式同样须锚定顶层键：模式以 4 个空格 + `"status"` 开头（顶层行形态），子 check 行以 12 空格开头不会命中；按 Task 1 记录的真实 JSON 格式校准。）

> **2026-09-10 实现注记（Task 4 质量审查）**：上块 test 行的 grep 模式草案存在过量转义（引号前双反斜杠，YAML 双引号标量解析后 shell 层残留反斜杠+引号，GNU grep 恰按字面引号处理，属未定义转义依赖）；实现按本节说明文字（shell 层 ^ 后恰 4 空格 + 纯净引号锚定）采用 YAML 标准转义（引号前单反斜杠），以渲染断言（config --format json 语义）与活体探针（正向 exit 0 / 负向 exit 1 / 合成顶层 DOWN+子 check UP 不假阳性）双重验证为准。

- [ ] **Step 2: 渲染验证探针字符串**

```bash
docker compose -f docker-compose-security.yml config | grep -A2 "test:"
```

Expected: 渲染出的 test 字符串含字面 `GET /health/ready HTTP/1.0\r\n\r\n`（printf 参数内为字面反斜杠序列）与锚定模式 `^    \"status\"[[:space:]]*:[[:space:]]*\"UP\"`（^ 后恰 4 个空格），且无 compose 插值告警。

- [ ] **Step 3: Commit**

```bash
git add docker-compose-security.yml
git commit -m "fix(keycloak): healthcheck 升级 HTTP 级 /health/ready 探测（TCP 存活≠就绪，对齐既往假变量教训的验证标准）"
```

---

### Task 5: nginx 共享端口 default_server 兜底（P2-6）

**Files:**
- Create: `portal/conf/conf.d/00-default-catchall.conf`

- [ ] **Step 1: 新建文件，内容如下**

```nginx
# 共享端口 IP 直连兜底：未带二级域名时统一 302 到门户，避免按文件 include 序
# 误入 adminer(8080) / grafana(3000) / mongo-express(8081)。
# 仅覆盖多 vhost 共享端口；独占端口 IP 直连本就命中唯一 server，无需处理。
server { listen 3000 default_server; server_name _; return 302 http://glseven.local:8000/; }
server { listen 8080 default_server; server_name _; return 302 http://glseven.local:8000/; }
server { listen 8081 default_server; server_name _; return 302 http://glseven.local:8000/; }
```

- [ ] **Step 2: 单文件独立语法验证（裸跑 nginx -t 会因其他 vhost 的 upstream 域名解析失败，故只挂本文件）**

```bash
docker run --rm -v "$PWD/portal/conf/conf.d/00-default-catchall.conf:/etc/nginx/conf.d/default.conf:ro" \
  nginx:1.30.4 nginx -t 2>&1 | tail -1
```

Expected: `syntax is ok` 与 `test is successful`。若报 default_server 重复，说明既有 vhost 已标 default_server（当前审计确认没有），需回到设计。

- [ ] **Step 3: Commit**

```bash
git add portal/conf/conf.d/00-default-catchall.conf
git commit -m "feat(portal): 共享端口(3000/8080/8081) IP 直连 default_server 302 兜底至门户"
```

---

### Task 6: P3 杂项（kibana 注释 + dashboards .gitkeep）

**Files:**
- Modify: `elk/kibana/config/kibana.yml:2`
- Create: `grafana/conf/dashboards/.gitkeep`

- [ ] **Step 1: kibana.yml 注释版本更正**

将：

```yaml
# Reference: https://www.elastic.co/guide/en/kibana/9.3/settings.html
```

改为：

```yaml
# Reference: https://www.elastic.co/guide/en/kibana/9.5/settings.html
```

- [ ] **Step 2: 创建 .gitkeep 使目录入 git（provisioning provider 指向更直观，挂载目录不再由 Docker 隐式创建）**

```bash
mkdir -p grafana/conf/dashboards && touch grafana/conf/dashboards/.gitkeep
```

- [ ] **Step 3: Commit**

```bash
git add elk/kibana/config/kibana.yml grafana/conf/dashboards/.gitkeep
git commit -m "chore: kibana.yml 注释版本 9.3→9.5；dashboards 目录以 .gitkeep 入 git"
```

---

### Task 7: README 同步

**Files:**
- Modify: `README.md`（51 行计数、74-75 行 Kafka 段、77 行容器网内清单、新增 Kafka 双 listener 小节、新增运维段落）

- [ ] **Step 1: 51 行端口计数与兜底说明**

将：

```markdown
**nginx（portal）是唯一持有宿主端口的容器**（26 个端口：8000 门户 + 10 个原生 http 监听 + 15 条 stream），其余 22 个服务零宿主端口；二级域名 = 容器名，URL 端口 = 容器原生端口，需先完成 /etc/hosts 初始化。
```

改为：

```markdown
**nginx（portal）是唯一持有宿主端口的容器**（27 个端口：8000 门户 + 10 个原生 http 监听 + 16 条 stream），其余 22 个服务零宿主端口；二级域名 = 容器名，URL 端口 = 容器原生端口，需先完成 /etc/hosts 初始化。IP 直连共享端口（3000/8080/8081）由 default_server 统一 302 到门户。
```

- [ ] **Step 2: 75 行协议端口清单 Kafka 段重写**

将：

```markdown
mysql 3306、redis 6379、mongo 27017、AMQP 5672（由 35672 回归默认）、MQTT 1883、MQTT-WS 15675、kafka 9092（宿主 Kafka 客户端需另加 hosts 条目 `127.0.0.1 kafka`——引导后元数据指向裸名 `kafka:9092`；或仅在容器网络内使用）、etcd 2379、ldap 389/636、nacos 8848/9848、ollama 11434、beats 5044、registry 5000。
```

改为：

```markdown
mysql 3306、redis 6379、mongo 27017、AMQP 5672（由 35672 回归默认）、MQTT 1883、MQTT-WS 15675、kafka 29092（宿主/局域网客户端入口，双 listener 见下方「Kafka 双 listener」）、etcd 2379、ldap 389/636、nacos 8848/9848、ollama 11434、beats 5044、registry 5000。
```

- [ ] **Step 3: 77 行容器网内清单补充**

将：

```markdown
仅容器网络内（未代理）：keycloak 管理端口 9000、apisix prometheus 指标 9091、etcd peer 2380。
```

改为：

```markdown
仅容器网络内（未代理）：keycloak 管理端口 9000、apisix prometheus 指标 9091、etcd peer 2380。kafka PLAINTEXT 9092 虽经 stream 透传宿主，但 advertised 裸名 `kafka:9092` 宿主不可解析，协议层对宿主不可用，Kafka 客户端一律走 29092（见下方「Kafka 双 listener」）。
```

- [ ] **Step 4: 「关键服务要点」APISIX 小节后新增 Kafka 小节**

在 `### APISIX 3.18.0` 小节（97 行 `- 配置存储为 infra 域的 etcd...` 行）之后、`## 存量环境迁移` 之前插入：

```markdown
### Kafka 双 listener（4.3.1）

- 容器网络内：`PLAINTEXT://kafka:9092`（advertised 裸名），微服务客户端 bootstrap 地址写 `kafka:9092`。
- 宿主/局域网：`EXTERNAL://:29092`，经 nginx stream 透传；advertised 地址在 `common/env/kafka.env`（默认 `127.0.0.1:29092`，本机 Docker Desktop 客户端直接用 `localhost:29092`）。
- NAS 局域网其他机器接入：把 `common/env/kafka.env` 中 EXTERNAL advertised 的 `127.0.0.1` 改成 NAS IP，然后 `docker compose -f docker-compose-infra.yml up -d kafka` 重建。
- 9092 的 nginx stream 透传为存量兼容保留：旧 hosts 接入路径仍可用（PLAINTEXT advertised 仍为裸名），容器网络内客户端直连 `kafka:9092`（Docker DNS，不经 nginx）——但新接入一律走 29092，hosts 路径勿再新增依赖。
- 旧「hosts 条目 `127.0.0.1 kafka`」workaround 已废弃，勿再使用。
```

- [ ] **Step 5: 「配置约定」小节后新增运维段落**

在 83 行 `- **监控接入**...` 行之后、`## 关键服务要点` 之前插入：

```markdown
## 容器日志轮转与 etcd 风险边界

- **日志轮转**（Linux 宿主）：preflight 第 7 步幂等写入 `/etc/docker/daemon.json`（`json-file`、max-size 50m、max-file 3；仅当文件不存在时写入，已存在但缺 `log-driver`/`log-opts` 时打印手工合并提示）。daemon 级配置对宿主上全部容器生效，且仅影响之后新建的容器（存量容器需重建才应用）。macOS Docker Desktop 在 Settings → Docker Engine 手工加同样的键。
- **etcd 无认证风险**：etcd 默认无认证且 2379 已透传宿主——宿主上任何进程可读写并改写 APISIX 路由。这是开发环境全量代理的明示决策（见 `docs/superpowers/specs/2026-09-09-nginx-unified-entry-design.md` §4.3）；不要在生产网络复用本编排的 etcd 暴露方式。
```

- [ ] **Step 6: 一致性核对**

```bash
grep -n "26 个端口\|15 条 stream\|9092（宿主 Kafka 客户端需另加\|127.0.0.1 kafka" README.md
```

Expected: 仅允许 1 处命中——Step 4 插入的「旧『hosts 条目 `127.0.0.1 kafka`』workaround 已废弃」声明行本身含字面 `127.0.0.1 kafka`（Step 4 与本 grep 的内在矛盾，2026-09-10 裁定：声明行是预期产物、非旧表述残留；其余 `26 个端口`/`15 条 stream`/`9092（宿主 Kafka 客户端需另加` 三类旧表述须 0 命中）；`grep -c "29092" README.md` ≥ 3。

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "docs(readme): 端口 27；Kafka 双 listener 接入与 hosts workaround 废弃；日志轮转；etcd 风险标注"
```

> **2026-09-10 修正注记（Task 7 质量审查，With fixes → 已修）**：Step 3/4/5 的「改为」块按审查修正——9092 实为 16 条 stream 之一（kafka.conf:3 + portal.yml 发布 9092），原「仅容器网络内（未代理）」归类失实，移出该清单并改述为「经 stream 透传但协议层对宿主不可用」；Kafka 小节统一「容器网络内」术语并补 9092 存量兼容保留说明；etcd 规格引用路径化。Step 6 不变量不变（旧三类表述 0 命中、`127.0.0.1 kafka` 恰 1 命中=废弃声明行、29092 ≥3）。配置侧（kafka.conf/portal.yml）注释修正移交 Task 8 回改项 4。

---

### Task 8: 全栈端到端验证与幂等回归

**Files:** 无代码改动（验证任务；发现问题回改对应 Task 并重跑）。

> **Task 3 质量审查移交的回改项（进入 Step 1 前先落地，各自独立提交）：**
> 1.（Important）`common/preflight.sh` `ensure_docker_log_rotation` 的 daemon.json 写入改原子：先写 `"$daemon_conf.tmp"`，成功后 `mv` 原子覆盖，失败分支补 `rm -f "$daemon_conf.tmp"`——避免写一半失败留下截断/空 daemon.json 导致 dockerd 起不来（preflight.sh:163-164，计划 Step 8 继承的设计缺口）。commit：`fix(preflight): daemon.json 原子写入（tmp+mv，失败清理临时文件）`。
> 2.（Minor）`startup.sh:20` 注释的步骤清单同步七步版（…/ 孤儿网桥 / registry 镜像 / 端口占用 / 日志轮转）。commit：`docs(startup): 注释步骤清单同步 preflight 七步版`。
> 3.（可选加测）mock 负向用例（全部代理失败→直连失败→exit 1）与 macOS lsof 冲突/放行双分支用例——质量审查已人工补测通过，入库与否均可。
> 4.（Important，Task 7 质量审查）9092 透传注释修正：`portal/conf/stream-conf.d/kafka.conf` 头注释与 `docker-compose-portal.yml` 9092 行注释的「供容器网内」表述失实（nginx stream 9092 的实际服务面是宿主侧旧 hosts 路径；容器网络内客户端直连 kafka:9092 走 Docker DNS 不经 nginx）——改为「存量兼容透传：宿主旧 hosts 接入路径；容器网络内客户端直连 kafka:9092 不经 nginx」。commit：`docs(portal): 修正 kafka 9092 透传注释（存量兼容路径，容器网络内直连不经 nginx）`。
> （审查另列三个既有行为 Minor——ss 非 root 前提、端口提取正则形态约束、mirror 命名镜像残留本地——非本次引入，不回改，仅记录。）

- [ ] **Step 1: 全栈拉起（preflight 全流程首次实跑）**

```bash
bash startup.sh
```

Expected: preflight 七步全过（macOS 上 1/3/4/7 静默跳过、6 走 lsof 分支无误报）；BASE → MySQL healthy → DEFERRED → PORTAL；末尾「所有服务已启动！」。`docker ps -q | wc -l` = 23，且 `docker ps --filter status=restarting -q | wc -l` = 0。

- [ ] **Step 2: 等待全栈健康并确认 nginx 配置实机有效**

```bash
sleep 45
docker exec nginx nginx -t
docker ps --format '{{.Names}}\t{{.Status}}' | sort
```

Expected: `syntax is ok` + `test is successful`（裸跑 nginx -t 因 DNS 必失败，实机 exec 是唯一有效手段）；23 个容器无 restarting/unhealthy（portainer 无探针显示 Up 属预期；ollama 探针间隔 30s 需多等一轮）。

- [ ] **Step 3: Kafka 双 listener 端到端（两段拼合，宿主无需 kafka CLI）**

```bash
# 3a. 宿主侧 TCP 探测：nginx stream 29092 链路通
bash -c '</dev/tcp/127.0.0.1/29092' && echo HOST_STREAM_OK
# 3b. 容器内经 EXTERNAL listener 收发闭环（127.0.0.1 同时命中监听与 advertised，完整验证双 listener 语义）
docker exec kafka bash -c 'echo plan-e2e-msg | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server 127.0.0.1:29092 --topic plan-e2e'
docker exec kafka bash -c '/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server 127.0.0.1:29092 --topic plan-e2e --from-beginning --max-messages 1 --timeout-ms 15000 2>/dev/null'
# 3c. 容器网内 PLAINTEXT 不受影响（healthcheck 同路径）
docker inspect kafka --format '{{.State.Health.Status}}'
```

Expected: `HOST_STREAM_OK`；consumer 输出 `plan-e2e-msg`；kafka health = `healthy`。

- [ ] **Step 4: Keycloak 新探针语义验证（starting → healthy 才算通过）**

```bash
docker inspect keycloak --format '{{.State.Health.Status}}'
docker inspect keycloak --format '{{json .Config.Healthcheck.Test}}'
```

Expected: Status 为 `healthy`（新探针 UP 判定真实通过；若卡 `starting`/`unhealthy`，`docker inspect keycloak --format '{{json .State.Health}}'` 看失败次数并回查 Task 1/4）；Test 渲染含 `/health/ready` 与 grep 模式。

- [ ] **Step 5: default_server 兜底验证**

```bash
curl -sI http://127.0.0.1:8080/ | head -3
curl -sI -H "Host: adminer.glseven.local" http://127.0.0.1:8080/ | head -1
```

Expected: 第一条 `HTTP/1.1 302` + `Location: http://glseven.local:8000/`；第二条 `HTTP/1.1 200`（带域名的正常 vhost 不受影响）。

> **复验坑（Task 5 质量审查发现）**：若在临时容器组合挂载既有 vhost 复验，镜像默认 nginx.conf 缺 `map $http_upgrade $connection_upgrade`（仓库 nginx.conf:31-35），而 snippets/proxy.conf:12 引用该变量——只挂 vhost 文件会 `unknown "connection_upgrade" variable` emerg 退出，必须连仓库主配置一起挂。另两处可选润色（catchall 注释补 8000 约定提醒 / 新增共享端口维护提醒）已评审为不影响合并，暂不做。

- [ ] **Step 6: 日志轮转生效检查（平台差异注明）**

```bash
docker inspect nginx --format '{{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}'
```

Expected（Linux 宿主）: `json-file map[max-file:3 max-size:50m]`；macOS：daemon.json 步骤被跳过，输出为 Docker Desktop 默认值——记录实际值即可，注明 Linux 路径已在 preflight 落地、待 NAS 部署时生效。

- [ ] **Step 7: 栈运行态下 preflight 幂等复跑（macOS lsof 过滤 docker 监听的活体测试）**

```bash
bash -c 'SCRIPT_DIR='"$PWD"'; DOCKER_VOLUME=/docker/glseven; source '"$PWD"'/common/preflight.sh; run_preflight'
```

Expected: 各步骤幂等通过（镜像已存在跳过；26+1 个已发布端口全部被 docker 占用但无一误报），末尾 `Preflight passed.`。

- [ ] **Step 8: 幂等回归（两轮全量起停）**

```bash
bash shutdown.sh && bash startup.sh && docker ps -q | wc -l && docker ps --filter status=restarting -q | wc -l
```

Expected: shutdown 逆序全停 + 网络移除；startup 再次全过；`23`；`0`。

- [ ] **Step 9: 收尾报告**

向用户汇报：8 项验证结果、平台差异备注（macOS daemon.json 走 GUI、Linux/NAS 生效路径）、遗留观察项（如有）。若 Step 1-8 触发了任何回改，回改后重跑对应步骤并补提交。

> **2026-09-10 验证发现（Task 8 规格审查 + 活体补证）：**
> 1.（存量缺陷，非本次范围，未在本分支实施）kafka 数据不持久：`apache/kafka:4.3.1` KRaft 默认 `log.dirs=/tmp/kafka-logs`，仓库虽挂载 `${DOCKER_VOLUME}/kafka/data → /var/lib/kafka/data` 但未设 `KAFKA_LOG_DIRS`——数据实际写在容器可写层，`down` 周期即全丢（活体 `kafka-log-dirs.sh` 实证 `logDir=/tmp/kafka-logs` + 挂载点空 + drain 0 条旧消息）。修复方向：`kafka.env` 加 `KAFKA_LOG_DIRS=/var/lib/kafka/data` 并固定 `KAFKA_CLUSTER_ID`（否则重建后随机 ID 与已 format 存储不匹配）；另评 shutdown.sh infra 批次 `stop`/`-t 60`（现状为 `down`）。属独立后续任务。
> 2.（环境约束，与 6 项修复无因果——`git diff 5362eca..HEAD -- '*nexus*'` 为空）elk OOMKilled 循环（`-Xmx3968m + AlwaysPreTouch` ≈6G vs Docker Desktop VM 7.75GiB——heap 为 sebp/elk 镜像内 ES 自动 sizing 的运行态值，仓库未显式配置 ES_JAVA_OPTS）与 nexus3 被内存压力挤出循环（RestartCount 39/40 快照值）。NAS 部署按实际内存复验；macOS 长跑需调大 VM 内存或给 elk/nexus3 设 mem_limit/降配 heap。
> 3. 健康计数口径修正：瞬时快照表述（20 healthy + 2 starting + portainer Up 无探针），不作绝对化断言；Step 3 kafka e2e 已在终态栈活体重做闭环（`post-restart-msg` 生产/消费 EXIT=0），跨周期持久化断言归入后续任务 1。
> 4. macOS 上 startup.sh 需传参 DOCKER_VOLUME（如 `/Users/george/docker/glseven`，`/docker` 根只读），属平台使用方式（startup.sh:5-6 参数化设计明文）；macOS 零参数适配为独立后续项。

---

## 自审记录（Self-Review）

1. **规格覆盖**：§3.1→Task 2；§3.2→Task 3 Step 2/8/9；§3.3→Task 3 Step 1-7；§3.4→Task 4；§3.5→Task 5；§3.6→Task 6；§3.7→Task 7；§5 验证方案 1→Task 2/4 Step 静态检查、2→Task 1 Step 1-5、3→Task 1 Step 6、4→Task 8 Step 2、5→Task 8 Step 3、6→Task 8 Step 5、7→Task 8 Step 6、8→Task 8 Step 1/7/8。无缺口。
2. **占位符扫描**：无 TBD/TODO；Task 1 的 A/B、C/D 结论均有确定代码分支，非占位。
3. **一致性**：`pull_registry_images`/`ensure_docker_log_rotation`/`PREFLIGHT_REGISTRY_MIRRORS`/`PREFLIGHT_LOG_MAX_SIZE` 命名在 Step 2/6/8/9 间一致；编号 1/7~7/7 全量一致；portal 计数注释按含 Task 5 的终态 21 块/16 条书写，Task 5 落地后自洽。

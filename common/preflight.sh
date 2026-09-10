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

preflight_on_linux() { [ "$(uname -s)" = "Linux" ]; }

# 1) 目录权限：部署目录递归修复（代码文件体积小）；数据目录仅修顶层（深层目录由 startup.sh 的
#    mkdir/chown_dir 与容器自建生成，且数据目录可能很大不宜每次 -R 遍历）
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

# 3) vm.max_map_count（仅过低时修改；已达标则跳过，重复执行无害）
ensure_max_map_count() {
  preflight_on_linux || return 0
  local current
  current=$(cat /proc/sys/vm/max_map_count 2>/dev/null) || { echo "WARN: cannot read vm.max_map_count, skipping"; return 0; }
  if [ "$current" -lt "$PREFLIGHT_MAX_MAP_COUNT" ]; then
    echo "Preflight 3/7: vm.max_map_count=$current too low, setting to $PREFLIGHT_MAX_MAP_COUNT..."
    sysctl -w "vm.max_map_count=$PREFLIGHT_MAX_MAP_COUNT" || { echo "Error: failed to set vm.max_map_count (need root)"; exit 1; }
    grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null || echo "vm.max_map_count=$PREFLIGHT_MAX_MAP_COUNT" >> /etc/sysctl.conf
    echo "Persisted to /etc/sysctl.conf"
  fi
}

# 4) 孤儿网桥：接口名 br-<network_id 前 12 位>，network inspect 查不到即孤儿，删除以释放被抢占的路由
clean_orphan_bridges() {
  preflight_on_linux || return 0
  local iface netid
  for iface in $(ls /sys/class/net 2>/dev/null | grep '^br-'); do
    netid="${iface#br-}"
    if ! docker network inspect "$netid" >/dev/null 2>&1; then
      echo "Preflight 4/7: removing orphan bridge $iface (docker network $netid not found)..."
      ip link del "$iface" || echo "WARN: failed to remove $iface, continuing..."
    fi
  done
}

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
      # 边界：-iv docker 为子串放行，进程名含 docker 的无关占用会被误放行（lsof 行内空格进程名经 awk $1 亦有截断风险）——开发环境务实取舍，精确集合匹配留作后续
      occupier=$(lsof +c0 -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1}' | sort -u | grep -iv docker | head -1)
      if [ -z "$occupier" ]; then continue; fi
    fi
    echo "Error: host port $port is occupied by '$occupier' (nginx portal will fail to bind)."
    echo "Hint: stop the conflicting host service, or remap the host-side port in docker-compose-portal.yml."
    issues=1
  done
  if [ "$issues" -ne 0 ]; then exit 1; fi
}

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
       "$PREFLIGHT_LOG_MAX_SIZE" "$PREFLIGHT_LOG_MAX_FILE" > "$daemon_conf.tmp" 2>/dev/null; then
    rm -f "$daemon_conf.tmp"
    echo "WARN: failed to write $daemon_conf (need root?), skipping"
    return 0
  fi
  if ! mv "$daemon_conf.tmp" "$daemon_conf" 2>/dev/null; then
    rm -f "$daemon_conf.tmp"
    echo "WARN: failed to install $daemon_conf (mv failed), skipping"
    return 0
  fi
  echo "Log rotation written; reloading docker (applies to containers created afterwards)..."
  systemctl reload docker 2>/dev/null || echo "WARN: systemctl reload docker failed; restart docker to apply"
}

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

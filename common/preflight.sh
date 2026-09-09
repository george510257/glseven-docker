#!/bin/bash
# 部署前置自愈与预检（由 startup.sh source 引入；全部幂等，已满足条件的项直接跳过）：
# 1. fix_dir_permissions   Linux 上修复部署/数据目录权限位（NAS 网页上传易出现 000，root 可操作
#                          但容器内非 root uid 读 bind mount 会 Permission denied）。
#                          特别保护 rabbitmq 的 .erlang.cookie（erlang 强制要求 600 且属主为容器
#                          内 rabbitmq uid=999，宽权限会导致 BOOT FAILED）。
# 2. ensure_env_file       .env 缺失时从 .env.example 生成（生成后需人工复核默认凭据）。
# 3. ensure_max_map_count  Linux 上保证 vm.max_map_count ≥ 262144（Elasticsearch bootstrap 硬性
#                          要求，fnOS/Debian 默认 65530），过低则 sysctl -w 并持久化 /etc/sysctl.conf。
# 4. clean_orphan_bridges  删除孤儿 docker 网桥（接口 br-<id> 存在但对应 network 已被删除）：
#                          残留的同网段直连路由会抢走在用网络的流量，导致发布端口宿主/外部均不通
#                          （特征：容器间互访正常，宿主本机与外部访问全部超时）。
# 5. pull_ghcr_images      ghcr.io 镜像本地缺失时，先经国内镜像代理拉取再 retag 回原名（ghcr.io
#                          直连在部分网络环境稳定超时）；镜像已在本地则跳过。
# 6. check_published_ports 预检 portal 发布端口：被宿主服务（非 docker-proxy）占用时提前报错，
#                          避免 nginx up 失败后才暴露（如 NAS 自带 rabbitmq-server 占 5672）。
# 平台约定：1/3/4/6 仅 Linux 执行（macOS Docker Desktop 的 bind mount 权限由 VM 侧处理，
# 且无 sysctl/ip/ss 等命令）；2/5 跨平台。

# ghcr 镜像代理清单（按序尝试，命中即止；均以 <mirror>/<owner>/<repo> 前缀形式代理）
PREFLIGHT_GHCR_MIRRORS=(ghcr.m.daocloud.io ghcr.nju.edu.cn)

# Elasticsearch bootstrap 对 max_map_count 的最低要求
PREFLIGHT_MAX_MAP_COUNT=262144

preflight_on_linux() { [ "$(uname -s)" = "Linux" ]; }

# 1) 目录权限：部署目录递归修复（代码文件体积小）；数据目录仅修顶层（深层目录由 startup.sh 的
#    mkdir/chown_dir 与容器自建生成，且数据目录可能很大不宜每次 -R 遍历）
fix_dir_permissions() {
  preflight_on_linux || return 0
  echo "Preflight 1/6: fixing permissions..."
  chmod -R u+rwX,go+rX "$SCRIPT_DIR" 2>/dev/null || echo "WARN: chmod -R $SCRIPT_DIR failed (need root?), continuing..."
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
    echo "Preflight 2/6: .env not found, generating from .env.example..."
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" || { echo "Error: failed to create $SCRIPT_DIR/.env"; exit 1; }
    echo "WARN: review $SCRIPT_DIR/.env and common/env/*.env for default credentials before production use."
  fi
}

# 3) vm.max_map_count（仅过低时修改；已达标则跳过，重复执行无害）
ensure_max_map_count() {
  preflight_on_linux || return 0
  local current
  current=$(cat /proc/sys/vm/max_map_count 2>/dev/null) || { echo "WARN: cannot read vm.max_map_count, skipping"; return 0; }
  if [ "$current" -lt "$PREFLIGHT_MAX_MAP_COUNT" ]; then
    echo "Preflight 3/6: vm.max_map_count=$current too low, setting to $PREFLIGHT_MAX_MAP_COUNT..."
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
      echo "Preflight 4/6: removing orphan bridge $iface (docker network $netid not found)..."
      ip link del "$iface" || echo "WARN: failed to remove $iface, continuing..."
    fi
  done
}

# 5) ghcr.io 镜像预拉取：从全部 compose 文件提取 ghcr.io 镜像引用，本地缺失时走代理
pull_ghcr_images() {
  local img mirror mirror_img pulled
  for img in $(grep -hoE "image:[[:space:]]*ghcr\.io/[A-Za-z0-9_./:-]+" "$SCRIPT_DIR"/docker-compose-*.yml 2>/dev/null | awk '{print $2}' | sort -u); do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    echo "Preflight 5/6: $img missing locally, pulling via mirror..."
    pulled=""
    for mirror in "${PREFLIGHT_GHCR_MIRRORS[@]}"; do
      mirror_img="${img/ghcr.io\//$mirror/}"
      if docker pull "$mirror_img" && docker tag "$mirror_img" "$img"; then
        echo "Pulled $img via $mirror"
        pulled=1
        break
      fi
    done
    if [ -z "$pulled" ]; then
      echo "All mirrors failed for $img, trying direct pull..."
      docker pull "$img" || { echo "Error: unable to pull $img (mirrors and direct pull all failed)"; exit 1; }
    fi
  done
}

# 6) portal 发布端口预检：提取宿主端口，检查占用者；docker-proxy 占用属正常（幂等重启场景）
check_published_ports() {
  preflight_on_linux || return 0
  local port occupier issues=0
  for port in $(grep -oE '"[0-9]+:[0-9]+"' "$SCRIPT_DIR/docker-compose-portal.yml" 2>/dev/null | cut -d'"' -f2 | cut -d: -f1 | sort -un); do
    occupier=$(ss -tlnp 2>/dev/null | grep -E "[:.]$port[[:space:]]" | grep -oE '\(\("[a-zA-Z0-9_-]+"' | head -1 | tr -d '("')
    case "$occupier" in
      ""|docker-proxy) continue ;;
      *)
        echo "Error: host port $port is occupied by '$occupier' (nginx portal will fail to bind)."
        echo "Hint: stop the conflicting host service, or remap the host-side port in docker-compose-portal.yml."
        issues=1
        ;;
    esac
  done
  [ "$issues" -eq 0 ] || exit 1
}

run_preflight() {
  echo "-------------------------------------------"
  echo "Preflight: permissions / env / sysctl / bridges / ghcr images / ports"
  echo "-------------------------------------------"
  fix_dir_permissions
  ensure_env_file
  ensure_max_map_count
  clean_orphan_bridges
  pull_ghcr_images
  check_published_ports
  echo "Preflight passed."
}

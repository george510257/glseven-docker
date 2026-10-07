#!/bin/bash

set -e

# DOCKER_VOLUME 外部传入，默认值为 /docker/glseven
export DOCKER_VOLUME=${1:-/docker/glseven}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/compose-list.sh
source "$SCRIPT_DIR/common/compose-list.sh"
# shellcheck source=common/preflight.sh
source "$SCRIPT_DIR/common/preflight.sh"
cd "$SCRIPT_DIR"

echo "==========================================="
echo "启动 GLSeven Docker 容器..."
echo "DOCKER_VOLUME: $DOCKER_VOLUME"
echo "==========================================="

# 部署前置自愈与预检（幂等）：目录权限 / .env / vm.max_map_count / 孤儿网桥 / registry 镜像（ghcr+quay）/ 端口占用 / 日志轮转
run_preflight

# chown 仅在 Linux 宿主上有意义；macOS(Docker Desktop) 非 root 无法 chown，降级为警告（VirtioFS 由 VM 侧处理 uid 映射）
chown_dir() {
  local dir="$1" uid="$2"
  if ! chown -R "$uid" "$dir" 2>/dev/null; then
    echo "WARN: chown -R $uid $dir failed (non-root or unsupported platform), continuing..."
  fi
}

# 创建必要的目录并设置权限（目录创建失败仍致命）
# 表驱动：每条为 "<相对 DOCKER_VOLUME 的路径> <宿主属主 uid>"。新增非 root 容器时在此加一行即可，
# 无需改下面的创建/授权/恢复 mode 三段逻辑（原先散在四处硬编码，易漏，2026-09-21 审查后收敛）。
# 属主 uid 依据：nexus3=200、prometheus=65534(nobody)、grafana=472、elk/kafka=1000、phpldapadmin=82(www-data)。
# kafka 是 2026-09-21 修复「数据不落盘」时新增：设了 KAFKA_LOG_DIRS 后 compose 会预建
# /var/lib/kafka/data 挂载点，属主不是 1000(appuser) 则 broker 起不来。
DIR_SPECS=(
  "nexus3/data 200"
  "prometheus/data 65534"
  "grafana/data 472"
  "elk/data 1000"
  "kafka/data 1000"
  "phpldapadmin 82"
  "phpldapadmin/sessions 82"
  "phpldapadmin/logs 82"
)

echo "Creating directories..."
for spec in "${DIR_SPECS[@]}"; do
  dir="$DOCKER_VOLUME/${spec% *}"
  uid="${spec##* }"
  mkdir -p "$dir" || { echo "Error: Failed to create directory $dir"; exit 1; }
  chown_dir "$dir" "$uid"
done

# fnOS(trimacl) 等存储层会把新建目录权限位剥成 000（实测 mkdir/touch 均然；dockerd 代建的 bind 源
# 目录不受影响），非 root 容器（上述全部）随即 Permission denied 崩溃循环或 500；
# preflight 的数据目录修复跑在本块之前、fresh 卷场景恒空转，须在此显式恢复 mode（幂等）。
chmod 755 "$DOCKER_VOLUME" 2>/dev/null || echo "WARN: chmod 755 $DOCKER_VOLUME failed, continuing..."
for spec in "${DIR_SPECS[@]}"; do
  dir="$DOCKER_VOLUME/${spec% *}"
  chmod 755 "$dir" 2>/dev/null || echo "WARN: chmod 755 $dir failed, continuing..."
done

# 创建 Docker 网络（幂等，已存在则跳过）
if ! docker network inspect glseven &>/dev/null; then
  echo "Creating Docker network glseven..."
  docker network create --driver=bridge --subnet=172.18.0.0/16 glseven
else
  echo "Network glseven already exists, skipping."
fi

# 启动基础设施服务
echo "Starting base services..."
for group in "${COMPOSE_FILES_BASE[@]}"; do
  docker compose -f "docker-compose-${group}.yml" up -d || { echo "Error: ${group} services failed to start"; exit 1; }
  echo "✓ ${group} services started"
done

# 等待 MySQL 健康检查通过（keycloak / nacos / xxl-job-admin 依赖 MySQL 完成初始化）
echo "Waiting for MySQL to be healthy..."
MYSQL_WAIT_TIMEOUT=120
MYSQL_WAIT_COUNT=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' mysql 2>/dev/null)" = "healthy" ]; do
  MYSQL_WAIT_COUNT=$((MYSQL_WAIT_COUNT + 1))
  if [ "$MYSQL_WAIT_COUNT" -ge "$MYSQL_WAIT_TIMEOUT" ]; then
    echo "Error: MySQL did not become healthy within ${MYSQL_WAIT_TIMEOUT} seconds. Aborting."
    exit 1
  fi
  echo "  MySQL not ready yet (${MYSQL_WAIT_COUNT}s)..."
  sleep 1
done
echo "✓ MySQL is healthy"

# 启动依赖 MySQL 的服务
echo "Starting deferred services..."
for group in "${COMPOSE_FILES_DEFERRED[@]}"; do
  docker compose -f "docker-compose-${group}.yml" up -d || { echo "Error: ${group} services failed to start"; exit 1; }
  echo "✓ ${group} services started"
done

# 启动导航门户（最后一批）
echo "Starting portal..."
for group in "${COMPOSE_FILES_PORTAL[@]}"; do
  docker compose -f "docker-compose-${group}.yml" up -d || { echo "Error: ${group} services failed to start"; exit 1; }
  echo "✓ ${group} services started"
done

echo "==========================================="
echo "所有服务已启动！"
echo "==========================================="

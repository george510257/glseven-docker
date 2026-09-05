#!/bin/bash

set -e

# DOCKER_VOLUME 外部传入，默认值为 /docker/glseven
export DOCKER_VOLUME=${1:-/docker/glseven}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/compose-list.sh
source "$SCRIPT_DIR/common/compose-list.sh"
cd "$SCRIPT_DIR"

echo "==========================================="
echo "启动 GLSeven Docker 容器..."
echo "DOCKER_VOLUME: $DOCKER_VOLUME"
echo "==========================================="

# 创建必要的目录并设置权限
echo "Creating directories..."
mkdir -p "$DOCKER_VOLUME/nexus3/data/"    && chown -R 200   "$DOCKER_VOLUME/nexus3/data/"   || { echo "Error: Failed to create nexus3 data directory"; exit 1; }
mkdir -p "$DOCKER_VOLUME/prometheus/data" && chown -R 65534 "$DOCKER_VOLUME/prometheus/data" || { echo "Error: Failed to create prometheus data directory"; exit 1; }
mkdir -p "$DOCKER_VOLUME/grafana/data"    && chown -R 472   "$DOCKER_VOLUME/grafana/data"   || { echo "Error: Failed to create grafana data directory"; exit 1; }
mkdir -p "$DOCKER_VOLUME/elk/data"        && chown -R 1000  "$DOCKER_VOLUME/elk/data"        || { echo "Error: Failed to create elk data directory"; exit 1; }

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
  docker compose -f "docker-compose-${group}.yml" up -d && echo "✓ ${group} services started"
done

# 等待 MySQL 健康检查通过（Nacos / xxl-job-admin 依赖 MySQL 完成初始化）
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
  docker compose -f "docker-compose-${group}.yml" up -d && echo "✓ ${group} services started"
done

echo "==========================================="
echo "所有服务已启动！"
echo "==========================================="

#!/bin/bash

set -e

# DOCKER_VOLUME 外部传入，默认值为 /docker/glseven
export DOCKER_VOLUME=${1:-/docker/glseven}

# 读取 MySQL root 密码（供 mysqladmin ping 使用）
MYSQL_ROOT_PASSWORD=$(grep '^MYSQL_ROOT_PASSWORD=' common/env/mysql.env | cut -d= -f2-)

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

# 启动核心服务
echo "Starting services..."
docker compose -f docker-compose-storage.yml    -p storage    up -d && echo "✓ Storage services started"
docker compose -f docker-compose-messaging.yml  -p messaging  up -d && echo "✓ Messaging services started"
docker compose -f docker-compose-auth.yml       -p auth       up -d && echo "✓ Auth services started"
docker compose -f docker-compose-devops.yml     -p devops     up -d && echo "✓ DevOps services started"
docker compose -f docker-compose-manager.yml    -p manager    up -d && echo "✓ Manager services started"
docker compose -f docker-compose-monitor.yml    -p monitor    up -d && echo "✓ Monitor services started"

# 等待 MySQL 就绪（Nacos / xxl-job-admin 依赖 MySQL 完成初始化）
echo "Waiting for MySQL to be ready..."
MYSQL_WAIT_TIMEOUT=120
MYSQL_WAIT_COUNT=0
until docker exec mysql mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent 2>/dev/null; do
  MYSQL_WAIT_COUNT=$((MYSQL_WAIT_COUNT + 1))
  if [ $MYSQL_WAIT_COUNT -ge $MYSQL_WAIT_TIMEOUT ]; then
    echo "Error: MySQL did not become ready within ${MYSQL_WAIT_TIMEOUT} seconds. Aborting."
    exit 1
  fi
  echo "  MySQL not ready yet (${MYSQL_WAIT_COUNT}s)..."
  sleep 1
done
echo "✓ MySQL is ready"

docker compose -f docker-compose-microservices.yml -p microservices up -d && echo "✓ Microservices started"
docker compose -f docker-compose-ai.yml            -p ai            up -d && echo "✓ AI services started"
docker compose -f docker-compose-tv.yml            -p tv            up -d && echo "✓ TV services started"

echo "==========================================="
echo "所有服务已启动！"
echo "==========================================="

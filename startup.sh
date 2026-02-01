#!/bin/bash

set -e

# DOCKER_VOLUME 外部传入，默认值为 /docker/glseven
export DOCKER_VOLUME=${1:-/docker/glseven}

echo "==========================================="
echo "启动 GLSeven Docker 容器..."
echo "DOCKER_VOLUME: $DOCKER_VOLUME"
echo "==========================================="

# 创建必要的目录并设置权限
echo "Creating directories..."
mkdir -p "$DOCKER_VOLUME/nexus3/data/" && chown -R 200 "$DOCKER_VOLUME/nexus3/data/" || { echo "Error: Failed to create nexus3 data directory"; exit 1; }
mkdir -p "$DOCKER_VOLUME/prometheus/data" && chown -R 65534 "$DOCKER_VOLUME/prometheus/data" || { echo "Error: Failed to create prometheus data directory"; exit 1; }

# 创建 Docker 网络（如果不存在）
echo "Creating Docker network..."
docker network create --driver=bridge --subnet=172.18.0.0/16 glseven 2>/dev/null || echo "Network glseven already exists"

# 启动各个服务
echo "Starting services..."
docker compose -f docker-compose-database.yml -p database up -d && echo "✓ Database services started"
docker compose -f docker-compose-devops.yml -p devops up -d && echo "✓ DevOps services started"
docker compose -f docker-compose-manager.yml -p manager up -d && echo "✓ Manager services started"
docker compose -f docker-compose-microservices.yml -p microservices up -d && echo "✓ Microservices started"

echo "==========================================="
echo "所有服务已启动！"
echo "==========================================="

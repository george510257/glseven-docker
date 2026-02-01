#!/bin/bash

set -e

echo "==========================================="
echo "停止 GLSeven Docker 容器..."
echo "==========================================="

# 按启动顺序的反向停止服务
echo "Stopping services..."
docker compose -f docker-compose-microservices.yml -p microservices down && echo "✓ Microservices stopped"
docker compose -f docker-compose-manager.yml -p manager down && echo "✓ Manager services stopped"
docker compose -f docker-compose-devops.yml -p devops down && echo "✓ DevOps services stopped"
docker compose -f docker-compose-database.yml -p database down && echo "✓ Database services stopped"

# 移除网络
echo "Removing Docker network..."
docker network rm glseven 2>/dev/null && echo "✓ Network glseven removed" || echo "Network glseven not found"

echo "==========================================="
echo "所有服务已停止！"
echo "==========================================="

#!/bin/bash

set -e

echo "==========================================="
echo "停止 GLSeven Docker 容器..."
echo "==========================================="

# 按启动顺序的反向停止所有服务
echo "Stopping services..."
docker compose -f docker-compose-ai.yml            -p ai            down 2>/dev/null && echo "✓ AI services stopped"       || echo "- AI not running"
docker compose -f docker-compose-tv.yml            -p tv            down 2>/dev/null && echo "✓ TV services stopped"       || echo "- TV not running"
docker compose -f docker-compose-microservices.yml -p microservices down 2>/dev/null && echo "✓ Microservices stopped"     || echo "- Microservices not running"
docker compose -f docker-compose-monitor.yml       -p monitor       down 2>/dev/null && echo "✓ Monitor services stopped"  || echo "- Monitor not running"
docker compose -f docker-compose-manager.yml       -p manager       down 2>/dev/null && echo "✓ Manager services stopped"  || echo "- Manager not running"
docker compose -f docker-compose-devops.yml        -p devops        down 2>/dev/null && echo "✓ DevOps services stopped"   || echo "- DevOps not running"
docker compose -f docker-compose-auth.yml          -p auth          down 2>/dev/null && echo "✓ Auth services stopped"     || echo "- Auth not running"
docker compose -f docker-compose-messaging.yml     -p messaging     down 2>/dev/null && echo "✓ Messaging services stopped" || echo "- Messaging not running"
docker compose -f docker-compose-storage.yml       -p storage       down 2>/dev/null && echo "✓ Storage services stopped"  || echo "- Storage not running"

# 移除网络（幂等，不存在则跳过）
if docker network inspect glseven &>/dev/null; then
  echo "Removing Docker network glseven..."
  docker network rm glseven && echo "✓ Network glseven removed"
else
  echo "Network glseven not found, skipping."
fi

echo "==========================================="
echo "所有服务已停止！"
echo "==========================================="

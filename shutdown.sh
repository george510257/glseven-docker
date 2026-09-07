#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/compose-list.sh
source "$SCRIPT_DIR/common/compose-list.sh"
cd "$SCRIPT_DIR"

echo "==========================================="
echo "停止 GLSeven Docker 容器..."
echo "==========================================="

# 按启动顺序（BASE + DEFERRED + PORTAL 拼接）的逆序停止所有服务
stop_all() {
  local -a groups=("$@")
  local i group
  for (( i=${#groups[@]}-1; i>=0; i-- )); do
    group=${groups[$i]}
    docker compose -f "docker-compose-${group}.yml" down 2>/dev/null && echo "✓ ${group} services stopped" || echo "- ${group} not running"
  done
}

echo "Stopping services..."
stop_all "${COMPOSE_FILES_BASE[@]}" "${COMPOSE_FILES_DEFERRED[@]}" "${COMPOSE_FILES_PORTAL[@]}"

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

#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile|-p)
      [ $# -ge 2 ] || { echo "Error: --profile requires a value"; exit 2; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#*=}"; shift ;;
    *)
      echo "Error: unknown argument: $1"; exit 2 ;;
  esac
done

# shellcheck source=common/profile.sh
source "$SCRIPT_DIR/common/profile.sh"
PROFILE="$(select_profile "$SCRIPT_DIR" "$PROFILE")" || exit 1
PROFILE_FILE="$(profile_file "$SCRIPT_DIR" "$PROFILE")"
if [ ! -f "$PROFILE_FILE" ]; then
  echo "Error: profile file not found: $PROFILE_FILE"
  echo "Hint: cp ${PROFILE_FILE}.example ${PROFILE_FILE}"
  exit 1
fi
export PROFILE PROFILE_FILE

# shellcheck source=common/docker-volume.sh
source "$SCRIPT_DIR/common/docker-volume.sh"
export DOCKER_VOLUME="$(
  resolve_docker_volume "$SCRIPT_DIR" "" "$(uname -s)" "$HOME" "$PROFILE_FILE"
)"

# shellcheck source=common/compose-list.sh
source "$SCRIPT_DIR/common/compose-list.sh"
cd "$SCRIPT_DIR"

echo "==========================================="
echo "停止 GLSeven Docker 容器..."
echo "Profile: $PROFILE"
echo "==========================================="

compose() {
  docker compose --env-file "$PROFILE_FILE" "$@"
}

# 按启动顺序（BASE + DEFERRED + PORTAL 拼接）的逆序停止所有服务
stop_all() {
  local -a groups=("$@")
  local i group
  for (( i=${#groups[@]}-1; i>=0; i-- )); do
    group=${groups[$i]}
    # -t 60：默认 10s 对 kafka/elk/mysql 偏短，强制 kill 易留脏存储。
    # 不用 stop 替代 down：容器留着会占住 glseven 网络，致随后的 network rm 失败。
    compose -f "docker-compose-${group}.yml" down -t 60 2>/dev/null && echo "✓ ${group} services stopped" || echo "- ${group} not running"
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

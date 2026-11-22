#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE=""
PROFILE_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile|-p)
      [ $# -ge 2 ] || { echo "Error: --profile requires a value"; exit 2; }
      PROFILE="$2"; PROFILE_SET=1; shift 2 ;;
    --profile=*)
      PROFILE="${1#*=}"; PROFILE_SET=1; shift ;;
    *)
      echo "Error: unknown argument: $1"; exit 2 ;;
  esac
done

# shellcheck source=common/profile.sh
source "$SCRIPT_DIR/common/profile.sh"
require_profile_value || exit 2
PROFILE="$(select_profile "$SCRIPT_DIR" "$PROFILE")" || exit 1
PROFILE_FILE="$(profile_file "$SCRIPT_DIR" "$PROFILE")"
if [ ! -f "$PROFILE_FILE" ]; then
  echo "Error: profile file not found: $PROFILE_FILE"
  echo "Hint: cp ${PROFILE_FILE}.example ${PROFILE_FILE}, or pass --profile local|sit"
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

# 关闭顺序：BASE + DEFERRED + DEVOPS + PORTAL 的逆序。DEVOPS 无条件加入，
# 避免档案从 sit 切到 local 后 GitLab/Runner 残留。
stop_all() {
  local -a groups=("$@")
  local i group
  for (( i=${#groups[@]}-1; i>=0; i-- )); do
    group=${groups[$i]}
    # -t 60：默认 10s 对 kafka/elk/mysql 偏短，强制 kill 易留脏存储。
    # 不用 stop 替代 down：容器留着会占住 glseven 网络，致随后的 network rm 失败。
    compose -f "${group}/docker-compose.yml" down -t 60 --remove-orphans 2>/dev/null && echo "✓ ${group} services stopped" || echo "- ${group} not running"
  done
}

echo "Stopping services..."
build_shutdown_groups
stop_all "${SHUTDOWN_GROUPS[@]}"

# 移除网络（幂等）。glseven 是共享网络：其他 project 仍在使用时保留并提示，
# 不能把「删不掉」误报成「全部停止」。
network_removed=false
if docker network inspect glseven &>/dev/null; then
  echo "Removing Docker network glseven..."
  if docker network rm glseven; then
    network_removed=true
    echo "✓ Network glseven removed"
  else
    occupants="$(docker network inspect glseven --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)"
    echo "WARN: network glseven is still in use (${occupants:-unknown}); leaving it in place."
  fi
else
  echo "Network glseven not found, skipping."
  network_removed=true
fi

echo "==========================================="
if $network_removed; then
  echo "所有服务已停止，网络 glseven 已移除"
else
  echo "所有编排容器已停止；网络 glseven 保留（被其他 project 占用）"
fi
echo "==========================================="

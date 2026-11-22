#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common/compose-list.sh
source "$ROOT/common/compose-list.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "${COMPOSE_FILES_DEVOPS[*]}" = "devops" ] || fail "COMPOSE_FILES_DEVOPS 应为 (devops)"

( PROFILE=sit; profile_includes_devops ) || fail "sit 档案必须包含 devops"
( PROFILE=local; profile_includes_devops ) && fail "local 档案不得包含 devops"
( PROFILE=''; profile_includes_devops ) && fail "未选档案不得包含 devops"
( unset PROFILE; profile_includes_devops ) && fail "PROFILE 未设置不得包含 devops"

grep -q 'profile_includes_devops' "$ROOT/startup.sh" || fail "startup.sh 未使用门控函数"

build_shutdown_groups
[ "${SHUTDOWN_GROUPS[*]}" = "infra observability security platform apps devops portal" ] ||
  fail "shutdown 顺序必须无条件包含 devops"
grep -q -- '--remove-orphans' "$ROOT/shutdown.sh" ||
  fail "shutdown.sh 必须清理孤儿容器"
grep -q 'ps -aq' "$ROOT/startup.sh" ||
  fail "startup.sh 必须检测并停止残留 devops"
grep -q 'network_removed' "$ROOT/shutdown.sh" ||
  fail "shutdown.sh 必须记录网络移除结果"
grep -q '网络 glseven 保留' "$ROOT/shutdown.sh" ||
  fail "shutdown.sh 必须区分网络保留的最终横幅"
grep -q 'still in use' "$ROOT/shutdown.sh" ||
  fail "shutdown.sh 必须打印网络占用者"
! grep -q 'gitlab-runner/cache' "$ROOT/startup.sh" ||
  fail "startup.sh 不应创建未挂载的 gitlab-runner/cache"

for dir in gitlab/config gitlab/logs gitlab/data gitlab-runner/config gitlab-runner/home; do
  grep -q "\"$dir " "$ROOT/startup.sh" || fail "DIR_SPECS 缺少 $dir"
done
# GitLab 的多用户数据目录必须标记 top（非递归 chown）：递归会破坏 redis/postgresql 文件属主，
# 重部署后两者无法启动（2026-11-22 sit 实测）。
for dir in gitlab/config gitlab/logs gitlab/data; do
  grep -q "\"$dir [0-9]* top\"" "$ROOT/startup.sh" || fail "DIR_SPECS 的 $dir 必须标记 top"
done
# elk 镜像内 ES 以 uid 991 运行，属主错会因 data-path 健康检查失败导致 Kibana 503（2026-11-22 sit 实测）。
grep -q '"elk/data 991"' "$ROOT/startup.sh" || fail "DIR_SPECS 的 elk/data 必须是 991"

printf 'compose-list tests: OK\n'

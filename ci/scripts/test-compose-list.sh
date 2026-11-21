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
grep -q 'profile_includes_devops' "$ROOT/shutdown.sh" || fail "shutdown.sh 未使用门控函数"
for dir in gitlab/config gitlab/logs gitlab/data gitlab-runner/config gitlab-runner/cache gitlab-runner/home; do
  grep -q "\"$dir " "$ROOT/startup.sh" || fail "DIR_SPECS 缺少 $dir"
done
# GitLab 的多用户数据目录必须标记 top（非递归 chown）：递归会破坏 redis/postgresql 文件属主，
# 重部署后两者无法启动（2026-11-22 sit 实测）。
for dir in gitlab/config gitlab/logs gitlab/data; do
  grep -q "\"$dir [0-9]* top\"" "$ROOT/startup.sh" || fail "DIR_SPECS 的 $dir 必须标记 top"
done

printf 'compose-list tests: OK\n'

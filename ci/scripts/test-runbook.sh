#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RB="$ROOT/docs/runbooks/sit-cicd-bootstrap.md"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$RB" ] || fail "缺少 docs/runbooks/sit-cicd-bootstrap.md"
grep -q -- '--add-host gitlab.glseven.local:172.18.7.1' "$RB" ||
  fail "runbook 需用作业容器方式验证域名解析（runner 容器不继承 extra_hosts）"
! grep -q 'docker exec gitlab-runner getent hosts' "$RB" ||
  fail "runner 容器只有 glseven 网络，getent 无法验证作业容器的 extra_hosts"
grep -q 'checkout -f develop' "$RB" ||
  fail "手工部署需先切回 develop（CI 部署留下 detached HEAD）"

printf 'runbook tests: OK\n'

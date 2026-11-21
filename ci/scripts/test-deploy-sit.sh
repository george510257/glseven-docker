#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

out="$(TARGET_SHA=abc123 CI_REPOSITORY_URL="http://gitlab-ci-token:x@gitlab:8929/g/p.git" \
  DRY_RUN=1 bash "$ROOT/ci/deploy-sit.sh")"

for expected in \
  "safe.directory=/vol1/1000/glseven-docker" \
  "fetch --prune" \
  "checkout -f abc123" \
  "chown -R 1000:1000 /vol1/1000/glseven-docker" \
  "startup.sh --profile sit" \
  "nginx -t" \
  "nginx -s reload" \
  "ci/smoke-test.sh"; do
  [[ "$out" == *"$expected"* ]] || fail "dry-run 缺少: $expected"
done

[[ "$out" != *"/deploy"* ]] || fail "不得使用 /deploy 挂载路径"

[ -f "$ROOT/.gitlab-ci.yml" ] || fail "缺少 .gitlab-ci.yml"
grep -q 'deploy:sit' "$ROOT/.gitlab-ci.yml" || fail "缺少 deploy:sit 作业"
grep -q 'deploy:sit:rollback' "$ROOT/.gitlab-ci.yml" || fail "缺少回滚作业"
grep -q 'docker-compose-devops.yml' "$ROOT/.gitlab-ci.yml" || fail "缺少 devops changes 规则"
grep -q 'when: never' "$ROOT/.gitlab-ci.yml" || fail "devops 变更必须 when: never"

printf 'deploy-sit tests: OK\n'

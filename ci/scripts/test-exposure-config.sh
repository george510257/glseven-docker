#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../../common/preflight.sh
source "$ROOT/common/preflight.sh"

grep -q '^PORT_BIND_IP=127\.0\.0\.1$' "$ROOT/.env.local.example" || fail "local 示例缺少 PORT_BIND_IP=127.0.0.1"
grep -q '^PORT_BIND_IP=0\.0\.0\.0$' "$ROOT/.env.sit.example" || fail "sit 示例缺少 PORT_BIND_IP=0.0.0.0"

count=$(grep -cE '^      - "\$\{PORT_BIND_IP:-127\.0\.0\.1\}:[0-9]+:[0-9]+"' "$ROOT/portal/docker-compose.yml")
[ "$count" -eq 28 ] || fail "portal 应有 28 条带 PORT_BIND_IP 的 ports，实际 $count"
total=$(grep -cE '^      - "[^"]+:[0-9]+:[0-9]+"' "$ROOT/portal/docker-compose.yml")
[ "$total" -eq 28 ] || fail "portal 总 ports 应为 28 条，实际 $total"

grep -q 'NF >= 3' "$ROOT/common/preflight.sh" || fail "preflight 端口解析应兼容两段/三段式"
grep -q 'PORT_BIND_IP' "$ROOT/common/preflight.sh" || fail "preflight 未校验 PORT_BIND_IP"

for key in "${PROFILE_REQUIRED_KEYS[@]}"; do
  grep -q "^${key}=" "$ROOT/.env.local.example" || fail "local 示例缺少 $key"
  grep -q "^${key}=" "$ROOT/.env.sit.example" || fail "sit 示例缺少 $key"
done
grep -q 'GF_SECURITY_ADMIN_PASSWORD' "$ROOT/observability/docker-compose.yml" || fail "Grafana 未注入管理员口令"
grep -q 'APISIX_ADMIN_KEY' "$ROOT/platform/apisix/conf/config.yaml" || fail "APISIX config 未引用 APISIX_ADMIN_KEY"
grep -q 'APISIX_ADMIN_KEY' "$ROOT/platform/docker-compose.yml" || fail "platform compose 未注入 APISIX_ADMIN_KEY"
grep -q 'XXL_JOB_ACCESS_TOKEN' "$ROOT/platform/xxl-job-admin/application.properties" || fail "xxl-job properties 未引用 XXL_JOB_ACCESS_TOKEN"
grep -q 'XXL_JOB_ACCESS_TOKEN' "$ROOT/platform/docker-compose.yml" || fail "platform compose 未注入 XXL_JOB_ACCESS_TOKEN"
grep -q 'KC_BOOTSTRAP_ADMIN_PASSWORD' "$ROOT/security/docker-compose.yml" || fail "Keycloak 未注入 bootstrap 口令"

! grep -q '^KC_BOOTSTRAP_ADMIN_PASSWORD=' "$ROOT/security/env/keycloak.env" || fail "keycloak.env 不应重复定义 bootstrap 口令"
! grep -Fq 'Hint: cp ${PROFILE_FILE}.example' "$ROOT/common/preflight.sh" || fail "preflight 缺键提示不得建议覆盖 profile"
grep -q 'append .*PROFILE_FILE' "$ROOT/common/preflight.sh" || fail "preflight 应提示追加缺失键"

printf 'exposure config tests: OK\n'

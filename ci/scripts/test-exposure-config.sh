#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -q '^PORT_BIND_IP=127\.0\.0\.1$' "$ROOT/.env.local.example" || fail "local 示例缺少 PORT_BIND_IP=127.0.0.1"
grep -q '^PORT_BIND_IP=0\.0\.0\.0$' "$ROOT/.env.sit.example" || fail "sit 示例缺少 PORT_BIND_IP=0.0.0.0"

count=$(grep -cE '^      - "\$\{PORT_BIND_IP:-127\.0\.0\.1\}:[0-9]+:[0-9]+"' "$ROOT/portal/docker-compose.yml")
[ "$count" -eq 30 ] || fail "portal 应有 30 条带 PORT_BIND_IP 的 ports，实际 $count"

grep -q 'NF-1' "$ROOT/common/preflight.sh" || fail "preflight 端口解析未使用三段式 NF-1"
grep -q 'PORT_BIND_IP' "$ROOT/common/preflight.sh" || fail "preflight 未校验 PORT_BIND_IP"

printf 'exposure config tests: OK\n'

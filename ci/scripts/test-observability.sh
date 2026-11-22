#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'retention.time=15d' "$ROOT/observability/docker-compose.yml" || fail "Prometheus 缺少 retention.time"
grep -Fq 'retention.size=10GB' "$ROOT/observability/docker-compose.yml" || fail "Prometheus 缺少 retention.size"
grep -Fq 'monitoring.enabled: true' "$ROOT/observability/filebeat/conf/filebeat.yml" || fail "Filebeat 未开启 monitoring"
grep -Fq 'monitoring.elasticsearch' "$ROOT/observability/filebeat/conf/filebeat.yml" || fail "Filebeat 未配置 monitoring.elasticsearch"
DASH="$ROOT/observability/grafana/conf/dashboards/glseven-targets.json"
[ -s "$DASH" ] || fail "缺少 Grafana Targets 面板"
grep -Fq '"prometheus"' "$DASH" || fail "面板未引用 prometheus 数据源"
grep -Fq '"up"' "$DASH" || fail "面板缺少 up 查询"

grep -Fq 'force-recreate filebeat' "$ROOT/README.md" || fail "README 缺少 filebeat 重建升级步骤"
grep -Fq 'reset-admin-password' "$ROOT/README.md" || fail "README 缺少 Grafana 口令重置说明"

printf 'observability tests: OK\n'

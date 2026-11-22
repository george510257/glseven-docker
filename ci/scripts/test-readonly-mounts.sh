#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check_mount() {
  local file="$1" mount="$2"
  grep -Fq -- "$mount" "$ROOT/$file" || fail "$file 缺少只读挂载: $mount"
}

check_mount infra/docker-compose.yml './mysql/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d:ro'
check_mount infra/docker-compose.yml './rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro'
check_mount observability/docker-compose.yml './prometheus/conf/prometheus.yml:/etc/prometheus/prometheus.yml:ro'
check_mount observability/docker-compose.yml './grafana/conf/provisioning:/etc/grafana/provisioning:ro'
check_mount observability/docker-compose.yml './grafana/conf/dashboards:/var/lib/grafana/dashboards:ro'
check_mount observability/docker-compose.yml './grafana/conf/config/grafana.ini:/etc/grafana/grafana.ini:ro'
check_mount observability/docker-compose.yml './elk/kibana/config/kibana.yml:/opt/kibana/config/kibana.yml:ro'
check_mount platform/docker-compose.yml './nacos/config/custom.properties:/home/nacos/init.d/custom.properties:ro'
check_mount platform/docker-compose.yml './xxl-job-admin/application.properties:/application.properties:ro'

printf 'readonly mount tests: OK\n'

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'ES_JAVA_OPTS: "-Xms1g -Xmx1g"' "$ROOT/observability/docker-compose.yml" || fail "ES 堆上限缺失"
grep -Fq 'LS_HEAP_SIZE: "512m"' "$ROOT/observability/docker-compose.yml" || fail "Logstash 堆上限缺失"
! grep -Fq 'LS_JAVA_OPTS' "$ROOT/observability/docker-compose.yml" || fail "elk 不应使用 LS_JAVA_OPTS"
grep -Fq 'KAFKA_HEAP_OPTS: "-Xms512m -Xmx512m"' "$ROOT/infra/docker-compose.yml" || fail "Kafka 堆上限缺失"
grep -Fq 'INSTALL4J_ADD_VM_PARAMS: "-Xms768m -Xmx768m -XX:MaxDirectMemorySize=768m -Djava.util.prefs.userRoot=/nexus-data/javaprefs -Dfile.encoding=UTF-8"' "$ROOT/platform/docker-compose.yml" || fail "Nexus 堆上限或 prefs 参数缺失"
grep -Fq -- '--maxmemory 256mb' "$ROOT/infra/docker-compose.yml" || fail "Redis maxmemory 缺失"
grep -Fq -- '--maxmemory-policy allkeys-lru' "$ROOT/infra/docker-compose.yml" || fail "Redis 淘汰策略缺失"

# 有 Docker CLI 时补一层渲染断言，降低与 YAML 写法的耦合。
if command -v docker >/dev/null 2>&1; then
  rendered="$(docker compose --env-file "$ROOT/.env.local.example" -f "$ROOT/observability/docker-compose.yml" config 2>/dev/null || true)"
  printf '%s\n' "$rendered" | grep -Fq 'Xms1g -Xmx1g' || fail "渲染后 ES 堆上限缺失"
  printf '%s\n' "$rendered" | grep -Fq 'LS_HEAP_SIZE' || fail "渲染后 LS_HEAP_SIZE 缺失"
  infra_rendered="$(docker compose --env-file "$ROOT/.env.local.example" -f "$ROOT/infra/docker-compose.yml" config 2>/dev/null || true)"
  printf '%s\n' "$infra_rendered" | grep -Fq 'maxmemory 256mb' || fail "渲染后 Redis maxmemory 缺失"
  printf '%s\n' "$infra_rendered" | grep -Fq 'allkeys-lru' || fail "渲染后 Redis 淘汰策略缺失"
fi

printf 'resource limit tests: OK\n'

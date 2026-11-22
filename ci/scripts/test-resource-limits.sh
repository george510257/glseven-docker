#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'ES_JAVA_OPTS: "-Xms1g -Xmx1g"' "$ROOT/observability/docker-compose.yml" || fail "ES 堆上限缺失"
grep -Fq 'LS_HEAP_SIZE: "512m"' "$ROOT/observability/docker-compose.yml" || fail "Logstash 堆上限缺失"
! grep -Fq 'LS_JAVA_OPTS' "$ROOT/observability/docker-compose.yml" || fail "elk 不应使用 LS_JAVA_OPTS"
grep -Fq 'KAFKA_HEAP_OPTS: "-Xms512m -Xmx512m"' "$ROOT/infra/docker-compose.yml" || fail "Kafka 堆上限缺失"
grep -Fq 'INSTALL4J_ADD_VM_PARAMS: "-Xms768m -Xmx768m -XX:MaxDirectMemorySize=768m"' "$ROOT/platform/docker-compose.yml" || fail "Nexus 堆上限缺失"
grep -Fq -- '--maxmemory 256mb' "$ROOT/infra/docker-compose.yml" || fail "Redis maxmemory 缺失"
grep -Fq -- '--maxmemory-policy allkeys-lru' "$ROOT/infra/docker-compose.yml" || fail "Redis 淘汰策略缺失"

printf 'resource limit tests: OK\n'

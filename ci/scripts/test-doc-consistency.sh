#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq '7 个职能域、27 个容器' "$ROOT/README.md" || fail "README 域/容器数量未更新"
grep -Fq '七域结构与启动时序' "$ROOT/README.md" || fail "README 结构标题未更新"
grep -Fq '| devops |' "$ROOT/README.md" || fail "README 结构表缺少 devops"
grep -Fq '25 个主机名' "$ROOT/README.md" || fail "README hosts 数量未更新"
grep -Fq -- '--env-file .env.local' "$ROOT/README.md" || fail "README 命令迁移仍指向旧 .env"
! grep -Fq 'MySQL/Mongo' "$ROOT/README.md" || fail "README 仍称 Adminer 支持 MongoDB"
grep -Fq 'MySQL 管理' "$ROOT/README.md" || fail "README Adminer 描述未更新"
! grep -Fq 'MySQL / MongoDB' "$ROOT/portal/html/index.html" || fail "门户仍称 Adminer 支持 MongoDB"
grep -Fq 'MySQL 数据库管理' "$ROOT/portal/html/index.html" || fail "门户 Adminer 描述未更新"

! grep -q '四个脚本' "$ROOT/CLAUDE.md" || fail "CLAUDE.md 仍写四个脚本"
grep -Fq 'test-*.sh' "$ROOT/CLAUDE.md" || fail "CLAUDE.md 未改为所有 test-*.sh"

! grep -q 'docker-compose-devops.yml' "$ROOT/docs/runbooks/sit-cicd-bootstrap.md" ||
  fail "runbook 仍引用旧文件名"
grep -Fq 'devops/docker-compose.yml' "$ROOT/docs/runbooks/sit-cicd-bootstrap.md" ||
  fail "runbook 未指向新路径"

! grep -Fq '35672' "$ROOT/portal/conf/stream-conf.d/rabbitmq.conf" ||
  fail "RabbitMQ stream 注释仍有 35672 笔误"
! grep -Fq '见 infra/env/kafka.env' "$ROOT/portal/conf/stream-conf.d/kafka.conf" ||
  fail "Kafka stream 注释仍指向错误文件"
grep -Fq 'KAFKA_EXTERNAL_HOST' "$ROOT/portal/conf/stream-conf.d/kafka.conf" ||
  fail "Kafka stream 注释未说明 advertised 来源"

server_count=0
for f in "$ROOT"/portal/conf/conf.d/*.conf; do
  case "$f" in *.local.conf) continue ;; esac
  count=$(grep -Fc 'server {' "$f" || true)
  server_count=$((server_count + count))
done
grep -Eq "(^|[^0-9])${server_count} 个 server 块" "$ROOT/portal/docker-compose.yml" ||
  fail "portal compose 的 server 块计数与实际 ${server_count} 不一致"

grep -Fq -- '--drop' "$ROOT/README.md" || fail "README Mongo 恢复缺少 --drop 提示"
grep -Fq '未导出' "$ROOT/README.md" || fail "README 恢复命令缺少 DOCKER_VOLUME 提示"

printf 'doc consistency tests: OK\n'

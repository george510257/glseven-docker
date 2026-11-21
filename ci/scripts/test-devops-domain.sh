#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
grep_file() { grep -q "$1" "$ROOT/$2" || fail "$2 缺少 $1"; }

[ -f "$ROOT/devops/docker-compose.yml" ] || fail "缺少 devops/docker-compose.yml"
grep_file '^  gitlab:$' devops/docker-compose.yml
grep_file '^  gitlab-runner:$' devops/docker-compose.yml
grep_file 'ipv4_address: 172.18.7.1' devops/docker-compose.yml
grep_file 'ipv4_address: 172.18.7.2' devops/docker-compose.yml
grep_file 'container_name: gitlab$' devops/docker-compose.yml
grep_file 'container_name: gitlab-runner$' devops/docker-compose.yml

[ -f "$ROOT/portal/conf/conf.d/gitlab.conf" ] || fail "缺少 conf.d/gitlab.conf"
grep_file 'listen 8080;' portal/conf/conf.d/gitlab.conf
grep_file 'server_name gitlab.glseven.local;' portal/conf/conf.d/gitlab.conf
grep_file 'resolver 127.0.0.11' portal/conf/conf.d/gitlab.conf

[ -f "$ROOT/portal/conf/stream-conf.d/gitlab.conf" ] || fail "缺少 stream-conf.d/gitlab.conf"
grep_file 'listen 2222;' portal/conf/stream-conf.d/gitlab.conf
grep_file 'resolver 127.0.0.11' portal/conf/stream-conf.d/gitlab.conf

grep_file '"8080:8080"' portal/docker-compose.yml
grep_file '"2222:2222"' portal/docker-compose.yml
grep_file 'data-host="gitlab"' portal/html/index.html
grep_file 'gitlab.glseven.local' README.md
grep_file 'INTERNAL_ONLY="filebeat gitlab-runner"' common/check-consistency.sh

printf 'devops domain tests: OK\n'

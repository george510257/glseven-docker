#!/usr/bin/env bash
# 端口标准化断言：门户/GitLab Web 8080、GitLab SSH 2222。
# 用法：bash ci/scripts/test-default-ports.sh [portal|gitlab|docs|ci|all]
set -u

group="${1:-all}"
fail=0

pass() { printf '  [OK]   %s\n' "$*"; }
fail_check() { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }

file_has() {
  if grep -qF -- "$2" "$1"; then pass "$3"; else fail_check "$3（缺 $2）"; fi
}

file_lacks() {
  if grep -qF -- "$2" "$1"; then fail_check "$3（仍有 $2）"; else pass "$3"; fi
}

check_8080_names() {
  local names dupes
  names=$(for f in portal/conf/conf.d/*.conf; do
    case "$f" in *.local.conf) continue ;; esac
    awk '{ gsub(/;/, ";\n"); print }' "$f" |
      awk '
        /listen[[:space:]]+8080/ { want = 1; next }
        want && /server_name[[:space:]]+/ { n = $2; sub(/;$/, "", n); print n; want = 0 }
      '
  done | sort)
  dupes=$(printf '%s\n' "$names" | uniq -d)
  if [[ -n "$dupes" ]]; then
    fail_check "8080 server_name 重复：$(echo "$dupes")"
  else
    pass "8080 server_name 唯一（$(printf '%s\n' "$names" | wc -l | tr -d ' ') 个）"
  fi
}

check_portal() {
  echo "portal:"
  file_has   portal/docker-compose.yml '"8080:8080"' "portal compose 发布 8080"
  file_lacks portal/docker-compose.yml '"8000:8000"' "portal compose 不再发布 8000"
  file_has   portal/docker-compose.yml '/dev/tcp/127.0.0.1/8080' "healthcheck 探 8080"
  file_has   portal/conf/conf.d/portal.conf 'listen 8080' "portal vhost listen 8080"
  file_lacks portal/conf/conf.d/portal.conf 'listen 8000' "portal vhost 不再 listen 8000"
  file_has   portal/conf/conf.d/portal.conf 'portal.glseven.local:8080' "根域 301 指向 8080"
  file_lacks portal/conf/conf.d/00-default-catchall.conf ':8000' "catchall 不再指向 8000"
  file_has   portal/conf/conf.d/00-default-catchall.conf 'portal.glseven.local:8080' "catchall 指向 8080"
  check_8080_names
}

check_gitlab() {
  echo "gitlab:"
  file_has   portal/conf/conf.d/gitlab.conf 'listen 8080' "gitlab vhost listen 8080"
  file_lacks portal/conf/conf.d/gitlab.conf '8929' "gitlab vhost 不再用 8929"
  file_has   portal/conf/conf.d/gitlab.conf 'gitlab:8080' "gitlab upstream 8080"
  file_has   portal/conf/stream-conf.d/gitlab.conf 'listen 2222' "gitlab ssh stream listen 2222"
  file_lacks portal/conf/stream-conf.d/gitlab.conf '2224' "gitlab ssh stream 不再用 2224"
  file_lacks portal/docker-compose.yml '"8929:8929"' "portal compose 不再发布 8929"
  file_has   portal/docker-compose.yml '"2222:2222"' "portal compose 发布 2222"
  file_lacks portal/docker-compose.yml '"2224:2224"' "portal compose 不再发布 2224"
  file_has   devops/docker-compose.yml "external_url 'http://gitlab.glseven.local:8080'" "GitLab external_url 8080"
  file_has   devops/docker-compose.yml "puma['port'] = 8082" "Puma 内部端口 8082（避开 external_url 的 8080）"
  file_has   devops/docker-compose.yml "gitlab_shell_ssh_port'] = 2222" "GitLab ssh port 2222"
  file_has   devops/docker-compose.yml 'localhost:8080/-/readiness' "GitLab healthcheck 8080"
  file_lacks devops/docker-compose.yml '8929' "GitLab compose 不再用 8929"
}

check_docs() {
  echo "docs:"
  file_lacks portal/html/index.html '8929' "门户页不再有 8929"
  file_has   portal/html/index.html 'data-host="gitlab" data-port="8080"' "GitLab 卡片 8080"
  file_lacks README.md ':8000' "README 不再有 :8000"
  file_lacks README.md ':8929' "README 不再有 :8929"
  file_lacks CLAUDE.md ':8000' "CLAUDE.md 不再有 :8000"
  file_lacks CLAUDE.md ':8929' "CLAUDE.md 不再有 :8929"
  file_lacks docs/runbooks/sit-cicd-bootstrap.md '8929' "runbook 不再有 8929"
  file_lacks docs/runbooks/sit-cicd-bootstrap.md '2224' "runbook 不再有 2224"
  file_has   docs/runbooks/sit-cicd-bootstrap.md 'SSH remote' "runbook 提示 SSH remote 改 2222"
  file_has   docs/runbooks/sit-cicd-bootstrap.md 'reconfigure' "runbook 提示 GitLab reconfigure"
}

check_ci() {
  echo "ci:"
  file_lacks ci/smoke-test.sh ':8000' "smoke-test 不再探 8000"
  file_lacks ci/smoke-test.sh ':8929' "smoke-test 不再探 8929"
  file_lacks ci/scripts/test-devops-domain.sh '8929' "test-devops-domain 不再断言 8929"
  file_lacks ci/scripts/test-devops-domain.sh '2224' "test-devops-domain 不再断言 2224"
  file_lacks ci/scripts/test-deploy-sit.sh '8929' "test-deploy-sit 不再用 8929"
}

case "$group" in
  portal) check_portal ;;
  gitlab) check_gitlab ;;
  docs)   check_docs ;;
  ci)     check_ci ;;
  all)    check_portal; check_gitlab; check_docs; check_ci ;;
  *) echo "usage: $0 [portal|gitlab|docs|ci|all]" >&2; exit 2 ;;
esac

if [[ "$fail" -gt 0 ]]; then
  echo "default-ports: $fail 项失败"
  exit 1
fi
echo "default-ports: OK"

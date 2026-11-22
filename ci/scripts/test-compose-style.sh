#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$ROOT/common/base-service.yml"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Task 2-4 逐步追加已转换的域，保证每个中间提交都是绿的。
DOMAINS=(infra observability security platform apps portal devops)

check_base() {
  [ -f "$BASE" ] || fail "缺少 common/base-service.yml"
  grep -q '^  service-base:$' "$BASE" || fail "base 缺少 service-base"
  grep -q '^  service-common:$' "$BASE" || fail "base 缺少 service-common"
  grep -q '^  service-healthy:$' "$BASE" || fail "base 缺少 service-healthy"
  grep -A2 '^  service-common:$' "$BASE" | grep -q 'extends: service-base' ||
    fail "service-common 必须继承 service-base"
  grep -A2 '^  service-healthy:$' "$BASE" | grep -q 'extends: service-common' ||
    fail "service-healthy 必须继承 service-common"
}

check_header() {
  local file="$1" domain="$2" header
  header=$(grep -E '^# [A-Z][A-Za-z]+ 172\.18\.[1-7]\.x =+$' "$file" | head -1 || true)
  [ -n "$header" ] || fail "$domain: 域名标题注释格式不正确"
  [ "${#header}" -eq 100 ] || fail "$domain: 域名标题注释应为 100 列（当前 ${#header}）"
}

check_services() {
  local file="$1" domain="$2" svc ext ref name line
  ! grep -q '^    restart:' "$file" || fail "$domain: 不应再出现 restart:"
  ! grep -q 'common/env/common.env' "$file" || fail "$domain: 不应再引用 common.env"

  for ref in $(grep -hoE '^[[:space:]]+extends: \*[a-z-]+' "$file" | awk '{print $2}' | sort -u || true); do
    name="${ref#\*}"
    grep -q "^x-${name}: &${name}$" "$file" ||
      fail "$domain: 使用了未定义的锚点 $ref"
  done

  while IFS= read -r line; do
    [ -z "$line" ] || fail "${line#FAIL: }"
  done < <(awk -v domain="$domain" '
    function flush() {
      if (svc == "") return
      if (ext == "") print "FAIL: " domain ": " svc " 缺少 extends"
      if (cn == "" || hn == "") print "FAIL: " domain ": " svc " 缺少 container_name/hostname"
      else if (cn != hn) print "FAIL: " domain ": " svc " container_name 与 hostname 不一致"
      if (hc && !test) print "FAIL: " domain ": " svc " healthcheck 缺少 test"
      if (test && test !~ /\["(CMD|CMD-SHELL|NONE)"/)
        print "FAIL: " domain ": " svc " test 数组格式不符合规范"
      svc = ""; ext = ""; cn = ""; hn = ""; hc = 0; test = ""
    }
    /^services:$/ { in_services = 1; next }
    in_services && /^  [a-z0-9-]+:$/ { flush(); svc = $1; sub(/:$/, "", svc); first = 1; next }
    in_services && /^    [a-z_]+:/ && first {
      if ($1 != "extends:") print "FAIL: " domain ": " svc " 首字段必须是 extends"
      first = 0
    }
    in_services && /^    extends:/ { ext = $2; next }
    in_services && /^    container_name:/ { cn = $2; next }
    in_services && /^    hostname:/ { hn = $2; next }
    in_services && /^    healthcheck:/ { hc = 1; next }
    in_services && /^      test:/ { test = $0; next }
    END { flush() }
  ' "$file")

  for svc in $(awk '/^services:$/ { in_services = 1; next } in_services && /^  [a-z0-9-]+:$/ { n=$1; sub(/:$/, "", n); print n }' "$file"); do
    ext=$(awk -v s="$svc" '
      $0 == "services:" { in_services = 1; next }
      in_services && $0 == "  " s ":" { in_svc = 1; next }
      in_svc && /^  [a-z0-9-]+:$/ { exit }
      in_svc && /^    extends:/ { print $2; exit }
    ' "$file")
    case "$svc" in
      gitlab|gitlab-runner) [ "$ext" = "*base" ] || fail "$domain: $svc 必须使用 *base" ;;
      portainer) [ "$ext" = "*common" ] || fail "$domain: $svc 必须使用 *common" ;;
      *) [ "$ext" = "*healthy" ] || fail "$domain: $svc 必须使用 *healthy" ;;
    esac
  done
}

check_base
for domain in "${DOMAINS[@]}"; do
  file="$ROOT/$domain/docker-compose.yml"
  [ -f "$file" ] || fail "缺少 $domain/docker-compose.yml"
  check_header "$file" "$domain"
  check_services "$file" "$domain"
done

printf 'compose style tests: OK\n'

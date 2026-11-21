#!/usr/bin/env bash
# 部署后 smoke：容器健康 + nginx 配置 + 宿主发布端口的真实 HTTP 路径。
set -euo pipefail

SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.23.0}"
CURL_HOST="--network host"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

echo "Smoke: waiting for healthy containers (timeout ${SMOKE_TIMEOUT}s)..."
deadline=$((SECONDS + SMOKE_TIMEOUT))
while :; do
  unhealthy=""
  for c in $(docker ps --format '{{.Names}}'); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || true)"
    [ -z "$status" ] && continue
    [ "$status" = "healthy" ] || unhealthy="$unhealthy $c:$status"
  done
  [ -z "$unhealthy" ] && break
  [ "$SECONDS" -lt "$deadline" ] || fail "unhealthy containers:$unhealthy"
  sleep 5
done

echo "Smoke: nginx -t"
docker exec nginx nginx -t

probe() {
  local url="$1" host="$2"
  local code
  code="$(docker run --rm $CURL_HOST "$CURL_IMAGE" \
    -sS -o /dev/null -w '%{http_code}' -H "Host: $host" "$url")"
  [ "$code" = "200" ] || fail "$url -> HTTP $code (expected 200)"
  echo "  OK $url"
}

echo "Smoke: host-published endpoints"
probe "http://127.0.0.1:8000/" "portal.glseven.local"
probe "http://127.0.0.1:8929/-/readiness" "gitlab.glseven.local"

if docker run --rm $CURL_HOST "$CURL_IMAGE" \
  -sS -o /dev/null -w '%{http_code}' -H "Host: nexus3.glseven.local" \
  "http://127.0.0.1:8081/service/rest/v1/status" | grep -qx 200; then
  echo "  OK nexus3"
else
  echo "  WARN: Nexus 未就绪（不阻断）"
fi

echo "Smoke: OK"

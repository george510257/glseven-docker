#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
file="${1:-$ROOT/platform/env/nacos.env}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$file" ] || fail "missing $file"
grep -q '^NACOS_AUTH_ENABLE=true$' "$file" || fail "NACOS_AUTH_ENABLE must be true"
for key in NACOS_AUTH_TOKEN NACOS_AUTH_IDENTITY_KEY NACOS_AUTH_IDENTITY_VALUE; do
  grep -qE "^${key}=.+" "$file" || fail "$key is missing"
done

if [ -z "${1:-}" ]; then
  tmp="$(mktemp)"
  grep -v '^NACOS_AUTH_IDENTITY_VALUE=' "$file" > "$tmp"
  if bash "$0" "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "mutated nacos.env must fail the assertion"
  fi
  rm -f "$tmp"
fi

printf 'env config tests: OK\n'

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../common/compose-list.sh
source "$ROOT_DIR/common/compose-list.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_true() {
  local context="$1"
  shift
  "$@" || fail "$context: expected true"
}

assert_false() {
  local context="$1"
  shift
  if "$@"; then
    fail "$context: expected false"
  fi
}

assert_true "Darwin arm64 is Apple Silicon" \
  is_apple_silicon Darwin arm64
assert_false "Darwin x86_64 is not Apple Silicon" \
  is_apple_silicon Darwin x86_64
assert_false "Linux arm64 is not Apple Silicon" \
  is_apple_silicon Linux arm64

expected_services="prometheus grafana"
actual_services="${COMPOSE_SERVICES_OBSERVABILITY_APPLE_SILICON[*]}"
[[ "$actual_services" == "$expected_services" ]] ||
  fail "Apple Silicon observability services: expected '$expected_services', got '$actual_services'"

printf 'startup-platform tests: OK\n'

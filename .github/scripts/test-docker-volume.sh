#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VOLUME_HELPER="$ROOT_DIR/common/docker-volume.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/glseven-volume-tests.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# shellcheck source=../../common/docker-volume.sh
source "$VOLUME_HELPER"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$context: expected '$expected', got '$actual'"
}

fixture="$TMP_ROOT/fixture"
home_dir="$TMP_ROOT/home"
mkdir -p "$fixture" "$home_dir"
cat > "$fixture/.env" <<'EOF'
# Existing user configuration must win over platform defaults.
export DOCKER_VOLUME="/tmp/glseven-from-env"
EOF

unset DOCKER_VOLUME
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir")" \
  "/tmp/glseven-from-env" \
  "Darwin uses DOCKER_VOLUME from .env"

assert_eq \
  "$(resolve_docker_volume "$fixture" "/tmp/glseven-positional" Darwin "$home_dir")" \
  "/tmp/glseven-positional" \
  "positional argument overrides .env"

export DOCKER_VOLUME="/tmp/glseven-from-shell"
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir")" \
  "/tmp/glseven-from-shell" \
  "shell environment overrides .env"
unset DOCKER_VOLUME

empty_fixture="$TMP_ROOT/empty"
mkdir -p "$empty_fixture"
assert_eq \
  "$(resolve_docker_volume "$empty_fixture" "" Darwin "$home_dir")" \
  "$home_dir/docker/glseven" \
  "Darwin fallback stays under HOME"

assert_eq \
  "$(resolve_docker_volume "$empty_fixture" "" Linux "$home_dir")" \
  "/docker/glseven" \
  "Linux fallback preserves /docker/glseven"

env_local="$TMP_ROOT/volume-local.env"
printf 'DOCKER_VOLUME=/from-local-profile\n' > "$env_local"
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir" "$env_local")" \
  "/from-local-profile" \
  "explicit env file is used"

home_env="$TMP_ROOT/volume-home.env"
printf 'DOCKER_VOLUME=$HOME/docker/glseven\n' > "$home_env"
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir" "$home_env")" \
  "$home_dir/docker/glseven" \
  "expands \$HOME prefix"

tilde_env="$TMP_ROOT/volume-tilde.env"
printf 'DOCKER_VOLUME=~/docker/glseven\n' > "$tilde_env"
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir" "$tilde_env")" \
  "$home_dir/docker/glseven" \
  "expands ~ prefix"

(
  SCRIPT_DIR="$TMP_ROOT/preflight"
  DOCKER_VOLUME="$home_dir/docker/glseven"
  mkdir -p "$SCRIPT_DIR"
  printf 'REDIS_PASSWORD=x\n' > "$SCRIPT_DIR/.env.example"
  # shellcheck source=../../common/preflight.sh
  source "$ROOT_DIR/common/preflight.sh"
  ensure_env_file >/dev/null
  grep -qx "DOCKER_VOLUME=$DOCKER_VOLUME" "$SCRIPT_DIR/.env" ||
    fail "generated .env does not persist resolved DOCKER_VOLUME"
)

printf 'docker-volume tests: OK\n'

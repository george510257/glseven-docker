#!/usr/bin/env bash

# Resolve the host data directory without mutating the caller's environment.
# Precedence: positional argument > exported DOCKER_VOLUME > root .env > platform default.
resolve_docker_volume() {
  local script_dir="$1"
  local positional="${2:-}"
  local platform="${3:-$(uname -s)}"
  local home_dir="${4:-$HOME}"
  local env_volume=""

  if [[ -n "$positional" ]]; then
    printf '%s\n' "$positional"
    return 0
  fi

  if [[ -n "${DOCKER_VOLUME:-}" ]]; then
    printf '%s\n' "$DOCKER_VOLUME"
    return 0
  fi

  if [[ -f "$script_dir/.env" ]]; then
    env_volume="$(
      awk -v key="DOCKER_VOLUME" '
        /^[[:space:]]*#/ { next }
        {
          line = $0
          sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
          if (index(line, key "=") != 1) next
          value = substr(line, length(key) + 2)
          sub(/[[:space:]]+#.*$/, "", value)
          gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
          print value
          exit
        }
      ' "$script_dir/.env"
    )"
  fi

  if [[ -n "$env_volume" ]]; then
    printf '%s\n' "$env_volume"
    return 0
  fi

  if [[ "$platform" == "Darwin" ]]; then
    printf '%s/docker/glseven\n' "$home_dir"
  else
    printf '/docker/glseven\n'
  fi
}

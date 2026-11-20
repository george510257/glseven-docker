#!/usr/bin/env bash

# Resolve the host data directory without mutating the caller's environment.
# Precedence: positional argument > exported DOCKER_VOLUME > env file > platform default.
resolve_docker_volume() {
  local script_dir="$1"
  local positional="${2:-}"
  local platform="${3:-$(uname -s)}"
  local home_dir="${4:-$HOME}"
  local env_file="${5:-$1/.env}"
  local value=""

  if [[ -n "$positional" ]]; then
    value="$positional"
  elif [[ -n "${DOCKER_VOLUME:-}" ]]; then
    value="$DOCKER_VOLUME"
  else
    if [[ -f "$env_file" ]]; then
      value="$(
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
        ' "$env_file"
      )"
    fi

    if [[ -z "$value" ]]; then
      if [[ "$platform" == "Darwin" ]]; then
        value="$home_dir/docker/glseven"
      else
        value="/docker/glseven"
      fi
    fi
  fi

  case "$value" in
    "~/"*)      value="$home_dir/${value#\~/}" ;;
    '$HOME/'*)  value="$home_dir/${value#\$HOME/}" ;;
    '${HOME}/'*) value="$home_dir/${value#\$\{HOME\}/}" ;;
  esac

  printf '%s\n' "$value"
}

#!/usr/bin/env bash
ACTIVE_PROFILE_FILE=".glseven-profile"

is_valid_profile_name() {
  [[ "${1:-}" =~ ^[a-z0-9_-]+$ ]]
}

profile_file() {
  printf '%s/.env.%s\n' "$1" "$2"
}

select_profile() {
  local script_dir="$1" explicit="${2:-}" saved=""
  if [ -n "$explicit" ]; then
    is_valid_profile_name "$explicit" || {
      printf 'Error: invalid profile name: %s\n' "$explicit" >&2
      return 1
    }
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -f "$script_dir/$ACTIVE_PROFILE_FILE" ]; then
    saved="$(tr -d '[:space:]' < "$script_dir/$ACTIVE_PROFILE_FILE")"
  fi
  if [ -n "$saved" ]; then
    is_valid_profile_name "$saved" || {
      printf 'Error: invalid saved profile: %s\n' "$saved" >&2
      return 1
    }
    printf '%s\n' "$saved"
    return 0
  fi
  printf 'Error: no profile selected; use --profile local|sit\n' >&2
  return 1
}

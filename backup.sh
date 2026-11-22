#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: bash backup.sh [--profile local|sit]

Back up MySQL (all databases), MongoDB (archive), and GitLab config (if present)
to ${BACKUP_DIR:-$DOCKER_VOLUME/backup}/<timestamp>/ and keep the newest
${KEEP_BACKUPS:-7} backups.
EOF
}

prune_backups() {
  local dir="$1" keep="$2" entry count=0
  [ -d "$dir" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      rm -rf "$entry"
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print | sort -r)
}

main() {
  local profile="" profile_file="" dest stamp
  PROFILE_SET=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile|-p)
        [ $# -ge 2 ] || { echo "Error: --profile requires a value" >&2; exit 2; }
        profile="$2"; PROFILE_SET=1; shift 2 ;;
      --profile=*)
        profile="${1#*=}"; PROFILE_SET=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  # shellcheck source=common/profile.sh
  source "$SCRIPT_DIR/common/profile.sh"
  PROFILE="$profile"
  require_profile_value || exit 2
  PROFILE="$(select_profile "$SCRIPT_DIR" "$PROFILE")" || exit 1
  profile_file="$(profile_file "$SCRIPT_DIR" "$PROFILE")"
  [ -f "$profile_file" ] || { echo "Error: profile file not found: $profile_file" >&2; exit 1; }

  # shellcheck source=common/docker-volume.sh
  source "$SCRIPT_DIR/common/docker-volume.sh"
  DOCKER_VOLUME="$(resolve_docker_volume "$SCRIPT_DIR" "" "$(uname -s)" "$HOME" "$profile_file")"
  BACKUP_DIR="${BACKUP_DIR:-$DOCKER_VOLUME/backup}"
  KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
  case "$KEEP_BACKUPS" in
    ''|*[!0-9]*) echo "Error: KEEP_BACKUPS must be a positive integer" >&2; exit 2 ;;
  esac
  [ "$KEEP_BACKUPS" -ge 1 ] || { echo "Error: KEEP_BACKUPS must be >= 1" >&2; exit 2; }

  umask 077
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"
  chmod 700 "$dest"
  echo "Backing up to $dest (profile: $PROFILE)"

  docker exec mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --routines --events' > "$dest/mysql.sql"
  docker exec mongo sh -c 'mongodump --archive --gzip --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > "$dest/mongo.archive.gz"
  if [ -d "$DOCKER_VOLUME/gitlab/config" ]; then
    tar -czf "$dest/gitlab-config.tar.gz" -C "$DOCKER_VOLUME/gitlab" config
  fi

  {
    echo "timestamp=$stamp"
    echo "profile=$PROFILE"
    echo "docker_volume=$DOCKER_VOLUME"
    ls -lh "$dest"
  } > "$dest/MANIFEST.txt"

  prune_backups "$BACKUP_DIR" "$KEEP_BACKUPS"
  echo "Backup complete: $dest"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

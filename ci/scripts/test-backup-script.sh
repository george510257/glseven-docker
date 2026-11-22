#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$ROOT/backup.sh" || fail "backup.sh 语法"
out="$(bash "$ROOT/backup.sh" --help 2>&1)" || fail "backup.sh --help 必须退出 0"
printf '%s\n' "$out" | grep -q 'Usage:' || fail "--help 缺少 Usage"

# shellcheck source=../../backup.sh
source "$ROOT/backup.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/glseven-backup-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
for i in 1 2 3 4 5 6 7 8 9; do
  mkdir -p "$tmp/2026010$i-000000"
done
prune_backups "$tmp" 7
count=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$count" -eq 7 ] || fail "keep 7: expected 7, got $count"
[ ! -d "$tmp/20260101-000000" ] || fail "最旧备份应被删除"

prune_backups "$tmp" 3
count=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$count" -eq 3 ] || fail "keep 3: expected 3, got $count"

printf 'backup script tests: OK\n'

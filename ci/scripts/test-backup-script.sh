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
trap 'rm -rf "$tmp"; rm -f "$ROOT/.env.backup-test-$$"' EXIT

# prune 只统计「时间戳目录 + MANIFEST」；decoy 与 partial 保留
mkdir -p "$tmp/backups"
for i in 1 2 3 4 5 6 7 8 9; do
  d="$tmp/backups/2026010$i-000000"
  mkdir -p "$d"
  : > "$d/MANIFEST.txt"
done
mkdir -p "$tmp/backups/keep-me"
mkdir -p "$tmp/backups/20260110-000000.partial"
prune_backups "$tmp/backups" 7
count=$(find "$tmp/backups" -mindepth 1 -maxdepth 1 -type d -name '2026*' ! -name '*.partial' | wc -l | tr -d ' ')
[ "$count" -eq 7 ] || fail "keep 7: expected 7, got $count"
[ ! -d "$tmp/backups/20260101-000000" ] || fail "最旧备份应被删除"
[ -d "$tmp/backups/keep-me" ] || fail "非时间戳目录不应被删除"
[ -d "$tmp/backups/20260110-000000.partial" ] || fail "partial 目录不应被删除"
prune_backups "$tmp/backups" 3
count=$(find "$tmp/backups" -mindepth 1 -maxdepth 1 -type d -name '2026*' ! -name '*.partial' | wc -l | tr -d ' ')
[ "$count" -eq 3 ] || fail "keep 3: expected 3, got $count"

# profile_has_key
printf 'DOCKER_VOLUME=/tmp/x\n' > "$tmp/with.env"
printf 'REDIS_PASSWORD=x\n' > "$tmp/without.env"
profile_has_key "$tmp/with.env" DOCKER_VOLUME || fail "profile_has_key should find DOCKER_VOLUME"
! profile_has_key "$tmp/without.env" DOCKER_VOLUME || fail "profile_has_key should reject missing DOCKER_VOLUME"

# 缺 DOCKER_VOLUME 必须快速失败
profile="$ROOT/.env.backup-test-$$"
printf 'REDIS_PASSWORD=x\n' > "$profile"
if BACKUP_DIR="$tmp/failfast" bash "$ROOT/backup.sh" --profile "backup-test-$$" >/dev/null 2>&1; then
  fail "profile missing DOCKER_VOLUME must fail"
fi

# docker 失败时只留 partial，不留正式目录
printf 'DOCKER_VOLUME=%s\n' "$tmp/vol" > "$profile"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/bin/docker"
if PATH="$tmp/bin:$PATH" BACKUP_DIR="$tmp/backups2" bash "$ROOT/backup.sh" --profile "backup-test-$$" >/dev/null 2>&1; then
  fail "docker failure must fail"
fi
partial_count=$(find "$tmp/backups2" -mindepth 1 -maxdepth 1 -type d -name '*.partial' | wc -l | tr -d ' ')
[ "$partial_count" -eq 1 ] || fail "failed backup should leave one partial dir, got $partial_count"
final_count=$(find "$tmp/backups2" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' | wc -l | tr -d ' ')
[ "$final_count" -eq 0 ] || fail "failed backup must not leave a final dir"

# partial 不占保留名额
for i in 1 2 3 4 5 6 7; do
  d="$tmp/backups2/2026010$i-000000"
  mkdir -p "$d"
  : > "$d/MANIFEST.txt"
done
prune_backups "$tmp/backups2" 7
partial_still=$(find "$tmp/backups2" -maxdepth 1 -name '*.partial' | wc -l | tr -d ' ')
[ "$partial_still" -eq 1 ] || fail "partial should not be pruned"

printf 'backup script tests: OK\n'

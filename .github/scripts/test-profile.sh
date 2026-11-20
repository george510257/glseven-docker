#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common/profile.sh
source "$ROOT/common/profile.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/glseven-profile-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

is_valid_profile_name local || fail "local should be valid"
is_valid_profile_name sit || fail "sit should be valid"
is_valid_profile_name '../x' && fail "../x must be invalid"
is_valid_profile_name 'Local' && fail "uppercase must be invalid"
is_valid_profile_name '' && fail "empty must be invalid"

[ "$(select_profile "$tmp" sit)" = "sit" ] || fail "explicit profile"
printf 'local\n' > "$tmp/.glseven-profile"
[ "$(select_profile "$tmp" '')" = "local" ] || fail "saved profile"
rm -f "$tmp/.glseven-profile"
if select_profile "$tmp" '' 2>/dev/null; then fail "missing profile must fail"; fi
if select_profile "$tmp" '../x' 2>/dev/null; then fail "invalid explicit must fail"; fi
[ "$(profile_file "$tmp" sit)" = "$tmp/.env.sit" ] || fail "profile_file path"

( PROFILE_SET=1 PROFILE=local; require_profile_value ) || fail "non-empty explicit profile must pass"
( PROFILE_SET=0 PROFILE=''; require_profile_value ) || fail "unset profile flag must pass"
if ( PROFILE_SET=1 PROFILE=''; require_profile_value ) 2>/dev/null; then
  fail "empty explicit profile must fail"
fi

printf 'profile tests: OK\n'

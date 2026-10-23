#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT_VERSION="$SCRIPT_DIR/next-version.sh"
RELEASE_NOTES="$SCRIPT_DIR/release-notes.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/glseven-release-tests.XXXXXX")"
REPO_INDEX=0
COMMIT_INDEX=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  [[ "$actual" == "$expected" ]] || fail "$context: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$context: missing '$needle'"
}

new_repo() {
  REPO_INDEX=$((REPO_INDEX + 1))
  REPO_DIR="$TMP_ROOT/repo-$REPO_INDEX"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init -q
  git config user.name "Release Test"
  git config user.email "release-test@example.com"
}

commit_file() {
  local message="$1"
  COMMIT_INDEX=$((COMMIT_INDEX + 1))
  printf '%s\n' "$COMMIT_INDEX" >> "$REPO_DIR/history.txt"
  git add history.txt
  git commit -q -m "$message"
}

init_v1() {
  commit_file "chore: init"
  git tag -a v1.0.0 -m "v1.0.0"
}

value_of() {
  local key="$1"
  local output="$2"
  printf '%s\n' "$output" | awk -v key="$key" '
    index($0, key "=") == 1 {
      sub("^[^=]*=", "")
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  '
}

assert_version_field() {
  local output="$1"
  local key="$2"
  local expected="$3"
  assert_eq "$(value_of "$key" "$output")" "$expected" "$key"
}

run_next_version_tests() {
  local output

  new_repo
  init_v1
  commit_file "fix(ci): 修复发布脚本"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.0.1
  assert_version_field "$output" tag_on_head false
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump patch

  new_repo
  init_v1
  commit_file "fix(ci): 修复发布脚本"
  commit_file "feat(portal): 增加统一入口"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.1.0
  assert_version_field "$output" bump minor

  new_repo
  init_v1
  commit_file "feat(api)!: 移除旧入口"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v2.0.0
  assert_version_field "$output" bump major

  new_repo
  init_v1
  commit_file $'chore: 调整内部结构\n\nBREAKING CHANGE: 配置格式不再兼容'
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v2.0.0
  assert_version_field "$output" bump major

  new_repo
  init_v1
  commit_file "docs: 更新说明"
  commit_file "ci: 调整校验"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release false
  assert_version_field "$output" version ""
  assert_version_field "$output" tag_on_head false
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump none

  new_repo
  init_v1
  commit_file "fix(ci): 修复发布脚本"
  git tag -a v1.0.1 -m "v1.0.1"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.0.1
  assert_version_field "$output" tag_on_head true
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump none

  new_repo
  commit_file "chore: init"
  commit_file "feat(ci): 初始化自动发布"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v0.1.0
  assert_version_field "$output" previous_tag ""
  assert_version_field "$output" bump minor

  printf 'next-version tests: OK\n'
}

case "${1:-all}" in
  next-version|all)
    run_next_version_tests
    ;;
  *)
    fail "unknown test group: $1"
    ;;
esac

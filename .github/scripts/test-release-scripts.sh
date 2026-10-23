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
  local base_branch output stderr status

  new_repo
  init_v1
  base_branch="$(git symbolic-ref --short HEAD)"
  git checkout -q -b unmerged-release
  commit_file "fix(ci): 未合并分支上的发布"
  git tag -a v1.0.1 -m "v1.0.1"
  git checkout -q "$base_branch"
  commit_file "fix(ci): 当前分支上的修复"
  status=0
  stderr="$(bash "$NEXT_VERSION" 2>&1 >/dev/null)" || status=$?
  [[ "$status" -ne 0 ]] || fail "unreachable tag collision: expected nonzero exit"
  assert_contains "$stderr" "v1.0.1" "unreachable tag collision"
  assert_contains "$stderr" "not reachable from HEAD" "unreachable tag collision"

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
  commit_file "fix(ci): 修复发布脚本"
  commit_file "feat(portal): 增加统一入口"
  commit_file $'chore: 调整内部结构\n\nBREAKING CHANGE: 配置格式不再兼容'
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v2.0.0
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump major

  new_repo
  init_v1
  commit_file "perf(ci): 优化构建流程"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.0.1
  assert_version_field "$output" bump patch

  new_repo
  init_v1
  commit_file "refactor(ci): 重构发布脚本"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.0.1
  assert_version_field "$output" bump patch

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
  commit_file "BREAKING CHANGE: 配置格式不再兼容"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release false
  assert_version_field "$output" version ""
  assert_version_field "$output" tag_on_head false
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump none

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
  git tag -a v1.2.3-rc.1 -m "v1.2.3-rc.1"
  git tag -a v1.2.3+build -m "v1.2.3+build"
  git tag -a v01.2.3 -m "v01.2.3"
  git tag -a v1.2 -m "v1.2"
  commit_file "fix(ci): 修复发布脚本"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.0.1
  assert_version_field "$output" tag_on_head false
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump patch

  new_repo
  commit_file "chore: init"
  git tag -a v1.2.3 -m "v1.2.3"
  git tag -a v1.2.3-rc.1 -m "v1.2.3-rc.1"
  git tag -a v1.2.3+build -m "v1.2.3+build"
  git tag -a v01.2.3 -m "v01.2.3"
  git tag -a v1.2 -m "v1.2"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.2.3
  assert_version_field "$output" tag_on_head true
  assert_version_field "$output" previous_tag ""
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
  init_v1
  git tag -a v1.9.0 -m "v1.9.0"
  git tag -a v1.10.0 -m "v1.10.0"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.10.0
  assert_version_field "$output" tag_on_head true
  assert_version_field "$output" previous_tag v1.9.0
  assert_version_field "$output" bump none

  new_repo
  init_v1
  commit_file "feat(ci): 准备 v1.10.0"
  git tag -a v1.10.0 -m "v1.10.0"
  commit_file "fix(ci): 回退到 v1.9.0"
  git tag -a v1.9.0 -m "v1.9.0"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.9.0
  assert_version_field "$output" tag_on_head true
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump none

  new_repo
  init_v1
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.0.0
  assert_version_field "$output" tag_on_head true
  assert_version_field "$output" previous_tag ""
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

run_release_notes_tests() {
  local output feat_hash fix_hash perf_hash refactor_hash docs_hash chore_hash expected_date
  local option status stderr

  for option in --from --to --repository; do
    status=0
    stderr="$(bash "$RELEASE_NOTES" "$option" 2>&1 >/dev/null)" || status=$?
    [[ "$status" -ne 0 ]] || fail "$option missing value: expected nonzero exit"
    assert_eq "$stderr" "missing value for $option" "$option missing value stderr"
    assert_eq "$status" "2" "$option missing value status"
  done

  new_repo
  init_v1
  commit_file "feat(portal): 增加统一入口"
  feat_hash="$(git rev-parse HEAD)"
  commit_file "fix(ci): 修复发布脚本"
  fix_hash="$(git rev-parse HEAD)"
  commit_file "perf(portal): 加速静态页面"
  perf_hash="$(git rev-parse HEAD)"
  commit_file "refactor(ci): 整理发布步骤"
  refactor_hash="$(git rev-parse HEAD)"
  commit_file "docs: 更新使用说明"
  docs_hash="$(git rev-parse HEAD)"
  commit_file "chore: 调整构建命令"
  chore_hash="$(git rev-parse HEAD)"
  git tag -a v1.1.0 -m "v1.1.0"
  output="$(
    GITHUB_SERVER_URL="https://github.example" \
      bash "$RELEASE_NOTES" \
        --from v1.0.0 \
        --to v1.1.0 \
        --repository owner/repo
  )"
  expected_date="$(TZ=Asia/Shanghai date +%Y-%m-%d)"
  assert_contains $'\n'"$output" $'\n'"发布日期：$expected_date"$'\n' "release date"
  assert_contains "$output" "## 功能" "feature heading"
  assert_contains "$output" "- feat(portal): 增加统一入口 ([${feat_hash:0:7}](https://github.example/owner/repo/commit/$feat_hash))" "feature entry hash"
  assert_contains "$output" "## 修复" "fix heading"
  assert_contains "$output" "- fix(ci): 修复发布脚本 ([${fix_hash:0:7}](https://github.example/owner/repo/commit/$fix_hash))" "fix entry hash"
  assert_contains "$output" "## 优化" "optimization heading"
  assert_contains "$output" "- perf(portal): 加速静态页面 ([${perf_hash:0:7}](https://github.example/owner/repo/commit/$perf_hash))" "perf entry hash"
  assert_contains "$output" "- refactor(ci): 整理发布步骤 ([${refactor_hash:0:7}](https://github.example/owner/repo/commit/$refactor_hash))" "refactor entry hash"
  assert_contains "$output" "## 文档" "docs heading"
  assert_contains "$output" "- docs: 更新使用说明 ([${docs_hash:0:7}](https://github.example/owner/repo/commit/$docs_hash))" "docs entry hash"
  assert_contains "$output" "## 其他" "other heading"
  assert_contains "$output" $'## 其他\n- chore: 调整构建命令 (' "other entry"
  assert_contains "$output" "- chore: 调整构建命令 ([${chore_hash:0:7}](https://github.example/owner/repo/commit/$chore_hash))" "other entry hash"
  assert_contains "$output" "https://github.example/owner/repo/compare/v1.0.0...v1.1.0" "compare link"

  new_repo
  init_v1
  commit_file $'chore: 调整内部结构\n\nBREAKING CHANGE: 配置格式不再兼容'
  git tag -a v2.0.0 -m "v2.0.0"
  output="$(
    bash "$RELEASE_NOTES" \
      --from v1.0.0 \
      --to v2.0.0 \
      --repository owner/repo
  )"
  assert_contains "$output" "## 破坏性变更" "breaking heading"
  assert_contains "$output" "chore: 调整内部结构" "breaking entry"

  new_repo
  init_v1
  commit_file "docs: 仅文档变更"
  git tag -a v1.0.1 -m "v1.0.1"
  output="$(
    bash "$RELEASE_NOTES" \
      --from v1.0.0 \
      --to v1.0.1 \
      --repository owner/repo
  )"
  assert_contains "$output" "## 文档" "docs-only heading"
  assert_contains "$output" "docs: 仅文档变更" "docs-only entry"

  new_repo
  commit_file "chore: init"
  commit_file "feat(ci): 初始化自动发布"
  output="$(
    bash "$RELEASE_NOTES" \
      --from "" \
      --to v0.1.0 \
      --repository owner/repo
  )"
  assert_contains "$output" "初始版本 v0.1.0" "initial release entry"
  assert_contains "$output" "https://github.com/owner/repo/commits/v0.1.0" "initial release link"

  printf 'release-notes tests: OK\n'
}

case "${1:-all}" in
  next-version)
    run_next_version_tests
    ;;
  release-notes)
    run_release_notes_tests
    ;;
  all)
    run_next_version_tests
    run_release_notes_tests
    ;;
  *)
    fail "unknown test group: $1"
    ;;
esac

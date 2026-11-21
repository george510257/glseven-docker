#!/usr/bin/env bash
# GitLab validate 作业的作业体：校验脚本、测试、compose 渲染、一致性与空白。
# 作业镜像基于 Alpine（无 bash），且 Runner 在 before_script 之前就选定了 /bin/sh，
# 因此 bashism 必须放在本脚本里，由 `bash ci/validate.sh` 执行。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(git ls-files -z '*.sh')

for test_script in ci/scripts/test-*.sh; do
  echo "Running $test_script"
  bash "$test_script"
done

cp .env.local.example .env.local
shopt -s nullglob
files=(*/docker-compose.yml)
[[ ${#files[@]} -gt 0 ]]
for file in "${files[@]}"; do
  echo "Validating $file"
  docker compose --env-file .env.local -f "$file" config -q
done

bash common/check-consistency.sh --strict

empty_tree="$(git hash-object -t tree /dev/null)"
if [ -n "${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}" ] &&
  git cat-file -e "$CI_MERGE_REQUEST_DIFF_BASE_SHA^{commit}" 2>/dev/null; then
  git diff --check "$CI_MERGE_REQUEST_DIFF_BASE_SHA" HEAD
elif [ -n "${CI_COMMIT_BEFORE_SHA:-}" ] &&
  ! printf '%s' "$CI_COMMIT_BEFORE_SHA" | grep -qx '0*' &&
  git cat-file -e "$CI_COMMIT_BEFORE_SHA^{commit}" 2>/dev/null; then
  git diff --check "$CI_COMMIT_BEFORE_SHA" HEAD
else
  git diff --check "$empty_tree" HEAD
fi

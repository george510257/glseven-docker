#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CO="$ROOT/.gitlab-ci.yml"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$CO" ] || fail "缺少 .gitlab-ci.yml"
grep -q 'apk add --no-cache bash git curl' "$CO" ||
  fail "before_script 必须安装 bash git curl（docker:cli 镜像无 bash/curl）"
grep -q 'GIT_DEPTH: "0"' "$CO" || fail "GIT_DEPTH 必须为 0（MR diff base 需完整历史）"
grep -q 'bash ci/validate.sh' "$CO" ||
  fail "validate 必须调用 ci/validate.sh（作业体在 /bin/sh 下解析，不能内联 bashism）"
grep -q 'bash ci/release.sh' "$CO" ||
  fail "release 必须调用 ci/release.sh（作业体在 /bin/sh 下解析）"
! grep -q 'shopt -s nullglob' "$CO" || fail "作业体不得内联 bashism（shopt）"
! grep -q 'done < <(' "$CO" || fail "作业体不得内联 bashism（进程替换）"

[ -f "$ROOT/ci/validate.sh" ] || fail "缺少 ci/validate.sh"
[ -f "$ROOT/ci/release.sh" ] || fail "缺少 ci/release.sh"
bash -n "$ROOT/ci/validate.sh"
bash -n "$ROOT/ci/release.sh"

# GitHub Actions 过渡期仍在：不得引用已改名的脚本目录
if ls "$ROOT"/.github/workflows/*.yml >/dev/null 2>&1; then
  for wf in "$ROOT"/.github/workflows/*.yml; do
    ! grep -q '\.github/scripts/' "$wf" || fail "$(basename "$wf") 仍引用 .github/scripts/"
  done
fi

# ci/validate.sh 不得覆盖工作区 .env.local
! grep -q 'cp \.env\.local\.example \.env\.local' "$ROOT/ci/validate.sh" ||
  fail "ci/validate.sh 不得直接覆盖 .env.local"
grep -q 'mktemp' "$ROOT/ci/validate.sh" ||
  fail "ci/validate.sh 应使用 mktemp 生成临时 env 文件"
grep -qE '^\.claude/?$' "$ROOT/.gitignore" ||
  fail ".gitignore 必须包含 .claude/"
for path in .env.local .env.sit .glseven-profile .claude/settings.local.json; do
  git -C "$ROOT" check-ignore -q "$path" || fail "$path 必须被 gitignore"
done

printf 'gitlab-ci tests: OK\n'

# GitHub Actions CI 与自动语义版本发布实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 glseven-docker 增加静态 GitHub Actions CI，并在合并到 `main` 后按 Conventional Commits 自动创建 SemVer tag 与中文 GitHub Release。

**Architecture:** `ci.yml` 同时作为 PR/`develop` 的校验入口与可复用 workflow；`release.yml` 在 push 到 `main` 时先调用 CI，再用仓库内 Bash 脚本计算版本和生成 notes，最后通过 `GITHUB_TOKEN` 推送 annotated tag 并创建 Release。版本计算与 notes 生成保持独立脚本边界，并通过临时 Git 仓库自动测试。

**Tech Stack:** GitHub Actions、Bash 3.2+ 兼容语法、Git、GitHub CLI (`gh`)、Docker Compose v2、Python 3 + PyYAML（仅本地 workflow 语法校验）

> **Historical implementation plan / as-built boundary:** 本文保留原始任务步骤、执行历史和部分代码快照。除明确标注 **as-built verified** 的章节外，代码块仅用于说明当时的实现，不是当前实现的复制来源；不得直接照抄。实际基线为已发布 `origin/main` 的 `a132f97`。当前 pending range 为 `a132f97..HEAD`，执行时以 `git log a132f97..HEAD` 为动态来源。历史快照 `a132f97..987e91f` 包含四个提交：`1ea301c`、`1e8fadf`、`cab6a93`、`987e91f`；当前分支到 `15b7c2d` 时已扩展为五个提交（包含 `15b7c2d`），本次修正提交会继续扩展范围，因此不硬编码 HEAD 的提交总数。权威来源始终是当前分支中的 `.github/scripts/next-version.sh`、`.github/scripts/release-notes.sh`、`.github/scripts/test-release-scripts.sh`、`.github/workflows/ci.yml` 和 `.github/workflows/release.yml`。

本节以下的 checkbox 是历史执行记录，不表示当前是否已完成。

| 项目 | 当前状态 |
|---|---|
| `v1.1.0` | 已发布；annotated tag peel 到 `a132f97` |
| `1ea301c`、`1e8fadf` | 在当前修复分支，待 PR；未合并、未发布 |
| `cab6a93` | Task 6 文档同步，待随修复分支推送 |
| `987e91f` | 后续发布与回填文档，待随修复分支推送 |
| `15b7c2d` | 发布与回填步骤加固，待随修复分支推送 |
| `a132f97..HEAD` | 当前 pending range；用 `git log a132f97..HEAD` 获取动态内容，本修正提交会扩展范围 |
| `a132f97..987e91f` | 历史快照，仅包含四个 pending 提交 |
| `v1.1.1` | 预期后续版本；发布 runbook 待执行 |

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `.github/scripts/next-version.sh` | 根据可达 SemVer tag 与 Conventional Commits 输出发布状态 |
| `.github/scripts/release-notes.sh` | 根据两个版本之间的提交生成中文 Markdown |
| `.github/scripts/test-release-scripts.sh` | 在临时 Git 仓库测试版本与 notes 脚本 |
| `.github/workflows/ci.yml` | 可复用静态 CI，以及 PR/`develop` push 入口 |
| `.github/workflows/release.yml` | `main` push 自动发布 |

设计规格：[2026-10-23-github-actions-semver-release-design.md](../specs/2026-10-23-github-actions-semver-release-design.md)

---

### Task 1: 自动版本计算

**Files:**
- Create: `.github/scripts/test-release-scripts.sh`
- Create: `.github/scripts/next-version.sh`

> **Historical snapshot (not authoritative).** 以下内容记录当时的任务步骤和代码快照，不代表完整或最终实现。当前版本计算与测试以 `.github/scripts/next-version.sh` 和 `.github/scripts/test-release-scripts.sh` 为准。

- [ ] **Step 1: 写版本计算失败测试**

创建 `.github/scripts/test-release-scripts.sh`：

```bash
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
  base_branch="$(git symbolic-ref --short HEAD)"
  git checkout -q -b docs-ci-topic
  commit_file "docs: 仅更新说明"
  commit_file "ci: 仅调整校验"
  git checkout -q "$base_branch"
  git merge -q --no-ff -m "feat(merge): 合并普通修正" docs-ci-topic
  assert_eq "$(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" "3" "docs/ci merge has two parents"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release false
  assert_version_field "$output" version ""
  assert_version_field "$output" tag_on_head false
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump none

  new_repo
  init_v1
  base_branch="$(git symbolic-ref --short HEAD)"
  git checkout -q -b feature-topic
  commit_file "feat(ci): 增加发布能力"
  git checkout -q "$base_branch"
  git merge -q --no-ff -m "docs: 合并功能分支" feature-topic
  assert_eq "$(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" "3" "feature merge has two parents"
  output="$(bash "$NEXT_VERSION")"
  assert_version_field "$output" release true
  assert_version_field "$output" version v1.1.0
  assert_version_field "$output" tag_on_head false
  assert_version_field "$output" previous_tag v1.0.0
  assert_version_field "$output" bump minor

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
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
bash .github/scripts/test-release-scripts.sh next-version
```

Expected: FAIL，`bash: .github/scripts/next-version.sh: No such file or directory`。

- [ ] **Step 3: 写最小版本计算实现**

创建 `.github/scripts/next-version.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

semver_tags() {
  git tag --merged HEAD --list 'v*' --sort=-v:refname |
    awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/'
}

tags="$(semver_tags)"
latest_tag="$(printf '%s\n' "$tags" | awk 'NF { print; exit }')"
head_tag="$(
  git tag --points-at HEAD --list 'v*' --sort=-v:refname |
    awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ { print; exit }'
)"

if [[ -n "$head_tag" ]]; then
  previous_tag="$(
    git tag --merged "$head_tag" --list 'v*' |
      awk -v head_tag="$head_tag" '
        function parse_version(tag, parts, value) {
          if (tag !~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
            return 0
          }
          value = substr(tag, 2)
          split(value, parts, ".")
          return 1
        }
        function compare_versions(left, right, i) {
          for (i = 1; i <= 3; i++) {
            if ((left[i] + 0) < (right[i] + 0)) return -1
            if ((left[i] + 0) > (right[i] + 0)) return 1
          }
          return 0
        }
        BEGIN {
          parse_version(head_tag, head_version)
          found = 0
        }
        {
          if (!parse_version($0, candidate)) next
          if (compare_versions(candidate, head_version) >= 0) next
          if (!found || compare_versions(candidate, best_version) > 0) {
            best = $0
            for (i = 1; i <= 3; i++) best_version[i] = candidate[i]
            found = 1
          }
        }
        END {
          if (found) print best
        }
      '
  )"
  printf 'release=true\n'
  printf 'version=%s\n' "$head_tag"
  printf 'tag_on_head=true\n'
  printf 'previous_tag=%s\n' "$previous_tag"
  printf 'bump=none\n'
  exit 0
fi

base_tag="${latest_tag:-v0.0.0}"
if [[ -n "$latest_tag" ]]; then
  commit_range="${latest_tag}..HEAD"
else
  commit_range="HEAD"
fi

bump="$(
  git log --no-merges --format='%B%x1e' "$commit_range" |
    awk '
      BEGIN { RS = "\036"; major = 0; minor = 0; patch = 0 }
      {
        body = $0
        sub(/^[\r\n]+/, "", body)
        split(body, lines, "\n")
        subject = lines[1]
        breaking_body = 0
        for (i = 2; i <= length(lines); i++) {
          if (lines[i] ~ /^BREAKING CHANGE: /) {
            breaking_body = 1
            break
          }
        }
        if (subject ~ /^[A-Za-z]+(\([^)]*\))?!:/ || breaking_body) {
          major = 1
        }
        if (subject ~ /^feat(\([^)]*\))?:/) {
          minor = 1
        }
        if (subject ~ /^(fix|perf|refactor)(\([^)]*\))?:/) {
          patch = 1
        }
      }
      END {
        if (major) print "major"
        else if (minor) print "minor"
        else if (patch) print "patch"
        else print "none"
      }
    '
)"

if [[ "$bump" == "none" ]]; then
  printf 'release=false\n'
  printf 'version=\n'
  printf 'tag_on_head=false\n'
  printf 'previous_tag=%s\n' "$latest_tag"
  printf 'bump=none\n'
  exit 0
fi

IFS=. read -r major minor patch <<< "${base_tag#v}"
case "$bump" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
esac

next_tag="v${major}.${minor}.${patch}"
if git rev-parse -q --verify "refs/tags/$next_tag" >/dev/null; then
  printf 'ERROR: calculated tag %s already exists but is not reachable from HEAD\n' "$next_tag" >&2
  exit 1
fi

printf 'release=true\n'
printf 'version=%s\n' "$next_tag"
printf 'tag_on_head=false\n'
printf 'previous_tag=%s\n' "$latest_tag"
printf 'bump=%s\n' "$bump"
```

- [ ] **Step 4: 运行测试确认通过**

Run:

```bash
bash .github/scripts/test-release-scripts.sh next-version
```

Expected:

```text
next-version tests: OK
```

- [ ] **Step 5: 提交版本计算**

```bash
chmod +x .github/scripts/next-version.sh .github/scripts/test-release-scripts.sh
git add .github/scripts/next-version.sh .github/scripts/test-release-scripts.sh
git commit -m "feat(ci): 新增语义版本计算"
```

### Task 2: 中文 Release Notes

**Files:**
- Create: `.github/scripts/release-notes.sh`
- Modify: `.github/scripts/test-release-scripts.sh`

> **Historical only; original executable snapshots removed.** Task 2 早期的测试和 `release-notes.sh` 快照缺少 parent-aware merge 过滤，照抄会把 conventional merge subject 写入 Release Notes，与当前实现冲突。

历史步骤保留为叙述：先添加 Release Notes 失败测试，再实现 notes 生成并补充分组测试。当前实现以 `.github/scripts/release-notes.sh` 为准：它读取每个提交的 parent 列表，跳过拥有多个 parent 的 merge commit，并跳过非 Conventional Commits；测试以 `.github/scripts/test-release-scripts.sh` 为准。

### Task 3: CI 与自动发布 Workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`

Task 3 的初始实现已随 `v1.1.0` 发布；`1ea301c` 将 checkout 更新到 v5、启用 strict consistency，并在版本脚本启用 `--no-merges`，属于当前分支上尚未合并的后续修正。以下 Step 1 和 Step 2 的 CI、prior-Release guard 与 Release classifier 片段均为 **as-built verified**，反映当前分支 workflow；完整 YAML 仍以 `.github/workflows/ci.yml` 和 `.github/workflows/release.yml` 为准。

- [ ] **Step 1: 创建可复用 CI workflow**

`.github/workflows/ci.yml` 的最终内容：

```yaml
name: CI

on:
  workflow_call:
  workflow_dispatch:
  pull_request:
    branches:
      - develop
      - main
  push:
    branches:
      - develop

permissions:
  contents: read

jobs:
  validate:
    name: Validate repository
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - name: Checkout
        uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - name: Validate shell syntax
        shell: bash
        run: |
          set -euo pipefail
          while IFS= read -r -d '' file; do
            bash -n "$file"
          done < <(git ls-files -z '*.sh')

      - name: Prepare Compose environment
        run: cp .env.example .env

      - name: Validate Compose files
        shell: bash
        run: |
          set -euo pipefail
          shopt -s nullglob
          files=(docker-compose-*.yml)
          [[ ${#files[@]} -gt 0 ]]
          for file in "${files[@]}"; do
            echo "Validating $file"
            docker compose -f "$file" config -q
          done

      - name: Check portal consistency
        run: bash common/check-consistency.sh --strict

      - name: Test release scripts
        run: bash .github/scripts/test-release-scripts.sh

      - name: Check changed lines for whitespace errors
        shell: bash
        env:
          EVENT_NAME: ${{ github.event_name }}
          BASE_REF: ${{ github.base_ref }}
          EVENT_BEFORE: ${{ github.event.before }}
        run: |
          set -euo pipefail
          empty_tree="$(git hash-object -t tree /dev/null)"
          case "$EVENT_NAME" in
            pull_request)
              git fetch --no-tags origin \
                "+refs/heads/$BASE_REF:refs/remotes/origin/$BASE_REF"
              merge_base="$(git merge-base "origin/$BASE_REF" HEAD)"
              git diff --check "$merge_base" HEAD
              ;;
            push)
              if [[ "$EVENT_BEFORE" =~ ^0+$ ]] ||
                ! git cat-file -e "$EVENT_BEFORE^{commit}" 2>/dev/null; then
                git diff --check "$empty_tree" HEAD
              else
                git diff --check "$EVENT_BEFORE" HEAD
              fi
              ;;
            *)
              git diff --check "$empty_tree" HEAD
              ;;
          esac
```

- [ ] **Step 2: 创建自动发布 workflow**

完整 YAML 为 `.github/workflows/release.yml`；以下保留不可偏离的 as-built step 顺序与判定代码。复制实现时应使用完整文件中对应 step，不能在两个 step 之间复用 shell 局部函数。

固定顺序：

1. `actions/checkout@v5`，`fetch-depth: 0`。
2. 调用 `next-version.sh` 并写入 step outputs。
3. 执行 `Guard previous release state`：除非没有 prior tag 或 `tag_on_head=true`，否则最新可达 prior tag 必须有 Release。
4. `release=true` 时生成 release notes。
5. 仅 `release=true && tag_on_head != true` 时创建并推送 annotated tag。
6. `release=true` 时分类目标 tag 的 Release：`2xx` 存在则结束，显式 `404`（HTTP 404）才创建，其余结果失败。
7. `release=false` 时报告跳过。

`Guard previous release state` 与 `Create GitHub Release` 各自定义并执行同一分类器：

```bash
classify_release_api() {
  local tag="$1"
  local status=0
  local response=""
  local http_status=""

  response="$(gh api --include \
    "repos/$GITHUB_REPOSITORY/releases/tags/$tag" 2>&1)" ||
    status=$?
  http_status="$(
    printf '%s\n' "$response" |
      awk '$1 ~ /^HTTP\// && !seen { print $2; seen = 1 }'
  )"

  if [[ "$status" -eq 0 && "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi
  if [[ "$status" -ne 0 && "$http_status" == "404" ]]; then
    return 2
  fi

  printf '%s\n' "$response" >&2
  return 1
}
```

分类器先完整捕获 `gh api --include` 输出。`awk` 不提前退出，继续消费完整响应，避免大 payload 下 `SIGPIPE` 与 `pipefail` 干扰状态判断；仅读取首个 HTTP 状态。

prior-Release invariant 的 as-built 判定：

```bash
latest_tag="$(
  git tag --merged HEAD --list 'v*' --sort=-v:refname |
    awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ { print; exit }'
)"

if [[ -z "$latest_tag" || "$TAG_ON_HEAD" == "true" ]]; then
  exit 0
fi

classification=0
classify_release_api "$latest_tag" || classification=$?
case "$classification" in
  0)
    ;;
  2)
    printf 'Latest tag %s has no GitHub Release; the missing prior Release must be published before newer versions are released. For legacy tags, backfill it from the annotated tag message.\n' "$latest_tag" >&2
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
```

目标 Release 的 as-built 判定；只有 `classification == 2`（显式 `404`）才创建：

```bash
classification=0
classify_release_api "$VERSION" || classification=$?
case "$classification" in
  0)
    echo "GitHub Release $VERSION already exists"
    ;;
  2)
    gh release create "$VERSION" \
      --verify-tag \
      --title "$VERSION" \
      --notes-file /tmp/release-notes.md
    ;;
  *)
    exit 1
    ;;
esac
```

- [ ] **Step 3: 校验 workflow YAML 与脚本语法**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import yaml

for path in (
    Path(".github/workflows/ci.yml"),
    Path(".github/workflows/release.yml"),
):
    yaml.safe_load(path.read_text())
    print(f"{path}: YAML OK")
PY
for file in .github/scripts/*.sh; do bash -n "$file"; done
```

Expected:

```text
.github/workflows/ci.yml: YAML OK
.github/workflows/release.yml: YAML OK
```

- [ ] **Step 4: 运行仓库完整静态校验**

Run:

```bash
bash .github/scripts/test-release-scripts.sh
for file in docker-compose-*.yml; do docker compose -f "$file" config -q; done
bash common/check-consistency.sh --strict
git diff --check
```

Expected:

```text
next-version tests: OK
release-notes tests: OK
  consistency: OK（25 个服务的门户/代理/hosts 同步点齐全）
```

- [ ] **Step 5: 提交 workflows**

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "feat(ci): 接入自动校验与发布"
```

### Task 4: 远端发布与幂等验收

**Files:**
- Verify only; no repository file changes.

以下记录实际已执行的发布路径；PR、tag 和 run 编号是固定验收证据，不应在发布完成后原样重放。

- [ ] **Step 1: 确认 GitHub 登录与 workflow 写权限**

Run:

```bash
gh auth status
gh api repos/george510257/glseven-docker/actions/permissions/workflow \
  --jq '.default_workflow_permissions'
```

Expected: `gh` 已登录；第二行输出 `write`。若输出 `read`，停止发布并请仓库管理员将 Actions Workflow Permissions 改为 `Read and write`。

- [ ] **Step 2: 通过功能分支 PR 合入 `develop`**

Run:

```bash
gh pr create --base develop --head codex/ci-semver-release \
  --title "feat(ci): 接入自动语义版本发布" \
  --body "新增静态 CI 与 main 自动语义版本发布。"
gh pr checks 3 --watch
gh pr merge 3 --merge
```

实际执行结果：PR #3 head `061648290630e613b1c350c1006e71fcc5582b2e` 的 `Validate repository` check 成功，随后以 merge commit `7b2d299867ef5a034f5918233b9df915b8605bcb` 合入 `develop`。未直接 push `develop`。

- [ ] **Step 3: 在 `develop` -> `main` 前补建 prior Release（历史实例为 `v1.0.0`）**

Run:

```bash
set -euo pipefail

backfill_missing_release() {
  local missing_tag="${MISSING_TAG:?set MISSING_TAG to the tag reported by the prior-Release guard}"
  local repository="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
  local command_status=0
  local response=""
  local http_status=""
  local tag_type=""

  [[ -n "$repository" ]] || {
    printf 'Cannot determine the GitHub repository.\n' >&2
    return 1
  }

  response="$(
    gh api --include \
      "repos/$repository/releases/tags/$missing_tag" 2>&1
  )" || command_status=$?
  http_status="$(
    printf '%s\n' "$response" |
      awk '$1 ~ /^HTTP\// && !seen { print $2; seen = 1 }'
  )"

  if [[ "$command_status" -eq 0 && "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    echo "Release $missing_tag already exists"
    return 0
  fi
  if [[ "$command_status" -ne 0 && "$http_status" == "404" ]]; then
    git fetch --tags origin
    if ! tag_type="$(git cat-file -t "$missing_tag" 2>/dev/null)"; then
      printf '%s is missing; refusing backfill.\n' "$missing_tag" >&2
      return 1
    fi
    if [[ "$tag_type" != "tag" ]]; then
      printf '%s is not an annotated tag; refusing backfill.\n' "$missing_tag" >&2
      return 1
    fi
    gh release create "$missing_tag" \
      --verify-tag \
      --title "$missing_tag" \
      --notes-from-tag || return $?
    return 0
  fi

  printf '%s\n' "$response" >&2
  printf 'Cannot determine Release state for %s; refusing backfill.\n' "$missing_tag" >&2
  return 1
}

MISSING_TAG=v1.0.0
backfill_missing_release
```

Expected: 只有显式 `404` 且 `git cat-file -t` 为 `tag` 才补建；其他错误失败关闭。实际已按该流程补建 `v1.0.0` Release，使用 annotated tag message 作为 notes。以后由 guard 报告其他缺失 tag 时，将报告中的 tag 赋给 `MISSING_TAG` 并重跑此函数。

- [ ] **Step 4: 创建并合并 `develop` 到 `main` 的 PR**

Run:

```bash
gh pr create --base main --head develop \
  --title "chore(release): 发布自动语义版本流程" \
  --body "新增静态 CI 与 main 自动语义版本发布；合并后预期创建 v1.1.0。"
gh pr checks 4 --watch
gh pr merge 4 --merge
```

实际执行结果：PR #4 head `7b2d299867ef5a034f5918233b9df915b8605bcb` 的 `Validate repository` check 成功，随后以 merge commit `a132f97ed190e3ab2e41ea1e38938c63d7630e6a` 合入 `main`。

- [ ] **Step 5: 验证 Release run 与两次 attempt**

Run:

```bash
gh api repos/george510257/glseven-docker/actions/runs/39899968642 \
  --jq '{status,conclusion,run_attempt,head_sha,url}'
gh api repos/george510257/glseven-docker/actions/runs/39899968642/attempts/1 \
  --jq '{run_attempt,status,conclusion,head_sha}'
gh api repos/george510257/glseven-docker/actions/runs/39899968642/attempts/2 \
  --jq '{run_attempt,status,conclusion,head_sha}'
```

Expected:

- run `39899968642` 最终 `run_attempt=2`、`status=completed`、`conclusion=success`，head 为 `a132f97ed190e3ab2e41ea1e38938c63d7630e6a`。
- attempt 1 与 attempt 2 的 `status` 均为 `completed`，`conclusion` 均为 `success`。

- [ ] **Step 6: 验证 annotated tag、peel 后的 commit 与 Release**

Run:

```bash
git fetch --tags origin
git cat-file -t v1.1.0
git rev-parse v1.1.0
git rev-parse v1.1.0^{}
git rev-parse origin/main
gh api repos/george510257/glseven-docker/releases/tags/v1.1.0 \
  --jq '{tag_name,name,draft,prerelease,url,body}'
```

Expected:

- `git cat-file -t v1.1.0` 输出 `tag`。
- tag object 为 `b5c1a26e5ecf0900f65715b77bf1f298cd7c5070`。
- `git rev-parse v1.1.0^{}` 与 `origin/main` 均为 `a132f97ed190e3ab2e41ea1e38938c63d7630e6a`。
- Release 的 `tag_name`、`name` 均为 `v1.1.0`，`draft=false`、`prerelease=false`。
- Release 正文含 `功能`、`修复`、`完整变更` 与 `v1.0.0...v1.1.0` 比较链接。

- [ ] **Step 7: 重跑 Release workflow 验证幂等**

Run:

```bash
gh run rerun 39899968642
gh run watch 39899968642 --exit-status
git fetch --tags origin
git tag --list 'v1.1.*'
gh api repos/george510257/glseven-docker/releases \
  --paginate --jq '.[].tag_name' | sort
```

Expected:

- attempt 2 成功。
- `git tag --list 'v1.1.*'` 仍只有 `v1.1.0`。
- Release 列表按 tag 排序后仅为 `v1.0.0`、`v1.1.0`，没有重复 `v1.1.0` Release。

- [ ] **Step 8: 后续修复分支状态**

`1ea301c` 与 `1e8fadf` 位于 `codex/ci-semver-release-fixes`，基于 `a132f97`；它们将 checkout v5、strict consistency、`--no-merges` 和 strict 失败摘要带入后续实现，但仍需通过 PR 合入 `develop` 和 `main`。在合并前，不得把这两个提交描述为 `v1.1.0` 的已发布内容。

---

## 后续修复发布 runbook（预期 v1.1.1）

> **状态：PENDING，尚未执行。** 当前 pending range 为 `a132f97..HEAD`，执行时以 `git log a132f97..HEAD` 为准。历史快照 `a132f97..987e91f` 包含四个提交：`1ea301c`、`1e8fadf`、`cab6a93`、`987e91f`；到 `15b7c2d` 时范围已包含五个提交，本次修正提交会继续扩展，因此不硬编码 HEAD 总数。`1ea301c`、`1e8fadf` 仍未合并或发布。基于 `v1.1.0` 运行 `bash .github/scripts/next-version.sh` 当前得到 `version=v1.1.1`、`previous_tag=v1.1.0`、`bump=patch`；merge commit 不参与分类，普通 `fix` / `ci` 提交参与。

以下步骤在同一 Bash session 中按顺序执行。每个 sequence block 都启用 `set -euo pipefail`；PR checks、merge、run lookup 或 watch 任一步失败，后续命令不会继续。

1. 推送修复分支：

```bash
set -euo pipefail
git push -u origin codex/ci-semver-release-fixes
```

2. 创建到 `develop` 的 PR：

```bash
set -euo pipefail
fix_pr_url="$(
  gh pr create \
    --base develop \
    --head codex/ci-semver-release-fixes \
    --title "fix(ci): 修正语义版本发布与一致性门禁" \
    --body "同步已验收的 CI/SemVer 文档，并合入 merge 排除、strict consistency、checkout v5 与失败摘要修正。"
)"
fix_pr="${fix_pr_url##*/}"
```

3. 等待 CI、检查结果，再 merge 到 `develop`：

```bash
set -euo pipefail
gh pr checks "$fix_pr" --watch --fail-fast
gh pr merge "$fix_pr" --merge
fix_merge_sha=""
for attempt in {1..12}; do
  fix_merge_sha="$(
    gh pr view "$fix_pr" --json mergeCommit --jq '.mergeCommit.oid // empty'
  )"
  if [[ -n "$fix_merge_sha" ]]; then
    break
  fi
  sleep 5
done
[[ -n "$fix_merge_sha" ]] || {
  echo "fix PR merge commit is not available" >&2
  exit 1
}
```

4. 按 `fix_merge_sha` 查找 merge 后的 `develop` push CI，短暂重试后 watch：

```bash
set -euo pipefail
develop_ci_run=""
for attempt in {1..12}; do
  develop_ci_run="$(
    gh run list \
      --workflow ci.yml \
      --branch develop \
      --commit "$fix_merge_sha" \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId // empty'
  )"
  if [[ -n "$develop_ci_run" ]]; then
    break
  fi
  sleep 5
done
[[ -n "$develop_ci_run" ]] || {
  echo "develop CI run for $fix_merge_sha was not indexed" >&2
  exit 1
}
gh run watch "$develop_ci_run" --exit-status
gh run view "$develop_ci_run" --json status,conclusion,url
```

5. 创建 `develop` -> `main` PR，等待 CI 后 merge：

```bash
set -euo pipefail
release_pr_url="$(
  gh pr create \
    --base main \
    --head develop \
    --title "chore(release): 发布 CI 修复并生成 v1.1.1" \
    --body "合入已通过 develop CI 的发布修复；预期自动生成 v1.1.1。"
)"
release_pr="${release_pr_url##*/}"
gh pr checks "$release_pr" --watch --fail-fast
gh pr merge "$release_pr" --merge
release_merge_sha=""
for attempt in {1..12}; do
  release_merge_sha="$(
    gh pr view "$release_pr" --json mergeCommit --jq '.mergeCommit.oid // empty'
  )"
  if [[ -n "$release_merge_sha" ]]; then
    break
  fi
  sleep 5
done
[[ -n "$release_merge_sha" ]] || {
  echo "release PR merge commit is not available" >&2
  exit 1
}
```

6. 按 `release_merge_sha` 查找 `release.yml`，短暂重试后 watch 并确认创建 `v1.1.1`：

```bash
set -euo pipefail
release_run=""
for attempt in {1..12}; do
  release_run="$(
    gh run list \
      --workflow release.yml \
      --branch main \
      --commit "$release_merge_sha" \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId // empty'
  )"
  if [[ -n "$release_run" ]]; then
    break
  fi
  sleep 5
done
[[ -n "$release_run" ]] || {
  echo "release run for $release_merge_sha was not indexed" >&2
  exit 1
}
gh run watch "$release_run" --exit-status
gh run view "$release_run" --json status,conclusion,headSha,url
git fetch --tags origin
git tag --list 'v1.1.*'
```

Expected: Release run 成功；`v1.1.1` 出现，`v1.1.0` 保留；merge commit 本身没有导致额外 bump。

7. 验证 annotated tag peel、Release body 与比较链接：

```bash
set -euo pipefail
git fetch --tags origin
git cat-file -t v1.1.1
git rev-parse v1.1.1^{}
git rev-parse origin/main
gh api repos/george510257/glseven-docker/releases/tags/v1.1.1 \
  --jq '{tag_name,name,draft,prerelease,url,body}'
```

Expected: `git cat-file -t` 输出 `tag`；peel 后的 commit 与 `origin/main` 一致；Release 的 tag/name 为 `v1.1.1`，`draft=false`、`prerelease=false`；body 含 `修复`、文档变更和 `v1.1.0...v1.1.1` 比较链接。

8. 重跑同一 Release workflow，验证幂等：

```bash
set -euo pipefail
gh run rerun "$release_run"
gh run watch "$release_run" --exit-status
git fetch --tags origin
git tag --list 'v1.1.*'
gh api repos/george510257/glseven-docker/releases \
  --paginate --jq '.[].tag_name' | sort
```

Expected: 重跑成功；tag 仅有 `v1.1.0`、`v1.1.1`，没有 `v1.1.2`；`v1.1.1` Release 只有一个，不产生重复。

9. 可选：发布后执行 docs-only `main` 合并 dry run，确认 `release=false`：

```bash
set -euo pipefail
git fetch origin
git switch -c docs/ci-release-dry-run-20261023 origin/main
printf '%s\n' '# CI release dry run' > docs/ci-release-dry-run.md
git add docs/ci-release-dry-run.md
git commit -m "docs(ci): 验证无版本发布"
git push -u origin docs/ci-release-dry-run-20261023
dry_pr_url="$(
  gh pr create \
    --base main \
    --head docs/ci-release-dry-run-20261023 \
    --title "docs(ci): 验证无版本发布" \
    --body "仅文档变更；预期 Release workflow 跳过，不创建新 tag。"
)"
dry_pr="${dry_pr_url##*/}"
gh pr checks "$dry_pr" --watch --fail-fast
gh pr merge "$dry_pr" --merge
dry_merge_sha=""
for attempt in {1..12}; do
  dry_merge_sha="$(
    gh pr view "$dry_pr" --json mergeCommit --jq '.mergeCommit.oid // empty'
  )"
  if [[ -n "$dry_merge_sha" ]]; then
    break
  fi
  sleep 5
done
[[ -n "$dry_merge_sha" ]] || {
  echo "dry-run PR merge commit is not available" >&2
  exit 1
}
dry_release_run=""
for attempt in {1..12}; do
  dry_release_run="$(
    gh run list \
      --workflow release.yml \
      --branch main \
      --commit "$dry_merge_sha" \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId // empty'
  )"
  if [[ -n "$dry_release_run" ]]; then
    break
  fi
  sleep 5
done
[[ -n "$dry_release_run" ]] || {
  echo "release dry-run for $dry_merge_sha was not indexed" >&2
  exit 1
}
gh run watch "$dry_release_run" --exit-status
# 非 quiet 模式会消费完整 stdin，避免 pipefail 下提前关闭管道。
if gh run view "$dry_release_run" --log |
  rg 'No releasable Conventional Commits found; skipping release\.' >/dev/null; then
  echo "docs-only release correctly skipped"
else
  echo "docs-only release did not report a skip" >&2
  exit 1
fi
git fetch --tags origin
git tag --list 'v1.1.*'
if git rev-parse -q --verify refs/tags/v1.1.2 >/dev/null; then
  echo "unexpected v1.1.2 tag" >&2
  exit 1
fi
```

Expected: run 成功且输出跳过 release；`rg` 匹配返回 `0`，无匹配返回 `1` 并进入失败分支，不出现假 `141`；`next-version.sh` 返回 `release=false` 语义；没有 `v1.1.2` 或新 Release。若需要删除 dry-run 文件，使用另一条 docs-only PR，同样不应产生版本。

---

## 计划自检

**Spec coverage**

- CI 触发、只读权限与静态检查：Task 3 Step 1。
- Release 触发、写权限、串行 concurrency：Task 3 Step 2。
- SemVer 基线与 bump 优先级：Task 1 Step 3。
- merge commit 排除与 merge 内普通提交仍参与：Task 1 Step 1、Step 3。
- 跳过与 tag-on-HEAD 幂等：Task 1 Step 3、Task 4 Step 7。
- 中文分组 Release Notes：Task 2 历史说明与 `.github/scripts/release-notes.sh`。
- prior-Release invariant、显式 `404` 与失败关闭：Task 3 Step 2、Task 4 Step 3。
- 失败后重跑补 Release：Task 3 Step 2、Task 4 Step 5 至 Step 7。
- 实际 PR #3、PR #4 与 `v1.1.0` 发布：Task 4 Step 2 至 Step 7。
- 后续修复仍待 PR：Task 4 Step 8。
- 通用 `MISSING_TAG` 回填：Task 4 Step 3 与设计文档第 7 节。
- 预期 `v1.1.1` 的后续发布、幂等与 docs-only dry run：后续修复发布 runbook。
- pending range 与 merge-SHA run 轮询：顶部状态表及后续修复发布 runbook。
- 不引入 npm、第三方发布 Action、PAT：文件结构与 workflows 均只使用 `actions/checkout`、Git 与 `gh`。

**Placeholder scan**

除明确标注 `PENDING` 的 `v1.1.1` runbook 外，计划中的执行记录、路径、脚本、workflow 命令与预期输出均为具体内容，没有占位符。

**Type and interface consistency**

`next-version.sh` 固定输出 `release`、`version`、`tag_on_head`、`previous_tag`、`bump`；`release.yml` 只读取这些键。`release-notes.sh` 固定接收 `--from`、`--to`、`--repository`，测试与 workflow 调用参数一致。CI 使用 `actions/checkout@v5`、`common/check-consistency.sh --strict` 和空树 whitespace fallback；release workflow 的 prior-Release guard 与 Create Release step 对 API 结果采用相同的退出码与 HTTP 状态分类。

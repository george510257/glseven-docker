#!/usr/bin/env bash
set -euo pipefail

from=""
to=""
repository=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ $# -ge 2 && "$2" != --* ]] || {
        printf 'missing value for --from\n' >&2
        exit 2
      }
      from="$2"
      shift 2
      ;;
    --to)
      [[ $# -ge 2 && "$2" != --* ]] || {
        printf 'missing value for --to\n' >&2
        exit 2
      }
      to="$2"
      shift 2
      ;;
    --repository)
      [[ $# -ge 2 && "$2" != --* ]] || {
        printf 'missing value for --repository\n' >&2
        exit 2
      }
      repository="$2"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$to" ]] || {
  printf 'missing --to\n' >&2
  exit 2
}
[[ -n "$repository" ]] || {
  printf 'missing --repository\n' >&2
  exit 2
}

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$from" ]]; then
  if git rev-parse -q --verify "refs/tags/$to" >/dev/null; then
    commit_range="$from..$to"
  else
    commit_range="$from..HEAD"
  fi
else
  if git rev-parse -q --verify "refs/tags/$to" >/dev/null; then
    commit_range="$to"
  else
    commit_range="HEAD"
  fi
fi

server="${GITHUB_SERVER_URL:-https://github.com}"
server="${server%/}"

printf '发布日期：%s\n\n' "$(TZ=Asia/Shanghai date +%Y-%m-%d)"

git log --reverse --format='%H%x1f%P%x1f%s%x1f%b%x1e' "$commit_range" |
  awk -v server="$server" -v repo="$repository" -v from="$from" -v to="$to" '
    function section(title, entries, count, i) {
      if (count == 0) return
      print "## " title
      for (i = 1; i <= count; i++) print entries[i]
      print ""
    }

    BEGIN {
      RS = "\036"
      FS = "\037"
      breaking_count = 0
      feature_count = 0
      fix_count = 0
      optimization_count = 0
      docs_count = 0
      other_count = 0
    }

    {
      hash = $1
      sub(/^[[:space:]]+/, "", hash)
      sub(/[[:space:]]+$/, "", hash)
      parents = $2
      subject = $3
      body = $4
      if (hash == "") next
      if (split(parents, parent_hashes, " ") > 1) next

      commit_url = server "/" repo "/commit/" hash
      link = "- " subject " ([" substr(hash, 1, 7) "](" commit_url "))"
      conventional = (subject ~ /^[A-Za-z]+(\([^)]*\))?!?:/)
      if (!conventional) next
      breaking = (body ~ /(^|\n)BREAKING CHANGE: /) ||
                 (subject ~ /^[A-Za-z]+(\([^)]*\))?!:/)

      if (breaking) {
        breaking_entries[++breaking_count] = link
      }
      if (subject ~ /^feat(\([^)]*\))?!?:/) {
        feature_entries[++feature_count] = link
      } else if (subject ~ /^(fix)(\([^)]*\))?!?:/) {
        fix_entries[++fix_count] = link
      } else if (subject ~ /^(perf|refactor)(\([^)]*\))?!?:/) {
        optimization_entries[++optimization_count] = link
      } else if (subject ~ /^docs(\([^)]*\))?!?:/) {
        docs_entries[++docs_count] = link
      } else if (subject ~ /^[A-Za-z]+(\([^)]*\))?!?:/) {
        other_entries[++other_count] = link
      }
    }

    END {
      section("破坏性变更", breaking_entries, breaking_count)
      section("功能", feature_entries, feature_count)
      section("修复", fix_entries, fix_count)
      section("优化", optimization_entries, optimization_count)
      section("文档", docs_entries, docs_count)
      section("其他", other_entries, other_count)

      print "## 完整变更"
      if (from != "") {
        compare_url = server "/" repo "/compare/" from "..." to
        print "- [" from "..." to "](" compare_url ")"
      } else {
        print "- [初始版本 " to "](" server "/" repo "/commits/" to ")"
      }
    }
  '

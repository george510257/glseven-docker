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
  head_commit="$(git rev-parse "$head_tag^{commit}")"
  previous_tag="$(
    git tag --merged "$head_tag" --list 'v*' --sort=-v:refname |
      awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/' |
      while IFS= read -r tag; do
        if [[ "$(git rev-parse "$tag^{commit}")" == "$head_commit" ]]; then
          continue
        fi
        printf '%s\n' "$tag"
        break
      done
  )"
  if [[ -z "$previous_tag" ]]; then
    previous_tag="$(
      git tag --merged "$head_tag" --list 'v*' --sort=v:refname |
        awk '/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/' |
        while IFS= read -r tag; do
          if [[ "$tag" != "$head_tag" &&
                "$(git rev-parse "$tag^{commit}")" == "$head_commit" ]]; then
            printf '%s\n' "$tag"
            break
          fi
        done
    )"
  fi
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
  git log --format='%B%x1e' "$commit_range" |
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

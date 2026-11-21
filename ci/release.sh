#!/usr/bin/env bash
# GitLab release 作业的作业体：计算版本、生成说明、创建 annotated tag 与 Release。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

output="$(bash ci/scripts/next-version.sh)"
printf '%s\n' "$output"
eval "$output"

if [ "$release" != "true" ] || [ "$tag_on_head" = "true" ]; then
  echo "No releasable Conventional Commits; skipping release."
  exit 0
fi

bash ci/scripts/release-notes.sh \
  --from "$previous_tag" --to "$version" \
  --repository "$CI_PROJECT_PATH" --provider gitlab \
  > /tmp/release-notes.md

: "${RELEASE_TOKEN:?RELEASE_TOKEN is required}"
curl -fsS --connect-timeout 5 --max-time 30 --request POST \
  --header "PRIVATE-TOKEN: $RELEASE_TOKEN" \
  --data-urlencode "tag_name=$version" \
  --data-urlencode "ref=$CI_COMMIT_SHA" \
  --data-urlencode "message=$version" \
  "$CI_API_V4_URL/projects/$CI_PROJECT_ID/repository/tags" >/dev/null

curl -fsS --connect-timeout 5 --max-time 30 --request POST \
  --header "PRIVATE-TOKEN: $RELEASE_TOKEN" \
  --data-urlencode "name=$version" \
  --data-urlencode "tag_name=$version" \
  --data-urlencode "description@/tmp/release-notes.md" \
  "$CI_API_V4_URL/projects/$CI_PROJECT_ID/releases" >/dev/null

echo "Released $version"

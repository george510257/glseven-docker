#!/usr/bin/env bash
# sit 部署：把宿主仓库切到目标提交，重放编排并验证。
# 由 GitLab CI 的 deploy:sit / deploy:sit:rollback 调用；也支持 DRY_RUN=1 本地演练。
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/vol1/1000/glseven-docker}"
DEPLOY_UID="${DEPLOY_UID:-1000}"
TARGET_SHA="${TARGET_SHA:-${CI_COMMIT_SHA:-}}"
REPO_URL="${CI_REPOSITORY_URL:-}"
DRY_RUN="${DRY_RUN:-0}"
# root 在作业容器里对 admin 属主的宿主仓库会触发 git 的 dubious ownership，
# 每条 git 命令显式信任部署目录。
GIT_SAFE=(-c safe.directory="$DEPLOY_DIR")

[[ -n "$TARGET_SHA" ]] || { echo "Error: TARGET_SHA (or CI_COMMIT_SHA) is required" >&2; exit 2; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -n "$REPO_URL" ]] || { echo "Error: CI_REPOSITORY_URL is required" >&2; exit 2; }
  run git "${GIT_SAFE[@]}" -C "$DEPLOY_DIR" fetch --prune "$REPO_URL" \
    "+refs/heads/develop:refs/remotes/origin/develop" "+refs/tags/*:refs/tags/*"
  git "${GIT_SAFE[@]}" -C "$DEPLOY_DIR" cat-file -e "$TARGET_SHA^{commit}" ||
    { echo "Error: $TARGET_SHA is not reachable from develop or tags" >&2; exit 1; }
  run git "${GIT_SAFE[@]}" -C "$DEPLOY_DIR" checkout -f "$TARGET_SHA"
  run chown -R "$DEPLOY_UID:$DEPLOY_UID" "$DEPLOY_DIR"
else
  run git "${GIT_SAFE[@]}" -C "$DEPLOY_DIR" fetch --prune "$REPO_URL" \
    "+refs/heads/develop:refs/remotes/origin/develop" "+refs/tags/*:refs/tags/*"
  run git "${GIT_SAFE[@]}" -C "$DEPLOY_DIR" checkout -f "$TARGET_SHA"
  run chown -R "$DEPLOY_UID:$DEPLOY_UID" "$DEPLOY_DIR"
fi

run bash "$DEPLOY_DIR/startup.sh" --profile sit
run docker exec nginx nginx -t
run docker exec nginx nginx -s reload
run bash "$DEPLOY_DIR/ci/smoke-test.sh"

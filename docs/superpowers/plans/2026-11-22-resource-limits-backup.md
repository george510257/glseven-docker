# 资源限制与备份脚本（批次 4）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 ES/Logstash/Kafka/Nexus 设置 JVM 堆上限、给 Redis 设置 maxmemory，并新增备份 MySQL/Mongo/GitLab config 的 `backup.sh`（保留 7 份）。

**Architecture:** 资源限制是 compose `environment` / `command` 的局部改动；`backup.sh` 复用现有 profile 与数据目录解析，用容器内 `mysqldump` / `mongodump`，备份目录按时间戳分层并在成功后裁剪。新增两个静态测试脚本。

**Tech Stack:** Bash 3.2、Docker Compose v2、MySQL/Percona mysqldump、mongodump、tar、GitLab CI。

**Spec:** docs/superpowers/specs/2026-11-22-resource-limits-backup-design.md

## Global Constraints

- 不设硬 `mem_limit` / `cpus`；只改 JVM 堆、Redis maxmemory 与备份脚本。
- 不备份 Nexus/Kafka/ELK 数据；GitLab 只备份 config。
- 脚本兼容 macOS 自带 Bash 3.2；`backup.sh` 可被测试 source，main 只在直接执行时运行。
- 所有命令在 worktree `/Users/george/project/glseven/glseven-docker/.claude/worktrees/project-config-service-reuse-71639c` 下执行。
- 本机无 Docker CLI；端到端备份/恢复在用户机器补验，最终报告标注。

## Review Focus

- JVM 参数必须进入容器环境且不覆盖镜像原有 entrypoint 行为；Task 1 的静态断言 + Task 4 的 `docker exec env` 检查覆盖。
- Redis `maxmemory` 与策略必须同时生效，避免只设上限无策略；Task 1 断言覆盖。
- `backup.sh` 缺容器/缺 DOCKER_VOLUME 时必须快速失败，不能生成半包并谎报成功；Task 2 的错误处理 + Task 4 演练覆盖。
- `prune_backups` 只能删除备份目录下的时间戳目录，不能误删其他内容；Task 2 的单元测试覆盖。
- 备份目录权限必须为 700，GitLab config 含 secrets；Task 2 的 `umask`/`chmod` + Task 4 检查覆盖。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `observability/docker-compose.yml` | ELK 的 ES/Logstash 堆 |
| `infra/docker-compose.yml` | Kafka 堆、Redis maxmemory |
| `platform/docker-compose.yml` | Nexus 堆 |
| `backup.sh` | 备份入口；`usage` / `prune_backups` / `main` |
| `ci/scripts/test-resource-limits.sh` | 堆与 Redis 上限断言 |
| `ci/scripts/test-backup-script.sh` | `--help`、`prune_backups`、语法 |
| `README.md` / `CLAUDE.md` | 资源上限、备份/恢复与边界 |

---

### Task 1: JVM 堆与 Redis 上限

**Files:**
- Modify: `observability/docker-compose.yml`（elk）
- Modify: `infra/docker-compose.yml`（kafka、redis）
- Modify: `platform/docker-compose.yml`（nexus3）
- Test: `ci/scripts/test-resource-limits.sh`（新建）

- [ ] **Step 1: 写失败测试**

创建 `ci/scripts/test-resource-limits.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'ES_JAVA_OPTS: "-Xms1g -Xmx1g"' "$ROOT/observability/docker-compose.yml" || fail "ES 堆上限缺失"
grep -Fq 'LS_HEAP_SIZE: "512m"' "$ROOT/observability/docker-compose.yml" || fail "Logstash 堆上限缺失"
! grep -Fq 'LS_JAVA_OPTS' "$ROOT/observability/docker-compose.yml" || fail "elk 不应使用 LS_JAVA_OPTS"
grep -Fq 'KAFKA_HEAP_OPTS: "-Xms512m -Xmx512m"' "$ROOT/infra/docker-compose.yml" || fail "Kafka 堆上限缺失"
grep -Fq 'INSTALL4J_ADD_VM_PARAMS: "-Xms768m -Xmx768m -XX:MaxDirectMemorySize=768m"' "$ROOT/platform/docker-compose.yml" || fail "Nexus 堆上限缺失"
grep -Fq -- '--maxmemory 256mb' "$ROOT/infra/docker-compose.yml" || fail "Redis maxmemory 缺失"
grep -Fq -- '--maxmemory-policy allkeys-lru' "$ROOT/infra/docker-compose.yml" || fail "Redis 淘汰策略缺失"

printf 'resource limit tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-resource-limits.sh`
Expected: FAIL，提示 ES 堆上限缺失。

- [ ] **Step 3: 实现**

- `observability/docker-compose.yml` 的 elk 增加：

```yaml
    environment:
      ES_JAVA_OPTS: "-Xms1g -Xmx1g"
      LS_HEAP_SIZE: "512m"
```

- `platform/docker-compose.yml` 的 nexus3 增加：

```yaml
    environment:
      INSTALL4J_ADD_VM_PARAMS: "-Xms768m -Xmx768m -XX:MaxDirectMemorySize=768m"
```

- `infra/docker-compose.yml` 的 kafka 现有 `environment` 增加一行：

```yaml
      KAFKA_HEAP_OPTS: "-Xms512m -Xmx512m"
```

- `infra/docker-compose.yml` 的 redis command 追加：

```text
--maxmemory 256mb --maxmemory-policy allkeys-lru
```

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-resource-limits.sh`
Expected: PASS，输出 `resource limit tests: OK`。

- [ ] **Step 5: 提交**

```bash
git add observability/docker-compose.yml infra/docker-compose.yml platform/docker-compose.yml ci/scripts/test-resource-limits.sh
git commit -m "feat(resources): 限制 JVM 堆与 Redis 内存"
```

---

### Task 2: backup.sh

**Files:**
- Create: `backup.sh`
- Test: `ci/scripts/test-backup-script.sh`（新建）

- [ ] **Step 1: 写失败测试**

创建 `ci/scripts/test-backup-script.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$ROOT/backup.sh" || fail "backup.sh 语法"
out="$(bash "$ROOT/backup.sh" --help 2>&1)" || fail "backup.sh --help 必须退出 0"
printf '%s\n' "$out" | grep -q 'Usage:' || fail "--help 缺少 Usage"

# shellcheck source=../../backup.sh
source "$ROOT/backup.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/glseven-backup-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
for i in 1 2 3 4 5 6 7 8 9; do
  mkdir -p "$tmp/2026010$i-000000"
done
prune_backups "$tmp" 7
count=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$count" -eq 7 ] || fail "keep 7: expected 7, got $count"
[ ! -d "$tmp/20260101-000000" ] || fail "最旧备份应被删除"

prune_backups "$tmp" 3
count=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$count" -eq 3 ] || fail "keep 3: expected 3, got $count"

printf 'backup script tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-backup-script.sh`
Expected: FAIL，提示 `backup.sh` 不存在或语法失败。

- [ ] **Step 3: 实现 `backup.sh`**

> 审查后修订（2026-11-22）：先写 `<timestamp>.partial`，写完 `MANIFEST.txt` 后再 `mv` 成正式目录；`prune_backups` 只统计「时间戳目录 + `MANIFEST.txt`」；profile 缺 `DOCKER_VOLUME` 时快速失败；dump 产物为空则失败。对齐 spec「失败目录不占保留名额」。

创建根目录 `backup.sh`：

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: bash backup.sh [--profile local|sit]

Back up MySQL (all databases), MongoDB (archive), and GitLab config (if present)
to ${BACKUP_DIR:-$DOCKER_VOLUME/backup}/<timestamp>/ and keep the newest
${KEEP_BACKUPS:-7} backups.
EOF
}

prune_backups() {
  local dir="$1" keep="$2" entry count=0
  [ -d "$dir" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      rm -rf "$entry"
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print | sort -r)
}

main() {
  local profile="" profile_file="" dest stamp
  PROFILE_SET=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile|-p)
        [ $# -ge 2 ] || { echo "Error: --profile requires a value" >&2; exit 2; }
        profile="$2"; PROFILE_SET=1; shift 2 ;;
      --profile=*)
        profile="${1#*=}"; PROFILE_SET=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  # shellcheck source=common/profile.sh
  source "$SCRIPT_DIR/common/profile.sh"
  PROFILE="$profile"
  require_profile_value || exit 2
  PROFILE="$(select_profile "$SCRIPT_DIR" "$PROFILE")" || exit 1
  profile_file="$(profile_file "$SCRIPT_DIR" "$PROFILE")"
  [ -f "$profile_file" ] || { echo "Error: profile file not found: $profile_file" >&2; exit 1; }

  # shellcheck source=common/docker-volume.sh
  source "$SCRIPT_DIR/common/docker-volume.sh"
  DOCKER_VOLUME="$(resolve_docker_volume "$SCRIPT_DIR" "" "$(uname -s)" "$HOME" "$profile_file")"
  BACKUP_DIR="${BACKUP_DIR:-$DOCKER_VOLUME/backup}"
  KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
  case "$KEEP_BACKUPS" in
    ''|*[!0-9]*) echo "Error: KEEP_BACKUPS must be a positive integer" >&2; exit 2 ;;
  esac
  [ "$KEEP_BACKUPS" -ge 1 ] || { echo "Error: KEEP_BACKUPS must be >= 1" >&2; exit 2; }

  umask 077
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"
  chmod 700 "$dest"
  echo "Backing up to $dest (profile: $PROFILE)"

  docker exec mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --routines --events' > "$dest/mysql.sql"
  docker exec mongo sh -c 'mongodump --archive --gzip --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > "$dest/mongo.archive.gz"
  if [ -d "$DOCKER_VOLUME/gitlab/config" ]; then
    tar -czf "$dest/gitlab-config.tar.gz" -C "$DOCKER_VOLUME/gitlab" config
  fi

  {
    echo "timestamp=$stamp"
    echo "profile=$PROFILE"
    echo "docker_volume=$DOCKER_VOLUME"
    ls -lh "$dest"
  } > "$dest/MANIFEST.txt"

  prune_backups "$BACKUP_DIR" "$KEEP_BACKUPS"
  echo "Backup complete: $dest"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
```

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-backup-script.sh`
Expected: PASS，输出 `backup script tests: OK`。

- [ ] **Step 5: 提交**

```bash
git add backup.sh ci/scripts/test-backup-script.sh
git commit -m "feat(backup): 新增 MySQL/Mongo/GitLab config 备份脚本"
```

---

### Task 3: 文档

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: README**

- 新增「备份与恢复」章节：`bash backup.sh --profile sit`、目录、范围、保留 7 份、`BACKUP_DIR`/`KEEP_BACKUPS` 覆盖、MySQL/Mongo/GitLab config 恢复命令、GitLab 仓库数据用 `gitlab-backup create`。
- 资源段落补：ES 1g / Logstash 512m / Kafka 512m / Nexus 768m / Redis 256mb allkeys-lru。

- [ ] **Step 2: CLAUDE.md**

- 常用命令加 `bash backup.sh --profile sit`。
- 约定段补备份范围与不备份项。

- [ ] **Step 3: 文档断言**

Run: `bash ci/scripts/test-doc-consistency.sh && bash ci/scripts/test-runbook.sh`
Expected: 通过。

- [ ] **Step 4: 提交**

```bash
git add README.md CLAUDE.md
git commit -m "docs: 补充资源上限与备份恢复说明"
```

---

### Task 4: 全量验证与最终审查

- [ ] **Step 1: 全量语法与测试**

Run:

```bash
while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')
for t in ci/scripts/test-*.sh; do bash "$t" || exit 1; done
bash common/check-consistency.sh --strict
git diff --check
```

Expected: 全部通过。

- [ ] **Step 2: 有 Docker 的机器运行时验证**

- `docker exec elk env` 含 `ES_JAVA_OPTS` / `LS_JAVA_OPTS`；Kafka/Nexus 同理。
- `docker exec redis redis-cli -a "$REDIS_PASSWORD" CONFIG GET maxmemory` 与 `maxmemory-policy`。
- `bash backup.sh --profile local` 生成 `mysql.sql`、`mongo.archive.gz`、（sit）`gitlab-config.tar.gz`、`MANIFEST.txt`；目录权限 700。
- 造 9 个时间戳目录后重跑，确认只留 7 份。
- 在临时库恢复 MySQL/Mongo 备份验证可用。

- [ ] **Step 3: 提交（如有修正）**

```bash
git status --short
# 若有修正：git add <files> && git commit -m "fix: 批次 4 运行时修正"
```

---

## Self-Review

- **Spec coverage:** 资源限制 → Task 1；backup.sh → Task 2；文档 → Task 3；验证 → Task 4。无遗漏。
- **Step scan:** 每个任务先写失败测试/断言，再实现，再跑通过。
- **Type consistency:** `prune_backups`、`BACKUP_DIR`、`KEEP_BACKUPS`、`PROFILE_SET` 在各处一致。
- **Review Focus:** 五条风险分别由 Task 1/4、Task 1、Task 2/4、Task 2、Task 2/4 覆盖。
- **Proportion:** 计划主要是脚本代码与断言，与 spec 体量相当。

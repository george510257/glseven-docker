# 设计文档：资源限制与备份脚本（批次 4）

日期：2026-11-22
状态：待批准

## 意图与背景

2026-11-20 配置审计的 P1-1 与 P1-11 仍未处理：

- 只有 ollama 有资源上限；ES、Kafka、Nexus、Redis 等内存大户没有堆上限或内存上限，NAS 上最先出现的往往是 OOM killer，而不是「慢」。
- 仓库没有备份路径；MySQL / Mongo / GitLab config 只存在宿主 bind mount，误删或磁盘故障不可恢复。

用户已选定：JVM 堆 + Redis 上限（不设硬 `mem_limit`）、备份 MySQL + Mongo + GitLab config、保留 7 份。

## 目标 / 非目标

**目标**

- 给 sebp/elk、Kafka、Nexus 设置 JVM 堆上限；给 Redis 设置 `maxmemory` 与淘汰策略。
- 新增 `backup.sh`：mysqldump 全库 + mongodump archive + GitLab config tar（存在时），按时间戳目录保存，保留最近 7 份。
- 更新 README / CLAUDE.md，补恢复步骤与备份边界说明。
- 新增静态测试，防止堆参数、Redis 上限与备份脚本行为回退。

**非目标**

- 不设硬 `mem_limit` / `cpus`（用户选择，避免不同宿主内存差异导致 OOM kill）。
- 不备份 Nexus blob、Kafka 日志、ELK 索引、Prometheus 指标（数据量大、可重建或非关键）。
- 不备份 GitLab 仓库数据；GitLab 自身用 `gitlab-backup create`，在 README 注明。
- 不新增备份容器、cron 或自动调度；`backup.sh` 手动执行。
- 不写 restore 脚本；README 给出恢复命令。

## 详细设计

### A. 资源限制

| 服务 | 变更 |
|---|---|
| `observability` elk | `environment:` 增加 `ES_JAVA_OPTS=-Xms1g -Xmx1g`、`LS_HEAP_SIZE=512m`（sebp/elk 的 `start.sh` 用它改写 Logstash 的 jvm.options；`LS_JAVA_OPTS` 会被镜像 entrypoint 覆盖，不可用） |
| `infra` kafka | `environment:` 增加 `KAFKA_HEAP_OPTS=-Xms512m -Xmx512m`（与现有 `KAFKA_ADVERTISED_LISTENERS` 并列） |
| `platform` nexus3 | `environment:` 增加 `INSTALL4J_ADD_VM_PARAMS=-Xms768m -Xmx768m -XX:MaxDirectMemorySize=768m` |
| `infra` redis | `command` 追加 `--maxmemory 256mb --maxmemory-policy allkeys-lru` |

- 不设 `mem_limit`：JVM 堆与 Redis 上限已经封住主要增长源；硬限制在 6–8GB 宿主上容易误杀。
- Redis 策略取舍：`allkeys-lru` 优先保证写入可用；若 moontv 的持久状态更重要，README 提示改为 `noeviction` 或调大 `maxmemory`。

### B. `backup.sh`

- 位置：仓库根目录，与 `startup.sh` / `shutdown.sh` 并列。
- 结构（可被测试 source，不自动执行 main）：

```bash
#!/bin/bash
set -euo pipefail
usage()
prune_backups DIR KEEP
do_backup PROFILE_FILE DEST
main "$@"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
```

- 参数与档案：`--profile local|sit` 或沿用 `.glseven-profile`；复用 `common/profile.sh` 与 `common/docker-volume.sh`。
- 输出目录：`${BACKUP_DIR:-$DOCKER_VOLUME/backup}/<YYYYmmdd-HHMMSS>/`；先写到 `<timestamp>.partial`，写完 `MANIFEST.txt` 后再 `mv` 成正式目录；`umask 077`，新建目录 `chmod 700`。profile 缺 `DOCKER_VOLUME` 时直接失败，不回退平台默认。
- 内容：
  - `mysql.sql`：`docker exec mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --routines --events'`。
  - `mongo.archive.gz`：`docker exec mongo sh -c 'mongodump --archive --gzip --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'`。
  - `gitlab-config.tar.gz`：当 `$DOCKER_VOLUME/gitlab/config` 存在时，`tar -czf ... -C "$DOCKER_VOLUME/gitlab" config`；含 `gitlab-secrets.json`。
  - `MANIFEST.txt`：时间、profile、数据目录、各文件大小。
- 保留：`prune_backups "$BACKUP_DIR" "${KEEP_BACKUPS:-7}"`，只统计「时间戳目录 + `MANIFEST.txt`」的完成备份，按目录名倒序保留最新 N 份；`.partial` 与非时间戳目录不参与、也不会被删除。
- 失败处理：任一 dump 失败或产物为空则整个备份失败并以非零退出；`.partial` 目录保留供排查，但不计入保留名额。
- 恢复（README）：
  - MySQL：`docker exec -i mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' < mysql.sql`（建议在空库/新卷上恢复）。
  - Mongo：`docker exec -i mongo sh -c 'mongorestore --archive --gzip --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' < mongo.archive.gz`。
  - GitLab config：停止 gitlab 后解压到 `$DOCKER_VOLUME/gitlab/`。

### C. 测试

- `ci/scripts/test-resource-limits.sh`：
  - observability compose 含 `ES_JAVA_OPTS=-Xms1g -Xmx1g` 与 `LS_JAVA_OPTS=-Xms512m -Xmx512m`；
  - infra compose 含 `KAFKA_HEAP_OPTS=-Xms512m -Xmx512m`；
  - platform compose 含 `INSTALL4J_ADD_VM_PARAMS=-Xms768m -Xmx768m`；
  - redis command 含 `--maxmemory 256mb` 与 `--maxmemory-policy allkeys-lru`。
- `ci/scripts/test-backup-script.sh`：
  - `bash -n backup.sh`；
  - `bash backup.sh --help` 输出 `Usage:` 且退出 0；
  - source `backup.sh` 后 `prune_backups` 在 9 个目录、KEEP=7 时保留 7 个并删除最旧两个；KEEP=3 时保留 3 个。测试不调用 Docker。

### D. 文档

- README 新增「备份与恢复」：命令、目录、范围、保留份数、恢复步骤、GitLab 仓库需 `gitlab-backup create`。
- README 的资源/监控段落补 JVM 堆与 Redis 上限。
- CLAUDE.md 常用命令加 `bash backup.sh --profile sit`；约定段补「备份范围与不备份项」。

## 验证

1. `bash -n backup.sh`；全部 `ci/scripts/test-*.sh`；`check-consistency --strict`；`git diff --check`。
2. 有 Docker 的机器：
   - `docker exec elk env | grep -E 'ES_JAVA_OPTS|LS_JAVA_OPTS'`；Kafka/Nexus 同理；
   - `docker exec redis redis-cli -a "$REDIS_PASSWORD" CONFIG GET maxmemory` 与 `maxmemory-policy`；
   - `bash backup.sh --profile local` 生成目录与三个文件；再跑 8 次或造 9 个目录验证只留 7 份；
   - 在临时库上恢复 mysql.sql 与 mongo.archive.gz 验证可用。
3. 本机无 Docker：运行静态测试与 `--help`；运行时项在最终报告标注缺口。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| ES 1g 堆对现有数据偏小 | 先按 1g；若启动/查询告警，调大到 1.5g（只改 compose 一行） |
| Redis `allkeys-lru` 可能淘汰 moontv 状态 | README 明确说明；需要持久状态时改 `noeviction` 或调大 maxmemory |
| mysqldump 全库包含系统库，恢复覆盖风险 | README 建议在空库/新卷恢复，不直接覆盖生产库 |
| GitLab config tar 含 secrets | 备份目录 700；README 提示与备份包分开保管 |
| GitLab 仓库数据不在备份内 | README 指向 `gitlab-backup create` |
| 备份脚本在服务运行时快照不一致 | MySQL 用 `--single-transaction`；Mongo 用 archive；config 只读 tar |
| 本机无 Docker，无法端到端验证 | 静态测试 + `--help`；运行时项由用户机器补验并在报告标注 |

## 我的决定（供审阅）

- 不设硬 `mem_limit`，只封 JVM 堆与 Redis 内存。
- Logstash 用 `LS_HEAP_SIZE=512m`，因为 sebp/elk 的 entrypoint 会覆盖 `LS_JAVA_OPTS`。
- Redis 用 `allkeys-lru`（按用户选择），文档说明持久状态风险。
- 备份先写 `.partial`、以 `MANIFEST.txt` 作为完成标记；prune 只处理完成的 时间戳目录。
- profile 缺 `DOCKER_VOLUME` 时快速失败，不回退平台默认。
- 备份保留 7 份，目录默认 `$DOCKER_VOLUME/backup`，可用 `BACKUP_DIR` / `KEEP_BACKUPS` 环境变量覆盖。
- 不写 restore 脚本，README 给命令。
- GitLab 只备份 config；仓库数据交给 `gitlab-backup create`。

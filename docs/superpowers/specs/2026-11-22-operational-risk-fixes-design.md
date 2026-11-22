# 设计文档：运行风险与文档漂移修复（批次 1）

日期：2026-11-22
状态：已批准（2026-11-22）
关联：批次 2 为 [Compose 公共模板收敛](2026-11-22-compose-template-consolidation-design.md)

## 意图与背景

全仓扫描发现 5 类运行风险与一批文档漂移。用户选择先修这些点状问题，再做 compose 模板收敛，避免「行为修复 + 全量配置重构」混在一个 diff 里，验证和回滚都会更难。

本批次只做点状修复，不改任何服务的镜像、端口、网络、数据卷与业务配置。

## 目标 / 非目标

**目标**

- 档案从 sit 切到 local（或反向）时，devops 容器状态收敛，不再残留 GitLab/Runner。
- `shutdown.sh` 不再出现「网络没删掉却打印全部停止」的假成功。
- `ci/validate.sh` 不再覆盖本机 `.env.local`。
- smoke test 只检查 glseven 栈内的容器。
- 删掉未使用的 `gitlab-runner/cache` 数据目录。
- 9 处配置挂载改为只读。
- 校正 README / CLAUDE.md / runbook / portal 注释中的漂移与事实错误。
- 仓库 `.gitignore` 忽略 `.claude/`，不再依赖个人全局忽略。

**非目标**

- 不做 compose 模板收敛（批次 2）。
- 不处理端口绑定、认证、默认凭据、Prometheus/Grafana 补齐（批次 3）。
- 不删除或改写 `.github/workflows`（是否保留 GitHub Actions 另行决定）。
- 不改任何服务的运行时参数、探针命令或镜像版本。

## 修复项

### 1. 档案切换时 devops 收敛

**现状**

- `startup.sh` 在 profile 不含 devops 时只打印 `Skipping devops services`，不停止已在运行的 GitLab/Runner。
- `shutdown.sh` 只在当前档案是 sit 时才把 devops 加入停止列表；`.glseven-profile` 已被 local 覆盖时，devops 不会被 `down`。
- 随后 `docker network rm glseven` 因仍有端点失败；`set -e` 对 `if` 体内的 `&&` 列表不触发退出，脚本仍打印「所有服务已停止」。

**改法**

- `shutdown.sh`：
  - 无条件把 `COMPOSE_FILES_DEVOPS` 加入停止列表，逆序变为 `PORTAL → DEVOPS → DEFERRED → BASE`。
  - `down` 增加 `--remove-orphans`。
  - 网络删除结果显式记录：成功打印移除；失败打印占用容器并保留网络，最终横幅区分「网络已移除」与「网络保留」。
- `startup.sh`：
  - profile 不含 devops 时，用 `compose -f devops/docker-compose.yml ps -aq` 检测是否有残留容器；有则打印说明并 `down -t 60`，让 local 档案真正不跑 devops。
  - 失败只告警，不阻断其余服务启动。
- 更新 `shutdown.sh` 顶部注释（BASE + DEFERRED + DEVOPS + PORTAL）。

**取舍**

- 选择「自动停止」而不是「仅告警」：用户切到 local 的意图就是不要 GitLab；让 3–3.5 GiB 的容器继续跑不符合档案语义。
- 网络删除失败降级为警告：`glseven` 是共享网络，其他 project（如 athena）可能正在使用；删不掉不一定是本编排的问题。

### 2. `ci/validate.sh` 不覆盖本地 `.env.local`

**现状**

`ci/validate.sh:17` 无条件 `cp .env.local.example .env.local`，本地执行会丢掉 `DOCKER_VOLUME` / `KAFKA_EXTERNAL_HOST` / `REDIS_PASSWORD`。

**改法**

```bash
tmp_env="$(mktemp "${TMPDIR:-/tmp}/glseven-validate-env.XXXXXX")"
trap 'rm -f "$tmp_env"' EXIT
cp .env.local.example "$tmp_env"
...
docker compose --env-file "$tmp_env" -f "$file" config -q
```

- 全程不触碰工作区的 `.env.local`。
- `.github/workflows/ci.yml:37` 保持不动：GitHub Actions 工作区是临时的，且该文件是否保留另行决定；若保留，下一批用 `$GITHUB_ENV` 传临时文件路径。

### 3. smoke test 只检查 glseven 栈

**现状**

`ci/smoke-test.sh:15` 遍历 `docker ps` 的全部容器；sit 宿主上其他 stack 的 unhealthy 容器会让本仓库部署失败。

**改法**

```bash
for c in $(docker ps --filter network=glseven --format '{{.Names}}'); do
```

- 只等待连接到 `glseven` 网络的容器。
- 注释说明共享宿主上的其他 stack 不参与本编排 smoke。

### 4. 删除未使用的 `gitlab-runner/cache`

**现状**

`startup.sh:114` 创建、`ci/scripts/test-compose-list.sh:18` 强制要求 `gitlab-runner/cache`，但 `devops/docker-compose.yml` 只挂载 config/home/socket，没有任何服务使用该目录。

**改法**

- 从 `DIR_SPECS` 删除 `"gitlab-runner/cache 0"`。
- 从 `test-compose-list.sh` 的目录清单删除 `gitlab-runner/cache`。
- 不新增 `/cache` 挂载：GitLab Runner 的 docker executor 在**作业容器**里使用 `/cache` 卷，不是 runner 容器本身；当前编排没有配置该卷，新增挂载会改变 runner 行为。

### 5. 配置挂载改为只读

给以下 9 处加 `:ro`（组件均只读取这些路径）：

| 文件 | 挂载 |
|---|---|
| `infra/docker-compose.yml` | `./mysql/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d` |
| `infra/docker-compose.yml` | `./rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins` |
| `observability/docker-compose.yml` | `./prometheus/conf/prometheus.yml:/etc/prometheus/prometheus.yml` |
| `observability/docker-compose.yml` | `./grafana/conf/provisioning:/etc/grafana/provisioning` |
| `observability/docker-compose.yml` | `./grafana/conf/dashboards:/var/lib/grafana/dashboards` |
| `observability/docker-compose.yml` | `./grafana/conf/config/grafana.ini:/etc/grafana/grafana.ini` |
| `observability/docker-compose.yml` | `./elk/kibana/config/kibana.yml:/opt/kibana/config/kibana.yml` |
| `platform/docker-compose.yml` | `./nacos/config/custom.properties:/home/nacos/init.d/custom.properties` |
| `platform/docker-compose.yml` | `./xxl-job-admin/application.properties:/application.properties` |

新增 `ci/scripts/test-readonly-mounts.sh`，用 9 条 `grep -Fq` 断言防止回退。

### 6. 文档与注释校正

- `README.md`
  - 第 3 行：改为「7 个职能域、27 个容器（nginx 门户 + 26 个后端服务）」。
  - 第 14 行：`24 个主机名` → `25 个主机名`。
  - 第 32 行：把 `nexus3/prometheus/grafana/elk` 的枚举改为「脚本按 `DIR_SPECS` 将数据目录 chown 到容器运行 uid」。
  - 第 36 行：`六域结构与启动时序` → `七域结构与启动时序`；表格补 devops 行：`gitlab .1、gitlab-runner .2 | 172.18.7.x | DEVOPS（仅 sit）`。
  - 第 57 行：`--env-file .env` → `--env-file .env.local`（sit 为 `.env.sit`），并把「根 `.env` 中的 REDIS_PASSWORD」改为「档案文件中的 REDIS_PASSWORD」。
  - 第 66 行：Adminer 说明改为「MySQL 管理」（Adminer 不支持 MongoDB）。
  - 第 147 行：迁移段补一句「devops 为 2026-11 新增的第 7 域」。
- `CLAUDE.md:41`：`四个脚本` → `所有 test-*.sh`。
- `docs/runbooks/sit-cicd-bootstrap.md:124`：`docker-compose-devops.yml` → `devops/docker-compose.yml`。
- `portal/docker-compose.yml:12`：`23 个 server 块` → `24 个 server 块`。
- `portal/conf/stream-conf.d/rabbitmq.conf:1`：删掉「35672」笔误，改为「AMQP 宿主 5673 → 容器 5672」。
- `portal/conf/stream-conf.d/kafka.conf:3`：advertised 地址来源改为「由 `infra/docker-compose.yml` 从当前档案的 `KAFKA_EXTERNAL_HOST` 渲染」，不再指向 `infra/env/kafka.env`。
- `portal/html/index.html:37`：Adminer 说明改为「MySQL 数据库管理」。

### 7. `.gitignore` 忽略 `.claude/`

- 在 `.gitignore` 增加 `.claude/`（本地 Claude Code 设置，不入库）。
- 在 `ci/validate.sh` 增加与 GitHub workflow 相同的忽略断言：

```bash
for path in .env.local .env.sit .glseven-profile .claude/settings.local.json; do
  git check-ignore -q "$path" || { echo "Error: $path must be ignored" >&2; exit 1; }
done
```

## 验证

1. `bash -n` 全部 shell 脚本。
2. 全部 `ci/scripts/test-*.sh`（含新增的 `test-readonly-mounts.sh`）。
3. `bash common/check-consistency.sh --strict`。
4. 七个 compose 各跑一次 `docker compose --env-file .env.local -f <域>/docker-compose.yml config -q`（CI 覆盖）。
5. 档案切换演练（有 Docker 的机器）：
   - `bash startup.sh --profile sit` 起全栈；
   - `bash startup.sh --profile local`：确认 devops 被停止，其余服务正常，`docker ps` 中无 gitlab/gitlab-runner；
   - `bash shutdown.sh`：确认 devops 不再阻塞网络删除，最终横幅与实际状态一致。
6. `:ro` 挂载运行时冒烟（sit）：相关容器 healthy，日志无写配置失败。
7. 文档断言：README 含「7 个职能域」「| devops |」；runbook 不再出现 `docker-compose-devops.yml`；portal 注释的 server 块计数与 `grep -c 'server {'` 一致。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 组件实际会写配置目录，加 `:ro` 后启动失败 | 只对已确认只读的 9 处加；sit 部署后检查容器日志与健康状态；失败则回退单行 |
| local 启动时自动停 devops 出乎预期 | 打印明确说明；README 的档案章节补一句行为说明 |
| 共享网络 `glseven` 被其他 project 占用时不再报错退出 | 这是有意为之：打印占用容器并保留网络，最终横幅提示「网络保留」 |
| `mktemp` 在 Alpine / macOS 的兼容性 | 模板用 `XXXXXX`，`TMPDIR` 回退 `/tmp`；CI 与本地均已具备 |
| 文档断言过脆 | 只断言关键事实（7 域、devops 行、旧文件名不再出现），不锁行号 |

## 我的决定（供审阅）

- 档案切换时**自动停止** devops，而不是只告警。
- 网络删除失败降级为警告，因为 `glseven` 是共享网络。
- 删除未使用的 `gitlab-runner/cache`，不新增 `/cache` 挂载。
- 本批次不动 `.github/workflows`；GitHub Actions 的去留单列。
- 只加 9 处已确认安全的 `:ro`，不扩大到数据目录。
- 文档校正只改事实错误，不重写历史迁移段的结构。

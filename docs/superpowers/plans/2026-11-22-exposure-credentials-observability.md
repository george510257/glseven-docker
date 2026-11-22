# 暴露面、凭据外置与可观测性补齐（批次 3）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 30 个宿主端口按档案收敛到本机/局域网，四项默认凭据改由 profile 注入，并补上 Prometheus retention、Filebeat 自监控与基础 Grafana 面板。

**Architecture:** 端口绑定通过 `PORT_BIND_IP` + portal compose 的 30 条 ports 前缀实现；凭据通过 compose `environment` 从 profile 注入（APISIX 额外用自身 `${{...}}` 语法）；可观测性只改现有组件配置，不新增容器。新增两个静态测试脚本固化这些不变量。

**Tech Stack:** Bash 3.2、Docker Compose v2、Prometheus、Filebeat、Grafana、GitLab CI。

**Spec:** docs/superpowers/specs/2026-11-22-exposure-credentials-observability-design.md

## Global Constraints

- 不改服务清单、镜像版本、端口数量、网络、数据卷语义；不改批次 1/2 的模板结构。
- local 默认 `127.0.0.1`，sit 默认 `0.0.0.0`；`PORT_BIND_IP` 与四项凭据在 profile 中必填。
- 所有脚本兼容 macOS 自带 Bash 3.2；新测试放 `ci/scripts/test-*.sh`。
- 不新增 node-exporter / JSON exporter；资源限制与备份不在本轮。
- 所有命令在 worktree `/Users/george/project/glseven/glseven-docker/.claude/worktrees/project-config-service-reuse-71639c` 下执行。
- 本机无 Docker CLI；`compose config` 与运行时验证由 CI / 有 Docker 的机器覆盖，最终报告明示。

## Review Focus

- local 档案渲染后 host_ip 必须是 `127.0.0.1`，sit 必须是 `0.0.0.0`；Task 1 的测试 + Task 5 的渲染检查覆盖。
- profile 缺任一必填键时必须快速失败，不能静默用默认凭据；Task 1/2 的 preflight 断言与 `test-docker-volume.sh` 覆盖。
- APISIX `${{...}}` 与 xxl-job Spring 占位符必须真正生效；Task 2 的静态断言 + Task 5 的运行时 curl/日志检查覆盖。
- Prometheus command 覆盖不能丢 `config.file` / `storage.tsdb.path`；Task 3 的测试覆盖。
- Filebeat monitoring 不能阻塞日志主链路；Task 5 的 `filebeat test output` 与日志检查覆盖。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `.env.local.example` / `.env.sit.example` | 增加 `PORT_BIND_IP` 与四项凭据变量 |
| `portal/docker-compose.yml` | 30 条 ports 加 `${PORT_BIND_IP:-127.0.0.1}:` 前缀 |
| `common/preflight.sh` | 三段式端口解析；profile 必填键扩展 |
| `observability/docker-compose.yml` | Prometheus command + Grafana 环境变量 |
| `observability/filebeat/conf/filebeat.yml` | Beats monitoring → ES |
| `observability/grafana/conf/dashboards/glseven-targets.json` | 基础 Targets 面板 |
| `platform/docker-compose.yml` | APISIX / xxl-job 凭据注入 |
| `platform/apisix/conf/config.yaml` | APISIX admin key 改 `${{...}}` |
| `platform/xxl-job-admin/application.properties` | access token 改 Spring 占位符 |
| `security/docker-compose.yml` | Keycloak bootstrap 口令注入 |
| `ci/scripts/test-exposure-config.sh` | 新增：端口/凭据不变量断言 |
| `ci/scripts/test-observability.sh` | 新增：retention/filebeat/面板断言 |
| `ci/scripts/test-devops-domain.sh` / `test-docker-volume.sh` / `test-env-config.sh` | 更新端口断言、profile fixture、凭据断言 |
| `README.md` / `CLAUDE.md` | 端口差异、五个新变量、可观测性说明 |

---

### Task 1: 端口绑定按档案

**Files:**
- Modify: `.env.local.example`, `.env.sit.example`
- Modify: `portal/docker-compose.yml`（ports 块）
- Modify: `common/preflight.sh`（端口解析、`ensure_profile_file`）
- Modify: `ci/scripts/test-devops-domain.sh`, `ci/scripts/test-docker-volume.sh`
- Test: `ci/scripts/test-exposure-config.sh`（新建）

**Interfaces:**
- Consumes: 无
- Produces: `PORT_BIND_IP` profile 变量；portal 30 条 ports 统一前缀；`ensure_profile_file` 必填键含 `PORT_BIND_IP`

- [ ] **Step 1: 写失败测试**

创建 `ci/scripts/test-exposure-config.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -q '^PORT_BIND_IP=127\.0\.0\.1$' "$ROOT/.env.local.example" || fail "local 示例缺少 PORT_BIND_IP=127.0.0.1"
grep -q '^PORT_BIND_IP=0\.0\.0\.0$' "$ROOT/.env.sit.example" || fail "sit 示例缺少 PORT_BIND_IP=0.0.0.0"

count=$(grep -cE '^      - "\$\{PORT_BIND_IP:-127\.0\.0\.1\}:[0-9]+:[0-9]+"' "$ROOT/portal/docker-compose.yml")
[ "$count" -eq 30 ] || fail "portal 应有 30 条带 PORT_BIND_IP 的 ports，实际 $count"

grep -q 'NF-1' "$ROOT/common/preflight.sh" || fail "preflight 端口解析未使用三段式 NF-1"
grep -q 'PORT_BIND_IP' "$ROOT/common/preflight.sh" || fail "preflight 未校验 PORT_BIND_IP"

printf 'exposure config tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-exposure-config.sh`
Expected: FAIL，提示 local 示例缺少 `PORT_BIND_IP`。

- [ ] **Step 3: 实现端口绑定**

- `.env.local.example` 增加 `PORT_BIND_IP=127.0.0.1`；`.env.sit.example` 增加 `PORT_BIND_IP=0.0.0.0`。
- 把 `portal/docker-compose.yml` 的 30 条 ports 全部改为 `- "${PORT_BIND_IP:-127.0.0.1}:<host>:<container>"`，host/container 端口保持不变。
- `common/preflight.sh` 端口解析改为：

```bash
for port in $(grep -oE '"[^"]+:[0-9]+:[0-9]+"' "$SCRIPT_DIR/portal/docker-compose.yml" 2>/dev/null |
  tr -d '"' | awk -F: '{print $(NF-1)}' | sort -un); do
```

- `ensure_profile_file` 的 `for key in DOCKER_VOLUME REDIS_PASSWORD; do` 改为包含 `PORT_BIND_IP`。
- `ci/scripts/test-devops-domain.sh` 的 `"8929:8929"` / `"2224:2224"` 断言改为 `PORT_BIND_IP:-127.0.0.1}:8929:8929` / `...:2224:2224`。
- `ci/scripts/test-docker-volume.sh` 的 `ensure_profile_file` fixture 增加 `PORT_BIND_IP=127.0.0.1`。

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-exposure-config.sh && bash ci/scripts/test-devops-domain.sh && bash ci/scripts/test-docker-volume.sh`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add .env.local.example .env.sit.example portal/docker-compose.yml common/preflight.sh ci/scripts/test-devops-domain.sh ci/scripts/test-docker-volume.sh ci/scripts/test-exposure-config.sh
git commit -m "feat(portal): 按档案绑定宿主端口"
```

---

### Task 2: 四项凭据外置

**Files:**
- Modify: `.env.local.example`, `.env.sit.example`
- Modify: `observability/docker-compose.yml`（Grafana）
- Modify: `platform/docker-compose.yml`（APISIX、xxl-job）
- Modify: `platform/apisix/conf/config.yaml`
- Modify: `platform/xxl-job-admin/application.properties`
- Modify: `security/docker-compose.yml`（Keycloak）
- Modify: `common/preflight.sh`（必填键）
- Modify: `ci/scripts/test-docker-volume.sh`, `ci/scripts/test-env-config.sh`, `ci/scripts/test-exposure-config.sh`

**Interfaces:**
- Consumes: Task 1 的 profile 必填键机制
- Produces: `GRAFANA_ADMIN_PASSWORD` / `APISIX_ADMIN_KEY` / `XXL_JOB_ACCESS_TOKEN` / `KEYCLOAK_ADMIN_PASSWORD` 四项 profile 变量与对应注入

- [ ] **Step 1: 扩展失败测试**

在 `ci/scripts/test-exposure-config.sh` 的 `printf` 前加入：

```bash
for key in GRAFANA_ADMIN_PASSWORD APISIX_ADMIN_KEY XXL_JOB_ACCESS_TOKEN KEYCLOAK_ADMIN_PASSWORD; do
  grep -q "^${key}=" "$ROOT/.env.local.example" || fail "local 示例缺少 $key"
  grep -q "^${key}=" "$ROOT/.env.sit.example" || fail "sit 示例缺少 $key"
done
grep -q 'GF_SECURITY_ADMIN_PASSWORD' "$ROOT/observability/docker-compose.yml" || fail "Grafana 未注入管理员口令"
grep -q 'APISIX_ADMIN_KEY' "$ROOT/platform/apisix/conf/config.yaml" || fail "APISIX config 未引用 APISIX_ADMIN_KEY"
grep -q 'APISIX_ADMIN_KEY' "$ROOT/platform/docker-compose.yml" || fail "platform compose 未注入 APISIX_ADMIN_KEY"
grep -q 'XXL_JOB_ACCESS_TOKEN' "$ROOT/platform/xxl-job-admin/application.properties" || fail "xxl-job properties 未引用 XXL_JOB_ACCESS_TOKEN"
grep -q 'XXL_JOB_ACCESS_TOKEN' "$ROOT/platform/docker-compose.yml" || fail "platform compose 未注入 XXL_JOB_ACCESS_TOKEN"
grep -q 'KC_BOOTSTRAP_ADMIN_PASSWORD' "$ROOT/security/docker-compose.yml" || fail "Keycloak 未注入 bootstrap 口令"
for key in GRAFANA_ADMIN_PASSWORD APISIX_ADMIN_KEY XXL_JOB_ACCESS_TOKEN KEYCLOAK_ADMIN_PASSWORD; do
  grep -q "$key" "$ROOT/common/preflight.sh" || fail "preflight 未校验 $key"
done
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-exposure-config.sh`
Expected: FAIL，提示 local 示例缺少 `GRAFANA_ADMIN_PASSWORD`。

- [ ] **Step 3: 实现四项凭据**

- 两个 profile 示例补齐四个变量（值沿用当前开发默认值）。
- `observability/docker-compose.yml` 的 grafana 增加：

```yaml
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:-admin}
```

- `platform/apisix/conf/config.yaml` 的 admin key 改为：

```yaml
        key: ${{APISIX_ADMIN_KEY:=7705a28bc106c39a9e959427f9351c51}}
```

- `platform/docker-compose.yml` 的 apisix 增加：

```yaml
    environment:
      APISIX_ADMIN_KEY: ${APISIX_ADMIN_KEY:-7705a28bc106c39a9e959427f9351c51}
```

- `platform/xxl-job-admin/application.properties` 的 token 改为：

```properties
xxl.job.accessToken=${XXL_JOB_ACCESS_TOKEN:default_token}
```

- `platform/docker-compose.yml` 的 xxl-job-admin 增加：

```yaml
    environment:
      XXL_JOB_ACCESS_TOKEN: ${XXL_JOB_ACCESS_TOKEN:-default_token}
```

- `security/docker-compose.yml` 的 keycloak 增加：

```yaml
    environment:
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD:-glseven_keycloak_2026}
```

- `ensure_profile_file` 的必填键加入四项；`test-docker-volume.sh` fixture 补齐；`test-env-config.sh` 增加四项在 profile 示例中的断言。

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-exposure-config.sh && bash ci/scripts/test-docker-volume.sh && bash ci/scripts/test-env-config.sh`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add .env.local.example .env.sit.example observability/docker-compose.yml platform/docker-compose.yml platform/apisix/conf/config.yaml platform/xxl-job-admin/application.properties security/docker-compose.yml common/preflight.sh ci/scripts/test-docker-volume.sh ci/scripts/test-env-config.sh ci/scripts/test-exposure-config.sh
git commit -m "feat(security): 四项默认凭据改由 profile 注入"
```

---

### Task 3: 可观测性补齐

**Files:**
- Modify: `observability/docker-compose.yml`
- Modify: `observability/filebeat/conf/filebeat.yml`
- Create: `observability/grafana/conf/dashboards/glseven-targets.json`
- Test: `ci/scripts/test-observability.sh`（新建）

**Interfaces:**
- Consumes: 无
- Produces: Prometheus retention 参数；Filebeat Beats monitoring；基础 Targets 面板

- [ ] **Step 1: 写失败测试**

创建 `ci/scripts/test-observability.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grep -Fq 'retention.time=15d' "$ROOT/observability/docker-compose.yml" || fail "Prometheus 缺少 retention.time"
grep -Fq 'retention.size=10GB' "$ROOT/observability/docker-compose.yml" || fail "Prometheus 缺少 retention.size"
grep -Fq 'monitoring.enabled: true' "$ROOT/observability/filebeat/conf/filebeat.yml" || fail "Filebeat 未开启 monitoring"
grep -Fq 'monitoring.elasticsearch' "$ROOT/observability/filebeat/conf/filebeat.yml" || fail "Filebeat 未配置 monitoring.elasticsearch"
DASH="$ROOT/observability/grafana/conf/dashboards/glseven-targets.json"
[ -s "$DASH" ] || fail "缺少 Grafana Targets 面板"
grep -Fq '"prometheus"' "$DASH" || fail "面板未引用 prometheus 数据源"
grep -Fq '"up"' "$DASH" || fail "面板缺少 up 查询"

printf 'observability tests: OK\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash ci/scripts/test-observability.sh`
Expected: FAIL，提示 Prometheus 缺少 retention.time。

- [ ] **Step 3: 实现**

- `observability/docker-compose.yml` 的 prometheus 增加 `command`（config.file、storage.tsdb.path、retention.time=15d、retention.size=10GB）。
- `observability/filebeat/conf/filebeat.yml` 末尾增加：

```yaml
monitoring.enabled: true
monitoring.elasticsearch:
  hosts: ["http://elk:9200"]
```

- 创建 `observability/grafana/conf/dashboards/glseven-targets.json`：最小 dashboard，数据源 uid `prometheus`，面板查询 `up` 与 `scrape_duration_seconds`。

- [ ] **Step 4: 运行确认通过**

Run: `bash ci/scripts/test-observability.sh`
Expected: PASS，输出 `observability tests: OK`。

- [ ] **Step 5: 提交**

```bash
git add observability/docker-compose.yml observability/filebeat/conf/filebeat.yml observability/grafana/conf/dashboards/glseven-targets.json ci/scripts/test-observability.sh
git commit -m "feat(observability): 补 retention、filebeat 自监控与基础面板"
```

---

### Task 4: 文档更新

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: 更新 README**

- 配置档案段落补五个变量：`PORT_BIND_IP`、`GRAFANA_ADMIN_PASSWORD`、`APISIX_ADMIN_KEY`、`XXL_JOB_ACCESS_TOKEN`、`KEYCLOAK_ADMIN_PASSWORD`，说明 local 默认 127.0.0.1、sit 默认 0.0.0.0。
- 端口章节说明：local 仅本机；局域网访问把 `PORT_BIND_IP` 改为 `0.0.0.0`。
- APISIX / xxl-job / Grafana 的凭据说明改为「见 profile」。
- 可观测性段落补 retention 与 Filebeat Stack Monitoring。

- [ ] **Step 2: 更新 CLAUDE.md**

同步配置档案变量、端口绑定差异、四项凭据、Prometheus retention 与 Filebeat monitoring。

- [ ] **Step 3: 文档断言**

Run: `bash ci/scripts/test-doc-consistency.sh && bash ci/scripts/test-runbook.sh`
Expected: 通过（如新增句子触发现有断言，按断言修正）。

- [ ] **Step 4: 提交**

```bash
git add README.md CLAUDE.md
git commit -m "docs: 说明端口绑定、profile 凭据与监控补齐"
```

---

### Task 5: 全量验证与最终审查

- [ ] **Step 1: 全量语法与测试**

Run:

```bash
while IFS= read -r -d '' f; do bash -n "$f"; done < <(git ls-files -z '*.sh')
for t in ci/scripts/test-*.sh; do bash "$t" || exit 1; done
bash common/check-consistency.sh --strict
git diff --check
```

Expected: 全部通过。

- [ ] **Step 2: Compose 渲染（CI / 有 Docker 的机器）**

Run:

```bash
cp .env.local.example /tmp/glseven-verify.env
for f in */docker-compose.yml; do docker compose --env-file /tmp/glseven-verify.env -f "$f" config -q || exit 1; done
rm -f /tmp/glseven-verify.env
```

Expected: 七个文件无输出通过；portal 渲染后的 host_ip 为 `127.0.0.1`。

- [ ] **Step 3: 运行时验证（有 Docker 的机器）**

- `startup.sh --profile local` 后 `ss -ltn` 确认宿主端口只监听 `127.0.0.1`；`--profile sit` 后确认 `0.0.0.0`。
- Grafana 用 profile 口令登录；APISIX Admin API 用 profile key；xxl-job 执行器注册使用 profile token；Keycloak 首启用 profile 口令。
- Prometheus `/api/v1/status/flags` 显示 retention；Kibana Stack Monitoring 看到 filebeat；Grafana 打开 Targets 面板。
- `docker exec filebeat filebeat test output` 仍通过（日志主链路未受 monitoring 影响）。

- [ ] **Step 4: 提交（如有验证修正）**

```bash
git status --short
# 若有修正：git add <files> && git commit -m "fix: 批次 3 运行时修正"
```

---

## Self-Review

- **Spec coverage:** 端口绑定 → Task 1；四项凭据 → Task 2；可观测性 → Task 3；文档 → Task 4；验证 → Task 5。无遗漏。
- **Step scan:** 每个任务先写/扩展失败测试，再实现，再跑通过；没有 TBD。
- **Type consistency:** `PORT_BIND_IP`、四个凭据变量、`test-exposure-config.sh` / `test-observability.sh` 名称在各任务一致。
- **Review Focus:** 五条风险分别由 Task 1/5、Task 1/2、Task 2/5、Task 3、Task 5 覆盖。
- **Proportion:** 计划与 spec 体量相当，主要是精确替换与测试代码。

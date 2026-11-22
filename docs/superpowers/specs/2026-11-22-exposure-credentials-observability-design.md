# 设计文档：暴露面、凭据外置与可观测性补齐（批次 3）

日期：2026-11-22
状态：已批准（2026-11-22）

## 意图与背景

全仓扫描发现三类问题：

- 30 个宿主端口全部绑定 `0.0.0.0`，ES 9200 无认证、etcd 无认证，局域网内任何设备可访问。
- 默认凭据散落在 compose / 组件配置中：Grafana admin/admin、APISIX admin key、xxl-job `default_token`、Keycloak bootstrap 口令；其中 APISIX key 与 xxl-job token 直接入库。
- Prometheus 无 retention 上限；Grafana dashboards 目录为空；filebeat 的 5066 自监控端点无人消费。

用户已选定范围：端口绑定按档案区分、四项凭据外置、监控做 retention + filebeat + 基础面板；资源限制与备份脚本不在本轮。

## 目标 / 非目标

**目标**

- local 档案只绑定 `127.0.0.1`，sit 档案绑定 `0.0.0.0`；由 `PORT_BIND_IP` 控制。
- Grafana 管理员口令、APISIX admin key、xxl-job access token、Keycloak bootstrap 口令改由档案变量注入，profile 中必填。
- Prometheus 增加 15 天 / 10GB retention；filebeat 自监控数据进入 ES/Kibana Stack Monitoring；新增一个基础 Grafana Targets 面板。
- 更新 README / CLAUDE.md / profile 示例与相关测试。

**非目标**

- 不新增 node-exporter / cadvisor / JSON exporter 等容器。
- 不做资源限制、Redis maxmemory、备份脚本（另立批次）。
- 不改数据库初始口令（`init.sql` 与各服务 DB 口令仍是开发默认值）。
- 不改 open-webui 注册开关、端口数量、服务清单、镜像版本。
- 不改批次 1/2 的模板与运行脚本结构。

**反目标（做了算失败）**

- local 档案仍能被局域网访问（除非用户显式改 `PORT_BIND_IP`）。
- 任一服务因凭据变量缺失而静默回落到公开默认值。
- Prometheus 因 command 覆盖丢失 config 或 storage 路径。
- filebeat 因开启 monitoring 而阻塞日志主链路。

## 决策

| 项 | 选择 | 理由 |
|---|---|---|
| 端口绑定 | local `127.0.0.1`，sit `0.0.0.0`，`PORT_BIND_IP` 控制 | 本机开发不需要局域网暴露；sit 需要其他设备访问 |
| 凭据 | 四项全部外置，profile 必填 | 避免公开默认值继续生效；显式失败优于静默回落 |
| 可观测性 | retention + filebeat Beats monitoring + 基础面板 | 不新增组件；5066 是 JSON，不能直接给 Prometheus |
| 资源/备份 | 本轮不做 | 与前三项风险面不同，另立批次 |

## 详细设计

### A. 端口绑定按档案

- `.env.local.example` 增加 `PORT_BIND_IP=127.0.0.1`；`.env.sit.example` 增加 `PORT_BIND_IP=0.0.0.0`。
- `portal/docker-compose.yml` 的 30 条 `ports` 全部改为：

```yaml
      - "${PORT_BIND_IP:-127.0.0.1}:8000:8000"
```

  其余 29 条同法，host/container 端口不变。
- `common/preflight.sh` 的端口解析改为兼容三段式：

```bash
for port in $(grep -oE '"[^"]+:[0-9]+:[0-9]+"' "$SCRIPT_DIR/portal/docker-compose.yml" 2>/dev/null |
  tr -d '"' | awk -F: '{print $(NF-1)}' | sort -un); do
```

- `common/preflight.sh` 的 `ensure_profile_file` 必填键增加：`PORT_BIND_IP`、`GRAFANA_ADMIN_PASSWORD`、`APISIX_ADMIN_KEY`、`XXL_JOB_ACCESS_TOKEN`、`KEYCLOAK_ADMIN_PASSWORD`。
- `ci/scripts/test-devops-domain.sh` 的两条端口断言改为匹配 `PORT_BIND_IP:-127.0.0.1}:8929:8929` / `...:2224:2224`。
- `ci/scripts/test-docker-volume.sh` 的 `ensure_profile_file` fixture 补齐五个新键。
- README 的快速开始与配置约定写明：local 默认仅本机；局域网访问需把 `PORT_BIND_IP` 改为 `0.0.0.0`。

### B. 四项凭据外置

| 服务 | 实现 |
|---|---|
| Grafana | compose `environment: GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:-admin}` |
| APISIX | `config.yaml` 的 `key` 改为 `${{APISIX_ADMIN_KEY:=7705a28bc106c39a9e959427f9351c51}}`；compose `environment: APISIX_ADMIN_KEY: ${APISIX_ADMIN_KEY:-7705...}` |
| xxl-job | `application.properties` 改为 `xxl.job.accessToken=${XXL_JOB_ACCESS_TOKEN:default_token}`；compose `environment: XXL_JOB_ACCESS_TOKEN: ${XXL_JOB_ACCESS_TOKEN:-default_token}` |
| Keycloak | compose `environment: KC_BOOTSTRAP_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD:-glseven_keycloak_2026}` |

- 两个 profile 示例补齐四个变量，值先沿用当前开发默认值，用户可自行轮换。
- APISIX 的 `${{...}}` 是 APISIX 自己的配置语法（官方 Admin API 文档「Using environment variables」），Compose 不会插值挂载文件；compose 只负责把 `APISIX_ADMIN_KEY` 注入容器。
- xxl-job 的 `${...}` 由 Spring 属性占位符解析；若运行时验证不支持，回退为「保持 default_token + 文档说明」并在最终报告标注。
- Keycloak 的 bootstrap 口令只在首次空库初始化生效；存量数据不受影响。

### C. 可观测性补齐

- `observability/docker-compose.yml` 的 prometheus 增加 `command`：

```yaml
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --storage.tsdb.retention.size=10GB
```

- `observability/filebeat/conf/filebeat.yml` 增加 Beats monitoring 到 ES：

```yaml
monitoring.enabled: true
monitoring.elasticsearch:
  hosts: ["http://elk:9200"]
```

  不新增 Prometheus job：Filebeat 5066 只提供 JSON `/stats`，不是 Prometheus 文本格式。
- 新增 `observability/grafana/conf/dashboards/glseven-targets.json`：一个最小 dashboard，数据源 uid `prometheus`，面板查询 `up`，按 job 展示目标是否在线。
- 新增 `ci/scripts/test-observability.sh`：
  - prometheus compose 含 `retention.time=15d` 与 `retention.size=10GB`；
  - filebeat.yml 含 `monitoring.enabled: true` 与 `monitoring.elasticsearch`；
  - dashboard JSON 存在且包含 `"prometheus"` 与 `"up"`。

### D. 测试与文档

- 新增 `ci/scripts/test-exposure-config.sh`：
  - 两个 `.env.*.example` 含 `PORT_BIND_IP` 与四项凭据变量；
  - portal compose 的 30 条 ports 全部以 `${PORT_BIND_IP` 开头；
  - `preflight.sh` 的端口解析含 `NF-1`；
  - 四个服务定义含对应的 `environment` 注入。
- README：配置档案段落列出五个新变量；端口章节说明 local/sit 差异；APISIX/xxl-job/Grafana 的凭据说明改为「见 profile」。
- CLAUDE.md：配置档案、凭据、可观测性三处同步。
- `ci/scripts/test-env-config.sh` 增加四项凭据在 profile 示例中的断言。

## 验证

1. `bash -n` 全部脚本；全部 `ci/scripts/test-*.sh`；`common/check-consistency.sh --strict`；`git diff --check`。
2. 七个 compose 各跑 `docker compose --env-file .env.local -f <域>/docker-compose.yml config -q`（CI 覆盖）；检查 portal 渲染后的 host_ip 为 `127.0.0.1`。
3. 用 `.env.sit.example` 渲染 portal，确认 host_ip 为 `0.0.0.0`。
4. 有 Docker 的机器：`startup.sh --profile local` 后确认宿主端口只监听 127.0.0.1；`startup.sh --profile sit` 后确认 0.0.0.0。
5. 凭据：Grafana 用 profile 口令登录；APISIX Admin API 用 profile key；xxl-job 执行器注册使用 profile token；Keycloak 首启用 profile 口令。
6. Prometheus `/api/v1/status/flags` 显示 retention 15d/10GB；Kibana Stack Monitoring 能看到 filebeat；Grafana 打开 Targets 面板。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| local 绑 127.0.0.1 后局域网设备访问失败 | README 明确说明与覆盖方法；sit 默认 0.0.0.0 |
| APISIX `${{...}}` 语法或 env 注入不生效 | 先本地/CI `compose config` 检查注入；启动后 `curl` Admin API 用新 key 验证；失败则回退为配置内 key + 文档 |
| xxl-job Spring 占位符不解析 | 启动后看 `/actuator/health` 与日志；失败则回退为 `default_token` + 文档 |
| Prometheus command 覆盖丢路径 | command 同时写 config.file 与 storage.tsdb.path |
| filebeat monitoring 加重 ES 负担 | 仅元数据指标，量很小；若影响日志链路则关闭 |
| profile 必填键增加导致旧档案启动失败 | README 给出补齐清单；preflight 报错信息明确 |
| 本机无 Docker，无法验证渲染与运行时 | CI `compose config` + 用户机器补验，最终报告明示 |

## 我的决定（供审阅）

- Filebeat 的「抓取」实现为 Beats monitoring → ES/Kibana，而不是 Prometheus job（5066 是 JSON）。
- 四项凭据在 profile 中**必填**，缺失直接失败，不静默回落。
- `PORT_BIND_IP` 必填，local/sit 各自示例给出明确值。
- 不新增 node-exporter / JSON exporter；资源限制与备份另立批次。
- APISIX / xxl-job 保留当前开发默认值作为配置层 fallback，便于旧环境平滑升级；真正生效值由 profile 注入。

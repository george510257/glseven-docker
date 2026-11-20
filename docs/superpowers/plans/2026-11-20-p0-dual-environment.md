# P0 修复与 local / sit 配置档案 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让同一套编排通过 `.env.local` / `.env.sit` 两套档案在 macOS 本机与家里测试服务器之间安全切换，并修复批次 A 的四个 P0。

**Architecture:** 新增 `common/profile.sh` 负责档案名校验与选择；`startup.sh` / `shutdown.sh` 统一用 `docker compose --env-file` 注入档案；compose 用 `${DOCKER_VOLUME:?}` 快速失败；Kafka 宿主地址由档案进入 `environment`；athena 降级为 gitignored 的本地 vhost；Nacos 开启客户端 API 鉴权。

**Tech Stack:** Bash 3.2、Docker Compose v2（`--env-file`、`${VAR:?}`）、nginx 1.30

**Spec:** `docs/superpowers/specs/2026-11-20-p0-dual-environment-design.md`

## Global Constraints

- 所有脚本必须兼容 macOS 自带的 Bash 3.2；不使用关联数组、`mapfile`、`${var,,}`。
- 档案名只允许 `[a-z0-9_-]+`；`--profile` 不得接受路径分隔符。
- 含凭据的文件（`.env*` 档案、`.glseven-profile`）不得入库；只提交 `*.example`。
- 所有 `docker compose` 调用必须带 `--env-file "$PROFILE_FILE"`，路径加引号。
- 不删除 `NACOS_AUTH_TOKEN` / `NACOS_AUTH_IDENTITY_KEY` / `NACOS_AUTH_IDENTITY_VALUE`（镜像 entrypoint 为空会 `exit 255`）。
- 提交信息用中文 + conventional 前缀；配置类提交优先 `fix` / `feat` / `chore` / `ci` / `docs`。
- 每个任务结束时 CI 必须仍可通过；离线验证不依赖 Docker daemon。

## Review Focus

1. `--profile ../x`、`--profile /tmp/x`、空档案名：必须在任何文件操作前拒绝。
2. 档案存在但缺少 `DOCKER_VOLUME` 或 `REDIS_PASSWORD`：必须报错并给出复制模板的命令，不能用默认值继续。
3. 换机器后 `.glseven-profile` 陈旧：启动必须打印实际档案名与数据目录；`shutdown.sh` 必须使用记录值或显式 `--profile`。
4. athena 未启动或未创建：portal 必须仍能启动与 reload（运行时验证）。
5. Nacos 的 token/identity 被误删：容器会 `exit 255`；测试必须断言三个键仍在。

---

### Task 1: 档案选择模块

**Files:**
- Create: `common/profile.sh`
- Test: `.github/scripts/test-profile.sh`

**Interfaces:**
- Produces:
  - `is_valid_profile_name NAME` → 0/1
  - `select_profile SCRIPT_DIR [EXPLICIT]` → stdout 为档案名；失败返回 1 并写 stderr
  - `profile_file SCRIPT_DIR NAME` → stdout 为 `SCRIPT_DIR/.env.NAME`
  - 常量 `ACTIVE_PROFILE_FILE=".glseven-profile"`

- [ ] **Step 1: 写失败测试**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common/profile.sh
source "$ROOT/common/profile.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/glseven-profile-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

is_valid_profile_name local || fail "local should be valid"
is_valid_profile_name sit || fail "sit should be valid"
is_valid_profile_name '../x' && fail "../x must be invalid"
is_valid_profile_name 'Local' && fail "uppercase must be invalid"
is_valid_profile_name '' && fail "empty must be invalid"

[ "$(select_profile "$tmp" sit)" = "sit" ] || fail "explicit profile"
printf 'local\n' > "$tmp/.glseven-profile"
[ "$(select_profile "$tmp" '')" = "local" ] || fail "saved profile"
rm -f "$tmp/.glseven-profile"
if select_profile "$tmp" '' 2>/dev/null; then fail "missing profile must fail"; fi
if select_profile "$tmp" '../x' 2>/dev/null; then fail "invalid explicit must fail"; fi
[ "$(profile_file "$tmp" sit)" = "$tmp/.env.sit" ] || fail "profile_file path"

printf 'profile tests: OK\n'
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash .github/scripts/test-profile.sh`
Expected: FAIL，`common/profile.sh: No such file or directory`

- [ ] **Step 3: 实现 `common/profile.sh`**

```bash
#!/usr/bin/env bash
ACTIVE_PROFILE_FILE=".glseven-profile"

is_valid_profile_name() {
  [[ "${1:-}" =~ ^[a-z0-9_-]+$ ]]
}

profile_file() {
  printf '%s/.env.%s\n' "$1" "$2"
}

select_profile() {
  local script_dir="$1" explicit="${2:-}" saved=""
  if [ -n "$explicit" ]; then
    is_valid_profile_name "$explicit" || {
      printf 'Error: invalid profile name: %s\n' "$explicit" >&2
      return 1
    }
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -f "$script_dir/$ACTIVE_PROFILE_FILE" ]; then
    saved="$(tr -d '[:space:]' < "$script_dir/$ACTIVE_PROFILE_FILE")"
  fi
  if [ -n "$saved" ]; then
    is_valid_profile_name "$saved" || {
      printf 'Error: invalid saved profile: %s\n' "$saved" >&2
      return 1
    }
    printf '%s\n' "$saved"
    return 0
  fi
  printf 'Error: no profile selected; use --profile local|sit\n' >&2
  return 1
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .github/scripts/test-profile.sh`
Expected: `profile tests: OK`

- [ ] **Step 5: 提交**

```bash
git add common/profile.sh .github/scripts/test-profile.sh
git commit -m "feat(profile): 增加配置档案选择与校验"
```

---

### Task 2: 数据目录解析支持指定档案并展开 HOME

**Files:**
- Modify: `common/docker-volume.sh`
- Modify: `.github/scripts/test-docker-volume.sh`

**Interfaces:**
- Consumes: 无
- Produces: `resolve_docker_volume SCRIPT_DIR POSITIONAL PLATFORM HOME_DIR [ENV_FILE]`，第 5 个参数缺省为 `SCRIPT_DIR/.env`

- [ ] **Step 1: 写失败测试**

在 `test-docker-volume.sh` 的 `assert_eq` 用例之后追加：

```bash
env_local="$TMP_ROOT/volume-local.env"
printf 'DOCKER_VOLUME=/from-local-profile\n' > "$env_local"
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir" "$env_local")" \
  "/from-local-profile" \
  "explicit env file is used"

home_env="$TMP_ROOT/volume-home.env"
printf 'DOCKER_VOLUME=$HOME/docker/glseven\n' > "$home_env"
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir" "$home_env")" \
  "$home_dir/docker/glseven" \
  "expands \$HOME prefix"

tilde_env="$TMP_ROOT/volume-tilde.env"
printf 'DOCKER_VOLUME=~/docker/glseven\n' > "$tilde_env"
assert_eq \
  "$(resolve_docker_volume "$fixture" "" Darwin "$home_dir" "$tilde_env")" \
  "$home_dir/docker/glseven" \
  "expands ~ prefix"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash .github/scripts/test-docker-volume.sh`
Expected: FAIL，`explicit env file is used: expected '/from-local-profile', got ...`

- [ ] **Step 3: 修改 `resolve_docker_volume`**

- 函数第 5 个参数 `env_file="${5:-$1/.env}"`。
- 读文件的分支从 `$script_dir/.env` 改为 `$env_file`。
- 在返回前对最终值做前缀展开：

```bash
case "$value" in
  "~/"*)     value="$home_dir/${value#\~/}" ;;
  '$HOME/'*) value="$home_dir/${value#\$HOME/}" ;;
  '${HOME}/'*) value="$home_dir/${value#\$\{HOME\}/}" ;;
esac
```

对位置参数、导出的 `DOCKER_VOLUME`、档案值、平台默认值统一走这段展开。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .github/scripts/test-docker-volume.sh`
Expected: `docker-volume tests: OK`

- [ ] **Step 5: 提交**

```bash
git add common/docker-volume.sh .github/scripts/test-docker-volume.sh
git commit -m "feat(volume): 支持指定档案并展开 HOME"
```

---

### Task 3: local / sit 档案模板与 gitignore

**Files:**
- Rename: `.env.example` → `.env.local.example`
- Create: `.env.sit.example`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: Task 1 的档案命名 `.env.<name>`
- Produces: 两份模板，键为 `DOCKER_VOLUME`、`KAFKA_EXTERNAL_HOST`、`REDIS_PASSWORD`

- [ ] **Step 1: 写失败检查**

Run:
```bash
git check-ignore -q .env.local .env.sit .glseven-profile || echo "NOT IGNORED"
```
Expected: 输出 `NOT IGNORED`

- [ ] **Step 2: 创建模板并改 gitignore**

`.env.local.example`：

```bash
# Local development profile. Copy to .env.local (gitignored) and adjust.
DOCKER_VOLUME=$HOME/docker/glseven
KAFKA_EXTERNAL_HOST=127.0.0.1
REDIS_PASSWORD=glseven_redis_2024
```

`.env.sit.example`：

```bash
# Home test server (sit) profile. Copy to .env.sit (gitignored) and adjust.
DOCKER_VOLUME=/docker/glseven
KAFKA_EXTERNAL_HOST=192.168.31.100
REDIS_PASSWORD=glseven_redis_2024
```

`.gitignore` 的 secrets 段替换为：

```gitignore
# Local environment profiles (copy from *.example)
.env
.env.*
!.env.*.example
.glseven-profile
```

并在文件末尾追加：

```gitignore
# Local-only portal vhosts
portal/conf/conf.d/*.local.conf
```

用 `git mv .env.example .env.local.example` 保留历史。

- [ ] **Step 3: 运行检查确认通过**

Run:
```bash
git check-ignore -q .env.local .env.sit .glseven-profile && echo "IGNORED"
git check-ignore -q .env.local.example && echo "TEMPLATE IGNORED (BAD)" || echo "TEMPLATE TRACKED"
```
Expected: `IGNORED` 与 `TEMPLATE TRACKED`

- [ ] **Step 4: 提交**

```bash
git add .gitignore .env.local.example .env.sit.example
git commit -m "chore(env): 拆分 local/sit 配置模板"
```

---

### Task 4: preflight 校验档案并收紧权限

**Files:**
- Modify: `common/preflight.sh`
- Modify: `.github/scripts/test-docker-volume.sh`

**Interfaces:**
- Consumes: 环境变量 `PROFILE_FILE`（由 `startup.sh` 导出）
- Produces: `ensure_profile_file()`，缺失文件或缺少键时 `exit 1`

- [ ] **Step 1: 写失败测试**

在 `test-docker-volume.sh` 末尾追加，替换原有的 `ensure_env_file` 子 shell：

```bash
(
  SCRIPT_DIR="$TMP_ROOT/preflight-profile"
  mkdir -p "$SCRIPT_DIR"
  PROFILE_FILE="$SCRIPT_DIR/.env.local"
  printf 'DOCKER_VOLUME=/tmp/glseven\nREDIS_PASSWORD=x\n' > "$PROFILE_FILE"
  # shellcheck source=../../common/preflight.sh
  source "$ROOT_DIR/common/preflight.sh"
  ensure_profile_file >/dev/null
)
printf 'DOCKER_VOLUME=/tmp/glseven\n' > "$TMP_ROOT/preflight-profile/.env.local"
if ( PROFILE_FILE="$TMP_ROOT/preflight-profile/.env.local"; source "$ROOT_DIR/common/preflight.sh"; ensure_profile_file ) 2>/dev/null; then
  fail "profile missing REDIS_PASSWORD must fail"
fi
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash .github/scripts/test-docker-volume.sh`
Expected: FAIL，`ensure_profile_file: command not found`

- [ ] **Step 3: 实现并接线**

- 删除 `ensure_env_file`，新增 `ensure_profile_file`：检查 `PROFILE_FILE` 已设置、文件存在、`DOCKER_VOLUME` 与 `REDIS_PASSWORD` 非空；失败时打印 `cp <file>.example <file>` 提示并 `exit 1`；成功后 `chmod 600`。
- `run_preflight` 改为调用 `ensure_profile_file`，横幅把 `env` 改为 `profile`。
- `fix_dir_permissions` 中处理 `.env` 的块改为遍历 `"$SCRIPT_DIR"/.env.*`，跳过 `*.example`，逐个 `chmod 600`。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .github/scripts/test-docker-volume.sh`
Expected: `docker-volume tests: OK`

- [ ] **Step 5: 提交**

```bash
git add common/preflight.sh .github/scripts/test-docker-volume.sh
git commit -m "feat(preflight): 校验配置档案并收紧权限"
```

---

### Task 5: startup.sh 支持 --profile 与档案插值

**Files:**
- Modify: `startup.sh`

**Interfaces:**
- Consumes: `common/profile.sh`、`resolve_docker_volume` 的第 5 个参数、`ensure_profile_file`
- Produces: 导出 `PROFILE`、`PROFILE_FILE`、`DOCKER_VOLUME`；写入 `.glseven-profile`

- [ ] **Step 1: 写失败检查**

Run:
```bash
bash startup.sh --profile ../x 2>&1 | grep -q 'invalid profile name' && echo "REJECTED" || echo "NOT REJECTED"
```
Expected: `NOT REJECTED`

- [ ] **Step 2: 改造参数解析与档案选择**

在 `source docker-volume.sh` 之后、解析 `DOCKER_VOLUME` 之前加入：

```bash
PROFILE=""
POSITIONAL_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile|-p)
      [ $# -ge 2 ] || { echo "Error: --profile requires a value"; exit 2; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#*=}"; shift ;;
    --*)
      echo "Error: unknown option: $1"; exit 2 ;;
    *)
      POSITIONAL_DIR="$1"; shift ;;
  esac
done

# shellcheck source=common/profile.sh
source "$SCRIPT_DIR/common/profile.sh"
PROFILE="$(select_profile "$SCRIPT_DIR" "$PROFILE")" || exit 1
PROFILE_FILE="$(profile_file "$SCRIPT_DIR" "$PROFILE")"
if [ ! -f "$PROFILE_FILE" ]; then
  echo "Error: profile file not found: $PROFILE_FILE"
  echo "Hint: cp ${PROFILE_FILE}.example ${PROFILE_FILE}"
  exit 1
fi
printf '%s\n' "$PROFILE" > "$SCRIPT_DIR/$ACTIVE_PROFILE_FILE"
export PROFILE PROFILE_FILE
```

- [ ] **Step 3: 解析数据目录并替换 compose 调用**

- `resolve_docker_volume "$SCRIPT_DIR" "$POSITIONAL_DIR" "$(uname -s)" "$HOME" "$PROFILE_FILE"`。
- 新增：
  ```bash
  compose() { docker compose --env-file "$PROFILE_FILE" "$@"; }
  ```
- 所有 `docker compose` 调用改为 `compose`。
- 启动横幅打印 `PROFILE` 与 `DOCKER_VOLUME`。

- [ ] **Step 4: 运行检查确认通过**

Run:
```bash
bash -n startup.sh
bash startup.sh --profile ../x 2>&1 | grep -q 'invalid profile name' && echo "REJECTED"
bash startup.sh --profile nope 2>&1 | grep -q 'profile file not found' && echo "MISSING OK"
```
Expected: `REJECTED` 与 `MISSING OK`

- [ ] **Step 5: 提交**

```bash
git add startup.sh
git commit -m "feat(startup): 支持 --profile 与档案插值"
```

---

### Task 6: shutdown.sh 解析档案并导出 DOCKER_VOLUME

**Files:**
- Modify: `shutdown.sh`

**Interfaces:**
- Consumes: Task 1 的 `select_profile`、Task 2 的 `resolve_docker_volume`
- Produces: 与 startup 相同的 `--env-file` 行为

- [ ] **Step 1: 写失败检查**

Run:
```bash
grep -q 'env-file' shutdown.sh && echo "HAS ENV FILE" || echo "MISSING ENV FILE"
```
Expected: `MISSING ENV FILE`

- [ ] **Step 2: 实现**

- 解析 `--profile|-p` 与 `--profile=*`，其余参数报错。
- source `common/profile.sh`，`select_profile` 失败则 `exit 1`。
- source `common/docker-volume.sh`，导出 `DOCKER_VOLUME="$(resolve_docker_volume "$SCRIPT_DIR" "" "$(uname -s)" "$HOME" "$PROFILE_FILE")"`。
- 新增 `compose()` 包装并替换三处 `docker compose`。
- 档案文件缺失时报错并提示 `--profile`。

- [ ] **Step 3: 运行检查确认通过**

Run:
```bash
bash -n shutdown.sh
grep -q -- '--env-file' shutdown.sh && echo "HAS ENV FILE"
bash shutdown.sh --profile ../x 2>&1 | grep -q 'invalid profile name' && echo "REJECTED"
```
Expected: `HAS ENV FILE` 与 `REJECTED`

- [ ] **Step 4: 提交**

```bash
git add shutdown.sh
git commit -m "fix(shutdown): 解析档案并导出数据目录"
```

---

### Task 7: compose 数据目录缺失时快速失败

**Files:**
- Modify: `docker-compose-infra.yml`（10 处）
- Modify: `docker-compose-apps.yml`、`docker-compose-observability.yml`、`docker-compose-security.yml`、`docker-compose-platform.yml`（共 15 处）

**Interfaces:**
- Consumes: Task 3 的档案文件
- Produces: 未设置 `DOCKER_VOLUME` 时 Compose 以明确错误退出

- [ ] **Step 1: 写失败检查**

Run:
```bash
[ -f .env.local ] || cp .env.local.example .env.local
tmp_env="$(mktemp)"
docker compose --env-file "$tmp_env" -f docker-compose-infra.yml config -q 2>&1 | grep -q 'DOCKER_VOLUME' && echo "ALREADY FAILS" || echo "STILL DEFAULTS"
```
Expected: `STILL DEFAULTS`

- [ ] **Step 2: 批量替换**

Run:
```bash
perl -pi -e 's/\$\{DOCKER_VOLUME:-\/docker\/glseven\}/\${DOCKER_VOLUME:?DOCKER_VOLUME is required (set it in the active profile)}/g' docker-compose-*.yml
```
Expected: `grep -c` 合计 25 处，`docker-compose-portal.yml` 为 0。

- [ ] **Step 3: 运行检查确认通过**

Run:
```bash
grep -c 'DOCKER_VOLUME:?' docker-compose-*.yml
tmp_env="$(mktemp)"
docker compose --env-file "$tmp_env" -f docker-compose-infra.yml config -q 2>&1 | grep -q 'required variable DOCKER_VOLUME' && echo "FAIL FAST OK"
docker compose --env-file .env.local -f docker-compose-infra.yml config -q && echo "PROFILE OK"
```
Expected: 五个文件计数合计 25；`FAIL FAST OK`；`PROFILE OK`

- [ ] **Step 4: 提交**

```bash
git add docker-compose-infra.yml docker-compose-apps.yml docker-compose-observability.yml docker-compose-security.yml docker-compose-platform.yml
git commit -m "fix(compose): 数据目录缺失时快速失败"
```

---

### Task 8: Kafka 宿主地址改由档案注入

**Files:**
- Modify: `common/env/kafka.env`
- Modify: `docker-compose-infra.yml`

**Interfaces:**
- Consumes: 档案中的 `KAFKA_EXTERNAL_HOST`
- Produces: `KAFKA_ADVERTISED_LISTENERS` 由 compose `environment` 渲染

- [ ] **Step 1: 写失败检查**

Run:
```bash
docker compose --env-file .env.local -f docker-compose-infra.yml config | grep -q 'EXTERNAL://127.0.0.1:29092' && echo "ALREADY LOCAL" || echo "STILL HARDCODED"
```
Expected: `STILL HARDCODED`

- [ ] **Step 2: 实现**

- 从 `common/env/kafka.env` 删除 `KAFKA_ADVERTISED_LISTENERS=...`，替换为一行注释：`# KAFKA_ADVERTISED_LISTENERS is rendered by docker-compose-infra.yml from the active profile.`
- 在 kafka 服务的 `env_file` 之后加入：
  ```yaml
  environment:
    KAFKA_ADVERTISED_LISTENERS: "PLAINTEXT://kafka:9092,EXTERNAL://${KAFKA_EXTERNAL_HOST:-127.0.0.1}:29092"
  ```

- [ ] **Step 3: 运行检查确认通过**

Run:
```bash
docker compose --env-file .env.local -f docker-compose-infra.yml config | grep -q 'EXTERNAL://127.0.0.1:29092' && echo "LOCAL OK"
[ -f .env.sit ] || cp .env.sit.example .env.sit
docker compose --env-file .env.sit -f docker-compose-infra.yml config | grep -q 'EXTERNAL://192.168.31.100:29092' && echo "SIT OK"
```
Expected: `LOCAL OK` 与 `SIT OK`

- [ ] **Step 4: 提交**

```bash
git add common/env/kafka.env docker-compose-infra.yml
git commit -m "fix(kafka): 宿主地址改由配置档案注入"
```

---

### Task 9: athena 改为本机专属 vhost

**Files:**
- Rename: `portal/conf/conf.d/athena.conf` → `portal/conf/conf.d/athena.local.conf`
- Modify: `portal/conf/conf.d/athena.local.conf`
- Modify: `common/check-consistency.sh`

**Interfaces:**
- Consumes: Task 3 的 `.gitignore` 模式
- Produces: `*.local.conf` 不参与一致性反查

- [ ] **Step 1: 写失败检查**

Run: `bash common/check-consistency.sh --strict`
Expected: 非零退出，输出 `athena.conf：server_name athena.glseven.local 无对应容器`

- [ ] **Step 2: 改名并改上游**

```bash
mv portal/conf/conf.d/athena.conf portal/conf/conf.d/athena.local.conf
```

把 `server` 块改为：

```nginx
server {
    listen 8080;
    server_name athena.glseven.local;

    resolver 127.0.0.11 valid=10s ipv6=off;
    set $athena_web "web:80";

    client_max_body_size 64m;

    location / {
        proxy_pass http://$athena_web;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

文件头补一行：`# 本机专属配置：文件名为 *.local.conf，已 gitignore，不参与一致性校验。`

- [ ] **Step 3: 一致性脚本跳过本地配置**

先在 `issues=0` 旁初始化 `skipped=0`，再在 `for f in portal/conf/conf.d/*.conf` 循环开头加入：

```bash
case "$f" in
  *.local.conf) skipped=$((skipped + 1)); continue ;;
esac
```

循环结束后打印 `consistency: 跳过 $skipped 个本地配置`。

- [ ] **Step 4: 运行检查确认通过**

Run:
```bash
bash common/check-consistency.sh --strict && echo "CONSISTENCY OK"
grep -q 'resolver 127.0.0.11' portal/conf/conf.d/athena.local.conf && echo "RESOLVER OK"
git check-ignore -q portal/conf/conf.d/athena.local.conf && echo "IGNORED"
```
Expected: 三项均通过

- [ ] **Step 5: 提交**

```bash
git add common/check-consistency.sh
git commit -m "fix(portal): athena 改为本机专属配置"
```

（`athena.local.conf` 被 gitignore，不进入提交。）

---

### Task 10: Nacos 开启客户端 API 鉴权

**Files:**
- Modify: `common/env/nacos.env`

**Interfaces:**
- Consumes: 无
- Produces: `NACOS_AUTH_ENABLE=true`，token/identity 保持不变

- [ ] **Step 1: 写失败检查**

Run:
```bash
grep -q '^NACOS_AUTH_ENABLE=true' common/env/nacos.env && echo "ENABLED" || echo "NOT ENABLED"
```
Expected: `NOT ENABLED`

注：`env_file` 的内容不会出现在 `docker compose config` 的输出里，所以本任务直接检查 env 文件。

- [ ] **Step 2: 实现**

在 `common/env/nacos.env` 的 `MODE=standalone` 之后加入：

```bash
# 客户端 SDK / gRPC / OpenAPI 鉴权（3.2.4 默认关闭；控制台与 admin 默认开启）。
NACOS_AUTH_ENABLE=true
```

- [ ] **Step 3: 运行检查确认通过**

Run:
```bash
grep -q '^NACOS_AUTH_ENABLE=true' common/env/nacos.env && echo "ENABLED"
grep -q '^NACOS_AUTH_TOKEN=' common/env/nacos.env && echo "TOKEN KEPT"
grep -q '^NACOS_AUTH_IDENTITY_KEY=' common/env/nacos.env && echo "IDENTITY KEPT"
```
Expected: 三项均通过

- [ ] **Step 4: 提交**

```bash
git add common/env/nacos.env
git commit -m "feat(nacos): 开启客户端 API 鉴权"
```

---

### Task 11: CI 与文档收尾

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: 前面所有任务
- Produces: CI 使用 `.env.local`；文档描述新命令

- [ ] **Step 1: 写失败检查**

Run:
```bash
grep -q -- '--env-file' .github/workflows/ci.yml && echo "CI READY" || echo "CI MISSING"
grep -q -- '--profile' README.md && echo "DOC READY" || echo "DOC MISSING"
```
Expected: `CI MISSING` 与 `DOC MISSING`

- [ ] **Step 2: 修改 CI**

- `Prepare Compose environment` 改为：`cp .env.local.example .env.local`。
- 新增步骤 `Test profile selection`：`bash .github/scripts/test-profile.sh`。
- 新增步骤 `Assert profiles are ignored`：
  ```bash
  git check-ignore -q .env.local
  git check-ignore -q .env.sit
  git check-ignore -q .glseven-profile
  if git check-ignore -q .env.local.example; then exit 1; fi
  ```
- Compose 校验循环改为 `docker compose --env-file .env.local -f "$file" config -q`。

- [ ] **Step 3: 更新文档**

README 快速开始改为两条路径：

```bash
# 本机
cp .env.local.example .env.local
bash startup.sh --profile local

# 家里测试服务器
cp .env.sit.example .env.sit
# 编辑 .env.sit：DOCKER_VOLUME、KAFKA_EXTERNAL_HOST
bash startup.sh --profile sit
```

并补充：`--profile` 可省略（沿用 `.glseven-profile`）；单域命令必须带 `--env-file`；`*.local.conf` 为本机专属；Nacos 客户端鉴权与首次管理员初始化；Kafka 宿主地址在档案里。

CLAUDE.md 同步命令与约定，删除「`cp .env.example .env`」。

- [ ] **Step 4: 运行检查确认通过**

Run:
```bash
grep -q -- '--env-file' .github/workflows/ci.yml && echo "CI READY"
grep -q -- '--profile local' README.md && echo "DOC READY"
bash common/check-consistency.sh --strict && echo "CONSISTENCY OK"
for f in docker-compose-*.yml; do docker compose --env-file .env.local -f "$f" config -q || exit 1; done; echo "COMPOSE OK"
```

- [ ] **Step 5: 提交**

```bash
git add .github/workflows/ci.yml README.md CLAUDE.md
git commit -m "ci: 适配配置档案并更新文档"
```

---

## 实施后的运行时验证（需要 Docker daemon）

- [ ] 本机：`bash startup.sh --profile local`，确认横幅中的档案与 `DOCKER_VOLUME`；`bash shutdown.sh` 能正常停止并移除网络。
- [ ] sit：`bash startup.sh --profile sit`；宿主客户端 `kafka-broker-api-versions --bootstrap-server localhost:29092` 成功。
- [ ] `docker exec nginx nginx -t` 通过；停掉 athena 容器后 `docker exec nginx nginx -s reload` 不报错。
- [ ] Nacos：未带凭据的客户端 API 返回 401/403；控制台完成管理员初始化后可登录。
- [ ] 两台宿主各确认一次数据目录与 `DOCKER_VOLUME` 打印值一致。

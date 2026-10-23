# 设计文档：GitHub Actions CI 与自动语义版本发布

- 日期：2026-10-23
- 状态：已经用户逐节确认
- 范围：glseven-docker 的静态 CI、Conventional Commits 自动升版、annotated tag 与 GitHub Release

## 1. 背景与目标

仓库是纯 Docker Compose 配置编排，没有应用构建与单元测试。现有验证手段是六个 Compose 文件的静态渲染和跨域一致性脚本；远端位于 GitHub。当前只有手工创建的 `v1.0.0`，`develop` 相对该标签包含 1 个 `feat` 和多个 `fix` 提交。

目标：

1. 对面向 `develop` / `main` 的 PR 和 `develop` push 执行稳定的静态 CI。
2. 合并到 `main` 后，按 Conventional Commits 自动计算下一个 SemVer。
3. 自动创建 annotated tag 和中文分类 GitHub Release。
4. 重复运行不重复升版；失败后重跑可以补完发布。
5. 不引入 npm、第三方发布 Action、PAT 或额外 secret。

本次发布范围为用户确认的当前全部 `develop` 变更；首个自动版本预期为 `v1.1.0`。

## 2. 决策记录

| 决策点 | 结论 |
|---|---|
| CI 平台 | GitHub Actions |
| 发布触发 | CI 通过后，push 到 `main` 自动发布 |
| 版本规则 | `feat` 升 minor；`fix` / `perf` / `refactor` 升 patch；breaking change 升 major |
| 无版本提交 | 仅 `docs` / `test` / `ci` / `chore` / `style` 时跳过发布 |
| CI 深度 | 静态校验；不启动整套服务 |
| Release 内容 | 自动生成中文分组变更记录 |
| 实现路径 | 原生 GitHub Actions + 仓库内 Bash 发布脚本 |
| 凭证 | 只使用 `GITHUB_TOKEN` |

## 3. 总体架构

```text
PR -> develop/main            push -> develop
          │                         │
          └────────────┬────────────┘
                       ▼
               .github/workflows/ci.yml
          bash syntax / compose / consistency
                       │
                       │ push -> main 且校验通过
                       ▼
             .github/workflows/release.yml
              next-version.sh -> tag -> gh release
                       │
                       ▼
            annotated tag + GitHub Release
```

### 3.1 文件边界

| 文件 | 职责 |
|---|---|
| `.github/workflows/ci.yml` | 可复用静态 CI；PR、`develop` push 和 `workflow_dispatch` 入口 |
| `.github/workflows/release.yml` | `main` push 发布入口；调用 CI，计算版本并发布 |
| `.github/scripts/next-version.sh` | 查找基线 tag、解析提交、计算下一版本或判断幂等状态 |
| `.github/scripts/release-notes.sh` | 根据两个 tag 之间的提交生成中文 Markdown |
| `.github/scripts/test-release-scripts.sh` | 在临时 Git 仓库验证版本与 notes 脚本 |

`.github/scripts` 仅由 CI/Release 使用，不混入 `common/` 下的部署脚本。

### 3.2 触发与权限

`ci.yml`：

- `workflow_call`
- `workflow_dispatch`
- `pull_request`，目标分支为 `develop`、`main`
- `push` 到 `develop`
- `permissions.contents: read`

`release.yml`：

- 仅 `push` 到 `main`
- 先复用 `ci.yml`，校验不通过时不进入发布 job
- 发布 job 使用 `permissions.contents: write`
- `concurrency.group: release-main`，`cancel-in-progress: false`，避免并发产生双版本
- checkout 使用完整历史和 tags，供 SemVer 与 Release Notes 计算

仓库的 Actions Workflow Permissions 必须允许 workflow 申请 `contents: write`；这是 GitHub 仓库设置，不是仓库内密钥。

## 4. CI 设计

CI 使用 `ubuntu-latest`，步骤固定为：

1. checkout。
2. 对所有 Git 跟踪的 `*.sh` 执行 `bash -n`。
3. 从 `.env.example` 生成仅存在于 runner 工作区的 `.env`。
4. 对每个 `docker-compose-*.yml` 执行 `docker compose -f <file> config -q`。
5. 执行 `bash common/check-consistency.sh`。
6. 执行 `bash .github/scripts/test-release-scripts.sh`。
7. 按本次变更范围执行 `git diff --check`：PR 比较 merge-base 到 `HEAD`，push 比较 event before 到 `HEAD`。

不引入 `shellcheck`：当前开发机未安装，且引入后可能要求修改与本次发布无关的存量脚本。GitHub 自身会解析 workflow YAML；Compose 文件由 `docker compose config -q` 校验。

`develop` 只做 CI。PR 的 CI 在分支与目标上下文均可单独重跑。

## 5. 版本计算设计

### 5.1 基线 tag

只考虑从当前 `HEAD` 可到达、且严格匹配 `vMAJOR.MINOR.PATCH` 的 tag。使用 Git 的版本排序取得最高语义版本，不按 tag 创建时间排序。无历史 tag 时基线为 `v0.0.0`。

### 5.2 bump 规则

检查基线 tag 到 `HEAD` 的全部提交：

1. 提交正文含 `BREAKING CHANGE:` 或标题 type 带 `!`：major。
2. 存在 `feat`：minor。
3. 存在 `fix`、`perf` 或 `refactor`：patch。
4. 若上述三类可发布变更均不存在，则跳过发布；只有 `docs`、`test`、`ci`、`chore`、`style`、`build` 或非 Conventional Commits 的区间不会产生版本。

多重条件取最高级别，不叠加 bump。Merge commit 本身不做分类；其可达的普通提交仍参与计算。

当前 `v1.0.0..develop` 含 `feat(portal)`，当前 `develop` 全量合并到 `main` 后应产生 `v1.1.0`。

### 5.3 幂等状态

脚本输出机器可读状态，供 workflow 区分：

- 有版本提交且 HEAD 尚未有目标 tag：创建新 tag 并发布。
- 最新 SemVer tag 已指向 HEAD：不再升版，输出 `release=true`；若 Release 不存在则补建。
- 没有版本提交且 HEAD 无 tag：正常跳过。

发布 job 串行执行是主要并发保护；“tag 已指向 HEAD”检查负责 workflow 重跑幂等。

## 6. Release Notes 设计

Release 标题为 `vX.Y.Z`，正文包含（发布日期按 `Asia/Shanghai` 计算）：

- 发布日期。
- `破坏性变更`（仅 breaking change 存在时）。
- `功能`：`feat`。
- `修复`：`fix`。
- `优化`：`perf`、`refactor`。
- `文档`：`docs`。
- `其他`：其余被纳入发布的有效 Conventional Commits。
- `完整变更`：GitHub compare URL。

每条记录保留提交标题，并链接到对应 commit。Merge commit 与非 Conventional Commits 不进入分组列表。发布后不维护仓库内 `CHANGELOG.md`；GitHub Release 是唯一版本记录。

## 7. 发布流程与失败处理

发布顺序：

1. 调用静态 CI。
2. 计算基线、目标版本和提交分组。
3. 在本地创建 annotated tag。
4. 推送 tag。
5. 使用 `gh release create` 创建 GitHub Release。

失败语义：

- CI 失败：发布 job 不运行，不产生 tag 或 Release。
- tag 推送失败：不创建 Release。
- tag 已推送但 Release 创建失败：workflow 重跑时识别 tag 已指向 HEAD，只补建 Release。
- Release 已存在：发布 job 正常结束，不重复创建。
- 无可发布提交：输出跳过原因，job 成功结束。

## 8. 脚本接口

### 8.1 `next-version.sh`

在仓库根目录运行，读取当前 `HEAD` 与 tags，并向 stdout 输出以下 `key=value`：

```text
release=true|false
version=vX.Y.Z|<empty>
tag_on_head=true|false
previous_tag=vX.Y.Z|<empty>
bump=major|minor|patch|none
```

这是 workflow 与脚本之间的稳定接口；测试脚本对字段和值做断言。

`release=true` 表示 workflow 应进入发布步骤；新建 tag 与“tag 已在 HEAD、仅补 Release”都返回 true。`tag_on_head=true` 时，`previous_tag` 取该 tag 之前的下一个可达 SemVer tag，用于生成比较链接。

### 8.2 `release-notes.sh`

接口：

```text
release-notes.sh --from <previous-tag> --to <target-tag> --repository <owner/repo>
```

向 stdout 输出完整 Markdown。compare URL 使用 `GITHUB_SERVER_URL`，未设置时默认 `https://github.com`。

### 8.3 测试覆盖

`test-release-scripts.sh` 创建临时 Git 仓库并验证：

1. 仅 `fix`：patch。
2. 含 `feat` 与 `fix`：minor。
3. `!` 或 `BREAKING CHANGE:`：major。
4. 仅 `docs` / `ci`：跳过。
5. 最新 tag 已指向 HEAD：`tag_on_head=true`，不再次 bump。
6. Release Notes 分组、commit 链接及 compare URL 正确。
7. 无历史 tag 时从 `v0.0.0` 开始。

## 9. 验收标准

1. 本地 `bash -n`、发布脚本测试、六个 Compose 渲染与一致性检查全部通过。
2. PR 到 `develop` 的 GitHub Actions 校验为绿色。
3. `develop` push 的 GitHub Actions 校验为绿色。
4. 当前 `develop` 全量合并到 `main` 后，自动产生指向该合并提交的 `v1.1.0` annotated tag。
5. 对应 GitHub Release 包含中文分组变更和 `v1.0.0...v1.1.0` 比较链接。
6. 重跑同一提交的 Release workflow 不会产生 `v1.1.1` 或重复 Release。
7. 后续仅含 `docs` / `ci` 的 `main` push 不产生新版本。

## 10. 明示不做

- 不启动整套 Docker 服务做运行态 smoke test。
- 不引入 nightly 全栈测试。
- 不自动创建或修改 `CHANGELOG.md`。
- 不引入 semantic-release、npm、第三方 tag/release Action。
- 不使用 PAT、GitHub App 或额外 secrets。
- 不自动合并 `develop` 到 `main`；分支合并仍由用户发起。

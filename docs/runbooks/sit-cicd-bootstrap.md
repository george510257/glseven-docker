# sit CI/CD 平台 bootstrap 与运维手册

适用：legion（sit）上的 GitLab CE + GitLab Runner 平台。设计见 `docs/superpowers/specs/2026-11-21-sit-cicd-platform-design.md`，流水线定义见 `.gitlab-ci.yml`。

## 1. 首次引导（一次性）

### 1.1 启动 GitLab

```bash
ssh legion
cd /vol1/1000/glseven-docker
git pull --ff-only
sudo bash startup.sh --profile sit
docker inspect -f '{{.State.Health.Status}}' gitlab    # 期望 healthy（首次 5-10 分钟）
```

`startup.sh` 只在 `sit` 档案启动 devops 域；`local` 档案不会启动 GitLab。

### 1.2 初始 root 密码

```bash
docker exec gitlab cat /etc/gitlab/initial_root_password
```

登录 `http://gitlab.glseven.local:8080`（用户名 `root`）后立即修改密码；该文件 24 小时后自动删除。

### 1.3 注册 GitLab Runner

1. GitLab 管理区 → CI/CD → Runners → New instance runner，标签 `sit`，取认证 token（`glrt-...`）。
2. 注册并写入运行参数：

```bash
docker exec gitlab-runner gitlab-runner register \
  --non-interactive --url http://gitlab:8080 --token <glrt-...> \
  --executor docker --docker-image docker:29.10.0-cli --tag-list sit
```

3. 编辑 `/vol1/1000/docker_volume/gitlab-runner/config/config.toml`，确认：

```toml
concurrent = 1

[[runners]]
  url = "http://gitlab:8080"
  executor = "docker"
  [runners.docker]
    image = "docker:29.10.0-cli"
    network_mode = "glseven"
    pull_policy = ["if-not-present"]
    extra_hosts = ["gitlab.glseven.local:172.18.7.1"]
    volumes = [
      "/var/run/docker.sock:/var/run/docker.sock",
      "/vol1/1000/glseven-docker:/vol1/1000/glseven-docker",
      "/vol1/1000/docker_volume:/vol1/1000/docker_volume",
      "/vol1/1000/docker_volume/gitlab-runner/cache:/cache"
    ]
```

4. 重启并验证：

> 从旧版本升级：`config.toml` 位于数据目录、不在仓库中，`url` 需手动改为 `http://gitlab:8080`，再执行 `docker restart gitlab-runner`；已有项目的 HTTP remote 同步改到 8080、SSH remote 改到 2222（旧端口已释放）；GitLab 需重建容器并等待首次 reconfigure（约数分钟）。

```bash
docker restart gitlab-runner
docker exec gitlab-runner gitlab-runner list
docker run --rm --network glseven --add-host gitlab.glseven.local:172.18.7.1 \
  curlimages/curl:8.23.0 -sS -o /dev/null -w '%{http_code}\n' \
  http://gitlab.glseven.local:8080/-/readiness    # 期望 200
```

说明：`extra_hosts` 让作业容器解析 GitLab 外部域名（`CI_REPOSITORY_URL` 依赖它）；三个 volume 必须按宿主原路径挂载，否则 compose 的相对路径挂载会失效并触发全量重建。

### 1.4 宿主 Docker 允许 Nexus registry

```bash
sudo vi /etc/docker/daemon.json    # 增加 "insecure-registries": ["192.168.31.100:5000"]
sudo systemctl restart docker
docker pull 192.168.31.100:5000/docker-hosted/<测试镜像>   # 验证（需先建仓库并推过一个镜像）
```

### 1.5 Nexus 仓库

登录 `http://nexus3.glseven.local:8081`：

- 确认 Maven 仓库（releases / snapshots / central 代理 / 聚合组）已存在；缺失则补建。
- 新建 `npm-hosted`、`npm-proxy`（https://registry.npmjs.org）、`npm-group`（hosted + proxy）。
- 新建 `docker-hosted`，HTTP 连接器端口 `5000`（portal 已预留 5000 → nexus3:5000）。
- 记录管理员凭据，供 Phase 2 的 CI 变量 `NEXUS_USER` / `NEXUS_PASS` 使用。

### 1.6 仓库迁移与 GitHub 镜像

1. GitLab 建组 `glseven`，项目 `glseven-docker`（后续 athena 仓库同组）。
2. 推送全部分支与 tag：

```bash
git remote add gitlab ssh://git@gitlab.glseven.local:2222/glseven/glseven-docker.git
git push gitlab --all
git push gitlab --tags
```

3. 把本地/服务器 clone 的 `origin` 切到 GitLab，GitHub 改名 `backup`：

```bash
git remote rename origin backup
git remote rename gitlab origin
```

4. GitLab 项目 → Settings → Repository → Mirroring repositories：push mirror 到 `https://github.com/george510257/glseven-docker.git`，使用 classic PAT（`repo` 权限），只镜像受保护分支与 tag。

### 1.7 首条流水线验证

推送一次无功能改动的提交到 `develop`，在 GitLab 观察：

```text
validate → deploy:sit → smoke
```

期望：两个作业通过，`environment: sit` 出现部署记录，smoke 输出 `Smoke: OK`。随后验证 annotated tag：

```bash
git -C /vol1/1000/glseven-docker cat-file -t <version>   # 期望 tag
```

## 2. 日常运维

- **部署**：push `develop` 自动执行 `deploy:sit`；改动 `devops/docker-compose.yml` 时该作业被跳过（`when: never`），必须宿主手工执行（CI 部署会重启 GitLab 本体并中断作业）：

  ```bash
  cd /vol1/1000/glseven-docker
  git fetch origin
  git checkout -f develop
  git reset --hard origin/develop
  sudo bash startup.sh --profile sit
  ```
- **回滚**：GitLab web → Run pipeline（分支选 `develop`）→ 手动运行 `deploy:sit:rollback`，变量 `ROLLBACK_SHA` 填目标提交（必须在 develop 历史或 tag 中可达）。
- **发布**：push `main` 触发 `release`，需要项目访问令牌 `RELEASE_TOKEN`（`api` + `write_repository`，masked 变量）。
- **内存**：`docker stats --no-stream`、`free -h`；GitLab 常驻目标 ≤ 3.5 GiB，构建并发固定为 1。紧张时先减 JVM 堆，再考虑调低 fnOS 自带 ES 堆或加内存。

## 3. 备份（手工）

```bash
docker exec gitlab gitlab-backup create
sudo tar -czf /vol1/backup/gitlab-config-$(date +%F).tar.gz \
  -C /vol1/1000/docker_volume/gitlab config
```

`gitlab/config` 含 `gitlab-secrets.json`，与备份包分开保管。恢复流程见 GitLab 官方文档（先恢复 config，再执行 `gitlab-backup restore`）。

## 4. 排障

| 现象 | 处理 |
|---|---|
| 作业 checkout 失败 / `Could not resolve host: gitlab.glseven.local` | 检查 runner `config.toml` 的 `extra_hosts`；用 `docker run --rm --network glseven --add-host gitlab.glseven.local:172.18.7.1 curlimages/curl:8.23.0 -sS -o /dev/null -w '%{http_code}\n' http://gitlab.glseven.local:8080/-/readiness` 验证（期望 200） |
| 部署后容器挂载为空或全量重建 | 检查 runner volume 是否按宿主原路径挂载（不得挂到 `/deploy`） |
| `dubious ownership` | 部署脚本会 `chown -R 1000:1000 /vol1/1000/glseven-docker`；手工操作前确认属主 |
| smoke 报 unhealthy | `docker ps`、`docker logs <容器>`；先修服务再重跑 `deploy:sit` |
| GitLab 502（本机 local） | 预期行为：devops 仅 sit 启动 |
| 内存吃紧 / swap 增长 | 降 JVM 堆、调低 fnOS 自带 ES 堆或加内存；保持 runner 并发 1 |
| Runner offline | `docker logs gitlab-runner`，确认 token、`url = http://gitlab:8080` 与网络 `glseven` |

## 5. 迁移切换清单

1. GitLab 流水线验证通过（第 1.7 节）。
2. 删除 `.github/workflows/`（GitHub Actions 下线）。
3. GitHub 仓库设置中关闭 Actions，仓库仅作 push mirror。
4. 更新团队/个人 clone 的 `origin`（第 1.6 节）。

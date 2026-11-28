---
name: glseven-deploy
description: 把使用方项目容器化并部署到 glseven 测试环境（sit）时使用。覆盖镜像构建与推 Nexus、compose 接入 glseven 网络、portal 入口、数据库/中间件配置、验证与回滚。
---

# 把项目部署到 glseven 测试环境

## 何时使用

- 需要把使用方项目（首个 athena）部署到 sit。
- 需要确认部署目录、镜像命名、网络接入、portal 入口和回滚方式。
- 部署后要验证或排查。

## 前置条件

- 能 `ssh legion`（sit，192.168.31.100）。
- Nexus registry 可用：`192.168.31.100:5000`，仓库 `docker-hosted`；sit 宿主已配置 insecure-registries（见 sit runbook §1.4）。
- 开发机 Docker Desktop 也要把 `192.168.31.100:5000` 加入 `insecure-registries`，并用 Nexus 凭据 `docker login`。开发机是 arm64、sit 是 amd64，镜像必须 `--platform linux/amd64`。
- sit 内存余量：先用 `free -h` / `docker stats --no-stream` 检查；不足 2.5–3 GiB 时先调低 fnOS ES 堆（约 11 → 6 GiB）或加内存。

## 部署模型

- 部署目录：`/vol1/1000/projects/<project>/`，放 compose、`.env`（600）和必要配置；不放进 glseven-docker。
- 镜像名：单段 `192.168.31.100:5000/docker-hosted/<project>-<service>:<tag>`。
- 服务名/容器名/网络别名：`<project>-<service>`，避免与其它项目在共享 `glseven` 网络上冲突。
- 不发布宿主端口；入口统一由 portal 的 `*.local.conf` vhost 代理。
- compose 加入外部网络 `glseven`，`restart: always`；按项目自身依赖写 `depends_on` / 启动顺序。

## 手动部署流程

见 `references/deploy-flow.md`。

## athena 示例

见 `references/athena.md`。

## 模板

`references/templates/`：

- `Dockerfile.java`：Spring Boot fat jar 镜像。
- `Dockerfile.web`：多份前端 dist 的 nginx 镜像。
- `nginx.web.conf`：主应用/子应用路径与 API、OAuth2 反代。
- `docker-compose.project.yml`：外部网络、服务名前缀、无宿主端口。
- `portal-project.conf`：portal vhost。
- `gitlab-ci.project.yml`：可选的 GitLab CI 模板。
- `env.project.example`：部署 `.env` 模板。

## 不要做

- 不在使用方 compose 里写宿主 `ports:`。
- 不给每个前端各起一个 nginx；用一个 web 容器托管全部 dist。
- 不把凭据提交到仓库，或不通过命令行参数传密码。
- 不在 sit 上直接 `mvn` 构建多个仓库（内存与 GitHub Packages 凭据都不合适）。

## 安全

- 部署目录 `.env` 权限 600，不入库。
- 不复制服务器端密钥（`NACOS_AUTH_TOKEN` 等）给使用方。
- 镜像按 `linux/amd64` 构建；日志不打印凭据。

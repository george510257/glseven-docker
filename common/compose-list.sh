#!/bin/bash
# Compose 文件清单（唯一数据源）：
# - BASE：基础设施服务（infra：数据/消息/etcd；observability：监控栈），第一批启动。
# - DEFERRED：依赖 MySQL 就绪后再启动（security:keycloak、platform:nacos/xxl-job-admin 需要 MySQL 完成初始化；
#   apps 无 MySQL 依赖，随 DEFERRED 保持与旧批次一致）。
# - PORTAL：nginx 导航门户，最后启动（导航的目标服务先就绪）。
# 关闭时按启动顺序（BASE + DEFERRED + PORTAL）的逆序执行。

COMPOSE_FILES_BASE=(infra observability)
COMPOSE_FILES_DEFERRED=(security platform apps)
COMPOSE_FILES_PORTAL=(portal)

# Apple Silicon 的 amd64 ELK 无法在 Rosetta 模拟层提供 seccomp；只启动可用的监控服务。
COMPOSE_SERVICES_OBSERVABILITY_APPLE_SILICON=(prometheus grafana)

is_apple_silicon() {
  [[ "${1:-}" == "Darwin" && "${2:-}" == "arm64" ]]
}

#!/bin/bash
# Compose 文件清单（唯一数据源）：
# - BASE：基础设施服务，第一批启动。
# - DEFERRED：依赖 MySQL 就绪后再启动（nacos/xxl-job-admin 需要 MySQL 完成初始化）。
# 关闭时按启动顺序（BASE + DEFERRED）的逆序执行。

COMPOSE_FILES_BASE=(storage messaging auth devops manager monitor)
COMPOSE_FILES_DEFERRED=(microservices ai tv)

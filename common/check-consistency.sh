#!/bin/bash
# 服务同步一致性校验（由 startup.sh 的 preflight 调用，只告警不阻断）。
#
# 背景：本编排「新增一个服务」需要同步 5 处，散落在不同文件里，没有任何机制保证不漏。
# iptv（commit 815c5ca）6 处同步点都改到了，但那是人工核对的运气，不是设计——
# 漏 /etc/hosts 那行的失败现象是「浏览器打不开」而非配置报错，最难定位。
# 本脚本把这些同步点变成可机械检查的断言，新增服务时漏改会在这里报出来。
#
# 检查的是三类「必须有对应文件/条目」的关系：
#   1. 每个 compose 服务有 portal/conf/{conf.d,stream-conf.d}/<name>.conf（内部服务豁免）
#   2. 每个 conf.d/*.conf 的 server_name 子域名有对应容器（反查，抓孤立 vhost / 改名遗漏）
#   3. 有 HTTP 入口的服务在门户 index.html 有卡片、且 README 的 /etc/hosts 清单含其子域名
# 另：服务的 container_name 与 hostname 必须一致（子域名 = 容器名 约定的前提），
# 提取服务清单时即按此过滤，不一致的服务根本不会进入下面的检查（属静默跳过，非断言）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 0

# 纯协议服务：无 HTTP 界面，不需要 conf.d 与门户卡片（走 stream 或仅容器网络内）。
PROTOCOL_ONLY="mysql redis mongo rabbitmq kafka etcd openldap ollama filebeat"
# 有意无门户卡片但确有 HTTP 入口的服务（在 conf.d 里，只是没放导航）。
NO_CARD_OK="apisix elk"
# 门户自身：nginx 服务根域 glseven.local（不是二级域名），且是代理方而非被代理方，
# 三类「应有 conf.d/卡片/hosts 条目」的检查对它都不适用。
PORTAL_SELF="nginx"
# 内部服务：只在容器网络内提供服务，宿主侧完全不暴露（nginx 里有意不出现），
# 因此三类检查一并豁免。与 PROTOCOL_ONLY 的区别：后者有 stream 转发到宿主，本类没有。
# filebeat=日志生产者，无用户界面；keycloak 的 9000 管理端口同理（见 README「仅容器网络内」）。
INTERNAL_ONLY="filebeat"

is_in() { local n="$1" list="$2"; [[ " $list " == *" $n "* ]]; }

issues=0
warn() { echo "  [!] $*"; issues=$((issues + 1)); }

# 从全部 compose 文件提取服务的 container_name / hostname 对。
# 用 awk 按服务块切分，避免引入 yq 依赖（preflight 只能依赖 docker/bash/grep 这类必有工具）。
services=$(for f in docker-compose-*.yml; do
  awk -v file="$f" '
    /^  [a-z0-9-]+:$/ { name=$1; sub(/:$/,"",name) }
    /^    container_name:/ { cn=$2 }
    /^    hostname:/ { hn=$2; if (cn != "" && hn != "" && cn == hn) print cn; cn=""; hn="" }
  ' "$f"
done | sort -u)

[[ -z "$services" ]] && { echo "  [!] 未能从 compose 提取任何服务（解析逻辑失效？）"; exit 0; }

# 1) 每个服务应有 conf.d 或 stream-conf.d 配置（纯协议服务与门户自身豁免）
for svc in $services; do
  is_in "$svc" "$PORTAL_SELF" && continue
  is_in "$svc" "$INTERNAL_ONLY" && continue
  has_http=false; has_stream=false
  [[ -f "portal/conf/conf.d/$svc.conf" ]] && has_http=true
  [[ -f "portal/conf/stream-conf.d/$svc.conf" ]] && has_stream=true
  if ! $has_http && ! $has_stream; then
    warn "${svc}：既无 portal/conf/conf.d/$svc.conf 也无 stream-conf.d/$svc.conf"
  elif ! $has_http && ! is_in "$svc" "$PROTOCOL_ONLY"; then
    warn "${svc}：无 conf.d 配置，但不在纯协议服务清单内（有 HTTP 入口却未代理？）"
  fi
done

# 2) conf.d 里出现的每个 server_name 子域名，都应有同名容器（抓孤立 vhost / 改名后遗留）
for f in portal/conf/conf.d/*.conf; do
  for sub in $(grep -hoE 'server_name[[:space:]]+[a-z0-9.-]+\.glseven\.local' "$f" | awk '{print $2}' | sed 's/\.glseven\.local$//' | sort -u); do
    is_in "$sub" "$(echo "$services" | tr '\n' ' ')" || warn "$(basename "$f")：server_name $sub.glseven.local 无同名容器"
  done
done

# 3) 有 HTTP 入口的服务应在门户页有卡片
for svc in $services; do
  is_in "$svc" "$PROTOCOL_ONLY" && continue
  is_in "$svc" "$NO_CARD_OK" && continue
  is_in "$svc" "$PORTAL_SELF" && continue
  is_in "$svc" "$INTERNAL_ONLY" && continue
  grep -q "data-host=\"$svc\"" portal/html/index.html || warn "${svc}：门户页 portal/html/index.html 缺卡片"
done

# 4) /etc/hosts 初始化清单（README 里的那行命令）应覆盖所有子域名
hosts_line=$(grep -oE "echo '127\.0\.0\.1 glseven\.local.*glseven\.local'" README.md | head -1)
if [[ -n "$hosts_line" ]]; then
  for svc in $services; do
    is_in "$svc" "$PROTOCOL_ONLY" && continue
    is_in "$svc" "$PORTAL_SELF" && continue
    is_in "$svc" "$INTERNAL_ONLY" && continue
    [[ "$hosts_line" == *"$svc.glseven.local"* ]] || warn "${svc}：README 的 /etc/hosts 初始化清单缺 $svc.glseven.local（二级域名将不解析）"
  done
else
  warn "未能从 README.md 定位 /etc/hosts 初始化清单，跳过该项校验"
fi

if [[ "$issues" -eq 0 ]]; then
  echo "  consistency: OK（$(echo "$services" | wc -l | tr -d ' ') 个服务的门户/代理/hosts 同步点齐全）"
else
  echo "  consistency: $issues 项待同步（仅告警，不阻断启动）"
fi
exit 0

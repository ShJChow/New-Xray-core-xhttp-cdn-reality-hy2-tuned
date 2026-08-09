# ==================================================
# 安装管理命令 xh + 保活自愈 + 内核自动更新
# ==================================================

info "[7/7] 安装管理命令 ${MANAGE_CMD}"

cat > "$MANAGE_BIN" << 'XHMANAGEEOF'
#!/bin/bash
# xray-xhttp 管理命令
# 用法: xh [子命令]，不带参数进入交互菜单

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

MANAGE_CMD="xh"
STATE_DIR="/etc/xhttp-cdn"
NODE_ENV_FILE="${STATE_DIR}/node.env"
SUB_TOKEN_FILE="${STATE_DIR}/sub_token"
SYSCTL_CONF="/etc/sysctl.d/99-xray-xhttp.conf"
LIMITS_CONF="/etc/security/limits.d/99-xray-xhttp.conf"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
CRON_TAG="# xray-xhttp"

[[ $EUID -ne 0 ]] && fail "请使用 root 用户运行"

if [[ -f "$NODE_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$NODE_ENV_FILE"
else
  warn "未找到 ${NODE_ENV_FILE}，部分信息不可用（是否尚未运行安装脚本？）"
fi

if [[ -z "${SERVICE_TYPE:-}" ]]; then
  if command -v systemctl >/dev/null 2>&1; then SERVICE_TYPE="systemd"; else SERVICE_TYPE="openrc"; fi
fi

# 兜底：node.env 通常带这两项，但老版本或文件缺失时 tuning 仍要能跑
PROJECT_NAME="${PROJECT_NAME:-xray-xhttp}"
if [[ -z "${OS_ID:-}" && -f /etc/os-release ]]; then
  OS_ID=$(. /etc/os-release && echo "$ID")
fi

svc() {
  local action="$1" name="$2"
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    rc-service "$name" "$action"
  else
    systemctl "$action" "$name"
  fi
}

svc_active() {
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    rc-service "$1" status >/dev/null 2>&1
  else
    systemctl is-active --quiet "$1"
  fi
}

# ---------------- 子命令 ----------------

cmd_status() {
  echo -e "${CYAN}[+] 服务状态${NC}"
  for s in xray nginx hysteria-server; do
    if [[ "$SERVICE_TYPE" == "openrc" ]]; then
      [[ -f "/etc/init.d/$s" ]] || continue
    else
      systemctl list-unit-files "${s}.service" >/dev/null 2>&1 || continue
      [[ -f "/etc/systemd/system/${s}.service" || -f "/lib/systemd/system/${s}.service" ]] || continue
    fi
    if svc_active "$s"; then
      echo -e "  ${s}: ${GREEN}running${NC}"
    else
      echo -e "  ${s}: ${RED}stopped${NC}"
    fi
  done

  echo -e "\n${CYAN}[+] 监听端口${NC}"
  if command -v ss >/dev/null 2>&1; then
    ss -tulnp 2>/dev/null | grep -E 'xray|nginx|hysteria' || echo "  （未发现相关监听）"
  else
    warn "未安装 ss，跳过端口检查"
  fi

  echo -e "\n${CYAN}[+] 流控状态${NC}"
  printf '  %-32s %s\n' "net.core.default_qdisc"          "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
  printf '  %-32s %s\n' "net.ipv4.tcp_congestion_control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
  printf '  %-32s %s\n' "net.core.rmem_max"               "$(sysctl -n net.core.rmem_max 2>/dev/null || echo n/a)"
  printf '  %-32s %s\n' "net.ipv4.tcp_fastopen"           "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo n/a)"
  printf '  %-32s %s\n' "机型 / 调优档位" "${CPU_CORES:-?} 核 / ${MEM_MB:-?} MB / ${ARCH:-?} → ${TUNE_TIER:-未知}"
  printf '  %-32s %s\n' "Xray policy.bufferSize" "${XRAY_BUFFER_KB:-未设置} KB"
  if [[ -f "$SYSCTL_CONF" ]]; then
    printf '  %-32s %s\n' "调优配置文件" "$SYSCTL_CONF（已启用）"
  else
    printf '  %-32s %s\n' "调优配置文件" "未启用（安装时自动开启，或手动 xh tuning on）"
  fi
  if [[ "$SERVICE_TYPE" == "systemd" ]] && svc_active xray; then
    local pid
    pid=$(systemctl show -p MainPID --value xray 2>/dev/null)
    if [[ -n "$pid" && "$pid" != "0" && -r "/proc/$pid/limits" ]]; then
      printf '  %-32s %s\n' "xray 进程 nofile" "$(awk '/Max open files/{print $4}' "/proc/$pid/limits")"
    fi
  fi

  echo -e "\n${CYAN}[+] 版本${NC}"
  [[ -x "$XRAY_BIN" ]] && echo "  $($XRAY_BIN version 2>/dev/null | head -1)"
  command -v nginx >/dev/null 2>&1 && echo "  $(nginx -v 2>&1)"
}

cmd_info() {
  [[ -f "$NODE_ENV_FILE" ]] || fail "未找到节点信息文件 ${NODE_ENV_FILE}"
  echo -e "${CYAN}[+] 节点参数${NC}"
  echo "  安装时间:        ${INSTALL_TIME:-未知}"
  echo "  Reality 域名:    ${REALITY_DOMAIN}"
  echo "  CDN 域名:        ${CDN_DOMAIN}"
  echo "  VPS IP:          ${VPS_IP}"
  echo "  UUID1 (Vision):  ${UUID1}"
  echo "  UUID2 (XHTTP):   ${UUID2}"
  echo "  Public Key:      ${PUBLIC_KEY}"
  echo "  Short ID:        ${SHORT_ID}"
  echo "  XHTTP Path:      ${XHTTP_PATH}"
  echo "  VLESS Enc:       ${VLESSENC_ENCRYPTION}"
  echo "  xpadding:        ${FEATURE_XPADDING:-false}"
  [[ "${FEATURE_XPADDING:-false}" == true ]] && \
    echo "  xpadding 字段:   header=${XHTTP_PADDING_HEADER} key=${XHTTP_PADDING_KEY}"
  echo "  CDN ECH:         ${CDN_ECH_ENABLED:-false}"
  echo ""
  echo -e "${CYAN}[+] CDN 独立 inbound${NC}"
  echo "  CDN 独立端口:   TCP ${CDN_DIRECT_PORT:-2053}（TLS + XHTTP，走 CF Origin Rule 回源）"
  echo "    ⚠ 用真实证书，应在安全组只放行 Cloudflare IP 段，否则暴露源站 IP"
  echo ""
  echo -e "${CYAN}[+] 直连 UDP 节点${NC}"
  if [[ "${FEATURE_H3_DIRECT:-false}" == true ]]; then
    echo "  h3-direct:       UDP ${H3_PORT:-443}（Xray 自己监听，不经 nginx）"
  else
    echo "  h3-direct:       未启用"
  fi
  if [[ "${FEATURE_HY2:-false}" == true ]]; then
    echo "  Hysteria2:       UDP ${HY2_PORT:-8443}"
    echo "    认证密码:      ${HY2_PASSWORD}"
    echo "    混淆:          salamander（Xray finalmask）"
    echo "    混淆密码:      ${OBFS_PASSWORD}"
    echo "    ↑ 两个密码是独立的值，客户端两处都要填对才能握手"
  else
    echo "  Hysteria2:       未启用"
  fi
  if [[ -f "$SYSCTL_CONF" ]]; then
    echo "  系统层调优:      已开启（${MANAGE_CMD} tuning off 可回滚）"
  else
    echo "  系统层调优:      未开启（${MANAGE_CMD} tuning on 开启）"
  fi
  echo ""
  echo -e "${YELLOW}[+] 客户端节点${NC}"
  local f="${USER_HOME:-/root}/client-config.txt"
  [[ -f "$f" ]] && cat "$f" || warn "未找到 $f"
}

cmd_sub() {
  [[ -f "$SUB_TOKEN_FILE" ]] || fail "未找到订阅 token，请先运行安装脚本"
  local token base
  token=$(tr -d '\r\n' < "$SUB_TOKEN_FILE")
  base="https://${REALITY_DOMAIN}/sub/${token}"
  echo -e "${CYAN}[+] 订阅链接${NC}"
  echo "  V2RayN (base64):       ${base}/v2rayn.txt"
  # 明文订阅一直有生成，但 v1.2.3 之前从未对外列出。部分 iOS 客户端
  # （Shadowrocket / onexray）对 base64 订阅更挑剔，明文是有效的备选。
  echo "  明文节点（备选）:      ${base}/v2rayn-raw.txt"
  echo "  Mihomo 完整分流:       ${base}/mihomo-full.yaml"
  echo "  Mihomo 纯节点:         ${base}/mihomo-nodes.yaml"
  echo ""
  echo -e "${YELLOW}  订阅拉不到节点时，先在该设备的浏览器里直接打开上面的链接：${NC}"
  echo "    打得开且有内容 → 客户端解析问题，改用明文订阅或手动导入单条节点"
  echo "    打不开         → 该设备到 VPS 的网络问题，与本项目配置无关"
  if command -v qrencode >/dev/null 2>&1; then
    echo ""
    echo -e "${YELLOW}[+] V2RayN / Shadowrocket 订阅二维码${NC}"
    qrencode -t ANSIUTF8 -m 1 "${base}/v2rayn.txt"
  fi
}

# 手工改过 ~/client-config.txt 后，用它把订阅文件重新生成，无需重跑安装脚本
cmd_resub() {
  [[ -f "$SUB_TOKEN_FILE" ]] || fail "未找到订阅 token，请先运行安装脚本"
  local home token subdir
  home="${USER_HOME:-/root}"
  token=$(tr -d '\r\n' < "$SUB_TOKEN_FILE")
  subdir="/usr/local/nginx/html/sub/${token}"
  [[ -d "$subdir" ]] || fail "未找到订阅目录 ${subdir}"
  [[ -f "${home}/client-config.txt" ]] || fail "未找到 ${home}/client-config.txt"

  cp "${home}/client-config.txt" "${subdir}/v2rayn-raw.txt"
  base64 "${home}/client-config.txt" | tr -d '\n' > "${subdir}/v2rayn.txt"
  [[ -f "${home}/client-config-mihomo-full.yaml" ]]  && cp "${home}/client-config-mihomo-full.yaml"  "${subdir}/mihomo-full.yaml"
  [[ -f "${home}/client-config-mihomo-nodes.yaml" ]] && cp "${home}/client-config-mihomo-nodes.yaml" "${subdir}/mihomo-nodes.yaml"
  info "订阅已按当前 client-config.txt 重新生成（客户端需手动更新订阅）"
  cmd_sub
}

# /etc/sysctl.d/ 里的冲突与残留检测。
# 背景：这台机器上常常跑过不止一个调优脚本。systemd-sysctl 按**文件名字典序**
# 加载，后加载的覆盖先加载的——也就是说别人的文件只要排在 99-xray-xhttp.conf
# 之后，就会静默覆盖掉本项目的值，而且没有任何报错。
# 本函数只报告，不删除任何文件：那些文件不是本项目产生的，脚本无权处置。
cmd_conflict() {
  local ours="99-xray-xhttp.conf" d=/etc/sysctl.d
  echo -e "${CYAN}[+] sysctl 配置冲突检测${NC}"
  [[ -f "$SYSCTL_CONF" ]] || { info "本项目未写入 sysctl（系统层调优关闭），无冲突可言"; echo ""; return 0; }

  local ourkeys conflict=0
  ourkeys=$(sed 's/#.*//; s/=.*//; s/[[:space:]]//g' "$SYSCTL_CONF" | grep -E '^[a-z]' | sort -u)

  for f in "$d"/*.conf; do
    [[ -f "$f" ]] || continue
    local base; base=$(basename "$f")
    [[ "$base" == "$ours" ]] && continue
    local dup; dup=$(sed 's/#.*//; s/=.*//; s/[[:space:]]//g' "$f" | grep -E '^[a-z]' | sort -u |
                     comm -12 - <(echo "$ourkeys") 2>/dev/null)
    [[ -z "$dup" ]] && continue
    conflict=1
    if [[ "$base" > "$ours" ]]; then
      echo -e "  ${RED}[!!]${NC} $base 排在本项目之后，会**覆盖**以下参数："
    else
      echo -e "  ${YELLOW}[--]${NC} $base 与本项目重叠，但排序在前，被本项目覆盖（当前无害）："
    fi
    echo "$dup" | sed 's/^/         /'
  done
  [[ "$conflict" -eq 0 ]] && echo -e "  ${GREEN}[OK]${NC}   未发现与其它 sysctl 文件的参数重叠"

  # 不会被加载的残留（systemd-sysctl 只读 *.conf）
  local junk; junk=$(ls "$d" 2>/dev/null | grep -vE '\.conf$|^README' || true)
  if [[ -n "$junk" ]]; then
    echo ""
    echo -e "  ${YELLOW}[--]${NC} 以下文件不以 .conf 结尾，systemd-sysctl 不会加载（仅占位，可自行清理）："
    echo "$junk" | sed 's/^/         /'
    echo "         清理: mkdir -p /root/sysctl-backup && mv /etc/sysctl.d/*.disabled.* /etc/sysctl.d/*.bak /root/sysctl-backup/"
  fi

  echo ""
  echo -e "  ${CYAN}实际生效值（以内核为准，与文件内容无关）${NC}"
  for k in net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog \
           net.core.rmem_max net.ipv4.tcp_congestion_control net.core.default_qdisc; do
    printf '    %-36s %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo n/a)"
  done
  echo ""
}

# UDP / HTTP3 节点连不上时的自检。
#
# v4.0.0 起本项目有三类 UDP 节点，排查路径互不相同：
#   1. Vless-xhttp-tls-UDP-cdn —— 经 CDN。**不经过本机任何 QUIC 配置**：
#      Cloudflare 边缘用 HTTP/3 面对客户端，回源到本机仍是 TCP。
#      它不通 = 常规 XHTTP 链路的问题，与本机 UDP 无关。
#   2. Vless-xhttp-h3-direct / Hysteria2-obfs —— 由 **Xray 自己 bind UDP**，
#      既不经 nginx 也没有独立 hysteria 二进制。查的是 xray 进程的监听。
#   3. add-quic-h3 扩展的节点 —— 由 nginx listen quic 提供（下方单独检查）。
# 判据：1 通而 2 全不通 → 云厂商安全组没放行 UDP，或内核 <26.6.1。
cmd_diag() {
  cmd_conflict
  local ok=0 bad=0
  chk() { # chk 描述 结果(0/1) 补充说明
    if [[ "$2" -eq 0 ]]; then echo -e "  ${GREEN}[OK]${NC}   $1${3:+ — $3}"; ok=$((ok+1))
    else echo -e "  ${RED}[!!]${NC}   $1${3:+ — $3}"; bad=$((bad+1)); fi
  }

  echo -e "${CYAN}[+] 服务端侧自检${NC}"

  if nginx -t >/dev/null 2>&1; then
    chk "nginx -t 配置有效" 0
  else
    chk "nginx -t 失败" 1 "执行 nginx -t 看具体报错"
  fi

  if svc_active nginx; then chk "nginx 运行中" 0; else chk "nginx 未运行" 1 "${MANAGE_CMD} restart"; fi
  if svc_active xray;  then chk "xray 运行中"  0; else chk "xray 未运行"  1 "${MANAGE_CMD} restart"; fi

  # CDN 流量经 Xray:443 fallback 直达 127.0.0.1:8001 XHTTP inbound（对齐 argosbx/Yulinanami）；
  # nginx:8003 仅用于 Reality 握手失败时的伪装站（realitySettings.target）
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | grep -qE ':443'  && chk "已监听 TCP 443"  0 || chk "未监听 TCP 443"  1 "Xray 未启动？"
    ss -lntp 2>/dev/null | grep -qE ':8003' && chk "已监听 TCP 8003" 0 || chk "未监听 TCP 8003" 1 "nginx 未启动？"
  else
    warn "未安装 ss，跳过端口监听检查"
  fi

  # location 的 gRPC 超时：缺失会让 XHTTP 长连接每 60 秒被 nginx 切断
  if grep -q 'grpc_read_timeout' /etc/nginx/nginx.conf 2>/dev/null; then
    chk "nginx location 已放大 grpc 读写超时" 0
  else
    chk "nginx location 缺少 grpc_read_timeout" 1 "XHTTP 长连接会每 60 秒断一次；重跑安装脚本"
  fi

  # ---------- 直连 UDP / QUIC（add-quic-h3 与 Hysteria2 扩展）----------
  # 走 CDN 的节点不碰这些；只有**直连 VPS 裸 IP 的 UDP** 节点依赖它们。
  # 三条 h3 节点同时不通、而经 CDN 的 h3 节点正常时，唯一共同点就是这一层。
  QUIC_PORTS=""
  if grep -q '# BEGIN quic-h3' /etc/nginx/nginx.conf 2>/dev/null; then
    QUIC_PORTS=$(grep -A2 '# BEGIN quic-h3' /etc/nginx/nginx.conf | grep -oE 'listen [0-9]+ quic' | grep -oE '[0-9]+')
    chk "nginx 已配置 quic-h3 段（UDP ${QUIC_PORTS:-?}）" 0
  fi
  if grep -q '# BEGIN quic xhttp' /etc/nginx/nginx.conf 2>/dev/null; then
    QUIC_PORTS="${QUIC_PORTS} $(grep -A2 '# BEGIN quic xhttp' /etc/nginx/nginx.conf | grep -oE 'listen [0-9]+ quic' | grep -oE '[0-9]+')"
    chk "nginx 已配置 quic xhttp 段" 0
  fi

  if [[ -n "${QUIC_PORTS// /}" ]] && command -v ss >/dev/null 2>&1; then
    for p in $QUIC_PORTS; do
      # 配置里写了 listen quic，但进程没真的 bind UDP —— nginx -t 查不出这种情况（L14）
      if ss -lnup 2>/dev/null | grep -qE ":${p}\b"; then
        chk "已监听 UDP ${p}" 0
      else
        chk "未监听 UDP ${p}" 1 "配置里有 listen ${p} quic 但进程未 bind；查 ${MANAGE_CMD} log nginx"
      fi
    done
  fi

  # ---------- v4.0.0 的两条直连 UDP 节点（由 Xray 自己监听）----------
  # 与上面 nginx quic 段的区别：h3-direct 与 Hysteria2 都是 Xray 直接 bind UDP，
  # 既不经 nginx 也没有独立的 hysteria 二进制，所以要查的是 xray 进程的监听。
  # CDN 独立 inbound（v4.3.0 起）：Xray 直接 bind TCP，不经 nginx。
  # 没监听不算致命——Origin Rule 未配置时 CDN 流量仍走 443 回落链。
  if command -v ss >/dev/null 2>&1; then
    if ss -lntp 2>/dev/null | grep -qE ":${CDN_DIRECT_PORT:-2053}\b"; then
      chk "CDN 独立 inbound 已监听 TCP ${CDN_DIRECT_PORT:-2053}" 0
    else
      chk "CDN 独立 inbound 未监听 TCP ${CDN_DIRECT_PORT:-2053}" 1 \
        "证书缺失时会跳过该 inbound；CDN 节点仍可走 443 回落。查 ${MANAGE_CMD} log xray"
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    if [[ "${FEATURE_H3_DIRECT:-false}" == true ]]; then
      if ss -lnup 2>/dev/null | grep -qE ":${H3_PORT:-443}\b"; then
        chk "h3-direct 已监听 UDP ${H3_PORT:-443}" 0
      else
        chk "h3-direct 未监听 UDP ${H3_PORT:-443}" 1 "config.json 里有该 inbound 但未 bind；查 ${MANAGE_CMD} log xray"
      fi
    fi
    if [[ "${FEATURE_HY2:-false}" == true ]]; then
      if ss -lnup 2>/dev/null | grep -qE ":${HY2_PORT:-8443}\b"; then
        chk "Hysteria2 已监听 UDP ${HY2_PORT:-8443}" 0
      else
        chk "Hysteria2 未监听 UDP ${HY2_PORT:-8443}" 1 "查 ${MANAGE_CMD} log xray；确认内核 ≥26.6.1"
      fi
    fi
  fi

  # 内核版本闸门：低于 26.6.1 时 finalmask 的 UDP listener 会在收到第一个无效包后
  # 死亡（issue #6184），表现是「节点先能用、跑一阵后静默全挂、重启又好」。
  # 这类故障靠看配置查不出来，只能靠版本号提前拦截。
  if [[ "${FEATURE_HY2:-false}" == true || "${FEATURE_H3_DIRECT:-false}" == true ]]; then
    XV=$([[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$XV" ]]; then
      if [[ "$(printf '%s\n26.6.1\n' "$XV" | sort -V | head -n1)" == "26.6.1" ]]; then
        chk "Xray ${XV} ≥ 26.6.1（finalmask UDP listener 已修复）" 0
      else
        chk "Xray ${XV} < 26.6.1" 1 "finalmask UDP listener 会在收到无效包后静默死亡（#6184），执行 ${MANAGE_CMD} update"
      fi
    fi
  fi

  # 旧版遗留：独立 hysteria 二进制。v4.0.0 起 Hysteria2 由 Xray 原生提供，
  # 两者同时在会抢同一个 UDP 端口。
  if [[ -f /etc/hysteria/config.yaml ]]; then
    chk "检测到独立 hysteria 二进制的配置" 1 \
      "v4.0.0 起 Hysteria2 由 Xray 原生提供，两者会抢端口；停用: systemctl disable --now hysteria-server"
  fi

  # 本机防火墙：只报告，不改动（规则可能是用户或云厂商 agent 写的）
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q .; then
    nft list ruleset 2>/dev/null | grep -qiE 'udp.*(accept|dport)' \
      && chk "nftables 有 UDP 相关规则" 0 \
      || chk "nftables 未见放行 UDP 的规则" 1 "直连 UDP 节点可能被本机防火墙挡下"
  elif command -v iptables >/dev/null 2>&1 && [[ $(iptables -S 2>/dev/null | wc -l) -gt 3 ]]; then
    iptables -S 2>/dev/null | grep -qi 'udp' \
      && chk "iptables 有 UDP 相关规则" 0 \
      || chk "iptables 未见放行 UDP 的规则" 1 "直连 UDP 节点可能被本机防火墙挡下"
  fi

  echo ""
  echo -e "${CYAN}[+] 结论与下一步${NC}"
  if [[ $bad -eq 0 ]]; then
    echo "  服务端侧未发现问题（$ok 项通过）。"
  else
    echo "  发现 $bad 项异常，先按上面的提示处理。"
  fi
  echo ""
  echo -e "${YELLOW}  ⚠ 直连 UDP 节点全不通、而经 CDN 的节点正常时，先查云厂商安全组${NC}"
  echo "  这一项**在机器里查不出来**——安全组在虚拟机外面，本机 ss 显示监听正常、"
  echo "  防火墙也放行，包仍可能在到达网卡之前就被云平台丢掉。"
  echo ""
  echo "    Oracle Cloud : 网络 → VCN → 安全列表 → 入站规则"
  echo "    AWS          : EC2 → 安全组 → 入站规则"
  echo "    GCP          : VPC 网络 → 防火墙"
  echo "  需要一条：协议 UDP / 源 0.0.0.0/0 / 目标端口 = 上面列出的 UDP 端口。"
  echo "  默认规则通常只开 TCP 22 与 TCP 443，加 TCP 时**不会自动带上 UDP**。"
  echo ""
  echo "  判据（Hysteria2 也是直连 VPS 裸 IP 的 UDP）："
  echo "    Hysteria2 通、h3 不通  ⇒ UDP 通路没问题，问题在 nginx QUIC 这一层"
  echo "    Hysteria2 也不通       ⇒ UDP 到本机的路被挡，先查安全组再查本机防火墙"
  echo ""
  echo -e "${YELLOW}  节点 Vless-xhttp-tls-UDP-cdn 不依赖本机任何 QUIC 配置${NC}"
  echo "  它只依赖：① Cloudflare 区域已开启 HTTP/3  ② 你的客户端网络允许 UDP 443 出站。"
  echo ""
  echo "  在客户端机器上执行下面两条来区分（任一不通即为客户端侧网络封锁 QUIC）："
  echo "    curl -sI --http3-only https://cloudflare-quic.com/ | head -1"
  echo "    curl -sI --http3-only https://${CDN_DOMAIN:-你的CDN域名}/ | head -1"
  echo "  若 curl 不支持 --http3-only，用浏览器访问 https://cloudflare-quic.com/ 看是否显示 HTTP/3。"
  echo ""
  echo "  UDP 节点不通而 TCP 节点正常 ⇒ 基本可判定为客户端侧 UDP 443 被封，"
  echo "  服务端无法解决；请改用 Vless-reality-vision / Vless-xhttp-reality 节点。"
  echo ""
  echo "  另：开启 TUN 时务必确认节点自身流量已豁免（client-config-mihomo-full.yaml"
  echo "  已内置 route-exclude-address / 首条 DIRECT 规则），否则 QUIC 会在 TUN 里自环。"
}

cmd_log() {
  case "${1:-xray}" in
    nginx) tail -n "${2:-50}" -f /usr/local/nginx/logs/error.log ;;
    xray)
      if [[ "$SERVICE_TYPE" == "systemd" ]]; then
        journalctl -u xray -n "${2:-50}" -f --no-pager
      else
        tail -n "${2:-50}" -f /var/log/xray/error.log
      fi
      ;;
    *) fail "用法: xh log [xray|nginx] [行数]" ;;
  esac
}

cmd_restart() {
  for s in xray nginx; do
    svc restart "$s" && info "${s} 已重启" || warn "${s} 重启失败"
  done
  if [[ -f /etc/hysteria/config.yaml ]]; then
    svc restart hysteria-server >/dev/null 2>&1 && info "hysteria-server 已重启" || true
  fi
}

cmd_start() { for s in xray nginx; do svc start "$s" || warn "${s} 启动失败"; done; }
cmd_stop()  { for s in xray nginx; do svc stop  "$s" || warn "${s} 停止失败"; done; }

# 更新 Xray-core：先备份，配置自检失败自动回滚
cmd_update() {
  local auto=0
  [[ "${1:-}" == "--auto" ]] && auto=1

  [[ -x "$XRAY_BIN" ]] || fail "未找到 ${XRAY_BIN}"
  local current latest backup
  current=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
  # Xray 自 v26.4.25 起把正式版 release 全标记为 GitHub prerelease，releases/latest
  # 只返回最后一个非 prerelease 的旧版。releases?per_page=1 取最新一条（不论 prerelease），
  # 返回格式 [{...}] 与旧端点的 {tag_name:...} 对 grep 提取兼容，无需改解析。
  latest=$(curl -fsSL --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4)
  latest="${latest#v}"

  if [[ -z "$latest" ]]; then
    warn "无法获取 Xray-core 最新版本号，跳过本次更新"
    return 0
  fi
  info "当前版本: ${current:-未知}  最新版本: ${latest}"
  if [[ "$current" == "$latest" ]]; then
    info "已是最新版本，无需更新"
    return 0
  fi
  if [[ $auto -eq 0 ]]; then
    read -rp "确认更新到 ${latest}? [y/N]: " reply
    [[ "${reply,,}" == "y" ]] || { info "已取消"; return 0; }
  fi

  backup="${XRAY_BIN}.bak-${current:-old}"
  cp -f "$XRAY_BIN" "$backup" || fail "备份 Xray 二进制失败，已中止更新"
  info "已备份旧版本 → ${backup}"

  local ok=0
  if [[ "${OS_ID:-}" != "alpine" ]]; then
    # --beta：不加的话官方脚本会装 RELEASE_LATEST（最后一个非 prerelease 的旧版），
    # 即使上面检测到新版本也会被装回旧版——必须与检测逻辑同一套。
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --beta -u root && ok=1
  else
    local arch asset tmpdir
    arch=$(uname -m)
    case "$arch" in
      x86_64|amd64) asset="Xray-linux-64.zip" ;;
      aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
      *) warn "Alpine 暂不支持架构 ${arch}"; return 0 ;;
    esac
    tmpdir=$(mktemp -d)
    # 用已检测到的真实最新 tag 下载（releases/latest/download 只指向非 prerelease 的旧版）
    if curl -fL "https://github.com/XTLS/Xray-core/releases/download/v${latest}/${asset}" -o "${tmpdir}/xray.zip" &&
       unzip -qo "${tmpdir}/xray.zip" -d "$tmpdir"; then
      install -m 755 "${tmpdir}/xray" "$XRAY_BIN"
      install -m 644 "${tmpdir}/geoip.dat" /usr/local/share/xray/geoip.dat 2>/dev/null || true
      install -m 644 "${tmpdir}/geosite.dat" /usr/local/share/xray/geosite.dat 2>/dev/null || true
      ok=1
    fi
    rm -rf "$tmpdir"
  fi

  if [[ $ok -ne 1 ]]; then
    warn "下载 / 安装失败，回滚到备份版本"
    cp -f "$backup" "$XRAY_BIN"
    svc restart xray || true
    return 1
  fi

  if ! "$XRAY_BIN" -test -config "$XRAY_CONF" >/dev/null 2>&1; then
    warn "新版本配置自检失败，回滚到 ${current:-旧版本}"
    cp -f "$backup" "$XRAY_BIN"
    svc restart xray || true
    return 1
  fi

  svc restart xray || { warn "重启失败，回滚"; cp -f "$backup" "$XRAY_BIN"; svc restart xray || true; return 1; }
  sleep 1
  if svc_active xray; then
    info "已更新到 $("$XRAY_BIN" version 2>/dev/null | head -1)"
  else
    warn "Xray 未能启动，回滚"
    cp -f "$backup" "$XRAY_BIN"
    svc restart xray || true
    return 1
  fi
}

cmd_tuning() {
  case "${1:-show}" in
    show)
      if [[ -f "$SYSCTL_CONF" ]]; then
        echo -e "${CYAN}[+] ${SYSCTL_CONF}${NC}"
        cat "$SYSCTL_CONF"
      else
        info "系统层调优未开启。安装时默认自动执行（跳过用 FEATURE_AUTO_TUNING=false），也可手动 ${MANAGE_CMD} tuning on"
      fi
      [[ -f "$LIMITS_CONF" ]] && { echo ""; echo -e "${CYAN}[+] ${LIMITS_CONF}${NC}"; cat "$LIMITS_CONF"; }
      ;;
    on)
      [[ -f "$SYSCTL_CONF" ]] && { info "系统层调优已处于开启状态（重跑请先 ${MANAGE_CMD} tuning off）"; return 0; }
      # v2.0.0：调优逻辑内联在本命令里，不再需要重跑安装脚本。
      # 全部 best-effort，逐项能力探测（BBR / 只读 sysctl / limits.d 是否存在），
      # 任何一项失败只 warn，不影响已经跑通的节点。
      apply_system_tuning
      ;;
    off)
      rm -f "$SYSCTL_CONF" "$LIMITS_CONF"
      rm -f /etc/systemd/system/xray.service.d/override.conf             /etc/systemd/system/nginx.service.d/override.conf
      rmdir /etc/systemd/system/xray.service.d /etc/systemd/system/nginx.service.d 2>/dev/null || true
      [[ "$SERVICE_TYPE" == "systemd" ]] && systemctl daemon-reload >/dev/null 2>&1
      sysctl --system >/dev/null 2>&1 || true
      info "已移除本项目写入的全部调优配置"
      warn "已生效的运行时内核参数需重启系统才能完全恢复默认值"
      ;;
    *) fail "用法: ${MANAGE_CMD} tuning [show|on|off]" ;;
  esac
}

@@include src/06-tuning-lib.sh

# 健康检查：服务掉线则拉起（由 cron 每 5 分钟调用）
cmd_guard() {
  local restarted=0
  for s in xray nginx; do
    if ! svc_active "$s"; then
      svc restart "$s" >/dev/null 2>&1 && restarted=1
      logger -t xray-xhttp "guard: restarted ${s}" 2>/dev/null || true
    fi
  done
  if [[ -f /etc/hysteria/config.yaml ]] && ! svc_active hysteria-server; then
    svc restart hysteria-server >/dev/null 2>&1 || true
  fi
  [[ $restarted -eq 1 ]] && info "已拉起异常服务" || true
  return 0
}

cron_write() {
  local body="$1"
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -v "$CRON_TAG" > "$tmp" || true
  [[ -n "$body" ]] && printf '%s\n' "$body" >> "$tmp"
  crontab "$tmp" && rm -f "$tmp"
}

cmd_keepalive() {
  case "${1:-show}" in
    on)
      cron_write "$(crontab -l 2>/dev/null | grep "$CRON_TAG" | grep -v 'guard'; \
        echo "*/5 * * * * /usr/local/bin/xh guard >/dev/null 2>&1 ${CRON_TAG} guard"; \
        echo "@reboot /usr/local/bin/xh guard >/dev/null 2>&1 ${CRON_TAG} guard")"
      info "保活已开启（每 5 分钟检查 + 开机自启）"
      ;;
    off)
      cron_write "$(crontab -l 2>/dev/null | grep "$CRON_TAG" | grep -v 'guard')"
      info "保活已关闭"
      ;;
    show|*)
      crontab -l 2>/dev/null | grep "$CRON_TAG" || info "未配置任何本项目 cron 任务"
      ;;
  esac
}

cmd_autoupdate() {
  case "${1:-show}" in
    on)
      cron_write "$(crontab -l 2>/dev/null | grep "$CRON_TAG" | grep -v 'update --auto'; \
        echo "0 4 * * 0 /usr/local/bin/xh update --auto >/dev/null 2>&1 ${CRON_TAG} autoupdate")"
      info "内核自动更新已开启（每周日 04:00，失败自动回滚）"
      ;;
    off)
      cron_write "$(crontab -l 2>/dev/null | grep "$CRON_TAG" | grep -v 'update --auto')"
      info "内核自动更新已关闭"
      ;;
    show|*)
      crontab -l 2>/dev/null | grep 'update --auto' || info "未开启内核自动更新"
      ;;
  esac
}

cmd_uninstall() {
  echo -e "${RED}[!] 将删除 Xray / Nginx / ACME / Hysteria2 及本项目的配置、证书、订阅文件${NC}"
  read -rp "确认卸载？输入 yes 继续: " reply
  [[ "$reply" == "yes" ]] || { info "已取消"; return 0; }

  # 停服务后**必须复核进程真的死了**再删文件。
  # 原先是 `systemctl stop ... || true` 一笔带过：stop 失败被吞掉，随后单元文件与
  # /usr/local/bin/xray 照删不误，留下「进程还活着、unit 和二进制都没了」的中间态
  # （Linux 上删掉正在运行的二进制，进程照常从内存继续跑）。
  # 下次装官方 Xray-install 时，它检测到 pidof xray 非空就去 systemctl stop xray.service，
  # 而单元已被删 → "Unit xray.service not loaded" → 脚本 exit 1，安装直接卡死。
  # 这个中间态用户自己看不出问题在哪，只能看到官方脚本报错。
  ensure_stopped() {  # ensure_stopped 进程名... —— 温和停不掉就强杀，并等它真的消失
    local p
    for p in "$@"; do
      pgrep -x "$p" >/dev/null 2>&1 || continue
      warn "${p} 在停止服务后仍在运行，强制结束"
      pkill -x "$p" >/dev/null 2>&1 || true
      sleep 1
      pgrep -x "$p" >/dev/null 2>&1 && { pkill -9 -x "$p" >/dev/null 2>&1 || true; sleep 1; }
      pgrep -x "$p" >/dev/null 2>&1 && warn "${p} 仍无法结束，请手动检查 pgrep -a ${p}"
    done
  }

  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    for s in xray nginx hysteria-server; do
      rc-service "$s" stop >/dev/null 2>&1 || true
      rc-update del "$s" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$s"
    done
    ensure_stopped xray nginx hysteria
  else
    systemctl stop xray nginx hysteria-server >/dev/null 2>&1 || true
    systemctl disable xray nginx hysteria-server >/dev/null 2>&1 || true
    ensure_stopped xray nginx hysteria
    rm -f /etc/systemd/system/xray.service \
          /etc/systemd/system/xray@.service \
          /etc/systemd/system/nginx.service \
          /etc/systemd/system/hysteria-server.service
    rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d \
           /etc/systemd/system/nginx.service.d
  fi

  rm -f  /usr/local/bin/xray /usr/local/bin/xray.bak-*
  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  rm -f  /usr/sbin/nginx
  rm -rf /usr/local/nginx /etc/nginx /var/log/nginx
  rm -f  /usr/local/bin/hysteria
  rm -rf /etc/hysteria
  rm -f  /var/log/hysteria-server.log

  crontab -l 2>/dev/null | grep -v ".acme.sh" | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
  rm -f  /usr/local/bin/acme.sh
  rm -rf /root/.acme.sh
  rm -f  /etc/ssl/private/private.key /etc/ssl/private/fullchain.cer

  rm -f "$SYSCTL_CONF" "$LIMITS_CONF"
  sysctl --system >/dev/null 2>&1 || true

  local home="${USER_HOME:-/root}"
  rm -f "${home}"/client-config.txt "${home}"/client-config-mihomo-*.yaml \
        "${home}"/client-config-v2rayn-tun.txt \
        "${home}"/subscription-links.txt "${home}"/subscription-*.png
  rm -f /root/client-config.txt /root/client-config-mihomo-*.yaml \
        /root/client-config-v2rayn-tun.txt \
        /root/subscription-links.txt /root/subscription-*.png
  rm -rf "$STATE_DIR"

  if [[ "$SERVICE_TYPE" == "systemd" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    # 不 reset-failed 的话，被删掉的 unit 会以 not-found/failed 状态挂在 systemctl 里，
    # 干扰下次安装时的状态判断
    systemctl reset-failed >/dev/null 2>&1 || true
  fi
  # 收尾自检：卸载后仍有残留进程是下次安装失败的主要来源，这里必须说出来
  for p in xray nginx hysteria; do
    pgrep -x "$p" >/dev/null 2>&1 && warn "注意：仍检测到 ${p} 进程，请手动确认: pgrep -a ${p}"
  done
  info "卸载完成（保留了 ${home}/dist 下你自己上传的回落页面）"
  rm -f /usr/local/bin/xh
}

cmd_menu() {
  while true; do
    echo ""
    echo -e "${CYAN}=== xray-xhttp 管理菜单 ===${NC}"
    echo "  1) 查看服务与流控状态"
    echo "  2) 查看节点参数与客户端配置"
    echo "  3) 查看订阅链接与二维码"
    echo "  4) 重启服务"
    echo "  5) 查看日志 (xray)"
    echo "  6) 更新 Xray-core"
    echo "  7) 系统层调优 show / on / off"
    echo "  8) 保活开关"
    echo "  9) 内核自动更新开关"
    echo " 10) UDP 节点自检 (diag)"
    echo " 11) sysctl 冲突检测 (conflict)"
    echo " 12) 卸载"
    echo "  0) 退出"
    read -rp "请选择: " choice
    case "$choice" in
      1) cmd_status ;;
      2) cmd_info ;;
      3) cmd_sub ;;
      4) cmd_restart ;;
      5) cmd_log xray ;;
      6) cmd_update ;;
      7) read -rp "  show / on / off: " a; cmd_tuning "${a:-show}" ;;
      8) read -rp "  on / off / show: " a; cmd_keepalive "${a:-show}" ;;
      9) read -rp "  on / off / show: " a; cmd_autoupdate "${a:-show}" ;;
      10) cmd_diag ;;
      11) cmd_conflict ;;
      12) cmd_uninstall; break ;;
      0) break ;;
      *) warn "无效选择" ;;
    esac
  done
}

usage() {
  cat <<'USAGEEOF'
xray-xhttp 管理命令

  xh                    进入交互菜单
  xh status             服务状态 / 监听端口 / 流控参数 / 版本
  xh info               节点参数与客户端节点链接
  xh sub                订阅链接与二维码
  xh resub              按当前 client-config.txt 重新生成订阅文件
  xh diag               UDP / HTTP3 节点连不上时的服务端侧自检
  xh log [xray|nginx] [行数]
  xh start | stop | restart
  xh update [--auto]    更新 Xray-core（自检失败自动回滚）
  xh tuning [show|on|off]  查看 / 开启 / 回滚系统层调优（安装时默认自动开启）
  xh keepalive [on|off|show]
  xh autoupdate [on|off|show]
  xh guard              健康检查并拉起异常服务（cron 调用）
  xh uninstall          卸载全部组件
  xh version
USAGEEOF
}

case "${1:-menu}" in
  menu)       cmd_menu ;;
  status)     cmd_status ;;
  info)       cmd_info ;;
  sub)        cmd_sub ;;
  resub)      cmd_resub ;;
  diag)       cmd_diag ;;
  conflict)   cmd_conflict ;;
  log)        shift; cmd_log "$@" ;;
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  update)     shift; cmd_update "$@" ;;
  tuning|tune) shift; cmd_tuning "$@" ;;   # tune 为常见误打，一并接受
  keepalive)  shift; cmd_keepalive "$@" ;;
  autoupdate) shift; cmd_autoupdate "$@" ;;
  guard)      cmd_guard ;;
  uninstall)  cmd_uninstall ;;
  version)    [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -1; echo "xray-xhttp ${PROJECT_VERSION:-unknown} (manage cli)" ;;
  -h|--help|help) usage ;;
  *)          usage; exit 1 ;;
esac
XHMANAGEEOF

chmod +x "$MANAGE_BIN"
info "管理命令已安装: ${MANAGE_BIN}"

# v4.2.0：内核层调优在安装时自动执行（best-effort，失败不阻断）。
# OpenVZ / LXC 只读 sysctl 会自动跳过并告警，不影响已跑通的节点。
# 回滚: xh tuning off  /  跳过: FEATURE_AUTO_TUNING=false
FEATURE_AUTO_TUNING=${FEATURE_AUTO_TUNING:-true}
if [[ "$FEATURE_AUTO_TUNING" == true ]]; then
  "$MANAGE_BIN" tuning on >/dev/null 2>&1 && info "系统层调优已自动应用（BBR / 缓冲区 / 句柄 / TFO）" || \
    warn "自动调优未生效（不影响节点功能），可稍后手动 ${MANAGE_CMD} tuning on"
fi

if [[ "$FEATURE_KEEPALIVE" == true ]]; then
  if command -v crontab >/dev/null 2>&1; then
    "$MANAGE_BIN" keepalive on >/dev/null 2>&1 && info "保活自愈已开启（每 5 分钟 + 开机自启）" || \
      warn "保活 cron 写入失败，可稍后手动执行 ${MANAGE_CMD} keepalive on"
  else
    warn "未找到 crontab，跳过保活配置"
  fi
fi

if [[ "$FEATURE_AUTOUPDATE" == true ]]; then
  if command -v crontab >/dev/null 2>&1; then
    "$MANAGE_BIN" autoupdate on >/dev/null 2>&1 && info "Xray 内核自动更新已开启（每周日 04:00）" || \
      warn "自动更新 cron 写入失败，可稍后手动执行 ${MANAGE_CMD} autoupdate on"
  fi
fi

echo ""

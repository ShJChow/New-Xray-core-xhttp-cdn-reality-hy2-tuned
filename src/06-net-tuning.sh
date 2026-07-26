# ==================================================
# 内核网络与句柄流控调优
#
# 设计原则：
#   1. 全部 best-effort。脚本头是 set -e，任何调优写操作失败只 warn，
#      绝不中断已经安装好 Xray 的部署流程（OpenVZ / LXC 常见只读 sysctl）。
#   2. 只写自己的文件（/etc/sysctl.d/99-xray-xhttp.conf、
#      /etc/security/limits.d/99-xray-xhttp.conf、systemd drop-in），
#      不修改用户既有的 /etc/sysctl.conf 与官方 unit 文件，随时可整体回滚。
#   3. 只把"试写成功"的项落盘，避免重启后 sysctl --system 报错刷屏。
# ==================================================

info "[2/8] 网络与流控调优"

SYSCTL_APPLIED=()
SYSCTL_SKIPPED=()
TUNING_BBR_OK=false

sysctl_get() { sysctl -n "$1" 2>/dev/null || true; }

# try_sysctl KEY VALUE —— 试写，成功则记录待落盘
try_sysctl() {
  local key="$1" value="$2"
  if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
    SYSCTL_APPLIED+=("${key} = ${value}")
  else
    SYSCTL_SKIPPED+=("$key")
  fi
}

# render_sockopt_kv INDENT —— 输出 `"sockopt": { ... }`，"sockopt" 行缩进 INDENT 空格
render_sockopt_kv() {
  local pad inner
  pad=$(printf '%*s' "$1" '')
  inner=$(printf '%*s' "$(( $1 + 4 ))" '')
  printf '%s"sockopt": {\n' "$pad"
  printf '%s"tcpFastOpen": true,\n' "$inner"
  if [[ "$TUNING_BBR_OK" == true ]]; then
    printf '%s"tcpcongestion": "bbr",\n' "$inner"
  fi
  printf '%s"tcpKeepAliveIdle": 100,\n' "$inner"
  printf '%s"tcpKeepAliveInterval": 30,\n' "$inner"
  printf '%s"tcpUserTimeout": 10000\n' "$inner"
  printf '%s}' "$pad"
}

if [[ "$FEATURE_TUNING" != true ]]; then
  warn "FEATURE_TUNING=false，跳过内核调优（Xray sockopt 也不会写入）"
  XRAY_SOCKOPT_JSON=""
  XRAY_SOCKOPT_OUT_JSON=""
else
  install -d -m 700 "$STATE_DIR"

  # ---------- 调优前快照 ----------
  BEFORE_QDISC=$(sysctl_get net.core.default_qdisc)
  BEFORE_CC=$(sysctl_get net.ipv4.tcp_congestion_control)
  BEFORE_RMEM=$(sysctl_get net.core.rmem_max)
  BEFORE_NOFILE=$(ulimit -n 2>/dev/null || echo "unknown")
  sysctl -a > "${STATE_DIR}/sysctl-before.txt" 2>/dev/null || \
    warn "无法导出调优前 sysctl 快照（不影响后续步骤）"

  # ---------- BBR 能力探测 ----------
  AVAILABLE_CC=$(sysctl_get net.ipv4.tcp_available_congestion_control)
  if [[ "$AVAILABLE_CC" != *bbr* ]]; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    AVAILABLE_CC=$(sysctl_get net.ipv4.tcp_available_congestion_control)
  fi
  if [[ "$AVAILABLE_CC" == *bbr* ]]; then
    TUNING_BBR_OK=true
  else
    warn "当前内核不提供 BBR（可用算法: ${AVAILABLE_CC:-未知}），将保持系统默认拥塞算法"
  fi

  # ---------- 拥塞控制与队列 ----------
  if [[ "$TUNING_BBR_OK" == true ]]; then
    try_sysctl net.core.default_qdisc fq
    try_sysctl net.ipv4.tcp_congestion_control bbr
  fi

  # ---------- 收发缓冲区（大带宽时延积链路 / 过 CDN 的关键项）----------
  try_sysctl net.core.rmem_max 16777216
  try_sysctl net.core.wmem_max 16777216
  try_sysctl net.core.rmem_default 1048576
  try_sysctl net.core.wmem_default 1048576
  try_sysctl net.ipv4.tcp_rmem "4096 87380 16777216"
  try_sysctl net.ipv4.tcp_wmem "4096 65536 16777216"
  try_sysctl net.ipv4.tcp_mem "786432 1048576 26777216"
  # QUIC / HTTP3（add-quic.sh 扩展与 Hysteria2 会用到）
  try_sysctl net.core.optmem_max 65536
  try_sysctl net.ipv4.udp_rmem_min 8192
  try_sysctl net.ipv4.udp_wmem_min 8192

  # ---------- 队列与并发 ----------
  try_sysctl net.core.netdev_max_backlog 32768
  try_sysctl net.core.somaxconn 65535
  try_sysctl net.ipv4.tcp_max_syn_backlog 32768
  try_sysctl net.ipv4.tcp_max_tw_buckets 65536
  try_sysctl net.ipv4.ip_local_port_range "1024 65535"

  # ---------- 连接建立与保持 ----------
  try_sysctl net.ipv4.tcp_fastopen 3
  try_sysctl net.ipv4.tcp_mtu_probing 1
  try_sysctl net.ipv4.tcp_slow_start_after_idle 0
  try_sysctl net.ipv4.tcp_notsent_lowat 131072
  try_sysctl net.ipv4.tcp_syncookies 1
  try_sysctl net.ipv4.tcp_tw_reuse 1
  try_sysctl net.ipv4.tcp_fin_timeout 15
  try_sysctl net.ipv4.tcp_keepalive_time 600
  try_sysctl net.ipv4.tcp_keepalive_intvl 30
  try_sysctl net.ipv4.tcp_keepalive_probes 5

  # ---------- 文件句柄 ----------
  try_sysctl fs.file-max 1048576
  try_sysctl fs.nr_open 1048576

  # ---------- 落盘 ----------
  if [[ ${#SYSCTL_APPLIED[@]} -gt 0 ]]; then
    {
      echo "# ${PROJECT_NAME} 流控调优，由安装脚本生成"
      echo "# 回滚: ${MANAGE_CMD} tuning off"
      printf '%s\n' "${SYSCTL_APPLIED[@]}"
    } > "$SYSCTL_CONF" 2>/dev/null || warn "写入 ${SYSCTL_CONF} 失败，本次调优仅在重启前有效"
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || \
      warn "sysctl 重载失败，参数已在运行时生效但可能无法持久化"
    info "已应用 ${#SYSCTL_APPLIED[@]} 项内核参数 → ${SYSCTL_CONF}"
  else
    warn "当前环境不允许修改任何 sysctl 参数（常见于 OpenVZ / 受限容器），已跳过内核调优"
  fi
  if [[ ${#SYSCTL_SKIPPED[@]} -gt 0 ]]; then
    warn "以下参数当前内核不支持或只读，已跳过: ${SYSCTL_SKIPPED[*]}"
  fi

  # ---------- 进程句柄上限 ----------
  if [[ "$OS_ID" != "alpine" ]]; then
    if [[ -d /etc/security/limits.d ]]; then
      cat > "$LIMITS_CONF" <<'LIMITSEOF' || warn "写入 limits.d 失败"
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITSEOF
      info "已写入句柄上限 → ${LIMITS_CONF}"
    else
      warn "未找到 /etc/security/limits.d，跳过 nofile 配置"
    fi
  fi

  # systemd 用 drop-in，不改官方 Xray-install 维护的 unit，避免内核更新后被覆盖
  if [[ "$SERVICE_TYPE" == "systemd" ]]; then
    for unit in xray nginx; do
      install -d -m 755 "/etc/systemd/system/${unit}.service.d" 2>/dev/null || continue
      cat > "/etc/systemd/system/${unit}.service.d/override.conf" <<'DROPINEOF' || warn "写入 ${unit} drop-in 失败"
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
DROPINEOF
    done
    systemctl daemon-reload >/dev/null 2>&1 || warn "systemctl daemon-reload 失败"
    info "已为 xray / nginx 写入 systemd drop-in（LimitNOFILE=1048576）"
  else
    if [[ -d /etc/conf.d ]]; then
      grep -q '^rc_ulimit=' /etc/conf.d/xray 2>/dev/null || \
        echo 'rc_ulimit="-n 1048576"' >> /etc/conf.d/xray 2>/dev/null || \
        warn "写入 /etc/conf.d/xray 失败"
      grep -q '^rc_ulimit=' /etc/conf.d/nginx 2>/dev/null || \
        echo 'rc_ulimit="-n 1048576"' >> /etc/conf.d/nginx 2>/dev/null || \
        warn "写入 /etc/conf.d/nginx 失败"
      info "已为 OpenRC 服务写入 rc_ulimit"
    fi
  fi

  # ---------- Before / After ----------
  echo ""
  echo -e "${YELLOW}[+] 流控调优 Before / After${NC}"
  printf '  %-28s %-18s -> %s\n' "net.core.default_qdisc"          "${BEFORE_QDISC:-n/a}"  "$(sysctl_get net.core.default_qdisc)"
  printf '  %-28s %-18s -> %s\n' "net.ipv4.tcp_congestion_control" "${BEFORE_CC:-n/a}"     "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf '  %-28s %-18s -> %s\n' "net.core.rmem_max"               "${BEFORE_RMEM:-n/a}"   "$(sysctl_get net.core.rmem_max)"
  printf '  %-28s %-18s -> %s\n' "net.ipv4.tcp_fastopen"           "-"                     "$(sysctl_get net.ipv4.tcp_fastopen)"
  printf '  %-28s %-18s -> %s\n' "ulimit -n (当前 shell)"          "${BEFORE_NOFILE}"      "重新登录后生效: 1048576"
  echo ""

  # ---------- 供 Xray 模板注入的 sockopt ----------
  # tcpNoDelay 已在新版 Xray 中废弃移除；tcpMptcp 需两端同时支持、过 CDN 无意义，默认不开。
  # tcpcongestion 仅在探测到 BBR 时写入，否则 Xray 会因未知拥塞算法启动失败。
  # 入站：拼在 streamSettings 内部（"sockopt" 缩进 16）
  XRAY_SOCKOPT_JSON=$(printf ',\n%s' "$(render_sockopt_kv 16)")
  # 出站 freedom：需要额外包一层 streamSettings（"streamSettings" 缩进 12）
  XRAY_SOCKOPT_OUT_JSON=$(printf ',\n            "streamSettings": {\n%s\n            }' "$(render_sockopt_kv 16)")
fi

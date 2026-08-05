# ==================================================
# 内核网络与句柄流控调优（函数库）
#
# v4.2.0：本模块由安装流程自动调用一次（安装完成时执行 `xh tuning on`），
# 也可随时手动执行 `xh tuning on`，`xh tuning off` 可整体回滚。
# 本文件被内联进管理命令 xh（src/13-manage-cli.sh 的 heredoc），
# 全部 best-effort——OpenVZ / LXC 只读 sysctl 逐项跳过并告警，绝不阻断安装（L1）。
#
# 设计原则：
#   1. 全部 best-effort。任何调优写操作失败只 warn，绝不中断（L1）。
#      OpenVZ / LXC 上 sysctl 常为只读。
#   2. 只写自己的文件（/etc/sysctl.d/99-xray-xhttp.conf、
#      /etc/security/limits.d/99-xray-xhttp.conf、systemd drop-in），
#      不修改用户既有的 /etc/sysctl.conf 与官方 unit 文件。
#   3. 只把"试写成功"的项落盘，避免重启后 sysctl --system 报错刷屏。
# ==================================================

sysctl_get() { sysctl -n "$1" 2>/dev/null || true; }

apply_system_tuning() {
  local SYSCTL_APPLIED=() SYSCTL_SKIPPED=() TUNING_BBR_OK=false
  local MEM_MB CPU_CORES ARCH PAGE_SIZE MEM_PAGES
  local TUNE_TIER SOCK_MEM_MAX TCP_MEM_MAX NETDEV_BACKLOG CONNTRACK_MAX
  local BEFORE_QDISC BEFORE_CC BEFORE_RMEM BEFORE_NOFILE AVAILABLE_CC unit

  # try_sysctl KEY VALUE —— 试写，成功则记录待落盘
  try_sysctl() {
    if sysctl -w "${1}=${2}" >/dev/null 2>&1; then
      SYSCTL_APPLIED+=("${1} = ${2}")
    else
      SYSCTL_SKIPPED+=("$1")
    fi
  }

  install -d -m 700 "$STATE_DIR"

  # ---------- 机型探测：按内存分档，参数随机器规格伸缩 ----------
  MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  CPU_CORES=$(nproc 2>/dev/null || echo 1)
  ARCH=$(uname -m 2>/dev/null || echo unknown)
  # tcp_mem 的单位是"页"，页大小不一定是 4K：RHEL 系的 aarch64 内核
  # （Oracle Linux / UEK）常用 64K 页，写死 /4 会让页数偏大 16 倍（L4）。
  PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null || echo 4096)
  MEM_PAGES=$(awk -v ps="$PAGE_SIZE" '/^MemTotal:/{printf "%d", $2*1024/ps}' /proc/meminfo 2>/dev/null || echo 262144)

  if [[ "$MEM_MB" -ge 16384 ]]; then
    TUNE_TIER="large";  SOCK_MEM_MAX=67108864; TCP_MEM_MAX=33554432; NETDEV_BACKLOG=65536; CONNTRACK_MAX=1048576; NETDEV_BUDGET=6000
  elif [[ "$MEM_MB" -ge 4096 ]]; then
    TUNE_TIER="medium"; SOCK_MEM_MAX=33554432; TCP_MEM_MAX=16777216; NETDEV_BACKLOG=32768; CONNTRACK_MAX=262144; NETDEV_BUDGET=6000
  else
    TUNE_TIER="small";  SOCK_MEM_MAX=16777216; TCP_MEM_MAX=8388608;  NETDEV_BACKLOG=16384; CONNTRACK_MAX=0; NETDEV_BUDGET=""
  fi

  info "机型: ${CPU_CORES} 核 / ${MEM_MB} MB / ${ARCH} → 调优档位 ${TUNE_TIER}"

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
    try_sysctl net.core.default_qdisc fq
    try_sysctl net.ipv4.tcp_congestion_control bbr
  else
    warn "当前内核不提供 BBR（可用算法: ${AVAILABLE_CC:-未知}），将保持系统默认拥塞算法"
  fi

  # ---------- 收发缓冲区（大带宽时延积链路 / 过 CDN 的关键项）----------
  try_sysctl net.core.rmem_max "$SOCK_MEM_MAX"
  try_sysctl net.core.wmem_max "$SOCK_MEM_MAX"
  try_sysctl net.core.rmem_default 1048576
  try_sysctl net.core.wmem_default 1048576
  # 中间值是**初始**默认值，autotuning 会在 min~max 之间增长；调大它影响的是
  # 连接建立初期与短流，对过 CDN 的高 RTT（100~300ms）链路少几个 RTT 的爬升。
  try_sysctl net.ipv4.tcp_rmem "4096 262144 ${TCP_MEM_MAX}"
  try_sysctl net.ipv4.tcp_wmem "4096 262144 ${TCP_MEM_MAX}"
  # 接收缓冲中留给协议开销的比例。负值表示按 1/2^|n| 计，-2 会让通告窗口更接近
  # rmem 实际大小。新内核语义几经调整且 tcp_moderate_rcvbuf 已覆盖多数场景，
  # 这里不断言收益；try_sysctl 在不支持的内核上只会记进 SKIPPED。
  try_sysctl net.ipv4.tcp_adv_win_scale -2
  # 按物理内存的 6% / 8% / 12% 推算（单位是页，已按 PAGESIZE 换算）
  try_sysctl net.ipv4.tcp_mem "$(( MEM_PAGES * 6 / 100 )) $(( MEM_PAGES * 8 / 100 )) $(( MEM_PAGES * 12 / 100 ))"
  # QUIC / HTTP3：本项目保留的 UDP+XHTTP+CDN 节点与 Hysteria2 扩展都会用到
  try_sysctl net.core.optmem_max 65536
  try_sysctl net.ipv4.udp_rmem_min 8192
  try_sysctl net.ipv4.udp_wmem_min 8192

  # ---------- 队列与并发 ----------
  try_sysctl net.core.netdev_max_backlog "$NETDEV_BACKLOG"
  # NAPI 每轮 poll 可处理的包数上限。默认 300 在高并发（CDN 回源 + XHTTP 长连接，
  # 大量小包）下 softirq 来不及收完，/proc/net/softnet_stat 的 time_squeeze 非零即此
  # 信号。放大到 6000 是"在 2000μs 窗口内多收包"，不延长窗口、不增加软中断时长，
  # 因而不引入 CPU 占用。小内存档（<4G）不写，保持默认（netdev_budget_usecs 已限时）。
  if [[ -n "$NETDEV_BUDGET" ]]; then
    try_sysctl net.core.netdev_budget "$NETDEV_BUDGET"
  fi
  try_sysctl net.core.somaxconn 65535
  try_sysctl net.ipv4.tcp_max_syn_backlog "$NETDEV_BACKLOG"
  try_sysctl net.ipv4.tcp_max_tw_buckets 65536
  try_sysctl net.ipv4.ip_local_port_range "1024 65535"

  # conntrack 仅在模块已加载时调整；未加载时写入会失败并留下无用告警
  if [[ "$CONNTRACK_MAX" -gt 0 ]] && [[ -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    try_sysctl net.netfilter.nf_conntrack_max "$CONNTRACK_MAX"
    try_sysctl net.netfilter.nf_conntrack_tcp_timeout_established 3600
  fi

  # ---------- 连接建立与保持 ----------
  try_sysctl net.ipv4.tcp_fastopen 3
  try_sysctl net.ipv4.tcp_mtu_probing 1
  try_sysctl net.ipv4.tcp_slow_start_after_idle 0
  # 套接字里允许积压的未发送字节数。调小 = Xray 更早被唤醒补数据，本地排队更少，
  # 降低队头阻塞与写入延迟（16KB 是通行取值）。这是**延迟**收益，不是吞吐收益：
  # 拥塞窗口由 BBR 与 rmem/wmem 决定，与本项无关。
  try_sysctl net.ipv4.tcp_notsent_lowat 16384
  try_sysctl net.ipv4.tcp_syncookies 1
  try_sysctl net.ipv4.tcp_tw_reuse 1
  # tcp_retries2 = 8：死连接在内核层约 1 分钟内被关闭（默认 15 约 15 分钟）。
  # 代理机器上对端死亡（掉线/关机/被墙）后，连接表槽位与 fd 被僵尸连接占住，
  # 收得越快、给正常连接腾的资源越多。代价是瞬时网络抖动可能更早报错——
  # 对代理是收益：应用层（Xray 自动重连）能更快接管。
  try_sysctl net.ipv4.tcp_retries2 8
  # 出站 SYN 最多重试 4 次（约 30s），默认 6 次（约 3 分钟）。连接发给回落站/上游
  # 时对端若不可达，不必为已死的对端浪费 3 分钟。
  try_sysctl net.ipv4.tcp_syn_retries 4
  # TIME_WAIT 暗杀保护（RFC 1337）：默认 0 时，对端在连接 TIME_WAIT 期发来的 RST
  # 会提前终结连接，破坏 TIME_WAIT 的 2MSL 语义，低概率但会诱发资源错乱；1 为忽略
  # 该 RST。零成本，语义上是防御性的。
  try_sysctl net.ipv4.tcp_rfc1337 1
  try_sysctl net.ipv4.tcp_fin_timeout 15
  try_sysctl net.ipv4.tcp_keepalive_time 600
  try_sysctl net.ipv4.tcp_keepalive_intvl 30
  try_sysctl net.ipv4.tcp_keepalive_probes 5

  # ---------- 内存行为（v3.0.2 从 ubuntu_vps_optimize.sh 同步）----------
  # 转发型服务器没有写负载，降低 swap 倾向但不关——OOM 时 swap 比杀进程安全。
  # dirty_ratio / dirty_background_ratio 作用在脏页回写，转发机器不落盘，故意不调。
  if [[ "$MEM_MB" -ge 4096 ]]; then try_sysctl vm.swappiness 10; else try_sysctl vm.swappiness 30; fi
  try_sysctl vm.vfs_cache_pressure 50

  # ---------- 文件句柄 ----------
  try_sysctl fs.file-max 1048576
  try_sysctl fs.nr_open 1048576

  # ---------- 落盘 ----------
  if [[ ${#SYSCTL_APPLIED[@]} -gt 0 ]]; then
    {
      echo "# ${PROJECT_NAME} 流控调优，由 ${MANAGE_CMD} tuning on 生成"
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

  # systemd 用 drop-in，不改官方 Xray-install 维护的 unit，避免更新后被覆盖
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
  printf '  %-28s %-18s -> %s\n' "net.core.default_qdisc"          "${BEFORE_QDISC:-n/a}" "$(sysctl_get net.core.default_qdisc)"
  printf '  %-28s %-18s -> %s\n' "net.ipv4.tcp_congestion_control" "${BEFORE_CC:-n/a}"    "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf '  %-28s %-18s -> %s\n' "net.core.rmem_max"               "${BEFORE_RMEM:-n/a}"  "$(sysctl_get net.core.rmem_max)"
  printf '  %-28s %-18s -> %s\n' "net.ipv4.tcp_fastopen"           "-"                    "$(sysctl_get net.ipv4.tcp_fastopen)"
  printf '  %-28s %-18s -> %s\n' "ulimit -n (当前 shell)"          "${BEFORE_NOFILE}"     "重新登录后生效: 1048576"
  echo ""
  info "BBR: ${TUNING_BBR_OK}；回滚请执行 ${MANAGE_CMD} tuning off"
}

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
    TUNE_TIER="large";  SOCK_MEM_MAX=67108864; TCP_MEM_MAX=67108864; NETDEV_BACKLOG=65536; CONNTRACK_MAX=1048576; NETDEV_BUDGET=6000; OPTMEM_MAX=262144
  elif [[ "$MEM_MB" -ge 4096 ]]; then
    TUNE_TIER="medium"; SOCK_MEM_MAX=33554432; TCP_MEM_MAX=33554432; NETDEV_BACKLOG=32768; CONNTRACK_MAX=262144; NETDEV_BUDGET=6000; OPTMEM_MAX=131072
  else
    TUNE_TIER="small";  SOCK_MEM_MAX=16777216; TCP_MEM_MAX=16777216; NETDEV_BACKLOG=16384; CONNTRACK_MAX=0; NETDEV_BUDGET=""; OPTMEM_MAX=65536
  fi

  info "机型: ${CPU_CORES} 核 / ${MEM_MB} MB / ${ARCH} → 调优档位 ${TUNE_TIER}"

  # ---------- 调优前快照 ----------
  BEFORE_QDISC=$(sysctl_get net.core.default_qdisc)
  BEFORE_CC=$(sysctl_get net.ipv4.tcp_congestion_control)
  BEFORE_RMEM=$(sysctl_get net.core.rmem_max)
  BEFORE_NOFILE=$(ulimit -n 2>/dev/null || echo "unknown")
  sysctl -a > "${STATE_DIR}/sysctl-before.txt" 2>/dev/null || \
    warn "无法导出调优前 sysctl 快照（不影响后续步骤）"

  # ---------- BBR 能力探测与队列调度 ----------
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
  if [[ "$MEM_MB" -ge 4096 ]]; then
    try_sysctl net.core.rmem_default 4194304
    try_sysctl net.core.wmem_default 4194304
    try_sysctl net.ipv4.udp_rmem_min 131072
    try_sysctl net.ipv4.udp_wmem_min 131072
  else
    try_sysctl net.core.rmem_default 1048576
    try_sysctl net.core.wmem_default 1048576
    try_sysctl net.ipv4.udp_rmem_min 16384
    try_sysctl net.ipv4.udp_wmem_min 16384
  fi
  # 中间值是**初始**默认值，autotuning 会在 min~max 之间增长；调大它影响的是
  # 连接建立初期与短流，对过 CDN 的高 RTT（100~300ms）链路少几个 RTT 的爬升。
  try_sysctl net.ipv4.tcp_rmem "4096 262144 ${TCP_MEM_MAX}"
  try_sysctl net.ipv4.tcp_wmem "4096 262144 ${TCP_MEM_MAX}"
  # 接收缓冲中留给协议开销的比例。设为 1（保留 50% 内存作为通告窗口），让 64MB/32MB
  # 缓冲能通告出 32MB/16MB 的接收窗口，突破跨境高延迟（200ms+）下的单流千兆吞吐瓶颈。
  try_sysctl net.ipv4.tcp_adv_win_scale 1
  # 自动合并小包发送，降低 PPS 与软中断 CPU 开销
  try_sysctl net.ipv4.tcp_autocorking 1
  # 内核 6.x/7.x SACK 压缩，在跨境丢包路径上聚合压缩 SACK ACK，抑制 ACK 风暴
  try_sysctl net.ipv4.tcp_comp_sack_nr 44
  try_sysctl net.ipv4.tcp_comp_sack_delay_ns 1000000
  # 按物理内存的 6% / 8% / 12% 推算（单位是页，已按 PAGESIZE 换算）
  try_sysctl net.ipv4.tcp_mem "$(( MEM_PAGES * 6 / 100 )) $(( MEM_PAGES * 8 / 100 )) $(( MEM_PAGES * 12 / 100 ))"
  # QUIC / HTTP3 / TLS 辅助缓冲扩容
  try_sysctl net.core.optmem_max "${OPTMEM_MAX:-65536}"
  # udp_mem（v4.7.2）：全系统 UDP 内存池上限，单位是页。上面两项是**单个套接字**的
  # 保底值，管不到这个总量；触顶后内核直接丢包且不回任何错误，表现为 h3-direct 与
  # Hysteria2 在高并发下莫名丢包，而 TCP 节点一切正常——极难定位，因此显式设置。
  # 针对 16GB+ 大内存机型提供 4%~16% 弹性缓冲池，避免高突发 UDP 丢包。
  if [[ "$MEM_MB" -ge 16384 ]]; then
    try_sysctl net.ipv4.udp_mem "$(( MEM_PAGES * 4 / 100 )) $(( MEM_PAGES * 8 / 100 )) $(( MEM_PAGES * 16 / 100 ))"
  elif [[ "$MEM_MB" -ge 1024 ]]; then
    try_sysctl net.ipv4.udp_mem "$(( MEM_PAGES * 2 / 100 )) $(( MEM_PAGES * 4 / 100 )) $(( MEM_PAGES * 8 / 100 ))"
  fi

  # ---------- 队列与并发 ----------
  try_sysctl net.core.netdev_max_backlog "$NETDEV_BACKLOG"
  # NAPI 每轮 poll 可处理的包数上限。默认 300 在高并发（CDN 回源 + XHTTP 长连接，
  # 大量小包）下 softirq 来不及收完，/proc/net/softnet_stat 的 time_squeeze 非零即此
  # 信号。放大到 6000 是"在 2000μs 窗口内多收包"，不延长窗口、不增加软中断时长，
  # 因而不引入 CPU 占用。小内存档（<4G）不写，保持默认（netdev_budget_usecs 已限时）。
  if [[ -n "$NETDEV_BUDGET" ]]; then
    try_sysctl net.core.netdev_budget "$NETDEV_BUDGET"
    try_sysctl net.core.netdev_budget_usecs 8000
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
  # 套接字里允许积压的未发送字节数。针对 150~200ms RTT 跨境链路，放宽到 256KB
  # 既能防止本地 bufferbloat，又不会锁死跨境单流高速下载吞吐。
  try_sysctl net.ipv4.tcp_notsent_lowat 262144
  try_sysctl net.ipv4.tcp_syncookies 1
  try_sysctl net.ipv4.tcp_tw_reuse 1
  try_sysctl net.ipv4.tcp_ecn 2
  try_sysctl net.ipv4.tcp_ecn_fallback 1
  # tcp_no_metrics_save = 1（v4.7.2）：不把连接结束时的 cwnd / ssthresh 缓存进路由表。
  # 默认行为（0）在同质网络里是优化，在代理机上是负担：对端遍布全球，线路质量差异
  # 极大，一条丢包严重的连接会把偏低的 ssthresh 写进缓存，之后**同网段**的新连接
  # 全部继承这个坏起点，慢启动被人为压制。关掉后每条连接独立探测。
  try_sysctl net.ipv4.tcp_no_metrics_save 1
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

  # ---------- 路由与网络硬件队列增强（best-effort）----------
  # 1. 优化默认路由初始拥塞窗口（initcwnd/initrwnd 32），加速 TLS 握手
  local def_route clean_route
  def_route=$(ip route show default 2>/dev/null | head -1)
  if [[ -n "$def_route" ]]; then
    clean_route=$(echo "$def_route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')
    ip route change $clean_route initcwnd 32 initrwnd 32 2>/dev/null || true
  fi

  # 2. RPS/RFS 多核软中断调优与网卡流控
  if [[ "$CPU_CORES" -gt 1 ]]; then
    local rps_mask flow_entries num_rx
    rps_mask=$(printf '%x' $((2**CPU_CORES - 1)))
    flow_entries=$((8192 * CPU_CORES))
    try_sysctl net.core.rps_sock_flow_entries "$flow_entries"
    for d in /sys/class/net/*; do
      [[ -e "$d" ]] || continue
      local dev
      dev=$(basename "$d")
      case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*) continue;;
      esac
      [[ -d "/sys/class/net/$dev/queues" ]] || continue
      num_rx=$(find "/sys/class/net/$dev/queues/" -maxdepth 1 -name 'rx-*' | wc -l)
      [[ "$num_rx" -le 0 ]] && num_rx=1
      for rxq in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        [[ -f "$rxq" ]] && echo "$rps_mask" > "$rxq" 2>/dev/null || true
      done
      for rxq_dir in /sys/class/net/$dev/queues/rx-*/; do
        [[ -f "${rxq_dir}rps_flow_cnt" ]] && echo "$((flow_entries / num_rx))" > "${rxq_dir}rps_flow_cnt" 2>/dev/null || true
      done

      # 多队列网卡 / 单队列网卡 fq 流控优化
      if command -v tc >/dev/null 2>&1 && [[ "$TUNING_BBR_OK" == "true" ]]; then
        local num_tx
        num_tx=$(find "/sys/class/net/$dev/queues/" -maxdepth 1 -name 'tx-*' | wc -l)
        if [[ "$num_tx" -gt 1 ]]; then
          tc qdisc replace dev "$dev" root handle 1: mq 2>/dev/null || true
          for i in $(seq 1 "$num_tx"); do
            tc qdisc replace dev "$dev" parent 1:$i fq limit 20480 flow_limit 4096 quantum 18028 initial_quantum 90140 2>/dev/null || true
          done
        else
          tc qdisc replace dev "$dev" root fq limit 20480 flow_limit 4096 quantum 18028 initial_quantum 90140 2>/dev/null || true
        fi
      fi
    done
  fi

  # 3. TCP MSS Clamp 防护（避免 Jumbo Frame 与公网 MTU 冲突导致的黑洞丢包）
  if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 \
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  fi

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

  # systemd 用 drop-in，不改官方 Xray-install 维护的 unit，避免更新后被覆盖。
  #
  # v4.7.3：文件名从 override.conf 改为 10-xray-xhttp.conf。
  # 起因：override.conf 是**用户手工加固的约定俗成文件名**（Restart=always、
  # OOMScoreAdjust、After=network-online.target 之类都习惯写在这里），而本函数是
  # `cat >` 整体覆写。用户加过料之后再跑一次 `xh tuning off && xh tuning on`，
  # 那些设置会被静默吃掉——没有报错、没有提示，只有下次机器没自动拉起时才发现。
  #
  # systemd 会把 <unit>.service.d/ 下所有 *.conf 按文件名序合并，所以换个专属文件名
  # 就从根本上解决了：我们只管自己的文件，用户的 override.conf 原样保留；
  # 数字前缀 10- 保证排在 override.conf 之前，用户想覆盖我们的值也依然有效。
  if [[ "$SERVICE_TYPE" == "systemd" ]]; then
    local dropin="10-xray-xhttp.conf" migrated=0 kept=0
    for unit in xray nginx hysteria-server sing-box; do
      local dir="/etc/systemd/system/${unit}.service.d"
      # 若服务未安装或目录不存在，仅在存在/可创建时操作
      if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 || [[ -d "$dir" ]]; then
        install -d -m 755 "$dir" 2>/dev/null || continue
        cat > "${dir}/${dropin}" <<'DROPINEOF' || warn "写入 ${unit} drop-in 失败"
# xray-xhttp 句柄上限，由 xh tuning on 生成 / xh tuning off 移除。
# 本项目只写这一个文件，同目录下你自己的 override.conf 不会被改动。
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
Environment="GOGC=200"
DROPINEOF
        # 旧版留下的 override.conf：内容与历史生成物逐字一致才删（说明用户没动过），
        # 否则一律保留——那是用户的加固，宁可留下一份内容重复的文件，也不能删掉它。
        local legacy="${dir}/override.conf"
        if [[ -f "$legacy" ]]; then
          if [[ "$(grep -vE '^\s*(#|$)' "$legacy" | tr -d '[:space:]')" \
                == "[Service]LimitNOFILE=1048576LimitNPROC=infinity" ]]; then
            rm -f "$legacy" && migrated=1
          else
            kept=1
          fi
        fi
      fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || warn "systemctl daemon-reload 失败"
    info "已为代理与网关服务 (xray/nginx/sing-box/hysteria) 写入 systemd drop-in（LimitNOFILE=1048576 → ${dropin}）"
    [[ "$migrated" -eq 1 ]] && info "已清理旧版留下的 override.conf（内容与本项目生成物一致）"
    [[ "$kept" -eq 1 ]] && \
      warn "检测到你自己修改过的 override.conf，已原样保留；它排在本项目文件之后，同名字段以你的为准"
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

show_win_tuning() {
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}   Windows 10 / 11 客户端千兆 TCP 栈与网络解限指南     ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo ""
  echo -e "${YELLOW}[+] 请以管理员身份打开 PowerShell 执行以下命令:${NC}"
  cat <<'EOF'
# 1. 开启 TCP 窗口自动调优（释放 16MB~64MB 接收窗口，跑满千兆 BDP）
netsh int tcp set global autotuninglevel=normal

# 2. 启用网卡多核接收侧缩放（RSS：防止千兆速率下单 CPU 核心被软中断占满）
netsh int tcp set global rss=enabled

# 3. 启用硬件接收分段合并（RSC：大幅降低 CPU 占用）
netsh int tcp set global rsc=enabled

# 4. 启用显式拥塞通知（ECN）与 TCP 快速打开（Fast Open 节省 1 次握手 RTT）
netsh int tcp set global ecncapability=enabled
netsh int tcp set global fastopen=enabled
netsh int tcp set global fastopenfallback=enabled

# 5. 允许 TCP 时间戳（防回绕序号 PAWS 与准确 RTT 采样）
netsh int tcp set global timestamps=allowed

# 6. 设置拥塞控制算法为 BBR2 / CUBIC
try {
    netsh int tcp set supplemental template=internet congestionprovider=bbr2
} catch {
    netsh int tcp set supplemental template=internet congestionprovider=cubic
}

# 7. 解除 Windows 系统级多媒体网络节流限制（NetworkThrottlingIndex = 0xffffffff）
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Type DWord -Value 0xffffffff
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Type DWord -Value 0

# 8. 禁用 Nagle 算法（降低小包延迟，提升游戏与交互响应）
Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" | ForEach-Object {
    Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Type DWord -Value 1 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Type DWord -Value 1 -ErrorAction SilentlyContinue
}
EOF
  echo ""
  echo -e "${GREEN}[+] 客户端软件建议:${NC}"
  echo "  - 优先选择支持 Wintun 驱动的客户端（如 Clash Verge Rev / Sing-box / Mihomo Party / v2rayN）"
  echo "  - TUN 协议栈建议选 Mixed 或 System（避开 gVisor 用户态单核瓶颈）"
  echo ""
}

show_mac_tuning() {
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}   macOS 客户端千兆 TCP 缓冲区与 TFO 调优指南         ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo ""
  echo -e "${GREEN}[1] 终端即时生效命令:${NC}"
  cat <<'EOF'
sudo sysctl -w kern.ipc.maxsockbuf=33554432
sudo sysctl -w net.inet.tcp.recvspace=4194304
sudo sysctl -w net.inet.tcp.sendspace=4194304
sudo sysctl -w net.inet.tcp.autorcvbuf=1
sudo sysctl -w net.inet.tcp.autorcvbufmax=33554432
sudo sysctl -w net.inet.tcp.autosndbuf=1
sudo sysctl -w net.inet.tcp.autosndbufmax=33554432
sudo sysctl -w net.inet.tcp.fastopen=3
sudo sysctl -w net.inet.tcp.rfc1323=1
sudo sysctl -w net.inet.tcp.win_scale_factor=8
sudo sysctl -w net.inet.tcp.mptcp.enable=1
EOF
  echo ""
  echo -e "${GREEN}[2] 开机自动守护 (LaunchDaemon):${NC}"
  cat <<'EOF'
sudo tee /Library/LaunchDaemons/com.user.sysctl.plist << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.sysctl</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/sbin/sysctl</string>
        <string>-w</string>
        <string>kern.ipc.maxsockbuf=33554432</string>
        <string>net.inet.tcp.recvspace=4194304</string>
        <string>net.inet.tcp.sendspace=4194304</string>
        <string>net.inet.tcp.autorcvbuf=1</string>
        <string>net.inet.tcp.autorcvbufmax=33554432</string>
        <string>net.inet.tcp.autosndbuf=1</string>
        <string>net.inet.tcp.autosndbufmax=33554432</string>
        <string>net.inet.tcp.fastopen=3</string>
        <string>net.inet.tcp.rfc1323=1</string>
        <string>net.inet.tcp.win_scale_factor=8</string>
        <string>net.inet.tcp.mptcp.enable=1</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF
sudo chown root:wheel /Library/LaunchDaemons/com.user.sysctl.plist
sudo chmod 644 /Library/LaunchDaemons/com.user.sysctl.plist
sudo launchctl load -w /Library/LaunchDaemons/com.user.sysctl.plist 2>/dev/null || true
EOF
  echo ""
}

show_linux_tuning() {
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}   Linux 客户端千兆 TCP 缓冲区与 BDP 调优指南         ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  cat <<'EOF'
sudo sysctl -w net.core.rmem_max=67108864
sudo sysctl -w net.core.wmem_max=67108864
sudo sysctl -w net.ipv4.tcp_rmem="4096 262144 67108864"
sudo sysctl -w net.ipv4.tcp_wmem="4096 262144 67108864"
sudo sysctl -w net.ipv4.tcp_adv_win_scale=1
sudo sysctl -w net.ipv4.tcp_fastopen=3
sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
EOF
  echo ""
}

show_sb_tuning() {
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}   sing-box 客户端 5 节点核心加速关键配置 (1000M 版)    ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo "  - FakeIP 零延迟解析:   fakeip.enabled: true, independent_cache: true"
  echo "  - Hysteria2 带宽校准:  up_mbps: 100, down_mbps: 1000"
  echo "  - TCP 快速握手 (TFO):  tcp_fast_open: true (VLESS / Naive / SS)"
  echo "  - Vision 零拷贝流控:   flow: xtls-rprx-vision, packet_encoding: xudp"
  echo "  - TUN 网卡巨帧加速:    mtu: 9000, stack: mixed, endpoint_independent_nat: true"
  echo "  - 智能秒级故障转移:    urltest 测速周期 3m, connect_timeout: 3s"
  echo ""
  echo -e "${YELLOW}[+] 完整配置已保存在: /root/sbbox/sbox_client.json${NC}"
  echo ""
}

show_client_tuning() {
  local target="${1:-all}"
  case "$target" in
    win|windows)
      show_win_tuning
      ;;
    mac|macos)
      show_mac_tuning
      ;;
    linux)
      show_linux_tuning
      ;;
    sb|singbox)
      show_sb_tuning
      ;;
    *)
      show_win_tuning
      show_mac_tuning
      show_linux_tuning
      show_sb_tuning
      ;;
  esac
}

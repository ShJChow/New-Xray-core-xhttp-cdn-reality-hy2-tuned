#!/bin/bash
# ==================================================
# xray-xhttp 运行时性能审计（只读，不修改任何配置）
#
# 用途：采集第一~五阶段的全部检测项，输出结构化报告。
# 安全性：全程只读。没有任何 sysctl -w / 文件写入 / 服务重启 / 包安装。
#         每一项都是 best-effort，命令缺失只打印 n/a，绝不中断（见 tasks/lessons.md L1）。
#
# ---- v2.0.0 起如何读这份报告 ----
# 安装脚本**不再做任何参数优化**：装完之后本机的内核参数就是发行版默认值，
# xray-config.json 与上游 Yulinanami/my-xhttp-cdn-config 逐字节一致（不含
# policy.bufferSize / sockopt），nginx 也没有吞吐旋钮。
# 因此在**未执行 `xh tuning on`** 的机器上，第 1 节读到的全是系统默认值，
# 第 5 节读不到 policy / sockopt —— 这是**预期状态，不是缺陷**。
# 报告开头的「调优状态」一行会明确告诉你当前处于哪一侧。
#
# 最有价值的用法是跑两次做对照：
#   sudo bash perf-audit.sh > before.txt 2>&1
#   xh tuning on
#   sudo bash perf-audit.sh > after.txt 2>&1
#   diff before.txt after.txt
#
# 用法：
#   curl -fsSL <raw-url>/tools/perf-audit.sh -o perf-audit.sh
#   sudo bash perf-audit.sh > perf-report.txt 2>&1
#   然后把 perf-report.txt 完整贴回对话
# ==================================================

# 故意不使用 set -e：审计脚本任何一项失败都不该中断整体采集
export LC_ALL=C

sec()  { printf '\n\n========== %s ==========\n' "$*"; }
sub()  { printf '\n--- %s ---\n' "$*"; }
kv()   { printf '%-40s %s\n' "$1" "${2:-n/a}"; }
have() { command -v "$1" >/dev/null 2>&1; }
sy()   { local v; v=$(sysctl -n "$1" 2>/dev/null); kv "$1" "${v:-<内核不支持>}"; }

echo "xray-xhttp perf-audit  $(date -Is 2>/dev/null)"

# ==================================================
sec "0. 基本环境"
kv "kernel"   "$(uname -r 2>/dev/null)"
kv "arch"     "$(uname -m 2>/dev/null)"
kv "PAGESIZE" "$(getconf PAGESIZE 2>/dev/null)"
[[ -f /etc/os-release ]] && grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' /etc/os-release
kv "uptime"   "$(uptime -p 2>/dev/null)"
kv "MemTotal" "$(awk '/^MemTotal:/{printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null)"
have systemd-detect-virt && kv "virt" "$(systemd-detect-virt 2>/dev/null)"

sub "调优状态（判读全文的前提）"
# v2.0.0 起 node.env 不再记录调优字段，唯一可信的判据是这两个文件是否存在——
# 它们只由 `xh tuning on` 创建，`xh tuning off` 删除。
TUNED=no
[[ -f /etc/sysctl.d/99-xray-xhttp.conf ]] && TUNED=yes
if [[ "$TUNED" == yes ]]; then
  kv "xh tuning" "已开启 —— 第 1 节的内核参数含本项目写入的值"
else
  kv "xh tuning" "未开启 —— 第 1 节全是系统默认值，第 5 节无 policy/sockopt（预期状态）"
fi

sub "本项目写入的调优文件"
for f in /etc/sysctl.d/99-xray-xhttp.conf /etc/security/limits.d/99-xray-xhttp.conf; do
  if [[ -f "$f" ]]; then
    echo "[存在] $f"
    sed 's/^/    /' "$f"
  else
    echo "[不存在] $f   （未执行 xh tuning on 时本就不存在）"
  fi
done

sub "node.env（本项目安装状态）"
# v2.0.0 移除了 TUNE_TIER / XRAY_BUFFER_KB / TUNING_BBR_OK / FEATURE_TUNING /
# FEATURE_SYSCTL / FEATURE_H3_DIRECT 这些字段——安装期不再做调优，也就无从记录。
# 继续 grep 它们只会在每台机器上打印空行，造成"调优丢了"的错觉。
if [[ -f /etc/xhttp-cdn/node.env ]]; then
  grep -E '^(PROJECT_NAME|INSTALL_TIME|OS_ID|SERVICE_TYPE|IP_CHOICE|FALLBACK_MODE|FEATURE_XPADDING|FEATURE_CDN_ECH|CDN_ECH_ENABLED)=' \
    /etc/xhttp-cdn/node.env
else
  echo "n/a"
fi

sub "所有 sysctl 配置文件内容（查重复 / 冲突）"
grep -RsHE '^[[:space:]]*[a-z]' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null | sed 's/^/  /' || echo "  n/a"

# ==================================================
sec "1. 内核网络参数"

sub "拥塞控制 / 队列规则"
sy net.ipv4.tcp_available_congestion_control
sy net.ipv4.tcp_congestion_control
sy net.core.default_qdisc
kv "tcp_bbr 模块已加载" "$(lsmod 2>/dev/null | grep -c '^tcp_bbr') (0 也可能是编译进内核)"

sub "缓冲区"
for k in net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
         net.core.optmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mem \
         net.ipv4.udp_mem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min; do
  sy "$k"
done

# tcp_mem 单位是"页"，页大小不一定是 4K（见 lessons.md L4）。这里做量纲断言。
PS=$(getconf PAGESIZE 2>/dev/null || echo 4096)
TM=$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)
MT=$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo 2>/dev/null)
if [[ -n "$TM" && -n "$MT" ]]; then
  awk -v tm="$TM" -v ps="$PS" -v mt="$MT" 'BEGIN{
    n=split(tm,a," "); if(n<3) exit;
    hi=a[3]*ps;
    printf "%-40s %.0f MB (物理内存 %.0f MB) -> %s\n", "tcp_mem 上限换算",
      hi/1048576, mt/1048576, (hi<mt ? "OK 低于物理内存" : "!! 超过物理内存，内存压力机制失效");
  }'
fi

sub "队列 / 积压"
for k in net.core.somaxconn net.core.netdev_max_backlog net.core.netdev_budget \
         net.core.netdev_budget_usecs net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_abort_on_overflow; do
  sy "$k"
done

sub "连接状态与超时"
for k in net.ipv4.tcp_fastopen net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse \
         net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_syncookies net.ipv4.tcp_slow_start_after_idle \
         net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat net.ipv4.ip_local_port_range \
         net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes; do
  sy "$k"
done

sub "文件句柄"
sy fs.file-max
sy fs.nr_open
kv "fs.file-nr (已分配/空闲/上限)" "$(cat /proc/sys/fs/file-nr 2>/dev/null)"
kv "ulimit -n (当前 shell)" "$(ulimit -n 2>/dev/null)"
for p in xray nginx; do
  pid=$(pgrep -x "$p" 2>/dev/null | head -1)
  if [[ -n "$pid" ]]; then
    kv "$p 进程 nofile (soft/hard)" "$(awk '/Max open files/{print $4" / "$5}' "/proc/$pid/limits" 2>/dev/null)"
  fi
done

sub "vm 参数"
for k in vm.swappiness vm.dirty_ratio vm.dirty_background_ratio vm.max_map_count vm.overcommit_memory; do
  sy "$k"
done

sub "!! 已废弃 / 无效参数检测"
for k in net.ipv4.tcp_tw_recycle net.ipv4.tcp_low_latency net.ipv4.tcp_no_metrics_save \
         net.ipv4.tcp_frto_response net.ipv4.tcp_bic net.ipv4.tcp_westwood \
         net.ipv4.tcp_vegas_cong_avoid net.ipv4.tcp_default_win_scale; do
  if sysctl -n "$k" >/dev/null 2>&1; then
    echo "  [内核仍支持] $k = $(sysctl -n "$k" 2>/dev/null)"
  else
    echo "  [内核已移除] $k"
  fi
done

echo ""
echo "  配置文件里写了、但当前内核不认的项（这些才是真正需要删除的）："
FOUND_DEAD=0
grep -RshE '^[[:space:]]*(net|fs|vm|kernel)\.' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null |
  sed 's/=.*//; s/[[:space:]]//g' | sort -u | while read -r k; do
    [[ -z "$k" ]] && continue
    sysctl -n "$k" >/dev/null 2>&1 || echo "    !! $k"
  done
[[ "$FOUND_DEAD" -eq 0 ]] && echo "    (以上为空则说明没有失效项)"

# ==================================================
sec "2. Socket / 连接状态"
have ss && ss -s 2>/dev/null

sub "TCP 状态分布"
have ss && ss -ant 2>/dev/null | awk 'NR>1{c[$1]++} END{for(s in c) printf "  %-16s %d\n", s, c[s]}' | sort -k2 -rn

sub "TCP 监听队列（Recv-Q=当前积压, Send-Q=队列上限）"
have ss && ss -lnt 2>/dev/null | sed 's/^/  /'

sub "UDP 监听（QUIC / HTTP3）"
have ss && ss -lnu 2>/dev/null | sed 's/^/  /'

sub "!! Accept / SYN 队列溢出（非 0 说明 somaxconn / backlog 不足）"
if have nstat; then
  nstat -az 2>/dev/null | grep -E 'ListenOverflows|ListenDrops|TCPReqQFullDrop|TCPBacklogDrop|SyncookiesSent' | sed 's/^/  /'
else
  grep -E 'ListenOverflows|ListenDrops' /proc/net/netstat 2>/dev/null | sed 's/^/  /' || echo "  n/a"
fi

sub "!! UDP 错误（RcvbufErrors 非 0 = UDP 收缓冲不足，直接影响 h3 节点）"
have nstat && nstat -az 2>/dev/null | grep -E 'UdpInErrors|UdpRcvbufErrors|UdpSndbufErrors|UdpNoPorts' | sed 's/^/  /'
echo "  /proc/net/snmp Udp 行:"
grep -A1 '^Udp:' /proc/net/snmp 2>/dev/null | sed 's/^/    /'

sub "TCP 重传 / 丢包"
have nstat && nstat -az 2>/dev/null | grep -E 'TcpRetransSegs|TcpExtTCPLostRetransmit|TcpExtTCPTimeouts|TcpInErrs' | sed 's/^/  /'

sub "conntrack"
if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
  kv "nf_conntrack_count" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)"
  sy net.netfilter.nf_conntrack_max
  sy net.netfilter.nf_conntrack_tcp_timeout_established
  sy net.netfilter.nf_conntrack_buckets
else
  echo "  conntrack 未加载 — 对纯转发场景是好事（没有 NAT/state 的每包开销）"
fi

sub "防火墙规则量（规则越多，每包匹配开销越大）"
if have nft; then
  echo "  nftables 规则行数: $(nft list ruleset 2>/dev/null | wc -l)"
fi
if have iptables; then
  echo "  iptables -S 总条数: $(iptables -S 2>/dev/null | wc -l)"
  iptables -S 2>/dev/null | head -30 | sed 's/^/    /'
fi

# ==================================================
sec "3. CPU 拓扑与多核网络分布【重点】"
have lscpu && lscpu 2>/dev/null | grep -E 'Architecture|^CPU\(s\)|Thread|Core|Socket|NUMA|Model name|BogoMIPS|L3|Vendor'
kv "nproc" "$(nproc 2>/dev/null)"

sub "NUMA"
if have numactl; then
  numactl --hardware 2>/dev/null
else
  echo "  numactl 未安装；/sys 中 NUMA 节点数: $(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)"
fi

sub "网卡识别"
NIC=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
[[ -z "$NIC" ]] && NIC=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
kv "默认出口网卡" "${NIC:-未识别}"

if [[ -n "$NIC" ]]; then
  if have ethtool; then
    echo ""
    echo "  驱动 (-i):"
    ethtool -i "$NIC" 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  !! 队列数 (-l) — Combined 若为 1，说明只有单队列，RSS 无从谈起:"
    ethtool -l "$NIC" 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Ring buffer (-g):"
    ethtool -g "$NIC" 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Offload (-k) 关键项:"
    ethtool -k "$NIC" 2>/dev/null |
      grep -E 'tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload|rx-checksumming|tx-checksumming|scatter-gather' |
      sed 's/^/    /'
  else
    echo "  ethtool 未安装 — 无法读取队列数 / ring / offload（这是本阶段最关键的数据）"
  fi

  echo ""
  echo "  队列 sysfs 目录:"
  ls /sys/class/net/"$NIC"/queues/ 2>/dev/null | sed 's/^/    /'

  echo ""
  echo "  !! RPS / RFS / XPS 当前值（全 0 = 未启用）:"
  for q in /sys/class/net/"$NIC"/queues/rx-*; do
    [[ -e "$q" ]] || continue
    printf '    %-10s rps_cpus=%-12s rps_flow_cnt=%s\n' "$(basename "$q")" \
      "$(cat "$q/rps_cpus" 2>/dev/null)" "$(cat "$q/rps_flow_cnt" 2>/dev/null)"
  done
  for q in /sys/class/net/"$NIC"/queues/tx-*; do
    [[ -e "$q" ]] || continue
    printf '    %-10s xps_cpus=%s\n' "$(basename "$q")" "$(cat "$q/xps_cpus" 2>/dev/null)"
  done
  sy net.core.rps_sock_flow_entries
  kv "MTU" "$(cat /sys/class/net/$NIC/mtu 2>/dev/null)"
  kv "网卡 qdisc" "$(tc qdisc show dev $NIC 2>/dev/null | head -2 | tr '\n' ' ')"
fi

sub "!! 网卡中断分布（关键：看数字是否集中在某一个 CPU 列）"
head -1 /proc/interrupts 2>/dev/null | sed 's/^/  /'
grep -iE 'virtio|eth|ens|enp|mlx|ena' /proc/interrupts 2>/dev/null | sed 's/^/  /'

sub "IRQ affinity"
for i in $(grep -iE 'virtio|eth|ens|enp|mlx|ena' /proc/interrupts 2>/dev/null | awk -F: '{gsub(/ /,"",$1); print $1}'); do
  if [[ -f "/proc/irq/$i/smp_affinity_list" ]]; then
    printf '  IRQ %-6s affinity_list=%s\n' "$i" "$(cat "/proc/irq/$i/smp_affinity_list" 2>/dev/null)"
  fi
done
kv "irqbalance 状态" "$(systemctl is-active irqbalance 2>/dev/null || echo '未安装/未运行')"

sub "!! softnet_stat 每 CPU 统计"
echo "  CPU   processed    dropped     time_squeeze"
# strtonum() 是 gawk 扩展；Debian 默认 awk 是 mawk，不支持它，会静默输出空。
# 改用 bash 的 $((16#..)) 做十六进制转换，任何发行版都可用。
if [[ -r /proc/net/softnet_stat ]]; then
  _c=0
  while read -r f1 f2 f3 _rest; do
    [[ "$f1" =~ ^[0-9a-fA-F]+$ ]] || continue
    printf '  %-5d %-12d %-11d %d\n' "$_c" "$((16#$f1))" "$((16#$f2))" "$((16#$f3))"
    _c=$((_c+1))
  done < /proc/net/softnet_stat
else
  echo "  /proc/net/softnet_stat 不可读"
fi
echo ""
echo "  判读："
echo "    dropped 非 0      -> netdev_max_backlog 不足"
echo "    time_squeeze 非 0 -> netdev_budget 不足（一次 NAPI 轮询没处理完）"
echo "    processed 严重倾斜到 CPU0 -> 单核软中断瓶颈，需要 RSS 多队列或 RPS"

sub "CPU 利用率（3 次采样）"
if have mpstat; then
  mpstat -P ALL 1 3 2>/dev/null
else
  echo "  mpstat 未安装（apt install sysstat 可得精确的 %soft / %sys 分列数据）"
  echo "  /proc/stat 快照（user nice system idle iowait irq softirq）:"
  grep -E '^cpu' /proc/stat 2>/dev/null | sed 's/^/    /'
  sleep 3
  echo "  3 秒后:"
  grep -E '^cpu' /proc/stat 2>/dev/null | sed 's/^/    /'
fi

sub "!! softirq 累计分布（NET_RX / NET_TX 各列 = 各 CPU）"
head -1 /proc/softirqs 2>/dev/null | sed 's/^/  /'
grep -E '^\s*(NET_RX|NET_TX|TIMER|SCHED|RCU)' /proc/softirqs 2>/dev/null | sed 's/^/  /'

sub "负载"
kv "loadavg" "$(cat /proc/loadavg 2>/dev/null)"

# ==================================================
sec "4. Nginx"
have nginx && nginx -v 2>&1 | sed 's/^/  /'
if have nginx; then
  echo "  编译参数中的关键模块:"
  nginx -V 2>&1 | tr ' ' '\n' | grep -E 'http_v2|http_v3|threads|openssl|quic|boringssl' | sed 's/^/    /'
fi

sub "关键指令当前值（从 /etc/nginx 抓取）"
for d in worker_processes worker_connections worker_rlimit_nofile worker_cpu_affinity \
         multi_accept sendfile tcp_nodelay tcp_nopush aio open_file_cache \
         keepalive_timeout keepalive_requests ssl_session_cache ssl_session_tickets \
         ssl_protocols ssl_buffer_size access_log gzip; do
  v=$(grep -RhE "^[[:space:]]*${d}[[:space:]]" /etc/nginx/nginx.conf /etc/nginx/conf.d/ 2>/dev/null |
      sed 's/^[[:space:]]*//' | head -3 | tr '\n' '|')
  kv "$d" "${v:-<未设置，走默认值>}"
done
kv "listen 指令" "$(grep -RhE '^[[:space:]]*listen' /etc/nginx/nginx.conf 2>/dev/null | sed 's/^[[:space:]]*//' | tr '\n' '|')"
kv "http2 / http3" "$(grep -RhE '^[[:space:]]*http[23][[:space:]]' /etc/nginx/nginx.conf 2>/dev/null | sed 's/^[[:space:]]*//' | tr '\n' '|')"

sub "!! 文件描述符上限（worker_connections 的实际天花板）"
# worker_rlimit_nofile 只是 nginx 自己的请求值，真正生效的上限由 systemd unit /
# limits.d 决定。二者取小。若 nofile < worker_connections*2，配置里写多大都没用，
# error.log 会出现 "worker_connections exceed open file resource limit"。
# 本项目所有连接都是代理（grpc_pass / proxy_pass），每条占「客户端+上游」两个 fd。
for unit in nginx xray; do
  kv "systemd ${unit} LimitNOFILE" \
     "$(systemctl show "$unit" -p LimitNOFILE --value 2>/dev/null)"
done
for p in nginx xray; do
  pid=$(pgrep -o -x "$p" 2>/dev/null)
  [[ -n "$pid" ]] && kv "运行中 ${p}(pid ${pid}) Max open files" \
     "$(awk '/^Max open files/{print $4" (soft) / "$5" (hard)"}' "/proc/${pid}/limits" 2>/dev/null)"
done
kv "当前 shell ulimit -n" "$(ulimit -n 2>/dev/null)"
echo "  /etc/security/limits.d/ 内容:"
grep -rhE '^[^#]*nofile' /etc/security/limits.d/ /etc/security/limits.conf 2>/dev/null |
  sed 's/^/    /' || echo "    <无 nofile 配置>"
sy fs.file-max
sy fs.nr_open

sub "!! worker 进程与实际所在 CPU（psr 列）"
ps -eo pid,psr,pcpu,pmem,nlwp,comm 2>/dev/null | awk 'NR==1 || /nginx|xray/' | sed 's/^/  /'
echo "  若 nginx worker 的 psr 全相同或集中在少数几个，说明未做 worker_cpu_affinity"

sub "grpc / proxy 超时（XHTTP 长连接关键项）"
grep -REn 'grpc_(read|send|connect)_timeout|grpc_socket_keepalive|proxy_(read|send)_timeout|client_max_body_size|client_body_buffer_size' \
  /etc/nginx/ 2>/dev/null | sed 's/^/  /'

# ==================================================
sec "5. Xray"
have xray && xray version 2>/dev/null | head -1 | sed 's/^/  /'
XC=/usr/local/etc/xray/config.json
if [[ -f "$XC" ]]; then
  sub "policy / sockopt / xhttp（脱敏：不输出 UUID / 密钥）"
  # v2.0.0 起本项目不再注入 policy 与 sockopt，配置与上游逐字节一致。
  # 所以 policy 为 {}、sockopt 为空是**正确结果**；若这里有值，说明是你自己
  # 或旧版本安装留下的，需要对照 /usr/local/etc/xray/config.json 确认来源。
  if have python3; then
    python3 -c '
import json,sys
c=json.load(open("/usr/local/etc/xray/config.json"))
print("  log.loglevel:", c.get("log",{}).get("loglevel"))
print("  policy:", json.dumps(c.get("policy",{}),ensure_ascii=False))
for i,ib in enumerate(c.get("inbounds",[])):
    ss=ib.get("streamSettings",{})
    print("  inbound[%d] listen=%s port=%s net=%s security=%s" % (
        i, ib.get("listen"), ib.get("port"), ss.get("network"), ss.get("security")))
    if ss.get("sockopt"): print("    sockopt:", json.dumps(ss["sockopt"],ensure_ascii=False))
    if ss.get("xhttpSettings"):
        x=dict(ss["xhttpSettings"])
        print("    xhttpSettings:", json.dumps(x,ensure_ascii=False))
    if ib.get("sniffing"): print("    sniffing:", json.dumps(ib["sniffing"],ensure_ascii=False))
for i,ob in enumerate(c.get("outbounds",[])):
    ss=ob.get("streamSettings",{})
    print("  outbound[%d] tag=%s proto=%s sockopt=%s" % (
        i, ob.get("tag"), ob.get("protocol"), json.dumps(ss.get("sockopt",{}),ensure_ascii=False)))
' 2>/dev/null || grep -E 'bufferSize|connIdle|handshake|uplinkOnly|downlinkOnly|sockopt|tcpcongestion|tcpFastOpen' "$XC" | sed 's/^/  /'
  else
    grep -E 'bufferSize|connIdle|handshake|uplinkOnly|downlinkOnly|sockopt|tcpcongestion|tcpFastOpen' "$XC" | sed 's/^/  /'
  fi

  sub "进程运行态"
  pid=$(pgrep -x xray 2>/dev/null | head -1)
  if [[ -n "$pid" ]]; then
    kv "PID"              "$pid"
    kv "线程数 (Go 调度)" "$(ls /proc/$pid/task 2>/dev/null | wc -l)"
    kv "打开的 fd 数"     "$(ls /proc/$pid/fd 2>/dev/null | wc -l)"
    kv "GOMAXPROCS / GODEBUG" "$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep -E 'GOMAXPROCS|GODEBUG' | tr '\n' ' ')"
    have taskset && kv "CPU 亲和性" "$(taskset -pc $pid 2>/dev/null | sed 's/.*: //')"
    kv "VmRSS" "$(awk '/VmRSS/{print $2" "$3}' /proc/$pid/status 2>/dev/null)"
  fi
else
  echo "  未找到 $XC"
fi

# ==================================================
sec "6. 服务状态与日志"
for s in xray nginx; do
  kv "$s active" "$(systemctl is-active $s 2>/dev/null)"
  kv "$s NRestarts/Mem" "$(systemctl show -p NRestarts -p MemoryCurrent $s 2>/dev/null | tr '\n' ' ')"
done

sub "监听端口"
have ss && ss -lntup 2>/dev/null | grep -E 'xray|nginx' | sed 's/^/  /'

sub "最近错误日志"
echo "  [nginx error.log 最后 15 行]"
{ tail -15 /usr/local/nginx/logs/error.log 2>/dev/null || tail -15 /var/log/nginx/error.log 2>/dev/null || echo "n/a"; } | sed 's/^/    /'
echo ""
echo "  [xray journal warning 及以上，最后 15 条]"
{ journalctl -u xray -p warning -n 15 --no-pager 2>/dev/null || echo "n/a"; } | sed 's/^/    /'

sec "采集完成"
echo "把本文件完整内容贴回对话即可。"
echo "全程只读：未执行任何 sysctl -w、未写入任何文件、未重启任何服务。"
echo ""
if [[ "$TUNED" == yes ]]; then
  echo "本机已执行过 xh tuning on：第 1 节的内核参数含本项目写入的值，"
  echo "可与 xh tuning off 之后的一次采集做 diff 来量化差异。"
else
  echo "本机未执行 xh tuning on：第 1 节读到的是系统默认值，第 5 节无 policy/sockopt，"
  echo "这是 v2.0.0 的预期状态。要评估调优收益，请按脚本头部的两次采集法做对照。"
fi

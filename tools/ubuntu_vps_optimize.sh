#!/bin/bash
# ==================================================
# ubuntu_vps_optimize.sh —— Ubuntu VPS 全面性能优化（12 阶段）
#
# 适用：Ubuntu 24.04+ / ARM64(aarch64) / x86_64
# 用途：Xray Reality + XHTTP + CDN + Docker + AI Agent 高并发转发型 VPS
#
# 设计原则：
#   1. 所有 sysctl / modprobe 写入 best-effort：失败只记 SKIPPED，不中断
#   2. 只写自己的文件，不修改官方 unit、不覆盖用户 sysctl.conf
#   3. 页大小用 getconf PAGESIZE 运行时查询，不写死 4096（ARM64 常为 64KB）
#   4. 每次运行自动备份 → /var/backups/ubuntu_vps_optimize/
#   5. 幂等：重复运行不会叠加或损坏配置
#   6. 可回滚：bash $0 --rollback
#
# 用法：
#   sudo bash ubuntu_vps_optimize.sh              # 检测 + 优化 + 验证
#   sudo bash ubuntu_vps_optimize.sh --dry-run    # 只检测，不修改
#   sudo bash ubuntu_vps_optimize.sh --rollback   # 完整回滚
#   sudo bash ubuntu_vps_optimize.sh --verify-only # 只做检测与对比输出
# ==================================================

set -uo pipefail   # 故意不加 -e：best-effort 写操作不能中断整体

# ---- 常量 ----
TAG="ubuntu_vps_optimize"
SYSCTL_CONF="/etc/sysctl.d/99-${TAG}.conf"
LIMITS_CONF="/etc/security/limits.d/99-${TAG}.conf"
BACKUP_DIR="/var/backups/${TAG}"
LOG="/var/log/${TAG}.log"
XH_SYSCTL="/etc/sysctl.d/99-xray-xhttp.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

# ---- ANSI ----
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYA=$'\033[36m'; WHI=$'\033[1;37m'; NC=$'\033[0m'

# ---- 输出函数 ----
_log()  { printf '%s\n' "$*" | tee -a "$LOG" >/dev/null; printf '%s\n' "$*"; }
info() { _log "${CYA}[*]${NC} $*"; }
ok()   { _log "${GRN}[+]${NC} $*"; }
warn() { _log "${YLW}[!]${NC} $*"; }
die()  { _log "${RED}[x]${NC} $*"; exit 1; }
sec()  { _log ""; _log "${WHI}========== $* ==========${NC}"; }
kv()   { _log "$(printf '  %-40s %s' "$1" "${2:-n/a}")"; }
have() { command -v "$1" >/dev/null 2>&1; }
sysget() { sysctl -n "$1" 2>/dev/null; }

# ---- 模式解析 ----
DRY_RUN=false; ROLLBACK=false; VERIFY_ONLY=false
case "${1:-}" in
  --dry-run)    DRY_RUN=true ;;
  --rollback)   ROLLBACK=true ;;
  --verify-only) VERIFY_ONLY=true ;;
  "")           ;;
  *) die "用法: $0 [--dry-run|--rollback|--verify-only]" ;;
esac

[[ "$(id -u)" -eq 0 ]] || die "需要 root 权限（sudo bash $0）"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
_log ""; _log "===== ${TAG} $(date -Is 2>/dev/null || date) ====="

# ==================================================
# 回滚逻辑
# ==================================================
if $ROLLBACK; then
  sec "回滚"
  rm -f "$SYSCTL_CONF" "$LIMITS_CONF"
  for d in /etc/systemd/system/nginx.service.d \
           /etc/systemd/system/xray.service.d \
           /etc/systemd/system/docker.service.d; do
    rm -f "${d}/${TAG}.conf"; rmdir "$d" 2>/dev/null
  done
  # 恢复 nginx（优先用 .orig 原始副本）
  [ -f "${BACKUP_DIR}/nginx.conf.orig" ] && cp -a "${BACKUP_DIR}/nginx.conf.orig" /etc/nginx/nginx.conf
  # 恢复 CPU governor
  [ -f "${BACKUP_DIR}/cpu-governor.orig" ] && cp -a "${BACKUP_DIR}/cpu-governor.orig" /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
  have systemctl && systemctl daemon-reload 2>/dev/null
  sysctl --system >/dev/null 2>&1
  ok "回滚完成。运行时参数需重启或 sysctl --system 重新加载发行版默认值"
  exit 0
fi

# ==================================================
# 辅助函数
# ==================================================

# try_sysctl KEY VALUE —— 试写，成功记入 APPLIED
APPLIED=(); SKIPPED=()
try() {
  if $DRY_RUN || $VERIFY_ONLY; then APPLIED+=("$1 = $2"); return; fi
  if sysctl -w "$1=$2" >/dev/null 2>&1; then APPLIED+=("$1 = $2"); else SKIPPED+=("$1"); fi
}

# 多行命令输出（屏幕+日志）
_logcmd() { local out; out=$("$@" 2>/dev/null | sed 's/^/    /'); [[ -n "$out" ]] && _log "$out"; }

# ---- 冲突检测：与 xh tuning 互斥 ----
if [[ -f "$XH_SYSCTL" ]]; then
  warn "检测到 ${XH_SYSCTL}（xh tuning on 已开启）"
  warn "本脚本与 xh tuning 写同一批 sysctl key，同时存在会互相覆盖。"
  warn "建议：保留 xh（与本项目安装/升级流程一体），执行 xh tuning off && xh tuning on 拿最新调优值。"
  warn "确实要用本脚本：先 xh tuning off 再重跑。"
  warn "当前将继续执行（best-effort），但回滚可能不完整。"
fi

if $DRY_RUN; then _log ""; warn "--dry-run 模式：只检测与打印计划，不写任何文件"; fi
if $VERIFY_ONLY; then _log ""; info "--verify-only 模式：只检测与输出对比，不修改"; fi

# ==================================================
# ==== 第一阶段：系统检测 ===========================
# ==================================================
sec "第一阶段：系统全面检测"

# ---- 操作系统 ----
. /etc/os-release 2>/dev/null || true
OS_NAME="${PRETTY_NAME:-unknown}"
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
KERNEL=$(uname -r 2>/dev/null)
KMAJ=${KERNEL%%.*}; KMIN=$(echo "$KERNEL" | cut -d. -f2 | tr -cd '0-9')
ARCH=$(uname -m 2>/dev/null)
CPU_CORES=$(nproc 2>/dev/null || echo 1)
# ARM64 /proc/cpuinfo 没有 model name，走 lscpu
CPU_MODEL=$(awk -F: '/^(model name|Model)[[:space:]]*:/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
[[ -n "$CPU_MODEL" ]] || CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/^Model name/{gsub(/^ +/,"",$2); print $2; exit}')
[[ -n "$CPU_MODEL" ]] || CPU_MODEL=$(awk -F: '/^CPU part/{gsub(/^ +/,"",$2); print "ARM part "$2; exit}' /proc/cpuinfo 2>/dev/null)
PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null || echo 4096)
MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
MEM_GB=$((MEM_MB / 1024))
MEM_PAGES=$(awk -v ps="$PAGE_SIZE" '/^MemTotal:/{printf "%d", $2*1024/ps}' /proc/meminfo 2>/dev/null || echo 262144)
SWAP_MB=$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo unknown)
FS_TYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)
DISK_AVAIL=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
IPV4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
IPV6=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2; exit}' | cut -d/ -f1)
DNS1=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || echo unknown)
LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)

kv "OS"               "$OS_NAME"
kv "Kernel"           "$KERNEL (major=${KMAJ})"
kv "架构"             "$ARCH"
kv "CPU"              "${CPU_MODEL:-unknown} × ${CPU_CORES} 核"
kv "PAGESIZE"         "$PAGE_SIZE B ($([ "$PAGE_SIZE" -eq 4096 ] && echo '4 KB 标准' || echo '非标准，注意量纲')"
kv "内存"             "${MEM_MB} MB ≈ ${MEM_GB} GB"
kv "Swap"             "${SWAP_MB} MB"
kv "磁盘可用"         "${DISK_AVAIL} MB"
kv "文件系统"         "$FS_TYPE"
kv "虚拟化"           "$VIRT_TYPE"
kv "IPv4"             "${IPV4:-未获取}"
kv "IPv6"             "${IPV6:-未获取}"
kv "DNS"              "$DNS1"
kv "CPU 负载 (1/5/15)" "$LOAD"

# ---- 网络 ----
NIC=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[[ -n "${NIC:-}" ]] || NIC=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
MTU=$(ip link show "${NIC:-eth0}" 2>/dev/null | awk '/mtu/{print $5}' || echo unknown)
SERVICE_TYPE=$(have systemctl && echo systemd || echo other)

_log ""
kv "出网网卡"         "${NIC:-未识别}"
kv "MTU"              "$MTU"
kv "init"             "$SERVICE_TYPE"

# ---- BBR / qdisc 当前状态 ----
_log ""
_log "  拥塞算法:"
kv "  可用"  "$(sysget net.ipv4.tcp_available_congestion_control)"
kv "  当前"  "$(sysget net.ipv4.tcp_congestion_control)"
kv "  qdisc" "$(sysget net.core.default_qdisc)"

# ---- TCP 关键参数 ----
_log ""
_log "  TCP 核心参数:"
kv "  tcp_fastopen" "$(sysget net.ipv4.tcp_fastopen)"
kv "  tcp_rmem"    "$(sysget net.ipv4.tcp_rmem)"
kv "  tcp_wmem"    "$(sysget net.ipv4.tcp_wmem)"
kv "  rmem_max"    "$(sysget net.core.rmem_max)"
kv "  wmem_max"    "$(sysget net.core.wmem_max)"
kv "  somaxconn"   "$(sysget net.core.somaxconn)"
kv "  tcp_retries2" "$(sysget net.ipv4.tcp_retries2)"
kv "  tcp_syn_retries" "$(sysget net.ipv4.tcp_syn_retries)"
kv "  tcp_syncookies"  "$(sysget net.ipv4.tcp_syncookies)"
kv "  tcp_tw_reuse"    "$(sysget net.ipv4.tcp_tw_reuse)"
kv "  tcp_fin_timeout" "$(sysget net.ipv4.tcp_fin_timeout)"
kv "  tcp_keepalive_time"  "$(sysget net.ipv4.tcp_keepalive_time)"
kv "  tcp_keepalive_intvl" "$(sysget net.ipv4.tcp_keepalive_intvl)"
kv "  tcp_keepalive_probes" "$(sysget net.ipv4.tcp_keepalive_probes)"

# ---- 文件句柄 ----
_log ""
kv "  ulimit -n (当前)" "$(ulimit -n 2>/dev/null)"
kv "  fs.file-max"      "$(sysget fs.file-max)"

# ---- 内存参数 ----
_log ""
_log "  内存参数:"
kv "  vm.swappiness"        "$(sysget vm.swappiness)"
kv "  vm.vfs_cache_pressure" "$(sysget vm.vfs_cache_pressure)"
kv "  vm.dirty_ratio"       "$(sysget vm.dirty_ratio)"
kv "  vm.dirty_background_ratio" "$(sysget vm.dirty_background_ratio)"

# ---- 网卡 offload ----
_log ""
if have ethtool && [[ -n "${NIC:-}" ]]; then
  kv "  网卡" "$NIC"
  _log "  网卡 offload 特性:"
  ethtool -k "$NIC" 2>/dev/null | grep -E '^(rx-checksumming|tx-checksumming|scatter-gather|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' | sed 's/^/    /' | tee -a "$LOG" 2>/dev/null
  _log "  网卡队列:"
  ethtool -l "$NIC" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG" 2>/dev/null || _log "    驱动不支持 -l（单队列或虚拟网卡）"
  _logcmd bash -c "ethtool -i '$NIC' 2>/dev/null | grep -E '^(driver|version|bus-info):'"
fi

# ---- 监听端口 ----
_log ""
if have ss; then _log "  监听端口:"; _logcmd ss -tlnp; elif have netstat; then _logcmd netstat -tlnp; fi

# ---- CPU governor ----
_log ""
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
  kv "  CPU governor" "${GOV:-unknown}"
elif [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]]; then
  kv "  CPU governor" "文件存在但不可读（VM 可能不支持 scaling）"
else
  kv "  CPU governor" "无 cpufreq（VM/容器，由宿主机管理）"
fi
kv "  irqbalance" "$(systemctl is-active irqbalance 2>/dev/null || echo '未安装')"

# ---- 当前资源 ----
_log ""
_log "  当前资源使用:"
kv "  CPU 使用率"    "$(top -bn1 2>/dev/null | awk '/^%Cpu/{print $2"%"}' || echo unknown)"
kv "  内存使用"      "$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d MB / %d MB (%.0f%%)", $3, $2, $3/$2*100}' || echo unknown)"
kv "  TCP 连接数"    "$(ss -tan 2>/dev/null | grep -c 'ESTAB\|TIME_WAIT\|SYN' || echo unknown)"
kv "  Socket 总数"   "$(ss -s 2>/dev/null | head -1 || echo unknown)"
kv "  Xray 进程"     "$(pgrep -c xray 2>/dev/null || echo 0)"
kv "  Docker 容器"   "$(docker ps -q 2>/dev/null | wc -l || echo 'N/A')"

# ---- Xray 检测 ----
_log ""
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
if [[ -f "$XRAY_CONF" ]]; then
  _log "  Xray config.json 存在:"
  kv "  Xray 版本"    "$($XRAY_BIN version 2>/dev/null | head -1 || echo '无法获取')"
  kv "  Xray 服务"    "$(systemctl is-active xray 2>/dev/null || echo '未运行')"
  # 检测 config.json 关键字段
  if have python3; then
    python3 -c "
import json, sys
try:
    c = json.load(open('$XRAY_CONF'))
    ins = c.get('inbounds', [])
    for i, ib in enumerate(ins):
        p = ib.get('protocol', '?')
        ss = ib.get('streamSettings', {})
        sec = ss.get('security', 'none')
        net = ss.get('network', '?')
        xhs = ss.get('xhttpSettings', {})
        xpad = xhs.get('xPaddingObfsMode', 'no xpadding')
        print(f'    入站 {i}: {p} / {sec} / network={net} / xpadding={xpad}')
    # sockopt 与 policy
    for ib in ins:
        so = ib.get('streamSettings', {}).get('sockopt', {})
        if so: print(f'    sockopt: {json.dumps(so)}')
    pol = c.get('policy', {}).get('levels', {}).get('0', {})
    if pol: print(f'    policy.level.0: {json.dumps(pol)}')
except: print('    (JSON 解析失败，需手动检查)')
" 2>/dev/null | tee -a "$LOG"
  else
    kv "  (未安装 python3，跳过 Xray JSON 深度分析)"
  fi
else
  warn "  未找到 Xray config.json（${XRAY_CONF}）"
fi

# ---- Cloudflare 可达性（best-effort） ----
_log ""
if have curl; then
  CF_TEST=$(curl -sI --max-time 5 https://cloudflare.com 2>/dev/null | head -1 || echo '不可达')
  kv "  Cloudflare CDN" "${CF_TEST}"
fi

# ---- 发现的问题 ----
_log ""
sec "检测到的问题"
ISSUES=0
note() { warn "  $*"; ISSUES=$((ISSUES+1)); }

[[ "$(sysget net.ipv4.tcp_congestion_control)" == bbr ]] || note "拥塞控制不是 BBR —— 跨境高丢包链路上这是收益最大的单项优化"
[[ "$(sysget net.core.default_qdisc)" == fq ]] || note "qdisc 不是 fq —— BBR 缺了它收益大打折扣"
[[ "$(sysget net.ipv4.tcp_fastopen)" == 3 ]] || note "TFO 未双向开启（当前=$(sysget net.ipv4.tcp_fastopen)），每次新连接多一个 RTT"
[[ "$(sysget net.core.somaxconn)" -ge 4096 ]] 2>/dev/null || note "somaxconn 偏低（当前=$(sysget net.core.somaxconn)），高并发下 accept 队列溢出"
[[ "$(ulimit -n)" -ge 65536 ]] 2>/dev/null || note "ulimit -n 偏低（当前=$(ulimit -n)），限制 nginx worker_connections 上限"
[[ "$(sysget net.ipv4.tcp_slow_start_after_idle)" == 0 ]] 2>/dev/null || note "tcp_slow_start_after_idle=1 —— XHTTP 长连接空闲后会回退慢启动"
[[ "$(sysget net.ipv4.tcp_retries2)" -le 8 ]] 2>/dev/null || note "tcp_retries2=$(sysget net.ipv4.tcp_retries2)（默认 15）—— 僵尸连接回收太慢，占 fd"
# BBR 需要 4.9+
[[ "$KMAJ" -lt 4 ]] || { [[ "$KMAJ" -eq 4 ]] && [[ "${KMIN:-0}" -lt 9 ]]; } && note "内核 ${KERNEL} 过旧，BBR 需要 4.9+"
[[ $ISSUES -eq 0 ]] && ok "未发现明显问题"

if $VERIFY_ONLY; then
  _log ""; info "--verify-only 完成。以上为当前系统全貌。"; exit 0
fi

# ---- 内存分档（控制后续所有派生参数） ----
# NETDEV_BUDGET: NAPI 每轮 poll 包数上限，默认 300 在高 PPS 下 softirq 收不完
if   [[ "$MEM_MB" -ge 16384 ]]; then TIER=large;  SOCK_MAX=67108864; TCP_MAX=33554432; BACKLOG=65536; CONNTRACK=1048576; NETDEV_BUDGET=6000; SWAPPINESS=10
elif [[ "$MEM_MB" -ge 4096  ]]; then TIER=medium; SOCK_MAX=33554432; TCP_MAX=16777216; BACKLOG=32768; CONNTRACK=262144; NETDEV_BUDGET=6000; SWAPPINESS=10
else                                 TIER=small;  SOCK_MAX=16777216; TCP_MAX=8388608;  BACKLOG=16384; CONNTRACK=0; NETDEV_BUDGET=""; SWAPPINESS=30
fi

# ==================================================
# ==== 第二阶段：sysctl 网络优化 =====================
# ==================================================
sec "第二阶段：sysctl 网络优化（档位: ${TIER}）"
ok "socket 上限 $((SOCK_MAX/1024/1024)) MB / TCP 上限 $((TCP_MAX/1024/1024)) MB / backlog ${BACKLOG}"

# ---- 备份 ----
if ! $DRY_RUN; then
  mkdir -p "$BACKUP_DIR"
  sysctl -a > "${BACKUP_DIR}/sysctl-all.${STAMP}.txt" 2>/dev/null || warn "sysctl 快照导出失败"
  for f in /etc/sysctl.conf /etc/security/limits.conf /etc/nginx/nginx.conf /etc/fstab; do
    [[ -f "$f" ]] || continue
    cp -a "$f" "${BACKUP_DIR}/$(basename "$f").${STAMP}"
    [[ -f "${BACKUP_DIR}/$(basename "$f").orig" ]] || cp -a "$f" "${BACKUP_DIR}/$(basename "$f").orig"
  done
  # CPU governor 备份
  if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > "${BACKUP_DIR}/cpu-governor.orig"
  fi
  ok "备份 → ${BACKUP_DIR}"
fi

# ---- BBR ----
AVAIL=$(sysget net.ipv4.tcp_available_congestion_control)
if [[ "$AVAIL" != *bbr* ]]; then
  $DRY_RUN || { modprobe tcp_bbr >/dev/null 2>&1; AVAIL=$(sysget net.ipv4.tcp_available_congestion_control); }
fi
if [[ "$AVAIL" == *bbr* ]]; then
  try net.core.default_qdisc fq
  try net.ipv4.tcp_congestion_control bbr
  ok "BBR + fq 已就绪"
else
  warn "内核不提供 BBR（可用: ${AVAIL:-未知}），保持系统默认"
fi

# ---- socket 缓冲区（高 BDP 链路吞吐的决定性参数） ----
try net.core.rmem_max "$SOCK_MAX"
try net.core.wmem_max "$SOCK_MAX"
try net.core.rmem_default 1048576
try net.core.wmem_default 1048576
# tcp_rmem/wmem 中间值是初始值，autotuning 在 min~max 间动态增长
try net.ipv4.tcp_rmem "4096 262144 ${TCP_MAX}"
try net.ipv4.tcp_wmem "4096 262144 ${TCP_MAX}"
# 接收缓冲中协议开销比例：-2 使通告窗口更接近 rmem 实际大小
try net.ipv4.tcp_adv_win_scale -2
# tcp_mem 单位是「页」，按运行时 PAGESIZE 换算。量纲断言防止 64KB 页偏大 16 倍（L4）
MEM_BACK_MB=$(( MEM_PAGES * PAGE_SIZE / 1048576 ))
if [[ "$MEM_MB" -le 0 || "$MEM_BACK_MB" -lt $((MEM_MB*95/100)) || "$MEM_BACK_MB" -gt $((MEM_MB*105/100)) ]]; then
  warn "页数量纲自检失败（${MEM_PAGES} 页 × ${PAGE_SIZE} B = ${MEM_BACK_MB} MB ≠ ${MEM_MB} MB），跳过 tcp_mem"
else
  try net.ipv4.tcp_mem "$((MEM_PAGES*6/100)) $((MEM_PAGES*8/100)) $((MEM_PAGES*12/100))"
fi
# UDP 缓冲（QUIC / HTTP3 / Hysteria2 的关键项）
try net.core.optmem_max 65536
try net.ipv4.udp_rmem_min 8192
try net.ipv4.udp_wmem_min 8192

# ---- 队列与并发 ----
try net.core.netdev_max_backlog "$BACKLOG"
[[ -n "$NETDEV_BUDGET" ]] && try net.core.netdev_budget "$NETDEV_BUDGET"
try net.core.somaxconn 65535
try net.ipv4.tcp_max_syn_backlog "$BACKLOG"
try net.ipv4.tcp_max_tw_buckets 65536
try net.ipv4.ip_local_port_range "1024 65535"
# conntrack: 仅在模块已加载时写
[[ "$CONNTRACK" -gt 0 && -r /proc/sys/net/netfilter/nf_conntrack_max ]] && {
  try net.netfilter.nf_conntrack_max "$CONNTRACK"
  try net.netfilter.nf_conntrack_tcp_timeout_established 3600
}

# ---- 连接建立与保持 ----
try net.ipv4.tcp_mtu_probing 1
try net.ipv4.tcp_slow_start_after_idle 0    # XHTTP 长连接最关键单行
try net.ipv4.tcp_notsent_lowat 16384         # 延迟收益，非吞吐
try net.ipv4.tcp_syncookies 1
try net.ipv4.tcp_tw_reuse 1                  # 仅出站方向复用，安全
try net.ipv4.tcp_retries2 8                  # 僵尸连接 ~1 分钟回收（默认 15 ≈ 15 分钟）
try net.ipv4.tcp_syn_retries 4               # 出站 SYN ~30s 放弃（默认 6 ≈ 3 分钟）
try net.ipv4.tcp_rfc1337 1                   # TIME_WAIT 暗杀保护
try net.ipv4.tcp_fin_timeout 15
# keepalive 先于 CDN/NAT 常见 900s 空闲回收探活
try net.ipv4.tcp_keepalive_time 600
try net.ipv4.tcp_keepalive_intvl 30
try net.ipv4.tcp_keepalive_probes 5

# ---- 文件句柄 ----
try fs.file-max 1048576
try fs.nr_open 1048576

# ---- 落盘 ----
if $DRY_RUN; then
  info "计划写入 ${#APPLIED[@]} 项 → ${SYSCTL_CONF}"
  printf '    %s\n' "${APPLIED[@]}"
elif [[ ${#APPLIED[@]} -gt 0 ]]; then
  {
    echo "# ${TAG} 生成于 ${STAMP}"
    echo "# 回滚: bash $0 --rollback"
    printf '%s\n' "${APPLIED[@]}"
  } > "$SYSCTL_CONF"
  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || \
    warn "sysctl 重载失败，参数已在运行时生效"
  ok "已应用 ${#APPLIED[@]} 项内核参数 → ${SYSCTL_CONF}"
else
  warn "当前环境不允许修改任何 sysctl 参数，已跳过内核调优"
fi
[[ ${#SKIPPED[@]} -gt 0 ]] && warn "内核不支持或只读，已跳过: ${SKIPPED[*]}"

# ==================================================
# ==== 第三阶段：TCP Fast Open =======================
# ==================================================
sec "第三阶段：TCP Fast Open"
FO_BEFORE=$(sysget net.ipv4.tcp_fastopen)
try net.ipv4.tcp_fastopen 3    # 3 = 客户端 + 服务端双向开启
FO_AFTER=$(sysget net.ipv4.tcp_fastopen)
kv "tcp_fastopen (Before)" "$FO_BEFORE"
kv "tcp_fastopen (After)"  "$FO_AFTER"
[[ "$FO_AFTER" == 3 ]] && ok "TFO 双向已开启（节省新连接一个 RTT）"
warn "TFO 需客户端侧也开启才能生效，本配置只覆盖服务端"

# ==================================================
# ==== 第四阶段：文件句柄与连接优化 ==================
# ==================================================
sec "第四阶段：文件句柄与连接优化"
NOFILE_BEFORE=$(ulimit -n 2>/dev/null || echo unknown)

# limits.d
if ! $DRY_RUN && [[ "$OS_ID" != alpine ]] && [[ -d /etc/security/limits.d ]]; then
  cat > "$LIMITS_CONF" <<'LIMITSEOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITSEOF
  ok "已写入 limits.d → ${LIMITS_CONF}（重新登录生效）"
fi

# systemd drop-in：用 override.conf 不碰官方 unit
if ! $DRY_RUN && [[ "$SERVICE_TYPE" == systemd ]]; then
  for unit in nginx xray docker; do
    systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 || continue
    install -d -m 755 "/etc/systemd/system/${unit}.service.d" 2>/dev/null || continue
    cat > "/etc/systemd/system/${unit}.service.d/${TAG}.conf" <<DROPIN
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
DROPIN
  done
  systemctl daemon-reload >/dev/null 2>&1
  ok "已为 nginx / xray / docker 写入 systemd drop-in（LimitNOFILE=1048576，需 restart）"
fi

kv "ulimit -n (Before)" "$NOFILE_BEFORE"
kv "ulimit -n (目标)"   "1048576（重新登录 / restart 后生效）"

# ==================================================
# ==== 第五阶段：网卡优化 ============================
# ==================================================
sec "第五阶段：网卡优化"
if have ethtool && [[ -n "${NIC:-}" ]]; then
  _log "  网卡 ${NIC} offload 状态（修改前）:"
  ethtool -k "$NIC" 2>/dev/null | grep -E '^(rx-checksumming|tx-checksumming|scatter-gather|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' | sed 's/^/    /'
  _log ""
  # 云厂商虚拟网卡（virtio_net / ENA / gVNIC）: GRO/GSO/TSO 默认已开启，
  # 且卸载路径归宿主机管。强制修改是纯下行风险，没有可验证收益。
  # 只在驱动明确支持且当前关闭时才尝试开启（best-effort）。
  DRV=$(ethtool -i "$NIC" 2>/dev/null | awk '/^driver:/{print $2}')
  kv "  网卡驱动" "${DRV:-unknown}"
  if [[ "${DRV:-}" == virtio* ]]; then
    info "virtio 驱动：GRO/GSO/TSO 由宿主机卸载管理，不修改"
  else
    for feat in rx-checksumming tx-checksumming scatter-gather tcp-segmentation-offload generic-segmentation-offload generic-receive-offload; do
      CUR=$(ethtool -k "$NIC" 2>/dev/null | awk -v f="$feat" '$1==f":/{print $2}')
      if [[ "$CUR" == off ]] && ! $DRY_RUN; then
        ethtool -K "$NIC" "$feat" on >/dev/null 2>&1 && info "  已启用 ${feat}" || true
      fi
    done
  fi
  # ring buffer（如果支持）：只读报告，不修改
  ethtool -g "$NIC" 2>/dev/null | sed 's/^/    Ring: /' | tee -a "$LOG" 2>/dev/null
else
  warn "未安装 ethtool 或未识别网卡，跳过"
fi

# ==================================================
# ==== 第六阶段：CPU 优化 ============================
# ==================================================
sec "第六阶段：CPU 优化"

# ---- CPU governor ----
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  GOV_BEFORE=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
  kv "CPU governor (Before)" "${GOV_BEFORE:-unknown}"

  # ARM Ampere / AWS Graviton 上 performance 是合理默认值：
  # 转发负载的 CPU 使用是间断的（中断驱动），ondemand/powersave 的升频延迟
  # （~10-30ms）会在突发时引入尾延迟。performance 锁定最高频，代价是空载功耗。
  # VM 里 cpufreq 常不存在或只读——尝试写入 performance，失败就跳过。
  if [[ "$GOV_BEFORE" != performance ]]; then
    if ! $DRY_RUN; then
      for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > "$cpu" 2>/dev/null || true
      done
    fi
    GOV_AFTER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')
    kv "CPU governor (After)"  "${GOV_AFTER:-N/A}"
    [[ "$GOV_AFTER" == performance ]] && ok "CPU governor → performance" || warn "CPU governor 写入失败（VM 常由宿主机控制，属正常）"
  else
    ok "CPU governor 已是 performance"
  fi
else
  kv "CPU governor" "无 cpufreq 接口（VM/容器，由宿主机管理）"
fi

# ---- irqbalance ----
if have systemctl; then
  IRQB=$(systemctl is-active irqbalance 2>/dev/null || echo '未安装')
  kv "irqbalance" "$IRQB"
  if [[ "$IRQB" == inactive || "$IRQB" == dead ]]; then
    if ! $DRY_RUN; then
      systemctl enable --now irqbalance >/dev/null 2>&1 && ok "irqbalance 已启用" || warn "irqbalance 启用失败（可能未安装，apt install irqbalance）"
    fi
  elif [[ "$IRQB" == active ]]; then
    ok "irqbalance 已运行"
  fi
fi

# ---- CPU affinity 建议 ----
_log ""
kv "CPU 核心数"  "$CPU_CORES"
RPS_CPUS=""
for ((i=0; i<CPU_CORES; i++)); do RPS_CPUS="${RPS_CPUS}$i "; done
RPS_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))
_log "  RPS/XPS 建议（本脚本不自动设置，需按网卡队列数手工调）:"
_log "    echo ${RPS_MASK} > /sys/class/net/${NIC:-eth0}/queues/rx-0/rps_cpus"
_log "    原因：RPS 把软中断分散到多核，但若网卡只有 1 个队列，RPS 仅在一个队列内工作——"
_log "    收益取决于流量模式，盲目设可能增加 cache 抖动。建议先跑 iperf3 对照再决定。"

# ==================================================
# ==== 第七阶段：内存优化 ============================
# ==================================================
sec "第七阶段：内存优化（${MEM_GB} GB）"

# ---- swappiness ----
SWAP_BEFORE=$(sysget vm.swappiness)
try vm.swappiness "$SWAPPINESS"
kv "vm.swappiness (Before)" "$SWAP_BEFORE"
kv "vm.swappiness (After)"  "$(sysget vm.swappiness)"
_log "  调至 ${SWAPPINESS}：转发型服务器没有写负载，降低 swap 倾向但不关——OOM 时 swap 比杀进程安全"

# ---- vfs_cache_pressure ----
VFS_BEFORE=$(sysget vm.vfs_cache_pressure)
try vm.vfs_cache_pressure 50
kv "vm.vfs_cache_pressure (Before)" "$VFS_BEFORE"
kv "vm.vfs_cache_pressure (After)"  "$(sysget vm.vfs_cache_pressure)"
_log "  50：降低 dentry/inode 回收倾向，连接数多时减少 inode 重读"

# dirty_ratio：转发型机器没有磁盘写负载，不调。
# 解释：dirty_ratio 控制脏页比例阈值。这台机器转发字节、不落盘，调它没有可作用的负载。
# legacy min_free_kbytes 也不动：内核自动计算的值对 24GB 机器足够准确。
_log "  dirty_ratio / dirty_background_ratio：不调（转发型机器无落盘负载）"

# overcommit_memory：Linux 默认 0（启发式）对转发负载足够。1（总是允许）是 Redis fork 快照场景的建议。
_log "  vm.overcommit_memory：保持默认 0（启发式），不改 1"

# ==================================================
# ==== 第八阶段：Xray 优化 ===========================
# ==================================================
sec "第八阶段：Xray 优化"

if [[ -f "$XRAY_CONF" ]]; then
  # ---- policy.bufferSize ----
  # ARM64 上 Xray 默认 bufferSize 只有 4 KB（x86 是 512 KB），同样配置下 ARM 吞吐被压死。
  # 按内存分档显式写入。
  if   [[ "$MEM_MB" -ge 16384 ]]; then XRAY_BUFFER_KB=512
  elif [[ "$MEM_MB" -ge 4096  ]]; then XRAY_BUFFER_KB=256
  else XRAY_BUFFER_KB=64
  fi
  kv "policy.bufferSize 建议" "${XRAY_BUFFER_KB} KB（当前档位: ${TIER}）"

  # ---- Xray config.json 深度分析 ----
  if have python3; then
    ANALYSIS=$(python3 -c "
import json
c = json.load(open('$XRAY_CONF'))
issues = []

# policy
pol = c.get('policy', {})
lv0 = pol.get('levels', {}).get('0', {})
bs = lv0.get('bufferSize', '未设置')
if bs == '未设置':
    issues.append('policy.bufferSize 未设置 —— ARM64 上默认仅 4 KB，建议显式写入 ' + str(${XRAY_BUFFER_KB}) + ' KB')

# inbounds analysis
for ib in c.get('inbounds', []):
    p = ib.get('protocol')
    ss = ib.get('streamSettings', {})
    sockopt = ss.get('sockopt', {})
    tcpcc = sockopt.get('tcpcongestion', '未设置')
    tfo = sockopt.get('tcpFastOpen', '未设置')

    if p == 'vless' and ss.get('security') == 'reality':
        if tcpcc == '未设置':
            issues.append('Reality 入站未设置 sockopt.tcpcongestion —— 建议 BBR 可用时写 bbr')
        if tfo == '未设置':
            issues.append('Reality 入站未设置 sockopt.tcpFastOpen')

    # xhttp padding
    xhs = ss.get('xhttpSettings', {})
    if xhs.get('xPaddingObfsMode') == True:
        # padding enabled, check if extra has xmux
        pass

    # check extra for xmux concurrency
    if ss.get('network') == 'xhttp':
        settings = ib.get('settings', {})
        if not settings:
            issues.append(f'入站 {p}/xhttp: settings 字段缺失')

if not issues:
    print('OK|Xray 配置未发现明显问题')
else:
    for iss in issues:
        print('WARN|' + iss)
" 2>/dev/null)
    while IFS='|' read -r level msg; do
      case "$level" in
        OK)  ok "$msg" ;;
        WARN) warn "$msg" ;;
        *)   _log "    $msg" ;;
      esac
    done <<< "$ANALYSIS"
  fi

  # ---- TLS 与 ALPN ----
  _log ""
  _log "  TLS / ALPN 检测:"
  if have python3; then
    python3 -c "
import json
c = json.load(open('$XRAY_CONF'))
for ib in c.get('inbounds', []):
    ss = ib.get('streamSettings', {})
    sec = ss.get('security', 'none')
    alpn = ss.get('realitySettings', {}).get('', '') if sec == 'reality' else ''
    print(f'    {ib[\"protocol\"]}: security={sec}')
" 2>/dev/null | tee -a "$LOG"
  fi

  _log ""
  kv "  Cloudflare CDN 链路"   "Client → CF CDN → Nginx gRPC → Xray XHTTP(8001)"
  kv "  xmux concurrency"     "建议 16-32（已在 client-config.txt 模板中设置）"
  kv "  connection reuse"     "cMaxReuseTimes=0 为无限复用（客户端侧 xmux 参数）"
  kv "  xpadding + xmux"      "若未启用：模板中 XPAD_FIELDS_ENC / XMUX_ENC 控制"
else
  warn "未找到 Xray config.json，跳过 Xray 优化分析"
fi

# ==================================================
# ==== 第九阶段：Cloudflare 优化建议 =================
# ==================================================
sec "第九阶段：Cloudflare 优化建议（只读）"

_log "  以下为 Cloudflare Dashboard 中与该 VPS 对应的域名设置建议:"
_log ""
_log "  SSL/TLS:"
_log "    → 加密模式: 完全（严格）"
_log "    → 最低 TLS 版本: 1.3"
_log "    → 开启 TLS 1.3 0-RTT（客户端支持时省一个 RTT）"
_log ""
_log "  Speed → 优化:"
_log "    → Brotli: 开启（文本压缩率比 gzip 高 15-20%）"
_log "    → HTTP/3（使用 QUIC）: 开启（本项目的 UDP-cdn 节点依赖它）"
_log "    → Early Hints: 开启"
_log ""
_log "  Edge Certificates:"
_log "    → ECH (Encrypted Client Hello): 开启（消除 TLS SNI 明文泄露）"
_log "    → 证书透明度监控: 开启"
_log ""
_log "  Network:"
_log "    → gRPC: 开启（XHTTP + CDN 回源走 gRPC）"
_log "    → WebSockets: 开启（部分回落场景需要）"
_log ""
_log "  Caching → Cache Rules:"
_log "    → 将 XHTTP path 设为绕过缓存"
_log "    表达式: (http.host eq \"你的CDN域名\") or (http.request.uri.path contains \"你的path\")"
_log ""
_log "  DNS:"
_log "    → Reality 域名: 仅 DNS（灰云）"
_log "    → CDN 域名: 代理开启（橙云）"
_log ""
info "以上为 Cloudflare Dashboard 侧的配置建议，需在 CF 后台手动操作"

# ==================================================
# ==== 第十阶段：安全检查 ============================
# ==================================================
sec "第十阶段：安全检查"

# ---- SSH ----
_log "  SSH 配置:"
if have sshd; then
  SSHD_CONF=$(sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|port|pubkeyauthentication|usedns)' || true)
  while IFS=' ' read -r key val; do
    kv "  sshd ${key}" "${val}"
  done <<< "$SSHD_CONF"
fi

# ---- fail2ban ----
if have fail2ban-client; then
  kv "  fail2ban" "$(fail2ban-client status 2>/dev/null | head -1 || echo '运行中')"
else
  kv "  fail2ban" "未安装（apt install fail2ban 可安装）"
fi

# ---- 防火墙 ----
if have nft && nft list ruleset 2>/dev/null | grep -q .; then
  _log "  防火墙: nftables (有规则)"
elif have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
  _log "  防火墙: ufw (已启用)"
  _logcmd ufw status verbose
elif have iptables && [[ $(iptables -S 2>/dev/null | wc -l) -gt 3 ]]; then
  _log "  防火墙: iptables (有规则)"
else
  _log "  防火墙: 未检测到活动规则（云厂商安全组在机器外层）"
fi
warn "安全优化不自动修改任何 SSH/防火墙规则，避免失联。如需加固请手动执行。"

# ==================================================
# ==== 第十二阶段：优化后验证 ========================
# ==================================================
sec "第十二阶段：优化后验证（Before → After 对比）"

printf '\n  %-5s %-34s %-18s %-18s\n' "" "项目" "修改前" "修改后" | tee -a "$LOG"
printf '  %-5s %-34s %-18s %-18s\n' "" "----" "------" "------" | tee -a "$LOG"

# 从备份的 sysctl 快照提取 Before 值
_snap_get() {
  local key="$1"
  if [[ -f "${BACKUP_DIR}/sysctl-all.${STAMP}.txt" ]]; then
    awk -F' = ' -v k="$key" '$1==k{print $2; exit}' "${BACKUP_DIR}/sysctl-all.${STAMP}.txt" 2>/dev/null || echo "-"
  else
    echo "-"
  fi
}

compare() {
  local label="$1" key="$2" unit="$3"
  local before after
  if [[ -f "${BACKUP_DIR}/sysctl-all.${STAMP}.txt" ]]; then
    before=$(_snap_get "$key")
  else
    before="-"
  fi
  after=$(sysget "$key")
  printf '  %-5s %-34s %-18s %-18s\n' "" "${label}" "${before:-n/a}${unit}" "${after:-n/a}${unit}" | tee -a "$LOG"
}

compare "TCP 拥塞控制"    "net.ipv4.tcp_congestion_control" ""
compare "默认 qdisc"      "net.core.default_qdisc" ""
compare "TCP Fast Open"   "net.ipv4.tcp_fastopen" ""
compare "rmem_max"        "net.core.rmem_max" " B"
compare "wmem_max"        "net.core.wmem_max" " B"
compare "tcp_rmem"        "net.ipv4.tcp_rmem" ""
compare "tcp_wmem"        "net.ipv4.tcp_wmem" ""
compare "somaxconn"       "net.core.somaxconn" ""
compare "tcp_retries2"    "net.ipv4.tcp_retries2" ""
compare "tcp_notsent_lowat" "net.ipv4.tcp_notsent_lowat" ""
compare "tcp_slow_start_after_idle" "net.ipv4.tcp_slow_start_after_idle" ""
compare "netdev_budget"   "net.core.netdev_budget" ""
compare "netdev_max_backlog" "net.core.netdev_max_backlog" ""
compare "vm.swappiness"   "vm.swappiness" ""
compare "vfs_cache_pressure" "vm.vfs_cache_pressure" ""
compare "fs.file-max"     "fs.file-max" ""

# ulimit
NOFILE_AFTER=$(ulimit -n 2>/dev/null || echo unknown)
printf '  %-5s %-34s %-18s %-18s\n' "" "ulimit -n" "${NOFILE_BEFORE}" "${NOFILE_AFTER}（重新登录后: 1048576）" | tee -a "$LOG"

# BBR 模块状态
BBR_LOADED=$(lsmod 2>/dev/null | grep -c tcp_bbr || echo 0)
printf '  %-5s %-34s %-18s %-18s\n' "" "tcp_bbr 模块" "-" "$([[ $BBR_LOADED -gt 0 ]] && echo '已加载' || echo '未加载')" | tee -a "$LOG"

# 服务状态
for u in nginx xray; do
  if have systemctl && systemctl list-unit-files "${u}.service" >/dev/null 2>&1; then
    STS=$(systemctl is-active "$u" 2>/dev/null)
    NOFILE_LIMIT=$(systemctl show "$u" -p LimitNOFILE --value 2>/dev/null)
    printf '  %-5s %-34s %-18s %-18s\n' "" "${u} LimitNOFILE" "-" "${NOFILE_LIMIT:-N/A}（服务: ${STS}）" | tee -a "$LOG"
  fi
done

# CPU governor
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  GOV_NOW=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')
  printf '  %-5s %-34s %-18s %-18s\n' "" "CPU governor" "${GOV_BEFORE:-N/A}" "${GOV_NOW}" | tee -a "$LOG"
fi

# ==================================================
# 完成
# ==================================================
_log ""
sec "全部阶段完成"
ok "日志: ${LOG}"
ok "备份: ${BACKUP_DIR}"
ok "回滚: sudo bash $0 --rollback"

_log ""
_log "  后续手工步骤:"
_log "  1. systemctl restart xray nginx docker    # 使 systemd drop-in 生效"
_log "  2. 重新登录 shell                            # 使 limits.d 生效"
_log "  3. 在 Cloudflare Dashboard 完成第九阶段的建议"
_log "  4. 用 iperf3 / curl 验证吞吐与延迟改善"
_log ""
warn "limits.d 对交互 shell 需重新登录生效；systemd drop-in 需 restart 对应服务"
warn "本脚本与 xh tuning 互斥，请勿在此之后再执行 xh tuning on（会互相覆盖）"
[[ ${#SKIPPED[@]} -gt 0 ]] && warn "以下参数被跳过（内核不支持或只读）: ${SKIPPED[*]}"

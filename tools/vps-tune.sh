#!/bin/bash
# ==================================================
# vps-tune.sh —— 独立的 VPS 系统层调优（检测 → 备份 → 应用 → 验证 → 可回滚）
#
# 适用：Debian / Ubuntu / Oracle Linux / RHEL 系 / Alpine（部分降级）
# 用途场景：Nginx + Xray/XHTTP + CDN 回源 + Docker 的高并发转发型机器
#
# ---- 与 `xh tuning on` 的关系（重要）----
# 本仓库的管理命令 `xh tuning on` 已经覆盖内核/TCP/BBR/limits 这一层。
# 两者写的是同一批 sysctl key，**同时启用会互相覆盖，且回滚互相看不见**。
# 因此本脚本启动时会检测 /etc/sysctl.d/99-xray-xhttp.conf，存在则直接退出，
# 要求你先 `xh tuning off`，二选一。这是为了保住「可回滚」这条底线。
#
# 相对 `xh tuning on` 本脚本多做的部分：swap / swappiness、网卡特性检测、
# nginx 并发上限校正、以及一份可复查的执行日志。
#
# ---- 设计约束 ----
# 1. sysctl / limits / modprobe 全部 best-effort：OpenVZ、LXC、Alpine 上常为只读，
#    任何一项失败只记 SKIPPED，绝不中断（见 tasks/lessons.md L1）。
# 2. 只写自己的文件，不碰 /etc/sysctl.conf、不改发行版 unit 文件。
# 3. 页大小用 getconf PAGESIZE 运行时查询，不写死 4096（L4：aarch64 常为 64K）。
# 4. 改 nginx 后校验「能否启动」而不只是 nginx -t（L14）。
#
# 用法：
#   sudo bash vps-tune.sh            # 检测 + 应用
#   sudo bash vps-tune.sh --dry-run  # 只检测与打印计划，不写任何东西
#   sudo bash vps-tune.sh --rollback # 完整回滚
# ==================================================

set -uo pipefail   # 故意不加 -e：best-effort 的写操作失败不能中断整体（L1）

TAG="vps-tune"
SYSCTL_CONF="/etc/sysctl.d/99-${TAG}.conf"
LIMITS_CONF="/etc/security/limits.d/99-${TAG}.conf"
BACKUP_DIR="/var/backups/${TAG}"
LOG="/var/log/${TAG}.log"
XH_SYSCTL="/etc/sysctl.d/99-xray-xhttp.conf"
SWAPFILE="/swapfile-${TAG}"
STAMP="$(date +%Y%m%d-%H%M%S)"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYA=$'\033[36m'; NC=$'\033[0m'
log()  { printf '%s\n' "$*" | tee -a "$LOG" >/dev/null; printf '%s\n' "$*"; }
info() { log "${CYA}[*]${NC} $*"; }
ok()   { log "${GRN}[+]${NC} $*"; }
warn() { log "${YLW}[!]${NC} $*"; }
die()  { log "${RED}[x]${NC} $*"; exit 1; }
sec()  { log ""; log "${CYA}========== $* ==========${NC}"; }
kv()   { log "$(printf '  %-38s %s' "$1" "${2:-n/a}")"; }
have() { command -v "$1" >/dev/null 2>&1; }
sysget() { sysctl -n "$1" 2>/dev/null; }

DRY_RUN=false
MODE=apply
case "${1:-}" in
  --dry-run)  DRY_RUN=true ;;
  --rollback) MODE=rollback ;;
  "")         ;;
  *) die "用法: $0 [--dry-run|--rollback]" ;;
esac

[[ "$(id -u)" -eq 0 ]] || die "需要 root 权限（sudo bash $0）"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
$DRY_RUN && MODE_LABEL="dry-run" || MODE_LABEL="$MODE"
log ""; log "===== ${TAG} ${MODE_LABEL} @ $(date -Is 2>/dev/null) ====="

# ==================================================
# 回滚
# ==================================================
if [[ "$MODE" == rollback ]]; then
  sec "回滚"
  rm -f "$SYSCTL_CONF" "$LIMITS_CONF"
  rm -f "/etc/systemd/system/nginx.service.d/${TAG}.conf" \
        "/etc/systemd/system/xray.service.d/${TAG}.conf"
  rmdir /etc/systemd/system/nginx.service.d /etc/systemd/system/xray.service.d 2>/dev/null
  ok "已移除 sysctl / limits / systemd drop-in"

  # nginx 配置还原。**必须优先用 .orig（首次运行前的原始副本）**：
  # 带时间戳的备份是每次 apply 都会重新生成的，第二次运行时抓到的已经是被本脚本
  # 改过的文件，用它还原等于「回滚成调优后的状态」并报告成功——那会让整个
  # 「可回滚」的设计前提落空。
  LAST_NGINX="${BACKUP_DIR}/nginx.conf.orig"
  [[ -f "$LAST_NGINX" ]] || LAST_NGINX=$(ls -1tr "${BACKUP_DIR}"/nginx.conf.* 2>/dev/null | head -1)
  if [[ -n "$LAST_NGINX" && -f "$LAST_NGINX" ]]; then
    cp -a "$LAST_NGINX" /etc/nginx/nginx.conf && ok "nginx.conf 已还原自 ${LAST_NGINX}"
    if have nginx && nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
    fi
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    swapoff "$SWAPFILE" && rm -f "$SWAPFILE"
    sed -i "\|^${SWAPFILE} |d" /etc/fstab 2>/dev/null
    ok "已移除本脚本创建的 swap"
  fi

  have systemctl && systemctl daemon-reload >/dev/null 2>&1
  sysctl --system >/dev/null 2>&1
  ok "回滚完成"
  warn "已生效的运行时内核参数需重启系统才能完全恢复默认值"
  exit 0
fi

# ==================================================
# 1. 系统检测
# ==================================================
sec "1. 系统检测"

OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")
OS_NAME=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
KERNEL=$(uname -r 2>/dev/null)
KMAJ=${KERNEL%%.*}; KMIN=$(echo "$KERNEL" | cut -d. -f2 | tr -cd '0-9')
ARCH=$(uname -m 2>/dev/null)
CPU_CORES=$(nproc 2>/dev/null || echo 1)
# aarch64 的 /proc/cpuinfo 没有 model name，只有 CPU implementer/part 编码，
# 所以 x86 那套 awk 在 ARM 机器上必然输出 unknown。lscpu 会把编码解析成型号名。
CPU_MODEL=$(awk -F: '/^(model name|Model)[[:space:]]*:/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
[[ -n "$CPU_MODEL" ]] || CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/^Model name/{gsub(/^ +/,"",$2); print $2; exit}')
[[ -n "$CPU_MODEL" ]] || CPU_MODEL=$(awk -F: '/^CPU part/{gsub(/^ +/,"",$2); print "ARM part "$2; exit}' /proc/cpuinfo 2>/dev/null)
PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null || echo 4096)
MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
MEM_PAGES=$(awk -v ps="$PAGE_SIZE" '/^MemTotal:/{printf "%d", $2*1024/ps}' /proc/meminfo 2>/dev/null || echo 262144)
SWAP_MB=$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
NIC=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[[ -n "${NIC:-}" ]] || NIC=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
SERVICE_TYPE=$(have systemctl && echo systemd || echo other)

kv "OS"              "$OS_NAME (ID=${OS_ID})"
kv "kernel"          "$KERNEL"
kv "arch"            "$ARCH"
kv "CPU"             "${CPU_MODEL:-unknown} x ${CPU_CORES}"
kv "PAGESIZE"        "$PAGE_SIZE"
kv "MemTotal"        "${MEM_MB} MB (${MEM_PAGES} 页)"
kv "SwapTotal"       "${SWAP_MB} MB"
kv "虚拟化"          "$VIRT"
kv "出网网卡"        "${NIC:-未识别}"
kv "init"            "$SERVICE_TYPE"
kv "当前拥塞控制"    "$(sysget net.ipv4.tcp_congestion_control)"
kv "当前 qdisc"      "$(sysget net.core.default_qdisc)"
kv "可用拥塞算法"    "$(sysget net.ipv4.tcp_available_congestion_control)"
kv "ulimit -n"       "$(ulimit -n 2>/dev/null)"
kv "fs.file-max"     "$(sysget fs.file-max)"

# 多行输出统一走这两个，保证屏幕与日志内容一致
logcmd() { local out; out=$("$@" 2>/dev/null | sed 's/^/    /'); [[ -n "$out" ]] && log "$out"; }
logpipe() { local out; out=$(sed 's/^/    /'); [[ -n "$out" ]] && log "$out"; }

log ""
log "  磁盘:"
logcmd df -hT /
log "  监听端口:"
if have ss; then logcmd ss -tulnp; elif have netstat; then logcmd netstat -tulnp; fi
log "  防火墙:"
if have nft && nft list ruleset 2>/dev/null | grep -q .; then log "    nftables: 有规则"
elif have iptables && [[ $(iptables -S 2>/dev/null | wc -l) -gt 3 ]]; then log "    iptables: 有规则"
else log "    未检测到活动规则（云厂商安全组可能在机器外层）"; fi

# ---- 内存分档：所有派生值都从这里出 ----
if   [[ "$MEM_MB" -ge 16384 ]]; then TIER=large;  SOCK_MAX=67108864; TCP_MAX=33554432; BACKLOG=65536; CONNTRACK=1048576
elif [[ "$MEM_MB" -ge 4096  ]]; then TIER=medium; SOCK_MAX=33554432; TCP_MAX=16777216; BACKLOG=32768; CONNTRACK=262144
else                                 TIER=small;  SOCK_MAX=16777216; TCP_MAX=8388608;  BACKLOG=16384; CONNTRACK=0
fi
kv "调优档位" "$TIER（socket 上限 $((SOCK_MAX/1024/1024)) MB / backlog ${BACKLOG}）"

# ---- 发现的问题 ----
sec "发现的问题"
ISSUES=0
note() { warn "$*"; ISSUES=$((ISSUES+1)); }
[[ "$(sysget net.ipv4.tcp_congestion_control)" == bbr ]] || note "拥塞控制不是 bbr —— 跨境高丢包链路上这是收益最大的单项"
[[ "$(sysget net.core.default_qdisc)" == fq ]] || note "qdisc 不是 fq —— BBR 缺了它收益大打折扣"
[[ "$(sysget net.ipv4.tcp_fastopen)" == 3 ]] || note "TFO 未双向开启，每次新连接多一个 RTT"
[[ "$(sysget net.core.somaxconn)" -ge 4096 ]] 2>/dev/null || note "somaxconn 偏低，高并发下 accept 队列会溢出"
[[ "$(ulimit -n)" -ge 65536 ]] 2>/dev/null || note "ulimit -n 偏低（$(ulimit -n)），nginx worker_connections 会被它压住"
if [[ "$MEM_MB" -lt 2048 && "$SWAP_MB" -eq 0 ]]; then note "内存 ${MEM_MB} MB 且无 swap —— OOM 时内核会直接杀进程"; fi
# BBR 需要 4.9+，所以主版本 4 还要看次版本；5 以上一律满足
if [[ "$KMAJ" -lt 4 ]] || { [[ "$KMAJ" -eq 4 ]] && [[ "${KMIN:-0}" -lt 9 ]]; }; then
  note "内核 ${KERNEL} 过旧，BBR 需要 4.9+"
fi
[[ $ISSUES -eq 0 ]] && ok "未发现明显问题"

# ---- 冲突检测：与 xh tuning 二选一，否则回滚会失真 ----
if [[ -f "$XH_SYSCTL" ]]; then
  log ""
  log "  当前 ${XH_SYSCTL} 内容:"
  logcmd cat "$XH_SYSCTL"
  die "检测到 ${XH_SYSCTL}（xh tuning on 已开启）。
    两者写同一批 sysctl key，同时存在会互相覆盖，且各自的回滚都清不掉对方，
    「可回滚」这条会失效。

    多数情况下**建议保留 xh**：内核/TCP/BBR/limits 这一层两者做的事几乎相同，
    而 xh 与本仓库的安装/升级流程是一体的。本脚本相对 xh 多出来的只有
    swappiness、vfs_cache_pressure、swap 创建、网卡特性报告这几项。
    要拿到最新的调优取值，执行:  xh tuning off && xh tuning on

    确实要改用本脚本:  先  xh tuning off  再重跑本脚本"
fi

if $DRY_RUN; then log ""; warn "--dry-run：以下为计划应用的内容，不会写入任何文件"; fi

# ==================================================
# 2. 备份
# ==================================================
sec "2. 备份"
if ! $DRY_RUN; then
  mkdir -p "$BACKUP_DIR"
  sysctl -a > "${BACKUP_DIR}/sysctl-all.${STAMP}.txt" 2>/dev/null || warn "sysctl 快照导出失败（不影响后续）"
  for f in /etc/sysctl.conf /etc/security/limits.conf /etc/nginx/nginx.conf /etc/fstab; do
    [[ -f "$f" ]] || continue
    cp -a "$f" "${BACKUP_DIR}/$(basename "$f").${STAMP}"
    # .orig 只在首次创建，之后永不覆盖 —— 这是回滚唯一可信的基准。
    # 带时间戳的那份只是历史留档，重复运行时它已经是被改过的内容。
    [[ -f "${BACKUP_DIR}/$(basename "$f").orig" ]] || cp -a "$f" "${BACKUP_DIR}/$(basename "$f").orig"
  done
  ok "备份 → ${BACKUP_DIR}（时间戳 ${STAMP}）"
else
  info "将备份 sysctl 全量快照 + sysctl.conf / limits.conf / nginx.conf / fstab"
fi

# ==================================================
# 3~5. 内核网络 / 拥塞控制 / 内存
# ==================================================
sec "3. 内核参数"

APPLIED=(); SKIPPED=()
try() {  # try KEY VALUE —— 试写，成功才记入落盘清单
  if $DRY_RUN; then APPLIED+=("$1 = $2"); return; fi
  if sysctl -w "$1=$2" >/dev/null 2>&1; then APPLIED+=("$1 = $2"); else SKIPPED+=("$1"); fi
}

# ---- BBR：先探测再写。没有 bbr 就保持系统默认，不硬塞 ----
AVAIL=$(sysget net.ipv4.tcp_available_congestion_control)
if [[ "$AVAIL" != *bbr* ]]; then
  if $DRY_RUN; then
    # 加载内核模块是状态变更，--dry-run 承诺「不写任何东西」，这里不能 modprobe。
    # 改为只读判断模块是否可用。
    if [[ -d /lib/modules/$(uname -r) ]] && modinfo tcp_bbr >/dev/null 2>&1; then
      info "tcp_bbr 模块存在但未加载；实际运行时会 modprobe 后启用"
      AVAIL="${AVAIL} bbr"
    fi
  else
    modprobe tcp_bbr >/dev/null 2>&1
    AVAIL=$(sysget net.ipv4.tcp_available_congestion_control)
  fi
fi
if [[ "$AVAIL" == *bbr* ]]; then
  try net.core.default_qdisc fq                 # BBR 依赖的公平队列，缺它 BBR 退化
  try net.ipv4.tcp_congestion_control bbr       # 基于 BDP 估计，跨境高丢包链路收益最大
  ok "BBR 可用"
else
  warn "内核不提供 BBR（可用: ${AVAIL:-未知}），保持系统默认拥塞算法"
fi

# ---- socket 缓冲：决定高 BDP（CDN 回源 100~300ms RTT）链路的吞吐上限 ----
try net.core.rmem_max "$SOCK_MAX"
try net.core.wmem_max "$SOCK_MAX"
try net.core.rmem_default 1048576
try net.core.wmem_default 1048576
# 中间值是**初始**默认值，autotuning 会在 min~max 间增长；调大它省掉启动期几个 RTT 的爬升
try net.ipv4.tcp_rmem "4096 262144 ${TCP_MAX}"
try net.ipv4.tcp_wmem "4096 262144 ${TCP_MAX}"
# 单位是「页」，PAGESIZE 已在上面运行时查询（L4：aarch64 常为 64K，写死 /4 会偏大 16 倍）。
# 量纲断言：页数 × 页大小必须回算出物理内存（±5%）。页大小取错时这里会当场发现——
# 靠肉眼看 tcp_mem 的数值是发现不了的，那正是 L4 的失败方式。
MEM_BACK_MB=$(( MEM_PAGES * PAGE_SIZE / 1048576 ))
if [[ "$MEM_MB" -le 0 || "$MEM_BACK_MB" -lt $((MEM_MB*95/100)) || "$MEM_BACK_MB" -gt $((MEM_MB*105/100)) ]]; then
  warn "页数量纲自检失败（${MEM_PAGES} 页 × ${PAGE_SIZE} B = ${MEM_BACK_MB} MB ≠ ${MEM_MB} MB），跳过 tcp_mem"
else
  try net.ipv4.tcp_mem "$((MEM_PAGES*6/100)) $((MEM_PAGES*8/100)) $((MEM_PAGES*12/100))"
fi
try net.core.optmem_max 65536
try net.ipv4.udp_rmem_min 8192                  # QUIC/HTTP3 走 UDP，与 TCP 缓冲是两套
try net.ipv4.udp_wmem_min 8192

# ---- 队列与并发 ----
try net.core.netdev_max_backlog "$BACKLOG"      # 网卡收包队列，高 PPS 下防丢包
try net.core.somaxconn 65535                    # accept 队列上限，nginx listen backlog 受它压制
try net.ipv4.tcp_max_syn_backlog "$BACKLOG"     # 半连接队列
try net.ipv4.tcp_max_tw_buckets 65536
try net.ipv4.ip_local_port_range "1024 65535"   # CDN 回源是出站方向，端口耗尽是真实瓶颈
[[ "$CONNTRACK" -gt 0 && -r /proc/sys/net/netfilter/nf_conntrack_max ]] && {
  try net.netfilter.nf_conntrack_max "$CONNTRACK"          # 仅在模块已加载时写，否则徒增告警
  try net.netfilter.nf_conntrack_tcp_timeout_established 3600; }

# ---- 连接建立与保持 ----
try net.ipv4.tcp_fastopen 3                     # 客户端+服务端同时开，省一个 RTT
try net.ipv4.tcp_mtu_probing 1                  # PMTU 黑洞探测，中间设备丢 ICMP 时避免大包卡死
try net.ipv4.tcp_slow_start_after_idle 0        # 空闲后不回慢启动 —— XHTTP 长连接的关键项
# 调小 = 应用更早被唤醒补数据，本地排队更少。这是**延迟**收益不是吞吐收益：
# 拥塞窗口由 BBR 与 rmem/wmem 决定，与本项无关。
try net.ipv4.tcp_notsent_lowat 16384
try net.ipv4.tcp_syncookies 1                   # SYN 洪泛保护，不影响正常连接
try net.ipv4.tcp_tw_reuse 1                     # 仅出站方向复用 TIME_WAIT，安全
try net.ipv4.tcp_fin_timeout 15
try net.ipv4.tcp_keepalive_time 600             # 比 CDN/NAT 常见的 900s 空闲回收更早探活
try net.ipv4.tcp_keepalive_intvl 30
try net.ipv4.tcp_keepalive_probes 5

# ---- 文件句柄 ----
try fs.file-max 1048576
try fs.nr_open 1048576

# ---- 内存行为：转发型机器没有写负载，只调 swap 相关，不碰 dirty_ratio ----
# dirty_ratio / dirty_background_ratio 作用于脏页回写。这台机器转发字节、不落盘，
# 调它们没有可作用的负载，属于「无意义参数」，故意不写。
if [[ "$MEM_MB" -ge 4096 ]]; then try vm.swappiness 10; else try vm.swappiness 30; fi
try vm.vfs_cache_pressure 50                    # 降低 dentry/inode 回收倾向，连接数多时有实际收益
# 故意不设 vm.overcommit_memory：Linux 默认是 0（启发式），不是 2（严格）。
# 设成 1 是「总是允许」，那是 Redis fork 快照场景的建议，不是转发型负载的。
# 从 0 改到 1 并没有解除什么限制，只是关掉了启发式拒绝——收益无从证实。

# ---- 落盘 ----
if $DRY_RUN; then
  info "计划写入 ${#APPLIED[@]} 项 → ${SYSCTL_CONF}"
  printf '    %s\n' "${APPLIED[@]}"
elif [[ ${#APPLIED[@]} -gt 0 ]]; then
  { echo "# ${TAG} 生成于 ${STAMP}"; echo "# 回滚: bash $0 --rollback"; printf '%s\n' "${APPLIED[@]}"; } > "$SYSCTL_CONF"
  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || warn "sysctl 重载失败，参数已运行时生效但可能不持久"
  ok "已应用 ${#APPLIED[@]} 项内核参数 → ${SYSCTL_CONF}"
else
  warn "当前环境不允许修改任何 sysctl（常见于 OpenVZ / 受限容器），已跳过内核调优"
fi
[[ ${#SKIPPED[@]} -gt 0 ]] && warn "内核不支持或只读，已跳过: ${SKIPPED[*]}"

# ==================================================
# 6. 文件描述符上限
# ==================================================
sec "4. 文件描述符上限"
# 三处取小才是真实天花板：limits.d（登录会话）、systemd LimitNOFILE（服务进程）、
# fs.nr_open（内核硬上限）。nginx 的 worker_rlimit_nofile 再大也突破不了它们。
if $DRY_RUN; then
  info "计划写入 ${LIMITS_CONF} 与 nginx/xray 的 systemd drop-in（nofile 1048576）"
elif [[ "$OS_ID" != alpine ]] && [[ -d /etc/security/limits.d ]]; then
  printf '* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' > "$LIMITS_CONF"
  ok "已写入 ${LIMITS_CONF}（重新登录后对交互 shell 生效）"
fi
if ! $DRY_RUN && [[ "$SERVICE_TYPE" == systemd ]]; then
  # 用 drop-in 而不是改 unit 文件：包升级不会覆盖，回滚只需删这一个文件
  for unit in nginx xray; do
    systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 || continue
    install -d -m 755 "/etc/systemd/system/${unit}.service.d" 2>/dev/null || continue
    printf '[Service]\nLimitNOFILE=1048576\nLimitNPROC=infinity\n' > "/etc/systemd/system/${unit}.service.d/${TAG}.conf"
  done
  systemctl daemon-reload >/dev/null 2>&1
  ok "已为 nginx / xray 写入 systemd drop-in（LimitNOFILE=1048576，需 restart 生效）"
fi

# ==================================================
# 7. Swap
# ==================================================
sec "5. Swap"
# 不盲目关 swap：无 swap 的小内存机器 OOM 时内核直接杀进程。
# 但也不盲目建：已有 swap、内存充足、或容器内（swap 归宿主机管）都跳过。
if [[ "$SWAP_MB" -gt 0 ]]; then
  info "已有 swap ${SWAP_MB} MB，不改动"
elif [[ "$MEM_MB" -ge 2048 ]]; then
  info "内存 ${MEM_MB} MB 且无 swap —— 转发型负载常驻内存小，不强制创建"
elif [[ "$VIRT" == lxc || "$VIRT" == openvz || "$VIRT" == docker ]]; then
  warn "容器环境（${VIRT}），swap 由宿主机管理，跳过"
else
  SWAP_NEW=$(( MEM_MB < 1024 ? 1024 : MEM_MB ))
  DISK_FREE=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
  if [[ "${DISK_FREE:-0}" -lt $((SWAP_NEW + 2048)) ]]; then
    warn "根分区剩余 ${DISK_FREE} MB，不足以安全创建 ${SWAP_NEW} MB swap，跳过"
  elif $DRY_RUN; then
    info "计划创建 ${SWAP_NEW} MB swap → ${SWAPFILE}"
  else
    if fallocate -l "${SWAP_NEW}M" "$SWAPFILE" 2>/dev/null || \
       dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_NEW" status=none 2>/dev/null; then
      chmod 600 "$SWAPFILE"
      if mkswap "$SWAPFILE" >/dev/null 2>&1 && swapon "$SWAPFILE" 2>/dev/null; then
        grep -q "^${SWAPFILE} " /etc/fstab 2>/dev/null || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
        ok "已创建并启用 ${SWAP_NEW} MB swap"
      else
        rm -f "$SWAPFILE"; warn "swap 启用失败（内核可能未编译 swap 支持），已清理"
      fi
    else
      warn "swap 文件分配失败，跳过"
    fi
  fi
fi

# ==================================================
# 8. 网卡特性（只检测不修改）
# ==================================================
sec "6. 网卡特性（只读）"
# 故意不执行 ethtool -K：virtio / ENA 上 GRO/GSO/TSO 默认就开，且卸载路径归宿主机管。
# 在 VPS 里关停或强开它们是纯下行风险，没有可验证的收益。此处只报告现状。
if have ethtool && [[ -n "${NIC:-}" ]]; then
  kv "网卡" "$NIC"
  ethtool -k "$NIC" 2>/dev/null | grep -E '^(rx-checksumming|tx-checksumming|scatter-gather|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload):' | logpipe
  log "  队列（如支持）:"; ethtool -l "$NIC" 2>/dev/null | logpipe || log "    驱动不支持 -l"
  log "  驱动: $(ethtool -i "$NIC" 2>/dev/null | awk '/^driver:/{print $2}')"
  info "以上为现状。GRO/GSO/TSO 保持驱动默认，本脚本不修改（见脚本内注释）"
else
  warn "未安装 ethtool 或未识别网卡，跳过"
fi

# ==================================================
# 9. Nginx
# ==================================================
sec "7. Nginx"
NGINX_CONF=/etc/nginx/nginx.conf
if ! have nginx || [[ ! -f "$NGINX_CONF" ]]; then
  info "未检测到 nginx，跳过"
else
  CUR_WC=$(grep -hE '^[[:space:]]*worker_connections' "$NGINX_CONF" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  CUR_RL=$(grep -hE '^[[:space:]]*worker_rlimit_nofile' "$NGINX_CONF" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  kv "worker_connections"   "${CUR_WC:-<未设置，默认 512/1024>}"
  kv "worker_rlimit_nofile" "${CUR_RL:-<未设置，走 systemd LimitNOFILE>}"

  # 本项目生成的 nginx.conf 会被下次安装覆盖 —— 就地改只是临时措施
  if grep -q 'grpc_pass 127.0.0.1:8001' "$NGINX_CONF" 2>/dev/null; then
    warn "这份 nginx.conf 由 xray-xhttp 安装器生成，就地修改会在下次重装时被覆盖。"
    warn "永久改动请改 templates/nginx.conf.tmpl 后重新构建安装。"
  fi

  # 代理每连接占「客户端 + 上游」两个 fd，故 rlimit 至少取 wc 的 2 倍。
  # 取整到 131072 而非 131070，与 templates/nginx.conf.tmpl 保持同一个数，
  # 否则本脚本会把模板渲染出的值反复改写成差 2 的数字，纯噪音。
  WANT_WC=65535; WANT_RL=131072
  if [[ "${CUR_WC:-0}" -ge "$WANT_WC" && "${CUR_RL:-0}" -ge "$WANT_RL" ]] 2>/dev/null; then
    ok "nginx 并发上限已达标，无需改动"
  elif $DRY_RUN; then
    info "计划设置 worker_connections=${WANT_WC} / worker_rlimit_nofile=${WANT_RL}"
  else
    cp -a "$NGINX_CONF" "${BACKUP_DIR}/nginx.conf.${STAMP}"
    if [[ -n "${CUR_WC:-}" ]]; then
      sed -i -E "s/^([[:space:]]*)worker_connections[[:space:]]+[0-9]+;/\\1worker_connections ${WANT_WC};/" "$NGINX_CONF"
    else
      sed -i -E "s/^([[:space:]]*)(events[[:space:]]*\{)/\\1\\2\n    worker_connections ${WANT_WC};/" "$NGINX_CONF"
    fi
    if [[ -n "${CUR_RL:-}" ]]; then
      sed -i -E "s/^([[:space:]]*)worker_rlimit_nofile[[:space:]]+[0-9]+;/\\1worker_rlimit_nofile ${WANT_RL};/" "$NGINX_CONF"
    else
      sed -i -E "0,/^worker_processes/s//worker_rlimit_nofile ${WANT_RL};\nworker_processes/" "$NGINX_CONF"
    fi
    # L14：nginx -t 只解析配置、不 bind 端口，「能否启动」要单独验证
    if ! nginx -t >/dev/null 2>&1; then
      warn "nginx -t 未通过，已还原"; nginx -t 2>&1 | logpipe
      cp -a "${BACKUP_DIR}/nginx.conf.${STAMP}" "$NGINX_CONF"
    else
      if systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1; then
        sleep 1
        if systemctl is-active --quiet nginx; then
          ok "nginx 已更新并成功重载（wc=${WANT_WC} / rlimit=${WANT_RL}）"
        else
          warn "nginx 重载后未处于 active，已还原配置并重启"
          journalctl -u nginx -n 20 --no-pager 2>/dev/null | logpipe
          cp -a "${BACKUP_DIR}/nginx.conf.${STAMP}" "$NGINX_CONF"; systemctl restart nginx >/dev/null 2>&1
        fi
      else
        warn "nginx reload/restart 失败，已还原"
        journalctl -u nginx -n 20 --no-pager 2>/dev/null | logpipe
        cp -a "${BACKUP_DIR}/nginx.conf.${STAMP}" "$NGINX_CONF"; systemctl restart nginx >/dev/null 2>&1
      fi
    fi
  fi
fi

# ==================================================
# 10. 验证
# ==================================================
sec "8. 验证（Before / After）"
if $DRY_RUN; then
  warn "--dry-run 结束，未做任何修改"; exit 0
fi
printf '  %-32s %s\n' "net.ipv4.tcp_congestion_control" "$(sysget net.ipv4.tcp_congestion_control)" | tee -a "$LOG"
printf '  %-32s %s\n' "net.core.default_qdisc"          "$(sysget net.core.default_qdisc)"          | tee -a "$LOG"
printf '  %-32s %s\n' "net.core.rmem_max"               "$(sysget net.core.rmem_max)"               | tee -a "$LOG"
printf '  %-32s %s\n' "net.ipv4.tcp_rmem"               "$(sysget net.ipv4.tcp_rmem)"               | tee -a "$LOG"
printf '  %-32s %s\n' "net.ipv4.tcp_notsent_lowat"      "$(sysget net.ipv4.tcp_notsent_lowat)"      | tee -a "$LOG"
printf '  %-32s %s\n' "net.ipv4.tcp_fastopen"           "$(sysget net.ipv4.tcp_fastopen)"           | tee -a "$LOG"
printf '  %-32s %s\n' "net.core.somaxconn"              "$(sysget net.core.somaxconn)"              | tee -a "$LOG"
printf '  %-32s %s\n' "vm.swappiness"                   "$(sysget vm.swappiness)"                   | tee -a "$LOG"
have lsmod && kv "tcp_bbr 模块" "$(lsmod 2>/dev/null | awk '/^tcp_bbr/{print "已加载"}')"
for u in nginx xray; do
  have systemctl && systemctl list-unit-files "${u}.service" >/dev/null 2>&1 && \
    kv "${u} 服务" "$(systemctl is-active "$u" 2>/dev/null) / LimitNOFILE=$(systemctl show "$u" -p LimitNOFILE --value 2>/dev/null)"
done

sec "完成"
ok "日志: ${LOG}"
ok "备份: ${BACKUP_DIR}"
ok "回滚: bash $0 --rollback"
warn "limits.d 对交互 shell 需重新登录生效；systemd drop-in 需 systemctl restart 对应服务"
warn "本脚本与 xh tuning 互斥，请勿在此之后再执行 xh tuning on"

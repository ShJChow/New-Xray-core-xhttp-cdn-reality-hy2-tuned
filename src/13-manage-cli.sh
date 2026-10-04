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

ver_ge() {
  [[ "$1" == "$2" ]] && return 0
  local lowest
  lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)
  [[ "$lowest" == "$2" ]]
}

try_sysctl() {
  if sysctl -w "${1}=${2}" >/dev/null 2>&1; then
    declare -p SYSCTL_APPLIED >/dev/null 2>&1 && SYSCTL_APPLIED+=("${1} = ${2}")
    return 0
  else
    declare -p SYSCTL_SKIPPED >/dev/null 2>&1 && SYSCTL_SKIPPED+=("$1")
    return 1
  fi
}

# 本脚本自身的版本，由安装时的 sed 从占位符替换而来（见本文件末尾）。
# 不能直接写 ${PROJECT_VERSION}：外层 heredoc 是 quoted 的，不做变量展开。
#
# 它与 node.env 里的 PROJECT_VERSION 是**两个不同的东西**：
#   XH_VERSION      —— 生成这个 xh 脚本的版本
#   PROJECT_VERSION —— 当初安装这套节点的版本（node.env，装完就不再变）
# 两者不一致是正常的（升级过 xh、或手工替换过），`xh version` 会同时打印，
# 这样"我这台机器的 xh 是新是旧"一眼可见——此前只能靠 grep 源码里的特征字符串判断。
XH_VERSION="@@XH_VERSION@@"

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

update_node_env() {
  local key="$1" val="$2"
  [[ -f "$NODE_ENV_FILE" ]] || return 0
  if grep -q "^${key}=" "$NODE_ENV_FILE"; then
    sed -i -E "s|^${key}=.*|${key}='${val}'|" "$NODE_ENV_FILE"
  else
    printf '%s=%q\n' "$key" "$val" >> "$NODE_ENV_FILE"
  fi
}

# ---------------- 子命令 ----------------

cmd_status() {
  if [[ -s "${STATE_DIR}/updates-available" ]]; then
    echo -e "${YELLOW}[!] 有可用更新（每周检查，需手动执行）：${NC}"
    sed 's/^/  /' "${STATE_DIR}/updates-available"
    echo ""
  fi
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
  local _cores _mem _arch _tier _buf _buf_mb _cap_mb
  _cores=$(nproc 2>/dev/null || echo '?')
  _mem=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  _arch=$(uname -m 2>/dev/null || echo unknown)
  if   [[ "$_mem" -ge 16384 ]]; then _tier=large; _buf_mb=128; _cap_mb=128;
  elif [[ "$_mem" -ge 4096  ]]; then _tier=medium; _buf_mb=64; _cap_mb=64;
  elif [[ "$_mem" -ge 1536  ]]; then _tier=entry; _buf_mb=32; _cap_mb=32;
  else _tier=small; _buf_mb=16; _cap_mb=16; fi

  echo -e "  推荐缓冲区：             ${GREEN}${_buf_mb}MB${NC}"
  echo -e "  内存保护上限：           ${GREEN}${_cap_mb}MB${NC}"
  echo -e "  队列算法：               ${GREEN}$(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)${NC}"
  echo -e "  拥塞控制：               ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)${NC}"
  printf '  %-32s %s\n' "  └─ BBR 版本" "$(detect_bbr_version)"
  echo -e "  tcp_wmem:                 ${GREEN}$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo n/a)${NC}"
  echo -e "  tcp_rmem:                 ${GREEN}$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo n/a)${NC}"
  echo -e "  tcp_limit_output_bytes:   ${GREEN}$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo n/a)${NC}"
  echo -e "  tcp_slow_start_after_idle: ${GREEN}$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo n/a)${NC}"
  printf '  %-32s %s\n' "net.core.rmem_max"               "$(sysctl -n net.core.rmem_max 2>/dev/null || echo n/a)"
  printf '  %-32s %s\n' "net.ipv4.tcp_fastopen"           "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo n/a)"
  # config.json 带 // 注释（JSONC），jq 解析不了，用文本提取
  _buf=$(grep -oE '"bufferSize"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONF" 2>/dev/null \
         | head -1 | grep -oE '[0-9]+$')
  printf '  %-32s %s\n' "机型 / 调优档位" "${_cores} 核 / ${_mem} MB / ${_arch} → ${_tier}"
  printf '  %-32s %s\n' "Xray policy.bufferSize" "${_buf:-未设置} KB"
  if [[ -f "$SYSCTL_CONF" ]]; then
    printf '  %-32s %s\n' "调优配置文件" "$SYSCTL_CONF（已启用）"
  elif [[ -f /etc/sysctl.d/99-sbbox.conf ]]; then
    printf '  %-32s %s\n' "调优配置文件" "/etc/sysctl.d/99-sbbox.conf（已由 sbbox 启用生效）"
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
  local cur_minver
  cur_minver=$(grep -o '"minClientVer"[[:space:]]*:[[:space:]]*"[^"]*"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "")
  if [[ -n "$cur_minver" ]]; then
    echo "  minClientVer:    ${cur_minver}（兼容模式：支持 mihomo/Clash/sing-box）"
  else
    echo "  minClientVer:    未设置（严格模式：Xray 内核默认）"
  fi
  echo ""
  echo -e "${CYAN}[+] 直连 UDP 节点${NC}"
  if [[ "${FEATURE_H3_DIRECT:-false}" == true ]]; then
    echo "  h3-direct:       UDP ${H3_PORT:-443}（Xray 自己监听，不经 nginx）"
  else
    echo "  h3-direct:       未启用"
  fi
  if [[ "${FEATURE_H2_DIRECT:-false}" == true ]]; then
    echo "  h2-direct:       TCP ${H2_PORT:-8445}（h3-direct 的 TCP 孪生体）"
  else
    echo "  h2-direct:       未启用"
  fi
  if [[ "${FEATURE_HY2:-false}" == true ]]; then
    if [[ "${FEATURE_HY2_H3:-false}" == true ]]; then
      echo "  Hysteria2-H3:    UDP ${HY2_H3_PORT}（无混淆，随机端口）"
      echo "    认证密码:      ${HY2_PASSWORD}"
    fi
    if [[ "${FEATURE_HY2_OBFS:-false}" == true ]]; then
      echo "  Hysteria2-obfs:  UDP ${HY2_PORT}（同一认证密码）"
      echo "    混淆:          salamander（Xray finalmask）"
      echo "    混淆密码:      ${OBFS_PASSWORD}"
      echo "    ↑ 两个密码是独立的值，客户端两处都要填对才能握手"
    fi
  else
    echo "  Hysteria2:       未启用"
  fi
  if [[ "${FEATURE_MASQUE:-false}" == true ]]; then
    echo "  MASQUE 隧道:     UDP/TCP ${MASQUE_PORT:-8447}（RFC 9484 CONNECT-IP）"
    echo "    认证账号:      user@${CDN_DOMAIN:-example.com}"
  else
    echo "  MASQUE 隧道:     未启用"
  fi
  if [[ "${FEATURE_XDRIVE:-false}" == true ]]; then
    echo "  XDRIVE 网盘代理: 已启用 (Google Drive 穿透)"
  else
    echo "  XDRIVE 网盘代理: 未启用"
  fi
  if [[ "${FEATURE_NOISE_EXP:-false}" == true ]]; then
    echo "  Noise 动态混淆:  已开启 (${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>})"
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
  echo "  V2RayN (全量 base64):    ${base}/v2rayn.txt"
  echo "  V2RayN (TUN 订阅，全部节点): ${base}/v2rayn-tun.txt"
  echo "  Xray 原生 TUN 配置:      ${base}/xray-tun-{windows,linux,macos}.json  (Xray-core >= 26.9.30)"
  echo "  Shadowrocket (小火箭专属): ${base}/shadowrocket.txt"
  echo "  明文节点（备选）:        ${base}/v2rayn-raw.txt"
  echo "  Mihomo 完整分流:         ${base}/mihomo-full.yaml"
  echo "  Mihomo 完整分流(TUN 按平台): ${base}/mihomo-full-{windows,linux,macos,android}.yaml"
  echo "  Mihomo 纯节点:           ${base}/mihomo-nodes.yaml"
  echo ""
  echo -e "${YELLOW}  订阅拉不到节点时，先在该设备的浏览器里直接打开上面的链接：${NC}"
  echo "    打得开且有内容 → 客户端解析问题，改用明文订阅或手动导入单条节点"
  echo "    打不开         → 该设备到 VPS 的网络问题，与本项目配置无关"
  if command -v qrencode >/dev/null 2>&1; then
    echo ""
    echo -e "${YELLOW}[+] V2RayN 全量订阅二维码${NC}"
    qrencode -t ANSIUTF8 -m 1 "${base}/v2rayn.txt"
  fi
}

# 由 client-config.txt 生成 Xray 原生 TUN 客户端配置（Xray-core >= 26.9.30）：xray-tun-{windows,linux,macos}.json
# 用法：xray_tun_variants <client-config.txt> <输出目录>
xray_tun_variants() {
  local src="$1" outdir="$2"
  [[ -s "$src" ]] || return 0
  python3 - "$src" "$outdir" "${REALITY_DOMAIN:-}" "${CDN_DOMAIN:-}" "${VPS_IP:-}" <<'XTUNPY' || warn "Xray TUN 配置生成失败（不影响其它订阅）"
@@include templates/xray-tun-gen.py.tmpl
XTUNPY
}

# 按客户端平台生成 TUN 自适应的 Mihomo 完整分流配置（mihomo-full-<平台>.yaml）。
# 基础文件的 tun 段 strict-route: false、stack: mixed；各平台只改确有区别的字段：
#   windows：strict-route 开（防止 DNS 经物理网卡泄漏，Wintun 支持）
#   linux  ：strict-route + auto-redirect 开（nftables 重定向，TCP 不再进用户态协议栈，更省 CPU）
#   macos / android：保持基础值（macOS 不支持 strict-route，Android 由 VpnService 接管路由）
# 用法：mihomo_tun_variants <基础 yaml> <输出目录>
mihomo_tun_variants() {
  local src="$1" outdir="$2" p
  [[ -s "$src" ]] || return 0
  for p in windows linux macos android; do
    case "$p" in
      windows) sed 's/^  strict-route: false$/  strict-route: true/' "$src" > "${outdir}/mihomo-full-${p}.yaml" ;;
      linux)   sed -e 's/^  strict-route: false$/  strict-route: true\n  auto-redirect: true/' "$src" > "${outdir}/mihomo-full-${p}.yaml" ;;
      *)       cp "$src" "${outdir}/mihomo-full-${p}.yaml" ;;
    esac
  done
}

# 手工改过 ~/client-config.txt 后，用它把订阅文件重新生成，无需重跑安装脚本
cmd_resub() {
  [[ -f "$SUB_TOKEN_FILE" ]] || fail "未找到订阅 token，请先运行安装脚本"
  local home token subdir
  if [[ -z "${USER_HOME:-}" || ! -f "${USER_HOME}/client-config.txt" ]]; then
    for candidate in /home/ubuntu /home/opc /root; do
      if [[ -f "${candidate}/client-config.txt" ]]; then
        home="$candidate"
        break
      fi
    done
  else
    home="$USER_HOME"
  fi
  home="${home:-/root}"
  token=$(tr -d '\r\n' < "$SUB_TOKEN_FILE")
  subdir="/usr/local/nginx/html/sub/${token}"
  [[ -d "$subdir" ]] || fail "未找到订阅目录 ${subdir}"
  [[ -f "${home}/client-config.txt" ]] || fail "未找到 ${home}/client-config.txt"

  cp "${home}/client-config.txt" "${subdir}/v2rayn-raw.txt"
  base64 "${home}/client-config.txt" | tr -d '\n' > "${subdir}/v2rayn.txt"
  [[ -f "${home}/client-config-mihomo-full.yaml" ]]  && cp "${home}/client-config-mihomo-full.yaml"  "${subdir}/mihomo-full.yaml"
  [[ -f "${home}/client-config-mihomo-nodes.yaml" ]] && cp "${home}/client-config-mihomo-nodes.yaml" "${subdir}/mihomo-nodes.yaml"
  mihomo_tun_variants "${home}/client-config-mihomo-full.yaml" "${subdir}"

  xray_tun_variants "${home}/client-config.txt" "${subdir}"

  # 重新生成 Shadowrocket 专属与 v2rayN TUN 订阅
  {
    # v4.9.49：剔除 v2rayN 专用的 fm（finalmask JSON）参数，小火箭解析不了复杂 URI
    # 小火箭专属处理同 12-subscription.sh：去 fm、type=raw→tcp、去 spx
    grep -E 'Reality-Vision|Hysteria2-(Obfs|H3)-Direct' "${home}/client-config.txt" | sed -E 's/&fm=[^&#]*//; s/&type=raw(&|#)/\&type=tcp\1/; s/&spx=[^&#]*//' || true
    if [[ "${FEATURE_CDN_H2:-false}" == true && "${FEATURE_XHTTP_VLESSENC:-true}" != true ]]; then
      echo "vless://${UUID2}@${CDN_DOMAIN}:443?encryption=none&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h2&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH}&mode=stream-up#VLESS-XHTTP-CDN-H2"
    fi
  } > "${subdir}/shadowrocket-raw.txt"
  if [[ -s "${subdir}/shadowrocket-raw.txt" ]]; then
    base64 "${subdir}/shadowrocket-raw.txt" | tr -d '\n' > "${subdir}/shadowrocket.txt"
  fi
  cp "${home}/client-config.txt" "${subdir}/v2rayn-tun-raw.txt" || true   # v4.9.76 起 TUN 订阅含全部节点（原因见 12-subscription.sh）
  if [[ -s "${subdir}/v2rayn-tun-raw.txt" ]]; then
    base64 "${subdir}/v2rayn-tun-raw.txt" | tr -d '\n' > "${subdir}/v2rayn-tun.txt"
  fi

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
#   1. Vless-xhttp-tls-cdn —— 经 CDN。**不经过本机任何 QUIC 配置**：
#      Cloudflare 边缘用 HTTP/3 面对客户端，回源到本机仍是 TCP。
#      它不通 = 常规 XHTTP 链路的问题，与本机 UDP 无关。
#   2. Vless-xhttp-h3-direct / Hysteria2-obfs —— 由 **Xray 自己 bind UDP**，
#      既不经 nginx 也没有独立 hysteria 二进制。查的是 xray 进程的监听。
#   3. add-quic-h3 扩展的节点 —— 由 nginx listen quic 提供（下方单独检查）。
# 判据：1 通而 2 全不通 → 云厂商安全组没放行 UDP，或内核 <26.3.27。
# UDP 端口劫持自检。
# 背景：Hysteria2 端口跳跃靠 nat 表里的「端口段」规则（DNAT/REDIRECT）实现。
# 这类规则按端口范围匹配，会把落在范围内的**任何**本机 UDP 服务端口一并改写。
# 真实事故：同机另一套脚本的 Hysteria2 基础端口 44116 落在本项目建议的跳跃段
# 40000-50000 内，于是所有直连 44116 的包被 REDIRECT 到 8443（本项目的实例），
# 因两边 obfs 密码不同而被静默丢弃——现象是「节点链接里的基础端口连不上，
# 只有跳跃段能连」，且被劫持方服务端日志里**没有任何记录**，极难排查。
cmd_portconflict() {
  echo -e "${CYAN}[+] UDP 端口段劫持检测${NC}"
  command -v iptables >/dev/null 2>&1 || { info "未安装 iptables，跳过"; echo ""; return 0; }

  local ranges listen found=0
  ranges=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -E '\-\-dport [0-9]+:[0-9]+')
  [[ -z "$ranges" ]] && { info "未发现端口段规则，无劫持风险"; echo ""; return 0; }

  # 只统计「真实服务端口」，排除代理进程的临时出站 UDP socket（它们同样
  # 绑在通配地址上，直接取 ss 输出会大量误报）。判据：服务端口在 INPUT 链里
  # 有一条显式的单端口 ACCEPT 规则，临时出站 socket 没有。
  local svc_ports
  svc_ports=$(iptables -S INPUT 2>/dev/null \
              | grep -E '\-p udp .*--dport [0-9]+ -j ACCEPT' \
              | grep -oE '\-\-dport [0-9]+' | awk '{print $2}' | sort -un)
  listen=$(ss -uln 2>/dev/null | tail -n +2 | awk '{print $4}' \
           | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)
  # 取交集：既在监听、又被防火墙显式放行的端口
  # （用 grep -Fx 而非 comm：comm 要求字典序，这里两侧都是数值序）
  listen=$(echo "$listen" | grep -Fx -f <(echo "$svc_ports") 2>/dev/null)

  while read -r line; do
    local rng lo hi tgt
    rng=$(echo "$line" | grep -oE '\-\-dport [0-9]+:[0-9]+' | awk '{print $2}')
    tgt=$(echo "$line" | grep -oE '(to-destination :|--to-ports )[0-9]+' | grep -oE '[0-9]+$')
    lo=${rng%%:*}; hi=${rng##*:}
    for p in $listen; do
      # 已插入 RETURN 例外的端口视为已修复，不再报警
      if iptables -t nat -C PREROUTING -p udp --dport "$p" -j RETURN 2>/dev/null; then
        continue
      fi
      if [[ "$p" -ge "$lo" && "$p" -le "$hi" && "$p" != "$tgt" ]]; then
        echo -e "  ${RED}[!!]${NC}   UDP $p 落在端口段 ${lo}-${hi} 内（该段被导向 $tgt）"
        echo -e "         直连 $p 的流量会被改写投递到 $tgt，两端密钥不同则静默丢弃。"
        echo -e "         修复：${YELLOW}iptables -t nat -I PREROUTING 1 -p udp --dport $p -j RETURN${NC}"
        found=1
      fi
    done
  done <<< "$ranges"

  [[ "$found" -eq 0 ]] && echo -e "  ${GREEN}[OK]${NC}   无端口被跳跃段劫持"
  echo ""
}

cmd_diag() {
  cmd_conflict
  cmd_portconflict
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

  # 全部 CDN 流量经 Xray:443 fallback 落到 nginx:8003，再 grpc_pass 到 127.0.0.1:8001
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | grep -qE ':443\b'  && chk "已监听 TCP 443"  0 || chk "未监听 TCP 443"  1 "Xray 未启动？"
    ss -lntp 2>/dev/null | grep -qE ':8003\b' && chk "已监听 TCP 8003" 0 || chk "未监听 TCP 8003" 1 "nginx 未启动？"
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
  if command -v ss >/dev/null 2>&1; then
    if [[ "${FEATURE_H3_DIRECT:-false}" == true ]]; then
      if ss -lnup 2>/dev/null | grep -qE ":${H3_PORT:-443}\b"; then
        chk "h3-direct 已监听 UDP ${H3_PORT:-443}" 0
      else
        chk "h3-direct 未监听 UDP ${H3_PORT:-443}" 1 "config.json 里有该 inbound 但未 bind；查 ${MANAGE_CMD} log xray"
      fi
    fi
    # h2-direct 是 TCP，查 -lnt
    if [[ "${FEATURE_H2_DIRECT:-false}" == true ]]; then
      if ss -lnt 2>/dev/null | grep -qE ":${H2_PORT:-8445}\b"; then
        chk "h2-direct 已监听 TCP ${H2_PORT:-8445}" 0
      else
        chk "h2-direct 未监听 TCP ${H2_PORT:-8445}" 1 "config.json 里有该 inbound 但未 bind；查 ${MANAGE_CMD} log xray"
      fi
    fi
    if [[ "${FEATURE_HY2:-false}" == true && "${FEATURE_HY2_H3:-false}" == true ]]; then
      if ss -lnup 2>/dev/null | grep -qE ":${HY2_H3_PORT}\b"; then
        chk "Hysteria2-H3 已监听 UDP ${HY2_H3_PORT}" 0
      else
        chk "Hysteria2-H3 未监听 UDP ${HY2_H3_PORT}" 1 "查 ${MANAGE_CMD} log xray；确认 UDP ${HY2_H3_PORT} 未被其他进程占用"
      fi
    fi
    if [[ "${FEATURE_HY2:-false}" == true && "${FEATURE_HY2_OBFS:-false}" == true ]]; then
      if ss -lnup 2>/dev/null | grep -qE ":${HY2_PORT}\b"; then
        chk "Hysteria2 已监听 UDP ${HY2_PORT}" 0
      else
        chk "Hysteria2 未监听 UDP ${HY2_PORT}" 1 "查 ${MANAGE_CMD} log xray；确认内核 ≥26.3.27"
      fi
    fi
    if [[ "${FEATURE_MASQUE:-false}" == true ]]; then
      if ss -lnup 2>/dev/null | grep -qE ":${MASQUE_PORT:-8447}\b"; then
        chk "MASQUE 已监听 UDP ${MASQUE_PORT:-8447}" 0
      else
        chk "MASQUE 未监听 UDP ${MASQUE_PORT:-8447}" 1 "查 ${MANAGE_CMD} log xray"
      fi
    fi
    if [[ "${FEATURE_XDRIVE:-false}" == true ]]; then
      chk "XDRIVE 网盘代理 (Google Drive) 已激活" 0
    fi
  fi

  # 内核版本闸门：低于 26.3.27 时缺少原生 Hysteria 2 inbound。
  if [[ "${FEATURE_HY2:-false}" == true || "${FEATURE_H3_DIRECT:-false}" == true ]]; then
    XV=$([[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$XV" ]]; then
      if [[ "$(printf '%s\n26.3.27\n' "$XV" | sort -V | head -n1)" == "26.3.27" ]]; then
        chk "Xray ${XV} ≥ 26.3.27（Hysteria2、XHTTP 与 v26.9.30+ 特性可用）" 0
      else
        chk "Xray ${XV} < 26.3.27" 1 "当前内核版本低于 26.3.27，缺少 Hysteria 2 原生支持，执行 ${MANAGE_CMD} update"
      fi
    fi
  fi

  # 证书自动续期链路自检。
  #
  # 本项目的 xray 8446（h3-direct）、独立 hysteria 8443、nginx 8003 三者都直接读
  # /etc/ssl/private/ 下的证书副本，而不是 acme.sh 自己的目录。这份副本靠安装时
  # 配置的 `acme.sh --install-cert --key-file/--fullchain-file` 在每次续期后自动
  # 更新——那几个路径记在域名配置的 Le_RealKeyPath / Le_RealFullChainPath 里。
  #
  # 真实事故：同机另一套脚本执行 `--install-cert` 时只传了 --reloadcmd，acme.sh
  # 会连带重写整组部署配置、把这几个路径清空。之后续期照常成功、reloadcmd 照常
  # 重启服务，但服务重新加载的还是那份从未更新过的旧文件——直到旧证书到期当天，
  # h3-direct / hy2 / 全部 CDN 节点同时失效。续期成功、重启成功、日志无异常，
  # 问题要到一个月后才发作，因此必须靠自检提前拦下。
  if [[ -n "${REALITY_DOMAIN:-}" ]] && [[ -d "$HOME/.acme.sh" ]]; then
    local _ac=""
    for _d in "$HOME/.acme.sh/${REALITY_DOMAIN}_ecc" "$HOME/.acme.sh/${REALITY_DOMAIN}"; do
      [[ -f "$_d/${REALITY_DOMAIN}.conf" ]] && _ac="$_d/${REALITY_DOMAIN}.conf" && break
    done
    if [[ -n "$_ac" ]]; then
      local _fc _kf _rc
      _fc=$(. "$_ac" 2>/dev/null; printf '%s' "${Le_RealFullChainPath:-}")
      _kf=$(. "$_ac" 2>/dev/null; printf '%s' "${Le_RealKeyPath:-}")
      _rc=$(. "$_ac" 2>/dev/null; printf '%s' "${Le_ReloadCmd:-}")
      case "$_rc" in
        *__ACME_BASE64__START_*)
          _rc=$(printf '%s' "$_rc" | sed -e 's/^__ACME_BASE64__START_//' -e 's/__ACME_BASE64__END_$//' | base64 -d 2>/dev/null) ;;
      esac

      if [[ -z "$_fc" || -z "$_kf" ]]; then
        chk "acme 未配置证书落地路径（Le_RealFullChainPath/Le_RealKeyPath 为空）" 1 \
          "续期后 /etc/ssl/private/ 不会更新，旧证书到期时 h3-direct/hy2/CDN 节点会同时失效。修复: acme.sh --install-cert -d ${REALITY_DOMAIN} --ecc --key-file /etc/ssl/private/private.key --fullchain-file /etc/ssl/private/fullchain.cer --reloadcmd '<原有 reloadcmd>'"
      elif [[ "$_fc" != "/etc/ssl/private/fullchain.cer" ]]; then
        chk "acme 落地路径与本项目使用的不一致（$_fc）" 1 \
          "本项目各服务读的是 /etc/ssl/private/fullchain.cer"
      else
        chk "acme 证书落地路径已配置（$_fc）" 0
      fi

      # 已部署副本与 acme 源的指纹是否一致——不一致说明续期后没落地
      local _src="${_ac%/*}/fullchain.cer"
      if [[ -f "$_src" && -f /etc/ssl/private/fullchain.cer ]]; then
        local _f1 _f2
        _f1=$(openssl x509 -in "$_src" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
        _f2=$(openssl x509 -in /etc/ssl/private/fullchain.cer -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
        if [[ -n "$_f1" && "$_f1" == "$_f2" ]]; then
          chk "已部署证书与 acme 源一致" 0
        else
          chk "已部署证书与 acme 源不一致（续期后未落地）" 1 \
            "执行 acme.sh --install-cert 重新落地，或手工复制后重启 nginx/xray"
        fi
      fi

      # v4.9.45：续期方式与 CDN 代理状态是否冲突。
      # CDN 域名开了 Cloudflare 代理后，standalone（HTTP-01）续期会被 CF 301 到 https
      # 再回源 443（Reality / 伪装站），60 天后续期必败，而平时一切正常、日志无异常。
      local _wr; _wr=$(. "$_ac" 2>/dev/null; printf '%s' "${Le_Webroot:-}")
      case "$_wr" in
        dns_*) chk "acme 续期方式: DNS-01（${_wr}），与 CDN 代理状态无关" 0 ;;
        *)
          if cdn_behind_proxy; then
            chk "acme 续期方式为 standalone，但 ${CDN_DOMAIN} 已走 CDN 代理，自动续期会失败" 1 \
              "执行 CF_Token=<Cloudflare API Token> ${MANAGE_CMD} cert dnscf 切换为 DNS-01"
          else
            chk "acme 续期方式: standalone（${CDN_DOMAIN:-CDN 域名} 当前直连本机，可用）" 0
          fi
          ;;
      esac

      # reloadcmd 是否覆盖了所有读这份证书的服务
      if [[ -z "$_rc" ]]; then
        chk "acme reloadcmd 为空" 1 "续期后没有任何服务会重新加载新证书"
      else
        local _miss=""
        [[ "$_rc" == *nginx* ]] || _miss="$_miss nginx"
        [[ "$_rc" == *xray* ]]  || _miss="$_miss xray"
        # 仅当本机确实跑着独立 hysteria 时才要求它出现在 reloadcmd 里
        if systemctl is-active --quiet hysteria-server 2>/dev/null; then
          [[ "$_rc" == *hysteria-server* ]] || _miss="$_miss hysteria-server"
        fi
        if [[ -n "$_miss" ]]; then
          chk "acme reloadcmd 未覆盖:${_miss}" 1 \
            "这些服务读 /etc/ssl/private/ 的证书，续期后不重启会继续用旧证书"
        else
          chk "acme reloadcmd 覆盖了全部读证书的服务" 0
        fi
      fi
    fi
  fi

  # 独立 hysteria 二进制的处置判断。
  #
  # v4.0.0 起本项目的 Hysteria2 可由 Xray 原生 inbound（"protocol": "hysteria"）提供，
  # 此时独立二进制是冗余的、且可能与之抢同一个 UDP 端口。
  #
  # 但**不能一看到 /etc/hysteria/config.yaml 就报错并建议停用**：
  # 当 xray 配置里并没有原生 hy2 inbound 时（例如安装时未取得 acme 证书而自动
  # 跳过了该 inbound，或用户有意用官方二进制），这个独立进程就是该 Hysteria2
  # 节点的**唯一提供者**——按旧提示执行 `systemctl disable --now hysteria-server`
  # 会直接打掉一条正在用的节点。所以先看 xray 到底提不提供，再决定怎么报。
  if [[ -f /etc/hysteria/config.yaml ]]; then
    local hy_std_port hy_xray_port
    hy_std_port=$(grep -oE '^listen:[[:space:]]*:?[0-9]+' /etc/hysteria/config.yaml 2>/dev/null \
                  | grep -oE '[0-9]+$' | head -1)
    # 取 xray 原生 hysteria inbound 的端口：从含 "protocol": "hysteria" 的那段
    # 往回找最近的 "port"（inbound 里 port 在 protocol 之前）
    hy_xray_port=""
    if grep -q '"protocol"[[:space:]]*:[[:space:]]*"hysteria"' "$XRAY_CONF" 2>/dev/null; then
      hy_xray_port=$(grep -B5 '"protocol"[[:space:]]*:[[:space:]]*"hysteria"' "$XRAY_CONF" \
                     | grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' | tail -1 \
                     | grep -oE '[0-9]+$')
    fi

    if [[ -z "$hy_xray_port" ]]; then
      # xray 不提供原生 hy2 —— 独立二进制是该节点的唯一提供者，保留它是正确的
      chk "Hysteria2 由独立 hysteria 二进制提供（UDP ${hy_std_port:-?}）" 0 \
        "xray 配置中无原生 hysteria inbound，请勿停用 hysteria-server，否则该节点会立即失效"
    elif [[ -n "$hy_std_port" && "$hy_std_port" == "$hy_xray_port" ]]; then
      # 真冲突：两者抢同一个端口
      chk "独立 hysteria 与 Xray 原生 hy2 抢占同一端口 UDP ${hy_std_port}" 1 \
        "二选一；用 Xray 原生请执行: systemctl disable --now hysteria-server"
    else
      # 两者都在但端口不同：冗余而非故障
      chk "独立 hysteria（UDP ${hy_std_port:-?}）与 Xray 原生 hy2（UDP ${hy_xray_port}）并存" 0 \
        "端口不冲突；如无需两套，可停用其一"
    fi
  fi

  # 本机防火墙：只报告，不改动（规则可能是用户或云厂商 agent 写的）
  # 判据是「input 链是否默认拒绝」，不是「有没有 UDP 规则」：
  # 默认放行时没有 UDP 规则完全正常，旧写法在只装了 fail2ban / mangle 表
  # （policy accept）的机器上必然误报，把人往云安全组的方向带偏。
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q .; then
    if nft list ruleset 2>/dev/null | grep -qE 'hook input .*policy drop'; then
      nft list ruleset 2>/dev/null | grep -qiE 'udp.*(accept|dport)' \
        && chk "nftables input 默认拒绝，但有 UDP 放行规则" 0 \
        || chk "nftables input 链 policy drop 且未放行 UDP" 1 "直连 UDP 节点会被本机防火墙挡下"
    else
      chk "nftables input 链默认放行（不拦 UDP）" 0
    fi
  elif command -v iptables >/dev/null 2>&1; then
    if iptables -S 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)'; then
      iptables -S 2>/dev/null | grep -qi 'udp' \
        && chk "iptables INPUT 默认拒绝，但有 UDP 放行规则" 0 \
        || chk "iptables INPUT 链 policy DROP 且未放行 UDP" 1 "直连 UDP 节点会被本机防火墙挡下"
    else
      chk "iptables INPUT 链默认放行（不拦 UDP）" 0
    fi
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
  echo -e "${YELLOW}  节点 VLESS-XHTTP-CDN-H3（默认开启，xh cdnh3 off 可关闭）经 Cloudflare CDN 转发${NC}"
  echo "  走 QUIC/UDP 443，依赖：① Cloudflare 区域开启 HTTP/3  ② 客户端网络允许 UDP 443 出站。"
  echo "  若所处网络环境对 UDP 443 存在限速或丢包，可通过 FEATURE_CDN_H2=true 启用 TCP/h2 备用节点。"
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

# 出站分流开关：屏蔽回国 IP / 广告域名（默认关闭）。参考 zxcvos/Xray-script 的 cn-ip / ad-domain 规则。
#   cn  → freedom 出站的 finalRules（域名解析成 IP 之后再判），geoip:cn 直接 block
#   ads → routing 规则 domain geosite:category-ads-all → block
# 每条规则占单独一行并带 xh-block-* 标记，开关只增删该行；先 xray -test 校验，失败自动回滚。
cmd_block() {
  local what="${1:-show}" act="${2:-}" key marker
  case "$what" in
    show|status)
      echo ""
      echo -e "${CYAN}=== 出站分流开关 ===${NC}"
      local k name
      for k in cn ads; do
        [[ "$k" == cn ]] && name="屏蔽回国 IP (geoip:cn)" || name="屏蔽广告域名 (geosite:category-ads-all)"
        if grep -q "xh-block-${k}" "$XRAY_CONF" 2>/dev/null; then
          echo -e "  ${name}：${GREEN}已开启${NC}"
        else
          echo -e "  ${name}：${YELLOW}未开启${NC}"
        fi
      done
      echo ""
      echo "用法：${MANAGE_CMD} block cn|ads on|off"
      echo "说明：回国 IP 屏蔽会让依赖本代理访问国内站点的客户端断流，仅在落地机不需要回国流量时开启。"
      echo ""
      return 0
      ;;
    cn)  key="FEATURE_BLOCK_CN";  marker="xh-block-cn" ;;
    ads) key="FEATURE_BLOCK_ADS"; marker="xh-block-ads" ;;
    *)   echo "用法: ${MANAGE_CMD} block [show|cn on|off|ads on|off]"; return 1 ;;
  esac
  [[ "$act" == on || "$act" == off ]] || { echo "用法: ${MANAGE_CMD} block ${what} on|off"; return 1; }
  [[ -f "$XRAY_CONF" ]] || fail "未找到 Xray 配置文件: $XRAY_CONF"
  local tmp="${XRAY_CONF%.json}.block-tmp.json" bak="${XRAY_CONF}.block.bak"   # 临时文件必须以 .json 结尾，Xray 靠扩展名识别格式
  python3 - "$XRAY_CONF" "$tmp" "$what" "$act" <<'BLOCKPY' || fail "改写配置失败，未做任何修改"
import re, sys
src, dst, what, act = sys.argv[1:5]
s = open(src, encoding='utf-8').read()
marker = 'xh-block-' + what
lines = [l for l in s.split('\n') if marker not in l]          # 先清掉旧行，开 / 关都幂等
s = '\n'.join(lines)
if act == 'on':
    if what == 'ads':
        pat = re.compile(r'("geosite:category-pt"\s*\]\s*,\s*"outboundTag"\s*:\s*"block"\s*\})')
        new = '\n            , { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" } // xh-block-ads'
    else:
        pat = re.compile(r'(\{ "action": "block", "ip": \["geoip:private"\] \})')
        new = '\n                    , { "action": "block", "ip": ["geoip:cn"] } // xh-block-cn'
    s, n = pat.subn(lambda m: m.group(1) + new, s, count=1)
    if n != 1:
        sys.stderr.write('没找到插入锚点（配置不是由本脚本生成？）\n'); sys.exit(1)
open(dst, 'w', encoding='utf-8').write(s)
BLOCKPY
  if ! "$XRAY_BIN" -test -format json -config "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; fail "Xray 配置校验失败（geodata 缺少对应规则？），已放弃，未做任何修改"
  fi
  cp -a "$XRAY_CONF" "$bak"
  mv -f "$tmp" "$XRAY_CONF"; chmod 600 "$XRAY_CONF" 2>/dev/null || true
  if svc restart xray; then
    update_node_env "$key" "$([[ "$act" == on ]] && echo true || echo false)"
    info "出站分流 ${what} 已$([[ "$act" == on ]] && echo 开启 || echo 关闭)，xray 已重启"
  else
    cp -a "$bak" "$XRAY_CONF"; svc restart xray >/dev/null 2>&1 || true
    fail "xray 重启失败，已回滚到修改前的配置"
  fi
}

# Reality maxTimeDiff（毫秒）：服务端只接受客户端时间戳与本机相差不超过该值的握手，防重放。
# 参考 XTLS/REALITY README 的可选项。客户端（手机 / 电脑）系统时间偏差超过该值就连不上，需开启自动校时。
cmd_timediff() {
  local action="${1:-show}" ms="${2:-60000}"
  case "$action" in
    show|status)
      local cur
      cur=$(grep -o '"maxTimeDiff"[[:space:]]*:[[:space:]]*[0-9]*' "$XRAY_CONF" 2>/dev/null | head -1 | grep -o '[0-9]*$' || true)
      echo ""
      echo -e "${CYAN}=== Reality maxTimeDiff 状态 ===${NC}"
      if [[ -n "$cur" ]]; then
        echo -e "  当前状态:       ${GREEN}${cur} ms${NC}"
      else
        echo -e "  当前状态:       ${YELLOW}未设置${NC}（不校验客户端时间差）"
      fi
      echo -e "  本机时间同步:   $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 未知)（yes 表示已校时）"
      echo ""
      echo -e "  ${MANAGE_CMD} timediff on [毫秒]   # 开启，默认 60000；客户端时间偏差超过它会连不上"
      echo -e "  ${MANAGE_CMD} timediff off         # 关闭"
      echo ""
      return 0
      ;;
    on|set|off) : ;;
    *) echo "用法: ${MANAGE_CMD} timediff [show|on [毫秒]|off]"; return 1 ;;
  esac
  [[ -f "$XRAY_CONF" ]] || fail "未找到 Xray 配置文件: $XRAY_CONF"
  if [[ "$action" != off ]]; then
    [[ "$ms" =~ ^[0-9]+$ && "$ms" -ge 1000 ]] || fail "毫秒数必须是 >= 1000 的整数（建议 60000）"
  fi
  local bak="${XRAY_CONF}.bak-timediff"
  cp -a "$XRAY_CONF" "$bak"
  python3 - "$XRAY_CONF" "$action" "$ms" <<'TDPY' || { mv -f "$bak" "$XRAY_CONF"; fail "改写配置失败，已恢复原配置"; }
import re, sys
cfg, action, ms = sys.argv[1:4]
t = open(cfg, encoding='utf-8').read()
t = re.sub(r',\s*"maxTimeDiff"\s*:\s*\d+', '', t)              # 先清掉旧值，开 / 关都幂等
if action != 'off':
    m = re.search(r'("shortIds"\s*:\s*\[[^\]]*\])', t)
    if not m: sys.exit(1)
    t = t[:m.end()] + ',\n                    "maxTimeDiff": ' + ms + t[m.end():]
open(cfg, 'w', encoding='utf-8').write(t)
TDPY
  if "$XRAY_BIN" run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
    rm -f "$bak"
    if svc restart xray; then
      update_node_env "REALITY_MAX_TIME_DIFF" "$([[ "$action" == off ]] && echo "" || echo "$ms")"
      info "Reality maxTimeDiff 已$([[ "$action" == off ]] && echo 关闭 || echo "设为 ${ms} ms")，xray 已重启"
    else
      warn "xray 重启失败，正在回滚..."; cp -a "$XRAY_CONF" "${XRAY_CONF}.failed"; fail "重启失败；坏配置留在 ${XRAY_CONF}.failed，请手动检查"
    fi
  else
    warn "Xray 配置文件测试失败，正在回滚..."
    mv -f "$bak" "$XRAY_CONF"
    fail "配置测试失败，已自动恢复原配置"
  fi
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
# 用法: xh update [<版本号>] [--auto]
cmd_update() {
  local auto=0 target_ver=""
  for arg in "$@"; do
    case "$arg" in
      --auto) auto=1 ;;
      *) [[ -z "$target_ver" ]] && target_ver="$arg" ;;
    esac
  done

  [[ -x "$XRAY_BIN" ]] || fail "未找到 ${XRAY_BIN}"
  local current latest backup
  current=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
  current="${current#v}"

  if [[ -n "$target_ver" ]]; then
    latest="${target_ver#v}"
  else
    # 优先检测最新版本号（含 v26.9.30 等前沿增强版本）
    latest=$(curl -fsSL --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases" 2>/dev/null \
      | grep -m1 '"tag_name"' | cut -d'"' -f4)
    latest="${latest#v}"
    [[ -z "$latest" ]] && latest="${XRAY_DEFAULT_VERSION:-26.9.30}"
  fi

  if [[ -z "$latest" ]]; then
    warn "无法获取 Xray-core 目标版本号，跳过本次更新"
    return 0
  fi

  # 拦截与检查测试版本 (pre-release)
  local is_prerelease
  is_prerelease=$(curl -fsSL --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${latest}" 2>/dev/null | grep -m1 '"prerelease"' | grep -oE 'true|false')
  local ver_type="正式版"
  [[ "$is_prerelease" == "true" ]] && ver_type="增强测试版 / Pre-release"

  info "当前版本: ${current:-未知}  目标版本: ${latest} (${ver_type})"
  if [[ "$current" == "$latest" ]]; then
    info "已是目标版本 (${latest})，无需更新"
    return 0
  fi

  if [[ "$is_prerelease" == "true" ]]; then
    if [[ "$latest" == "${XRAY_DEFAULT_VERSION:-26.9.30}" || "$latest" == "26.9.30" ]]; then
      info "目标版本 v${latest} 为项目推荐的增强版本（支持 XDRIVE 云盘代理、MASQUE 等新特性）"
    else
      echo ""
      warn "============================================================"
      warn "⚠️ 目标版本 v${latest} 被标记为 Pre-release / 测试版本！"
      warn "测试版本可能引入实验性更改，请评估客户端兼容性。"
      warn "============================================================"
      echo ""
      if [[ $auto -eq 1 ]]; then
        warn "自动更新模式已拦截非项目推荐的未知测试版本安装。"
        return 0
      else
        read -rp "确定仍要安装此测试版本吗? [y/N]: " force_reply
        [[ "${force_reply,,}" == "y" ]] || { info "已取消安装测试版本"; return 0; }
      fi
    fi
  fi

  if [[ $auto -eq 0 ]]; then
    read -rp "确认安装/更新到 ${latest}? [y/N]: " reply
    [[ "${reply,,}" == "y" ]] || { info "已取消"; return 0; }
  fi

  backup="${XRAY_BIN}.bak-${current:-old}"
  cp -f "$XRAY_BIN" "$backup" || fail "备份 Xray 二进制失败，已中止更新"
  info "已备份旧版本 → ${backup}"

  local ok=0
  if [[ "${OS_ID:-}" != "alpine" ]]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "v${latest}" -u root && ok=1
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
      local _mem _buf_mb _cap_mb
      _mem=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
      if   [[ "$_mem" -ge 16384 ]]; then _buf_mb=128; _cap_mb=128;
      elif [[ "$_mem" -ge 4096  ]]; then _buf_mb=64; _cap_mb=64;
      elif [[ "$_mem" -ge 1536  ]]; then _buf_mb=32; _cap_mb=32;
      else _buf_mb=16; _cap_mb=16; fi

      echo -e "${CYAN}[+] 流控状态摘要${NC}"
      echo -e "  推荐缓冲区：             ${GREEN}${_buf_mb}MB${NC}"
      echo -e "  内存保护上限：           ${GREEN}${_cap_mb}MB${NC}"
      echo -e "  队列算法：               ${GREEN}$(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)${NC}"
      echo -e "  拥塞控制：               ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)${NC}"
      printf '  %-32s %s\n' "  └─ BBR 版本" "$(detect_bbr_version)"
      echo -e "  tcp_wmem:                 ${GREEN}$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo n/a)${NC}"
      echo -e "  tcp_rmem:                 ${GREEN}$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo n/a)${NC}"
      echo -e "  tcp_limit_output_bytes:   ${GREEN}$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo n/a)${NC}"
      echo -e "  tcp_slow_start_after_idle: ${GREEN}$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo n/a)${NC}"
      echo ""

      if [[ -f "$SYSCTL_CONF" ]]; then
        echo -e "${CYAN}[+] ${SYSCTL_CONF}${NC}"
        cat "$SYSCTL_CONF"
      elif [[ -f /etc/sysctl.d/99-sbbox.conf ]]; then
        echo -e "${CYAN}[+] /etc/sysctl.d/99-sbbox.conf（已由 sbbox 启用生效）${NC}"
        cat /etc/sysctl.d/99-sbbox.conf
      else
        info "系统层调优未开启。安装时默认自动执行（跳过用 FEATURE_AUTO_TUNING=false），也可手动 ${MANAGE_CMD} tuning on"
      fi
      [[ -f "$LIMITS_CONF" ]] && { echo ""; echo -e "${CYAN}[+] ${LIMITS_CONF}${NC}"; cat "$LIMITS_CONF"; }
      return 0
      ;;
    on)
      [[ -f "$SYSCTL_CONF" ]] && { info "系统层调优已处于开启状态（重跑请先 ${MANAGE_CMD} tuning off）"; return 0; }
      # v2.0.0：调优逻辑内联在本命令里，不再需要重跑安装脚本。
      # 全部 best-effort，逐项能力探测（BBR / 只读 sysctl / limits.d 是否存在），
      # 任何一项失败只 warn，不影响已经跑通的节点。
      apply_system_tuning
      ;;
    off)
      rm -f "$SYSCTL_CONF" "$LIMITS_CONF" /etc/modules-load.d/xray-xhttp-conntrack.conf
      # v4.9.44：网卡运行时参数的开机重设（xray-xhttp-nic.service）一并移除；
      # 当前的 fq / initcwnd 保持到下次重启，与 sysctl 的回滚方式一致。
      remove_nic_tune
      # v4.7.3：只删本项目自己的 drop-in。用户手工加固的 override.conf 一律不动
      # ——除非它的内容与旧版生成物逐字一致（说明是本项目留下的，用户没改过）。
      # 旧实现无条件 rm override.conf，会连用户的 Restart=always / OOMScoreAdjust
      # 一起删掉，且不留任何提示。
      local d kept_user=0
      for d in /etc/systemd/system/xray.service.d /etc/systemd/system/nginx.service.d /etc/systemd/system/hysteria-server.service.d /etc/systemd/system/sing-box.service.d; do
        rm -f "${d}/10-xray-xhttp.conf"
        if [[ -f "${d}/override.conf" ]]; then
          if [[ "$(grep -vE '^\s*(#|$)' "${d}/override.conf" | tr -d '[:space:]')" \
                == "[Service]LimitNOFILE=1048576LimitNPROC=infinity" ]]; then
            rm -f "${d}/override.conf"
          else
            kept_user=1
          fi
        fi
        rmdir "$d" 2>/dev/null || true
      done
      [[ "$kept_user" -eq 1 ]] && \
        warn "你自己修改过的 override.conf 已保留（本命令只移除本项目写入的 10-xray-xhttp.conf）"
      # 与 fs.nr_open 对齐用的 DefaultLimitNOFILE drop-in 也一并移除（见
      # align_default_nofile）。删掉后 systemd 回到 /etc/systemd/system.conf 的值。
      if [[ -f /etc/systemd/system.conf.d/10-xray-xhttp-nofile.conf ]]; then
        rm -f /etc/systemd/system.conf.d/10-xray-xhttp-nofile.conf
        rmdir /etc/systemd/system.conf.d 2>/dev/null || true
        systemctl daemon-reexec >/dev/null 2>&1 || true
      fi
      [[ "$SERVICE_TYPE" == "systemd" ]] && systemctl daemon-reload >/dev/null 2>&1
      sysctl --system >/dev/null 2>&1 || true
      info "已移除本项目写入的全部调优配置"
      warn "已生效的运行时内核参数需重启系统才能完全恢复默认值"
      ;;
    client)
      show_client_tuning "${2:-all}"
      ;;
    win|windows|mac|macos|linux|sb|singbox)
      show_client_tuning "$1"
      ;;
    *) fail "用法: ${MANAGE_CMD} tuning [show|on|off|client|win|mac|linux|sb]" ;;
  esac
}

@@include src/06-tuning-lib.sh

cmd_brutal() {
  local action="${1:-show}"
  shift || true
  case "$action" in
    show|status|list|ls)
      echo ""
      local max_spd default_spd
      max_spd=$(get_machine_max_speed_mbps)
      default_spd=$(get_default_brutal_speed_mbps)
      echo -e "${CYAN}=== TCP Brutal 状态 ===${NC}"
      if lsmod | grep -qw brutal; then
        echo -e "  内核模块:       ${GREEN}已加载 (v$(cat /sys/module/brutal/version 2>/dev/null || echo '2.x'))${NC}"
      else
        echo -e "  内核模块:       ${RED}未加载${NC}"
      fi
      local cc_xray
      cc_xray=$(grep -o '"tcpcongestion"[[:space:]]*:[[:space:]]*"[^"]*"' /usr/local/etc/xray/config.json 2>/dev/null | head -1 | cut -d'"' -f4 || echo "未知")
      echo -e "  Xray 入站 CC:   ${YELLOW}${cc_xray}${NC}"
      echo -e "  本机最大带宽:   ${GREEN}${max_spd} Mbps${NC}"
      echo -e "  默认下发速率:   ${GREEN}${default_spd} Mbps (本机最大带宽 95%)${NC}"
      echo ""
      echo -e "${CYAN}=== 当前 Brutal 规则与实时连接 ===${NC}"
      if command -v brutalctl >/dev/null 2>&1; then
        brutalctl list
      else
        echo "  未安装 brutalctl"
      fi
      echo ""

      # 路由级 congctl lock 会按**目的地**强制 CC，优先级压过入站的 sockopt 分工，
      # 把本该走 BBR 的入站（乃至 SSH）一并拽进 brutal 定速。单独列出来提醒。
      local _rlocks
      _rlocks=$(ip route show 2>/dev/null | grep -E 'congctl[[:space:]]+lock')
      if [[ -n "$_rlocks" ]]; then
        echo -e "${YELLOW}=== 路由级 congctl lock（按目的地强制 CC，会覆盖入站分工）===${NC}"
        echo "$_rlocks" | sed 's/^/  /'
        echo -e "  ${YELLOW}提示：该锁对目的地的所有 TCP 连接生效，不区分是否代理流量；${NC}"
        echo -e "  ${YELLOW}      如需恢复「Xray 走 brutal / 其余走 BBR」的分工，用 brutalctl del <prefix> 移除。${NC}"
        echo ""
      fi

      # 实测口径的效果对比：Brutal 是定速算法，速率超过链路真实容量时不会退让，
      # 表现为重传率飙升。这里按 CC 汇总在线连接的发送量与重传量——
      # brutal 重传率显著高于 bbr 即说明速率超配，应下调而不是继续加码。
      echo -e "${CYAN}=== 在线连接实际 CC 分布与重传率 ===${NC}"
      local _cc_stat
      _cc_stat=$(ss -tin state established 2>/dev/null | awk '
        /^[[:space:]]/ {
          cc=""
          for (i=1; i<=NF; i++)
            if ($i=="bbr" || $i=="brutal" || $i=="cubic" || $i=="reno") { cc=$i; break }
          if (cc=="") next
          s=0; r=0
          for (i=1; i<=NF; i++) {
            if ($i ~ /^bytes_sent:/)    { t=$i; sub(/^bytes_sent:/,"",t);    s=t+0 }
            if ($i ~ /^bytes_retrans:/) { t=$i; sub(/^bytes_retrans:/,"",t); r=t+0 }
          }
          n[cc]++; sent[cc]+=s; ret[cc]+=r
        }
        END {
          for (c in n) {
            p = sent[c]>0 ? ret[c]*100.0/sent[c] : 0
            printf "  %-7s 连接 %-4d 发送 %8.1f MB  重传 %7.1f MB (%.1f%%)\n", c, n[c], sent[c]/1048576, ret[c]/1048576, p
          }
        }')
      if [[ -n "$_cc_stat" ]]; then
        echo "$_cc_stat"
        echo -e "  ${YELLOW}注：CC 在连接建立时确定，改了规则后需客户端重连才会切换。${NC}"
      else
        echo "  (当前无已建立的 TCP 连接)"
      fi
      echo ""
      ;;
    on)
      set_tcp_brutal_xray on "${1:-auto}"
      ;;
    off)
      set_tcp_brutal_xray off
      ;;
    speed)
      set_tcp_brutal_speed "${1:-auto}"
      ;;
    add)
      add_tcp_brutal_rule "$@"
      ;;
    del|rm)
      del_tcp_brutal_rule "$@"
      ;;
    update|up)
      update_tcp_brutal
      [[ " $* " == *" --now "* ]] && reload_tcp_brutal
      ;;
    reload)
      reload_tcp_brutal
      ;;
    *)
      echo "用法: ${MANAGE_CMD} brutal [show|on|off|speed|add|del|update|reload]"
      echo "  ${MANAGE_CMD} brutal show          查看 TCP Brutal 状态与活跃连接"
      echo "  ${MANAGE_CMD} brutal on [mbps]     开启 Xray TCP Brutal（默认设为本机最大速率的 95%）"
      echo "  ${MANAGE_CMD} brutal off           关闭 Xray TCP Brutal（回落至 BBR）"
      echo "  ${MANAGE_CMD} brutal speed [mbps]  修改全局默认下发速率（不填则自动设为本机 95% 速率）"
      echo "  ${MANAGE_CMD} brutal add <IP> [M]  为指定客户端 IP 设定独立下发速率"
      echo "  ${MANAGE_CMD} brutal del <IP>      删除指定客户端 IP 规则"
      echo "  ${MANAGE_CMD} brutal update [--now] 更新内核模块到上游最新版（校验 sha256；默认下次开机生效，--now 立即重载）"
      echo "  ${MANAGE_CMD} brutal reload        立即重载为已编译的新版模块（Xray 停止数秒）"
      ;;
  esac
}

# 健康检查：服务掉线则拉起（由 cron 每 5 分钟调用）
cmd_guard() {
  local restarted=0
  for s in xray nginx; do
    if ! svc_active "$s"; then
      svc restart "$s" >/dev/null 2>&1 && restarted=1
      logger -t xray-xhttp "guard: restarted ${s}" 2>/dev/null || true
    fi
  done
  if systemctl is-enabled --quiet hysteria-server 2>/dev/null && [[ -f /etc/hysteria/config.yaml ]] && ! svc_active hysteria-server; then
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
      info "自动更新已开启（每周日 04:00：Xray-core 自动更新、失败回滚；nginx / tcp-brutal 只检查并提醒；日志 journalctl -t xh-autoupdate）"
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

cmd_minversion() {
  local action="${1:-show}"
  local target_ver="${2:-1.8.0}"
  case "$action" in
    show|status)
      local cur_minver
      cur_minver=$(grep -o '"minClientVer"[[:space:]]*:[[:space:]]*"[^"]*"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "")
      echo ""
      echo -e "${CYAN}=== Reality minClientVer (minversion) 状态 ===${NC}"
      if [[ -n "$cur_minver" ]]; then
        echo -e "  当前状态:       ${GREEN}${cur_minver}${NC} (兼容模式：允许 mihomo / Clash / sing-box 客户端握手)"
      else
        echo -e "  当前状态:       ${YELLOW}未设置${NC} (严格模式：使用 Xray-core 内核默认版本)"
      fi
      local env_ver="${REALITY_MIN_CLIENT_VER:-}"
      [[ -n "$env_ver" ]] && echo -e "  node.env 设定:  ${env_ver}"
      local cur_core_ver
      cur_core_ver=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
      cur_core_ver="${cur_core_ver#v}"
      [[ -n "$cur_core_ver" ]] && echo -e "  Xray 内核版本:  ${cur_core_ver}"
      if [[ -n "$cur_core_ver" ]] && ver_ge "$cur_core_ver" "26.9.8"; then
        echo ""
        echo -e "  ${YELLOW}ℹ️ 提示：当前 Xray 内核为 v${cur_core_ver} (>= 26.9.8)${NC}"
        echo -e "  该版本在 REALITY 中启用了后量子混合密钥 (X25519MLKEM768) 握手强校验防 GFW 探测。"
        echo -e "  客户端若使用 REALITY 需支持后量子混合算法；或使用订阅中的 XHTTP / H3 / H2 / Hysteria2 节点。"
      fi
      echo ""
      echo -e "说明："
      echo -e "  • 开启兼容（1.8.0）：支持 mihomo、Clash Meta、sing-box 等非 Xray 官方客户端正常握手。"
      echo -e "  • 关闭兼容（off / default）：恢复内核最新默认限制，非同代 Xray 客户端将握手失败。"
      echo -e "  • 快捷命令:"
      echo -e "      ${MANAGE_CMD} minversion on [版本号]     # 开启兼容模式（默认 1.8.0）"
      echo -e "      ${MANAGE_CMD} minversion off            # 切换为严格模式（内核默认）"
      echo -e "      ${MANAGE_CMD} minversion set <版本号>   # 指定具体最低版本"
      echo ""
      ;;
    on|set)
      local ver="$target_ver"
      [[ -z "$ver" || "$ver" == "on" ]] && ver="1.8.0"
      [[ -f "$XRAY_CONF" ]] || fail "未找到 Xray 配置文件: $XRAY_CONF"

      local bak="${XRAY_CONF}.bak-minver"
      cp -a "$XRAY_CONF" "$bak"

      python3 -c "
import re, sys

cfg = '$XRAY_CONF'
ver = '$ver'
with open(cfg, 'r', encoding='utf-8') as f:
    text = f.read()

if re.search(r'\"minClientVer\"\s*:', text):
    text = re.sub(r'(\"minClientVer\"\s*:\s*)\"[^\"]*\"', lambda m: f'{m.group(1)}\"{ver}\"', text, count=1)
else:
    m = re.search(r'(\"shortIds\"\s*:\s*\[[^\]]*\])', text)
    if m:
        text = text[:m.end()] + f',\n                    \"minClientVer\": \"{ver}\"' + text[m.end():]
    else:
        sys.exit(1)

with open(cfg, 'w', encoding='utf-8') as f:
    f.write(text)
" 2>/dev/null || {
        if grep -q '"minClientVer"' "$XRAY_CONF"; then
          sed -i -E "s/\"minClientVer\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"minClientVer\": \"${ver}\"/" "$XRAY_CONF"
        fi
      }

      if "$XRAY_BIN" run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
        rm -f "$bak"
        svc restart xray
        update_node_env "REALITY_MIN_CLIENT_VER" "$ver"
        info "已成功开启 Reality 兼容模式，minClientVer 设为: ${ver}，并重启 xray 服务"
      else
        warn "Xray 配置文件测试失败，正在回滚..."
        mv -f "$bak" "$XRAY_CONF"
        fail "配置测试失败，已自动恢复原配置"
      fi
      ;;
    off|default|none)
      [[ -f "$XRAY_CONF" ]] || fail "未找到 Xray 配置文件: $XRAY_CONF"

      local bak="${XRAY_CONF}.bak-minver"
      cp -a "$XRAY_CONF" "$bak"

      python3 -c "
import re, sys

cfg = '$XRAY_CONF'
with open(cfg, 'r', encoding='utf-8') as f:
    text = f.read()

text = re.sub(r',\s*(//[^\n]*\n\s*)?\"minClientVer\"\s*:\s*\"[^\"]*\"', '', text, count=1)
text = re.sub(r'\"minClientVer\"\s*:\s*\"[^\"]*\"\s*,?', '', text, count=1)

with open(cfg, 'w', encoding='utf-8') as f:
    f.write(text)
" 2>/dev/null || true

      if "$XRAY_BIN" run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
        rm -f "$bak"
        svc restart xray
        update_node_env "REALITY_MIN_CLIENT_VER" "default"
        info "已关闭 minClientVer，已恢复为 Xray-core 内核默认版本（严格模式），并重启 xray 服务"
      else
        warn "Xray 配置文件测试失败，正在回滚..."
        mv -f "$bak" "$XRAY_CONF"
        fail "配置测试失败，已自动恢复原配置"
      fi
      ;;
    *)
      if [[ "$action" =~ ^[0-9]+ ]]; then
        cmd_minversion set "$action"
      else
        echo "用法: ${MANAGE_CMD} minversion [show|on|off|set <ver>|<ver>]"
        echo "  ${MANAGE_CMD} minversion show        查看当前 minClientVer 配置状态"
        echo "  ${MANAGE_CMD} minversion on          开启兼容模式（设为 1.8.0，支持 mihomo/Clash）"
        echo "  ${MANAGE_CMD} minversion off         恢复内核默认（严格模式）"
        echo "  ${MANAGE_CMD} minversion 1.8.0       设为指定版本"
      fi
      ;;
  esac
}

sync_client_configs_ech() {
  local enable="$1"
  local query="${2:-cloudflare-ech.com+https://223.5.5.5/dns-query}"
  python3 -c "
import os, sys, re, urllib.parse, json, yaml

enable = ('$enable' == 'true')
query = '$query'
ech_query_enc = urllib.parse.quote(query, safe='')
user_homes = ['${USER_HOME:-/home/ubuntu}', '/home/ubuntu', '/home/opc', '/root']
seen = set()

for home in user_homes:
    if not home or home in seen or not os.path.isdir(home):
        continue
    seen.add(home)
    txt_file = os.path.join(home, 'client-config.txt')
    nodes_file = os.path.join(home, 'client-config-mihomo-nodes.yaml')
    full_file = os.path.join(home, 'client-config-mihomo-full.yaml')

    if os.path.isfile(txt_file):
        with open(txt_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        new_lines = []
        for line in lines:
            line_str = re.sub(r'\s*([&?])\s*', r'\1', line.strip())
            if not line_str:
                continue
            # v4.9.29：按节点名（URI fragment）不区分大小写匹配。v4.9.21 改名后节点名是
            # VLESS-Reality-Up-CDN-Down，原先按小写 'reality-up-cdn-down' 匹配不上，
            # 分离节点被当成普通 CDN 节点在顶层加了 &ech=（那是 Reality 腿，不该有）。
            node_name = urllib.parse.unquote(line_str.rsplit('#', 1)[-1]).lower()
            is_split = 'reality-up-cdn-down' in node_name
            if not is_split and ('-cdn-' in node_name or 'cdn-up' in node_name):
                if enable:
                    if '&ech=' in line_str:
                        line_str = re.sub(r'&ech=[^&#]*', f'&ech={ech_query_enc}', line_str)
                    else:
                        line_str = re.sub(r'(&security=tls)', f'\\g<1>&ech={ech_query_enc}', line_str)
                else:
                    line_str = re.sub(r'&ech=[^&#]*', '', line_str)
            elif is_split:
                m = re.search(r'&extra=([^#]+)', line_str)
                if m:
                    try:
                        extra_json = json.loads(urllib.parse.unquote(m.group(1)))
                        ds_tls = extra_json.get('downloadSettings', {}).get('tlsSettings', {})
                        if enable:
                            # 放进 JSON 的必须是原文：整个 extra 随后会整体 quote 一次，
                            # 塞已编码的串会变成双重编码（%252B），客户端解不出 DoH 地址。
                            ds_tls['ech'] = urllib.parse.unquote(ech_query_enc)
                        else:
                            ds_tls.pop('ech', None)
                        new_extra_enc = urllib.parse.quote(json.dumps(extra_json, separators=(',', ':')), safe='')
                        line_str = line_str[:m.start()] + f'&extra={new_extra_enc}' + line_str[m.end():]
                    except Exception:
                        pass
            line_str = re.sub(r'\s+&', '&', line_str)
            line_str = re.sub(r'&\s+', '&', line_str)
            new_lines.append(line_str.strip() + '\n')
        with open(txt_file, 'w', encoding='utf-8') as f:
            f.writelines(new_lines)

    for yfile in [nodes_file, full_file]:
        if os.path.isfile(yfile):
            with open(yfile, 'r', encoding='utf-8') as f:
                cfg = yaml.safe_load(f)
            if not isinstance(cfg, dict):
                continue
            for p in cfg.get('proxies', []):
                name = p.get('name', '')
                lname = name.lower()
                if ('-cdn-' in lname or 'cdn-up' in lname) and 'reality-up-cdn-down' not in lname:
                    if enable:
                        p['ech-opts'] = {'enable': True, 'query-server-name': 'cloudflare-ech.com'}
                    else:
                        p.pop('ech-opts', None)
                elif 'reality-up-cdn-down' in lname:
                    xopts = p.get('xhttp-opts', {})
                    ds = xopts.get('download-settings', {})
                    if enable:
                        ds['ech-opts'] = {'enable': True, 'query-server-name': 'cloudflare-ech.com'}
                    else:
                        ds.pop('ech-opts', None)
            with open(yfile, 'w', encoding='utf-8') as f:
                yaml.dump(cfg, f, allow_unicode=True, sort_keys=False)
" 2>/dev/null || true
  cmd_resub
}

sync_client_configs_cdnh2() {
  local enable="$1"
  # 优先从备用节点库取节点行与 Mihomo 条目（和全新安装逐字一致）。没有库的旧安装才走下面的克隆兜底。
  if [[ -f "${ALL_STORE_DIR}/client-config.txt" ]]; then
    local _act=off; [[ "$enable" == true ]] && _act=on
    backup_node_sync_files "VLESS-XHTTP-CDN-H2" "$_act" || warn "VLESS-XHTTP-CDN-H2 的客户端文件同步未完成（原因见上）"
    cmd_resub
    return 0
  fi
  python3 -c "
import os, sys, re, yaml, copy

enable = ('$enable' == 'true')
user_homes = ['${USER_HOME:-/home/ubuntu}', '/home/ubuntu', '/home/opc', '/root']
seen = set()

for home in user_homes:
    if not home or home in seen or not os.path.isdir(home):
        continue
    seen.add(home)
    txt_file = os.path.join(home, 'client-config.txt')
    nodes_file = os.path.join(home, 'client-config-mihomo-nodes.yaml')
    full_file = os.path.join(home, 'client-config-mihomo-full.yaml')

    if os.path.isfile(txt_file):
        with open(txt_file, 'r', encoding='utf-8') as f:
            lines = [l.strip() for l in f if l.strip()]
        new_lines = []
        has_h2 = any('#VLESS-XHTTP-CDN-H2' in l for l in lines)
        if enable:
            if not has_h2:
                added = False
                for line in lines:
                    if '#VLESS-XHTTP-CDN-H3' in line:
                        h2_line = line.replace('alpn=h3', 'alpn=h2').replace('#VLESS-XHTTP-CDN-H3', '#VLESS-XHTTP-CDN-H2')
                        new_lines.append(h2_line)
                        added = True
                    elif not added and ('#VLESS-XHTTP-Direct-H3' in line or '#VLESS-Reality' in line):
                        # 兜底：从直连节点提取参数构造
                        h2_line = line.replace('alpn=h3', 'alpn=h2')
                        h2_line = re.sub(r'@[^:]+:[0-9]+', '@${CDN_DOMAIN}:443', h2_line)
                        h2_line = re.sub(r'sni=[^&]+', 'sni=${CDN_DOMAIN}', h2_line)
                        h2_line = re.sub(r'#[^#]+$', '#VLESS-XHTTP-CDN-H2', h2_line)
                        if '&host=' not in h2_line:
                            h2_line = h2_line.replace('&path=', '&host=${CDN_DOMAIN}&path=')
                        new_lines.append(h2_line)
                        added = True
                    new_lines.append(line)
            else:
                new_lines = lines
        else:
            new_lines = [l for l in lines if '#VLESS-XHTTP-CDN-H2' not in l]
        with open(txt_file, 'w', encoding='utf-8') as f:
            f.write('\n'.join(new_lines) + '\n')

    for yfile in [nodes_file, full_file]:
        if os.path.isfile(yfile):
            with open(yfile, 'r', encoding='utf-8') as f:
                cfg = yaml.safe_load(f)
            if not isinstance(cfg, dict):
                continue
            proxies = cfg.get('proxies', [])
            has_h2 = any('VLESS-XHTTP-CDN-H2' in p.get('name', '') for p in proxies)
            if enable and not has_h2:
                new_proxies = []
                added = False
                for p in proxies:
                    if 'VLESS-XHTTP-CDN-H3' in p.get('name', ''):
                        h2_p = copy.deepcopy(p)
                        h2_p['name'] = p['name'].replace('VLESS-XHTTP-CDN-H3', 'VLESS-XHTTP-CDN-H2')
                        h2_p['alpn'] = ['h2']
                        new_proxies.append(h2_p)
                        added = True
                    elif not added and ('VLESS-XHTTP-Direct-H3' in p.get('name', '') or 'VLESS-Reality' in p.get('name', '')):
                        h2_p = copy.deepcopy(p)
                        h2_p['name'] = 'VLESS-XHTTP-CDN-H2'
                        h2_p['server'] = '${CDN_DOMAIN}'
                        h2_p['port'] = 443
                        h2_p['servername'] = '${CDN_DOMAIN}'
                        h2_p['alpn'] = ['h2']
                        if 'xhttp-opts' in h2_p:
                            h2_p['xhttp-opts']['host'] = '${CDN_DOMAIN}'
                            h2_p['xhttp-opts']['mode'] = 'stream-up'
                        new_proxies.append(h2_p)
                        added = True
                    new_proxies.append(p)
                cfg['proxies'] = new_proxies
            elif not enable and has_h2:
                cfg['proxies'] = [p for p in proxies if 'VLESS-XHTTP-CDN-H2' not in p.get('name', '')]
            with open(yfile, 'w', encoding='utf-8') as f:
                yaml.dump(cfg, f, allow_unicode=True, sort_keys=False)
" 2>/dev/null || true
  cmd_resub
}

cmd_cdnh2() {
  local action="${1:-show}"
  case "$action" in
    show|status)
      echo ""
      echo -e "${CYAN}=== CDN TCP(h2) 节点状态 ===${NC}"
      local cur_h2="${FEATURE_CDN_H2:-false}"
      if [[ "$cur_h2" == "true" ]]; then
        echo -e "  当前状态:       ${GREEN}已开启 (Enabled)${NC}"
      else
        echo -e "  当前状态:       ${YELLOW}未开启 (Disabled)${NC}"
      fi
      local cdn_domain="${CDN_DOMAIN:-}"
      if [[ -n "$cdn_domain" ]]; then
        echo -e "  CDN 域名:       ${cdn_domain}"
      fi
      echo ""
      echo -e "说明："
      echo -e "  • 走 TCP 443 的 VLESS-XHTTP-CDN-H2 节点，经 CDN 的 TCP(h2) 备用节点，默认关闭；UDP 被限速 / 封锁时用 xh cdnh2 on 开启。"
      echo -e "  • 快捷命令:"
      echo -e "      ${MANAGE_CMD} cdnh2 on       # 开启 CDN TCP(h2) 节点并同步更新订阅"
      echo -e "      ${MANAGE_CMD} cdnh2 off      # 关闭 CDN TCP(h2) 节点并恢复精简订阅"
      echo ""
      ;;
    on)
      info "正在开启 CDN TCP(h2) 节点..."
      update_node_env "FEATURE_CDN_H2" "true"
      export FEATURE_CDN_H2=true
      sync_client_configs_cdnh2 "true"
      info "CDN TCP(h2) 节点已成功开启并同步更新订阅！"
      ;;
    off)
      info "正在关闭 CDN TCP(h2) 节点..."
      update_node_env "FEATURE_CDN_H2" "false"
      export FEATURE_CDN_H2=false
      sync_client_configs_cdnh2 "false"
      info "CDN TCP(h2) 节点已成功关闭并恢复精简订阅！"
      ;;
    *)
      echo "用法: ${MANAGE_CMD} cdnh2 [show|on|off]"
      ;;
  esac
}

sync_client_configs_cdnh3() {
  local enable="$1"
  # 优先从备用节点库取节点行与 Mihomo 条目（和全新安装逐字一致）。没有库的旧安装才走下面的克隆兜底。
  if [[ -f "${ALL_STORE_DIR}/client-config.txt" ]]; then
    local _act=off; [[ "$enable" == true ]] && _act=on
    backup_node_sync_files "VLESS-XHTTP-CDN-H3" "$_act" || warn "VLESS-XHTTP-CDN-H3 的客户端文件同步未完成（原因见上）"
    cmd_resub
    return 0
  fi
  python3 -c "
import os, sys, re, yaml, copy

enable = ('$enable' == 'true')
user_homes = ['${USER_HOME:-/home/ubuntu}', '/home/ubuntu', '/home/opc', '/root']
seen = set()

for home in user_homes:
    if not home or home in seen or not os.path.isdir(home):
        continue
    seen.add(home)
    txt_file = os.path.join(home, 'client-config.txt')
    nodes_file = os.path.join(home, 'client-config-mihomo-nodes.yaml')
    full_file = os.path.join(home, 'client-config-mihomo-full.yaml')

    if os.path.isfile(txt_file):
        with open(txt_file, 'r', encoding='utf-8') as f:
            lines = [l.strip() for l in f if l.strip()]
        new_lines = []
        has_h3 = any('#VLESS-XHTTP-CDN-H3' in l for l in lines)
        if enable:
            if not has_h3:
                added = False
                for line in lines:
                    new_lines.append(line)
                    if '#VLESS-XHTTP-CDN-H2' in line:
                        h3_line = line.replace('alpn=h2,http%2F1.1', 'alpn=h3').replace('alpn=h2', 'alpn=h3').replace('#VLESS-XHTTP-CDN-H2', '#VLESS-XHTTP-CDN-H3')
                        new_lines.append(h3_line)
                        added = True
                if not added:
                    for line in lines:
                        if '#VLESS-XHTTP-Direct-H3' in line:
                            h3_line = line.replace('${REALITY_DOMAIN}', '${CDN_DOMAIN}').replace('${VPS_IP}', '${CDN_DOMAIN}').replace(':${H3_PORT}', ':443').replace('#VLESS-XHTTP-Direct-H3', '#VLESS-XHTTP-CDN-H3')
                            new_lines.append(h3_line)
                        new_lines.append(line)
            else:
                new_lines = lines
        else:
            new_lines = [l for l in lines if '#VLESS-XHTTP-CDN-H3' not in l]
        with open(txt_file, 'w', encoding='utf-8') as f:
            f.write('\n'.join(new_lines) + '\n')

    for yfile in [nodes_file, full_file]:
        if os.path.isfile(yfile):
            with open(yfile, 'r', encoding='utf-8') as f:
                cfg = yaml.safe_load(f)
            if not isinstance(cfg, dict):
                continue
            proxies = cfg.get('proxies', [])
            has_h3 = any('VLESS-XHTTP-CDN-H3' in p.get('name', '') for p in proxies)
            if enable and not has_h3:
                new_proxies = []
                for p in proxies:
                    new_proxies.append(p)
                    if 'VLESS-XHTTP-CDN-H2' in p.get('name', ''):
                        h3_p = copy.deepcopy(p)
                        h3_p['name'] = p['name'].replace('VLESS-XHTTP-CDN-H2', 'VLESS-XHTTP-CDN-H3')
                        h3_p['alpn'] = ['h3']
                        new_proxies.append(h3_p)
                cfg['proxies'] = new_proxies
            elif not enable and has_h3:
                cfg['proxies'] = [p for p in proxies if 'VLESS-XHTTP-CDN-H3' not in p.get('name', '')]
            with open(yfile, 'w', encoding='utf-8') as f:
                yaml.dump(cfg, f, allow_unicode=True, sort_keys=False)
" 2>/dev/null || true
  cmd_resub
}

cmd_cdnh3() {
  local action="${1:-show}"
  case "$action" in
    show|status)
      echo ""
      echo -e "${CYAN}=== CDN QUIC(h3) 节点状态 ===${NC}"
      local cur_h3="${FEATURE_CDN_H3:-false}"
      if [[ "$cur_h3" == "true" ]]; then
        echo -e "  当前状态:       ${GREEN}已开启 (Enabled)${NC}"
      else
        echo -e "  当前状态:       ${YELLOW}未开启 (Disabled)${NC}"
      fi
      local cdn_domain="${CDN_DOMAIN:-}"
      if [[ -n "$cdn_domain" ]]; then
        echo -e "  CDN 域名:       ${cdn_domain}"
      fi
      echo ""
      echo -e "说明："
      echo -e "  • 开启此项可生成走 UDP 443 (HTTP/3 / QUIC) 的 VLESS-XHTTP-CDN-H3 节点（默认开启）。"
      echo -e "  • 快捷命令:"
      echo -e "      ${MANAGE_CMD} cdnh3 on       # 开启 CDN QUIC(h3) 节点并同步更新订阅"
      echo -e "      ${MANAGE_CMD} cdnh3 off      # 关闭 CDN QUIC(h3) 节点并恢复精简订阅"
      echo ""
      ;;
    on)
      info "正在开启 CDN QUIC(h3) 节点..."
      update_node_env "FEATURE_CDN_H3" "true"
      export FEATURE_CDN_H3=true
      sync_client_configs_cdnh3 "true"
      info "CDN QUIC(h3) 节点已成功开启并同步更新订阅！"
      ;;
    off)
      info "正在关闭 CDN QUIC(h3) 节点..."
      update_node_env "FEATURE_CDN_H3" "false"
      export FEATURE_CDN_H3=false
      sync_client_configs_cdnh3 "false"
      info "CDN QUIC(h3) 节点已成功关闭并恢复精简订阅！"
      ;;
    *)
      echo "用法: ${MANAGE_CMD} cdnh3 [show|on|off]"
      ;;
  esac
}

cmd_ech() {
  local action="${1:-show}"
  case "$action" in
    show|status)
      echo ""
      echo -e "${CYAN}=== Cloudflare CDN ECH (Encrypted Client Hello) 状态 ===${NC}"
      local cur_ech="${CDN_ECH_ENABLED:-false}"
      if [[ "$cur_ech" == "true" ]]; then
        echo -e "  当前状态:       ${GREEN}已开启 (Enabled)${NC}"
        echo -e "  DoH 查询端点:   ${CDN_ECH_QUERY:-cloudflare-ech.com+https://223.5.5.5/dns-query}"
      else
        echo -e "  当前状态:       ${YELLOW}未开启 (Disabled)${NC}"
      fi
      local cdn_domain="${CDN_DOMAIN:-}"
      if [[ -n "$cdn_domain" ]]; then
        echo -e "  CDN 域名:       ${cdn_domain}"
        echo -n "  Cloudflare 记录: "
        local ech_probe=""
        if command -v dig >/dev/null 2>&1; then
          ech_probe=$(dig +short HTTPS "$cdn_domain" @1.1.1.1 2>/dev/null | grep -o 'ech=[^ ]*' || true)
        fi
        if [[ -n "$ech_probe" ]]; then
          echo -e "${GREEN}检测到有效 ECH 记录${NC} (${ech_probe:0:32}...)"
        else
          echo -e "${YELLOW}未检测到 ECH 记录 (请在 Cloudflare SSL/TLS 边缘证书中开启 ECH)${NC}"
        fi
      else
        echo -e "  CDN 域名:       ${YELLOW}未配置${NC}"
      fi
      echo ""
      echo -e "说明："
      echo -e "  • ECH 加密 TLS ClientHello 中的 SNI，将真实 CDN 域名隐藏在 cloudflare-ech.com 之后。"
      echo -e "  • 开启后自动更新全套客户端配置与订阅 (v2rayN / Mihomo / Clash / v2rayNG)。"
      echo -e "  • 快捷命令:"
      echo -e "      ${MANAGE_CMD} ech on       # 开启 CDN ECH 并同步更新订阅"
      echo -e "      ${MANAGE_CMD} ech off      # 关闭 CDN ECH 并恢复标准 TLS 订阅"
      echo ""
      ;;
    on)
      info "正在开启 CDN ECH..."
      local cdn_query="${2:-cloudflare-ech.com+https://223.5.5.5/dns-query}"
      update_node_env "FEATURE_CDN_ECH" "true"
      update_node_env "CDN_ECH_ENABLED" "true"
      update_node_env "CDN_ECH_QUERY" "$cdn_query"
      export FEATURE_CDN_ECH=true
      export CDN_ECH_ENABLED=true
      export CDN_ECH_QUERY="$cdn_query"
      sync_client_configs_ech "true" "$cdn_query"
      info "CDN ECH 已成功开启并同步更新订阅！"
      ;;
    off)
      info "正在关闭 CDN ECH..."
      update_node_env "FEATURE_CDN_ECH" "true"
      update_node_env "CDN_ECH_ENABLED" "false"
      update_node_env "CDN_ECH_QUERY" ""
      export FEATURE_CDN_ECH=true
      export CDN_ECH_ENABLED=false
      export CDN_ECH_QUERY=""
      sync_client_configs_ech "false" ""
      info "CDN ECH 已成功关闭并恢复标准订阅！"
      ;;
    *)
      echo "用法: ${MANAGE_CMD} ech [show|on|off]"
      ;;
  esac
}

cmd_ecn() {
  local action="${1:-show}"
  case "$action" in
    show|status)
      echo ""
      echo -e "${CYAN}=== TCP ECN (Explicit Congestion Notification) 状态 ===${NC}"
      local cur_ecn cur_fallback
      cur_ecn=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "n/a")
      cur_fallback=$(sysctl -n net.ipv4.tcp_ecn_fallback 2>/dev/null || echo "n/a")
      if [[ "$cur_ecn" == "1" ]]; then
        echo -e "  当前状态:       ${GREEN}已开启 (1 - 主动双向协商)${NC}"
      elif [[ "$cur_ecn" == "2" ]]; then
        echo -e "  当前状态:       ${YELLOW}被动协商 (2 - 仅响应对端 ECN 请求)${NC}"
      else
        echo -e "  当前状态:       ${RED}已关闭 (0)${NC}"
      fi
      echo -e "  自动回退黑洞:   ${cur_fallback} (1=开启，遇到不支持 ECN 的坏中间盒自动回退)"
      local ce_stat
      ce_stat=$(nstat -az 2>/dev/null | grep -iE 'DeliveredCE|InCEPkts' | awk '{printf "%s: %s  ", $1, $2}')
      echo -e "  路径 CE 标记:   ${ce_stat:-无记录或0}"
      echo ""
      echo -e "说明："
      echo -e "  • ECN 允许网络路由器在缓冲区打满前向 TCP 端点标记拥塞（CE 标记），避免直接丢包。"
      echo -e "  • 配合当前主机的 BBRv3 内核，可实现极低抖动拥塞控制响应。"
      echo -e "  • 快捷命令:"
      echo -e "      ${MANAGE_CMD} ecn on       # 开启主动双向 ECN 协商 (tcp_ecn=1)"
      echo -e "      ${MANAGE_CMD} ecn off      # 关闭 ECN 协商 (tcp_ecn=0)"
      echo ""
      ;;
    on)
      info "正在开启 TCP ECN..."
      try_sysctl net.ipv4.tcp_ecn 1 || sysctl -w net.ipv4.tcp_ecn=1 >/dev/null 2>&1 || true
      try_sysctl net.ipv4.tcp_ecn_fallback 1 || sysctl -w net.ipv4.tcp_ecn_fallback=1 >/dev/null 2>&1 || true
      if [[ -f "$SYSCTL_CONF" ]]; then
        sed -i -E 's/^#?net\.ipv4\.tcp_ecn[[:space:]]*=.*/net.ipv4.tcp_ecn = 1/' "$SYSCTL_CONF" 2>/dev/null || true
        sed -i -E 's/^#?net\.ipv4\.tcp_ecn_fallback[[:space:]]*=.*/net.ipv4.tcp_ecn_fallback = 1/' "$SYSCTL_CONF" 2>/dev/null || true
      fi
      if [[ -f "/etc/sysctl.d/99-sbbox.conf" ]]; then
        sed -i -E 's/^#?net\.ipv4\.tcp_ecn[[:space:]]*=.*/net.ipv4.tcp_ecn = 1/' "/etc/sysctl.d/99-sbbox.conf" 2>/dev/null || true
        sed -i -E 's/^#?net\.ipv4\.tcp_ecn_fallback[[:space:]]*=.*/net.ipv4.tcp_ecn_fallback = 1/' "/etc/sysctl.d/99-sbbox.conf" 2>/dev/null || true
      fi
      info "TCP ECN 已成功开启 (net.ipv4.tcp_ecn=1, tcp_ecn_fallback=1)！"
      ;;
    off)
      info "正在关闭 TCP ECN..."
      try_sysctl net.ipv4.tcp_ecn 0 || sysctl -w net.ipv4.tcp_ecn=0 >/dev/null 2>&1 || true
      if [[ -f "$SYSCTL_CONF" ]]; then
        sed -i -E 's/^#?net\.ipv4\.tcp_ecn[[:space:]]*=.*/net.ipv4.tcp_ecn = 0/' "$SYSCTL_CONF" 2>/dev/null || true
      fi
      if [[ -f "/etc/sysctl.d/99-sbbox.conf" ]]; then
        sed -i -E 's/^#?net\.ipv4\.tcp_ecn[[:space:]]*=.*/net.ipv4.tcp_ecn = 0/' "/etc/sysctl.d/99-sbbox.conf" 2>/dev/null || true
      fi
      info "TCP ECN 已关闭 (net.ipv4.tcp_ecn=0)！"
      ;;
    *)
      echo "用法: ${MANAGE_CMD} ecn [show|on|off]"
      ;;
  esac
}

# ---------- nginx 更新（v4.9.47：每周只提醒，手动更新并校验 PGP 签名）----------
# 跟随 nginx.org 的 mainline（nginx 官方推荐生产使用；安装器同样装 mainline）。
# 源码包必须通过 nginx 官方发布签名校验，且签名密钥的主指纹必须在下面的固定列表里——
# 防止下载源或密钥文件被替换。列表来自 https://nginx.org/en/pgp_keys.html（2026-09-29 核对）：
#   Sergey Kandaurov / Roman Arutyunyan / Konstantin Pavlov / Sergey Budnevitch
NGINX_PGP_KEYS="pluknet arut thresh sb"
NGINX_PGP_FPRS="D6786CE303D9A9022998DC6CC8464D549AF75C0A 43387825DDB1BB97EC36BA5D007C8D7C15D87369 13C82A63B603576156E30A4EA0EA981B66B0D967 7338973069ED3F443F4D37DFA64FD5B17ADB39A8"

nginx_latest_mainline() {
  curl -fsSL --max-time 20 https://nginx.org/en/download.html 2>/dev/null \
    | sed 's/Stable version.*//' | grep -o 'nginx-[0-9][0-9.]*\.tar\.gz' | head -1 \
    | sed 's/^nginx-//; s/\.tar\.gz$//'
}

nginx_build_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq gcc make libpcre2-dev zlib1g-dev libssl-dev gnupg >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q gcc make pcre2-devel zlib-devel openssl-devel gnupg2 >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q gcc make pcre2-devel zlib-devel openssl-devel gnupg2 >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache build-base pcre2-dev zlib-dev openssl-dev linux-headers gnupg >/dev/null 2>&1
  fi
}

# nginx_verify_pgp <tarball> <asc>：签名有效且签名者主指纹在固定列表内才返回 0
nginx_verify_pgp() {
  local tgz="$1" asc="$2" gh k fpr ok=1
  command -v gpg >/dev/null 2>&1 || { warn "未安装 gpg，无法校验 nginx 签名"; return 1; }
  gh=$(mktemp -d) && chmod 700 "$gh"
  for k in $NGINX_PGP_KEYS; do
    curl -fsSL --max-time 20 "https://nginx.org/keys/${k}.key" 2>/dev/null | GNUPGHOME="$gh" gpg -q --batch --import 2>/dev/null
  done
  # VALIDSIG 行最后一个字段是签名密钥的主指纹
  fpr=$(GNUPGHOME="$gh" gpg --batch --status-fd 1 --verify "$asc" "$tgz" 2>/dev/null | awk '$2=="VALIDSIG"{print $NF}')
  rm -rf "$gh"
  if [[ -n "$fpr" ]] && [[ " $NGINX_PGP_FPRS " == *" $fpr "* ]]; then
    info "nginx 源码 PGP 签名校验通过（签名者主指纹 ${fpr}）"; ok=0
  else
    warn "nginx 源码 PGP 签名校验失败（签名者：${fpr:-无有效签名}），拒绝使用"
  fi
  return $ok
}

# nginx 只接受 HTTP/2（请求层）：开 = 在两个真实 server 块里写入 xh-h2only 标记块，关 = 整块删除。
# nginx 的 ALPN 握手里始终会列出 http/1.1，没有指令可以去掉；这里是对 HTTP/1.x 请求直接 return 444。
# 例外：/sub/ 订阅页与 /.well-known/（部分订阅客户端只会 HTTP/1.1）。
# 注意：经 Cloudflare 回源时 CF 对普通页面可能用 HTTP/1.1，打开 h2only 后用浏览器访问 CDN 域名首页会看到 CF 的 52x 错误页；
# xhttp / gRPC 流量本来就是 HTTP/2，不受影响。
nginx_h2only() {
  local act="${1:-show}" conf="/etc/nginx/nginx.conf" cur=off tmp bak
  [[ -f "$conf" ]] || fail "未找到 ${conf}"
  grep -q '# >>xh-h2only' "$conf" && cur=on
  case "$act" in
    show|status)
      echo -e "${CYAN}=== nginx 只接受 HTTP/2 ===${NC}"
      [[ "$cur" == on ]] && echo -e "  当前状态:  ${GREEN}已开启${NC}（HTTP/1.x 请求被断开，/sub/ 例外）" || echo -e "  当前状态:  ${YELLOW}未开启${NC}"
      echo -e "  ${MANAGE_CMD} nginx h2only on|off"
      return 0 ;;
    on|off) ;;
    *) echo "用法: ${MANAGE_CMD} nginx h2only [show|on|off]"; return 1 ;;
  esac
  [[ "$cur" == "$act" ]] && { info "nginx h2only 本来就是 ${act}"; return 0; }
  tmp="${conf}.h2only-tmp"; bak="${conf}.h2only.bak"
  python3 - "$conf" "$tmp" "$act" <<'H2PY' || { rm -f "$tmp"; fail "改写 nginx 配置失败，未做任何修改"; }
import re, sys
src, dst, act = sys.argv[1:4]
s = open(src, encoding='utf-8').read()
BLOCK = (
    '        # >>xh-h2only\n'
    '        # 只接受 HTTP/2：HTTP/1.x 请求直接断开。/sub/ 与 /.well-known/ 例外。xh nginx h2only off 可关闭。\n'
    '        set $h2only 1;\n'
    '        if ($server_protocol = "HTTP/2.0") { set $h2only 0; }\n'
    '        if ($uri ~ "^/(sub|\\.well-known)/") { set $h2only 0; }\n'
    '        if ($h2only) { return 444; }\n'
    '        # <<xh-h2only\n')
if act == 'off':
    s, n = re.subn(r'[ \t]*# >>xh-h2only\n.*?# <<xh-h2only\n', '', s, flags=re.S)
else:
    line = '        http2        on;\n'
    if s.count(line) < 1:
        sys.stderr.write('没找到 http2 on 行（配置不是由本脚本生成？）\n'); sys.exit(1)
    s = s.replace(line, line + BLOCK)
open(dst, 'w', encoding='utf-8').write(s)
H2PY
  if ! nginx -t -c "$tmp" >/dev/null 2>&1; then
    nginx -t -c "$tmp" 2>&1 | tail -3; rm -f "$tmp"; fail "nginx 配置校验失败，已放弃，未做任何修改"
  fi
  cp -a "$conf" "$bak"
  chown --reference="$conf" "$tmp" 2>/dev/null || true; chmod --reference="$conf" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$conf"
  if nginx -t >/dev/null 2>&1 && nginx -s reload 2>/dev/null; then
    info "nginx h2only 已$([[ "$act" == on ]] && echo 开启 || echo 关闭)（nginx 已重载，Xray 没有重启，客户端不需要重连）"
  else
    cp -a "$bak" "$conf"; nginx -s reload 2>/dev/null || true
    fail "nginx 重载失败，已回滚到修改前的配置"
  fi
}

cmd_nginx() {
  local action="${1:-show}" a
  local bin cur latest
  bin=$(command -v nginx) || fail "未找到 nginx"
  cur=$("$bin" -v 2>&1 | sed -n 's|.*nginx/||p')
  case "$action" in
    h2only) shift; nginx_h2only "$@"; return $? ;;
    show|status)
      latest=$(nginx_latest_mainline)
      echo "nginx 当前: ${cur}   mainline 最新: ${latest:-查询失败}"
      "$bin" -V 2>&1 | grep -E 'built with|running with'
      ;;
    check)
      # 每周任务调用：只检查、写提醒
      latest=$(nginx_latest_mainline)
      [[ -n "$latest" ]] || { warn "查询 nginx 最新版本失败"; return 0; }
      if [[ "$(printf '%s\n%s\n' "$latest" "$cur" | sort -V | tail -1)" != "$cur" ]]; then
        update_notice nginx "${cur} → ${latest}（手动更新：${MANAGE_CMD} nginx update）"
        info "nginx 有新版本：${cur} → ${latest}"
      else
        update_notice nginx ""
        info "nginx 已是最新 mainline：${cur}"
      fi
      ;;
    update|up)
      latest=$(nginx_latest_mainline)
      [[ -n "$latest" ]] || { warn "无法从 nginx.org 获取最新版本"; return 1; }
      if [[ "$(printf '%s\n%s\n' "$latest" "$cur" | sort -V | tail -1)" == "$cur" ]]; then
        info "nginx 已是最新 mainline：${cur}"; update_notice nginx ""; return 0
      fi
      info "nginx ${cur} → ${latest}"
      if [[ " $* " != *" -y "* ]]; then
        read -rp "下载并校验签名、按原编译参数重新编译并替换 nginx（约需数分钟，替换时重启 nginx）？[y/N] " a
        [[ "${a,,}" == "y" ]] || { info "已取消"; return 0; }
      fi
      local args tmp src log="/var/log/xh-nginx-build.log"
      args=$("$bin" -V 2>&1 | sed -n 's/^configure arguments: //p')
      [[ -n "$args" ]] || { warn "读取不到原编译参数"; return 1; }
      nginx_build_deps
      tmp=$(mktemp -d) || return 1
      if ! curl -fsSL --max-time 120 "https://nginx.org/download/nginx-${latest}.tar.gz" -o "$tmp/n.tgz" \
         || ! curl -fsSL --max-time 20 "https://nginx.org/download/nginx-${latest}.tar.gz.asc" -o "$tmp/n.asc"; then
        warn "下载 nginx ${latest} 源码或签名失败"; rm -rf "$tmp"; return 1
      fi
      nginx_verify_pgp "$tmp/n.tgz" "$tmp/n.asc" || { rm -rf "$tmp"; return 1; }
      tar -xzf "$tmp/n.tgz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
      src="$tmp/nginx-${latest}"
      info "编译中（日志 ${log}）..."
      # 参数来自本机二进制自身的 nginx -V，含 --with-cc-opt 等，需 eval 还原
      if ! ( cd "$src" && eval "./configure $args" && make -j"$(nproc 2>/dev/null || echo 1)" ) >"$log" 2>&1; then
        warn "nginx ${latest} 编译失败，保留 ${cur}（详见 ${log}）"; rm -rf "$tmp"; return 1
      fi
      if ! "$src/objs/nginx" -t -q >>"$log" 2>&1; then
        warn "新二进制测试现有配置失败，保留 ${cur}（详见 ${log}）"; rm -rf "$tmp"; return 1
      fi
      local bak="${bin}.bak-${cur}"
      cp -a "$bin" "$bak" || { rm -rf "$tmp"; fail "备份旧 nginx 失败"; }
      install -m 755 "$src/objs/nginx" "${bin}.new" && mv -f "${bin}.new" "$bin"
      rm -rf "$tmp"
      if svc restart nginx >/dev/null 2>&1 && sleep 1 && "$bin" -v 2>&1 | grep -q "nginx/${latest}" \
         && ss -lnt 2>/dev/null | grep -q ':8003 '; then
        local o; for o in "${bin}".bak-*; do [[ "$o" == "$bak" ]] || rm -f "$o"; done
        update_notice nginx ""
        info "nginx 已更新：${cur} → ${latest}（旧二进制备份 ${bak}）"
      else
        warn "新 nginx 启动或端口复核失败，回滚到 ${cur}"
        cp -a "$bak" "$bin"; svc restart nginx || true
        return 1
      fi
      ;;
    *) echo "用法: ${MANAGE_CMD} nginx [show|check|update [-y]]" ;;
  esac
}

# ---------- 证书续期方式（v4.9.45）----------
# 找到本项目双域名证书在 acme.sh 里的域名配置文件
acme_domain_conf() {
  local _d
  for _d in "$HOME/.acme.sh/${REALITY_DOMAIN}_ecc" "$HOME/.acme.sh/${REALITY_DOMAIN}"; do
    [[ -f "$_d/${REALITY_DOMAIN}.conf" ]] && { printf '%s' "$_d/${REALITY_DOMAIN}.conf"; return 0; }
  done
  return 1
}

# CDN 域名是否走了代理：解析结果里不含本机 IP 即视为经 CDN（Cloudflare 橙云）
cdn_behind_proxy() {
  [[ -n "${CDN_DOMAIN:-}" && -n "${VPS_IP:-}" ]] || return 1
  local _ips
  _ips=$(getent ahostsv4 "$CDN_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
  [[ -n "$_ips" ]] || return 1
  ! grep -Fxq "$VPS_IP" <<< "$_ips"
}

cmd_cert() {
  local action="${1:-show}" conf
  conf=$(acme_domain_conf) || fail "未找到 acme.sh 的域名配置（${REALITY_DOMAIN:-未设置}）"
  local acct="$HOME/.acme.sh/account.conf"
  case "$action" in
    show|status)
      local wr nr
      wr=$(. "$conf" 2>/dev/null; printf '%s' "${Le_Webroot:-}")
      nr=$(. "$conf" 2>/dev/null; printf '%s' "${Le_NextRenewTimeStr:-}")
      echo "证书到期:   $(openssl x509 -in /etc/ssl/private/fullchain.cer -noout -enddate 2>/dev/null | cut -d= -f2)"
      echo "下次续期:   ${nr:-未知}"
      case "$wr" in
        dns_*) echo "续期方式:   DNS-01（${wr}）" ;;
        *)     echo "续期方式:   standalone（HTTP-01，续期时停 nginx 占用 80 端口）" ;;
      esac
      if cdn_behind_proxy; then echo "CDN 域名:   已走 CDN 代理"; else echo "CDN 域名:   直连本机（或解析失败）"; fi
      grep -q '^SAVED_CF_Token=' "$acct" 2>/dev/null && echo "CF Token:   已保存（account.conf）" || echo "CF Token:   未保存"
      if [[ "$wr" != dns_* ]] && cdn_behind_proxy; then
        warn "CDN 已走代理，standalone 续期会失败：CF_Token=<API Token> ${MANAGE_CMD} cert dnscf"
      fi
      ;;
    dnscf)
      # Token 来源：环境变量 CF_Token 优先，否则沿用 account.conf 里已保存的
      local tok="${CF_Token:-}"
      [[ -n "$tok" ]] || tok=$(sed -nE "s/^SAVED_CF_Token='?([^']*)'?\$/\1/p" "$acct" 2>/dev/null | head -1)
      [[ -n "$tok" ]] || fail "需要 Cloudflare API Token（Zone.DNS 编辑权限）：CF_Token=<token> ${MANAGE_CMD} cert dnscf"
      # 先验证 Token 能看到 CDN 域名所在的 Zone，避免切过去之后续期时才失败
      local zone="${CDN_DOMAIN#*.}" resp
      # 请求头经 stdin（curl -K -）传入，Token 不出现在进程参数里（ps 可见）
      resp=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -fsS --max-time 20 -K - \
        "https://api.cloudflare.com/client/v4/zones?name=${zone}" 2>/dev/null) || fail "Cloudflare API 请求失败（Token 无效或网络不通）"
      python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("success") and d.get("result") else 1)' <<< "$resp" \
        || fail "该 Token 看不到 Zone ${zone}，请检查权限（需 Zone.Zone 读 + Zone.DNS 编辑）"
      info "Token 已验证：可访问 Zone ${zone}"
      if [[ -n "${CF_Token:-}" ]]; then
        cp -a "$acct" "${acct}.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        sed -i '/^SAVED_CF_Token=/d' "$acct"
        printf "SAVED_CF_Token='%s'\n" "$CF_Token" >> "$acct"
        chmod 600 "$acct"
      fi
      cp -a "$conf" "${conf}.bak-$(date +%Y%m%d%H%M%S)"
      # 续期模式记在 Le_Webroot；DNS-01 不需要停 nginx，清空 Pre/PostHook
      sed -i -E "s/^Le_Webroot=.*/Le_Webroot='dns_cf'/; s/^Le_PreHook=.*/Le_PreHook=''/; s/^Le_PostHook=.*/Le_PostHook=''/" "$conf"
      grep -q "^Le_Webroot='dns_cf'" "$conf" || fail "写入续期方式失败：$conf"
      info "已切换为 DNS-01 续期（dns_cf），续期时不再停 nginx"
      info "可用 LE 测试环境演练：acme.sh --issue --server letsencrypt_test --dns dns_cf -d ${REALITY_DOMAIN} -d ${CDN_DOMAIN} --keylength ec-256 --config-home /tmp/acme-test --cert-home /tmp/acme-test/certs"
      ;;
    *) fail "用法: ${MANAGE_CMD} cert [show|dnscf]" ;;
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
  rm -f /etc/profile.d/xh-updates.sh
  remove_nic_tune
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

# ==================================================
# 可选节点开关：h2direct / hy2obfs / split（上下行分离两条）；各自的默认开关状态见 01-env.sh
# ==================================================
# 备用节点库 /etc/xhttp-cdn/all/ 由安装脚本在「全部备用节点开启」的参数下渲染一遍得到
# （见 11-client-config.sh、09-server-config.sh）。开关只从库里取节点行 / Mihomo 条目 /
# 服务端入站文本，不在这里重新拼装，所以和全新安装逐字一致。
# 限制：库是安装时的快照。装好后用 xh ech 改过的 ECH 设置不会同步进库；节点被 NODE_NAME_MAP
# 改过名时，按默认名匹配会找不到，开关会明确报错而不是静默跳过。
ALL_STORE_DIR="/etc/xhttp-cdn/all"

backup_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

backup_store_check() {
  [[ -f "${ALL_STORE_DIR}/client-config.txt" ]] || fail "缺少备用节点库 ${ALL_STORE_DIR}（本机由旧版安装脚本部署，或安装时生成失败，见 ${STATE_DIR}/all-render.log）。需用最新安装命令重新部署一次才有这些开关。"
}

# 把一条节点加进 / 移出本机的 client-config.txt 与两份 Mihomo yaml。
# $1 = 节点名（链接 # 后面的名字，不含 NODE_SUFFIX），$2 = on|off
# 先在内存里算好所有文件的新内容，全部成功才写盘（逐个 tmp + rename）。失败返回非零，不留半改状态。
# 返回 0 = 已处理，2 = 节点库里没有该节点（on）或本机没有该节点（off）。
backup_node_sync_files() {
  python3 - "$ALL_STORE_DIR" "$1" "$2" "${USER_HOME:-/home/ubuntu}" /home/ubuntu /home/opc /root <<'SYNCPY'
import copy, os, sys

try:
    import yaml
except ImportError:
    sys.stderr.write('缺少 python3-yaml，无法同步 Mihomo 配置\n')
    sys.exit(1)

store, name, act = sys.argv[1:4]
homes = sys.argv[4:]
enable = (act == 'on')

def frag(line):
    return line.rsplit('#', 1)[-1]

def match(line):
    return frag(line).startswith(name)

def insert_pos(all_items, idx, live_keys, key):
    """新节点放在节点库顺序里「前一个本机已有的节点」之后，都没有就放最前。"""
    for prev in reversed(all_items[:idx]):
        k = key(prev)
        if k in live_keys:
            return live_keys.index(k) + 1
    return 0

pending = []      # (路径, 新内容)
found_any = False
seen = set()
try:
    for home in homes:
        if not home or home in seen or not os.path.isdir(home):
            continue
        seen.add(home)

        tf = os.path.join(home, 'client-config.txt')
        sf = os.path.join(store, 'client-config.txt')
        if os.path.isfile(tf) and os.path.isfile(sf):
            all_lines = [l.strip() for l in open(sf, encoding='utf-8') if l.strip()]
            live = [l.strip() for l in open(tf, encoding='utf-8') if l.strip()]
            has = any(match(l) for l in live)
            if enable:
                src = [l for l in all_lines if match(l)]
                if not src:
                    sys.stderr.write('节点库里没有 %s（节点被改过名？）\n' % name)
                    sys.exit(2)
                found_any = True
                if not has:
                    pos = insert_pos(all_lines, all_lines.index(src[0]), [frag(l) for l in live], frag)
                    live.insert(pos, src[0])
                    pending.append((tf, '\n'.join(live) + '\n'))
            else:
                if has:
                    found_any = True
                    live = [l for l in live if not match(l)]
                    pending.append((tf, '\n'.join(live) + '\n'))

        for fname in ('client-config-mihomo-nodes.yaml', 'client-config-mihomo-full.yaml'):
            lf = os.path.join(home, fname)
            sf = os.path.join(store, fname)
            if not (os.path.isfile(lf) and os.path.isfile(sf)):
                continue
            live = yaml.safe_load(open(lf, encoding='utf-8'))
            ref = yaml.safe_load(open(sf, encoding='utf-8'))
            if not isinstance(live, dict) or not isinstance(ref, dict):
                raise ValueError('%s 不是有效的 Mihomo 配置' % lf)
            lp = live.setdefault('proxies', [])
            rp = ref.get('proxies', [])
            pm = lambda p: str(p.get('name', '')).startswith(name)
            has = any(pm(p) for p in lp)
            changed = False
            if enable and not has:
                src = [p for p in rp if pm(p)]
                if not src:
                    continue
                p = copy.deepcopy(src[0])
                names = [x.get('name') for x in lp]
                lp.insert(insert_pos(rp, rp.index(src[0]), names, lambda x: x.get('name')), p)
                ref_groups = {g.get('name'): g for g in (ref.get('proxy-groups') or []) if isinstance(g, dict)}
                for g in (live.get('proxy-groups') or []):
                    r = ref_groups.get(g.get('name'))
                    if r and isinstance(r.get('proxies'), list) and isinstance(g.get('proxies'), list) and p['name'] in r['proxies']:
                        if p['name'] not in g['proxies']:
                            i = r['proxies'].index(p['name'])
                            g['proxies'].insert(insert_pos(r['proxies'], i, g['proxies'], lambda x: x), p['name'])
                changed = True
            elif not enable and has:
                gone = [p.get('name') for p in lp if pm(p)]
                live['proxies'] = [p for p in lp if not pm(p)]
                for g in (live.get('proxy-groups') or []):
                    if isinstance(g.get('proxies'), list):
                        g['proxies'] = [n for n in g['proxies'] if n not in gone]
                changed = True
            if changed:
                pending.append((lf, yaml.dump(live, allow_unicode=True, sort_keys=False)))
except SystemExit:
    raise
except Exception as e:
    sys.stderr.write('同步客户端文件失败：%s\n' % e)
    sys.exit(1)

if not enable and not found_any and not pending:
    sys.stderr.write('本机的客户端文件里没有 %s，无需移除\n' % name)
    sys.exit(2)

try:
    for path, content in pending:
        tmp = path + '.xh-new'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(content)
        st = os.stat(path)
        os.chmod(tmp, st.st_mode & 0o7777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        os.replace(tmp, path)
except Exception as e:
    sys.stderr.write('写入客户端文件失败：%s\n' % e)
    sys.exit(1)
SYNCPY
}

# 往 / 从线上 Xray 配置里加一条服务端入站。入站文本来自节点库，用成对的 // 注释标记包起来，
# 关闭时按标记整块删掉，配置字节级还原。安装脚本（09）也用同样的标记写入这两条入站。
# $1 = h2direct|hy2obfs，$2 = on|off，$3 = 端口（off 时用来发现「没有标记但端口已在配置里」的情况）
# 返回 0 = 已改并重启成功，3 = 无需改动，其余 = 失败（已回滚，原因已打印）。
backup_inbound_edit() {
  local key="$1" act="$2" port="$3" tmp="${XRAY_CONF%.json}.bk-tmp.json" bak="${XRAY_CONF}.bk.bak" rc err   # 临时文件必须以 .json 结尾
  [[ -f "$XRAY_CONF" ]] || { backup_error "未找到 Xray 配置文件: $XRAY_CONF"; return 1; }
  python3 - "$XRAY_CONF" "$tmp" "${ALL_STORE_DIR}/inbound-${key}.json" "$key" "$act" "$port" <<'INBPY'
import re, sys

src, dst, store, key, act, port = sys.argv[1:7]
s = open(src, encoding='utf-8').read()
# port 参数以 tag: 开头时按入站 tag 判断
pat = ('"tag"\\s*:\\s*"%s' % re.escape(port[4:])) if port.startswith('tag:') else ('"port"\\s*:\\s*%s\\b' % re.escape(port))
begin = '        // >>xh:' + key
end = '        // <<xh:' + key
has = ('// >>xh:' + key) in s

def inbounds_close(s):
    """返回 "inbounds" 数组结尾 ] 的下标（跳过字符串与 // /* */ 注释）。"""
    i, n, depth = 0, len(s), 0
    target = None
    while i < n:
        c = s[i]
        if c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            tok = s[i + 1:j]
            i = j + 1
            if target is None and depth == 1 and tok == 'inbounds':
                k = i
                while k < n and s[k] in ' \t\r\n':
                    k += 1
                if k < n and s[k] == ':':
                    k += 1
                    while k < n and s[k] in ' \t\r\n':
                        k += 1
                    if k < n and s[k] == '[':
                        depth += 1
                        target = depth
                        i = k + 1
            continue
        if s.startswith('//', i):
            while i < n and s[i] != '\n':
                i += 1
            continue
        if s.startswith('/*', i):
            i = s.index('*/', i) + 2
            continue
        if c in '{[':
            depth += 1
        elif c in '}]':
            if c == ']' and target is not None and depth == target:
                return i
            depth -= 1
        i += 1
    return -1

def strip_comments(t):
    return re.sub(r'(?m)^\s*//.*$', '', t)

if act == 'off':
    if not has:
        if re.search(pat, strip_comments(s)):
            sys.stderr.write('配置里有 %s 的入站，但没有 xh 标记（不是由 xh 开关写入）。请手动删除该入站后再关闭。\n' % port)
            sys.exit(4)
        sys.exit(3)
    a = s.index('\n' + begin)
    b = s.index(end, a) + len(end)
    s = s[:a] + s[b:]
else:
    if has:
        sys.exit(3)
    if re.search(pat, strip_comments(s)):
        sys.stderr.write('配置里已经有 %s 的入站（不是由 xh 开关写入），不重复添加。\n' % port)
        sys.exit(4)
    text = open(store, encoding='utf-8').read().rstrip('\n')
    pos = inbounds_close(s)
    if pos < 0:
        sys.stderr.write('没找到 inbounds 数组\n')
        sys.exit(1)
    while pos > 0 and s[pos - 1] in ' \t\r\n':
        pos -= 1
    s = s[:pos] + '\n' + begin + '\n' + text + '\n' + end + s[pos:]
open(dst, 'w', encoding='utf-8').write(s)
INBPY
  rc=$?
  [[ $rc -eq 3 ]] && return 3
  if [[ $rc -ne 0 ]]; then rm -f "$tmp"; backup_error "改写配置失败（代码 ${rc}），未做任何修改"; return 1; fi
  if ! err=$("$XRAY_BIN" -test -format json -config "$tmp" 2>&1); then
    rm -f "$tmp"; backup_error "Xray 配置校验失败，已放弃，未做任何修改。最后几行输出："; echo "$err" | tail -n 5 >&2; return 1
  fi
  cp -a "$XRAY_CONF" "$bak"
  chown --reference="$XRAY_CONF" "$tmp" 2>/dev/null || true
  chmod --reference="$XRAY_CONF" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$XRAY_CONF" || { backup_error "无法替换 $XRAY_CONF"; return 1; }
  if ! svc restart xray; then
    cp -a "$bak" "$XRAY_CONF"
    if svc restart xray >/dev/null 2>&1; then
      backup_error "xray 重启失败，已回滚到修改前的配置并重新启动"
    else
      backup_error "xray 重启失败，回滚后也无法启动！请立即检查：journalctl -u xray -n 30"
    fi
    return 1
  fi
  return 0
}

# 放行端口（只开不关：关闭节点时保留规则，和安装脚本一致）。$1 = tcp|udp，$2 = 端口，$3 = 是否加 QUIC 握手限速
# 有规则没写进去时打印警告，不再把失败当成功。
backup_open_port() {
  local proto="$1" port="$2" qdos="${3:-}" ipt failed=0
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    "$ipt" -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || "$ipt" -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || failed=1
    if [[ -n "$qdos" ]]; then
      "$ipt" -C INPUT -p udp --dport "$port" -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 50/sec --hashlimit-burst 100 --hashlimit-mode srcip --hashlimit-name "hy_qdos_${port}" -j DROP 2>/dev/null || \
        "$ipt" -I INPUT 1 -p udp --dport "$port" -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 50/sec --hashlimit-burst 100 --hashlimit-mode srcip --hashlimit-name "hy_qdos_${port}" -j DROP 2>/dev/null || failed=1
    fi
  done
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || failed=1
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || failed=1
  elif command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || failed=1
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || failed=1
  fi
  [[ $failed -eq 0 ]] || warn "端口 ${proto^^} ${port} 的防火墙规则没有全部写入或保存，请手动检查：iptables -S INPUT | grep ${port}"
}

backup_port_busy() {   # $1 = tcp|udp，$2 = 端口
  if [[ "$1" == tcp ]]; then
    ss -Hltn "sport = :$2" 2>/dev/null | grep -q .
  else
    ss -Hlun "sport = :$2" 2>/dev/null | grep -q .
  fi
}

# 需要服务端入站的备用节点：h2direct（TCP H2_PORT）、hy2obfs（UDP HY2_PORT）与 masque（UDP MASQUE_PORT）。$1 = key，$2 = show|on|off
# 顺序：开启时先改客户端文件（可原子撤销），再改服务端，最后写标志位；任何一步失败都撤销前面的步骤。
cmd_backup_server_node() {
  local key="$1" action="${2:-show}" flag name label proto port cur rc
  case "$key" in
    h2direct) flag=FEATURE_H2_DIRECT; name="VLESS-XHTTP-Direct-H2"; label="XHTTP-Direct-H2（TCP 直连，h3-direct 的孪生体）"; proto=tcp; port="${H2_PORT:-8445}" ;;
    hy2obfs)  flag=FEATURE_HY2_OBFS;  name="Hysteria2-Obfs-Direct"; label="Hysteria2-Obfs-Direct（salamander 混淆）";       proto=udp; port="${HY2_PORT}" ;;
    masque)   flag=FEATURE_MASQUE;    name="MASQUE-CONNECT-IP";     label="MASQUE 标准 L3 隧道 (RFC 9484 CONNECT-IP)";        proto=udp; port="${MASQUE_PORT:-8447}" ;;
  esac
  cur="${!flag:-false}"
  case "$action" in
    show|status)
      echo ""
      echo -e "${CYAN}=== ${label} ===${NC}"
      if [[ "$cur" == true ]]; then
        echo -e "  当前状态:       ${GREEN}已开启${NC}  (${proto^^} ${port})"
      else
        echo -e "  当前状态:       ${YELLOW}未开启${NC}  (开启后监听 ${proto^^} ${port})"
      fi
      if [[ "$key" == hy2obfs ]]; then
        echo -e "  ${MANAGE_CMD} hy2 obfs on   # 开启：加服务端入站、放行端口、重启 xray、更新订阅"
        echo -e "  ${MANAGE_CMD} hy2 obfs off  # 关闭：移除入站并从订阅中去掉（防火墙规则保留）"
      elif [[ "$key" == masque ]]; then
        echo -e "  ${MANAGE_CMD} masque on     # 开启：加服务端入站、放行端口、重启 xray、更新订阅"
        echo -e "  ${MANAGE_CMD} masque off    # 关闭：移除入站并从订阅中去掉（防火墙规则保留）"
      else
        echo -e "  ${MANAGE_CMD} ${key} on     # 开启：加服务端入站、放行端口、重启 xray、更新订阅"
        echo -e "  ${MANAGE_CMD} ${key} off    # 关闭：移除入站并从订阅中去掉（防火墙规则保留）"
      fi
      echo ""
      ;;
    on)
      [[ "$cur" == true ]] && { info "${label} 已经是开启状态"; return 0; }
      backup_store_check
      [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存开关状态"
      if [[ ! -s "${ALL_STORE_DIR}/inbound-${key}.json" ]]; then
        if [[ "$key" == masque ]]; then
          mkdir -p "${ALL_STORE_DIR}"
          render_masque_inbound > "${ALL_STORE_DIR}/inbound-masque.json"
          chmod 600 "${ALL_STORE_DIR}/inbound-masque.json"
        else
          fail "备用节点库缺少 inbound-${key}.json，需用最新安装命令重新部署"
        fi
      fi
      [[ -s /etc/ssl/private/fullchain.cer ]] || fail "未找到证书 /etc/ssl/private/fullchain.cer，无法开启直连类节点"
      if [[ "$key" == hy2obfs ]]; then
        [[ "${FEATURE_HY2:-false}" == true ]] || fail "Hysteria2 总开关未开启，不能开混淆节点。先执行：${MANAGE_CMD} hy2 on"
        [[ "${FEATURE_PORT_HOPPING:-false}" != true ]] || fail "本机开着端口跳跃（FEATURE_PORT_HOPPING），该开关暂不处理跳跃规则"
      fi
      backup_port_busy "$proto" "$port" && fail "${proto^^} ${port} 已被其他进程占用，未做任何修改"
      info "正在开启 ${label} ..."
      backup_node_sync_files "$name" on || fail "更新客户端文件失败，未改动服务端（原因见上）"
      backup_inbound_edit "$key" on "$port"; rc=$?
      if [[ $rc -ne 0 && $rc -ne 3 ]]; then
        backup_node_sync_files "$name" off >/dev/null 2>&1 || true
        fail "服务端入站写入失败，已撤销客户端文件改动"
      fi
      if ! update_node_env "$flag" "true" || ! grep -qE "^${flag}='?true'?\$" "$NODE_ENV_FILE"; then
        backup_inbound_edit "$key" off "$port" >/dev/null 2>&1 || true
        backup_node_sync_files "$name" off >/dev/null 2>&1 || true
        fail "无法写入 ${NODE_ENV_FILE}，已撤销本次改动"
      fi
      export "$flag"=true
      if [[ "$key" == hy2obfs ]]; then backup_open_port udp "$port" qdos; else backup_open_port "$proto" "$port"; fi
      info "${label} 已开启（${proto^^} ${port}）。云厂商安全组 / 安全列表需自行放行该端口。"
      cmd_resub
      ;;
    off)
      [[ "$cur" == true ]] || { info "${label} 本来就是关闭状态"; return 0; }
      [[ "$key" != hy2obfs || "${FEATURE_PORT_HOPPING:-false}" != true ]] || fail "本机开着端口跳跃，关闭混淆节点会留下跳跃规则，请先手动处理 FEATURE_PORT_HOPPING"
      backup_store_check
      info "正在关闭 ${label} ..."
      backup_inbound_edit "$key" off "$port"; rc=$?
      [[ $rc -eq 0 || $rc -eq 3 ]] || fail "移除服务端入站失败（原因见上），未改动客户端文件和标志位"
      backup_node_sync_files "$name" off || warn "服务端入站已移除，但客户端文件没有同步（原因见上）。请手动检查 client-config.txt 与订阅"
      update_node_env "$flag" "false"
      export "$flag"=false
      info "${label} 已关闭"
      cmd_resub
      ;;
    *) echo "用法: ${MANAGE_CMD} ${key} [show|on|off]" ;;
  esac
}

cmd_h2direct() { cmd_backup_server_node h2direct "$@"; }
cmd_hy2obfs()  { cmd_hy2 obfs "$@"; }

render_masque_inbound() {
  cat <<MASQUEEOF
,
        {
            "listen": "0.0.0.0",
            "port": ${MASQUE_PORT:-8447},
            "protocol": "masque",
            "settings": {
                "users": [
                    {
                        "email": "user@${CDN_DOMAIN:-example.com}",
                        "pass": "${MASQUE_PASSWORD:-${UUID2}}",
                        "level": 0
                    }
                ],
                "address": [
                    "10.13.0.1/24",
                    "fd13::1/64"
                ],
                "mtu": 1400
            },
            "streamSettings": {
                "network": "masque",
                "security": "tls",
                "tlsSettings": {
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "rejectUnknownSni": true,
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE:-/etc/ssl/private/fullchain.cer}",
                            "keyFile": "${CERT_KEY:-/etc/ssl/private/private.key}"
                        }
                    ],
                    "alpn": ["h3", "h2"]
                },
                "sockopt": {
                    "tcpcongestion": "bbr"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
MASQUEEOF
}

cmd_masque() {
  local subcmd="${1:-show}" port="${MASQUE_PORT:-8447}"
  case "$subcmd" in
    show|status)
      echo ""
      echo -e "${CYAN}=== MASQUE 标准 L3 隧道 (RFC 9484 CONNECT-IP) ===${NC}"
      if [[ "${FEATURE_MASQUE:-false}" == true ]]; then
        echo -e "  MASQUE 隧道节点:      ${GREEN}已开启${NC}  (UDP/TCP ${port}，alpn: h3,h2)"
      else
        echo -e "  MASQUE 隧道节点:      ${YELLOW}未开启${NC}  (开启后监听 UDP/TCP ${port})"
      fi
      echo -e "  认证邮箱:             user@${CDN_DOMAIN:-example.com}"
      echo -e "  内网虚拟 IP 池:       10.13.0.1/24, fd13::1/64"
      echo -e "  协议标准:             IETF RFC 9484 (CONNECT-IP) / RFC 8441 Extended CONNECT"
      echo ""
      echo -e "  常用指令:"
      echo -e "    ${MANAGE_CMD} masque on            # 开启 MASQUE 隧道节点（UDP/TCP ${port}）"
      echo -e "    ${MANAGE_CMD} masque off           # 关闭 MASQUE 隧道节点"
      echo ""
      ;;
    on)
      cmd_backup_server_node masque on
      ;;
    off)
      cmd_backup_server_node masque off
      ;;
    *)
      echo "用法: ${MANAGE_CMD} masque [show|on|off]"
      ;;
  esac
}

# Hysteria2 直连与混淆节点统一管理（UDP 随机高端口）
cmd_hy2() {
  local subcmd="${1:-show}" port="${HY2_H3_PORT:-}" obfs_port="${HY2_PORT:-}" rc
  [[ -z "$port" ]] && port="未设置"
  [[ -z "$obfs_port" ]] && obfs_port="未设置"

  case "$subcmd" in
    obfs)
      shift
      cmd_backup_server_node hy2obfs "${1:-show}"
      ;;
    show|status)
      echo ""
      echo -e "${CYAN}=== Hysteria2 节点与混淆管理 ===${NC}"
      if [[ "${FEATURE_HY2:-false}" == true && "${FEATURE_HY2_H3:-false}" == true ]]; then
        echo -e "  Hysteria2 直连节点:   ${GREEN}已开启${NC}  (UDP ${port}，随机端口)"
      else
        echo -e "  Hysteria2 直连节点:   ${YELLOW}未开启${NC}  (开启后监听 UDP ${port})"
      fi
      if [[ "${FEATURE_HY2_OBFS:-false}" == true ]]; then
        echo -e "  Hysteria2 混淆节点:   ${GREEN}已开启${NC}  (UDP ${obfs_port}，salamander 混淆)"
      else
        echo -e "  Hysteria2 混淆节点:   ${YELLOW}未开启${NC}  (开启后监听 UDP ${obfs_port})"
      fi
      echo ""
      echo -e "  常用指令:"
      echo -e "    ${MANAGE_CMD} hy2 on            # 开启 Hysteria2 直连节点（UDP ${port}）"
      echo -e "    ${MANAGE_CMD} hy2 off           # 关闭全部 Hysteria2 节点（直连与混淆）"
      echo -e "    ${MANAGE_CMD} hy2 obfs on       # 开启 Hysteria2 混淆节点（UDP ${obfs_port}）"
      echo -e "    ${MANAGE_CMD} hy2 obfs off      # 关闭 Hysteria2 混淆节点"
      echo ""
      ;;
    on)
      if [[ "${FEATURE_HY2:-false}" == true && "${FEATURE_HY2_H3:-false}" == true ]]; then info "Hysteria2 已经是开启状态"; return 0; fi
      backup_store_check
      [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存开关状态"
      [[ -s "${ALL_STORE_DIR}/inbound-hy2h3.json" ]] || fail "备用节点库缺少 inbound-hy2h3.json，需用最新安装命令重新部署"
      [[ -s /etc/ssl/private/fullchain.cer ]] || fail "未找到证书 /etc/ssl/private/fullchain.cer，无法开启 Hysteria2"
      [[ -n "${HY2_PASSWORD:-}" ]] || fail "node.env 里没有 HY2_PASSWORD，无法开启 Hysteria2"
      backup_port_busy udp "$port" && fail "UDP ${port} 已被其他进程占用，未做任何修改"
      info "正在开启 Hysteria2 直连节点 ..."
      backup_node_sync_files "Hysteria2-H3-Direct" on || fail "更新客户端文件失败，未改动服务端（原因见上）"
      backup_inbound_edit hy2h3 on "tag:hy2-h3"; rc=$?
      if [[ $rc -ne 0 && $rc -ne 3 ]]; then
        backup_node_sync_files "Hysteria2-H3-Direct" off >/dev/null 2>&1 || true
        fail "服务端入站写入失败，已撤销客户端文件改动"
      fi
      if ! update_node_env FEATURE_HY2 true || ! update_node_env FEATURE_HY2_H3 true \
         || ! grep -qE "^FEATURE_HY2_H3='?true'?\$" "$NODE_ENV_FILE"; then
        backup_inbound_edit hy2h3 off "tag:hy2-h3" >/dev/null 2>&1 || true
        backup_node_sync_files "Hysteria2-H3-Direct" off >/dev/null 2>&1 || true
        fail "无法写入 ${NODE_ENV_FILE}，已撤销本次改动"
      fi
      export FEATURE_HY2=true FEATURE_HY2_H3=true
      backup_open_port udp "$port" qdos
      info "Hysteria2 直连节点已开启（UDP ${port}）。云厂商安全组 / 安全列表需自行放行该端口。"
      cmd_resub
      ;;
    off)
      if [[ "${FEATURE_HY2:-false}" != true && "${FEATURE_HY2_H3:-false}" != true ]]; then info "Hysteria2 本来就是关闭状态"; return 0; fi
      backup_store_check
      if [[ "${FEATURE_HY2_OBFS:-false}" == true ]]; then
        info "混淆节点依附于 Hysteria2，先一并关闭 ..."
        cmd_backup_server_node hy2obfs off
      fi
      info "正在关闭 Hysteria2 ..."
      backup_inbound_edit hy2h3 off "tag:hy2-h3"; rc=$?
      [[ $rc -eq 0 || $rc -eq 3 ]] || fail "移除服务端入站失败（原因见上），未改动客户端文件和标志位"
      backup_node_sync_files "Hysteria2-H3-Direct" off || warn "服务端入站已移除，但客户端文件没有同步（原因见上）。请手动检查 client-config.txt 与订阅"
      update_node_env FEATURE_HY2 false
      update_node_env FEATURE_HY2_H3 false
      export FEATURE_HY2=false FEATURE_HY2_H3=false
      info "Hysteria2 已关闭"
      cmd_resub
      ;;
    obfs-on) cmd_backup_server_node hy2obfs on ;;
    obfs-off) cmd_backup_server_node hy2obfs off ;;
    *) echo "用法: ${MANAGE_CMD} hy2 [show|on|off|obfs on|obfs off]" ;;
  esac
}

render_xdrive_inbound() {
  cat <<XDRIVEEOF
,
        {
            "tag": "vless-xdrive",
            "port": 0,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID2}",
                        "level": 0
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xdrive",
                "xdriveSettings": {
                    "service": "Google Drive",
                    "remoteFolder": "${XDRIVE_FOLDER:-unknown}",
                    "secrets": [
                        "${XDRIVE_CLIENT_ID:-unknown}",
                        "${XDRIVE_CLIENT_SECRET:-unknown}",
                        "${XDRIVE_REFRESH_TOKEN:-unknown}"
                    ]
                }
            }
        }
XDRIVEEOF
}

generate_xdrive_client_config() {
  local target="${USER_HOME:-/root}/xdrive-client.json"
  cat > "$target" <<XCEOF
{
    "remarks": "XDRIVE-Google-Drive",
    "outbounds": [
        {
            "tag": "proxy-xdrive",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "127.0.0.1",
                        "port": 0,
                        "users": [
                            {
                                "id": "${UUID2}",
                                "encryption": "none"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "xdrive",
                "xdriveSettings": {
                    "service": "Google Drive",
                    "remoteFolder": "${XDRIVE_FOLDER:-your_folder_id}",
                    "secrets": [
                        "${XDRIVE_CLIENT_ID:-your_client_id}",
                        "${XDRIVE_CLIENT_SECRET:-your_client_secret}",
                        "${XDRIVE_REFRESH_TOKEN:-your_refresh_token}"
                    ]
                }
            }
        }
    ]
}
XCEOF
  chmod 600 "$target" 2>/dev/null || true
  chown "$(stat -c '%u:%g' "${USER_HOME:-/root}")" "$target" 2>/dev/null || true
}

# XDRIVE 网盘穿透代理管理 (Google Drive)
cmd_xdrive() {
  local subcmd="${1:-show}" rc
  case "$subcmd" in
    show|status)
      echo ""
      echo -e "${CYAN}=== XDRIVE 网盘穿透代理 (Google Drive) ===${NC}"
      if [[ "${FEATURE_XDRIVE:-false}" == true ]]; then
        echo -e "  XDRIVE 网盘代理:      ${GREEN}已开启${NC}  (零公网 IP / 极端白名单网络穿透)"
      else
        echo -e "  XDRIVE 网盘代理:      ${YELLOW}未开启${NC}"
      fi
      echo -e "  云存储服务类型:       Google Drive (原生 HTTP API，无需第三方 SDK)"
      echo -e "  远程中转目录 ID:      ${XDRIVE_FOLDER:-未配置}"
      if [[ -n "${XDRIVE_CLIENT_ID:-}" ]]; then
        local masked_cid="${XDRIVE_CLIENT_ID:0:8}***.apps.googleusercontent.com"
        echo -e "  OAuth Client ID:      ${masked_cid}"
      else
        echo -e "  OAuth Client ID:      未配置"
      fi
      echo -e "  客户端配置示例:       ${USER_HOME:-/root}/xdrive-client.json"
      echo ""
      echo -e "  使用说明与提示 (Google zhoushj6@gmail.com):"
      echo -e "    1. 在 Google Cloud Console 创建 OAuth 2.0 Client ID (类型选桌面应用或 Web)"
      echo -e "    2. 在 Google Drive 新建一个中转文件夹，获取 URL 中的 folderId"
      echo -e "    3. 获取 OAuth Refresh Token 并运行: ${MANAGE_CMD} xdrive setup 进行配置"
      echo ""
      echo -e "  常用指令:"
      echo -e "    ${MANAGE_CMD} xdrive show          # 查看 XDRIVE 状态与配置"
      echo -e "    ${MANAGE_CMD} xdrive setup         # 交互式配置 Google Drive 凭据"
      echo -e "    ${MANAGE_CMD} xdrive on            # 开启 XDRIVE 网盘穿透代理入站"
      echo -e "    ${MANAGE_CMD} xdrive off           # 关闭 XDRIVE 网盘穿透代理入站"
      echo ""
      ;;
    setup)
      echo ""
      echo -e "${CYAN}=== 配置 XDRIVE Google Drive 网盘穿透凭证 ===${NC}"
      echo "提示: 请先在 Google Cloud Console 创建 OAuth 2.0 桌面客户端，并在 Google Drive 新建中转目录。"
      read -rp "请输入 Google Drive 中转目录 ID (Folder ID) [${XDRIVE_FOLDER:-}]: " folder
      [[ -z "$folder" ]] && folder="${XDRIVE_FOLDER:-}"
      read -rp "请输入 Google OAuth Client ID [${XDRIVE_CLIENT_ID:-}]: " cid
      [[ -z "$cid" ]] && cid="${XDRIVE_CLIENT_ID:-}"
      read -rp "请输入 Google OAuth Client Secret: " csec
      [[ -z "$csec" ]] && csec="${XDRIVE_CLIENT_SECRET:-}"
      read -rp "请输入 Google OAuth Refresh Token: " rtok
      [[ -z "$rtok" ]] && rtok="${XDRIVE_REFRESH_TOKEN:-}"

      if [[ -z "$folder" || -z "$cid" || -z "$csec" || -z "$rtok" ]]; then
        fail "所有 4 项凭据均不能为空！"
      fi

      update_node_env XDRIVE_FOLDER "$folder"
      update_node_env XDRIVE_CLIENT_ID "$cid"
      update_node_env XDRIVE_CLIENT_SECRET "$csec"
      update_node_env XDRIVE_REFRESH_TOKEN "$rtok"
      export XDRIVE_FOLDER="$folder" XDRIVE_CLIENT_ID="$cid" XDRIVE_CLIENT_SECRET="$csec" XDRIVE_REFRESH_TOKEN="$rtok"

      mkdir -p "${ALL_STORE_DIR}"
      render_xdrive_inbound > "${ALL_STORE_DIR}/inbound-xdrive.json"
      chmod 600 "${ALL_STORE_DIR}/inbound-xdrive.json"

      generate_xdrive_client_config

      info "Google Drive 凭据配置成功并已保存！"
      if [[ "${FEATURE_XDRIVE:-false}" == true ]]; then
        info "正在重新加载线上 XDRIVE 配置 ..."
        backup_inbound_edit xdrive off "tag:vless-xdrive" >/dev/null 2>&1 || true
        backup_inbound_edit xdrive on "tag:vless-xdrive"
      else
        info "可运行 ${MANAGE_CMD} xdrive on 开启入站"
      fi
      ;;
    on)
      if [[ "${FEATURE_XDRIVE:-false}" == true ]]; then info "XDRIVE 网盘代理已经是开启状态"; return 0; fi
      if [[ -z "${XDRIVE_FOLDER:-}" || "${XDRIVE_FOLDER:-}" == "unknown" || -z "${XDRIVE_CLIENT_ID:-}" || "${XDRIVE_CLIENT_ID:-}" == "unknown" || -z "${XDRIVE_CLIENT_SECRET:-}" || "${XDRIVE_CLIENT_SECRET:-}" == "unknown" || -z "${XDRIVE_REFRESH_TOKEN:-}" || "${XDRIVE_REFRESH_TOKEN:-}" == "unknown" ]]; then
        warn "XDRIVE 凭据尚未完整配置，现在进入交互式配置："
        cmd_xdrive setup || return 1
      fi
      backup_store_check
      [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存开关状态"
      [[ -s "${ALL_STORE_DIR}/inbound-xdrive.json" ]] || {
        mkdir -p "${ALL_STORE_DIR}"
        render_xdrive_inbound > "${ALL_STORE_DIR}/inbound-xdrive.json"
        chmod 600 "${ALL_STORE_DIR}/inbound-xdrive.json"
      }
      info "正在开启 XDRIVE 网盘穿透代理 ..."
      backup_inbound_edit xdrive on "tag:vless-xdrive"; rc=$?
      if [[ $rc -ne 0 && $rc -ne 3 ]]; then
        fail "服务端入站写入失败，未改动配置"
      fi
      update_node_env FEATURE_XDRIVE true
      export FEATURE_XDRIVE=true
      generate_xdrive_client_config
      info "XDRIVE 网盘穿透入站已开启（tag: vless-xdrive）。"
      info "客户端配置文件已生成: ${USER_HOME:-/root}/xdrive-client.json"
      ;;
    off)
      if [[ "${FEATURE_XDRIVE:-false}" != true ]]; then info "XDRIVE 网盘代理本来就是关闭状态"; return 0; fi
      backup_store_check
      info "正在关闭 XDRIVE 网盘穿透代理 ..."
      backup_inbound_edit xdrive off "tag:vless-xdrive"; rc=$?
      [[ $rc -eq 0 || $rc -eq 3 ]] || fail "移除服务端入站失败"
      update_node_env FEATURE_XDRIVE false
      export FEATURE_XDRIVE=false
      info "XDRIVE 网盘穿透代理已关闭"
      ;;
    *)
      echo "用法: ${MANAGE_CMD} xdrive [show|setup|on|off]"
      ;;
  esac
}

render_hy2_obfs_inbound() {
  cat <<HY2EOF
,
        {
            "listen": "0.0.0.0",
            "port": ${HY2_PORT},
            "protocol": "hysteria",
            "settings": {
                "version": 2,
                "clients": [
                    {
                        "auth": "${HY2_PASSWORD}",
                        "level": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "hysteria",
                "security": "tls",
                "tlsSettings": {
                    "alpn": ["h3"],
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "cipherSuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                    "rejectUnknownSni": true,
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE:-/etc/ssl/private/fullchain.cer}",
                            "keyFile": "${CERT_KEY:-/etc/ssl/private/private.key}"
                        }
                    ]
                },
                "hysteriaSettings": {
                    "version": 2,
                    "udpIdleTimeout": 60,
                    "masquerade": {
                        "type": "proxy",
                        "url": "https://127.0.0.1:8003",
                        "rewriteHost": false,
                        "insecure": true
                    }
                },
                "sockopt": {
                    "tcpFastOpen": true,
                    "tcpcongestion": "brutal"
                },
                "finalmask": {
                    "udp": [
$(if [[ "${FEATURE_NOISE_EXP:-false}" == true ]]; then cat <<NEOF
                        {
                            "type": "noise",
                            "settings": {
                                "noise": [
                                    {
                                        "type": "exp",
                                        "packet": "${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>}",
                                        "delay": "${NOISE_EXP_DELAY:-10-50}"
                                    }
                                ]
                            }
                        },
NEOF
fi)
                        {
                            "type": "salamander",
                            "settings": {
                                "password": "${OBFS_PASSWORD}"
                            }
                        }
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
HY2EOF
}

render_hy2_h3_inbound() {
  cat <<HY2H3EOF
,
        {
            "listen": "0.0.0.0",
            "tag": "hy2-h3",
            "port": ${HY2_H3_PORT:-443},
            "protocol": "hysteria",
            "settings": {
                "version": 2,
                "clients": [
                    {
                        "auth": "${HY2_PASSWORD}",
                        "level": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "hysteria",
                "security": "tls",
                "tlsSettings": {
                    "alpn": ["h3"],
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "cipherSuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                    "rejectUnknownSni": true,
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE:-/etc/ssl/private/fullchain.cer}",
                            "keyFile": "${CERT_KEY:-/etc/ssl/private/private.key}"
                        }
                    ]
                },
                "hysteriaSettings": {
                    "version": 2,
                    "udpIdleTimeout": 60,
                    "masquerade": {
                        "type": "proxy",
                        "url": "https://127.0.0.1:8003",
                        "rewriteHost": false,
                        "insecure": true
                    }
                },
                "sockopt": {
                    "tcpFastOpen": true,
                    "tcpcongestion": "brutal"
                }$(if [[ "${FEATURE_NOISE_EXP:-false}" == true ]]; then cat <<NEOF
,
                "finalmask": {
                    "udp": [
                        {
                            "type": "noise",
                            "settings": {
                                "noise": [
                                    {
                                        "type": "exp",
                                        "packet": "${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>}",
                                        "delay": "${NOISE_EXP_DELAY:-10-50}"
                                    }
                                ]
                            }
                        }
                    ]
                }
NEOF
fi)
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
HY2H3EOF
}

# 让客户端链接里的 Hysteria2 fm 参数与 Noise 开关一致：开启时在 quicParams 之后的 udp 数组最前面放 noise 项，
# 关闭时去掉；保留已有的 salamander 项与 quicParams，其余链接一行不动。改 client-config.txt 与备用节点库里的那份。
# 此前 xh noise on/off/set 只改了服务端入站与备用节点库的入站文本，链接没跟着变，开关和链接就不一致。
sync_noise_links() {
  local home="" candidate files=() f
  if [[ -n "${USER_HOME:-}" && -f "${USER_HOME}/client-config.txt" ]]; then
    home="$USER_HOME"
  else
    for candidate in /home/ubuntu /home/opc /root; do
      [[ -f "${candidate}/client-config.txt" ]] && { home="$candidate"; break; }
    done
  fi
  [[ -n "$home" ]] && files+=("${home}/client-config.txt")
  [[ -f "${ALL_STORE_DIR}/client-config.txt" ]] && files+=("${ALL_STORE_DIR}/client-config.txt")
  [[ ${#files[@]} -gt 0 ]] || { warn "没找到 client-config.txt，链接未同步"; return 0; }
  for f in "${files[@]}"; do
    python3 - "$f" "$([[ "${FEATURE_NOISE_EXP:-false}" == true && "${FEATURE_NOISE_LINKS:-false}" == true ]] && echo true || echo false)" "${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>}" "${NOISE_EXP_DELAY:-10-50}" <<'NLPY' || warn "同步 ${f} 里的 Noise 链接参数失败"
import json, os, re, sys
from urllib.parse import quote, unquote

path, enabled, packet, delay = sys.argv[1:5]
enabled = (enabled == 'true')
text = open(path, encoding='utf-8').read()
out = []
changed = False
for line in text.split('\n'):
    if line.startswith('hysteria2://') and '&fm=' in line:
        m = re.search(r'&fm=([^&#]*)', line)
        try:
            fm = json.loads(unquote(m.group(1)))
        except ValueError:
            out.append(line); continue
        udp = [x for x in fm.get('udp', []) if x.get('type') != 'noise']
        if enabled:
            udp.insert(0, {"type": "noise", "settings": {"noise": [{"type": "exp", "packet": packet, "delay": delay}]}})
        new = {"quicParams": fm.get("quicParams", {})}
        if udp:
            new["udp"] = udp
        enc = quote(json.dumps(new, separators=(',', ':'), ensure_ascii=False), safe='')
        line2 = line[:m.start(1)] + enc + line[m.end(1):]
        if line2 != line:
            changed = True
        line = line2
    out.append(line)
if changed:
    tmp = path + '.xh-new'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out))
    st = os.stat(path)
    os.chmod(tmp, st.st_mode & 0o7777)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.replace(tmp, path)
NLPY
  done
}

sync_noise_live_config() {
  local tmp="${XRAY_CONF%.json}.bk-tmp.json" bak="${XRAY_CONF}.bk.bak"
  [[ -f "$XRAY_CONF" ]] || return 0
  python3 - "$XRAY_CONF" "$tmp" "${ALL_STORE_DIR}" <<'NPY'
import sys, os

src, dst, store_dir = sys.argv[1:4]
s = open(src, encoding='utf-8').read()
changed = False

for key in ['hy2h3', 'hy2obfs']:
    begin = '        // >>xh:' + key
    end = '        // <<xh:' + key
    sf = os.path.join(store_dir, 'inbound-%s.json' % key)
    if begin in s and end in s and os.path.isfile(sf):
        a = s.index('\n' + begin)
        b = s.index(end, a) + len(end)
        text = open(sf, encoding='utf-8').read().rstrip('\n')
        s = s[:a] + '\n' + begin + '\n' + text + '\n' + end + s[b:]
        changed = True

if not changed:
    sys.exit(3)
open(dst, 'w', encoding='utf-8').write(s)
NPY
  local rc=$?
  if [[ $rc -eq 3 ]]; then
    return 0
  elif [[ $rc -ne 0 ]]; then
    rm -f "$tmp"; warn "替换 Noise 配置失败"; return 1
  fi

  if ! err=$("$XRAY_BIN" -test -format json -config "$tmp" 2>&1); then
    rm -f "$tmp"; warn "Xray 配置校验失败，已放弃修改：$err"; return 1
  fi
  cp -a "$XRAY_CONF" "$bak"
  mv -f "$tmp" "$XRAY_CONF"
  if ! svc restart xray; then
    cp -a "$bak" "$XRAY_CONF"
    svc restart xray >/dev/null 2>&1 || true
    warn "重启 Xray 失败，已回滚"
    return 1
  fi
  return 0
}

# Finalmask Noise 动态混淆管理 (Xray v26.9.30+)
cmd_noise() {
  local subcmd="${1:-show}" cur="${FEATURE_NOISE_EXP:-false}"
  local cur_pkt="${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>}"
  local cur_delay="${NOISE_EXP_DELAY:-10-50}"
  case "$subcmd" in
    show|status)
      echo ""
      echo -e "${CYAN}=== Finalmask Noise 动态混淆 (Xray v26.9.30+) ===${NC}"
      if [[ "$cur" == true ]]; then
        echo -e "  Noise 动态混淆:       ${GREEN}已开启${NC}"
      else
        echo -e "  Noise 动态混淆:       ${YELLOW}未开启${NC}"
      fi
      echo -e "  混淆数据包表达式:     ${CYAN}${cur_pkt}${NC}"
      echo -e "  延迟范围 (毫秒):      ${CYAN}${cur_delay}${NC}"
      echo ""
      echo -e "  支持的动态表达式标签 (AWG 风格):"
      echo -e "    <b hex>   指定十六进制字节（例如: <b 16030100> 伪造 TLS ClientHello 头）"
      echo -e "    <r N>     N 个随机字节（例如: <r 32> 伪造 32 字节 Session ID）"
      echo -e "    <rc>      随机英文字母"
      echo -e "    <rd N>    N 个随机十进制数字"
      echo -e "    <t>       4 字节时间戳"
      echo -e "    <c>       递增计数器"
      echo -e "    <n>       8 字节随机 Nonce"
      echo ""
      echo -e "  常用指令:"
      echo -e "    ${MANAGE_CMD} noise on                 # 开启 Noise 动态混淆"
      echo -e "    ${MANAGE_CMD} noise off                # 关闭 Noise 动态混淆"
      echo -e "    ${MANAGE_CMD} noise set \"<exp>\" [延时]  # 自定义混淆模板与延时"
      echo -e "    ${MANAGE_CMD} noise sync               # 只按当前开关把客户端链接对齐（不重启 Xray）"
      echo -e "    ${MANAGE_CMD} noise links on|off       # 链接里是否带 noise（默认不带；需要客户端内核 >= 26.9.30）"
      echo ""
      ;;
    on)
      if [[ "$cur" == true ]]; then info "Noise 动态混淆已经是开启状态"; return 0; fi
      backup_store_check
      [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存开关状态"
      info "正在开启 Noise 动态混淆 ..."
      update_node_env FEATURE_NOISE_EXP true
      export FEATURE_NOISE_EXP=true
      mkdir -p "${ALL_STORE_DIR}"
      render_hy2_obfs_inbound > "${ALL_STORE_DIR}/inbound-hy2obfs.json"
      render_hy2_h3_inbound   > "${ALL_STORE_DIR}/inbound-hy2h3.json"
      chmod 600 "${ALL_STORE_DIR}"/inbound-hy2*.json 2>/dev/null || true
      sync_noise_live_config
      sync_noise_links
      info "Noise 动态混淆已开启！"
      cmd_resub
      ;;
    off)
      if [[ "$cur" != true ]]; then info "Noise 动态混淆本来就是关闭状态"; return 0; fi
      backup_store_check
      info "正在关闭 Noise 动态混淆 ..."
      update_node_env FEATURE_NOISE_EXP false
      export FEATURE_NOISE_EXP=false
      mkdir -p "${ALL_STORE_DIR}"
      render_hy2_obfs_inbound > "${ALL_STORE_DIR}/inbound-hy2obfs.json"
      render_hy2_h3_inbound   > "${ALL_STORE_DIR}/inbound-hy2h3.json"
      chmod 600 "${ALL_STORE_DIR}"/inbound-hy2*.json 2>/dev/null || true
      sync_noise_live_config
      sync_noise_links
      info "Noise 动态混淆已关闭"
      cmd_resub
      ;;
    set)
      shift
      local new_pkt="${1:-}" new_delay="${2:-10-50}"
      [[ -z "$new_pkt" ]] && new_pkt="<b 16030100><r 32><t><c><rd 8>"
      backup_store_check
      [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存状态"
      info "正在更新 Noise 混淆模板: packet=${new_pkt}, delay=${new_delay} ..."
      update_node_env NOISE_EXP_PACKET "$new_pkt"
      update_node_env NOISE_EXP_DELAY "$new_delay"
      export NOISE_EXP_PACKET="$new_pkt" NOISE_EXP_DELAY="$new_delay"
      mkdir -p "${ALL_STORE_DIR}"
      render_hy2_obfs_inbound > "${ALL_STORE_DIR}/inbound-hy2obfs.json"
      render_hy2_h3_inbound   > "${ALL_STORE_DIR}/inbound-hy2h3.json"
      chmod 600 "${ALL_STORE_DIR}"/inbound-hy2*.json 2>/dev/null || true
      if [[ "${FEATURE_NOISE_EXP:-false}" == true ]]; then
        sync_noise_live_config
      fi
      sync_noise_links
      info "Noise 混淆模板已更新！"
      cmd_resub
      ;;
    links)
      # 链接里是否带 noise：服务端 noise 开着也可以不带（老客户端不受影响）。noise.exp 需要客户端内核 >= 26.9.30。
      case "${2:-show}" in
        show|status)
          echo -e "  链接里带 noise:       $([[ "${FEATURE_NOISE_LINKS:-false}" == true ]] && echo "${GREEN}是${NC}" || echo "${YELLOW}否（默认，兼容老内核）${NC}")"
          echo -e "  ${MANAGE_CMD} noise links on|off   # 需要客户端内核 >= 26.9.30，否则 v2rayN 会报「运行内核失败」"
          ;;
        on)
          [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存状态"
          warn "链接里的 noise.exp 需要客户端 Xray 内核 >= 26.9.30；v2rayN 自带内核更老时 Hysteria2 节点会「运行内核失败」"
          update_node_env FEATURE_NOISE_LINKS true; export FEATURE_NOISE_LINKS=true
          sync_noise_links; info "已让 Hysteria2 链接带上 noise"; cmd_resub ;;
        off)
          [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存状态"
          update_node_env FEATURE_NOISE_LINKS false; export FEATURE_NOISE_LINKS=false
          sync_noise_links; info "已去掉 Hysteria2 链接里的 noise（服务端 noise 不变，不重启 Xray）"; cmd_resub ;;
        *) echo "用法: ${MANAGE_CMD} noise links [show|on|off]" ;;
      esac
      ;;
    sync)
      # 只按当前开关把客户端链接的 fm 对齐（不动服务端、不重启 Xray）
      sync_noise_links
      info "已按当前 Noise 开关（${cur}）同步客户端链接"
      cmd_resub
      ;;
    *)
      echo "用法: ${MANAGE_CMD} noise [show|on|off|links|sync|set <packet> [delay]]"
      ;;
  esac
}

# ==================================================
# Reality 节点管理（xh reality）：Vision / XHTTP 两个直连节点的服务端 + 订阅开关，上下行分离节点转给 xh split
# ==================================================
# 443 的 Reality 入站始终保留（CDN 域名的回源要靠它的 target）；开关只增删入站里的两项：
#   vision：clients 里的 UUID1 + flow（xh:realityvision 标记块）
#   xhttp ：fallbacks 里指向 8001 的那一项（xh:realityxhttp 标记块）
# 已安装的老机器配置里没有标记：关闭时按结构找到那一项直接删掉，开启时再写成带标记的块。
# 返回 0 = 已改并重启成功，3 = 无需改动，其余 = 失败（已回滚，原因已打印）。
reality_server_edit() {
  local key="$1" act="$2" tmp="${XRAY_CONF%.json}.bk-tmp.json" bak="${XRAY_CONF}.bk.bak" rc err
  [[ -f "$XRAY_CONF" ]] || { backup_error "未找到 Xray 配置文件: $XRAY_CONF"; return 1; }
  python3 - "$XRAY_CONF" "$tmp" "$key" "$act" "${UUID1:-}" "${VISION_FLOW:-xtls-rprx-vision}" <<'RSPY'
import re, sys

src, dst, key, act, uuid1, flow = sys.argv[1:7]
s = open(src, encoding='utf-8').read()
tag = 'reality' + key
begin = '        // >>xh:' + tag
end = '        // <<xh:' + tag
if key == 'vision':
    arr = '"clients"'
    if not uuid1:
        sys.stderr.write('node.env 里没有 UUID1\n'); sys.exit(1)
    obj = ('                    {\n'
           '                        "id": "%s",\n'
           '                        "level": 0,\n'
           '                        "flow": "%s"\n'
           '                    }') % (uuid1, flow)
    ident = uuid1
else:
    arr = '"fallbacks"'
    obj = ('                    {\n'
           '                        "dest": "127.0.0.1:8001",\n'
           '                        "xver": 0\n'
           '                    }')
    ident = '127.0.0.1:8001'

def skip_ws_comments(t, i):
    n = len(t)
    while i < n:
        if t[i] in ' \t\r\n':
            i += 1
        elif t.startswith('//', i):
            while i < n and t[i] != '\n':
                i += 1
        elif t.startswith('/*', i):
            i = t.index('*/', i) + 2
        else:
            break
    return i

def match_close(t, i):
    """t[i] 是 { 或 [，返回与之配对的 } / ] 的下标（跳过字符串与注释）。"""
    n, depth = len(t), 0
    while i < n:
        c = t[i]
        if c == '"':
            i += 1
            while i < n and t[i] != '"':
                i += 2 if t[i] == '\\' else 1
        elif t.startswith('//', i):
            while i < n and t[i] != '\n':
                i += 1
            continue
        elif t.startswith('/*', i):
            i = t.index('*/', i) + 2
            continue
        elif c in '{[':
            depth += 1
        elif c in '}]':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

# 443 Reality 入站是 inbounds 里的第一项：取全文第一个 "clients" / "fallbacks" 数组
m = re.search(arr + r'\s*:\s*\[', s)
if not m:
    sys.stderr.write('没找到 %s 数组\n' % arr); sys.exit(1)
lb = m.end() - 1
rb = match_close(s, lb)
inner = s[lb + 1:rb]
has_marker = ('// >>xh:' + tag) in inner
has_obj = ident in inner

if act == 'off':
    if not has_obj:
        sys.exit(3)
    if has_marker:
        a = inner.index('\n' + begin)
        b = inner.index(end, a) + len(end)
        inner2 = inner[:a] + inner[b:]
    else:
        # 没有标记（老机器）：删掉数组里含 ident 的那个对象
        i = skip_ws_comments(inner, 0)
        removed = False
        while i < len(inner) and inner[i] == '{':
            j = match_close(inner, i)
            if ident in inner[i:j + 1]:
                k = i
                while k > 0 and inner[k - 1] in ' \t':
                    k -= 1
                if k > 0 and inner[k - 1] == '\n':
                    k -= 1
                e = j + 1
                if e < len(inner) and inner[e] == ',':
                    e += 1
                inner2 = inner[:k] + inner[e:]
                removed = True
                break
            i = skip_ws_comments(inner, j + 1)
            if i < len(inner) and inner[i] == ',':
                i = skip_ws_comments(inner, i + 1)
        if not removed:
            sys.stderr.write('没找到可删除的 %s 项\n' % ident); sys.exit(1)
else:
    if has_obj:
        sys.exit(3)
    if inner.strip():
        sys.stderr.write('%s 数组里已有其他内容，不自动插入\n' % arr); sys.exit(1)
    inner2 = '\n' + begin + '\n' + obj + '\n' + end + inner
s = s[:lb + 1] + inner2 + s[rb:]
open(dst, 'w', encoding='utf-8').write(s)
RSPY
  rc=$?
  [[ $rc -eq 3 ]] && return 3
  if [[ $rc -ne 0 ]]; then rm -f "$tmp"; backup_error "改写配置失败（代码 ${rc}），未做任何修改"; return 1; fi
  if ! err=$("$XRAY_BIN" -test -format json -config "$tmp" 2>&1); then
    rm -f "$tmp"; backup_error "Xray 配置校验失败，已放弃，未做任何修改。最后几行输出："; echo "$err" | tail -n 5 >&2; return 1
  fi
  cp -a "$XRAY_CONF" "$bak"
  chown --reference="$XRAY_CONF" "$tmp" 2>/dev/null || true
  chmod --reference="$XRAY_CONF" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$XRAY_CONF" || { backup_error "无法替换 $XRAY_CONF"; return 1; }
  if ! svc restart xray; then
    cp -a "$bak" "$XRAY_CONF"
    if svc restart xray >/dev/null 2>&1; then
      backup_error "xray 重启失败，已回滚到修改前的配置并重新启动"
    else
      backup_error "xray 重启失败，回滚后也无法启动！请立即检查：journalctl -u xray -n 30"
    fi
    return 1
  fi
  return 0
}

# 单个 Reality 节点开关。$1 = vision|xhttp，$2 = on|off
# 顺序同其它备用节点：开启时先改订阅文件（原子），再改服务端，最后写标志位；任何一步失败都撤销前面的步骤。
reality_toggle() {
  local key="$1" act="$2" flag name label cur rc
  case "$key" in
    vision) flag=FEATURE_REALITY_VISION; name="VLESS-Reality-Vision-Direct"; label="Reality-Vision-Direct（xtls-rprx-vision）" ;;
    xhttp)  flag=FEATURE_REALITY_XHTTP;  name="VLESS-Reality-XHTTP-Direct";  label="Reality-XHTTP-Direct（XHTTP + vlessenc）" ;;
  esac
  cur="${!flag:-true}"
  backup_store_check
  [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存开关状态"
  if [[ "$act" == on ]]; then
    [[ "$cur" == true ]] && { info "${label} 已经是开启状态"; return 0; }
    info "正在开启 ${label} ..."
    backup_node_sync_files "$name" on || fail "更新订阅文件失败，未改动服务端（原因见上）"
    reality_server_edit "$key" on; rc=$?
    if [[ $rc -ne 0 && $rc -ne 3 ]]; then
      backup_node_sync_files "$name" off >/dev/null 2>&1 || true
      fail "服务端写入失败，已撤销订阅文件改动"
    fi
    if ! update_node_env "$flag" "true" || ! grep -qE "^${flag}='?true'?\$" "$NODE_ENV_FILE"; then
      reality_server_edit "$key" off >/dev/null 2>&1 || true
      backup_node_sync_files "$name" off >/dev/null 2>&1 || true
      fail "无法写入 ${NODE_ENV_FILE}，已撤销本次改动"
    fi
    export "$flag"=true
    info "${label} 已开启。xray 已重启，客户端需要更新订阅并重新连接。"
  else
    [[ "$cur" == true ]] || { info "${label} 本来就是关闭状态"; return 0; }
    # 两个 Reality 节点都关掉时，443 上只剩 CDN 回源的壳：允许，但要说一声
    local other_flag other_cur
    [[ "$key" == vision ]] && other_flag=FEATURE_REALITY_XHTTP || other_flag=FEATURE_REALITY_VISION
    other_cur="${!other_flag:-true}"
    [[ "$other_cur" == true ]] || warn "另一个 Reality 节点已经关了：关掉这个以后，443 上不再有可用的 Reality 节点（CDN 回源不受影响）"
    info "正在关闭 ${label} ..."
    reality_server_edit "$key" off; rc=$?
    [[ $rc -eq 0 || $rc -eq 3 ]] || fail "移除服务端项失败（原因见上），未改动订阅文件和标志位"
    backup_node_sync_files "$name" off || warn "服务端项已移除，但订阅文件没有同步（原因见上）。请手动检查 client-config.txt 与订阅"
    update_node_env "$flag" "false"
    export "$flag"=false
    info "${label} 已关闭。xray 已重启，客户端需要更新订阅。"
  fi
  cmd_resub
}

cmd_reality() {
  local what="${1:-show}" act="${2:-show}" v x u sid minv mtd
  case "$what" in
    show|status)
      v="${FEATURE_REALITY_VISION:-true}"; x="${FEATURE_REALITY_XHTTP:-true}"; u="${FEATURE_REALITY_UP_CDN_DOWN:-false}"
      sid="${SHORT_ID:-}"; [[ -n "$sid" ]] && sid="${sid:0:2}$(printf '%*s' $(( ${#sid} > 2 ? ${#sid} - 2 : 0 )) '' | tr ' ' '*')"
      minv=$(grep -o '"minClientVer"[[:space:]]*:[[:space:]]*"[^"]*"' "$XRAY_CONF" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
      mtd=$(grep -o '"maxTimeDiff"[[:space:]]*:[[:space:]]*[0-9]*' "$XRAY_CONF" 2>/dev/null | head -1 | grep -o '[0-9]*$')
      echo ""
      echo -e "${CYAN}=== Reality 节点 ===${NC}"
      printf '  %-30s %s\n' "VLESS-Reality-Vision-Direct" "$([[ "$v" == true ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${YELLOW}未开启${NC}")  TCP 443  xtls-rprx-vision      ${MANAGE_CMD} reality vision on|off"
      printf '  %-30s %s\n' "VLESS-Reality-XHTTP-Direct" "$([[ "$x" == true ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${YELLOW}未开启${NC}")  TCP 443  XHTTP + vlessenc       ${MANAGE_CMD} reality xhttp on|off"
      printf '  %-30s %s\n' "VLESS-Reality-Up-CDN-Down" "$([[ "$u" == true ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${YELLOW}未开启${NC}")  上行 Reality / 下行 CDN   ${MANAGE_CMD} reality updown on|off"
      echo ""
      echo -e "  伪装目标 target:   127.0.0.1:8003（本机 nginx，证书域名 ${REALITY_DOMAIN:-?}）"
      echo -e "  serverNames:       ${REALITY_DOMAIN:-?}、${CDN_DOMAIN:-?}"
      echo -e "  shortId:           ${sid:-?}（已隐藏）"
      if [[ -n "$minv" ]]; then
        echo -e "  minClientVer:      ${minv}    （${MANAGE_CMD} minversion）"
      else
        echo -e "  minClientVer:      ${YELLOW}未设置${NC}    （${MANAGE_CMD} minversion）"
        echo -e "    ${YELLOW}注意：Xray 26.9.x 的默认值是 26.3.27，Shadowrocket / sing-box / Mihomo / 老版本内核的 Reality 连接可能被拒；${NC}"
        echo -e "    ${YELLOW}需要兼容这些客户端时执行 ${MANAGE_CMD} minversion 1.8.0（会重启 xray）。${NC}"
      fi
      echo -e "  maxTimeDiff:       ${mtd:+${mtd} ms}${mtd:-未设置}    （${MANAGE_CMD} timediff）"
      echo -e "  说明: 443 入站始终保留（CDN 域名的回源要靠它）；vision / xhttp 开关会增删入站里对应的一项并重启 xray。"
      echo ""
      ;;
    vision|xhttp)
      case "$act" in
        on|off) reality_toggle "$what" "$act" ;;
        show|status|"") cmd_reality show ;;
        *) echo "用法: ${MANAGE_CMD} reality ${what} [on|off]" ;;
      esac
      ;;
    updown|split)
      case "$act" in
        on|off) cmd_split reality-up "$act" ;;
        *) cmd_split reality-up show ;;
      esac
      ;;
    *) echo "用法: ${MANAGE_CMD} reality [show | vision on|off | xhttp on|off | updown on|off]" ;;
  esac
}

# 上下行分离两条（纯客户端链接，不动服务端）
cmd_split() {
  local which="${1:-show}" action="${2:-show}" flag name label
  case "$which" in
    show|status)
      echo ""
      echo -e "${CYAN}=== 上下行分离节点（纯客户端链接，不动服务端）===${NC}"
      [[ "${FEATURE_REALITY_UP_CDN_DOWN:-false}" == true ]] && echo -e "  Reality-Up-CDN-Down:  ${GREEN}已开启${NC}" || echo -e "  Reality-Up-CDN-Down:  ${YELLOW}未开启${NC}"
      [[ "${FEATURE_CDN_UP_REALITY_DOWN:-false}" == true ]] && echo -e "  CDN-Up-Reality-Down:  ${GREEN}已开启${NC}" || echo -e "  CDN-Up-Reality-Down:  ${YELLOW}未开启${NC}"
      echo -e "  ${MANAGE_CMD} split reality-up on|off   # 上行 Reality、下行 CDN"
      echo -e "  ${MANAGE_CMD} split cdn-up on|off       # 上行 CDN、下行 Reality"
      echo ""
      return 0
      ;;
    reality-up) flag=FEATURE_REALITY_UP_CDN_DOWN;  name="VLESS-Reality-Up-CDN-Down"; label="Reality-Up-CDN-Down（上行 Reality、下行 CDN）" ;;
    cdn-up)     flag=FEATURE_CDN_UP_REALITY_DOWN;  name="VLESS-CDN-Up-Reality-Down"; label="CDN-Up-Reality-Down（上行 CDN、下行 Reality）" ;;
    *) echo "用法: ${MANAGE_CMD} split [show|reality-up on|off|cdn-up on|off]"; return 1 ;;
  esac
  case "$action" in
    show|status) cmd_split show ;;
    on)
      backup_store_check
      [[ -f "$NODE_ENV_FILE" ]] || fail "未找到 ${NODE_ENV_FILE}，无法保存开关状态"
      [[ -n "${CDN_DOMAIN:-}" ]] || fail "未配置 CDN 域名，分离节点没有 CDN 腿可用"
      info "正在开启 ${label} ..."
      backup_node_sync_files "$name" on || fail "更新客户端文件失败，未做任何修改（原因见上）"
      update_node_env "$flag" "true"
      export "$flag"=true
      if [[ "$which" == reality-up ]]; then update_node_env FEATURE_UP_CDN_DOWN_MIHOMO true; fi
      info "${label} 已开启"
      cmd_resub
      ;;
    off)
      backup_store_check
      info "正在关闭 ${label} ..."
      backup_node_sync_files "$name" off || warn "客户端文件里没有该节点或同步失败（原因见上），仍按关闭处理标志位"
      update_node_env "$flag" "false"
      export "$flag"=false
      if [[ "$which" == reality-up ]]; then update_node_env FEATURE_UP_CDN_DOWN_MIHOMO false; fi
      info "${label} 已关闭"
      cmd_resub
      ;;
    *) echo "用法: ${MANAGE_CMD} split ${which} on|off" ;;
  esac
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
    echo "  8) TCP Brutal 极速加速 show / on / off / speed"
    echo "  9) 保活开关"
    echo " 10) 内核自动更新开关"
    echo " 11) UDP 节点自检 (diag)"
    echo " 12) sysctl 冲突检测 (conflict)"
    echo " 13) Reality 兼容模式 / minversion (minClientVer)"
    echo " 14) CDN ECH 加密 SNI 开关 (show / on / off)"
    echo " 15) TCP ECN 拥塞通知开关 (show / on / off)"
    echo " 16) 备用节点 CDN TCP(h2)，默认关闭 (show / on / off)"
    echo " 17) CDN QUIC(h3) 节点开关，默认开启 (show / on / off)"
    echo " 18) 出站分流开关 屏蔽回国 IP / 广告域名 (show / cn on|off / ads on|off)"
    echo " 19) Reality 时间差校验 maxTimeDiff (show / on [毫秒] / off)"
    echo " 20) 备用节点 XHTTP-Direct-H2（TCP 直连）(show / on / off)"
    echo " 21) Hysteria2 节点与混淆管理 (show / on / off / obfs on|off)"
    echo " 22) MASQUE 标准 L3 隧道 (show / on / off)"
    echo " 23) XDRIVE 网盘穿透代理 (show / setup / on / off)"
    echo " 24) Finalmask Noise exp 动态混淆 (show / on / off / set)"
    echo " 25) 备用节点 上行 Reality / 下行 CDN，默认关闭 (show / on / off)"
    echo " 26) 备用节点 上行 CDN / 下行 Reality (show / on / off)"
    echo " 27) 重新生成全量订阅 (resub)"
    echo " 28) 证书续期方式查看 / 切换 DNS-01 (cert: show / dnscf)"
    echo " 29) Nginx 版本检查与升级 (nginx: show / check / update)"
    echo " 30) Reality 节点管理 (show / vision on|off / xhttp on|off / updown on|off)"
    echo " 31) 卸载"
    echo "  0) 退出"
    read -rp "请选择: " choice
    case "$choice" in
      1) cmd_status ;;
      2) cmd_info ;;
      3) cmd_sub ;;
      4) cmd_restart ;;
      5) cmd_log xray ;;
      6) read -rp "  直接回车更新最新版，或输入指定版本 (如 26.7.28): " a; cmd_update "${a}" ;;
      7) read -rp "  show / on / off / client / win / mac / linux / sb: " a; cmd_tuning "${a:-show}" ;;
      8) read -rp "  show / on / off / speed: " a; cmd_brutal "${a:-show}" ;;
      9) read -rp "  on / off / show: " a; cmd_keepalive "${a:-show}" ;;
      10) read -rp "  on / off / show: " a; cmd_autoupdate "${a:-show}" ;;
      11) cmd_diag ;;
      12) cmd_conflict ;;
      13) read -rp "  show / on / off / 版本号(默认1.8.0): " a; cmd_minversion "${a:-show}" ;;
      14) read -rp "  show / on / off: " a; cmd_ech "${a:-show}" ;;
      15) read -rp "  show / on / off: " a; cmd_ecn "${a:-show}" ;;
      16) read -rp "  show / on / off: " a; cmd_cdnh2 "${a:-show}" ;;
      17) read -rp "  show / on / off: " a; cmd_cdnh3 "${a:-show}" ;;
      18) read -rp "  show / cn on|off / ads on|off: " a; cmd_block ${a:-show} ;;
      19) read -rp "  show / on [毫秒] / off: " a; cmd_timediff ${a:-show} ;;
      20) read -rp "  show / on / off: " a; ( cmd_h2direct "${a:-show}" ) ;;
      21)
        echo ""
        echo -e "${CYAN}--- Hysteria2 操作选择 ---${NC}"
        echo "  1) 查看 Hysteria2 状态 (show)"
        echo "  2) 开启 Hysteria2 直连节点 (hy2 on)"
        echo "  3) 关闭全部 Hysteria2 节点 (hy2 off)"
        echo "  4) 开启 Hysteria2 混淆节点 (hy2 obfs on)"
        echo "  5) 关闭 Hysteria2 混淆节点 (hy2 obfs off)"
        read -rp "请选择 [1-5 或输入指令，直接回车查看状态]: " a
        case "$a" in
          1|show|"")            cmd_hy2 show ;;
          2|on)                 cmd_hy2 on ;;
          3|off)                cmd_hy2 off ;;
          4|"obfs on"|obfson)   cmd_hy2 obfs on ;;
          5|"obfs off"|obfsoff) cmd_hy2 obfs off ;;
          obfs*)                cmd_hy2 $a ;;
          *)                    cmd_hy2 "${a:-show}" ;;
        esac
        ;;
      22) read -rp "  show / on / off: " a; ( cmd_masque "${a:-show}" ) ;;
      23)
        echo ""
        echo -e "${CYAN}--- XDRIVE 网盘代理操作选择 ---${NC}"
        echo "  1) 查看 XDRIVE 状态 (show)"
        echo "  2) 配置 Google Drive 凭证 (setup)"
        echo "  3) 开启 XDRIVE 网盘穿透入站 (on)"
        echo "  4) 关闭 XDRIVE 网盘穿透入站 (off)"
        read -rp "请选择 [1-4 或输入指令，直接回车查看状态]: " a
        case "$a" in
          1|show|"")  cmd_xdrive show ;;
          2|setup)    cmd_xdrive setup ;;
          3|on)       cmd_xdrive on ;;
          4|off)      cmd_xdrive off ;;
          *)          cmd_xdrive "${a:-show}" ;;
        esac
        ;;
      24)
        echo ""
        echo -e "${CYAN}--- Finalmask Noise exp 动态混淆操作选择 ---${NC}"
        echo "  1) 查看 Noise 状态与模板 (show)"
        echo "  2) 开启 Noise 动态混淆 (on)"
        echo "  3) 关闭 Noise 动态混淆 (off)"
        echo "  4) 自定义数据包表达式与延时 (set)"
        read -rp "请选择 [1-4 或输入指令，直接回车查看状态]: " a
        case "$a" in
          1|show|"")  cmd_noise show ;;
          2|on)       cmd_noise on ;;
          3|off)      cmd_noise off ;;
          4|set)      read -rp "请输入数据包表达式 (回车默认: <b 16030100><r 32><t><c><rd 8>): " p
                      read -rp "请输入延时范围毫秒 (回车默认: 10-50): " d
                      cmd_noise set "$p" "$d" ;;
          *)          cmd_noise "${a:-show}" ;;
        esac
        ;;
      25) read -rp "  show / on / off: " a; ( cmd_split reality-up "${a:-show}" ) ;;
      26) read -rp "  show / on / off: " a; ( cmd_split cdn-up "${a:-show}" ) ;;
      27) cmd_resub ;;
      28) read -rp "  show / dnscf: " a; cmd_cert "${a:-show}" ;;
      29) read -rp "  show / check / update: " a; cmd_nginx "${a:-show}" ;;
      30) read -rp "  show / vision on|off / xhttp on|off / updown on|off: " a; ( cmd_reality ${a:-show} ) ;;
      31) cmd_uninstall; break ;;
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
  xh conflict           sysctl 冲突与覆盖检测
  xh log [xray|nginx] [行数]
  xh start | stop | restart
  xh update [<ver>] [--auto] 更新或指定 Xray-core 版本（自检失败自动回滚）
  xh minversion [show|on|off|<ver>] Reality 客户端最低版本控制 (默认 1.8.0 兼容 mihomo/Clash)
  xh ech [show|on|off]              Cloudflare CDN ECH (加密 SNI) 开关与订阅同步
  xh ecn [show|on|off]              TCP ECN (显式拥塞通知) 开关与状态查看
  xh cert [show|dnscf]              证书续期方式查看 / 切换为 Cloudflare DNS-01（CDN 走代理时必需）
  xh nginx [show|check|update]      nginx 版本 / 检查新版 / 手动更新到最新 mainline（校验 PGP 签名，失败回滚）
  xh nginx h2only [show|on|off]     nginx 只接受 HTTP/2（HTTP/1.x 请求断开，/sub/ 例外）
  xh cdnh2 [show|on|off]            CDN TCP(h2) 备用节点开关与订阅同步（默认关闭）
  xh cdnh3 [show|on|off]            CDN QUIC(h3) 节点开关与订阅同步（默认开启）
  xh h2direct [show|on|off]         备用节点 XHTTP-Direct-H2（TCP 直连），开启时加服务端入站并放行端口
  xh hy2 [show|on|off]              Hysteria2 直连节点开关（随机高 UDP 端口，默认安装），关闭时连同混淆节点一起移除
  xh hy2 obfs [show|on|off]         Hysteria2 混淆节点（salamander 混淆，需先开 hy2；别名: xh hy2obfs）
  xh masque [show|on|off]           MASQUE 标准 L3 隧道 (RFC 9484 CONNECT-IP, UDP/TCP 8447)
  xh xdrive [show|setup|on|off]     XDRIVE 网盘穿透代理 (Google Drive 中继，零公网 IP 穿透)
  xh noise [show|on|off|links|sync|set <exp>]  Finalmask Noise exp 动态混淆 (抗 DPI 模板标签)
  xh split [show|reality-up on|off|cdn-up on|off]  上下行分离两条（纯客户端链接；两条都是默认关闭的备用节点）
  xh block [show|cn on|off|ads on|off]  出站屏蔽回国 IP / 广告域名（默认关闭）
  xh timediff [show|on [毫秒]|off]  Reality maxTimeDiff 时间差校验（默认关闭）
  xh tuning [show|on|off|client|win|mac|linux|sb]  系统流控调优 / Windows与macOS客户端与sing-box加速
  xh brutal [show|on|off|speed|add|del|update|reload]  TCP Brutal 拥塞控制 / 速率调节 / 模块更新
  xh keepalive [on|off|show]
  xh autoupdate [on|off|show]       每周日 04:00 自动更新 Xray-core，并检查 nginx / tcp-brutal 新版本（只提醒）
  xh guard              健康检查并拉起异常服务（cron 调用）
  xh reality [show|vision on|off|xhttp on|off|updown on|off]  Reality 节点管理（Vision / XHTTP 增删服务端项并重启 xray；updown 为纯客户端链接）
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
  block)      shift; cmd_block "$@" ;;
  timediff)   shift; cmd_timediff "$@" ;;
  update)
    shift
    if [[ " $* " == *" --auto "* ]]; then
      # v4.9.47：每周任务顺带「检查」nginx 与 tcp-brutal 新版本——只写提醒（登录时与
      # xh status 显示），不自动安装，更新由管理员手动执行并校验签名 / 哈希。
      # 放在分发处：cmd_update 的 fail 会直接 exit，子 shell 隔离后互不影响；
      # 已有 cron 行无需改动。输出写入 syslog（journalctl -t xh-autoupdate）。
      {
        ( cmd_update "$@" ) || true
        ( cmd_nginx check ) || true
        ( check_tcp_brutal_update ) || true
      } 2>&1 | logger -t xh-autoupdate
    else
      cmd_update "$@"
    fi
    ;;
  nginx)      shift; cmd_nginx "$@" ;;
  minversion|minver) shift; cmd_minversion "$@" ;;
  ech)        shift; cmd_ech "$@" ;;
  ecn)        shift; cmd_ecn "$@" ;;
  cert)       shift; cmd_cert "$@" ;;
  cdnh2|h2cdn) shift; cmd_cdnh2 "$@" ;;
  cdnh3|h3cdn) shift; cmd_cdnh3 "$@" ;;
  h2direct)   shift; cmd_h2direct "$@" ;;
  hy2)
    shift
    if [[ "${1:-}" == "obfs" ]]; then
      shift
      cmd_hy2 obfs "$@"
    else
      cmd_hy2 "$@"
    fi
    ;;
  hy2obfs)    shift; cmd_hy2 obfs "$@" ;;
  masque)     shift; cmd_masque "$@" ;;
  xdrive)     shift; cmd_xdrive "$@" ;;
  noise)      shift; cmd_noise "$@" ;;
  split)      shift; cmd_split "$@" ;;
  reality)    shift; cmd_reality "$@" ;;
  tuning|tune) shift; cmd_tuning "$@" ;;   # tune 为常见误打，一并接受
  brutal)     shift; cmd_brutal "$@" ;;
  keepalive)  shift; cmd_keepalive "$@" ;;
  autoupdate) shift; cmd_autoupdate "$@" ;;
  guard)      cmd_guard ;;
  uninstall)  cmd_uninstall ;;
  version)
    [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -1
    echo "xray-xhttp ${XH_VERSION:-unknown} (manage cli)"
    # node.env 里的 PROJECT_VERSION 是安装时刻的版本，只在两者不同时才提示，
    # 避免绝大多数（未升级过）机器上多出一行噪音。
    # 这里用 if 而非 `[[ ]] && echo`：后者作为分支最后一条语句，会在条件为假时
    # 把整个 xh version 的退出码变成 1（此处已是脚本末尾，没有后续命令兜底）。
    XH_INSTALLED_VER=""
    # node.env 里的值带引号（PROJECT_VERSION="4.9.44"），去掉再比，否则版本相同也会误报
    [[ -f "$NODE_ENV_FILE" ]] && \
      XH_INSTALLED_VER=$(sed -n 's/^PROJECT_VERSION=//p' "$NODE_ENV_FILE" | head -1 | tr -d "\"'")
    if [[ -n "$XH_INSTALLED_VER" && "$XH_INSTALLED_VER" != "${XH_VERSION:-}" ]]; then
      echo "  （本机节点安装于 ${XH_INSTALLED_VER}，之后 xh 被更新过；节点配置不会因 xh 更新而改变）"
    fi
    ;;
  -h|--help|help) usage ;;
  *)          usage; exit 1 ;;
esac
XHMANAGEEOF

# 把版本号注入生成好的 xh。上面的 heredoc 是 quoted 的（不展开变量），这是刻意的：
# xh 里满是 ${VAR} 与 $(...)，一旦改成非 quoted，整个脚本会在安装时就被展开掉。
# 因此版本号只能事后替换。占位符用 @@..@@ 而非 ${..}，就是为了不与 shell 语法冲突。
sed -i "s|@@XH_VERSION@@|${PROJECT_VERSION}|" "$MANAGE_BIN" || \
  warn "版本号注入失败，${MANAGE_CMD} version 将显示占位符（不影响其它功能）"

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

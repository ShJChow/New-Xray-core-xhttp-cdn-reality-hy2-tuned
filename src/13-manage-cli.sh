# ==================================================
# 安装管理命令 xh + 保活自愈 + 内核自动更新
# ==================================================

info "[8/8] 安装管理命令 ${MANAGE_CMD}"

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
    printf '  %-32s %s\n' "调优配置文件" "未启用（重跑安装脚本可开启）"
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
  echo "  直连 H3 节点:    ${FEATURE_H3_DIRECT:-false}"
  echo "  Xray 侧调优:     ${FEATURE_TUNING:-false}（bufferSize / sockopt）"
  echo "  系统层调优:      ${FEATURE_SYSCTL:-false}（内核 / 句柄，BBR 可用: ${TUNING_BBR_OK:-false}）"
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
  echo "  V2RayN / Shadowrocket: ${base}/v2rayn.txt"
  echo "  Mihomo 完整分流:       ${base}/mihomo-full.yaml"
  echo "  Mihomo 纯节点:         ${base}/mihomo-nodes.yaml"
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

# UDP / HTTP3 节点连不上时的服务端侧自检。
# 目的是"排除服务端"：这里全绿说明问题在客户端网络或客户端内核。
cmd_diag() {
  local ok=0 bad=0
  chk() { # chk 描述 结果(0/1) 补充说明
    if [[ "$2" -eq 0 ]]; then echo -e "  ${GREEN}[OK]${NC}   $1${3:+ — $3}"; ok=$((ok+1))
    else echo -e "  ${RED}[!!]${NC}   $1${3:+ — $3}"; bad=$((bad+1)); fi
  }

  echo -e "${CYAN}[+] 直连 UDP 节点（Vless-xhttp-tls-UDP-direct）服务端自检${NC}"

  # FEATURE_H3_DIRECT=false 是一个**有意的**状态（用户主动关闭，或安装期
  # nginx 启动失败后自动降级），不是异常：此时直连节点本就不该存在，后面
  # 的 quic / server 块检查全部跳过，否则会刷出一屏假告警。
  if [[ "${FEATURE_H3_DIRECT:-true}" != true ]]; then
    echo -e "  ${YELLOW}[--]${NC}   FEATURE_H3_DIRECT 已关闭 — 直连 UDP 节点未部署，本项检查跳过"
    echo ""
    echo "  仅 CDN 的 UDP 节点（Vless-xhttp-tls-UDP-cdn）可用。若这是安装期自动降级的"
    echo "  结果，根因是当时的 nginx quic 启动失败，重装时可用 FEATURE_H3_DIRECT=true 重试。"
    return 0
  fi
  chk "FEATURE_H3_DIRECT 已开启" 0

  if grep -q '443 quic' /etc/nginx/nginx.conf 2>/dev/null; then
    chk "nginx.conf 含 UDP 443 quic 监听" 0
  else
    chk "nginx.conf 无 UDP 443 quic 监听" 1 "重跑安装脚本，或确认未被 add-quic.sh 接管"
  fi

  # v1.2.1：quic 监听与 XHTTP 的 location 必须落在 **同一个** server 块里，
  # 且该块的 server_name 要等于客户端节点的 sni（Reality 域名）。
  # 两者分处不同 server_name 正是 v1.2.0 及之前直连 H3 节点不通的原因。
  if [[ -n "${REALITY_DOMAIN:-}" ]] && [[ -n "${XHTTP_PATH:-}" ]]; then
    if awk -v d="$REALITY_DOMAIN" -v p="$XHTTP_PATH" '
          $0 ~ "^[[:space:]]*server[[:space:]]*\\{" { blk=""; }
          { blk = blk $0 "\n" }
          $0 ~ "^[[:space:]]*server_name[[:space:]]+" d ";[[:space:]]*$" { want=1 }
          want && index(blk, "quic") && index(blk, "location " p) { found=1 }
          $0 ~ "^[[:space:]]*\\}[[:space:]]*$" { want=0 }
          END { exit(found ? 0 : 1) }
        ' /etc/nginx/nginx.conf 2>/dev/null; then
      chk "quic 监听与 location ${XHTTP_PATH} 同在 ${REALITY_DOMAIN} 的 server 块" 0
    else
      chk "quic 监听与 XHTTP location 未落在 ${REALITY_DOMAIN} 的同一 server 块" 1 \
        "客户端 sni 与服务端 server_name 不一致会导致握手落到回落网站；重跑安装脚本"
    fi
  fi

  if nginx -t >/dev/null 2>&1; then
    chk "nginx -t 配置有效" 0
  else
    chk "nginx -t 失败" 1 "执行 nginx -t 看具体报错；可用 FEATURE_H3_DIRECT=false 重装排除 quic"
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -lunp 2>/dev/null | grep -qE ':443\b'; then
      chk "本机已监听 UDP 443" 0 "$(ss -lunp 2>/dev/null | grep -E ':443\b' | head -1 | tr -s ' ')"
    else
      chk "本机未监听 UDP 443" 1 "nginx 可能未加载 quic 监听，或服务未启动"
    fi
  else
    warn "未安装 ss，跳过 UDP 监听检查"
  fi

  # 防火墙：只做提示，不自动改规则
  if command -v iptables >/dev/null 2>&1; then
    if iptables -S INPUT 2>/dev/null | grep -qE 'udp.*(dport 443|--dport 443)'; then
      chk "iptables 有 UDP 443 相关规则" 0
    elif iptables -S INPUT 2>/dev/null | grep -qE '^-A INPUT -j (REJECT|DROP)'; then
      chk "iptables 有兜底 REJECT/DROP 且未见 UDP 443 放行" 1 \
        "Oracle 默认镜像常见；见 docs/12 第 3 节"
    else
      chk "iptables 未见明显拦截" 0
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if firewall-cmd --list-ports 2>/dev/null | grep -q '443/udp'; then
      chk "firewalld 已放行 443/udp" 0
    else
      chk "firewalld 未放行 443/udp" 1 "firewall-cmd --permanent --add-port=443/udp && firewall-cmd --reload"
    fi
  fi

  echo ""
  echo -e "${CYAN}[+] 结论与下一步${NC}"
  if [[ $bad -eq 0 ]]; then
    echo "  服务端侧未发现问题（$ok 项通过）。"
    echo "  注意：云厂商的安全组/VCN 在机器外部，本地查不到，仍需自行确认已放行 UDP 443。"
  else
    echo "  发现 $bad 项异常，先按上面的提示处理。"
  fi
  echo ""
  echo -e "${YELLOW}  经 CDN 的 UDP 节点（Vless-xhttp-tls-UDP-cdn）不经过本机任何配置${NC}"
  echo "  它只依赖：① Cloudflare 区域已开启 HTTP/3  ② 你的客户端网络允许 UDP 443 出站。"
  echo ""
  echo "  在客户端机器上执行下面三条来区分（任一不通即为客户端侧网络封锁 QUIC）："
  echo "    curl -sI --http3-only https://cloudflare-quic.com/ | head -1"
  echo "    curl -sI --http3-only https://${CDN_DOMAIN:-你的CDN域名}/ | head -1"
  echo "    curl -sI --http3-only --resolve ${REALITY_DOMAIN:-你的Reality域名}:443:${VPS_IP:-你的VPS_IP} https://${REALITY_DOMAIN:-你的Reality域名}/ | head -1"
  echo "    （第三条直接打本机 UDP 443，走的正是直连节点的路径）"
  echo "  若 curl 不支持 --http3-only，用浏览器访问 https://cloudflare-quic.com/ 看是否显示 HTTP/3。"
  echo ""
  echo "  两条 UDP 节点同时不通、而 TCP 节点正常 ⇒ 基本可判定为客户端侧 UDP 443 被封，"
  echo "  服务端无法解决；请改用 Vless-reality-vision / Vless-xhttp-reality 节点。"
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
  latest=$(curl -fsSL --max-time 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
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
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root && ok=1
  else
    local arch asset tmpdir
    arch=$(uname -m)
    case "$arch" in
      x86_64|amd64) asset="Xray-linux-64.zip" ;;
      aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
      *) warn "Alpine 暂不支持架构 ${arch}"; return 0 ;;
    esac
    tmpdir=$(mktemp -d)
    if curl -fL "https://github.com/XTLS/Xray-core/releases/latest/download/${asset}" -o "${tmpdir}/xray.zip" &&
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
        info "未启用系统层调优（默认关闭，用 `xh tuning on` 查看开启方式）"
      fi
      [[ -f "$LIMITS_CONF" ]] && { echo ""; echo -e "${CYAN}[+] ${LIMITS_CONF}${NC}"; cat "$LIMITS_CONF"; }
      ;;
    on)
      [[ -f "$SYSCTL_CONF" ]] && { info "系统层调优已处于开启状态"; return 0; }
      # v1.2.2：系统层调优（FEATURE_SYSCTL）默认关闭，等节点验证无误后再开。
      # 调优含逐项能力探测（BBR / 只读 sysctl / limits.d 是否存在），只能由安装
      # 脚本执行，这里给出带 FEATURE_SYSCTL=true 的现成命令，并复用已有参数重装。
      warn "开启系统层调优需重跑安装脚本（其中包含逐项能力探测），已为你拼好命令："
      echo ""
      echo "  curl -fsSL https://github.com/${PROJECT_REPO:-ShJChow26/xhttp-cdn-tuned}/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh"
      echo "  AUTO=1 FEATURE_SYSCTL=true \\"
      echo "  REALITY_DOMAIN=${REALITY_DOMAIN} CDN_DOMAIN=${CDN_DOMAIN} IP_CHOICE=${IP_CHOICE} \\"
      echo "  bash ~/install-xpadding.sh"
      echo ""
      info "Xray 侧的 bufferSize / sockopt 不受该开关影响，安装时已写入"
      ;;
    off)
      rm -f "$SYSCTL_CONF" "$LIMITS_CONF"
      rm -f /etc/systemd/system/xray.service.d/override.conf \
            /etc/systemd/system/nginx.service.d/override.conf
      rmdir /etc/systemd/system/xray.service.d /etc/systemd/system/nginx.service.d 2>/dev/null || true
      [[ "$SERVICE_TYPE" == "systemd" ]] && systemctl daemon-reload >/dev/null 2>&1
      sysctl --system >/dev/null 2>&1 || true
      info "已移除本项目写入的全部调优配置"
      warn "已生效的运行时内核参数需重启系统才能完全恢复默认值"
      ;;
    *) fail "用法: xh tuning [show|on|off]" ;;
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

  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    for s in xray nginx hysteria-server; do
      rc-service "$s" stop >/dev/null 2>&1 || true
      rc-update del "$s" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$s"
    done
  else
    systemctl stop xray nginx hysteria-server >/dev/null 2>&1 || true
    systemctl disable xray nginx hysteria-server >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray.service \
          /etc/systemd/system/nginx.service \
          /etc/systemd/system/hysteria-server.service
    rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/nginx.service.d
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
        "${home}"/subscription-links.txt "${home}"/subscription-*.png
  rm -f /root/client-config.txt /root/client-config-mihomo-*.yaml \
        /root/subscription-links.txt /root/subscription-*.png
  rm -rf "$STATE_DIR"

  [[ "$SERVICE_TYPE" == "systemd" ]] && systemctl daemon-reload >/dev/null 2>&1 || true
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
    echo " 11) 卸载"
    echo "  0) 退出"
    read -rp "请选择: " choice
    case "$choice" in
      1) cmd_status ;;
      2) cmd_info ;;
      3) cmd_sub ;;
      4) cmd_restart ;;
      5) cmd_log xray ;;
      6) cmd_update ;;
      7) read -rp "  show / off: " a; cmd_tuning "${a:-show}" ;;
      8) read -rp "  on / off / show: " a; cmd_keepalive "${a:-show}" ;;
      9) read -rp "  on / off / show: " a; cmd_autoupdate "${a:-show}" ;;
      10) cmd_diag ;;
      11) cmd_uninstall; break ;;
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
  xh tuning [show|on|off]  查看 / 开启 / 回滚系统层调优（默认关闭）
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
  log)        shift; cmd_log "$@" ;;
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  update)     shift; cmd_update "$@" ;;
  tuning)     shift; cmd_tuning "$@" ;;
  keepalive)  shift; cmd_keepalive "$@" ;;
  autoupdate) shift; cmd_autoupdate "$@" ;;
  guard)      cmd_guard ;;
  uninstall)  cmd_uninstall ;;
  version)    [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -1; echo "xray-xhttp manage cli" ;;
  -h|--help|help) usage ;;
  *)          usage; exit 1 ;;
esac
XHMANAGEEOF

chmod +x "$MANAGE_BIN"
info "管理命令已安装: ${MANAGE_BIN}"

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

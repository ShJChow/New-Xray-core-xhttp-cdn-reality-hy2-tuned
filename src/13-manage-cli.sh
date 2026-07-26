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
  echo "  流控调优:        ${FEATURE_TUNING:-false}（BBR 可用: ${TUNING_BBR_OK:-false}）"
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
        info "未启用流控调优（重跑安装脚本可开启）"
      fi
      [[ -f "$LIMITS_CONF" ]] && { echo ""; echo -e "${CYAN}[+] ${LIMITS_CONF}${NC}"; cat "$LIMITS_CONF"; }
      ;;
    on)
      [[ -f "$SYSCTL_CONF" ]] && { info "调优已处于开启状态"; return 0; }
      warn "重新开启调优需要重跑安装脚本（其中包含逐项能力探测）："
      echo "  curl -fsSL https://github.com/${PROJECT_REPO:-ShJChow26/xhttp-cdn-tuned}/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh && bash ~/install-xpadding.sh"
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
    echo "  7) 流控调优 show / off"
    echo "  8) 保活开关"
    echo "  9) 内核自动更新开关"
    echo " 10) 卸载"
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
      10) cmd_uninstall; break ;;
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
  xh log [xray|nginx] [行数]
  xh start | stop | restart
  xh update [--auto]    更新 Xray-core（自检失败自动回滚）
  xh tuning [show|off]  查看 / 回滚流控调优（重新开启需重跑安装脚本）
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

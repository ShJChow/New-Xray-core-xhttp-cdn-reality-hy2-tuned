# ==================================================
# Xray 安装与服务配置
# ==================================================

# ==================================================
# 内核版本闸门（v4.0.0）
# --------------------------------------------------
# 两个直连 UDP 节点（h3-direct / Hysteria2-obfs）要求 Xray >= 26.6.1：
#   1. Hysteria2 inbound 在 v26.3.27 才加入；
#   2. finalmask 的 UDP listener 在 v26.3.27~v26.5.9 上收到第一个无效包即死亡、
#      内核缓冲区静默溢出，此后丢弃所有合法流量直到重启（issue #6184，PR #6185 修复）。
#      公网 UDP 扫描噪音使这个 bug 必然被触发，且**同时影响 Hysteria2 与 XHTTP/3**。
# 版本不足时把两个开关置 false，只保留 3 条能用的节点，不中断安装（L1）。
XRAY_MIN_VER_UDP="26.6.1"

# ver_ge A B —— A >= B ? 用 sort -V 做版本比较，不做字符串比较
ver_ge() {
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

require_xray_version_for_udp() {
  [[ "${FEATURE_H3_DIRECT:-false}" == true || "${FEATURE_HY2:-false}" == true ]] || return 0

  local raw ver
  raw=$(/usr/local/bin/xray version 2>/dev/null | head -1)
  # 形如 "Xray 26.7.28 (Xray, Penetrates Everything.) ..."，取第一个 x.y.z
  ver=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$raw" | head -1)

  if [[ -z "$ver" ]]; then
    warn "无法解析 Xray 版本（输出: ${raw:-空}），保守起见禁用两个直连 UDP 节点"
    FEATURE_H3_DIRECT=false
    FEATURE_HY2=false
    return 0
  fi

  if ver_ge "$ver" "$XRAY_MIN_VER_UDP"; then
    info "Xray ${ver} >= ${XRAY_MIN_VER_UDP}，h3-direct 与 Hysteria2 节点可用"
  else
    warn "Xray ${ver} < ${XRAY_MIN_VER_UDP}，已禁用 h3-direct 与 Hysteria2 两个直连 UDP 节点"
    warn "原因: Hysteria2 inbound 需 26.3.27+，且 finalmask UDP listener 崩溃 bug 需 26.6.1+ 才修复"
    warn "升级方法: ${MANAGE_CMD} update  （或删除 /usr/local/bin/xray 后重跑本脚本）"
    FEATURE_H3_DIRECT=false
    FEATURE_HY2=false
  fi
}

# 直连 UDP 端口与既有扩展的互检。基础安装无任何 UDP 监听，但两个扩展会占用：
#   extensions/quic-h3        默认 UDP 443  （/etc/xhttp-cdn/quic-h3.env）
#   extensions/common-nodes   默认 UDP 8443 （/etc/hysteria/config.yaml）
# 纯 Xray 方案下这两个扩展已无必要，同时存在会抢同一个端口。
check_udp_port_conflict() {
  local hy_conf="/etc/hysteria/config.yaml"

  if [[ "$FEATURE_H3_DIRECT" == true && -f /etc/xhttp-cdn/quic-h3.env ]]; then
    error "检测到 add-quic-h3 扩展（/etc/xhttp-cdn/quic-h3.env），它默认占用 UDP ${H3_PORT}。
    v4.0.0 的 h3-direct 节点由 Xray 直接提供，与该扩展重复且端口冲突。
    请先卸载扩展再重跑：${MANAGE_CMD} uninstall 后重新安装，或手工删除 nginx 中
    '# BEGIN quic-h3' 到 '# END quic-h3' 的段落与该 env 文件。"
  fi

  if [[ "$FEATURE_HY2" == true && -f "$hy_conf" ]]; then
    error "检测到独立 hysteria2 二进制的配置（${hy_conf}），它默认占用 UDP ${HY2_PORT}。
    v4.0.0 的 Hysteria2 由 Xray 原生 inbound 提供，不再需要独立二进制。
    请先停用并卸载：systemctl disable --now hysteria-server; rm -rf /etc/hysteria /usr/local/bin/hysteria"
  fi
}

install_xray() {
  info "Installing Xray-core..."

  if [ -f "/usr/local/bin/xray" ]; then
    info "Xray already installed: $(/usr/local/bin/xray version 2>/dev/null | head -1 || echo 'unknown')"
    return
  fi

  if [[ "$OS_ID" != "alpine" ]]; then
    # 官方 install-release.sh 在 `pidof xray` 非空时会去 systemctl stop xray.service，
    # 单元文件不存在就直接 exit 1（"Unit xray.service not loaded"）。
    # 这个中间态由「上一次卸载删了 unit 和二进制、却没杀掉进程」造成——旧版本的
    # 卸载脚本已经装在用户机器上，改不了，所以安装侧必须自己兜住。
    if [[ "$SERVICE_TYPE" == "systemd" ]] && pgrep -x xray >/dev/null 2>&1; then
      if ! systemctl cat xray.service >/dev/null 2>&1; then
        warn "检测到残留的 xray 进程，但 xray.service 单元已不存在"
        warn "该中间态会让官方安装脚本报 'Unit xray.service not loaded' 并中止，先清理"
        pkill -x xray >/dev/null 2>&1 || true
        sleep 1
        pgrep -x xray >/dev/null 2>&1 && { pkill -9 -x xray >/dev/null 2>&1 || true; sleep 1; }
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
        pgrep -x xray >/dev/null 2>&1 && \
          error "无法结束残留的 xray 进程，请手动执行: pkill -9 -x xray 后重跑"
        info "残留进程已清理"
      fi
    fi
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
    return
  fi

  local arch asset tmpdir
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) error "Alpine 暂不支持当前架构: $arch" ;;
  esac

  command -v unzip >/dev/null 2>&1 || pkg_install unzip
  tmpdir=$(mktemp -d)
  curl -fL "https://github.com/XTLS/Xray-core/releases/latest/download/${asset}" -o "${tmpdir}/xray.zip"
  unzip -q "${tmpdir}/xray.zip" -d "$tmpdir"

  mkdir -p /usr/local/bin /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  install -m 755 "${tmpdir}/xray" /usr/local/bin/xray
  install -m 644 "${tmpdir}/geoip.dat" /usr/local/share/xray/geoip.dat
  install -m 644 "${tmpdir}/geosite.dat" /usr/local/share/xray/geosite.dat
  rm -rf "$tmpdir"

  cat > /etc/init.d/xray << 'XRAYSERVICEEOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"

export XRAY_LOCATION_ASSET="/usr/local/share/xray"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /run
    checkpath --directory --mode 0755 /var/log/xray
}
XRAYSERVICEEOF
  chmod +x /etc/init.d/xray
  service_enable xray
}


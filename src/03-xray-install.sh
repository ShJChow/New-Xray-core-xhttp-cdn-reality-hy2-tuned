# ==================================================
# Xray 安装与服务配置
# ==================================================

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


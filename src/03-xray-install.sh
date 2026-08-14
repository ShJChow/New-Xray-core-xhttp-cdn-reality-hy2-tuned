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
# 旧版 UDP 组件的自动迁移（v4.0.1）
# --------------------------------------------------
# v4.0.0 起 Hysteria2 与 h3 直连都由 Xray 原生提供，早期版本的两个扩展
# （add-quic.sh 的独立 hysteria 二进制、add-quic-h3.sh 的 nginx quic 段）
# 会抢同一批 UDP 端口。这些组件本来就是本项目自己装的，所以由本脚本自动接管，
# 而不是报错要求用户手工卸载——挡住用户的结果是他们继续用没有 obfs 的旧节点。
#
# 设 KEEP_LEGACY_UDP=true 可保留旧组件，此时改为关闭新节点避免端口冲突。
LEGACY_BACKUP_DIR="/var/backups/xray-xhttp-migrate"

migrate_legacy_udp_components() {
  local hy_conf="/etc/hysteria/config.yaml"
  local h3_env="/etc/xhttp-cdn/quic-h3.env"
  local nginx_conf="/etc/nginx/nginx.conf"
  local found=false stamp
  stamp="$(date +%Y%m%d-%H%M%S)"

  [[ -f "$hy_conf" || -f "$h3_env" ]] && found=true
  [[ "$found" == true ]] || return 0

  if [[ "${KEEP_LEGACY_UDP:-false}" == true ]]; then
    warn "KEEP_LEGACY_UDP=true：保留旧的独立 UDP 组件，改为关闭 Xray 原生的两个新节点"
    [[ -f "$hy_conf" ]] && { FEATURE_HY2=false; warn "  → Hysteria2-obfs 已关闭（旧的独立 hysteria 无 Salamander 混淆）"; }
    [[ -f "$h3_env" ]] && { FEATURE_H3_DIRECT=false; warn "  → h3-direct 已关闭"; }
    return 0
  fi

  info "检测到旧版 UDP 组件，开始自动迁移到 Xray 原生实现..."
  install -d -m 700 "$LEGACY_BACKUP_DIR" 2>/dev/null || true

  # ---- 独立 hysteria 二进制 → Xray 原生 hysteria inbound ----
  if [[ -f "$hy_conf" ]]; then
    cp -a "$hy_conf" "${LEGACY_BACKUP_DIR}/hysteria-config.yaml.${stamp}" 2>/dev/null || true
    if [[ "$SERVICE_TYPE" == "systemd" ]]; then
      systemctl disable --now hysteria-server >/dev/null 2>&1 || true
    else
      rc-service hysteria-server stop >/dev/null 2>&1 || true
      rc-update del hysteria-server default >/dev/null 2>&1 || true
    fi
    rm -rf /etc/hysteria 2>/dev/null || true
    rm -f /usr/local/bin/hysteria 2>/dev/null || true
    rm -f /etc/systemd/system/hysteria-server.service /etc/init.d/hysteria-server 2>/dev/null || true
    info "  已停用独立 hysteria 二进制（配置备份于 ${LEGACY_BACKUP_DIR}）"
    info "  Hysteria2 改由 Xray 原生 inbound 提供，本次起带 Salamander 混淆"
  fi

  # ---- add-quic-h3 的 nginx quic 段 → Xray 自己监听 UDP ----
  # 不删掉的话 nginx 会继续占 UDP 443，Xray 的 h3-direct 无法 bind。
  if [[ -f "$h3_env" ]]; then
    if [[ -f "$nginx_conf" ]]; then
      cp -a "$nginx_conf" "${LEGACY_BACKUP_DIR}/nginx.conf.${stamp}" 2>/dev/null || true
      sed -i '/# BEGIN quic-h3/,/# END quic-h3/d' "$nginx_conf" 2>/dev/null || true
      sed -i '/# BEGIN quic xhttp/,/# END quic xhttp/d' "$nginx_conf" 2>/dev/null || true
      if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        warn "  移除 nginx quic 段后 nginx -t 未通过，已还原该文件"
        cp -a "${LEGACY_BACKUP_DIR}/nginx.conf.${stamp}" "$nginx_conf" 2>/dev/null || true
      else
        info "  已从 nginx 移除 quic 监听段（改由 Xray 自己 bind UDP ${H3_PORT}）"
      fi
    fi
    rm -f "$h3_env" 2>/dev/null || true
  fi

  [[ "$SERVICE_TYPE" == "systemd" ]] && systemctl daemon-reload >/dev/null 2>&1 || true
  info "旧版 UDP 组件迁移完成，回滚可用 ${LEGACY_BACKUP_DIR} 中的备份"
}

# 迁移之后仍要确认端口确实空了出来——迁移可能因权限或非常规安装而部分失败。
check_udp_port_conflict() {
  command -v ss >/dev/null 2>&1 || return 0
  local p

  for p in "${H3_PORT}:FEATURE_H3_DIRECT:h3-direct" "${HY2_PORT}:FEATURE_HY2:Hysteria2-obfs"; do
    local port="${p%%:*}" rest="${p#*:}"
    local var="${rest%%:*}" name="${rest#*:}"
    [[ "${!var}" == true ]] || continue
    if ss -lnup 2>/dev/null | grep -qE ":${port}\b"; then
      local holder
      holder=$(ss -lnupH 2>/dev/null | grep -E ":${port}\b" | grep -oE 'users:\(\("[^"]+' | head -1 | sed 's/.*"//')
      # xray 自己占着是重跑安装的正常情况（旧进程还没被 restart 掉），不算冲突
      if [[ "$holder" == "xray" ]]; then continue; fi
      warn "UDP ${port} 已被 ${holder:-未知进程} 占用，${name} 节点已自动关闭"
      warn "  腾出该端口后重跑安装脚本即可启用；或用 ${var}=false 显式关闭本提示"
      printf -v "$var" '%s' false
    fi
  done

  # h2-direct 走 TCP，要查的是 ss -lnt 而不是 -lnu（v4.7.0）。
  # -p 不可省：没有它 ss 根本不输出 users:(("proc",...)) 那一列，h2_holder 恒为空，
  # 于是 "" != "xray" 成立——重跑安装时旧 xray 还占着 8445，节点就被无声关掉。
  # 上面的 UDP 分支用的是 -lnup / -lnupH，这里必须对齐（v4.7.7）。
  if [[ "$FEATURE_H2_DIRECT" == true ]] && ss -lntp 2>/dev/null | grep -qE ":${H2_PORT}\b"; then
    local h2_holder
    h2_holder=$(ss -lntpH 2>/dev/null | grep -E ":${H2_PORT}\b" | grep -oE 'users:\(\("[^"]+' | head -1 | sed 's/.*"//')
    if [[ "$h2_holder" != "xray" ]]; then
      warn "TCP ${H2_PORT} 已被 ${h2_holder:-未知进程} 占用，h2-direct 节点已自动关闭"
      warn "  换端口用 H2_PORT=<port> 重跑；或用 FEATURE_H2_DIRECT=false 显式关闭本提示"
      FEATURE_H2_DIRECT=false
    fi
  fi
}

install_xray() {
  info "Installing Xray-core..."

  if [ -f "/usr/local/bin/xray" ]; then
    local cur
    cur=$(/usr/local/bin/xray version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    info "Xray already installed: ${cur:-unknown}"

    # 已装但版本低于两个 UDP 节点的下限时**自动升级**，而不是跳过后再把节点关掉。
    # 用户重跑安装脚本的意图就是让新功能生效；停在旧版只会让他们拿到一份
    # 静默缺少 Hysteria2/h3 的配置，还以为是自己配错了。
    if [[ "${FEATURE_H3_DIRECT:-false}" == true || "${FEATURE_HY2:-false}" == true ]]; then
      if [[ -n "$cur" ]] && ! ver_ge "$cur" "$XRAY_MIN_VER_UDP"; then
        warn "当前 Xray ${cur} 低于直连 UDP 节点所需的 ${XRAY_MIN_VER_UDP}，正在自动升级..."
        if [[ "$OS_ID" != "alpine" ]]; then
          # --beta：Xray 自 v26.4.25 起把正式版 release 全部标记为 GitHub prerelease，
          # releases/latest 只返回非 prerelease 的旧版。--beta 让官方脚本取
          # PRE_RELEASE_LATEST（releases 列表里第一条有 Linux zip 资产的新版）。
          bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --beta -u root \
            || warn "自动升级失败，将按现有版本继续（两个直连 UDP 节点会被关闭）"
          info "升级后版本: $(/usr/local/bin/xray version 2>/dev/null | head -1 || echo unknown)"
        else
          warn "Alpine 下不自动升级，请手动更新后重跑（${MANAGE_CMD} update）"
        fi
      fi
    fi
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
    # --beta：同上面的说明——Xray 正式版全被标记为 prerelease，不加 --beta 会装到旧版
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --beta -u root
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
  # releases/latest/download 只指向最后一个非 prerelease（旧版）。先用 releases?per_page=1
  # 取真实最新 tag（不论 prerelease 与否），再按 tag 下载；API 失败时退回 releases/latest。
  local latest_tag asset_url
  latest_tag=$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4)
  if [[ -n "$latest_tag" ]]; then
    asset_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/${asset}"
  else
    warn "无法获取最新 Xray 版本，改用 releases/latest 下载"
    asset_url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
  fi
  curl -fL "$asset_url" -o "${tmpdir}/xray.zip"
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


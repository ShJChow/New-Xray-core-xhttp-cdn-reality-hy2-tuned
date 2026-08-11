# ==================================================
# 基础环境安装
# ==================================================

info "[1/7] 安装基础环境"

pkg_update

if [[ "$OS_ID" == "alpine" ]]; then
  pkg_install bash ca-certificates
  update-ca-certificates >/dev/null 2>&1 || true
fi

command -v curl    >/dev/null 2>&1 || pkg_install curl
command -v sudo    >/dev/null 2>&1 || pkg_install sudo
command -v socat   >/dev/null 2>&1 || pkg_install socat
command -v wget    >/dev/null 2>&1 || pkg_install wget
command -v tar     >/dev/null 2>&1 || pkg_install tar
command -v openssl >/dev/null 2>&1 || pkg_install openssl
if ! command -v qrencode >/dev/null 2>&1; then
  info "安装二维码工具 qrencode..."
  if [[ "$OS_ID" == "alpine" ]]; then
    pkg_install libqrencode-tools || warn "qrencode 安装失败，将跳过二维码输出"
  else
    pkg_install qrencode || warn "qrencode 安装失败，将跳过二维码输出"
  fi
fi

if ! command -v crontab >/dev/null 2>&1; then
  case "$OS_ID" in
    debian|ubuntu|opensuse*|sles)
      pkg_install cron
      ;;
    centos|rhel|almalinux|rocky|ol|amzn|fedora|alpine)
      pkg_install cronie
      if [[ "$SERVICE_TYPE" == "openrc" ]]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
      else
        systemctl enable --now crond 2>/dev/null || true
      fi
      ;;
  esac
fi

info "安装 Xray..."
install_xray
export PATH="/usr/local/bin:$PATH"

info "生成参数..."
# 节点 1 的 flow：默认用兼容性最好的 xtls-rprx-vision。
# 只有明确设置 VISION_UDP443=1 才写 -udp443（不拦截 UDP 443/QUIC）。
# 原因：部分客户端不认识 -udp443，会把 flow 置空；而服务端 account 是 XRV 时，
# 客户端空 flow 会被直接拒绝（Xray inbound.go: "client flow is empty"），
# 节点不是变慢而是完全连不上，同时也失去 Splice。
if [[ "${VISION_UDP443:-0}" == "1" ]]; then
  VISION_FLOW="xtls-rprx-vision-udp443"
else
  VISION_FLOW="xtls-rprx-vision"
fi
# 节点名后缀：取主机名，剔除非 ASCII 字母数字与连字符，避免客户端列表乱码
HOSTNAME_TAG=$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9-' | cut -c1-20)
[[ -z "$HOSTNAME_TAG" ]] && HOSTNAME_TAG="vps"
UUID1=$(xray uuid)
UUID2=$(xray uuid)
KEY_OUTPUT=$(xray x25519 2>&1)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk 'tolower($0) ~ /private/ { print $NF; exit }')
PUBLIC_KEY=$(echo "$KEY_OUTPUT"  | awk 'tolower($0) ~ /public/  { print $NF; exit }')
[[ -z "$PRIVATE_KEY" ]] && error "未能提取 Private Key，xray x25519 输出: $KEY_OUTPUT"
[[ -z "$PUBLIC_KEY" ]] && error "未能提取 Public Key，xray x25519 输出: $KEY_OUTPUT"
SHORT_ID=$(echo "$UUID1" | tr -d '-' | cut -c1-8)
XHTTP_PATH="/$(echo "$UUID2" | tr -d '-' | cut -c1-8)"

XHTTP_PADDING_PLACEMENT="queryInHeader"
XHTTP_PADDING_METHOD="tokenish"

# ==================================================
# 直连 UDP 节点参数（v4.0.0）
# ==================================================
# 与 extensions/common-nodes/00-env-utils.sh:48 的实现保持一致。主安装脚本原先
# 没有这个函数（只在扩展里有），节点 URI 里拼未转义的密码会产生非法 URI。
rawurlencode() {
  local string="$1"
  local encoded="" i char hex
  local LC_ALL=C

  for ((i = 0; i < ${#string}; i++)); do
    char="${string:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) encoded+="$char" ;;
      *) printf -v hex '%%%02X' "'$char"; encoded+="$hex" ;;
    esac
  done
  printf '%s' "$encoded"
}

# 密码用 hex：URL 安全，且避开 YAML 里需要引号的字符。
# 允许用环境变量覆盖，便于重装时保持客户端配置不变。
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -hex 16)}"
OBFS_PASSWORD="${OBFS_PASSWORD:-$(openssl rand -hex 16)}"

# H3_PORT **不能用 443**（v4.0.3 修复）：
# v4.0.0 曾按「一个 UDP 一个 TCP，协议不同不冲突」把它设成 443，那是**未经验证的假设**。
# 实际上 Xray 的 XHTTP inbound 在 alpn=h3 下可能被静默忽略而退回 TCP
# （XTLS/Xray-core#4391，closed as not planned；#5849 同类），一旦退回，
# 它就与 Reality 的 TCP 443 抢同一个端口，后 bind 的那个失败 —— 表现为「Reality 不通」。
# 用独立端口后，即使 h3 退回 TCP 也只影响它自己，不会波及主力节点。
H3_PORT="${H3_PORT:-8444}"
HY2_PORT="${HY2_PORT:-8443}"
# H2_PORT（v4.7.0）：h3-direct 的 TCP 孪生体，见 01-env.sh 的 FEATURE_H2_DIRECT。
# 它是**真 TCP**，和 Reality 的 TCP 443 属于同一协议族，必须独立端口。
H2_PORT="${H2_PORT:-8445}"

# 兜底：无论用户怎么设，都不允许与 Reality 的 TCP 443 同端口。
if [[ "$H3_PORT" == "443" ]]; then
  warn "H3_PORT=443 会与 Reality 抢占 TCP 443（见 Xray#4391），已改用 8444"
  H3_PORT=8444
fi
if [[ "$H2_PORT" == "443" ]]; then
  warn "H2_PORT=443 会与 Reality 抢占 TCP 443，已改用 8445"
  H2_PORT=8445
fi
# H2 是 TCP、H3/HY2 是 UDP，端口号相同在内核层面不冲突，但会让排障和安全组
# 规则变得难以分辨，因此仍然要求三者互不相同。
if [[ "$H2_PORT" == "$H3_PORT" || "$H2_PORT" == "$HY2_PORT" ]]; then
  warn "H2_PORT=${H2_PORT} 与 UDP 端口重复，已改用 8445"
  H2_PORT=8445
fi

# 顺序不能调换，三者依次收窄「哪些新节点真的可用」：
#   1. 版本闸门   —— 内核 <26.6.1 时关掉两个新节点
#   2. 旧组件迁移 —— 停用独立 hysteria / nginx quic 段，把 UDP 端口腾出来
#   3. 端口复查   —— 迁移后仍被占用的，对应节点自动关闭（不中止安装）
require_xray_version_for_udp
migrate_legacy_udp_components
check_udp_port_conflict

if [[ "$FEATURE_XPADDING" == true ]]; then
  XRAY_XHTTP_PADDING_JSON=$(cat <<EOF
,
                    "xPaddingObfsMode": true,
                    "xPaddingKey": "${XHTTP_PADDING_KEY}",
                    "xPaddingHeader": "${XHTTP_PADDING_HEADER}",
                    "xPaddingPlacement": "${XHTTP_PADDING_PLACEMENT}",
                    "xPaddingMethod": "${XHTTP_PADDING_METHOD}"
EOF
)
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  CDN_ECH_QUERY_ENC=$(echo "$CDN_ECH_QUERY" | sed -e 's/%/%25/g' -e 's/+/%2B/g' -e 's/:/%3A/g' -e 's/\//%2F/g')
fi

info "生成 VLESS Encryption 密钥..."
if ! VLESSENC_OUTPUT=$(xray vlessenc 2>&1) || ! grep -qi "encryption" <<< "$VLESSENC_OUTPUT"; then
  error "VLESS Encryption 密钥生成失败，请确保 Xray 版本支持 vlessenc。输出: $VLESSENC_OUTPUT"
fi
VLESSENC_ENCRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"encryption"/{print $4; exit}')
VLESSENC_DECRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"decryption"/{print $4; exit}')
[[ -z "$VLESSENC_ENCRYPTION" ]] && error "未能提取 ML-KEM-768 Encryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"
[[ -z "$VLESSENC_DECRYPTION" ]] && error "未能提取 ML-KEM-768 Decryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"
if [[ "$IP_CHOICE" == "2" ]]; then
  VPS_IP=$(curl -6 -s --max-time 5 ip.sb)
  [[ -z "$VPS_IP" ]] && error "无法获取 IPv6 地址"
  VPS_IP_URI="[${VPS_IP}]"
else
  VPS_IP=$(curl -4 -s --max-time 5 ip.sb)
  [[ -z "$VPS_IP" ]] && error "无法获取 IPv4 地址"
  VPS_IP_URI="${VPS_IP}"
fi

info "UUID1 (Vision): $UUID1"
info "UUID2 (XHTTP):  $UUID2"
info "Private Key:    $PRIVATE_KEY"
info "Public Key:     $PUBLIC_KEY"
info "Short ID:       $SHORT_ID"
info "Path:           $XHTTP_PATH"
info "VPS IP:         $VPS_IP"
info "VLESS Enc:      已启用 (防 CDN 中间人)"
echo ""

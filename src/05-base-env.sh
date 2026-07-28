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

# ------------------------------------------------------------------
# DNS 与出站域名策略（v1.2.8）
#
# 背景：routing.domainStrategy 是 IPIfNonMatch，而 sniffing.routeOnly=true 让目标
# 以**域名**形式进入路由，于是每条新连接都必须解析一次域名才能匹配 geoip:cn /
# geoip:private 规则。此前配置里没有 dns 段，Xray 因此走 localhost（系统解析器）
# 且自身无缓存；同时无论出网协议族如何都会照发 AAAA 查询。
#
# 按出网协议族收敛查询类型，可以省掉那次注定连不上的地址族解析：
#   IP_CHOICE=1（纯 IPv4 出网）→ UseIPv4
#   IP_CHOICE=2（纯 IPv6 出网）→ UseIPv6
# freedom 出站同样显式指定，避免 AsIs 在拨号时用 Go 解析器再解析一遍。
#
# 注意：这会让"只有 AAAA 记录"的目标在纯 IPv4 机器上不可达——但这类目标在纯
# IPv4 出网的机器上本来就不可达，不是本次新增的损失。
# ------------------------------------------------------------------
if [[ "$IP_CHOICE" == "2" ]]; then
  XRAY_DNS_QUERY_STRATEGY="UseIPv6"
  XRAY_FREEDOM_DOMAIN_STRATEGY="UseIPv6"
else
  XRAY_DNS_QUERY_STRATEGY="UseIPv4"
  XRAY_FREEDOM_DOMAIN_STRATEGY="UseIPv4"
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

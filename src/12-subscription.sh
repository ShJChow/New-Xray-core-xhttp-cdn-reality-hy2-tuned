# ==================================================
# 订阅文件与二维码输出
# ==================================================

SUB_TOKEN_FILE="/etc/xhttp-cdn/sub_token"
install -d -m 700 /etc/xhttp-cdn
if [[ -f "$SUB_TOKEN_FILE" ]]; then
  SUB_TOKEN=$(tr -d '\r\n' < "$SUB_TOKEN_FILE")
else
  SUB_TOKEN=$(openssl rand -hex 16)
  echo "$SUB_TOKEN" > "$SUB_TOKEN_FILE"
  chmod 600 "$SUB_TOKEN_FILE"
fi

SUB_DIR="/usr/local/nginx/html/sub/${SUB_TOKEN}"
install -d -m 755 "$SUB_DIR"
cp "$USER_HOME/client-config.txt" "$SUB_DIR/v2rayn-raw.txt"
base64 "$USER_HOME/client-config.txt" | tr -d '\n' > "$SUB_DIR/v2rayn.txt"
cp "$USER_HOME/client-config-mihomo-full.yaml" "$SUB_DIR/mihomo-full.yaml"
cp "$USER_HOME/client-config-mihomo-nodes.yaml" "$SUB_DIR/mihomo-nodes.yaml"

# Shadowrocket 专属订阅（只包含小火箭完全兼容的 REALITY 与 Hy2 节点）
grep -E 'Vless-reality-vision|Hysteria2-obfs' "$USER_HOME/client-config.txt" > "$SUB_DIR/shadowrocket-raw.txt" || true
if [[ -s "$SUB_DIR/shadowrocket-raw.txt" ]]; then
  base64 "$SUB_DIR/shadowrocket-raw.txt" | tr -d '\n' > "$SUB_DIR/shadowrocket.txt"
fi

# v2rayN TUN 优化订阅（排除在 TUN 模式下会导致 UDP 53 DNS 丢包超时的纯 CDN 节点）
grep -vE -- '-cdn-' "$USER_HOME/client-config.txt" > "$SUB_DIR/v2rayn-tun-raw.txt" || true
if [[ -s "$SUB_DIR/v2rayn-tun-raw.txt" ]]; then
  base64 "$SUB_DIR/v2rayn-tun-raw.txt" | tr -d '\n' > "$SUB_DIR/v2rayn-tun.txt"
fi

V2RAYN_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/v2rayn.txt"
V2RAYN_RAW_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/v2rayn-raw.txt"
V2RAYN_TUN_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/v2rayn-tun.txt"
SHADOWROCKET_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/shadowrocket.txt"
MIHOMO_FULL_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/mihomo-full.yaml"
MIHOMO_NODES_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/mihomo-nodes.yaml"

V2RAYN_QR_FILE="${USER_HOME}/subscription-v2rayn.png"
V2RAYN_TUN_QR_FILE="${USER_HOME}/subscription-v2rayn-tun.png"
SHADOWROCKET_QR_FILE="${USER_HOME}/subscription-shadowrocket.png"
MIHOMO_FULL_QR_FILE="${USER_HOME}/subscription-mihomo-full.png"
MIHOMO_NODES_QR_FILE="${USER_HOME}/subscription-mihomo-nodes.png"
SUB_LINKS_FILE="${USER_HOME}/subscription-links.txt"

output_subscription_qr() {
  local label="$1" url="$2" file="$3"
  qrencode -o "$file" -s 8 -m 2 "$url"
  chown "$(stat -c '%u:%g' "$USER_HOME")" "$file"
  echo -e "${YELLOW}[+] ${label}${NC}"
  qrencode -t ANSIUTF8 -m 1 "$url"
}

check_subscription() {
  cmp -s "$2" <(curl -kfsS --resolve "${REALITY_DOMAIN}:443:127.0.0.1" \
    "https://${REALITY_DOMAIN}$1") ||
    error "订阅自检失败: $1"
}

info "验证订阅链接..."
check_subscription "/sub/${SUB_TOKEN}/v2rayn.txt" "$SUB_DIR/v2rayn.txt"
check_subscription "/sub/${SUB_TOKEN}/v2rayn-raw.txt" "$SUB_DIR/v2rayn-raw.txt"
[[ -f "$SUB_DIR/shadowrocket.txt" ]] && check_subscription "/sub/${SUB_TOKEN}/shadowrocket.txt" "$SUB_DIR/shadowrocket.txt"
[[ -f "$SUB_DIR/v2rayn-tun.txt" ]] && check_subscription "/sub/${SUB_TOKEN}/v2rayn-tun.txt" "$SUB_DIR/v2rayn-tun.txt"
check_subscription "/sub/${SUB_TOKEN}/mihomo-full.yaml" "$SUB_DIR/mihomo-full.yaml"
check_subscription "/sub/${SUB_TOKEN}/mihomo-nodes.yaml" "$SUB_DIR/mihomo-nodes.yaml"
info "订阅链接自检通过"

# 上面的自检用 -k 跳过证书校验（只为验证内容一致），而真实客户端会严格校验。
# 这里额外做一次**带证书校验**的公网路径检查：iOS 客户端（Shadowrocket /
# onexray）对证书链比 curl -k 严格得多，链不完整时表现就是"订阅拉不到节点"。
# best-effort：失败只告警，不中断安装（可能只是本机出网受限）。
if curl -fsS -o /dev/null --max-time 15 "${V2RAYN_SUB_URL}" 2>/dev/null; then
  info "订阅链接证书校验通过（公网路径）"
else
  warn "订阅链接在**严格证书校验**下拉取失败：${V2RAYN_SUB_URL}"
  warn "若 iOS 客户端提示订阅为空，多半就是这里——请在该设备浏览器里打开该链接确认"
fi

cat > "$SUB_LINKS_FILE" << SUBLINKEOF
V2RayN 订阅 (base64):
$V2RAYN_SUB_URL

V2RayN TUN 模式优化订阅 (排除纯 CDN 节点):
$V2RAYN_TUN_SUB_URL

Shadowrocket 专属订阅 (仅保留完全兼容节点):
$SHADOWROCKET_SUB_URL

明文节点订阅（Shadowrocket / onexray 等对 base64 挑剔时改用这个）:
${V2RAYN_RAW_SUB_URL}

Mihomo 完整分流订阅:
$MIHOMO_FULL_SUB_URL

Mihomo 纯节点订阅:
$MIHOMO_NODES_SUB_URL

二维码 PNG 文件:
V2RayN 全量: $V2RAYN_QR_FILE
V2RayN TUN 优化: $V2RAYN_TUN_QR_FILE
Shadowrocket 专属: $SHADOWROCKET_QR_FILE
Mihomo 完整分流: $MIHOMO_FULL_QR_FILE
Mihomo 纯节点: $MIHOMO_NODES_QR_FILE
SUBLINKEOF
chown "$(stat -c '%u:%g' "$USER_HOME")" "$SUB_LINKS_FILE"

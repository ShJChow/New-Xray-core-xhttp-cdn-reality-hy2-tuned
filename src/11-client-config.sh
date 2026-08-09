# ==================================================
# 客户端配置生成
# ==================================================

info "[6/7] 生成客户端配置"
XHTTP_PATH_ENC=${XHTTP_PATH//\//%2F}

# ==================================================
# TUN 模式下的节点自身流量豁免（v1.2.3）
# ==================================================
# 症状：开启 TUN 后 TCP 节点（1/2）正常，两条 UDP/h3 节点（3/4）全不通。
# 节点 3 的 server 是 CDN 域名、节点 4 是裸 IP，两者唯一的共同点就是 QUIC。
#
# 机制：TUN 用 auto-route 把默认路由指向自己，Mihomo 自己发往节点服务器的包
# 会被自家 TUN 再次捕获，按 rules 兜到 MATCH,漏网之鱼 → 又送回代理 → 环路。
# TCP 之所以不受影响，是因为 dialer 绑定物理接口的保护在 TCP 路径上更完整；
# QUIC 是无连接的 UDP，同样的保护在多数平台上兜不住。
#
# 三道防线，越靠前越根本：
#   ① tun.route-exclude-address：让节点流量**根本不进 TUN**（最根本）
#   ② rules 首条 DIRECT：万一进了 TUN，也在第一条就放出去
#   ③ sniffer.skip-dst-address：即使被 TUN 捞到，也不许改写目标地址
# 字段名均已核对 mihomo 源码（listener/config/tun.go、config/config.go:373-378）。
if [[ "$IP_CHOICE" == "2" ]]; then
  VPS_IP_CIDR="${VPS_IP}/128"
  MIHOMO_NODE_DIRECT_RULE="  - IP-CIDR6,${VPS_IP_CIDR},全局直连,no-resolve"
else
  VPS_IP_CIDR="${VPS_IP}/32"
  MIHOMO_NODE_DIRECT_RULE="  - IP-CIDR,${VPS_IP_CIDR},全局直连,no-resolve"
fi

rm -f /etc/xhttp-cdn/dual-cdn-domains /etc/xhttp-cdn/dual-ip-domains 2>/dev/null || true

if [[ "$FEATURE_XPADDING" == true ]]; then
  # 客户端 extra 只保留 xmux 复用（参考优化：8-16 并发 / 2-4 连接 / 600-900 次 /
  # 1800-3000s 复用）；xPaddingBytes 是服务端参数，客户端无需 padding 字段。
  XMUX_ENC="%22xmux%22%3A%7B%22maxConcurrency%22%3A%228-16%22%2C%22maxConnections%22%3A%222-4%22%2C%22hMaxRequestTimes%22%3A%22600-900%22%2C%22hMaxReusableSecs%22%3A%221800-3000%22%7D"
  XPAD_EXTRA_ENC="%7B${XMUX_ENC}%7D"
  MIHOMO_XPADDING_XHTTP_BLOCK=""
  MIHOMO_XPADDING_DOWNLOAD_BLOCK=""
  MIHOMO_SC_MIN_POSTS_BLOCK=""
  MIHOMO_REUSE_KEEPALIVE_XHTTP=""
  MIHOMO_REUSE_KEEPALIVE_DOWNLOAD=""
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  MIHOMO_ECH_PROXY_BLOCK=$(cat <<EOF

    ech-opts:
      enable: true
      query-server-name: cloudflare-ech.com
EOF
)
  MIHOMO_ECH_DOWNLOAD_BLOCK=$(cat <<EOF

        ech-opts:
          enable: true
          query-server-name: cloudflare-ech.com
EOF
)
fi

# v4.0.0 节点集：3 条 QUIC/h3 + 2 条 TCP 兜底，全部由 Xray 单核心提供。
# 两条直连 UDP 节点（h3-direct / Hysteria2）依赖 Xray ≥26.6.1，低版本时
# FEATURE_H3_DIRECT / FEATURE_HY2 会在 03-xray-install.sh 里被置 false，
# 此处渲染为空行，随后的 sed 删掉——空行若进了 base64 订阅会变成一条空节点。
# L19：同一节点的 URI 版与 mihomo 版是两处独立代码，必须同时处理。
if [[ "$FEATURE_H3_DIRECT" == true ]]; then
  H3_DIRECT_NODE_LINE="vless://${UUID2}@${VPS_IP_URI}:${H3_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${REALITY_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0&type=xhttp&path=${XHTTP_PATH}&mode=stream-up${XPAD_EXTRA_ENC:+&extra=${XPAD_EXTRA_ENC}}#Vless-xhttp-h3-direct-${HOSTNAME_TAG}"
else
  H3_DIRECT_NODE_LINE=""
fi

if [[ "$FEATURE_HY2" == true ]]; then
  HY2_NODE_LINE="hysteria2://$(rawurlencode "$HY2_PASSWORD")@${VPS_IP_URI}:${HY2_PORT}/?sni=${REALITY_DOMAIN}&insecure=0&obfs=salamander&obfs-password=$(rawurlencode "$OBFS_PASSWORD")#Hysteria2-obfs-${HOSTNAME_TAG}"
else
  HY2_NODE_LINE=""
fi

info "节点集: xhttp-tls-UDP-cdn + h3-direct(${FEATURE_H3_DIRECT}) + Hysteria2-obfs(${FEATURE_HY2}) + Reality x2"

cat > "$USER_HOME/client-config.txt" << CLIENTEOF
@@include templates/client-config.txt.tmpl
CLIENTEOF
# 删掉 CDN 节点关闭后留下的空行，保证 client-config.txt 每行都是一条可用节点
sed -i '/^[[:space:]]*$/d' "$USER_HOME/client-config.txt"

# v2rayN TUN 绕行清单。**不能并进 client-config.txt**——那份文件会被整体
# base64 成 v2rayN 订阅（12-subscription.sh:18），混入非节点行会污染订阅。
V2RAYN_TUN_FILE="$USER_HOME/client-config-v2rayn-tun.txt"
cat > "$V2RAYN_TUN_FILE" << V2RAYNTUNEOF
@@include templates/v2rayn-tun.txt.tmpl
V2RAYNTUNEOF

MIHOMO_FULL_FILE="$USER_HOME/client-config-mihomo-full.yaml"
MIHOMO_NODES_FILE="$USER_HOME/client-config-mihomo-nodes.yaml"

# 完整分流配置：保留用户选择的 ECH 配置
cat > "$MIHOMO_FULL_FILE" << MIHOMOEOF
@@include templates/mihomo-full.yaml.tmpl
MIHOMOEOF

cat > "$MIHOMO_NODES_FILE" << MIHOMOEOF
@@include templates/mihomo-nodes.yaml.tmpl
MIHOMOEOF

chown "$(stat -c '%u:%g' "$USER_HOME")" \
  "$USER_HOME/client-config.txt" \
  "$V2RAYN_TUN_FILE" \
  "$MIHOMO_FULL_FILE" \
  "$MIHOMO_NODES_FILE"

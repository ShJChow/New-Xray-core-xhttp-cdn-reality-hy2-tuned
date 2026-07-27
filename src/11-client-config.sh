# ==================================================
# 客户端配置生成
# ==================================================

info "[7/8] 生成客户端配置"
XHTTP_PATH_ENC=${XHTTP_PATH//\//%2F}

rm -f /etc/xhttp-cdn/dual-cdn-domains /etc/xhttp-cdn/dual-ip-domains 2>/dev/null || true

if [[ "$FEATURE_XPADDING" == true ]]; then
  XPAD_FIELDS_ENC="%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingMethod%22%3A%22${XHTTP_PADDING_METHOD}%22%2C%22xPaddingPlacement%22%3A%22${XHTTP_PADDING_PLACEMENT}%22%2C%22xPaddingHeader%22%3A%22${XHTTP_PADDING_HEADER}%22%2C%22xPaddingKey%22%3A%22${XHTTP_PADDING_KEY}%22"
  XMUX_ENC="%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%2C%22cMaxReuseTimes%22%3A0%2C%22hMaxReusableSecs%22%3A%221800-3000%22%2C%22hKeepAlivePeriod%22%3A0%7D"
  XPAD_EXTRA_ENC="%7B${XPAD_FIELDS_ENC}%2C${XMUX_ENC}%7D"
  SC_MIN_POSTS_ENC="%22scMinPostsIntervalMs%22%3A30"

  EXTRA_2_PARAM="&extra=${XPAD_EXTRA_ENC}"
  EXTRA_4_PARAM="&extra=%7B${XPAD_FIELDS_ENC}%2C${SC_MIN_POSTS_ENC}%2C${XMUX_ENC}%7D"

  MIHOMO_XPADDING_XHTTP_BLOCK=$(cat <<EOF

      x-padding-obfs-mode: true
      x-padding-key: "${XHTTP_PADDING_KEY}"
      x-padding-header: "${XHTTP_PADDING_HEADER}"
      x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
      x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
)
  MIHOMO_SC_MIN_POSTS_BLOCK=$(cat <<EOF

      sc-min-posts-interval-ms: 30
EOF
)
  MIHOMO_REUSE_KEEPALIVE_XHTTP=$(cat <<EOF

        h-keep-alive-period: 0
EOF
)
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  MIHOMO_ECH_PROXY_BLOCK=$(cat <<EOF

    ech-opts:
      enable: true
      query-server-name: cloudflare-ech.com
EOF
)
fi

# 直连 VPS 的 XHTTP-over-H3 节点依赖 Nginx 的 UDP 443 quic 监听（见
# src/09-server-config.sh 的 NGINX_H3_DIRECT_BLOCK），该监听曾在部分环境下
# 导致 nginx 启动失败。FEATURE_H3_DIRECT=false 时两者一起关闭，避免生成一个
# 打不通的节点链接。
if [[ "$FEATURE_H3_DIRECT" == true ]]; then
  # 直连节点走的是 VPS 自己的 UDP 443，不经过 CDN：sni/host 必须用 Reality 域名
  # （Cloudflare 灰云、DNS 直指 VPS），才能命中 Nginx 里带 quic 监听的那个
  # server 块（见 src/09-server-config.sh 的 NGINX_H3_DIRECT_BLOCK）。
  NODE_UDP_DIRECT_LINE="vless://${UUID2}@${VPS_IP_URI}:443?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${REALITY_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0&type=xhttp&host=${REALITY_DOMAIN}&path=${XHTTP_PATH}&mode=auto${EXTRA_4_PARAM}#Vless-xhttp-tls-UDP-direct-${HOSTNAME_TAG}"
  # Mihomo 同样支持 alpn: [h3]（transport/xhttp/client.go:159）
  MIHOMO_UDP_DIRECT_BLOCK=$(cat <<EOF


  - name: Vless-xhttp-tls-UDP-direct-${HOSTNAME_TAG}
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    network: xhttp
    alpn:
      - h3
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    encryption: ${VLESSENC_ENCRYPTION}
    xhttp-opts:
      host: ${REALITY_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}${MIHOMO_SC_MIN_POSTS_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}
EOF
)
else
  NODE_UDP_DIRECT_LINE=""
  MIHOMO_UDP_DIRECT_BLOCK=""
fi

cat > "$USER_HOME/client-config.txt" << CLIENTEOF
@@include templates/client-config.txt.tmpl
CLIENTEOF

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
  "$MIHOMO_FULL_FILE" \
  "$MIHOMO_NODES_FILE"

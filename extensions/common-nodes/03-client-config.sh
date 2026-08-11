# ==================================================
# 追加客户端节点
# ==================================================

NODE_XHTTP_H3_NAME="Vless-xhttp-tls-h3-direct-${HOSTNAME_TAG}"
NODE_HY2_NAME="Hysteria2-direct-${HOSTNAME_TAG}"

# v1.1.0 之前使用中文节点名，重复运行时一并清理，避免残留重复节点
LEGACY_XHTTP_H3_TAG=$(rawurlencode "vless+xhttp+tls+h3 直连")
LEGACY_HY2_TAG=$(rawurlencode "hysteria2 直连")

NODE_XHTTP_H3_TAG=$(rawurlencode "$NODE_XHTTP_H3_NAME")
NODE_HY2_TAG=$(rawurlencode "$NODE_HY2_NAME")

BASE_SERVER_URI=$(format_uri_host "$BASE_SERVER")

# 本扩展的 h3 节点挂在 Reality 域名（sni=${REALITY_DOMAIN}、同 UUID2、同 path），
# 与主脚本 v4.7.0 的 h2-direct 是同一条链路的 QUIC / TCP 两面，端口不同而已。
QUIC_TWIN_DESC="对应的 TCP 节点是主脚本的 Vless-xhttp-h2-tcp-direct（同 sni ${REALITY_DOMAIN}、同 path，走 TCP），UDP 不通时改用它。"

# 本扩展的 nginx 监听与 location 都挂在 Reality 域名的 server 块（见
# 02-server-config.sh），因此 sni/host 必须同为 Reality 域名（灰云直连），
# 否则 TLS 握手落到别的 server_name 上，节点必然不通。ECH 是 Cloudflare CDN
# 侧的机制，直连节点不适用，已一并去掉。
LINE_XHTTP_H3="vless://${UUID2}@${BASE_SERVER_URI}:${XHTTP_H3_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${REALITY_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0&type=xhttp&host=${REALITY_DOMAIN}&path=$(rawurlencode "$XHTTP_PATH")&mode=auto${XHTTP_EXTRA:+&extra=${XHTTP_EXTRA}}#${NODE_XHTTP_H3_TAG}"
LINE_HY2="hysteria2://$(rawurlencode "$HY2_PASSWORD")@${BASE_SERVER_URI}:${HY2_PORT}/?sni=${REALITY_DOMAIN}&insecure=0#${NODE_HY2_TAG}"

# 四条删除**无条件执行**：重复运行时先清掉自己上次写的节点，
# 且关闭 h3 后要能把上一次装的那条 h3 节点从订阅里清掉（幂等 + 降级路径）。
sed -i "/#${NODE_XHTTP_H3_TAG}\$/d" "$V2RAYN_FILE"
sed -i "/#${NODE_HY2_TAG}\$/d" "$V2RAYN_FILE"
sed -i "/#${LEGACY_XHTTP_H3_TAG}\$/d" "$V2RAYN_FILE"
sed -i "/#${LEGACY_HY2_TAG}\$/d" "$V2RAYN_FILE"
if [[ "$FEATURE_XHTTP_H3_NODE" == true ]]; then
  printf '%s\n%s\n' "$LINE_XHTTP_H3" "$LINE_HY2" >> "$V2RAYN_FILE"
else
  printf '%s\n' "$LINE_HY2" >> "$V2RAYN_FILE"
fi
chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

build_common_nodes_block() {
  # h3 节点关闭时只产出 Hysteria2 块。update_mihomo_file 里的 awk 仍会按
  # h3_name 删除旧块，所以从开启降级到关闭不会留下孤立节点。
  [[ "$FEATURE_XHTTP_H3_NODE" == true ]] || { build_hy2_node_block; return; }
  cat <<EOF
  - name: ${NODE_XHTTP_H3_NAME}
    type: vless
    server: "${BASE_SERVER}"
    port: ${XHTTP_H3_PORT}
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    encryption: "${VLESSENC_ENCRYPTION}"
    network: xhttp
    alpn:
      - h3
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    xhttp-opts:
      host: ${REALITY_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto
EOF

  if [[ -n "$XHTTP_EXTRA" ]]; then
    cat <<EOF
      x-padding-obfs-mode: true
      x-padding-key: "${XHTTP_PADDING_KEY}"
      x-padding-header: "${XHTTP_PADDING_HEADER}"
      x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
      x-padding-method: "${XHTTP_PADDING_METHOD}"
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"
        h-keep-alive-period: 0
EOF
  fi

  build_hy2_node_block
}

build_hy2_node_block() {
  cat <<EOF
  - name: ${NODE_HY2_NAME}
    type: hysteria2
    server: "${BASE_SERVER}"
    port: ${HY2_PORT}
    password: "${HY2_PASSWORD}"
    sni: ${REALITY_DOMAIN}
    alpn:
      - h3
EOF
}

update_mihomo_file() {
  local source_file="$1"
  local node_file tmp_file

  node_file=$(mktemp)
  tmp_file=$(mktemp)
  build_common_nodes_block > "$node_file"

  awk -v h3_name="$NODE_XHTTP_H3_NAME" \
      -v hy2_name="$NODE_HY2_NAME" \
      -v node_file="$node_file" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip=0 }

    $0 == "  - name: " h3_name ||
    $0 == "  - name: " hy2_name {
      skip=1
      next
    }

    /^proxy-groups:/ {
      while ((getline line < node_file) > 0) print line
      print ""
      inserted=1
    }

    { print }

    END {
      if (!inserted) {
        print ""
        while ((getline line < node_file) > 0) print line
      }
    }
  ' "$source_file" > "$tmp_file"

  cat "$tmp_file" > "$source_file"
  rm -f "$node_file" "$tmp_file"
}

for target_file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
  update_mihomo_file "$target_file"
done
chown "$(stat -c '%u:%g' "$USER_HOME")" "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"

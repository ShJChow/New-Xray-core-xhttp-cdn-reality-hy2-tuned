# ==================================================
# 追加客户端节点（三条 XHTTP over h3）
# ==================================================

# 本扩展的 h3 节点挂在 CDN 域名的 server 块、复用主脚本已有的 location，
# 所以它的 TCP 面就是主脚本的 CDN 节点本身（同域名、同 path、TCP 443 + h2）。
QUIC_TWIN_DESC="对应的 TCP 节点是主脚本的 Vless-xhttp-tls-UDP-cdn（同 CDN 域名、同 path，TCP 443 + alpn h2），UDP 不通时改用它。"

# 节点名用本项目的纯 ASCII 约定（上游用中文名）。
# 已核对不与任何 NODE_RE_* 冲突（L10）：
#   NODE_RE_CDN_BOTH   匹配 Vless-xhttp-tls-cdn- / Vless-xhttp-tls-UDP-cdn-
# 下面三个都不落进这些前缀；与 common-nodes 的 Vless-xhttp-tls-h3-direct-
# 也不同（删除 sed 按 `#名字$` 锚定行尾，两者可区分）。
# v4.0.0：NODE_RE_SPLIT_* 已随两条上下行分离节点一并删除；主脚本新增的
# Vless-xhttp-h3-direct- 不含 "tls"，与本文件的 Vless-xhttp-tls-h3- 前缀不重叠。
NODE_H3_NAME="Vless-xhttp-tls-h3-${HOSTNAME_TAG}"
NODE_H2UP_H3DOWN_NAME="Vless-xhttp-split-h2up-h3down-${HOSTNAME_TAG}"
NODE_H3UP_H2DOWN_NAME="Vless-xhttp-split-h3up-h2down-${HOSTNAME_TAG}"

NODE_H3_TAG=$(rawurlencode "$NODE_H3_NAME")
NODE_H2UP_H3DOWN_TAG=$(rawurlencode "$NODE_H2UP_H3DOWN_NAME")
NODE_H3UP_H2DOWN_TAG=$(rawurlencode "$NODE_H3UP_H2DOWN_NAME")

# 上游有、我们 00-env-utils 没有的两个辅助函数，原样移植
urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/}"
  printf '%s' "$value"
}

BASE_SERVER_URI=$(format_uri_host "$BASE_SERVER")
XHTTP_PATH_ENC=$(rawurlencode "$XHTTP_PATH")
BASE_EXTRA_JSON=""
[[ -n "$XHTTP_EXTRA" ]] && BASE_EXTRA_JSON=$(urldecode "$XHTTP_EXTRA")

# ${BASE_EXTRA_JSON:+…} 这类条件展开逐字保留上游写法，只做变量名映射，
# 不做「风格统一」——normal / xpadding 两个 profile 下的展开结果完全不同，
# 顺手规范化会让其中一个静默退化成普通节点（L18）。
build_download_extra() {
  local address="$1" port="$2" alpn="$3" download

  download="\"downloadSettings\":{\"address\":\"$(json_escape "$address")\",\"port\":${port},\"network\":\"xhttp\",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"$(json_escape "$CDN_DOMAIN")\",\"allowInsecure\":false,\"alpn\":[\"${alpn}\"],\"fingerprint\":\"chrome\"${ECH_PARAM:+,\"echConfigList\":\"$(json_escape "$(urldecode "$ECH_PARAM")")\"}},\"xhttpSettings\":{\"host\":\"$(json_escape "$CDN_DOMAIN")\",\"path\":\"$(json_escape "$XHTTP_PATH")\",\"mode\":\"auto\"${BASE_EXTRA_JSON:+,\"extra\":${BASE_EXTRA_JSON}}}}"

  if [[ -n "$BASE_EXTRA_JSON" ]]; then
    rawurlencode "${BASE_EXTRA_JSON%\}},${download}}"
  else
    rawurlencode "{${download}}"
  fi
}

# 三条删除无条件执行：重复运行时先清掉自己上次写的节点（幂等）
sed -i "/#${NODE_H3_TAG}\$/d"            "$V2RAYN_FILE"
sed -i "/#${NODE_H2UP_H3DOWN_TAG}\$/d"   "$V2RAYN_FILE"
sed -i "/#${NODE_H3UP_H2DOWN_TAG}\$/d"   "$V2RAYN_FILE"

printf '%s\n%s\n%s\n' \
  "vless://${UUID2}@${BASE_SERVER_URI}:${XHTTP_H3_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0${ECH_PARAM:+&ech=${ECH_PARAM}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH_ENC}&mode=auto${XHTTP_EXTRA:+&extra=${XHTTP_EXTRA}}#${NODE_H3_TAG}" \
  "vless://${UUID2}@${CDN_DOMAIN}:443?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h2&insecure=0&allowInsecure=0${ECH_PARAM:+&ech=${ECH_PARAM}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH_ENC}&mode=auto&extra=$(build_download_extra "$BASE_SERVER" "$XHTTP_H3_PORT" "h3")#${NODE_H2UP_H3DOWN_TAG}" \
  "vless://${UUID2}@${BASE_SERVER_URI}:${XHTTP_H3_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0${ECH_PARAM:+&ech=${ECH_PARAM}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH_ENC}&mode=auto&extra=$(build_download_extra "$CDN_DOMAIN" "443" "h2")#${NODE_H3UP_H2DOWN_TAG}" \
  >> "$V2RAYN_FILE"

chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

# ==================================================
# mihomo 节点块
# ==================================================
write_xhttp_node() {
  local name="$1" server="$2" port="$3" alpn="$4"
  local download_server="${5:-}" download_port="${6:-}" download_alpn="${7:-}"

  cat <<EOF
  - name: ${name}
    type: vless
    server: "${server}"
    port: ${port}
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    encryption: "${VLESSENC_ENCRYPTION}"
    network: xhttp
    alpn:
      - ${alpn}
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome
EOF

  if [[ -n "$ECH_PARAM" ]]; then
    cat <<'EOF'
    ech-opts:
      enable: true
      query-server-name: cloudflare-ech.com
EOF
  fi

  cat <<EOF
    xhttp-opts:
      host: ${CDN_DOMAIN}
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
EOF
  fi

  # xmux 与上游一致，本项目不改（L16：cMaxReuseTimes:0 = 无限复用，
  # hKeepAlivePeriod:0 = 采用 quic-go/Chrome 默认，都不是「禁用」）
  cat <<'EOF'
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"
        h-keep-alive-period: 0
EOF

  if [[ -n "$download_server" ]]; then
    cat <<EOF
      download-settings:
        host: ${CDN_DOMAIN}
        path: ${XHTTP_PATH}
        server: "${download_server}"
        port: ${download_port}
        tls: true
        alpn:
          - ${download_alpn}
        servername: ${CDN_DOMAIN}
        client-fingerprint: chrome
EOF

    if [[ -n "$ECH_PARAM" ]]; then
      cat <<'EOF'
        ech-opts:
          enable: true
          query-server-name: cloudflare-ech.com
EOF
    fi

    if [[ -n "$XHTTP_EXTRA" ]]; then
      cat <<EOF
        x-padding-obfs-mode: true
        x-padding-key: "${XHTTP_PADDING_KEY}"
        x-padding-header: "${XHTTP_PADDING_HEADER}"
        x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
        x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
    fi

    cat <<'EOF'
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"
          h-keep-alive-period: 0
EOF
  fi
}

build_quic_h3_nodes_block() {
  write_xhttp_node "$NODE_H3_NAME"            "$BASE_SERVER" "$XHTTP_H3_PORT" "h3"
  write_xhttp_node "$NODE_H2UP_H3DOWN_NAME"   "$CDN_DOMAIN"  "443"            "h2" "$BASE_SERVER" "$XHTTP_H3_PORT" "h3"
  write_xhttp_node "$NODE_H3UP_H2DOWN_NAME"   "$BASE_SERVER" "$XHTTP_H3_PORT" "h3" "$CDN_DOMAIN"  "443"            "h2"
}

update_mihomo_file() {
  local source_file="$1" node_file tmp_file
  node_file=$(mktemp); tmp_file=$(mktemp)
  build_quic_h3_nodes_block > "$node_file"

  awk -v n1="$NODE_H3_NAME" -v n2="$NODE_H2UP_H3DOWN_NAME" -v n3="$NODE_H3UP_H2DOWN_NAME" \
      -v node_file="$node_file" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip=0 }
    $0 == "  - name: " n1 || $0 == "  - name: " n2 || $0 == "  - name: " n3 { skip=1; next }
    /^proxy-groups:/ {
      while ((getline line < node_file) > 0) print line
      print ""
      inserted=1
    }
    { print }
    END { if (!inserted) { print ""; while ((getline line < node_file) > 0) print line } }
  ' "$source_file" > "$tmp_file"

  cat "$tmp_file" > "$source_file"
  rm -f "$node_file" "$tmp_file"
}

for target_file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
  [[ -f "$target_file" ]] && update_mihomo_file "$target_file"
done
chown "$(stat -c '%u:%g' "$USER_HOME")" "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE" 2>/dev/null || true

info "已追加 3 条 XHTTP over h3 节点"

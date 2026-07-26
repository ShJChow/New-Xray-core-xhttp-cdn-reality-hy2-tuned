# ==================================================
# 服务端配置生成
# ==================================================

info "[5/8] 生成配置文件"

if [[ "$FALLBACK_MODE" == "static" ]]; then
  [[ -f "${STATIC_SITE_DIR}/${REALITY_DOMAIN}/index.html" ]] || error "未找到 Reality 域名页面"
  [[ -f "${STATIC_SITE_DIR}/${CDN_DOMAIN}/index.html" ]] || error "未找到 CDN 域名页面"
fi

nginx_fallback_config() {
  if [[ "$FALLBACK_MODE" == "static" ]]; then
    cat <<EOF
            root ${STATIC_SITE_DIR}/$1;
            index index.html;
            try_files \$uri \$uri/ /index.html;
EOF
  else
    cat <<EOF
            proxy_pass $2;
            proxy_ssl_server_name on;
            proxy_ssl_name $3;
            proxy_redirect http://$3/ https://\$host/;
            proxy_redirect https://$3/ https://\$host/;
            proxy_set_header Host $3;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
EOF
  fi
}

# 直连 VPS 的 XHTTP-over-H3（节点 Vless-xhttp-tls-UDP-direct）需要 Nginx 监听
# UDP 443 quic。http3 依赖支持 QUIC 的 TLS 库，标准 OpenSSL 未必满足，曾在部分
# 环境下导致 nginx 启动失败。FEATURE_H3_DIRECT=false 可跳过该监听（对应客户端
# 节点也不生成，见 src/11-client-config.sh）。add-quic.sh 扩展会接管并移除本段。
if [[ "$FEATURE_H3_DIRECT" == true ]]; then
  NGINX_H3_DIRECT_BLOCK=$(cat <<'EOF'
        # BEGIN main-h3
        # 直连 VPS 的 XHTTP over HTTP/3（节点 Vless-xhttp-tls-UDP-direct）
        # Xray 占用的是 TCP 443，这里占用 UDP 443，互不冲突。
        # 需要防火墙放行 UDP 443；add-quic.sh 会接管并移除本段。
        listen       443 quic reuseport;
        http3        on;
        # END main-h3
EOF
)
else
  NGINX_H3_DIRECT_BLOCK=""
fi

info "写入 /etc/nginx/nginx.conf ..."
cat > /etc/nginx/nginx.conf << NGINXEOF
@@include templates/nginx.conf.tmpl
NGINXEOF

install -d -m 700 /etc/xhttp-cdn
{
  printf 'FALLBACK_MODE=%q\n' "$FALLBACK_MODE"
  if [[ "$FALLBACK_MODE" == "static" ]]; then
    printf 'STATIC_SITE_DIR=%q\n' "$STATIC_SITE_DIR"
  else
    printf 'REALITY_FALLBACK_ORIGIN=%q\n' "$REALITY_FALLBACK_ORIGIN"
    printf 'REALITY_FALLBACK_HOST=%q\n' "$REALITY_FALLBACK_HOST"
    printf 'CDN_FALLBACK_ORIGIN=%q\n' "$CDN_FALLBACK_ORIGIN"
    printf 'CDN_FALLBACK_HOST=%q\n' "$CDN_FALLBACK_HOST"
  fi
} > /etc/xhttp-cdn/fallback.env
chmod 600 /etc/xhttp-cdn/fallback.env

info "写入 /usr/local/etc/xray/config.json ..."
cat > /usr/local/etc/xray/config.json << XRAYEOF
@@include templates/xray-config.json.tmpl
XRAYEOF

# 节点状态：供管理命令 xh 读取（info / sub / status / uninstall）
info "写入 ${NODE_ENV_FILE} ..."
{
  printf 'PROJECT_NAME=%q\n'      "$PROJECT_NAME"
  printf 'PROJECT_REPO=%q\n'      "$PROJECT_REPO"
  printf 'INSTALL_TIME=%q\n'      "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'OS_ID=%q\n'             "$OS_ID"
  printf 'SERVICE_TYPE=%q\n'      "$SERVICE_TYPE"
  printf 'USER_HOME=%q\n'         "$USER_HOME"
  printf 'REALITY_DOMAIN=%q\n'    "$REALITY_DOMAIN"
  printf 'CDN_DOMAIN=%q\n'        "$CDN_DOMAIN"
  printf 'VPS_IP=%q\n'            "$VPS_IP"
  printf 'IP_CHOICE=%q\n'         "$IP_CHOICE"
  printf 'UUID1=%q\n'             "$UUID1"
  printf 'UUID2=%q\n'             "$UUID2"
  printf 'PUBLIC_KEY=%q\n'        "$PUBLIC_KEY"
  printf 'PRIVATE_KEY=%q\n'       "$PRIVATE_KEY"
  printf 'SHORT_ID=%q\n'          "$SHORT_ID"
  printf 'XHTTP_PATH=%q\n'        "$XHTTP_PATH"
  printf 'VLESSENC_ENCRYPTION=%q\n' "$VLESSENC_ENCRYPTION"
  printf 'VLESSENC_DECRYPTION=%q\n' "$VLESSENC_DECRYPTION"
  printf 'FEATURE_XPADDING=%q\n'  "$FEATURE_XPADDING"
  printf 'FEATURE_CDN_ECH=%q\n'   "$FEATURE_CDN_ECH"
  printf 'CDN_ECH_ENABLED=%q\n'   "$CDN_ECH_ENABLED"
  printf 'FEATURE_H3_DIRECT=%q\n' "$FEATURE_H3_DIRECT"
  printf 'FEATURE_TUNING=%q\n'    "$FEATURE_TUNING"
  printf 'TUNING_BBR_OK=%q\n'     "${TUNING_BBR_OK:-false}"
  printf 'TUNE_TIER=%q\n'         "${TUNE_TIER:-none}"
  printf 'XRAY_BUFFER_KB=%q\n'    "${XRAY_BUFFER_KB:-0}"
  printf 'MEM_MB=%q\n'            "${MEM_MB:-0}"
  printf 'CPU_CORES=%q\n'         "${CPU_CORES:-0}"
  printf 'ARCH=%q\n'              "${ARCH:-unknown}"
  if [[ "$FEATURE_XPADDING" == true ]]; then
    printf 'XHTTP_PADDING_HEADER=%q\n' "$XHTTP_PADDING_HEADER"
    printf 'XHTTP_PADDING_KEY=%q\n'    "$XHTTP_PADDING_KEY"
  fi
} > "$NODE_ENV_FILE"
chmod 600 "$NODE_ENV_FILE"

echo ""

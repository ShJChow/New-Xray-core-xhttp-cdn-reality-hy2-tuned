# ==================================================
# Nginx XHTTP H3 与 hysteria2
# ==================================================

command -v nginx >/dev/null 2>&1 || error "未找到 nginx，请先运行主脚本"
command -v xray >/dev/null 2>&1 || error "未找到 xray，请先运行主脚本"
command -v acme.sh >/dev/null 2>&1 || error "未找到 acme.sh，请先运行主脚本"
nginx -V 2>&1 | grep -q -- '--with-http_v3_module' || error "Nginx 未启用 HTTP/3 模块，请重新运行主脚本"

NGINX_CONF="/etc/nginx/nginx.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
[[ -f "$NGINX_CONF" ]] || error "未找到 $NGINX_CONF"
[[ -f "$XRAY_CONF" ]] || error "未找到 $XRAY_CONF"
[[ -f /etc/ssl/private/fullchain.cer && -f /etc/ssl/private/private.key ]] || error "未找到证书文件，请先运行主脚本"
info "XHTTP H3 复用 Xray 127.0.0.1:8001 入站"

# main-h3 是主脚本 v2.0.0 之前生成的 UDP 443 quic 段（含它自己的
# location ${XHTTP_PATH}）。v2.0.0 已不再生成，对新装机器这条 sed 是 no-op；
# 保留它是为了让**从旧版本升级过来**的 nginx.conf 也能被正确清理——否则本扩展
# 插入的 location 会与残留的那个同名，nginx -t 报 duplicate location。
sed -i \
  -e '/^[[:space:]]*# BEGIN common-nodes h3$/,/^[[:space:]]*# END common-nodes h3$/d' \
  -e '/^[[:space:]]*# BEGIN quic xhttp$/,/^[[:space:]]*# END quic xhttp$/d' \
  -e '/^[[:space:]]*# BEGIN main-h3$/,/^[[:space:]]*# END main-h3$/d' \
  "$NGINX_CONF"
info "已移除主脚本的 UDP 443 quic 监听（由本扩展接管，避免 reuseport 重复）"

grep -Eq "^[[:space:]]*server_name[[:space:]][[:space:]]*${REALITY_DOMAIN};[[:space:]]*$" "$NGINX_CONF" ||
  error "未找到 Reality 域名 Nginx 配置"

# 上面的清理 sed 无条件执行（幂等地清掉旧版本残留的块）；下面的**插入**才受开关控制。
# 关闭 h3 节点时不插入 location/listen：节点 2 直连 xray 的 TCP 443、不经 nginx，
# 这段配置只服务 h3 节点，插了就是一个没有客户端的 QUIC 监听。
if [[ "$FEATURE_XHTTP_H3_NODE" != true ]]; then
  info "跳过 Nginx XHTTP H3 配置（FEATURE_XHTTP_H3_NODE=false，仅安装 hysteria2）"
else

sed -i "/^[[:space:]]*server_name[[:space:]][[:space:]]*${REALITY_DOMAIN};[[:space:]]*$/a\\
        # BEGIN quic xhttp\\
        location ${XHTTP_PATH} {\\
            grpc_pass 127.0.0.1:8001;\\
            grpc_socket_keepalive on;\\
            grpc_read_timeout     1h;\\
            grpc_send_timeout     1h;\\
            grpc_connect_timeout  15s;\\
            grpc_set_header Host                  \$host;\\
            grpc_set_header X-Real-IP             \$real_client_ip;\\
            grpc_set_header Forwarded             \$proxy_add_forwarded;\\
            grpc_set_header X-Forwarded-For       \$proxy_add_x_forwarded_for;\\
            grpc_set_header X-Forwarded-Proto     \$scheme;\\
        }\\
        # END quic xhttp" "$NGINX_CONF"

if [[ "$QUIC_MODE" == "separate" ]]; then
  sed -i "/^[[:space:]]*# BEGIN quic xhttp$/a\\
        listen ${XHTTP_H3_PORT} quic reuseport;\\
        add_header Alt-Svc 'h3=\":${XHTTP_H3_PORT}\"; ma=86400' always;\\
" "$NGINX_CONF"
  info "已配置 Nginx XHTTP H3: UDP $XHTTP_H3_PORT"
else
  info "已配置 hysteria2 到 Nginx 的 XHTTP 转发"
fi

fi   # FEATURE_XHTTP_H3_NODE

HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_CONF_DIR="/etc/hysteria"
HYSTERIA_CONF="${HYSTERIA_CONF_DIR}/config.yaml"
HYSTERIA_SERVICE="hysteria-server"

if [[ ! -x "$HYSTERIA_BIN" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) HY_ARCH="amd64" ;;
    aarch64|arm64) HY_ARCH="arm64" ;;
    armv7l|armv7) HY_ARCH="arm" ;;
    s390x) HY_ARCH="s390x" ;;
    *) error "不支持的 CPU 架构: $(uname -m)，无法安装 hysteria2" ;;
  esac
  info "下载 hysteria2 (linux-${HY_ARCH})..."
  curl -fsSL -o "$HYSTERIA_BIN" \
    "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" \
    || error "hysteria2 下载失败"
  chmod +x "$HYSTERIA_BIN"
else
  info "检测到已安装 hysteria2，跳过下载"
fi

install -d -m 755 "$HYSTERIA_CONF_DIR"
cat > "$HYSTERIA_CONF" <<EOF
listen: :${HY2_PORT}

tls:
  cert: /etc/ssl/private/fullchain.cer
  key: /etc/ssl/private/private.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://127.0.0.1:8003
    rewriteHost: false
    insecure: true
EOF
chmod 600 "$HYSTERIA_CONF"
info "已写入 hysteria2 配置: $HYSTERIA_CONF"

if [[ "$SERVICE_TYPE" == "openrc" ]]; then
  cat > "/etc/init.d/${HYSTERIA_SERVICE}" <<'EOF'
#!/sbin/openrc-run

name="hysteria-server"
description="Hysteria2 Server"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria-server.pid"
output_log="/var/log/hysteria-server.log"
error_log="/var/log/hysteria-server.log"

depend() {
    need net
}
EOF
  chmod +x "/etc/init.d/${HYSTERIA_SERVICE}"
  rc-update add "$HYSTERIA_SERVICE" default >/dev/null 2>&1 || true
  HYSTERIA_RESTART_CMD="rc-service ${HYSTERIA_SERVICE} restart"
else
  cat > "/etc/systemd/system/${HYSTERIA_SERVICE}.service" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=${HYSTERIA_BIN} server --config ${HYSTERIA_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$HYSTERIA_SERVICE" >/dev/null 2>&1 || true
  HYSTERIA_RESTART_CMD="systemctl restart ${HYSTERIA_SERVICE}"
fi

acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "${HYSTERIA_RESTART_CMD}; ${NGINX_RESTART_CMD}"

install -d -m 700 "$COMMON_STATE_DIR"
cat > "$COMMON_STATE_FILE" <<EOF
QUIC_MODE=${QUIC_MODE}
XHTTP_H3_PORT=${XHTTP_H3_PORT}
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PASSWORD}
EOF
chmod 600 "$COMMON_STATE_FILE"

nginx -t
xray -test -config "$XRAY_CONF"

if [[ "$SERVICE_TYPE" == "openrc" ]]; then
  rc-service "$HYSTERIA_SERVICE" stop >/dev/null 2>&1 || true
else
  systemctl stop "$HYSTERIA_SERVICE" >/dev/null 2>&1 || true
fi
service_restart nginx
service_restart "$HYSTERIA_SERVICE"

if [[ "$SERVICE_TYPE" == "systemd" ]]; then
  sleep 1
  systemctl is-active --quiet "$HYSTERIA_SERVICE" || error "hysteria2 启动失败，请检查 journalctl -u ${HYSTERIA_SERVICE}"
fi
info "Nginx / hysteria2 已重启"
if [[ "$QUIC_MODE" == "separate" ]]; then
  info "XHTTP H3:  Nginx UDP ${XHTTP_H3_PORT}"
  info "hysteria2: UDP ${HY2_PORT}"
else
  info "XHTTP H3 / hysteria2: UDP ${XHTTP_H3_PORT}"
fi

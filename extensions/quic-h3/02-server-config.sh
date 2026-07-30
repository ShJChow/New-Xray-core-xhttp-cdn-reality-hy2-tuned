# ==================================================
# Nginx XHTTP H3 监听
# ==================================================
#
# 照搬上游做法：只往 **CDN 域名的 server 块**插一条 listen quic + Alt-Svc，
# **不新建 location**——主脚本已经在该块里生成了 location ${XHTTP_PATH}
# （grpc_pass 127.0.0.1:8001 + grpc_read_timeout 1h），h3 请求会直接落到它。
#
# 节点侧 sni/host 也用 CDN 域名，与这里的 server_name 字面相等（L11：
# 「监听 + location + server_name + 客户端 sni」必须作为一个整体断言）。

command -v nginx >/dev/null 2>&1 || error "未找到 nginx，请先运行主脚本"
command -v xray  >/dev/null 2>&1 || error "未找到 xray，请先运行主脚本"
nginx -V 2>&1 | grep -q -- '--with-http_v3_module' || error "Nginx 未启用 HTTP/3 模块，请重新运行主脚本"

NGINX_CONF="/etc/nginx/nginx.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
[[ -f "$NGINX_CONF" ]] || error "未找到 $NGINX_CONF"
[[ -f "$XRAY_CONF" ]]  || error "未找到 $XRAY_CONF"
[[ -f /etc/ssl/private/fullchain.cer && -f /etc/ssl/private/private.key ]] || \
  error "未找到证书文件，请先运行主脚本"

# 标记名刻意与 common-nodes 的 `# BEGIN quic xhttp` **不同**：
# 两个扩展都会往 nginx.conf 插 quic 段，共用标记会让后运行的那个把先运行的
# 整段删掉（两者的清理 sed 都按标记范围删）。用独立标记后互不干扰。
sed -i \
  -e '/^[[:space:]]*# BEGIN quic-h3$/,/^[[:space:]]*# END quic-h3$/d' \
  "$NGINX_CONF"

grep -Eq "^[[:space:]]*server_name[[:space:]][[:space:]]*${CDN_DOMAIN};[[:space:]]*$" "$NGINX_CONF" ||
  error "未找到 CDN 域名（${CDN_DOMAIN}）的 Nginx server 块"

sed -i "/^[[:space:]]*server_name[[:space:]][[:space:]]*${CDN_DOMAIN};[[:space:]]*$/a\\
        # BEGIN quic-h3\\
        listen ${XHTTP_H3_PORT} quic reuseport;\\
        add_header Alt-Svc 'h3=\":${XHTTP_H3_PORT}\"; ma=86400' always;\\
        # END quic-h3" "$NGINX_CONF"

# L14：nginx -t 只解析配置、不 bind 端口，`listen ... quic` 的失败恰好落在它的
# 盲区里。所以语法检查通过之后还要单独验证「能否真的启动」，失败就删段回滚，
# 这既是自愈也是一次干净的二分。
nginx -t || { sed -i '/^[[:space:]]*# BEGIN quic-h3$/,/^[[:space:]]*# END quic-h3$/d' "$NGINX_CONF"
              error "nginx -t 未通过，已移除本扩展插入的 quic 段"; }
xray -test -config "$XRAY_CONF"

if ! service_restart nginx; then
  sed -i '/^[[:space:]]*# BEGIN quic-h3$/,/^[[:space:]]*# END quic-h3$/d' "$NGINX_CONF"
  service_restart nginx >/dev/null 2>&1 || true
  command -v journalctl >/dev/null 2>&1 && journalctl -u nginx -n 20 --no-pager | sed 's/^/    /'
  error "Nginx 启动失败，已移除 quic 段并重启。常见原因：UDP ${XHTTP_H3_PORT} 被占用，或本机 SSL 库不支持 QUIC"
fi
if [[ "$SERVICE_TYPE" == "systemd" ]]; then
  sleep 1
  if ! systemctl is-active --quiet nginx; then
    sed -i '/^[[:space:]]*# BEGIN quic-h3$/,/^[[:space:]]*# END quic-h3$/d' "$NGINX_CONF"
    systemctl restart nginx >/dev/null 2>&1 || true
    journalctl -u nginx -n 20 --no-pager | sed 's/^/    /'
    error "Nginx 重启后未处于 active，已移除 quic 段并回滚"
  fi
fi

install -d -m 700 "$QUIC_H3_STATE_DIR"
printf 'XHTTP_H3_PORT=%q\n' "$XHTTP_H3_PORT" > "$QUIC_H3_STATE_FILE"
chmod 600 "$QUIC_H3_STATE_FILE"

info "XHTTP H3 已监听 Nginx UDP ${XHTTP_H3_PORT}（CDN 块，复用已有 location）"

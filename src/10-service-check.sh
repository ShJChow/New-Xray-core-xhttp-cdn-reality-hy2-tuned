# ==================================================
# 启动服务与配置自检
# ==================================================

info "[6/8] 启动服务"

info "配置证书自动续签命令..."
mkdir -p /etc/ssl/private
# 证书文件必须先落地，nginx -t 才能加载，所以 install-cert 只能排在前面。
# 但它的 reloadcmd 会先于我们自己的 nginx -t 重启 nginx：配置有错时 acme 只会打印
# "Reload error"，真正的 nginx 报错被吞掉。因此这里让 reloadcmd 自带 nginx -t，
# 并容忍 acme 的非零返回，把判定权交给紧随其后的显式自检。
acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "nginx -t && ${NGINX_RESTART_CMD}" || \
  warn "acme.sh reloadcmd 返回非零，下面的 Nginx 自检会给出具体原因"

info "测试 Nginx 配置..."
nginx -t || error "Nginx 配置有误，具体报错见上方 nginx -t 输出"

info "测试 Xray 配置..."
xray -test -config /usr/local/etc/xray/config.json

info "启动服务..."
service_restart xray
service_restart nginx
sleep 1
service_is_active xray || error "Xray 启动失败"
service_is_active nginx || error "Nginx 启动失败"
info "Xray 运行中"
info "Nginx 运行中"

echo ""


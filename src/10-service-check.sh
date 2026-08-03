# ==================================================
# 启动服务与配置自检
# ==================================================

info "[5/7] 启动服务"

info "配置证书自动续签命令..."
mkdir -p /etc/ssl/private
# 证书文件必须先落地，nginx -t 才能加载，所以 install-cert 只能排在前面。
# 但它的 reloadcmd 会先于我们自己的 nginx -t 重启 nginx：配置有错时 acme 只会打印
# "Reload error"，真正的 nginx 报错被吞掉。因此这里让 reloadcmd 自带 nginx -t，
# 并容忍 acme 的非零返回，把判定权交给紧随其后的显式自检。
#
# v4.0.0：reloadcmd 必须同时重启 Xray。h3-direct 与 Hysteria2-obfs 两个 inbound
# 直接读 /etc/ssl/private/fullchain.cer（不像 Reality 用自签密钥），证书 60 天
# 续期一次后 Xray 若不重启，会继续用内存里的旧证书直到下次手工重启——
# 表现是「网站证书正常，但这两个节点在续期后某天突然握手失败」。
# Xray 重启放在 nginx 之后且失败不阻断：nginx 承载伪装站，优先级更高。
acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "nginx -t && ${NGINX_RESTART_CMD} && { ${XRAY_RESTART_CMD} || true; }" || \
  warn "acme.sh reloadcmd 返回非零，下面的 Nginx 自检会给出具体原因"

info "测试 Nginx 配置..."
nginx -t || error "Nginx 配置有误，具体报错见上方 nginx -t 输出"

info "测试 Xray 配置..."
xray -test -config /usr/local/etc/xray/config.json

# `nginx -t` 只解析配置，不绑定端口、不初始化 QUIC/TLS 运行时，所以"语法 OK 但
# 启动失败"是完全可能的（端口占用、QUIC 运行时初始化、SELinux 拒绝……）。
# v1.2.2 之前这里是裸调用 service_restart：它返回非零会被 `set -e` 直接中断，
# 连下一行的 error 都执行不到，用户只看到 systemd 一句 "See systemctl status"，
# 拿不到任何根因。下面改为捕获失败 → 打印诊断 → 报出根因。
dump_nginx_failure() {
  echo ""
  echo -e "${YELLOW}[+] Nginx 启动失败诊断${NC}"
  if [[ "$SERVICE_TYPE" == "systemd" ]]; then
    journalctl -xeu nginx.service -n 50 --no-pager 2>/dev/null || \
      warn "无法读取 journalctl"
  else
    rc-service nginx status 2>&1 | tail -20 || true
    tail -50 /var/log/nginx/error.log 2>/dev/null || \
      warn "无法读取 /var/log/nginx/error.log"
  fi
  echo ""
  echo -e "${YELLOW}[+] 端口占用（80 / 443 / 8003）${NC}"
  ss -lntup 2>/dev/null | grep -E ':(80|443|8003)\b' || echo "  （无匹配）"
  # SELinux 拒绝是 RHEL 系上典型的"-t 通过但启动失败"
  command -v getenforce >/dev/null 2>&1 && echo "  SELinux: $(getenforce 2>/dev/null)"
  echo ""
}

info "启动服务..."
service_restart xray || warn "Xray 重启命令返回非零，下面会判定实际服务状态"

if ! service_restart nginx || ! { sleep 1; service_is_active nginx; }; then
  dump_nginx_failure

  error "Nginx 启动失败，根因见上方诊断输出"
fi

service_is_active xray || error "Xray 启动失败"
info "Xray 运行中"
info "Nginx 运行中"

echo ""


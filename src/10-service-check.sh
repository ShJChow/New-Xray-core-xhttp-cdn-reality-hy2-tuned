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

# `nginx -t` 只解析配置，不绑定端口、不初始化 QUIC/TLS 运行时，所以"语法 OK 但
# 启动失败"是完全可能的（端口占用、QUIC 运行时初始化、SELinux 拒绝……）。
# v1.2.2 之前这里是裸调用 service_restart：它返回非零会被 `set -e` 直接中断，
# 连下一行的 error 都执行不到，用户只看到 systemd 一句 "See systemctl status"，
# 拿不到任何根因。下面改为捕获失败 → 打印诊断 → 自动降级重试。
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

  # 自动降级：main-h3 段（UDP 443 quic + http3）是本配置里唯一有 SSL 库依赖、
  # 且唯一在 `nginx -t` 阶段验证不到的部分。去掉它再试一次——这同时也是一次
  # 干净的二分：起来了就是 quic 的问题，还起不来就与 quic 无关（诊断已在上方）。
  if [[ "$FEATURE_H3_DIRECT" == true ]] && grep -q '# BEGIN main-h3' /etc/nginx/nginx.conf; then
    warn "自动降级：移除 UDP 443 quic 监听（main-h3 段）后重试一次"
    sed -i '/^[[:space:]]*# BEGIN main-h3$/,/^[[:space:]]*# END main-h3$/d' /etc/nginx/nginx.conf
    nginx -t || error "移除 quic 段后 nginx -t 反而失败，请把上方输出反馈给项目"

    if service_restart nginx && { sleep 1; service_is_active nginx; }; then
      FEATURE_H3_DIRECT=false
      # node.env 在 [5/8] 已按 true 写入，这里必须同步改回，否则 xh info / xh diag
      # 会在一台没有该监听的机器上报告 H3 已启用。
      sed -i 's/^FEATURE_H3_DIRECT=.*/FEATURE_H3_DIRECT=false/' "$NODE_ENV_FILE" 2>/dev/null || true
      warn "降级成功：Nginx 已启动，但**节点 4（Vless-xhttp-tls-UDP-direct）已停用**"
      warn "根因就是上方诊断里的 quic 相关报错；节点 1-3 不受影响"
      warn "后续客户端配置不会生成该节点，避免留下连不上的死链接"
    else
      dump_nginx_failure
      error "移除 quic 段后 Nginx 仍无法启动，根因与 quic 无关，请看上方两段诊断输出"
    fi
  else
    error "Nginx 启动失败，根因见上方诊断输出"
  fi
fi

service_is_active xray || error "Xray 启动失败"
info "Xray 运行中"
info "Nginx 运行中"

echo ""


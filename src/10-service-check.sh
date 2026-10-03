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
#
# 末尾那段独立 hysteria 的重启是有条件的：本项目默认由 Xray 原生提供 Hysteria2
# （03-xray-install.sh 会停用 hysteria-server），此时它是空转。但装在已有独立
# hysteria 的机器上时，8443 由该二进制提供服务、同样读 /etc/ssl/private/ 的证书，
# 续期后不重启就会一直用旧证书。用 is-active 判断而非无条件重启，避免在没有该
# 服务的机器上让整条 reloadcmd 返回非零。
# reloadcmd 开头那句 xh-trim-chain：acme.sh 每次续期都会把完整 4 张链重新写进
# /etc/ssl/private/fullchain.cer，裁剪结果不会自己留下来，必须在续期后重跑。
# 用 `|| true` 兜底——裁剪失败只是握手多传 1.6KB，绝不该阻断证书续期。
acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "/usr/local/sbin/xh-trim-chain /etc/ssl/private/fullchain.cer 2>/dev/null || true; nginx -t && ${NGINX_RESTART_CMD} && { ${XRAY_RESTART_CMD} || true; }; { command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet hysteria-server 2>/dev/null && systemctl restart hysteria-server; } || true" || \
  warn "acme.sh reloadcmd 返回非零，下面的 Nginx 自检会给出具体原因"

info "测试 Nginx 配置..."
nginx -t || error "Nginx 配置有误，具体报错见上方 nginx -t 输出"

info "测试 Xray 配置..."
if ! xray -test -config /usr/local/etc/xray/config.json; then
  # 可选入站（h2-direct / Hysteria2-Obfs）出问题时，不让它拖垮 Reality 等核心节点：
  # 关掉它们，用同一份模板重新生成配置再试一次。核心节点的配置本身有错时，这里仍然报错退出。
  if [[ "${FEATURE_H2_DIRECT:-false}" == true || "${FEATURE_HY2_OBFS:-false}" == true ]]; then
    warn "Xray 配置校验失败。先关闭可选入站（h2-direct / Hysteria2-Obfs）后重新生成配置再试"
    FEATURE_H2_DIRECT=false
    FEATURE_HY2_OBFS=false
    XRAY_H2_DIRECT_INBOUND=""
    XRAY_HY2_INBOUND=""
    write_xray_config
    sed -i -E "s/^FEATURE_H2_DIRECT=.*/FEATURE_H2_DIRECT=false/; s/^FEATURE_HY2_OBFS=.*/FEATURE_HY2_OBFS='false'/" "$NODE_ENV_FILE" 2>/dev/null || true
    xray -test -config /usr/local/etc/xray/config.json || error "关闭可选入站后 Xray 配置仍然校验失败，核心节点配置有误，见上方输出"
    warn "已关闭 h2-direct / Hysteria2-Obfs 两个可选节点，Reality 等核心节点不受影响。原因见上方 xray -test 输出"
  else
    xray -test -config /usr/local/etc/xray/config.json
  fi
fi

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

# 监听自检：进程在运行不等于端口真的在监听。Reality 在 TCP 443，缺了它节点一定不通，所以单独报错；
# 其余按已开启的节点逐个检查，缺哪个就告诉用户哪个，方便区分「服务端没监听」和「云安全组没放行」。
sleep 1
_listening() {   # $1 = tcp|udp，$2 = 端口
  local flag=-ltnH
  [[ "$1" == udp ]] && flag=-lunH
  ss "$flag" "sport = :$2" 2>/dev/null | grep -q .
}
if _listening tcp 443; then
  info "监听自检：TCP 443（Reality）正常"
else
  warn "监听自检：TCP 443 没有在监听，Reality 节点会不通。查看：journalctl -u xray -n 40 --no-pager；ss -ltnup | grep -E ':443 |xray'"
fi
[[ "${FEATURE_H3_DIRECT:-false}" == true ]] && { _listening udp "$H3_PORT" || warn "监听自检：UDP ${H3_PORT}（XHTTP-Direct-H3）没有在监听"; }
[[ "${FEATURE_HY2_H3:-false}" == true ]] && { _listening udp "${HY2_H3_PORT:-443}" || warn "监听自检：UDP ${HY2_H3_PORT:-443}（Hysteria2-H3）没有在监听"; }
[[ "${FEATURE_HY2_OBFS:-false}" == true ]] && { _listening udp "$HY2_PORT" || warn "监听自检：UDP ${HY2_PORT}（Hysteria2-Obfs）没有在监听"; }
[[ "${FEATURE_H2_DIRECT:-false}" == true ]] && { _listening tcp "$H2_PORT" || warn "监听自检：TCP ${H2_PORT}（XHTTP-Direct-H2）没有在监听"; }

echo ""


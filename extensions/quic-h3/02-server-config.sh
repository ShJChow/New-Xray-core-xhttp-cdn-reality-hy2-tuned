# ==================================================
# Nginx XHTTP H3 监听
# ==================================================
#
# v4.4.1：**不再往 CDN 域名的既有 server 块里插 listen quic**，改为追加一个
# 专用 server 块。
#
# 起因是一次实机故障（2026-08-06）：旧做法往 `listen 8003 ssl` 的 CDN 块里
# 插入 `listen ${PORT} quic reuseport;` + `add_header Alt-Svc ...` 之后，
# **默认的 Vless-xhttp-tls-UDP-cdn 节点连同三条 h3 节点一起不通**，
# nginx error.log 持续报：
#     upstream rejected request with error 5 while reading response header
#     from upstream, upstream: "grpc://127.0.0.1:8001"
# （gRPC error 5 = NOT_FOUND，是 Xray 8001 在拒绝上行 POST）。
# 单变量二分确认：删掉这两行并重启 nginx，主链路立刻恢复。
#
# 机制**未查清**。能排除的是 `add_header`——它只作用于响应，而故障发生在
# 「读上游响应头」之前的请求阶段，响应头改不出 NOT_FOUND；嫌疑因此落在
# `listen ... quic reuseport` 上，但「一个 UDP 监听为何会打死同块 TCP 8003
# 的请求路径」这条因果链没有推出来（L8：没查清就得说没查清）。
#
# 所以这里不去「修那一行」，而是改成**生产路径一个字符都不动**：
#   - h3 监听放进独立 server 块，自带 server_name / 证书 / location；
#   - 主脚本生成的 CDN 块保持原样，故障就无从发生，与机制是什么无关。
# 两个 server 块 server_name 相同但 listen 端口不同，在 nginx 里是各自独立的
# 虚拟服务器，互不影响。
#
# 节点侧 sni/host 仍用 CDN 域名，与这里的 server_name 字面相等（L11：
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
#
# 这条删除同时负责清理 **旧版本插进 CDN 块里的两行**（标记名没变），
# 所以从旧版升级上来的机器重跑本扩展就会自动脱离故障配置。
quic_h3_strip() {
  sed -i '/^[[:space:]]*# BEGIN quic-h3$/,/^[[:space:]]*# END quic-h3$/d' "$NGINX_CONF"
}
quic_h3_strip

grep -Eq "^[[:space:]]*server_name[[:space:]][[:space:]]*${CDN_DOMAIN};[[:space:]]*$" "$NGINX_CONF" ||
  error "未找到 CDN 域名（${CDN_DOMAIN}）的 Nginx server 块"

# ==================================================
# 基线：改动前主链路的行为
# --------------------------------------------------
# L14 的教训还不够——旧版 `nginx -t` 通过、nginx 也 active，主链路照样死。
# 「配置能解析」「进程活着」都不等于「业务还通」。这里改成对**主链路本身**
# 取一次指纹：带 CDN 域名的 SNI 打 8003 上的 XHTTP path，记下 HTTP 状态码。
# 改动后必须**逐字节相同**，否则自动回滚。
#
# 只断言「与改动前一致」，不断言具体值：Xray 对裸 GET 返回什么码取决于版本，
# 写死期望值会在某次上游变更后变成假警报（L23：只断言能证实的东西）。
xhttp_path_probe() {
  curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "${CDN_DOMAIN}:8003:127.0.0.1" \
    "https://${CDN_DOMAIN}:8003${XHTTP_PATH}" 2>/dev/null || echo "ERR"
}

BASELINE_PROBE=""
if command -v curl >/dev/null 2>&1; then
  BASELINE_PROBE=$(xhttp_path_probe)
  info "主链路基线指纹: ${BASELINE_PROBE}（改动后必须一致，否则自动回滚）"
else
  warn "未找到 curl，跳过主链路基线检测——本扩展将无法自动发现「装完主链路反而坏了」"
fi

# ==================================================
# 追加专用 server 块（不触碰任何既有块）
# --------------------------------------------------
# location ${XHTTP_PATH} 的 grpc_* 参数与主脚本 templates/nginx.conf.tmpl 的
# CDN 块保持一致（长连接超时 1h 等），因为落到的是同一个 Xray 8001 inbound。
# location / 直接 404：本块只在直连 VPS 的 h3 端口上可达，不是伪装门面；
# 在这里再挂一套回落反代属于无谓的攻击面（L25：指不出故障现象就不加）。
QUIC_H3_BLOCK=$(cat <<NGXEOF
    # BEGIN quic-h3
    server {
        listen ${XHTTP_H3_PORT} quic reuseport;
        server_name ${CDN_DOMAIN};

        ssl_certificate /etc/ssl/private/fullchain.cer;
        ssl_certificate_key /etc/ssl/private/private.key;

        location ${XHTTP_PATH} {
            grpc_pass 127.0.0.1:8001;
            grpc_socket_keepalive on;
            grpc_read_timeout     1h;
            grpc_send_timeout     1h;
            grpc_connect_timeout  15s;
            grpc_set_header Host                  \$host;
            grpc_set_header X-Real-IP             \$real_client_ip;
            grpc_set_header Forwarded             \$proxy_add_forwarded;
            grpc_set_header X-Forwarded-For       \$proxy_add_x_forwarded_for;
            grpc_set_header X-Forwarded-Proto     \$scheme;
        }

        location / {
            return 404;
        }
    }
    # END quic-h3
NGXEOF
)

# 插到 http{} 的末尾——即文件最后一个 `}` 之前。用 awk 按行号定位，
# 不用 `sed '$i'`：后者在文件末尾有空行时会插到 http{} 外面，产生
# 「server directive is not allowed here」。
NGINX_TMP=$(mktemp)
LAST_BRACE=$(grep -n '^}' "$NGINX_CONF" | tail -n1 | cut -d: -f1)
[[ -n "$LAST_BRACE" ]] || error "无法定位 nginx.conf 的 http{} 结束位置，已中止（未修改任何文件）"
awk -v ln="$LAST_BRACE" -v block="$QUIC_H3_BLOCK" \
  'NR==ln { print block } { print }' "$NGINX_CONF" > "$NGINX_TMP"
cat "$NGINX_TMP" > "$NGINX_CONF"
rm -f "$NGINX_TMP"

# ==================================================
# 三道验证，任一失败都回滚到「本扩展从未运行过」的状态
# --------------------------------------------------
nginx -t || { quic_h3_strip
              error "nginx -t 未通过，已移除本扩展插入的 server 块"; }
xray -test -config "$XRAY_CONF"

quic_h3_rollback() {
  quic_h3_strip
  service_restart nginx >/dev/null 2>&1 || true
}

# ① 能否真的启动（L14：nginx -t 不 bind 端口，listen quic 的失败落在它盲区里）
if ! service_restart nginx; then
  quic_h3_rollback
  command -v journalctl >/dev/null 2>&1 && journalctl -u nginx -n 20 --no-pager | sed 's/^/    /'
  error "Nginx 启动失败，已移除 quic 段并重启。常见原因：UDP ${XHTTP_H3_PORT} 被占用，或本机 SSL 库不支持 QUIC"
fi

# ② 启动后是否稳定在 active
if [[ "$SERVICE_TYPE" == "systemd" ]]; then
  sleep 1
  if ! systemctl is-active --quiet nginx; then
    quic_h3_rollback
    journalctl -u nginx -n 20 --no-pager | sed 's/^/    /'
    error "Nginx 重启后未处于 active，已移除 quic 段并回滚"
  fi
fi

# ③ **主链路是否还活着**——这一条是 2026-08-06 那次故障后新增的。
# 前两条在那次故障里全部通过，却放行了一个打死默认 CDN 节点的配置。
if [[ -n "$BASELINE_PROBE" ]]; then
  AFTER_PROBE=$(xhttp_path_probe)
  if [[ "$AFTER_PROBE" != "$BASELINE_PROBE" ]]; then
    quic_h3_rollback
    error "主链路指纹在本扩展安装后发生变化（${BASELINE_PROBE} → ${AFTER_PROBE}），
    这意味着默认 CDN 节点可能已被打断。已回滚到安装前状态，nginx 已重启。
    请把这两个值反馈到 ${PROJECT_REPO} 的 issue。"
  fi
  info "主链路指纹未变（${AFTER_PROBE}），默认 CDN 节点未受影响"
fi

install -d -m 700 "$QUIC_H3_STATE_DIR"
printf 'XHTTP_H3_PORT=%q\n' "$XHTTP_H3_PORT" > "$QUIC_H3_STATE_FILE"
chmod 600 "$QUIC_H3_STATE_FILE"

info "XHTTP H3 已监听 Nginx UDP ${XHTTP_H3_PORT}（独立 server 块，不触碰 CDN 块）"

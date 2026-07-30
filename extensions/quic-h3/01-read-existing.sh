# ==================================================
# 读取已有节点参数（XHTTP over HTTP/3，上游 add-quic.sh 的移植）
# ==================================================
#
# 与 extensions/common-nodes 的分工：
#   common-nodes  → Hysteria2-direct（独立协议，独立端口）
#   quic-h3（本扩展）→ 三条 XHTTP over h3 节点
#
# 本扩展照搬上游 Yulinanami/my-xhttp-cdn-config 的设计，与 common-nodes 的
# h3 节点有一处**根本差异**（见 tasks/lessons.md L11 / L12）：
#   上游：quic 监听插进 **CDN 域名**的 server 块，节点 sni/host 都用 CDN 域名，
#         复用该块**已有的** location ${XHTTP_PATH}（主脚本已经生成好了）；
#   本项目 common-nodes：插进 Reality 块并自建 location，sni 用 Reality 域名。
# 两者各自内部自洽，但上游那套不需要额外 location，且 SNI 与 server_name 的
# 配对关系更直观。本扩展保持上游写法，不做「风格统一」（L18）。

echo -e "\n${CYAN}[+] 添加扩展模式：XHTTP over HTTP/3（三条节点）${NC}\n"
echo -e "${YELLOW}[+] 前置条件${NC}"
echo "  1. 已经成功运行主脚本"
echo "  2. Nginx 需已编译 http_v3_module（主脚本默认满足）"
echo "  3. CDN 域名的 DNS 需保持橙云代理，且 Cloudflare 侧已开启 HTTP/3"
echo ""

find_client_files
info "读取已有客户端配置: $USER_HOME"

BASE_LINE=$(find_node_line "$V2RAYN_FILE" "$NODE_RE_XHTTP_REALITY")
[[ -n "$BASE_LINE" ]] || error "未找到 xhttp+Reality 节点，无法自动读取参数"

# 本扩展的三条节点全部用 CDN 域名做 SNI/host，所以 CDN 域名是**硬依赖**，
# 读不到就不能继续（与 common-nodes 里它是可选项不同，见 L33）。
CDN_LINE=$(find_node_line "$V2RAYN_FILE" "$NODE_RE_CDN_BOTH")
[[ -n "$CDN_LINE" ]] || error "未找到经 CDN 的 xhttp+TLS 节点，无法读取 CDN 域名。
    请确认主脚本已生成 Vless-xhttp-tls-UDP-cdn 节点后再运行本扩展"

BASE_SERVER=$(strip_ipv6_brackets "$(extract_uri_server "$BASE_LINE")")
UUID2=$(extract_uri_user "$BASE_LINE")
XHTTP_PATH=$(get_query_param "$BASE_LINE" "path" || true)
REALITY_DOMAIN=$(get_query_param "$BASE_LINE" "sni" || true)
VLESSENC_ENCRYPTION=$(get_query_param "$BASE_LINE" "encryption" || true)
XHTTP_EXTRA=$(get_query_param "$BASE_LINE" "extra" || true)
CDN_DOMAIN=$(get_query_param "$CDN_LINE" "host" || true)
ECH_PARAM=$(get_query_param "$CDN_LINE" "ech" || true)

[[ -n "$UUID2" ]]                || error "读取 UUID2 失败"
[[ -n "$BASE_SERVER" ]]          || error "读取 VPS 地址失败"
[[ -n "$XHTTP_PATH" ]]           || error "读取 XHTTP Path 失败"
[[ -n "$REALITY_DOMAIN" ]]       || error "读取 Reality 域名失败"
[[ -n "$CDN_DOMAIN" ]]           || error "读取 CDN 域名失败"
[[ -n "$VLESSENC_ENCRYPTION" ]]  || error "读取 VLESS Encryption 失败"

if [[ -n "$XHTTP_EXTRA" ]]; then
  XHTTP_PADDING_KEY=$(sed -n 's/.*"xPaddingKey":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
  XHTTP_PADDING_HEADER=$(sed -n 's/.*"xPaddingHeader":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
  XHTTP_PADDING_PLACEMENT=$(sed -n 's/.*"xPaddingPlacement":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
  XHTTP_PADDING_METHOD=$(sed -n 's/.*"xPaddingMethod":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
fi

info "VPS 地址:     $BASE_SERVER"
info "CDN 域名:     $CDN_DOMAIN"
info "XHTTP Path:   $XHTTP_PATH"
echo ""

# ---------- H3 端口 ----------
QUIC_H3_STATE_DIR="/etc/xhttp-cdn"
QUIC_H3_STATE_FILE="${QUIC_H3_STATE_DIR}/quic-h3.env"
[[ -f "$QUIC_H3_STATE_FILE" ]] && . "$QUIC_H3_STATE_FILE"

read -rp "请输入 XHTTP H3 UDP 端口 [1-65535] (默认 ${XHTTP_H3_PORT:-443}): " _port
XHTTP_H3_PORT=${_port:-${XHTTP_H3_PORT:-443}}
[[ "$XHTTP_H3_PORT" =~ ^[0-9]+$ ]] || error "端口必须是数字"
(( XHTTP_H3_PORT >= 1 && XHTTP_H3_PORT <= 65535 )) || error "端口必须在 1-65535 之间"

# Hysteria2 扩展可能已经占了这个 UDP 端口，抢占会让后装的那个静默失效
if [[ -f /etc/hysteria/config.yaml ]] &&
   grep -Eq "^[[:space:]]*listen:[[:space:]]*:${XHTTP_H3_PORT}[[:space:]]*$" /etc/hysteria/config.yaml; then
  error "UDP ${XHTTP_H3_PORT} 已被 Hysteria2 占用，请换一个端口（Hysteria2 默认 8443）"
fi

info "XHTTP H3:     UDP ${XHTTP_H3_PORT}"

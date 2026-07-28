# ==================================================
# 客户端配置生成
# ==================================================

info "[7/8] 生成客户端配置"
XHTTP_PATH_ENC=${XHTTP_PATH//\//%2F}

# ==================================================
# TUN 模式下的节点自身流量豁免（v1.2.3）
# ==================================================
# 症状：开启 TUN 后 TCP 节点（1/2）正常，两条 UDP/h3 节点（3/4）全不通。
# 节点 3 的 server 是 CDN 域名、节点 4 是裸 IP，两者唯一的共同点就是 QUIC。
#
# 机制：TUN 用 auto-route 把默认路由指向自己，Mihomo 自己发往节点服务器的包
# 会被自家 TUN 再次捕获，按 rules 兜到 MATCH,漏网之鱼 → 又送回代理 → 环路。
# TCP 之所以不受影响，是因为 dialer 绑定物理接口的保护在 TCP 路径上更完整；
# QUIC 是无连接的 UDP，同样的保护在多数平台上兜不住。
#
# 三道防线，越靠前越根本：
#   ① tun.route-exclude-address：让节点流量**根本不进 TUN**（最根本）
#   ② rules 首条 DIRECT：万一进了 TUN，也在第一条就放出去
#   ③ sniffer.skip-dst-address：即使被 TUN 捞到，也不许改写目标地址
# 字段名均已核对 mihomo 源码（listener/config/tun.go、config/config.go:373-378）。
if [[ "$IP_CHOICE" == "2" ]]; then
  VPS_IP_CIDR="${VPS_IP}/128"
  MIHOMO_NODE_DIRECT_RULE="  - IP-CIDR6,${VPS_IP_CIDR},全局直连,no-resolve"
else
  VPS_IP_CIDR="${VPS_IP}/32"
  MIHOMO_NODE_DIRECT_RULE="  - IP-CIDR,${VPS_IP_CIDR},全局直连,no-resolve"
fi

rm -f /etc/xhttp-cdn/dual-cdn-domains /etc/xhttp-cdn/dual-ip-domains 2>/dev/null || true

if [[ "$FEATURE_XPADDING" == true ]]; then
  XPAD_FIELDS_ENC="%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingMethod%22%3A%22${XHTTP_PADDING_METHOD}%22%2C%22xPaddingPlacement%22%3A%22${XHTTP_PADDING_PLACEMENT}%22%2C%22xPaddingHeader%22%3A%22${XHTTP_PADDING_HEADER}%22%2C%22xPaddingKey%22%3A%22${XHTTP_PADDING_KEY}%22"
  # ------------------------------------------------------------------
  # xmux 参数（已按 Xray-core transport/internet/splithttp/mux.go 核对语义）
  #
  #   cMaxReuseTimes: 0    → leftUsage = -1，**无限复用**，不是"不复用"
  #   hKeepAlivePeriod: 0  → h3 取 quic-go 默认、h2 取 Chrome 默认，不是"禁用"
  #                          （负值才是禁用，见 dialer.go:154-186）
  #   hMaxRequestTimes 未设 → LeftRequests = MaxInt32，无限
  # 上面三项写死为"采用默认"，把它们改成拍脑袋的正值等于覆盖掉更好的默认（L16），
  # 所以本次调优一律不动。
  #
  # maxConcurrency 是唯一真实旋钮：每条底层连接的并发请求上限，超了才开新连接。
  # ------------------------------------------------------------------
  XMUX_ENC="%22xmux%22%3A%7B%22maxConcurrency%22%3A%2232-64%22%2C%22cMaxReuseTimes%22%3A0%2C%22hMaxReusableSecs%22%3A%223600-6000%22%2C%22hKeepAlivePeriod%22%3A0%7D"
  # h3 专用变量：现已与其余节点取同一个值，保留变量只为让 h3 节点的取值点保持显式。
  #
  # 【v1.2.8：64-128 回滚为 32-64——此前那个"假设"已被源码证伪】
  # v1.2.7 曾把 h3 节点提到 64-128，理由是 QUIC 无队头阻塞、单连接多流可省 CF 侧握手，
  # 但同时记录了一个未排除的反向机制。核对 Xray v26.3.27 源码后该反向机制成立：
  #
  #   transport/internet/splithttp/mux.go:92-105
  #     if m.concurrency > 0 {
  #         for _, xmuxClient := range m.xmuxClients {
  #             if xmuxClient.OpenUsage.Load() < m.concurrency { ... }
  #         }
  #     }
  #     if len(xmuxClients) == 0 { return m.newXmuxClient() }   // 只有自己的计数满了才开新连接
  #
  # xmux 只统计自己的 OpenUsage，对对端 QUIC 的 MAX_STREAMS 毫无感知。若 Cloudflare
  # 边缘授予的并发流数低于 128，quic-go 会阻塞在建流上，而 xmux 因为自己的计数没满、
  # 不会另开连接——实际并行度反而低于 32-64。CF 边缘的并发流上限通常在 100 附近，
  # 128 落在危险区，故取 64 上限留足余量。
  # h2 侧本来就没跟进：h2 跑在单条 TCP 上，拉高并发会放大队头阻塞。
  XMUX_H3_ENC="%22xmux%22%3A%7B%22maxConcurrency%22%3A%2232-64%22%2C%22cMaxReuseTimes%22%3A0%2C%22hMaxReusableSecs%22%3A%223600-6000%22%2C%22hKeepAlivePeriod%22%3A0%7D"
  XPAD_EXTRA_ENC="%7B${XPAD_FIELDS_ENC}%2C${XMUX_ENC}%7D"
  SC_MIN_POSTS_ENC="%22scMinPostsIntervalMs%22%3A30"

  EXTRA_2_PARAM="&extra=${XPAD_EXTRA_ENC}"
  EXTRA_4_PARAM="&extra=%7B${XPAD_FIELDS_ENC}%2C${SC_MIN_POSTS_ENC}%2C${XMUX_H3_ENC}%7D"

  MIHOMO_XPADDING_XHTTP_BLOCK=$(cat <<EOF

      x-padding-obfs-mode: true
      x-padding-key: "${XHTTP_PADDING_KEY}"
      x-padding-header: "${XHTTP_PADDING_HEADER}"
      x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
      x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
)
  # 上下行分离节点的 download-settings 比 xhttp-opts 深一级，缩进各 +2
  MIHOMO_XPADDING_DOWNLOAD_BLOCK=$(cat <<EOF

        x-padding-obfs-mode: true
        x-padding-key: "${XHTTP_PADDING_KEY}"
        x-padding-header: "${XHTTP_PADDING_HEADER}"
        x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
        x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
)
  MIHOMO_SC_MIN_POSTS_BLOCK=$(cat <<EOF

      sc-min-posts-interval-ms: 30
EOF
)
  MIHOMO_REUSE_KEEPALIVE_XHTTP=$(cat <<EOF

        h-keep-alive-period: 0
EOF
)
  MIHOMO_REUSE_KEEPALIVE_DOWNLOAD=$(cat <<EOF

          h-keep-alive-period: 0
EOF
)
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  MIHOMO_ECH_PROXY_BLOCK=$(cat <<EOF

    ech-opts:
      enable: true
      query-server-name: cloudflare-ech.com
EOF
)
  MIHOMO_ECH_DOWNLOAD_BLOCK=$(cat <<EOF

        ech-opts:
          enable: true
          query-server-name: cloudflare-ech.com
EOF
)
fi

# 直连 VPS 的 XHTTP-over-H3 节点依赖 Nginx 的 UDP 443 quic 监听（见
# src/09-server-config.sh 的 NGINX_H3_DIRECT_BLOCK），该监听曾在部分环境下
# 导致 nginx 启动失败。FEATURE_H3_DIRECT=false 时两者一起关闭，避免生成一个
# 打不通的节点链接。
if [[ "$FEATURE_H3_DIRECT" == true ]]; then
  # 直连节点走的是 VPS 自己的 UDP 443，不经过 CDN：sni/host 必须用 Reality 域名
  # （Cloudflare 灰云、DNS 直指 VPS），才能命中 Nginx 里带 quic 监听的那个
  # server 块（见 src/09-server-config.sh 的 NGINX_H3_DIRECT_BLOCK）。
  # 换行符写在变量里（而不是模板里单独占一行）：FEATURE_H3_DIRECT=false 时
  # 变量为空，订阅文件不会多出一个空行——空行会被部分客户端解析成非法节点。
  NODE_UDP_DIRECT_LINE=$'\n'"vless://${UUID2}@${VPS_IP_URI}:443?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${REALITY_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0&type=xhttp&host=${REALITY_DOMAIN}&path=${XHTTP_PATH}&mode=auto${EXTRA_4_PARAM}#Vless-xhttp-tls-UDP-direct-${HOSTNAME_TAG}"
  # Mihomo 同样支持 alpn: [h3]（transport/xhttp/client.go:159）
  MIHOMO_UDP_DIRECT_BLOCK=$(cat <<EOF


  - name: Vless-xhttp-tls-UDP-direct-${HOSTNAME_TAG}
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    network: xhttp
    alpn:
      - h3
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    encryption: ${VLESSENC_ENCRYPTION}
    xhttp-opts:
      host: ${REALITY_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}${MIHOMO_SC_MIN_POSTS_BLOCK}
      reuse-settings:
        # 与 URI 版（XMUX_H3_ENC）保持一致：本节点同为 h3
        # v1.2.8 随 XMUX_H3_ENC 一起回滚 64-128 → 32-64，理由见上方 XMUX_H3_ENC 注释
        max-concurrency: "32-64"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "3600-6000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}
EOF
)
else
  NODE_UDP_DIRECT_LINE=""
  MIHOMO_UDP_DIRECT_BLOCK=""
fi

cat > "$USER_HOME/client-config.txt" << CLIENTEOF
@@include templates/client-config.txt.tmpl
CLIENTEOF

MIHOMO_FULL_FILE="$USER_HOME/client-config-mihomo-full.yaml"
MIHOMO_NODES_FILE="$USER_HOME/client-config-mihomo-nodes.yaml"

# 完整分流配置：保留用户选择的 ECH 配置
cat > "$MIHOMO_FULL_FILE" << MIHOMOEOF
@@include templates/mihomo-full.yaml.tmpl
MIHOMOEOF

cat > "$MIHOMO_NODES_FILE" << MIHOMOEOF
@@include templates/mihomo-nodes.yaml.tmpl
MIHOMOEOF

chown "$(stat -c '%u:%g' "$USER_HOME")" \
  "$USER_HOME/client-config.txt" \
  "$MIHOMO_FULL_FILE" \
  "$MIHOMO_NODES_FILE"

# ==================================================
# 客户端配置生成
# ==================================================

info "[6/7] 生成客户端配置"
VISION_FLOW="${VISION_FLOW:-xtls-rprx-vision}"
XHTTP_PATH_ENC=${XHTTP_PATH//\//%2F}

if [[ -z "${VPS_IP_URI:-}" ]]; then
  if [[ "$IP_CHOICE" == "2" ]]; then
    VPS_IP_URI="[${VPS_IP}]"
  else
    VPS_IP_URI="${VPS_IP}"
  fi
fi

if [[ -z "${XHTTP_ENCRYPTION:-}" ]]; then
  if [[ "${FEATURE_XHTTP_VLESSENC:-true}" == true && -n "${VLESSENC_ENCRYPTION:-}" ]]; then
    XHTTP_ENCRYPTION="$VLESSENC_ENCRYPTION"
  else
    XHTTP_ENCRYPTION="none"
  fi
fi

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

# xmux 参数依据 Xray 官方文档及 #4113 建议：
#   maxConcurrency: 16-32  → 兼顾多路复用与抗审查
#   cMaxReuseTimes: 0      → leftUsage = -1，无限复用
#   hMaxRequestTimes: 600-900 → 避免 Nginx 单连接累计 1000 请求断开
#   hMaxReusableSecs: 1800-3000 → 定期切换主连接消除特征
#   hKeepAlivePeriod: 0    → h3 取 quic-go 默认、h2 取 Chrome 默认
# ---------- XHTTP packet-up 的最小 POST 间隔（v4.9.1） ----------
# CDN 两条节点必须走 packet-up（见下方 stream-up 的实测反证），packet-up 把上行
# 切成一串 POST，两次 POST 之间有一个最小间隔。这个间隔就是 CDN 节点延迟的**主项**，
# 不是 Cloudflare 边缘慢。实测（经 CF，socks 打 gstatic/generate_204，各 9 个样本）：
#
#   间隔 30ms（旧默认）  中位 21.7ms   p95 45.6ms
#   间隔 10ms（现默认）  中位 12.2ms   p95 70.0ms
#   间隔  1ms            中位 10.3ms   p95 38.8ms
#
# 20MB 下载吞吐三档无差别（328~546 Mbps，波动来自 CF 边缘本身），
# 也就是说这一项是纯延迟收益、不用拿吞吐换。
#
# 取 10 而不是 1：间隔越小，单位时间内打给 CDN 的请求数越多——收益从 30→10 已经
# 拿到大头（−9.5ms），10→1 只再省 1.9ms，不值得为此把请求速率再抬一个数量级
# （请求数是 CDN 侧最容易做特征的维度之一）。
# 需要时可用环境变量覆盖：XHTTP_SC_MIN_POSTS_MS=30 bash install.sh
XHTTP_SC_MIN_POSTS_MS=${XHTTP_SC_MIN_POSTS_MS:-10}

# ---------- Hysteria2 客户端带宽声明（v4.9.24） ----------
# 链接里的 upmbps / downmbps 在 **sing-box 内核（v2rayN 的 Hysteria2 默认走它）与 Mihomo** 下会启用
# Brutal，按声明速率硬发；**Xray 内核下无可测效果**。它应当约等于用户自己的真实线路带宽，
# 生成器猜不出每个人的线路，只能给默认值。实测（netns，160ms RTT，sing-box 客户端，上行 Mbps）：
#
#   声明 ↑    线路 300↓/50↑（无丢包 / 下行1%）   线路 1000↓/300↑（无丢包 / 下行1%）
#   100          41 / 42                          85 / 85      ← 快上行被硬卡在 ~89
#   300          —  / 27                         190 / 175
#   1000         31 / 33                         163 / 167
#   不声明(BBR)   40 / 13                         171 / 160
#
# 没有哪个值两头都赢：调高后快上行翻倍，但慢上行掉 25~35%（超发把自己的上行队列灌满，
# 上传期间同线路并行 ping 也更高）；不声明在「慢上行 + 丢包」下跌到 13。
# 默认保持 100：国内家宽上行多在 30~100 Mbps，100 离主流最近。上行快（≥300）的用户应设成
# 接近自己真实上行的值：HY2_UP_MBPS=300 bash install.sh；或在客户端里直接改节点的上行带宽。
HY2_UP_MBPS=${HY2_UP_MBPS:-100}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS:-1000}

XMUX_ENC="%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%2C%22cMaxReuseTimes%22%3A0%2C%22hMaxRequestTimes%22%3A%22600-900%22%2C%22hMaxReusableSecs%22%3A%221800-3000%22%2C%22hKeepAlivePeriod%22%3A0%7D"

if [[ "$FEATURE_XPADDING" == true ]]; then
  XPAD_FIELDS_ENC="%22xPaddingBytes%22%3A%22100-1000%22%2C%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingMethod%22%3A%22${XHTTP_PADDING_METHOD}%22%2C%22xPaddingPlacement%22%3A%22${XHTTP_PADDING_PLACEMENT}%22%2C%22xPaddingHeader%22%3A%22${XHTTP_PADDING_HEADER}%22%2C%22xPaddingKey%22%3A%22${XHTTP_PADDING_KEY}%22"
  XPAD_EXTRA_ENC="%7B${XPAD_FIELDS_ENC}%2C${XMUX_ENC}%7D"
  XPAD_CDN_EXTRA_ENC="%7B${XPAD_FIELDS_ENC}%2C%22scMinPostsIntervalMs%22%3A${XHTTP_SC_MIN_POSTS_MS}%2C${XMUX_ENC}%7D"

  MIHOMO_XPADDING_XHTTP_BLOCK=$(cat <<EOF

      x-padding-bytes: "100-1000"
      x-padding-obfs-mode: true
      x-padding-key: "${XHTTP_PADDING_KEY}"
      x-padding-header: "${XHTTP_PADDING_HEADER}"
      x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
      x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
)
  # 上下行分离节点的 download-settings 比 xhttp-opts 深一级，缩进各 +2
  MIHOMO_XPADDING_DOWNLOAD_BLOCK=$(cat <<EOF

          x-padding-bytes: "100-1000"
          x-padding-obfs-mode: true
          x-padding-key: "${XHTTP_PADDING_KEY}"
          x-padding-header: "${XHTTP_PADDING_HEADER}"
          x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
          x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
)
  MIHOMO_SC_MIN_POSTS_BLOCK=$(cat <<EOF

      sc-min-posts-interval-ms: ${XHTTP_SC_MIN_POSTS_MS}
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
else
  XPAD_FIELDS_ENC=""
  XPAD_EXTRA_ENC="%7B${XMUX_ENC}%7D"
  XPAD_CDN_EXTRA_ENC="%7B%22scMinPostsIntervalMs%22%3A${XHTTP_SC_MIN_POSTS_MS}%2C${XMUX_ENC}%7D"
  MIHOMO_XPADDING_XHTTP_BLOCK=""
  MIHOMO_XPADDING_DOWNLOAD_BLOCK=""
  MIHOMO_SC_MIN_POSTS_BLOCK=""
  MIHOMO_REUSE_KEEPALIVE_XHTTP=""
  MIHOMO_REUSE_KEEPALIVE_DOWNLOAD=""
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  DOWNLOAD_TLS_ENC="%22tlsSettings%22%3A%7B%22serverName%22%3A%22${CDN_DOMAIN}%22%2C%22allowInsecure%22%3Afalse%2C%22alpn%22%3A%5B%22h2%22%2C%22http%2F1.1%22%5D%2C%22fingerprint%22%3A%22chrome%22%2C%22ech%22%3A%22${CDN_ECH_QUERY_ENC}%22%7D"
else
  DOWNLOAD_TLS_ENC="%22tlsSettings%22%3A%7B%22serverName%22%3A%22${CDN_DOMAIN}%22%2C%22allowInsecure%22%3Afalse%2C%22alpn%22%3A%5B%22h2%22%2C%22http%2F1.1%22%5D%2C%22fingerprint%22%3A%22chrome%22%7D"
fi
if [[ "$FEATURE_XPADDING" == true ]]; then
  DOWNLOAD_XHTTP_ENC="%22xhttpSettings%22%3A%7B%22host%22%3A%22${CDN_DOMAIN}%22%2C%22path%22%3A%22${XHTTP_PATH_ENC}%22%2C%22mode%22%3A%22auto%22%2C%22extra%22%3A%7B${XPAD_FIELDS_ENC}%2C%22scMinPostsIntervalMs%22%3A${XHTTP_SC_MIN_POSTS_MS}%2C${XMUX_ENC}%7D%7D"
  DOWNLOAD_SETTINGS_ENC="%22downloadSettings%22%3A%7B%22address%22%3A%22${CDN_DOMAIN}%22%2C%22port%22%3A443%2C%22network%22%3A%22xhttp%22%2C%22security%22%3A%22tls%22%2C${DOWNLOAD_TLS_ENC}%2C${DOWNLOAD_XHTTP_ENC}%7D"
  XPAD_SPLIT_EXTRA_ENC="%7B${XPAD_FIELDS_ENC}%2C%22scMinPostsIntervalMs%22%3A${XHTTP_SC_MIN_POSTS_MS}%2C${XMUX_ENC}%2C${DOWNLOAD_SETTINGS_ENC}%7D"
else
  DOWNLOAD_XHTTP_ENC="%22xhttpSettings%22%3A%7B%22host%22%3A%22${CDN_DOMAIN}%22%2C%22path%22%3A%22${XHTTP_PATH_ENC}%22%2C%22mode%22%3A%22auto%22%2C%22extra%22%3A%7B%22scMinPostsIntervalMs%22%3A${XHTTP_SC_MIN_POSTS_MS}%2C${XMUX_ENC}%7D%7D"
  DOWNLOAD_SETTINGS_ENC="%22downloadSettings%22%3A%7B%22address%22%3A%22${CDN_DOMAIN}%22%2C%22port%22%3A443%2C%22network%22%3A%22xhttp%22%2C%22security%22%3A%22tls%22%2C${DOWNLOAD_TLS_ENC}%2C${DOWNLOAD_XHTTP_ENC}%7D"
  XPAD_SPLIT_EXTRA_ENC="%7B%22scMinPostsIntervalMs%22%3A${XHTTP_SC_MIN_POSTS_MS}%2C${XMUX_ENC}%2C${DOWNLOAD_SETTINGS_ENC}%7D"
fi

if [[ "${FEATURE_REALITY_UP_CDN_DOWN:-true}" == true || "${FEATURE_UP_CDN_DOWN_MIHOMO:-true}" == true ]]; then
  REALITY_UP_CDN_DOWN_NODE_LINE="vless://${UUID2}@${VPS_IP_URI}:443?encryption=${XHTTP_ENCRYPTION}&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&alpn=h2,http%2F1.1&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=auto${XPAD_SPLIT_EXTRA_ENC:+&extra=${XPAD_SPLIT_EXTRA_ENC}}#VLESS-Reality-Up-CDN-Down${NODE_SUFFIX}"
else
  REALITY_UP_CDN_DOWN_NODE_LINE=""
fi

# 上行腿用 h3（v4.9.30）：netns 160ms RTT / 1% 丢包实测，上行 h2 11 Mbps（3 次均为 11）
# → h3 102 Mbps（73~140），下行持平（93 → 102）。h2 经 Cloudflare 的上行被卡在 packet-up 的逐请求往返上。
# 反向分离（v4.9.29，FEATURE_CDN_UP_REALITY_DOWN）：上行 XHTTP+TLS 经 CDN，
# 下行 downloadSettings 直连 VPS 的 Reality 443。两条腿都落到 8001 入站，
# 因此共用 UUID2 / path / XHTTP_ENCRYPTION。下行腿的 extra 与 Reality-XHTTP 直连节点一致；
# 上行腿的 extra 与 CDN 节点一致（含 scMinPostsIntervalMs，packet-up 经 CDN 需要）。
# IPv6 地址在 JSON 里不加方括号，但冒号要编码。
REALITY_DOWNLOAD_ENC="%22downloadSettings%22%3A%7B%22address%22%3A%22${VPS_IP//:/%3A}%22%2C%22port%22%3A443%2C%22network%22%3A%22xhttp%22%2C%22security%22%3A%22reality%22%2C%22realitySettings%22%3A%7B%22serverName%22%3A%22${REALITY_DOMAIN}%22%2C%22fingerprint%22%3A%22chrome%22%2C%22publicKey%22%3A%22${PUBLIC_KEY}%22%2C%22shortId%22%3A%22${SHORT_ID}%22%2C%22spiderX%22%3A%22%22%7D%2C%22xhttpSettings%22%3A%7B%22path%22%3A%22${XHTTP_PATH_ENC}%22%2C%22mode%22%3A%22auto%22%2C%22extra%22%3A${XPAD_EXTRA_ENC}%7D%7D"
XPAD_REV_SPLIT_EXTRA_ENC="${XPAD_CDN_EXTRA_ENC%\%7D}%2C${REALITY_DOWNLOAD_ENC}%7D"
if [[ "${FEATURE_CDN_UP_REALITY_DOWN:-false}" == true ]]; then
  CDN_UP_REALITY_DOWN_NODE_LINE="vless://${UUID2}@${CDN_DOMAIN}:443?encryption=${XHTTP_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0${CDN_ECH_QUERY_ENC:+&ech=${CDN_ECH_QUERY_ENC}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH}&mode=auto&extra=${XPAD_REV_SPLIT_EXTRA_ENC}#VLESS-CDN-Up-Reality-Down${NODE_SUFFIX}"
else
  CDN_UP_REALITY_DOWN_NODE_LINE=""
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  MIHOMO_ECH_PROXY_BLOCK=$(cat <<EOF

    ech-opts:
      enable: true
      query-server-name: cloudflare-ech.com
EOF
)
  # v4.9.31：缩进必须与 download-settings 的子项一致（8 格）。此前写成 6 格，
  # ech-opts 变成与 download-settings 平级，紧随其后的 reality-opts / path / host /
  # reuse-settings 全被 YAML 归到 ech-opts 名下——download-settings 里没了
  # 「reality-opts: { public-key: "" }」，mihomo 对 Cloudflare 做 Reality 握手，
  # 报 REALITY authentication failed（开启 ECH 的机器自 v4.9.20 起均受影响）。
  MIHOMO_ECH_DOWNLOAD_BLOCK=$(cat <<EOF

        ech-opts:
          enable: true
          query-server-name: cloudflare-ech.com
EOF
)
else
  MIHOMO_ECH_PROXY_BLOCK=""
  MIHOMO_ECH_DOWNLOAD_BLOCK=""
fi

# v4.0.0 节点集：3 条 QUIC/h3 + 2 条 TCP 兜底，全部由 Xray 单核心提供。
# 两条直连 UDP 节点（h3-direct / Hysteria2）依赖 Xray 官方正式版 ≥26.3.27，低版本时
# FEATURE_H3_DIRECT / FEATURE_HY2 会在 03-xray-install.sh 里被置 false，
# 此处渲染为空行，随后的 sed 删掉——空行若进了 base64 订阅会变成一条空节点。
# L19：同一节点的 URI 版与 mihomo 版是两处独立代码，必须同时处理。
#
# 两条直连节点用 mode=stream-up 而不是 auto（v4.7.13）：
# auto 在 security=tls 时保守地选 packet-up，把上行切成一串带最小间隔的 POST，
# 首字节要多等约 50ms。实测（同机、同目标、各 10 次取中位数）：
#   h2-direct auto/packet-up 68ms → stream-up 18ms（直连基线也是 18ms）
#   h3-direct auto/packet-up 69ms → stream-up 18ms
# 吞吐不受影响（337 / 356 Mbps）。
#
# **CDN 节点绝不能这样改**：packet-up 存在的理由就是 CDN 不支持流式请求体。
# 实测经 Cloudflare 用 stream-up：CDN-TLS 吞吐直接掉到 0、CDN-H3 连接超时。
# Reality 节点也不用改——它的 auto 本来就会选 stream-up（实测 18ms）。
if [[ "$FEATURE_H3_DIRECT" == true ]]; then
  H3_DIRECT_NODE_LINE="vless://${UUID2}@${VPS_IP_URI}:${H3_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${REALITY_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0&type=xhttp&path=${XHTTP_PATH}&mode=stream-up${XPAD_EXTRA_ENC:+&extra=${XPAD_EXTRA_ENC}}#VLESS-XHTTP-Direct-H3${NODE_SUFFIX}"
else
  H3_DIRECT_NODE_LINE=""
fi

# h2-cdn: 经 CDN 的 TCP(h2) 链路（默认关闭，FEATURE_CDN_H2=true 时启用）
if [[ "$FEATURE_CDN_H2" == true ]]; then
  H2_CDN_NODE_LINE="vless://${UUID2}@${CDN_DOMAIN}:443?encryption=${XHTTP_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h2,http%2F1.1&insecure=0&allowInsecure=0${CDN_ECH_QUERY_ENC:+&ech=${CDN_ECH_QUERY_ENC}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH}&mode=auto&extra=${XPAD_CDN_EXTRA_ENC}#VLESS-XHTTP-CDN-H2${NODE_SUFFIX}"
else
  H2_CDN_NODE_LINE=""
fi

# h3-cdn（v4.7.4）：节点 1 的 QUIC 版，只差 alpn（h2,http/1.1 → h3）与节点名。
# 不需要任何服务端改动：ALPN 是客户端与 Cloudflare 边缘之间的协商，回源侧恒为 h2/TCP。
# 之所以必须另开一条而不能给节点 1 加个 h3：mihomo 仅在 alpn **恰好等于** h3 时才走
# HTTP/3（transport/xhttp/client.go:159），列表里多一个值就退回 TCP。
# 不设 FEATURE 开关，与节点 1 一致：它不依赖任何服务端能力（没有新端口、没有新入站），
# CDN 存在则它必然可生成。真正决定它能否用的是 Cloudflare 侧是否开着 HTTP/3
# （默认开启，`curl -sI https://<cdn域名>/ | grep alt-svc` 可确认），
# 那是安装脚本无从探测也无权更改的东西，做成开关只会给出虚假的控制感。
H3_CDN_NODE_LINE="vless://${UUID2}@${CDN_DOMAIN}:443?encryption=${XHTTP_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0${CDN_ECH_QUERY_ENC:+&ech=${CDN_ECH_QUERY_ENC}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH}&mode=auto&extra=${XPAD_CDN_EXTRA_ENC}#VLESS-XHTTP-CDN-H3${NODE_SUFFIX}"

# h2-direct（v4.7.0）：h3-direct 的 TCP 版，只差 port 与 alpn。
# alpn 里的 http/1.1 必须写成 http%2F1.1——裸斜杠会被解析成 URI 的 path 分隔符。
if [[ "$FEATURE_H2_DIRECT" == true ]]; then
  H2_DIRECT_NODE_LINE="vless://${UUID2}@${VPS_IP_URI}:${H2_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${REALITY_DOMAIN}&fp=chrome&alpn=h2,http%2F1.1&insecure=0&allowInsecure=0&type=xhttp&path=${XHTTP_PATH}&mode=stream-up${XPAD_EXTRA_ENC:+&extra=${XPAD_EXTRA_ENC}}#VLESS-XHTTP-Direct-H2${NODE_SUFFIX}"
else
  H2_DIRECT_NODE_LINE=""
fi

if [[ "$FEATURE_HY2" == true && "${FEATURE_HY2_OBFS:-false}" == true ]]; then
  if [[ "${FEATURE_PORT_HOPPING:-false}" == true ]]; then
    HY2_NODE_LINE="hysteria2://$(rawurlencode "$HY2_PASSWORD")@${REALITY_DOMAIN}:${HY2_PORT}/?sni=${REALITY_DOMAIN}&mport=${HY2_PORT},${PORT_HOP_RANGE:-40000-50000}&insecure=0&obfs=salamander&obfs-password=$(rawurlencode "$OBFS_PASSWORD")&upmbps=${HY2_UP_MBPS}&downmbps=${HY2_DOWN_MBPS}#Hysteria2-Obfs-Direct${NODE_SUFFIX}"
    MIHOMO_HY2_PORTS_LINE=$(printf '\n    ports: %s,%s' "${HY2_PORT}" "${PORT_HOP_RANGE:-40000-50000}")
  else
    HY2_NODE_LINE="hysteria2://$(rawurlencode "$HY2_PASSWORD")@${REALITY_DOMAIN}:${HY2_PORT}/?sni=${REALITY_DOMAIN}&insecure=0&obfs=salamander&obfs-password=$(rawurlencode "$OBFS_PASSWORD")&upmbps=${HY2_UP_MBPS}&downmbps=${HY2_DOWN_MBPS}#Hysteria2-Obfs-Direct${NODE_SUFFIX}"
    MIHOMO_HY2_PORTS_LINE=""
  fi
else
  HY2_NODE_LINE=""
  MIHOMO_HY2_PORTS_LINE=""
fi

# Hysteria2-H3（v4.9.26）：UDP 443、无混淆，其余与 Hysteria2-Obfs-Direct 相同。
if [[ "${FEATURE_HY2_H3:-false}" == true ]]; then
  HY2_H3_NODE_LINE="hysteria2://$(rawurlencode "$HY2_PASSWORD")@${REALITY_DOMAIN}:${HY2_H3_PORT:-443}/?sni=${REALITY_DOMAIN}&alpn=h3&insecure=0&upmbps=${HY2_UP_MBPS}&downmbps=${HY2_DOWN_MBPS}#Hysteria2-H3-Direct${NODE_SUFFIX}"
else
  HY2_H3_NODE_LINE=""
fi

info "节点集: h3-cdn + h3-direct(${FEATURE_H3_DIRECT}) + Hysteria2-H3(${FEATURE_HY2_H3:-false}) + Reality x2 + Reality-up-CDN-down(${FEATURE_REALITY_UP_CDN_DOWN:-true}) [精简默认关闭: h2-cdn(${FEATURE_CDN_H2:-false}), CDN-up-Reality-down(${FEATURE_CDN_UP_REALITY_DOWN:-false})]"

cat > "$USER_HOME/client-config.txt" << CLIENTEOF
@@include templates/client-config.txt.tmpl
CLIENTEOF
# 删掉 CDN 节点关闭后留下的空行，保证 client-config.txt 每行都是一条可用节点
sed -i '/^[[:space:]]*$/d' "$USER_HOME/client-config.txt"

# v2rayN TUN 绕行清单。**不能并进 client-config.txt**——那份文件会被整体
# base64 成 v2rayN 订阅（12-subscription.sh:18），混入非节点行会污染订阅。
V2RAYN_TUN_FILE="$USER_HOME/client-config-v2rayn-tun.txt"
cat > "$V2RAYN_TUN_FILE" << V2RAYNTUNEOF
@@include templates/v2rayn-tun.txt.tmpl
V2RAYNTUNEOF

MIHOMO_FULL_FILE="$USER_HOME/client-config-mihomo-full.yaml"
MIHOMO_NODES_FILE="$USER_HOME/client-config-mihomo-nodes.yaml"

# 完整分流配置：保留用户选择的 ECH 配置
cat > "$MIHOMO_FULL_FILE" << MIHOMOEOF
@@include templates/mihomo-full.yaml.tmpl
MIHOMOEOF

cat > "$MIHOMO_NODES_FILE" << MIHOMOEOF
@@include templates/mihomo-nodes.yaml.tmpl
MIHOMOEOF

# 按 FEATURE_* 裁剪 mihomo 配置里的可选节点（v4.7.8）。
# URI 侧靠 ${..._NODE_LINE} 置空 + 删空行处理，mihomo 侧原先没有对应机制，
# 于是 h3-direct / h2-direct / Hysteria2 被关掉时，yaml 里仍留着这些节点——
# 客户端拿到的是指向不存在入站的死节点，「直连择优」组还会一直去测它们。
#
# 做法是在模板里用 YAML 注释打成对标记：
#   #<<FEATURE_H2_DIRECT ... #>>FEATURE_H2_DIRECT
# 开则只删标记行，关则连同标记之间的内容一起删。
# 用注释而不是变量占位有两个好处：模板本身仍是合法 YAML（可直接 lint），
# 且万一裁剪没跑，产物退化成「多了几行注释」而不是「YAML 语法错」。
#
# L19：同一节点在 mihomo-proxies（节点定义）与 mihomo-full（「直连择优」组的
# 成员列表）里各出现一次，两处都打了标记，靠同一次裁剪一起处理。
prune_mihomo_features() {
  local file="$1" feat
  [[ -f "$file" ]] || return 0
  for feat in FEATURE_CDN_H2 FEATURE_H3_DIRECT FEATURE_H2_DIRECT FEATURE_HY2 FEATURE_HY2_H3 FEATURE_HY2_OBFS FEATURE_UP_CDN_DOWN_MIHOMO FEATURE_CDN_UP_REALITY_DOWN; do
    if [[ "${!feat}" == true ]]; then
      sed -i "/^[[:space:]]*#<<${feat}\$/d; /^[[:space:]]*#>>${feat}\$/d" "$file"
    else
      sed -i "/^[[:space:]]*#<<${feat}\$/,/^[[:space:]]*#>>${feat}\$/d" "$file"
    fi
  done
}

prune_mihomo_features "$MIHOMO_FULL_FILE"
prune_mihomo_features "$MIHOMO_NODES_FILE"

# 自定义节点名（v4.7.9）。NODE_TAG 只能换后缀，机场式的名字（🇺🇸 US-CDN-H3）
# 换的是整个名字，没法靠模板变量拼出来，所以放在这里做一次改名。
#
# 放在产物生成之后而不是模板里，是因为节点名在三种产物里出现的形式不同：
#   client-config.txt  —— URI 的 fragment，emoji 与空格必须百分号编码，
#                          否则 Shadowrocket 等客户端会在空格处截断节点名
#   mihomo-*.yaml      —— proxies 的 name 与 proxy-groups 的成员引用，用原文，
#                          且两处必须一起改，改漏一处 mihomo 会拒绝加载整份配置
# 统一在产物上做替换，只需维护一张表，扩展脚本追加的节点也一并覆盖。
#
# 表的格式是每行 `旧名=新名`，来自 NODE_NAME_MAP 环境变量，或 NODE_NAME_FILE
# 指向的文件；旧名就是默认生成的完整节点名（含 ${HOSTNAME_TAG} 后缀）。
apply_node_names() {
  local map="${NODE_NAME_MAP:-}"
  [[ -n "${NODE_NAME_FILE:-}" && -f "${NODE_NAME_FILE}" ]] && map=$(cat "${NODE_NAME_FILE}")
  [[ -n "$map" ]] || return 0

  local line old new enc f
  while IFS= read -r line; do
    # 跳过空行与注释；新名里可以有 =，所以只按第一个 = 切
    [[ -z "${line// }" || "${line#\#}" != "$line" ]] && continue
    old="${line%%=*}"; new="${line#*=}"
    [[ -n "$old" && -n "$new" ]] || continue
    enc=$(rawurlencode "$new")

    # perl 不加 -CSD：替换串本身就是 UTF-8 字节，按字节替换才不会把 emoji
    # 变成乱码（-CSD 会把它当 latin-1 解一遍再编回去）。
    perl -pi -e "s/\Q${old}\E/${enc}/g" "$USER_HOME/client-config.txt"
    for f in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
      perl -pi -e "s/\Q${old}\E/${new}/g" "$f"
    done
  done <<< "$map"
}

apply_node_names

chown "$(stat -c '%u:%g' "$USER_HOME")" \
  "$USER_HOME/client-config.txt" \
  "$V2RAYN_TUN_FILE" \
  "$MIHOMO_FULL_FILE" \
  "$MIHOMO_NODES_FILE"

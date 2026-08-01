# ==================================================
# 客户端配置生成
# ==================================================

info "[6/7] 生成客户端配置"
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
  # xmux 参数与上游 Yulinanami/my-xhttp-cdn-config 完全一致，本项目不再改动：
  #   cMaxReuseTimes: 0    → leftUsage = -1，**无限复用**，不是"不复用"
  #   hKeepAlivePeriod: 0  → h3 取 quic-go 默认、h2 取 Chrome 默认，不是"禁用"
  #                          （负值才是禁用，见 dialer.go:154-186）
  # 这两项写死为"采用默认"，改成拍脑袋的正值等于覆盖掉更好的默认（L16）。
  XMUX_ENC="%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%2C%22cMaxReuseTimes%22%3A0%2C%22hMaxReusableSecs%22%3A%221800-3000%22%2C%22hKeepAlivePeriod%22%3A0%7D"
  XPAD_EXTRA_ENC="%7B${XPAD_FIELDS_ENC}%2C${XMUX_ENC}%7D"

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

# 两条上下行分离节点按 FEATURE_SPLIT_NODES 决定是否输出（v2.0.2，见 01-env.sh）。
# Vless-xhttp-tls-UDP-cdn 不受本开关控制，它是默认节点集的一员（实测最快）。
# 用 heredoc 先渲染成变量再插进 client-config.txt——关闭时变量为空，
# 随后的 sed 会删掉留下的空行。空行会被 base64 进订阅，v2rayN 里会多出一条空节点。
# L19：同一节点的 URI 版与 mihomo 版是两处独立代码，必须同时处理，
# 否则会出现「订阅里没有、mihomo 配置里还有」的不一致。
if [[ "$FEATURE_SPLIT_NODES" == true ]]; then
  SPLIT_NODE_LINES=$(cat << SPLITNODEEOF
@@include templates/cdn-node-lines.txt.tmpl
SPLITNODEEOF
)
  MIHOMO_SPLIT_PROXIES=$(cat << MIHOMOSPLITEOF
@@include templates/mihomo-cdn-proxies.yaml.tmpl
MIHOMOSPLITEOF
)
  info "节点集: Reality x2 + xhttp-tls-UDP-cdn + 上下行分离 x2（FEATURE_SPLIT_NODES=true）"
else
  SPLIT_NODE_LINES=""
  MIHOMO_SPLIT_PROXIES=""
  info "节点集: Reality x2 + xhttp-tls-UDP-cdn（默认，实测最快；FEATURE_SPLIT_NODES=true 可加两条上下行分离）"
fi

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

chown "$(stat -c '%u:%g' "$USER_HOME")" \
  "$USER_HOME/client-config.txt" \
  "$V2RAYN_TUN_FILE" \
  "$MIHOMO_FULL_FILE" \
  "$MIHOMO_NODES_FILE"

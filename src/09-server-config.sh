# ==================================================
# 服务端配置生成
# ==================================================

info "[4/7] 生成配置文件"

if [[ "$FALLBACK_MODE" == "static" ]]; then
  [[ -f "${STATIC_SITE_DIR}/${REALITY_DOMAIN}/index.html" ]] || error "未找到 Reality 域名页面"
  [[ -f "${STATIC_SITE_DIR}/${CDN_DOMAIN}/index.html" ]] || error "未找到 CDN 域名页面"
fi

# IP_CHOICE=1（纯 IPv4 出网）的机器上，回落站域名若解析出 AAAA，nginx 会先尝试
# IPv6 再失败回退，实测 error.log 出现:
#   connect() to [2600:...]:443 failed (101: Network is unreachable)
# 每次伪装探测都白白多一次超时。这里按出网协议族关掉对应的解析。
if [[ "$IP_CHOICE" == "2" ]]; then
  NGINX_RESOLVER_IPV6="ipv4=off"
else
  NGINX_RESOLVER_IPV6="ipv6=off"
fi

nginx_fallback_config() {
  if [[ "$FALLBACK_MODE" == "static" ]]; then
    cat <<EOF
            root ${STATIC_SITE_DIR}/$1;
            index index.html;
            try_files \$uri \$uri/ /index.html;
EOF
  else
    cat <<EOF
            proxy_pass $2;
            # 伪装源是第三方站点，慢响应/黑洞时按默认 60s 占住 worker，并发探测下
            # 会把连接池拖满，连带影响正常的 XHTTP 流量。
            # 但不能收得太紧：回落站的用途就是让主动探测看到真实站点内容，超时提前
            # 返回 504 而真站返回正文，本身就是一个指纹差异——而拖满连接池需要有人
            # 刻意冲刷回落站。两害相权，这里只砍掉「明显异常」的那一段：
            # connect 10s 覆盖国际链路握手，读写 30s 兜住慢站，仍比默认 60s 减半。
            proxy_connect_timeout 10s;
            proxy_send_timeout    30s;
            proxy_read_timeout    30s;
            proxy_ssl_server_name on;
            proxy_ssl_name $3;
            proxy_redirect http://$3/ https://\$host/;
            proxy_redirect https://$3/ https://\$host/;
            proxy_set_header Host $3;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
EOF
  fi
}

# ==================================================
# Xray 应用层优化注入（v3.0.0）
# 与 `xh tuning on` 的 sysctl 层互不冲突：bufferSize 是 Xray 进程内的 Go 分配、
# sockopt 是 Xray 建的 socket 选项，sysctl 都调不到，只能在 config.json 里写。
# --------------------------------------------------
# policy.bufferSize：ARM64 上 Xray 默认只有 4 KB（x86 是 512 KB），同样配置
# ARM 机器吞吐被压死。按内存分档显式写入，三档 512 / 256 / 64 KB。
MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if   [[ "$MEM_MB" -ge 16384 ]]; then XRAY_BUFFER_KB=512
elif [[ "$MEM_MB" -ge 4096  ]]; then XRAY_BUFFER_KB=256
else XRAY_BUFFER_KB=64
fi
XRAY_POLICY_JSON="\"policy\":{\"levels\":{\"0\":{\"bufferSize\":${XRAY_BUFFER_KB}}}},"

# Reality 入站 sockopt：tcpcongestion 只在 BBR 可用时写，否则 xray -test 直接
# 失败（L3：字段名 tcpcongestion 全小写，见官方 sockopt 文档）。TFO/keepalive/
# tcpUserTimeout 与拥塞算法无关，总是写。
AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
if [[ "$AVAIL" != *bbr* ]]; then
  modprobe tcp_bbr >/dev/null 2>&1 || true
  AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
fi
if [[ "$AVAIL" == *bbr* ]]; then
  XRAY_SOCKOPT_JSON=',"sockopt":{"tcpFastOpen":true,"tcpcongestion":"bbr","tcpKeepAliveIdle":300,"tcpKeepAliveInterval":30,"tcpUserTimeout":30000}'
else
  warn "BBR 不可用，Xray Reality 入站不写 tcpcongestion（TFO / keepalive 照常写入）"
  XRAY_SOCKOPT_JSON=',"sockopt":{"tcpFastOpen":true,"tcpKeepAliveIdle":300,"tcpKeepAliveInterval":30,"tcpUserTimeout":30000}'
fi

# ==================================================
# DNS over HTTPS（v4.4.3）
# --------------------------------------------------
# 不配 dns 段时，Xray 走系统 /etc/resolv.conf —— 所有代理目标域名的解析都是
# **明文 UDP 53**，VPS 的上游（云厂商 / 机房）能完整看到访问过哪些域名。
# 这是纯粹的隐私缺口，与能否连通无关，因此本段只改解析路径、不改路由逻辑。
#
# 服务器地址写 **IP 形式**（1.1.1.1 / 8.8.8.8），不写 dns.google 之类的域名：
# 域名形式的 DoH 需要先解析自己，会形成引导依赖，首次查询必然回落到系统 DNS，
# 隐私缺口照旧存在（L3：Xray DNS 文档明确建议 DoH 用 IP 形式避免 bootstrap）。
#
# 末位保留 "localhost"（系统 DNS）作兜底：DoH 出网被阻断时仍能解析，
# 代价是那种情况下退回明文——可用性优先于隐私（L1）。
#
# queryStrategy 跟随 IP_CHOICE：纯 IPv4 机器若查出 AAAA，freedom 出站会先试
# IPv6 再超时回退，白白多一次 RTT（与本文件开头 nginx resolver 同一个道理）。
if [[ "$IP_CHOICE" == "2" ]]; then
  XRAY_DNS_QUERY_STRATEGY="UseIP"
else
  XRAY_DNS_QUERY_STRATEGY="UseIPv4"
fi
XRAY_DNS_JSON=$(cat <<DNSEOF
"dns": {
        "servers": [
            "https://1.1.1.1/dns-query",
            "https://8.8.8.8/dns-query",
            "localhost"
        ],
        "queryStrategy": "${XRAY_DNS_QUERY_STRATEGY}",
        "disableCache": false,
        "tag": "dns-out"
    },
DNSEOF
)
info "已启用 DoH 解析（queryStrategy=${XRAY_DNS_QUERY_STRATEGY}，兜底 localhost）"

# ==================================================
# 直连 UDP inbound（v4.0.0）
# --------------------------------------------------
# 两者都用 acme 签发的真实证书（Reality+CDN 双域名 SAN，见 07-acme-cert.sh:34），
# 而不是 Reality —— Hysteria2 与标准 h3 客户端都要求可验证的证书链。
# 证书不存在时跳过这两个节点，不中断安装（L1 best-effort）。
#
# 配置字段依据 docs/llms-full.md（Xray 官方文档离线副本），非凭记忆书写（L3）：
#   Hysteria2 inbound  : :3001  protocol=hysteria / settings.clients[].auth
#   HysteriaObject     : :3102  hysteriaSettings.masquerade
#   FinalMaskObject    : :8211  finalmask.udp[].type / .settings
#   salamander settings: :8460  { "password": "..." }
# 注意 obfs 走 finalmask.udp[]，不是原版 hysteria 的 obfs.salamander；
# 认证是 clients[].auth，不是 users[]。
# config.json 里写的是 /etc/ssl/private/ —— 该路径由 10-service-check.sh:13-16 的
# acme.sh --install-cert 落地，**晚于本文件**。所以可用性判定必须查 acme 的源证书
# （07-acme-cert.sh:18 的 ACME_CERT_HOME），查目标路径在首次安装时必然为空，
# 会把两个节点误判为不可用。时序上没有问题：xray -test 在 10:23，install-cert 在 10:13。
CERT_FILE="/etc/ssl/private/fullchain.cer"
CERT_KEY="/etc/ssl/private/private.key"
XRAY_CDN_DIRECT_INBOUND=""
XRAY_H3_DIRECT_INBOUND=""
XRAY_HY2_INBOUND=""

if [[ ! -s "${ACME_CERT_HOME}/fullchain.cer" ]]; then
  if [[ "$FEATURE_H3_DIRECT" == true || "$FEATURE_HY2" == true ]]; then
    warn "未找到 acme 证书 ${ACME_CERT_HOME}/fullchain.cer，已跳过 h3-direct 与 Hysteria2 两个直连 UDP 节点"
    FEATURE_H3_DIRECT=false
    FEATURE_HY2=false
  fi
fi

# CDN 独立 inbound（v4.3.0）：CDN 流量不再走 Reality 443 的回落链，改由
# 独立 TLS+XHTTP inbound 直接处理。客户端 URI 仍写 443（连 Cloudflare），
# CF 侧用 Origin Rule 把 cdn 域名回源映射到 CDN_DIRECT_PORT。
# 复用同一套 UUID2 / VLESS 加密 / XHTTP_PATH / xpadding（L19：与 443 回落路径同源）。
# 证书不存在时跳过，CDN 节点仍走旧路径（443 回落）可用（L1 best-effort）。
if [[ ! -s "${ACME_CERT_HOME}/fullchain.cer" ]]; then
  warn "未找到 acme 证书，CDN 独立 inbound 已跳过（CDN 节点仍走 443 回落）"
else
  XRAY_CDN_DIRECT_INBOUND=$(cat <<CDNEOF
,
        {
            "listen": "0.0.0.0",
            "port": ${CDN_DIRECT_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID2}",
                        "level": 0
                    }
                ],
                "decryption": "${VLESSENC_DECRYPTION}"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "tls",
                "tlsSettings": {
                    "alpn": ["h2","http/1.1"],
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ]
                },
                "xhttpSettings": {
                    "host": "",
                    "path": "${XHTTP_PATH}",
                    "mode": "auto"${XRAY_XHTTP_PADDING_JSON}
                }${XRAY_SOCKOPT_JSON}
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
CDNEOF
)
  info "已启用 CDN 独立 inbound: TCP ${CDN_DIRECT_PORT}（TLS + XHTTP，走 CF Origin Rule）"
fi

if [[ "$FEATURE_H3_DIRECT" == true ]]; then
  XRAY_H3_DIRECT_INBOUND=$(cat <<H3EOF
,
        {
            "listen": "0.0.0.0",
            "port": ${H3_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID2}",
                        "level": 0
                    }
                ],
                "decryption": "${VLESSENC_DECRYPTION}"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "tls",
                "tlsSettings": {
                    "alpn": ["h3"],
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ]
                },
                "xhttpSettings": {
                    "host": "",
                    "path": "${XHTTP_PATH}",
                    "mode": "auto"${XRAY_XHTTP_PADDING_JSON}
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
H3EOF
)
  info "已启用 h3-direct 直连节点: UDP ${H3_PORT}"
fi

if [[ "$FEATURE_HY2" == true ]]; then
  XRAY_HY2_INBOUND=$(cat <<HY2EOF
,
        {
            "listen": "0.0.0.0",
            "port": ${HY2_PORT},
            "protocol": "hysteria",
            "settings": {
                "version": 2,
                "clients": [
                    {
                        "auth": "${HY2_PASSWORD}",
                        "level": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "hysteria",
                "security": "tls",
                "tlsSettings": {
                    "alpn": ["h3"],
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ]
                },
                "hysteriaSettings": {
                    "version": 2,
                    "masquerade": {
                        "type": "proxy",
                        "url": "https://127.0.0.1:8003",
                        "rewriteHost": false,
                        "insecure": true
                    }
                },
                "finalmask": {
                    "udp": [
                        {
                            "type": "salamander",
                            "settings": {
                                "password": "${OBFS_PASSWORD}"
                            }
                        }
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
HY2EOF
)
  info "已启用 Hysteria2-obfs 节点: UDP ${HY2_PORT}（Salamander 混淆）"
fi

info "写入 /etc/nginx/nginx.conf ..."
cat > /etc/nginx/nginx.conf << NGINXEOF
@@include templates/nginx.conf.tmpl
NGINXEOF

install -d -m 700 /etc/xhttp-cdn
{
  printf 'FALLBACK_MODE=%q\n' "$FALLBACK_MODE"
  if [[ "$FALLBACK_MODE" == "static" ]]; then
    printf 'STATIC_SITE_DIR=%q\n' "$STATIC_SITE_DIR"
  else
    printf 'REALITY_FALLBACK_ORIGIN=%q\n' "$REALITY_FALLBACK_ORIGIN"
    printf 'REALITY_FALLBACK_HOST=%q\n' "$REALITY_FALLBACK_HOST"
    printf 'CDN_FALLBACK_ORIGIN=%q\n' "$CDN_FALLBACK_ORIGIN"
    printf 'CDN_FALLBACK_HOST=%q\n' "$CDN_FALLBACK_HOST"
  fi
} > /etc/xhttp-cdn/fallback.env
chmod 600 /etc/xhttp-cdn/fallback.env

info "写入 /usr/local/etc/xray/config.json ..."
cat > /usr/local/etc/xray/config.json << XRAYEOF
@@include templates/xray-config.json.tmpl
XRAYEOF

# 节点状态：供管理命令 xh 读取（info / sub / status / uninstall）
info "写入 ${NODE_ENV_FILE} ..."
{
  printf 'PROJECT_NAME=%q\n'      "$PROJECT_NAME"
  printf 'PROJECT_VERSION=%q\n'   "$PROJECT_VERSION"
  printf 'FEATURE_H3_DIRECT=%q\n' "$FEATURE_H3_DIRECT"
  printf 'FEATURE_HY2=%q\n'       "$FEATURE_HY2"
  printf 'H3_PORT=%q\n'           "$H3_PORT"
  printf 'HY2_PORT=%q\n'          "$HY2_PORT"
  printf 'CDN_DIRECT_PORT=%q\n'   "$CDN_DIRECT_PORT"
  printf 'HY2_PASSWORD=%q\n'      "$HY2_PASSWORD"
  printf 'OBFS_PASSWORD=%q\n'     "$OBFS_PASSWORD"
  printf 'PROJECT_REPO=%q\n'      "$PROJECT_REPO"
  printf 'INSTALL_TIME=%q\n'      "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'OS_ID=%q\n'             "$OS_ID"
  printf 'SERVICE_TYPE=%q\n'      "$SERVICE_TYPE"
  printf 'USER_HOME=%q\n'         "$USER_HOME"
  printf 'REALITY_DOMAIN=%q\n'    "$REALITY_DOMAIN"
  printf 'CDN_DOMAIN=%q\n'        "$CDN_DOMAIN"
  printf 'VPS_IP=%q\n'            "$VPS_IP"
  printf 'IP_CHOICE=%q\n'         "$IP_CHOICE"
  printf 'UUID1=%q\n'             "$UUID1"
  printf 'UUID2=%q\n'             "$UUID2"
  printf 'PUBLIC_KEY=%q\n'        "$PUBLIC_KEY"
  printf 'PRIVATE_KEY=%q\n'       "$PRIVATE_KEY"
  printf 'SHORT_ID=%q\n'          "$SHORT_ID"
  printf 'XHTTP_PATH=%q\n'        "$XHTTP_PATH"
  printf 'VLESSENC_ENCRYPTION=%q\n' "$VLESSENC_ENCRYPTION"
  printf 'VLESSENC_DECRYPTION=%q\n' "$VLESSENC_DECRYPTION"
  printf 'FEATURE_XPADDING=%q\n'  "$FEATURE_XPADDING"
  printf 'FEATURE_CDN_ECH=%q\n'   "$FEATURE_CDN_ECH"
  printf 'CDN_ECH_ENABLED=%q\n'   "$CDN_ECH_ENABLED"
  if [[ "$FEATURE_XPADDING" == true ]]; then
    printf 'XHTTP_PADDING_HEADER=%q\n' "$XHTTP_PADDING_HEADER"
    printf 'XHTTP_PADDING_KEY=%q\n'    "$XHTTP_PADDING_KEY"
  fi
} > "$NODE_ENV_FILE"
chmod 600 "$NODE_ENV_FILE"

echo ""

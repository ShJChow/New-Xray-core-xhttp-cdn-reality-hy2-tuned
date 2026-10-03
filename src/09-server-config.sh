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
            # 用变量形式 proxy_pass：写死域名时 nginx 在启动期用 getaddrinfo 解析，
            # 会拿到 AAAA 并在无 IPv6 的机器上反复 connect() 失败
            # （error.log: Network is unreachable → upstream server temporarily disabled）。
            # 变量形式改走上面的 resolver（ipv6=off），只解析 A 记录。
            set \$masq_upstream $2;
            proxy_pass \$masq_upstream\$request_uri;
            # 回落站带浏览器 UA 时会返回一大堆 Set-Cookie/CSP，默认 4k 头缓冲装不下，
            # nginx 报 "upstream sent too big header" 并回 502——主动探测看到 502
            # 而真站看到 200，本身就是可指纹的差异。
            proxy_buffer_size   32k;
            proxy_buffers     8 32k;
            proxy_busy_buffers_size 64k;
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
# policy.bufferSize：ARM64 上 Xray 默认只有 4 KB（x86 是 512 KB，源码 features/policy/policy.go 已核实），
# 按内存分档显式设为 4096 / 2048 / 512 KB。
# v4.9.24 实测更正：此前注释称扩容可「释放千兆高吞吐性能」，**实测无可测差异**。
# 在 4 KB（默认）/ 32 / 512 / 4096 KB 四档下测 Reality-Vision、Reality-XHTTP、XHTTP-H3、Hysteria2，
# 不限速 RTT 0 与 160ms RTT + 1% 丢包两组，上下行中位全部落在彼此范围内，xray RSS 58~70MB 也无差别。
# 保留现值只是因为改动同样拿不出收益，不代表它提速。
# 超时调优：handshake 10s（防跨境抖动重试断开）、connIdle 1800s（30分钟长连接保活）、
# uplinkOnly 5s / downlinkOnly 10s（防非对称关闭提前截断数据）。
MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if   [[ "$MEM_MB" -ge 16384 ]]; then XRAY_BUFFER_KB=4096
elif [[ "$MEM_MB" -ge 4096  ]]; then XRAY_BUFFER_KB=2048
else XRAY_BUFFER_KB=512
fi
XRAY_POLICY_JSON="\"policy\":{\"levels\":{\"0\":{\"handshake\":10,\"connIdle\":1800,\"uplinkOnly\":5,\"downlinkOnly\":10,\"bufferSize\":${XRAY_BUFFER_KB}}}},"


# Reality 入站 sockopt：不启用 TFO 避免部分运营商/移动端网络丢弃带数据的 SYN 包导致 failed to read client hello
# tcpUserTimeout 设为 300000 (5分钟)，杜绝因 20s/60s 瞬时抖动杀死健康连接
AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
if [[ "$AVAIL" != *brutal* ]]; then
  modprobe brutal 2>/dev/null || true
  AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
fi
if [[ "$AVAIL" != *bbr* ]]; then
  modprobe tcp_bbr 2>/dev/null || true
  AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
fi

XRAY_TCP_CC=""
if [[ "$AVAIL" == *brutal* && "${FEATURE_BRUTAL:-true}" != false ]]; then
  XRAY_TCP_CC="brutal"
  info "检测到 TCP Brutal 内核模块，已为 Xray 入站启用 Brutal 极速拥塞控制"
  install_tcp_brutal_service "${BRUTAL_DEFAULT_MBPS:-auto}" 2>/dev/null || true
elif [[ "$AVAIL" == *bbr* ]]; then
  XRAY_TCP_CC="bbr"
fi

if [[ -n "$XRAY_TCP_CC" ]]; then
  XRAY_SOCKOPT_JSON=',"sockopt":{"tcpFastOpen":true,"tcpMptcp":true,"tcpcongestion":"'"${XRAY_TCP_CC}"'","tcpKeepAliveIdle":30,"tcpKeepAliveInterval":5,"tcpUserTimeout":300000}'
  REALITY_SOCKOPT_JSON=',"sockopt":{"tcpFastOpen":true,"tcpMptcp":true,"tcpcongestion":"'"${XRAY_TCP_CC}"'","tcpKeepAliveIdle":30,"tcpKeepAliveInterval":5,"tcpUserTimeout":300000}'
else
  warn "BBR / Brutal 均不可用，Xray Reality 入站不写 tcpcongestion（TFO / keepalive 照常写入）"
  XRAY_SOCKOPT_JSON=',"sockopt":{"tcpFastOpen":true,"tcpMptcp":true,"tcpKeepAliveIdle":30,"tcpKeepAliveInterval":5,"tcpUserTimeout":300000}'
  REALITY_SOCKOPT_JSON=',"sockopt":{"tcpFastOpen":true,"tcpMptcp":true,"tcpKeepAliveIdle":30,"tcpKeepAliveInterval":5,"tcpUserTimeout":300000}'
fi

# Reality maxTimeDiff（毫秒，XTLS/REALITY README 的可选项，默认不设）：客户端时间偏差超过该值则拒绝握手
if [[ "${REALITY_MAX_TIME_DIFF:-}" =~ ^[0-9]+$ && "${REALITY_MAX_TIME_DIFF:-0}" -ge 1000 ]]; then
  REALITY_MAX_TIME_DIFF_JSON=$',\n                    "maxTimeDiff": '"${REALITY_MAX_TIME_DIFF}"
  info "Reality maxTimeDiff 设为 ${REALITY_MAX_TIME_DIFF} ms"
else
  REALITY_MAX_TIME_DIFF_JSON=""
fi

# Reality minClientVer 控制：
# 若 REALITY_MIN_CLIENT_VER 设定且不为 none / default / off，注入 minClientVer 配置
if [[ -n "$REALITY_MIN_CLIENT_VER" && "$REALITY_MIN_CLIENT_VER" != "none" && "$REALITY_MIN_CLIENT_VER" != "default" && "$REALITY_MIN_CLIENT_VER" != "off" ]]; then
  REALITY_MIN_CLIENT_VER_JSON=$',\n                    "minClientVer": "'"${REALITY_MIN_CLIENT_VER}"'"'
  info "Reality 最低客户端版本设为: ${REALITY_MIN_CLIENT_VER}（兼容模式：支持 mihomo/Clash/sing-box）"
else
  REALITY_MIN_CLIENT_VER_JSON=""
  info "Reality 最低客户端版本: 未指定（严格模式：使用 Xray 内核默认版本）"
fi

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
# 可选入站的端口预检：默认开启的 Hysteria2-Obfs（UDP HY2_PORT）和可选的 h2-direct（TCP H2_PORT）。
# Xray 是一个进程，任何一个入站绑定失败都会让整个 Xray 起不来，Reality 也就跟着不通。
# 端口已被别的进程（不是 xray 自己）占用时，直接关掉这个可选节点并提示，而不是让安装带着坏配置继续。
_port_taken_by_other() {   # $1 = tcp|udp，$2 = 端口
  local flag=-ltnpH
  [[ "$1" == udp ]] && flag=-lunpH
  ss "$flag" "sport = :$2" 2>/dev/null | grep -v '"xray"' | grep -q .
}
if [[ "${FEATURE_HY2_OBFS:-false}" == true ]] && _port_taken_by_other udp "$HY2_PORT"; then
  warn "UDP ${HY2_PORT} 已被其他进程占用，已关闭 Hysteria2-Obfs 节点（占用者：$(ss -lunpH "sport = :${HY2_PORT}" 2>/dev/null | grep -o 'users:(([^)]*' | head -1)）。腾出端口后可用 xh hy2obfs on 开启"
  FEATURE_HY2_OBFS=false
fi
if [[ "${FEATURE_H2_DIRECT:-false}" == true ]] && _port_taken_by_other tcp "$H2_PORT"; then
  warn "TCP ${H2_PORT} 已被其他进程占用，已关闭 h2-direct 节点。腾出端口后可用 xh h2direct on 开启"
  FEATURE_H2_DIRECT=false
fi

XRAY_H3_DIRECT_INBOUND=""
XRAY_H2_DIRECT_INBOUND=""
XRAY_HY2_INBOUND=""
XRAY_HY2_H3_INBOUND=""

if [[ ! -s "${ACME_CERT_HOME}/fullchain.cer" ]]; then
  if [[ "$FEATURE_H3_DIRECT" == true || "$FEATURE_HY2" == true || "$FEATURE_H2_DIRECT" == true ]]; then
    warn "未找到 acme 证书 ${ACME_CERT_HOME}/fullchain.cer，已跳过 h3-direct / h2-direct / Hysteria2 三个直连节点"
    FEATURE_H3_DIRECT=false
    FEATURE_H2_DIRECT=false
    FEATURE_HY2=false
  fi
fi
[[ "$FEATURE_HY2" == true ]] || FEATURE_HY2_H3=false

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
                    // 只谈 TLS 1.3。注意不能靠「删掉这行」来要最新特性——
                    // 删掉后 Xray 会退回它自己的默认下限（更低），
                    // 所以这里显式写死 1.3。
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "cipherSuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                    // 只接受证书覆盖的 SNI；未知 SNI 直接拒绝握手，
                    // 避免本入站被当作任意 SNI 的 TLS 前置来探测或滥用。
                    "rejectUnknownSni": true,
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ]
                }${XRAY_SOCKOPT_JSON},
                "xhttpSettings": {
                    "host": "",
                    "path": "${XHTTP_PATH}",
                    "mode": "stream-up"${XRAY_XHTTP_PADDING_JSON}
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

# h2-direct（v4.7.0）：与上面的 h3-direct 共用 UUID2、decryption 和 XHTTP_PATH，
# 仅传输层不同（TCP + alpn h2）。客户端把两者编成 fallback 对，
# UDP 被封时自动落到这条。sockopt 与 Reality 入站保持一致。
# 供 xh h2direct 开关复用：同一份文本，开关开启时直接插进线上配置
xray_h2_direct_inbound() {
  cat <<H2EOF
,
        {
            "listen": "0.0.0.0",
            "port": ${H2_PORT},
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
                    "alpn": ["h2"],
                    // 只谈 TLS 1.3。注意不能靠「删掉这行」来要最新特性——
                    // 删掉后 Xray 会退回它自己的默认下限（更低），
                    // 所以这里显式写死 1.3。
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "cipherSuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ]
                }${XRAY_SOCKOPT_JSON},
                "xhttpSettings": {
                    "host": "",
                    "path": "${XHTTP_PATH}",
                    "mode": "stream-up"${XRAY_XHTTP_PADDING_JSON}
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
H2EOF
}

if [[ "$FEATURE_H2_DIRECT" == true ]]; then
  # 带 xh 开关使用的成对标记，xh h2direct off 才能整块删除安装时写入的入站
  XRAY_H2_DIRECT_INBOUND=$(printf '\n        // >>xh:h2direct\n%s\n        // <<xh:h2direct' "$(xray_h2_direct_inbound)")
  info "已启用 h2-direct 直连节点: TCP ${H2_PORT}"
fi

# 供 xh hy2obfs 开关复用（同上）
xray_hy2_obfs_inbound() {
  cat <<HY2EOF
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
                    // 只谈 TLS 1.3。注意不能靠「删掉这行」来要最新特性——
                    // 删掉后 Xray 会退回它自己的默认下限（更低），
                    // 所以这里显式写死 1.3。
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "cipherSuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                    // 只接受证书覆盖的 SNI；未知 SNI 直接拒绝握手，
                    // 避免本入站被当作任意 SNI 的 TLS 前置来探测或滥用。
                    "rejectUnknownSni": true,
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ]
                },
                "hysteriaSettings": {
                    "version": 2,
                    "udpIdleTimeout": 60,
                    "masquerade": {
                        "type": "proxy",
                        "url": "https://127.0.0.1:8003",
                        "rewriteHost": false,
                        "insecure": true
                    }
                },
                "sockopt": {
                    "tcpFastOpen": true,
                    "tcpcongestion": "brutal"
                },
                "finalmask": {
                    "udp": [
$(if [[ "${FEATURE_NOISE_EXP:-false}" == true ]]; then cat <<NEOF
                        {
                            "type": "noise",
                            "settings": {
                                "noise": [
                                    {
                                        "type": "exp",
                                        "packet": "${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>}",
                                        "delay": "${NOISE_EXP_DELAY:-10-50}"
                                    }
                                ]
                            }
                        },
NEOF
fi)
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
}

if [[ "$FEATURE_HY2" == true ]]; then
  if [[ "${FEATURE_HY2_OBFS:-false}" == true ]]; then
  XRAY_HY2_INBOUND=$(printf '\n        // >>xh:hy2obfs\n%s\n        // <<xh:hy2obfs' "$(xray_hy2_obfs_inbound)")
  info "已启用 Hysteria2-obfs 节点: UDP ${HY2_PORT}（Salamander 混淆，FEATURE_HY2_OBFS=true）"
  fi

# Hysteria2-H3（v4.9.26）：与上面同一套认证与证书，端口 UDP 443、**不加 salamander**。
# 实测（netns，160ms RTT，下行 Mbps，Xray / sing-box 客户端）：
#   1000↓300↑ 无丢包  H3-443 257 / 263   Obfs-8443 227 / 206   Reality-Vision 198
#   1000↓300↑ 1%丢包  H3-443 159 / 132   Obfs-8443 126 / 108   Reality-Vision 128
#   300↓50↑   1%丢包  H3-443 129 / 139   Obfs-8443 127 / 118   Reality-Vision 108
# 上行与 Obfs-8443 持平（范围重叠）。去掉混淆后流量就是标准 HTTP/3，伪装到本机站点。
# 代价是未认证者能完成 QUIC 握手，所以防火墙对 UDP 443 同样加了每源 IP 50/s 的握手限速。
# 供 xh hy2 开关复用（同上）
xray_hy2_h3_inbound() {
  cat <<HY2H3EOF
,
        {
            "listen": "0.0.0.0",
            "tag": "hy2-h3",
            "port": ${HY2_H3_PORT},
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
                    // 只谈 TLS 1.3。注意不能靠「删掉这行」来要最新特性——
                    // 删掉后 Xray 会退回它自己的默认下限（更低），
                    // 所以这里显式写死 1.3。
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "cipherSuites": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
                    // 只接受证书覆盖的 SNI；未知 SNI 直接拒绝握手，
                    // 避免本入站被当作任意 SNI 的 TLS 前置来探测或滥用。
                    "rejectUnknownSni": true,
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ]
                },
                "hysteriaSettings": {
                    "version": 2,
                    "udpIdleTimeout": 60,
                    "masquerade": {
                        "type": "proxy",
                        "url": "https://127.0.0.1:8003",
                        "rewriteHost": false,
                        "insecure": true
                    }
                },
                "sockopt": {
                    "tcpFastOpen": true,
                    "tcpcongestion": "brutal"
                }$(if [[ "${FEATURE_NOISE_EXP:-false}" == true ]]; then cat <<NEOF
,
                "finalmask": {
                    "udp": [
                        {
                            "type": "noise",
                            "settings": {
                                "noise": [
                                    {
                                        "type": "exp",
                                        "packet": "${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>}",
                                        "delay": "${NOISE_EXP_DELAY:-10-50}"
                                    }
                                ]
                            }
                        }
                    ]
                }
NEOF
fi)
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
HY2H3EOF
}

if [[ "$FEATURE_HY2_H3" == true ]]; then
  XRAY_HY2_H3_INBOUND=$(printf '\n        // >>xh:hy2h3\n%s\n        // <<xh:hy2h3' "$(xray_hy2_h3_inbound)")
  info "已启用 Hysteria2-H3 直连节点: UDP ${HY2_H3_PORT}（无混淆，标准 HTTP/3 形态）"
fi
fi

# MASQUE 标准 L3 隧道 (IETF RFC 9484 CONNECT-IP, Xray v26.9.30+)
xray_masque_inbound() {
  cat <<MASQUEEOF
,
        {
            "listen": "0.0.0.0",
            "port": ${MASQUE_PORT},
            "protocol": "masque",
            "settings": {
                "users": [
                    {
                        "email": "user@${CDN_DOMAIN}",
                        "pass": "${MASQUE_PASSWORD}",
                        "level": 0
                    }
                ],
                "address": [
                    "10.13.0.1/24",
                    "fd13::1/64"
                ],
                "mtu": 1400
            },
            "streamSettings": {
                "network": "masque",
                "security": "tls",
                "tlsSettings": {
                    "minVersion": "1.3",
                    "maxVersion": "1.3",
                    "rejectUnknownSni": true,
                    "certificates": [
                        {
                            "certificateFile": "${CERT_FILE}",
                            "keyFile": "${CERT_KEY}"
                        }
                    ],
                    "alpn": ["h3", "h2"]
                },
                "sockopt": {
                    "tcpcongestion": "bbr"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
MASQUEEOF
}

XRAY_MASQUE_INBOUND=""
if [[ "$FEATURE_MASQUE" == true ]]; then
  XRAY_MASQUE_INBOUND=$(printf '\n        // >>xh:masque\n%s\n        // <<xh:masque' "$(xray_masque_inbound)")
  info "已启用 MASQUE 标准 L3 隧道 (RFC 9484): UDP/TCP ${MASQUE_PORT}"
fi

# XDRIVE 网盘穿透代理 (Google Drive 中继, Xray v26.9.30+)
xray_xdrive_inbound() {
  cat <<XDRIVEEOF
,
        {
            "tag": "vless-xdrive",
            "port": 0,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID2}",
                        "level": 0
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xdrive",
                "xdriveSettings": {
                    "service": "Google Drive",
                    "remoteFolder": "${XDRIVE_FOLDER:-unknown}",
                    "secrets": [
                        "${XDRIVE_CLIENT_ID:-unknown}",
                        "${XDRIVE_CLIENT_SECRET:-unknown}",
                        "${XDRIVE_REFRESH_TOKEN:-unknown}"
                    ]
                }
            }
        }
XDRIVEEOF
}

XRAY_XDRIVE_INBOUND=""
if [[ "$FEATURE_XDRIVE" == true && -n "${XDRIVE_FOLDER:-}" && -n "${XDRIVE_CLIENT_ID:-}" ]]; then
  XRAY_XDRIVE_INBOUND=$(printf '\n        // >>xh:xdrive\n%s\n        // <<xh:xdrive' "$(xray_xdrive_inbound)")
  info "已启用 XDRIVE 网盘穿透代理 (Google Drive)"
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

# 出站分流（可选，默认关闭）：每条规则单独一行并带 xh-block-* 标记，xh block 据此增删
XRAY_BLOCK_ADS_RULE=""
XRAY_BLOCK_CN_RULE=""
if [[ "${FEATURE_BLOCK_ADS:-false}" == true ]]; then
  XRAY_BLOCK_ADS_RULE=$'\n            , { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" } // xh-block-ads'
fi
if [[ "${FEATURE_BLOCK_CN:-false}" == true ]]; then
  XRAY_BLOCK_CN_RULE=$'\n                    , { "action": "block", "ip": ["geoip:cn"] } // xh-block-cn'
fi

info "写入 /usr/local/etc/xray/config.json ..."
# 包成函数：10-service-check.sh 里校验失败时，要在关掉可选入站后用同样的模板重新生成
write_xray_config() {
cat > /usr/local/etc/xray/config.json << XRAYEOF
@@include templates/xray-config.json.tmpl
XRAYEOF
}
write_xray_config

# 节点状态：供管理命令 xh 读取（info / sub / status / uninstall）
info "写入 ${NODE_ENV_FILE} ..."
{
  printf 'PROJECT_NAME=%q\n'      "$PROJECT_NAME"
  printf 'PROJECT_VERSION=%q\n'   "$PROJECT_VERSION"
  printf 'FEATURE_H3_DIRECT=%q\n' "$FEATURE_H3_DIRECT"
  printf 'FEATURE_HY2=%q\n'       "$FEATURE_HY2"
  printf 'FEATURE_HY2_H3=%q\n'    "$FEATURE_HY2_H3"
  printf 'FEATURE_HY2_OBFS=%q\n'  "${FEATURE_HY2_OBFS:-false}"
  printf 'HY2_H3_PORT=%q\n'       "${HY2_H3_PORT:-443}"
  printf 'FEATURE_H2_DIRECT=%q\n' "$FEATURE_H2_DIRECT"
  printf 'FEATURE_PORT_HOPPING=%q\n' "${FEATURE_PORT_HOPPING:-false}"
  printf 'H3_PORT=%q\n'           "$H3_PORT"
  printf 'H2_PORT=%q\n'           "$H2_PORT"
  printf 'HY2_PORT=%q\n'          "$HY2_PORT"
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
  printf 'VISION_FLOW=%q\n'       "${VISION_FLOW:-xtls-rprx-vision}"
  printf 'PUBLIC_KEY=%q\n'        "$PUBLIC_KEY"
  printf 'PRIVATE_KEY=%q\n'       "$PRIVATE_KEY"
  printf 'SHORT_ID=%q\n'          "$SHORT_ID"
  printf 'XHTTP_PATH=%q\n'        "$XHTTP_PATH"
  printf 'VLESSENC_ENCRYPTION=%q\n' "$VLESSENC_ENCRYPTION"
  printf 'VLESSENC_DECRYPTION=%q\n' "$VLESSENC_DECRYPTION"
  printf 'XHTTP_ENCRYPTION=%q\n'    "${XHTTP_ENCRYPTION:-$VLESSENC_ENCRYPTION}"
  printf 'VPS_IP_URI=%q\n'          "${VPS_IP_URI:-$VPS_IP}"
  printf 'FEATURE_XPADDING=%q\n'  "$FEATURE_XPADDING"
  printf 'FEATURE_XHTTP_VLESSENC=%q\n' "${FEATURE_XHTTP_VLESSENC:-true}"
  printf 'FEATURE_CDN_H2=%q\n'    "${FEATURE_CDN_H2:-true}"
  printf 'FEATURE_CDN_H3=%q\n'    "${FEATURE_CDN_H3:-true}"
  printf 'FEATURE_BLOCK_CN=%q\n'  "${FEATURE_BLOCK_CN:-false}"
  printf 'FEATURE_BLOCK_ADS=%q\n' "${FEATURE_BLOCK_ADS:-false}"
  printf 'FEATURE_REALITY_UP_CDN_DOWN=%q\n' "${FEATURE_REALITY_UP_CDN_DOWN:-true}"
  printf 'FEATURE_UP_CDN_DOWN_MIHOMO=%q\n'  "${FEATURE_UP_CDN_DOWN_MIHOMO:-${FEATURE_REALITY_UP_CDN_DOWN:-true}}"
  printf 'FEATURE_CDN_UP_REALITY_DOWN=%q\n' "${FEATURE_CDN_UP_REALITY_DOWN:-false}"
  printf 'REALITY_MIN_CLIENT_VER=%q\n' "${REALITY_MIN_CLIENT_VER:-1.8.0}"
  printf 'REALITY_MAX_TIME_DIFF=%q\n'  "${REALITY_MAX_TIME_DIFF:-}"
  printf 'FEATURE_CDN_ECH=%q\n'   "$FEATURE_CDN_ECH"
  printf 'CDN_ECH_ENABLED=%q\n'   "$CDN_ECH_ENABLED"
  printf 'FEATURE_MASQUE=%q\n'         "${FEATURE_MASQUE:-false}"
  printf 'MASQUE_PORT=%q\n'            "${MASQUE_PORT:-}"
  printf 'MASQUE_PASSWORD=%q\n'        "${MASQUE_PASSWORD:-}"
  printf 'FEATURE_XDRIVE=%q\n'         "${FEATURE_XDRIVE:-false}"
  printf 'XDRIVE_FOLDER=%q\n'          "${XDRIVE_FOLDER:-}"
  printf 'XDRIVE_CLIENT_ID=%q\n'       "${XDRIVE_CLIENT_ID:-}"
  printf 'XDRIVE_CLIENT_SECRET=%q\n'   "${XDRIVE_CLIENT_SECRET:-}"
  printf 'XDRIVE_REFRESH_TOKEN=%q\n'   "${XDRIVE_REFRESH_TOKEN:-}"
  printf 'FEATURE_NOISE_EXP=%q\n'      "${FEATURE_NOISE_EXP:-false}"
  printf 'NOISE_EXP_PACKET=%q\n'       "${NOISE_EXP_PACKET:-<b 16030100><r 32><t><c><rd 8>}"
  printf 'NOISE_EXP_DELAY=%q\n'        "${NOISE_EXP_DELAY:-10-50}"
  if [[ "$FEATURE_XPADDING" == true ]]; then
    printf 'XHTTP_PADDING_HEADER=%q\n'    "$XHTTP_PADDING_HEADER"
    printf 'XHTTP_PADDING_KEY=%q\n'       "$XHTTP_PADDING_KEY"
    printf 'XHTTP_PADDING_PLACEMENT=%q\n' "${XHTTP_PADDING_PLACEMENT:-queryInHeader}"
    printf 'XHTTP_PADDING_METHOD=%q\n'    "${XHTTP_PADDING_METHOD:-tokenish}"
  fi
} > "$NODE_ENV_FILE"
chmod 600 "$NODE_ENV_FILE"

# 备用节点库的服务端部分：备用入站的完整文本（带前导逗号），xh 开启时插入 inbounds 末尾
mkdir -p /etc/xhttp-cdn/all
xray_h2_direct_inbound  > /etc/xhttp-cdn/all/inbound-h2direct.json
xray_hy2_obfs_inbound   > /etc/xhttp-cdn/all/inbound-hy2obfs.json
xray_hy2_h3_inbound     > /etc/xhttp-cdn/all/inbound-hy2h3.json
xray_masque_inbound     > /etc/xhttp-cdn/all/inbound-masque.json
xray_xdrive_inbound     > /etc/xhttp-cdn/all/inbound-xdrive.json
chmod 700 /etc/xhttp-cdn/all; chmod 600 /etc/xhttp-cdn/all/inbound-*.json

echo ""

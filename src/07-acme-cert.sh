# ==================================================
# 证书申请与复用
# ==================================================

info "[2/7] 申请 / 复用 SSL 证书"

curl https://get.acme.sh | sh
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

acme.sh --set-default-ca --server letsencrypt

prefer_ipv4_for_acme() {
  if [[ "$IP_CHOICE" == "1" ]] && ! grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
    echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
  fi
}

ACME_CERT_HOME="/root/.acme.sh/${REALITY_DOMAIN}_ecc"
ACME_CERT_CONF="${ACME_CERT_HOME}/${REALITY_DOMAIN}.conf"

have_existing_dual_cert() {
  [[ -f "$ACME_CERT_CONF" ]] || return 1
  [[ -f "$ACME_CERT_HOME/fullchain.cer" ]] || return 1
  [[ -f "$ACME_CERT_HOME/${REALITY_DOMAIN}.key" ]] || return 1

  local cert_domains
  cert_domains=$(openssl x509 -in "$ACME_CERT_HOME/fullchain.cer" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' || true)
  grep -Fxq "$REALITY_DOMAIN" <<< "$cert_domains" &&
    grep -Fxq "$CDN_DOMAIN" <<< "$cert_domains"
}

issue_dual_cert() {
  local force_flag=""
  # 如果已有旧证书或 conf 但不满足双域名 SAN，必须加 --force 强制覆盖申请，否则 acme.sh 会因未到期直接 skip
  if [[ -f "$ACME_CERT_CONF" || -f "$ACME_CERT_HOME/fullchain.cer" ]]; then
    force_flag="--force"
  fi

  if [[ "$IP_CHOICE" == "2" ]]; then
    acme.sh --issue -d "$REALITY_DOMAIN" -d "$CDN_DOMAIN" --standalone --listen-v6 --keylength ec-256 $force_flag \
      --pre-hook "${NGINX_STOP_CMD} 2>/dev/null || true" \
      --post-hook "${NGINX_START_CMD} 2>/dev/null || true"
  else
    prefer_ipv4_for_acme
    acme.sh --issue -d "$REALITY_DOMAIN" -d "$CDN_DOMAIN" --standalone --listen-v4 --request-v4 --keylength ec-256 $force_flag \
      --pre-hook "${NGINX_STOP_CMD} 2>/dev/null || true" \
      --post-hook "${NGINX_START_CMD} 2>/dev/null || true"
  fi
}

if have_existing_dual_cert; then
  info "检测到已存在的双域名证书，跳过重新签发，直接复用"
else
  info "未检测到可复用的双域名证书，开始申请 (需要 80 端口空闲)..."
  if ! ISSUE_OUTPUT=$(issue_dual_cert 2>&1); then
    echo "$ISSUE_OUTPUT"
    error "双域名证书申请失败，请确认 80 端口未被占用、本机防火墙已放行 80 端口且域名 DNS 已正确解析"
  fi
  echo "$ISSUE_OUTPUT"
  have_existing_dual_cert || error "证书申请流程已结束，但未能在 ${ACME_CERT_HOME} 找到有效的双域名证书"
fi

echo ""

# ==================================================
# 证书链裁剪脚本落地（握手提速，v4.9.0）
# ==================================================
# Let's Encrypt 的 fullchain 末尾带交叉签名的根证书（ISRG Root X2 by X1）。
# 根证书本来就该由客户端信任库提供，服务端每次握手重传一遍纯属浪费。
# 对 QUIC（h3-direct / Hysteria2 / CDN-H3）尤其贵：客户端地址被验证前，
# 服务端受 3 倍放大限制，首包群越大越容易多吃一个 RTT。
#
# 实测本域证书 4 张 → 3 张、4841 → 3243 字节，每次握手少传 1598 字节；
# 单条 TLS 1.3 握手服务端出向字节数 5509 → 4364（tcpdump 实测）。
# 再往下裁不动：只留 leaf + YE2 时 openssl verify 直接失败（Root YE 尚未进
# 主流信任库），脚本会自己停手——它的判据是「从尾部逐张试删、每删一张验一次」，
# 不是按张数写死的，所以换签发方 / 换根证书都不需要改这里。
#
# 必须落成独立文件而不是内联进 reloadcmd：install.sh 是 src/*.sh 拼出来的单文件，
# 装完就没了，而续期发生在几十天以后，那时只有 /usr/local/sbin 里的这份还在。
install -d /usr/local/sbin
cat > /usr/local/sbin/xh-trim-chain <<'XH_TRIM_CHAIN_EOF'
#!/bin/sh
# xh-trim-chain <fullchain.pem>
#
# 从证书链尾部逐张试删，每删一张就拿本机信任库验一次；验得过才落实，
# 验不过立刻停手。裁掉的都是客户端信任库里本来就有的根证书，服务端每次
# 握手重传一遍纯属浪费。对 QUIC（h3 / hy2 / tuic）尤其贵：QUIC 在客户端
# 地址被验证前有 3 倍放大限制，服务端首包群越大越容易多吃一个 RTT。
#
# 判据不能用「自签根」：Let's Encrypt 链尾那张是交叉签名的
# （ISRG Root X2 由 X1 签发），subject != issuer，按自签找一张都裁不掉。
# 找不到 CA bundle 时直接放弃裁剪——宁可慢一点，也不能生成连不上的链。
set -u
f="${1:-}"
[ -n "$f" ] && [ -s "$f" ] || exit 0
command -v openssl >/dev/null 2>&1 || exit 0

bundle=""
for b in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
         /etc/ssl/cert.pem /etc/ssl/certs/ca-bundle.crt; do
  [ -s "$b" ] && { bundle="$b"; break; }
done
[ -n "$bundle" ] || exit 0

d=$(mktemp -d) || exit 0
trap 'rm -rf "$d"' EXIT
awk -v d="$d" 'BEGIN{n=0} /-----BEGIN CERTIFICATE-----/{n++} n>0{print > (d "/c" n ".pem")}' "$f"
n=$(find "$d" -name 'c*.pem' | wc -l)
[ "$n" -ge 2 ] || exit 0

# 注意：POSIX sh 的函数没有局部变量，这里刻意用 _ck / _ci 而不是 keep / i——
# 早先版本在函数里复用了外层的 keep，函数每调一次就把外层游标改掉，
# 结果验证失败也照样把链砍短了一张（实测把 3 张链砍成 2 张，客户端验不过）。
chain_ok() {
  _ck=$1; _ci=2; set --
  while [ "$_ci" -le "$_ck" ]; do set -- "$@" -untrusted "$d/c$_ci.pem"; _ci=$((_ci+1)); done
  openssl verify -CAfile "$bundle" "$@" "$d/c1.pem" >/dev/null 2>&1
}

# 完整链本来就验不过（私有 CA / 缺中间证书）就别动它
chain_ok "$n" || exit 0

keep=$n
while [ "$keep" -gt 1 ] && chain_ok $((keep-1)); do keep=$((keep-1)); done
[ "$keep" -lt "$n" ] || exit 0

tmp="$d/trimmed.pem"; i=1; : > "$tmp"
while [ "$i" -le "$keep" ]; do cat "$d/c$i.pem" >> "$tmp"; i=$((i+1)); done
before=$(wc -c < "$f"); after=$(wc -c < "$tmp")
cp -f "$f" "$f.full" 2>/dev/null
cat "$tmp" > "$f"
chmod 600 "$f" "$f.full" 2>/dev/null
echo "证书链已裁剪：$n → $keep 张（${before} → ${after} 字节，每次握手少传 $((before-after)) 字节）"
XH_TRIM_CHAIN_EOF
chmod 755 /usr/local/sbin/xh-trim-chain

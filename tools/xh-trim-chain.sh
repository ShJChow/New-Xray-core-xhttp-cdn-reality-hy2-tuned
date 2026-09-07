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

"""订阅链接 → Xray 客户端出站（vless / hysteria2），与 xray_compat.py 同一套解析。"""
import json, urllib.parse as up
XRAY_PROTOS = {"vless", "hysteria2", "hy2"}
def q1(qs, k, d=None): return qs.get(k, [d])[0]
def truthy(v): return str(v).lower() in ("1", "true", "yes")

def tls_block(qs, sec):
    t = {"serverName": q1(qs, "sni", "")}
    if q1(qs, "fp"): t["fingerprint"] = q1(qs, "fp")
    if q1(qs, "alpn"): t["alpn"] = q1(qs, "alpn").split(",")
    if sec == "tls":
        if truthy(q1(qs, "insecure", "0")) or truthy(q1(qs, "allowInsecure", "0")): t["allowInsecure"] = True
        if q1(qs, "ech"): t["echConfigList"] = q1(qs, "ech")
        if q1(qs, "pinSHA256"): t["pinnedPeerCertSha256"] = q1(qs, "pinSHA256")
    if sec == "reality":
        t = {"serverName": q1(qs, "sni", ""), "fingerprint": q1(qs, "fp", "chrome"),
             "publicKey": q1(qs, "pbk", ""), "shortId": q1(qs, "sid", ""), "spiderX": q1(qs, "spx", "")}
    return t

def vless(u, qs):
    uid = up.unquote(u.username or ""); host, port = u.hostname, u.port or 443
    user = {"id": uid, "encryption": q1(qs, "encryption", "none")}
    if q1(qs, "flow"): user["flow"] = q1(qs, "flow")
    ob = {"protocol": "vless", "settings": {"vnext": [{"address": host, "port": port, "users": [user]}]}}
    net = q1(qs, "type", "tcp"); net = "raw" if net == "tcp" else net
    sec = q1(qs, "security", "none")
    ss = {"network": net, "security": sec}
    if sec in ("tls", "reality"): ss[f"{sec}Settings"] = tls_block(qs, sec)
    if net == "xhttp":
        x = {"path": q1(qs, "path", "/"), "mode": q1(qs, "mode", "auto")}
        if q1(qs, "host"): x["host"] = q1(qs, "host")
        if q1(qs, "extra"): x["extra"] = json.loads(q1(qs, "extra"))
        ss["xhttpSettings"] = x
    if q1(qs, "packetEncoding"): ob["settings"]["vnext"][0]["users"][0]  # xray 客户端默认 xudp，忽略
    ob["streamSettings"] = ss
    return ob

def hy2(u, qs):
    auth = up.unquote(u.username or "") + ((":" + up.unquote(u.password)) if u.password else "")
    ob = {"protocol": "hysteria", "settings": {"version": 2, "address": u.hostname, "port": u.port or 443}}
    t = tls_block(qs, "tls"); t.setdefault("alpn", ["h3"])
    ss = {"network": "hysteria", "security": "tls", "tlsSettings": t, "hysteriaSettings": {"version": 2, "auth": auth}}
    fm = {}
    if q1(qs, "obfs") == "salamander": fm["udp"] = [{"type": "salamander", "settings": {"password": q1(qs, "obfs-password", "")}}]
    up_, dn = q1(qs, "upmbps"), q1(qs, "downmbps")
    if up_ or dn:
        qp = {"congestion": "brutal"}
        if up_: qp["brutalUp"] = f"{up_} mbps"
        if dn: qp["brutalDown"] = f"{dn} mbps"
        fm["quicParams"] = qp
    if fm: ss["finalmask"] = fm
    ob["streamSettings"] = ss
    return ob


def load_nodes(files):
    out = {}
    for f in files:
        try: lines = [l.strip() for l in open(f) if l.strip()]
        except OSError: continue
        for l in lines:
            scheme = l.split("://")[0].lower()
            if scheme not in XRAY_PROTOS: continue
            name = up.unquote(l.split("#")[-1]); u = up.urlsplit(l); qs = up.parse_qs(u.query)
            out.setdefault(name, vless(u, qs) if scheme == "vless" else hy2(u, qs))
    return out

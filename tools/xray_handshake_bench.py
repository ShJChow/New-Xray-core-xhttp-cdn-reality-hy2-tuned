#!/usr/bin/env python3
"""逐节点握手延迟（v4.9.48）：netns + netem 纯 RTT（不丢包不限速），经 socks 取 http://www.gstatic.com/generate_204 的 time_total。
冷 = 客户端刚启动后的第一枪；热 = 隧道已建后新开代理连接；闲置 = 空闲 N 秒后的第一枪。结果同时折算成 RTT 个数。
用法: xray_handshake_bench.py <rtt_ms> <rounds> [idle秒,idle秒]
环境: ONLY=名1,名2  WARM=热连接次数  URL=目标  SB_BIN  VAR=json 覆盖变体
      变体键：link（Xray 订阅节点名，可带 patch）/ uri（直接给一条 vless / hysteria2 链接）/ core=sing-box / sbtag（sbbox 客户端出站）/ mihomo+src（mihomo 节点名与 yaml）
含凭据的客户端配置写在 0700 临时目录（或 BENCH_TMP），结束时 shred 删除。
"""
import json, subprocess, sys, time, statistics, copy, os, tempfile, atexit, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xlinks
S = os.environ.get("BENCH_TMP") or tempfile.mkdtemp(prefix="hsbench-")
os.chmod(S, 0o700)
def _cleanup():
    for f in glob.glob(f"{S}/hs_*"):
        if os.path.isfile(f): subprocess.run(["shred", "-u", f])
    if not os.environ.get("BENCH_TMP"): subprocess.run(["rm", "-rf", S])
atexit.register(_cleanup)
RTT = int(sys.argv[1]); R = int(sys.argv[2]); IDLES = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 and sys.argv[3] else []
WARM = int(os.environ.get("WARM", "5"))
NS = "hsbench"
SUB = [l for l in os.popen("ls -d /usr/local/nginx/html/sub/*/").read().split() if l][0]
LINKS = xlinks.load_nodes([f"{SUB}/v2rayn-raw.txt"])
RAW = xlinks.load_raw([f"{SUB}/v2rayn-raw.txt"])
SB_BIN = os.environ.get("SB_BIN", "/root/sbbox/sing-box")
SBC = json.load(open("/root/sbbox/sbox_client.json"))
CDN = next((l.split("=", 1)[1].strip().strip("\"'") for l in open("/etc/xhttp-cdn/node.env") if l.startswith("CDN_DOMAIN=")), "")
URL = os.environ.get("URL", "http://www.gstatic.com/generate_204")
H = "10.202.0.1"

def sh(c, check=False): return subprocess.run(c, shell=True, capture_output=True, text=True, check=check)
NAT = ["-X FORWARD -s 10.202.0.0/30 -j ACCEPT", "-X FORWARD -d 10.202.0.0/30 -j ACCEPT",
       "-t nat -X POSTROUTING -s 10.202.0.0/30 ! -d 10.202.0.0/30 -j MASQUERADE"]
def ns_down():
    for r in NAT:
        while sh(f"iptables {r.replace('-X', '-D', 1)}").returncode == 0: pass
    sh(f"ip netns del {NS}"); sh("ip link del hvh"); sh(f"rm -rf /etc/netns/{NS}")
def ns_up():
    ns_down()
    for c in [f"ip netns add {NS}", "ip link add hvh type veth peer name hvc", f"ip link set hvc netns {NS}",
              f"ip addr add {H}/30 dev hvh", "ip link set hvh up", f"ip -n {NS} addr add 10.202.0.2/30 dev hvc",
              f"ip -n {NS} link set hvc up", f"ip -n {NS} link set lo up", f"ip -n {NS} route add default via {H}"]:
        sh(c, True)
    for r in NAT: sh(f"iptables {r.replace('-X', '-I', 1)}", True)
    os.makedirs(f"/etc/netns/{NS}", exist_ok=True)
    open(f"/etc/netns/{NS}/resolv.conf", "w").write("nameserver 1.1.1.1\n")
    sh(f"tc qdisc add dev hvh root netem delay {RTT/2}ms limit 100000", True)
    sh(f"ip netns exec {NS} tc qdisc add dev hvc root netem delay {RTT/2}ms limit 100000", True)

def sb_hy2(name):
    u, qs = RAW[name]; q = lambda k, d=None: qs.get(k, [d])[0]
    ob = {"type": "hysteria2", "server": H, "server_port": u.port or 443, "password": xlinks.up.unquote(u.username or ""),
          "tls": {"enabled": True, "server_name": q("sni", ""), "alpn": ["h3"]}}
    if q("upmbps"): ob["up_mbps"] = int(q("upmbps"))
    if q("downmbps"): ob["down_mbps"] = int(q("downmbps"))
    return ob

DEFAULT = [
    {"name": "X Reality-Vision", "link": "VLESS-Reality-Vision-Direct"},
    {"name": "X Reality-XHTTP", "link": "VLESS-Reality-XHTTP-Direct"},
    {"name": "X XHTTP-Direct-H3", "link": "VLESS-XHTTP-Direct-H3"},
    {"name": "X XHTTP-CDN-H3", "link": "VLESS-XHTTP-CDN-H3"},
    {"name": "X Hy2-H3 (xray客户端)", "link": "Hysteria2-H3-Direct"},
    {"name": "X Hy2-H3 (sing-box客户端)", "link": "Hysteria2-H3-Direct", "core": "sing-box"},
    {"name": "S hysteria2", "sbtag": "hysteria2"},
    {"name": "S anytls", "sbtag": "anytls"},
    {"name": "S naive-h3", "sbtag": "naive-h3"},
    {"name": "S naive-h2", "sbtag": "naive-h2"},
    {"name": "S tuic", "sbtag": "tuic"},
]
V = json.loads(os.environ["VAR"]) if os.environ.get("VAR") else DEFAULT
if os.environ.get("ONLY"): V = [v for v in V if v["name"] in os.environ["ONLY"].split(",")]

def setpath(obj, path, val):
    keys = path.split("."); cur = obj
    for k in keys[:-1]: cur = cur[int(k)] if k.isdigit() else cur.setdefault(k, {})
    last = int(keys[-1]) if keys[-1].isdigit() else keys[-1]
    if val is None: cur.pop(last, None) if isinstance(cur, dict) else None
    else: cur[last] = val

def build():
    xin, xout, xr, sin, sout, sr = [], [], [], [], [], []
    mp, ml = [], []
    for i, v in enumerate(V):
        port = 13300 + i
        if v.get("mihomo"):
            import yaml
            src = yaml.safe_load(open(v["src"]))
            o = copy.deepcopy(next(x for x in src["proxies"] if x["name"] == v["mihomo"]))
            o["server"] = H; o["name"] = f"o{i}"
            for k, val in v.get("set", {}).items(): o[k] = val
            mp.append(o); ml.append({"name": f"i{i}", "type": "socks", "listen": "127.0.0.1", "port": port, "udp": True, "proxy": f"o{i}"})
            continue
        if v.get("sbtag") or v.get("core") == "sing-box":
            if v.get("sbtag"):
                o = copy.deepcopy(next(x for x in SBC["outbounds"] if x.get("tag") == v["sbtag"])); o["server"] = H
            else: o = sb_hy2(v["link"])
            for k, val in v.get("set", {}).items(): setpath(o, k, val)
            o["tag"] = f"o{i}"; sout.append(o)
            sin.append({"type": "socks", "tag": f"i{i}", "listen": "127.0.0.1", "listen_port": port})
            sr.append({"inbound": [f"i{i}"], "outbound": f"o{i}"})
        else:
            ob = copy.deepcopy(xlinks.parse_link(v["uri"]) if v.get("uri") else LINKS[v["link"]])
            if ob["protocol"] == "vless":
                vn = ob["settings"]["vnext"][0]
                if not (CDN and vn["address"] == CDN): vn["address"] = H
            else: ob["settings"]["address"] = H
            for p, val in v.get("patch", []): setpath(ob, p, val)
            ob["tag"] = f"o{i}"; xout.append(ob)
            xin.append({"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": {"udp": True}, "tag": f"i{i}"})
            xr.append({"type": "field", "inboundTag": [f"i{i}"], "outboundTag": f"o{i}"})
    cfgs = []
    if mp:
        import yaml
        p = f"{S}/hs_mi.yaml"
        os.makedirs(f"{S}/mihome", exist_ok=True)
        yaml.safe_dump({"mode": "rule", "log-level": "warning", "ipv6": False, "allow-lan": False, "bind-address": "127.0.0.1",
                        "dns": {"enable": False}, "tun": {"enable": False}, "proxies": mp, "listeners": ml, "rules": ["MATCH,DIRECT"]},
                       open(p, "w"), allow_unicode=True)
        t = sh(f"mihomo -d {S}/mihome -t -f {p}");  assert t.returncode == 0, t.stdout[-400:]
        cfgs.append(f"mihomo -d {S}/mihome -f {p}")
    # 每个 Xray 变体单独一个进程：Xray 的 hysteria 客户端按「目标 IP:端口」全局缓存连接
    # （v26.3.27 dialer.go 的 manger.m[addr]），同一进程里指向同一服务端的出站会共用第一个出站
    # 建好的连接及其配置（保活、混淆、拥塞控制），变体之间的差异会被抹掉、冷启动也测成 1R。
    for j, (xi, xo, xrule) in enumerate(zip(xin, xout, xr)):
        p = f"{S}/hs_x{j}.json"; json.dump({"log": {"loglevel": "warning"}, "inbounds": [xi], "outbounds": [xo], "routing": {"rules": [xrule]}}, open(p, "w"))
        t = sh(f"xray run -test -c {p}");  assert t.returncode == 0, t.stdout[-400:]
        cfgs.append(f"xray run -c {p}")
    if sout:
        p = f"{S}/hs_sb.json"; json.dump({"log": {"level": "warn"}, "inbounds": sin, "outbounds": sout + [{"type": "direct", "tag": "direct"}], "route": {"rules": sr, "final": "direct"}}, open(p, "w"))
        t = sh(f"{SB_BIN} check -c {p}");  assert t.returncode == 0, t.stderr[-400:]
        cfgs.append(f"{SB_BIN} run -c {p}")
    return cfgs

def start(cfgs):
    ps = [subprocess.Popen(f"exec ip netns exec {NS} {c}", shell=True, stdout=open(f"{S}/hs_client.log", "a"), stderr=subprocess.STDOUT) for c in cfgs]
    time.sleep(3); return ps
def stop(ps):
    for p in ps: p.terminate()
    for p in ps:
        try: p.wait(5)
        except Exception: p.kill()
    sh(f"pkill -f '{S}/hs_'"); time.sleep(0.5)

def req(i):
    o = sh(f"ip netns exec {NS} curl -s -o /dev/null --max-time 10 -w '%{{http_code}} %{{time_total}}' --socks5-hostname 127.0.0.1:{13300+i} {URL}").stdout.split()
    return float(o[1]) * 1000 if len(o) == 2 and o[0] == "204" else None

ns_up()
res = {v["name"]: {"cold": [], "warm": [], **{f"idle{s}": [] for s in IDLES}} for v in V}
try:
    cfgs = build()
    base = [float(sh(f"ip netns exec {NS} curl -s -o /dev/null -w '%{{time_total}}' {URL}").stdout or 0) * 1000 for _ in range(3)]
    for r in range(R):
        ps = start(cfgs)
        for i, v in enumerate(V):
            res[v["name"]]["cold"].append(req(i))
            for _ in range(WARM): res[v["name"]]["warm"].append(req(i))
        if r < R - 1 or not IDLES: stop(ps)
    for s in IDLES:
        time.sleep(s)
        for i, v in enumerate(V): res[v["name"]][f"idle{s}"].append(req(i))
    if IDLES: stop(ps)
finally:
    sh(f"pkill -f '{S}/hs_'"); ns_down()

def fmt(a):
    ok = [x for x in a if x is not None]; bad = len(a) - len(ok)
    if not ok: return f"{'失败':>14}"
    m = statistics.median(ok)
    return f"{m:6.0f}ms {m/RTT:4.1f}R" + (f" !{bad}" if bad else "")
print(f"\n### RTT {RTT}ms  无代理直连基线 {statistics.median(base):.0f}ms（TCP+HTTP = 2R）  冷 {R} 次 / 热 {R*WARM} 次")
hdr = f"{'节点':<28}{'冷启动':>15}{'热连接':>15}" + "".join(f"{'闲置'+str(s)+'s':>15}" for s in IDLES)
print(hdr)
for v in V:
    d = res[v["name"]]
    print(f"{v['name']:<28}{fmt(d['cold']):>15}{fmt(d['warm']):>15}" + "".join(f"{fmt(d[f'idle{s}']):>15}" for s in IDLES))

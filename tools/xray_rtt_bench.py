#!/usr/bin/env python3
"""Xray 客户端（订阅链接解析）在真实 RTT + 用户线路限速下的上下行基准。
用法: xray_rtt_bench.py <rtt_ms> <down_loss_pct> <down_mbit|0> <up_mbit|0> <variants.json> [N]
variants: [{"name":..., "link":"订阅中的节点名", "server":"10.200.0.1", "patch":[["路径.a.b", 值|null], ...]}]
"""
import json, subprocess, sys, time, statistics, copy, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xlinks
S = os.environ.get("BENCH_TMP", "/tmp")
RTT, LOSS, DOWN, UP, VARF = int(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
N = int(sys.argv[6]) if len(sys.argv) > 6 else 3
NS = "xbench"
SUB = [l for l in os.popen("ls -d /usr/local/nginx/html/sub/*/").read().split() if l][0]
LINKS = xlinks.load_nodes([f"{SUB}/v2rayn-raw.txt", "/root/sbbox/nodes.txt"])
DL_URLS = ["https://speedtest.fremont.linode.com/100MB-fremont.bin", "https://sjo-ca-us-ping.vultr.com/vultr.com.100MB.bin"]
DL_BYTES = int(os.environ.get("DL_BYTES", "60000000")); UP_BYTES = int(os.environ.get("UP_BYTES", "20000000"))
UPFILE = f"{S}/up_payload.bin"

def sh(c, check=False): return subprocess.run(c, shell=True, capture_output=True, text=True, check=check)

def shape(dev, ns, delay_ms, loss, rate):
    pre = f"ip netns exec {ns} " if ns else ""
    sh(f"{pre}ethtool -K {dev} gso off tso off gro off")
    lossarg = f" loss {loss}%" if loss else ""
    if rate:
        # tbf 模拟用户线路（排队上限 100ms），netem 作内层加延迟/丢包
        sh(f"{pre}tc qdisc add dev {dev} root handle 1: tbf rate {rate}mbit burst 256kb latency 100ms", True)
        sh(f"{pre}tc qdisc add dev {dev} parent 1:1 handle 10: netem delay {delay_ms}ms{lossarg} limit 400000", True)
    elif delay_ms or loss:
        sh(f"{pre}tc qdisc add dev {dev} root netem delay {delay_ms}ms{lossarg} limit 400000", True)

def ns_up():
    ns_down()
    for c in [f"ip netns add {NS}", "ip link add xvh type veth peer name xvc", f"ip link set xvc netns {NS}",
              "ip addr add 10.201.0.1/30 dev xvh", "ip link set xvh up",
              f"ip -n {NS} addr add 10.201.0.2/30 dev xvc", f"ip -n {NS} link set xvc up",
              f"ip -n {NS} link set lo up", f"ip -n {NS} route add default via 10.201.0.1"]:
        sh(c, True)
    shape("xvh", None, RTT/2, LOSS, DOWN)     # 服务端→客户端 = 下行
    shape("xvc", NS, RTT/2, 0, UP)            # 客户端→服务端 = 上行

def ns_down():
    sh(f"ip netns del {NS}"); sh("ip link del xvh")

def kill_clients():
    me = os.getpid()
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me: continue
        try: argv = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
        except OSError: continue
        if argv and argv[0].endswith(b"xray") and any(a.endswith(b"xb_client.json") for a in argv):
            try: os.kill(int(pid), 15)
            except OSError: pass

def setpath(obj, path, val):
    keys = path.split("."); cur = obj
    for k in keys[:-1]:
        k = int(k) if k.isdigit() else k
        cur = cur[k] if isinstance(k, int) else cur.setdefault(k, {})
    last = int(keys[-1]) if keys[-1].isdigit() else keys[-1]
    if val is None:
        if isinstance(cur, dict): cur.pop(last, None)
    else: cur[last] = val

variants = [v for v in json.load(open(VARF)) if not v.get("skip")]
if not os.path.exists(UPFILE) or os.path.getsize(UPFILE) != UP_BYTES:
    with open(UPFILE, "wb") as f: f.write(os.urandom(UP_BYTES))
ns_up()
try:
    ins, outs, rules = [], [], []
    for i, v in enumerate(variants):
        ob = copy.deepcopy(LINKS[v["link"]])
        tgt = "10.201.0.1"
        if ob["protocol"] == "vless": ob["settings"]["vnext"][0]["address"] = tgt
        else: ob["settings"]["address"] = tgt
        for p, val in v.get("patch", []): setpath(ob, p, val)
        ob["tag"] = f"o{i}"; outs.append(ob)
        ins.append({"listen": "127.0.0.1", "port": 13100 + i, "protocol": "socks", "settings": {"udp": True}, "tag": f"i{i}"})
        rules.append({"type": "field", "inboundTag": [f"i{i}"], "outboundTag": f"o{i}"})
    cfg = f"{S}/xb_client.json"
    json.dump({"log": {"loglevel": "warning"}, "inbounds": ins, "outbounds": outs, "routing": {"rules": rules}}, open(cfg, "w"), indent=1)
    t = sh(f"xray run -test -c {cfg}")
    if t.returncode: print("CONFIG FAIL:", (t.stdout + t.stderr)[-500:]); sys.exit(1)
    p = subprocess.Popen(f"ip netns exec {NS} xray run -c {cfg}", shell=True, stdout=open(f"{S}/xb.log", "w"), stderr=subprocess.STDOUT)
    time.sleep(4)
    rt = re.search(r"= [\d.]+/([\d.]+)/", sh(f"ip netns exec {NS} ping -c 4 -i 0.3 -q 10.201.0.1").stdout)
    print(f"\n### RTT {RTT}ms(实测 {rt.group(1) if rt else '?'}) 下行丢包 {LOSS}% 线路 {DOWN or '不限'}↓/{UP or '不限'}↑ Mbps  每项 {N} 次 (↓{DL_BYTES//1000000}MB ↑{UP_BYTES//1000000}MB)")
    print(f"{'变体':<38}{'下行中位':>8}{'范围':>12}{'上行中位':>9}{'范围':>12}{'无效↓/↑':>9}")
    def c(port, args): return sh(f"ip netns exec {NS} curl -s -o /dev/null --socks5-hostname 127.0.0.1:{port} {args}").stdout.split()
    for i, v in enumerate(variants):
        port = 13100 + i
        c(port, "--max-time 15 http://www.gstatic.com/generate_204")
        dl, ul, bd, bu = [], [], 0, 0
        for k in range(N):
            o = c(port, f"-w '%{{http_code}} %{{size_download}} %{{speed_download}}' --max-time 120 -r 0-{DL_BYTES-1} {DL_URLS[k%2]}")
            if len(o)==3 and o[0] in ("200","206") and int(o[1])>=DL_BYTES: dl.append(float(o[2])*8/1e6)
            else: bd += 1
            o = c(port, f"-w '%{{http_code}} %{{size_upload}} %{{speed_upload}}' --max-time 120 -X POST --data-binary @{UPFILE} https://speed.cloudflare.com/__up")
            if len(o)==3 and o[0]=="200" and int(o[1])>=UP_BYTES: ul.append(float(o[2])*8/1e6)
            else: bu += 1; 
            if len(o)>=1 and o[0]=="429": print("   ! speed.cloudflare 429 限流")
        f = lambda a: (f"{statistics.median(a):.0f}", f"{min(a):.0f}~{max(a):.0f}") if a else ("—", "")
        d, u = f(dl), f(ul)
        print(f"{v['name']:<38}{d[0]:>8}{d[1]:>12}{u[0]:>9}{u[1]:>12}{f'{bd}/{bu}':>9}"); sys.stdout.flush()
    p.terminate()
finally:
    kill_clients(); ns_down()

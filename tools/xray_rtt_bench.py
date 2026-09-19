#!/usr/bin/env python3
"""Xray 客户端（订阅链接解析）在真实 RTT + 用户线路限速下的上下行基准。
用法: xray_rtt_bench.py <rtt_ms> <down_loss_pct> <down_mbit|0> <up_mbit|0> <variants.json> [N]
variants: [{"name":..., "link":"订阅中的节点名", "patch":[["路径.a.b", 值|null], ...]}]\n          hysteria2 可加 "core":"sing-box" 用 sing-box 客户端测，配合 "set"/"unset" 改 up_mbps/down_mbps
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
RAW = xlinks.load_raw([f"{SUB}/v2rayn-raw.txt", "/root/sbbox/nodes.txt"])
SB_BIN = os.environ.get("SB_BIN", "/root/sbbox/sing-box")

def sb_hy2(name, tgt):
    """按 v2rayN(sing-box 内核) 的映射把 hysteria2 链接转成 sing-box 出站：upmbps/downmbps → up_mbps/down_mbps"""
    u, qs = RAW[name]; q = lambda k, d=None: qs.get(k, [d])[0]
    ob = {"type": "hysteria2", "server": tgt, "server_port": u.port or 443,
          "password": xlinks.up.unquote(u.username or ""),
          "tls": {"enabled": True, "server_name": q("sni", ""), "alpn": ["h3"]}}
    if q("obfs") == "salamander": ob["obfs"] = {"type": "salamander", "password": q("obfs-password", "")}
    if q("upmbps"): ob["up_mbps"] = int(q("upmbps"))
    if q("downmbps"): ob["down_mbps"] = int(q("downmbps"))
    return ob
DL_URLS = ["https://speedtest.fremont.linode.com/100MB-fremont.bin", "https://sjo-ca-us-ping.vultr.com/vultr.com.100MB.bin"]
DL_BYTES = int(os.environ.get("DL_BYTES", "60000000")); UP_BYTES = int(os.environ.get("UP_BYTES", "20000000"))
UPFILE = f"{S}/up_payload.bin"

def sh(c, check=False): return subprocess.run(c, shell=True, capture_output=True, text=True, check=check)

def shape(dev, ns, delay_ms, loss, rate):
    pre = f"ip netns exec {ns} " if ns else ""
    sh(f"{pre}ethtool -K {dev} gso off tso off gro off")
    lossarg = f" loss {loss}%" if loss else ""
    if rate:
        # 用 netem 自带 rate 模拟用户线路，并给队列设**有界**上限：
        # 在途（延迟线）包数 + 约 BUF_MS 毫秒的排队，按 1400 字节/包估算。
        # 早期版本用 tbf 外层 + netem 内层且内层 limit=400000，tbf 的 latency 管不到内层，
        # 实际模拟出 1 秒级缓冲：上传期间并行 ping 飙到 ~1000ms，Brutal 会把它灌满、BBR 被严重误导。
        buf_ms = float(os.environ.get("BUF_MS", "100"))
        limit = int(rate * 1e6 * (delay_ms + buf_ms) / 1000 / (1400 * 8)) + 64
        sh(f"{pre}tc qdisc add dev {dev} root netem delay {delay_ms}ms{lossarg} rate {rate}mbit limit {limit}", True)
    elif delay_ms or loss:
        sh(f"{pre}tc qdisc add dev {dev} root netem delay {delay_ms}ms{lossarg} limit 400000", True)

def ns_up():
    ns_down()
    for c in [f"ip netns add {NS}", "ip link add xvh type veth peer name xvc", f"ip link set xvc netns {NS}",
              "ip addr add 10.201.0.1/30 dev xvh", "ip link set xvh up",
              f"ip -n {NS} addr add 10.201.0.2/30 dev xvc", f"ip -n {NS} link set xvc up",
              f"ip -n {NS} link set lo up", f"ip -n {NS} route add default via 10.201.0.1"]:
        sh(c, True)
    # 经 CDN 的腿要从 netns 出公网（客户端 → Cloudflare 边缘）。FORWARD 默认策略常是 DROP
    # （装了 Docker 就是），不加这三条时 CDN 节点全部「无效」。只在运行期存在，ns_down 删除，不持久化。
    for r in NAT_RULES: sh(f"iptables {r.replace('-X', '-I', 1)}", True)
    # 宿主 resolv.conf 指向 127.0.0.53（systemd-resolved），netns 里访问不到，CDN 域名解析失败。
    # ip netns exec 会把 /etc/netns/<ns>/resolv.conf 绑定挂载到 /etc/resolv.conf。
    os.makedirs(f"/etc/netns/{NS}", exist_ok=True)
    open(f"/etc/netns/{NS}/resolv.conf", "w").write("nameserver 1.1.1.1\nnameserver 8.8.8.8\n")
    shape("xvh", None, RTT/2, LOSS, DOWN)     # 服务端→客户端 = 下行
    shape("xvc", NS, RTT/2, 0, UP)            # 客户端→服务端 = 上行

NAT_RULES = ["-X FORWARD -s 10.201.0.0/30 -j ACCEPT", "-X FORWARD -d 10.201.0.0/30 -j ACCEPT",
             "-t nat -X POSTROUTING -s 10.201.0.0/30 ! -d 10.201.0.0/30 -j MASQUERADE"]

def ns_down():
    for r in NAT_RULES:
        while sh(f"iptables {r.replace('-X', '-D', 1)}").returncode == 0: pass
    sh(f"ip netns del {NS}"); sh("ip link del xvh"); sh(f"rm -rf /etc/netns/{NS}")

def kill_clients():
    me = os.getpid()
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me: continue
        try: argv = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
        except OSError: continue
        if argv and (argv[0].endswith(b"xray") or argv[0].endswith(b"sing-box")) and any(a.endswith((b"xb_client.json", b"xb_sbclient.json")) for a in argv):
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
    sb_in, sb_out, sb_rules = [], [], []
    for i, v in enumerate(variants):
        if v.get("core") == "sing-box":
            o = sb_hy2(v["link"], "10.201.0.1")
            for k, val in v.get("set", {}).items(): o[k] = val
            for k in v.get("unset", []): o.pop(k, None)
            o["tag"] = f"o{i}"; sb_out.append(o)
            sb_in.append({"type": "socks", "tag": f"i{i}", "listen": "127.0.0.1", "listen_port": 13100 + i})
            sb_rules.append({"inbound": [f"i{i}"], "outbound": f"o{i}"})
            continue
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
    if outs:
        t = sh(f"xray run -test -c {cfg}")
        if t.returncode: print("CONFIG FAIL:", (t.stdout + t.stderr)[-500:]); sys.exit(1)
    procs = []
    if outs:
        procs.append(subprocess.Popen(f"ip netns exec {NS} xray run -c {cfg}", shell=True, stdout=open(f"{S}/xb.log", "w"), stderr=subprocess.STDOUT))
    if sb_out:
        sbcfg = f"{S}/xb_sbclient.json"
        json.dump({"log": {"level": "warn"}, "inbounds": sb_in, "outbounds": sb_out + [{"type": "direct", "tag": "direct"}],
                   "route": {"rules": sb_rules, "final": "direct"}}, open(sbcfg, "w"), indent=1)
        t2 = sh(f"{SB_BIN} check -c {sbcfg}")
        if t2.returncode: print("SING-BOX CONFIG FAIL:", t2.stderr[-500:]); sys.exit(1)
        procs.append(subprocess.Popen(f"ip netns exec {NS} {SB_BIN} run -c {sbcfg}", shell=True, stdout=open(f"{S}/xb_sb.log", "w"), stderr=subprocess.STDOUT))
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
            # PING_DURING=1：上传期间在客户端侧并行 ping 服务端，量「同一条线路上的其他流量」被挤成什么样
            pg = subprocess.Popen(f"ip netns exec {NS} ping -i 0.1 -q -w 60 10.201.0.1", shell=True, stdout=subprocess.PIPE, text=True) if os.environ.get("PING_DURING") else None
            o = c(port, f"-w '%{{http_code}} %{{size_upload}} %{{speed_upload}}' --max-time 120 -X POST --data-binary @{UPFILE} https://speed.cloudflare.com/__up")
            if pg:
                sh(f"pkill -INT -P {pg.pid}"); out = pg.communicate(timeout=10)[0]
                lm = re.search(r"([\d.]+)% packet loss", out); am = re.search(r"= [\d.]+/([\d.]+)/([\d.]+)/", out)
                v.setdefault("_ping", []).append((float(lm.group(1)) if lm else None, float(am.group(1)) if am else None, float(am.group(2)) if am else None))
            if len(o)==3 and o[0]=="200" and int(o[1])>=UP_BYTES: ul.append(float(o[2])*8/1e6)
            else: bu += 1; 
            if len(o)>=1 and o[0]=="429": print("   ! speed.cloudflare 429 限流")
        f = lambda a: (f"{statistics.median(a):.0f}", f"{min(a):.0f}~{max(a):.0f}") if a else ("—", "")
        d, u = f(dl), f(ul)
        extra = ""
        if v.get("_ping"):
            ls = [x[0] for x in v["_ping"] if x[0] is not None]; av = [x[1] for x in v["_ping"] if x[1] is not None]; mx = [x[2] for x in v["_ping"] if x[2] is not None]
            extra = f"   上传时并行 ping: 丢包 {statistics.median(ls):.1f}%  平均 {statistics.median(av):.0f}ms  最大 {max(mx):.0f}ms" if ls and av else "   ping 无数据"
        print(f"{v['name']:<38}{d[0]:>8}{d[1]:>12}{u[0]:>9}{u[1]:>12}{f'{bd}/{bu}':>9}{extra}"); sys.stdout.flush()
    for pr in procs: pr.terminate()
finally:
    kill_clients(); ns_down()

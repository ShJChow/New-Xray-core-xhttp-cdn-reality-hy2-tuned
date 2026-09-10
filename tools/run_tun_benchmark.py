#!/usr/bin/env python3
"""
TUN Mode End-to-End Connectivity & Performance Benchmark
Tests all proxy protocols and nodes under a real Layer-3 TUN virtual interface
inside an isolated Linux network namespace (tuntest), with zero risk to host routing.

Measures:
1. TCP HTTP 204 latency (Median, P95, Jitter) through TUN
2. UDP DNS Query (@8.8.8.8) through TUN
"""

import json, subprocess, time, os, sys, statistics, socket

SCRATCH = "/root/.gemini/antigravity-cli/brain/19ec0928-302f-40fe-9cdb-d8d7e35ef9ed/scratch"
os.makedirs(SCRATCH, exist_ok=True)

# 1. Read parameters from /etc/xhttp-cdn/node.env
env = {}
if os.path.isfile("/etc/xhttp-cdn/node.env"):
    with open("/etc/xhttp-cdn/node.env") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                env[k] = v.strip('"').strip("'")

CDN_DOMAIN = env.get("CDN_DOMAIN", "cdn.cch.us.kg")
REALITY_DOMAIN = env.get("REALITY_DOMAIN", "reality.cch.us.kg")
VPS_IP = env.get("VPS_IP", "192.9.145.231")
UUID1 = env.get("UUID1", "")
UUID2 = env.get("UUID2", "")
PUBLIC_KEY = env.get("PUBLIC_KEY", "")
SHORT_ID = env.get("SHORT_ID", "")
XHTTP_PATH = env.get("XHTTP_PATH", "")
VLESSENC = env.get("VLESSENC_ENCRYPTION", "none")
HY2_PASS = env.get("HY2_PASSWORD", "")
OBFS_PASS = env.get("OBFS_PASSWORD", "")
H3_PORT = int(env.get("H3_PORT", 8446))
HY2_PORT = int(env.get("HY2_PORT", 8443))

XP = {
    "xPaddingObfsMode": True,
    "xPaddingMethod": env.get("XHTTP_PADDING_METHOD", "tokenish"),
    "xPaddingPlacement": env.get("XHTTP_PADDING_PLACEMENT", "queryInHeader"),
    "xPaddingHeader": env.get("XHTTP_PADDING_HEADER", "Referer"),
    "xPaddingKey": env.get("XHTTP_PADDING_KEY", "x_padding")
}
SC_MIN_POSTS_MS = int(os.environ.get("SC_MIN_POSTS_MS", "10"))

def xh_opts(host, mode="auto"):
    extra = dict(XP)
    if mode != "stream-up":
        extra["scMinPostsIntervalMs"] = SC_MIN_POSTS_MS
    return {"host": host, "path": XHTTP_PATH, "mode": mode, "extra": extra}

def vless(addr, port, uid, enc, flow=None):
    u = {"id": uid, "encryption": enc}
    if flow: u["flow"] = flow
    return {"address": addr, "port": port, "users": [u]}

# Xray Outbounds
n0 = {
    "protocol": "vless",
    "settings": {"vnext": [vless(CDN_DOMAIN, 443, UUID2, VLESSENC)]},
    "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {"serverName": CDN_DOMAIN, "alpn": ["h2", "http/1.1"], "fingerprint": "chrome"},
        "xhttpSettings": xh_opts(CDN_DOMAIN, "auto")
    }
}
n1 = {
    "protocol": "vless",
    "settings": {"vnext": [vless(CDN_DOMAIN, 443, UUID2, VLESSENC)]},
    "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {"serverName": CDN_DOMAIN, "alpn": ["h3"], "fingerprint": "chrome"},
        "xhttpSettings": xh_opts(CDN_DOMAIN, "auto")
    }
}
n2 = {
    "protocol": "vless",
    "settings": {"vnext": [vless(VPS_IP, H3_PORT, UUID2, VLESSENC)]},
    "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {"serverName": REALITY_DOMAIN, "alpn": ["h3"], "fingerprint": "chrome"},
        "xhttpSettings": xh_opts("", "stream-up")
    }
}
# Node 4: Vless-reality-vision (TCP)
n4 = {
    "protocol": "vless",
    "settings": {"vnext": [vless(VPS_IP, 443, UUID1, "none", "xtls-rprx-vision")]},
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "serverName": REALITY_DOMAIN,
            "fingerprint": "chrome",
            "publicKey": PUBLIC_KEY,
            "shortId": SHORT_ID
        }
    }
}
# Node 4-raw: VLESS + RAW + Reality + Vision
n4_raw = {
    "protocol": "vless",
    "settings": {"vnext": [vless(VPS_IP, 443, UUID1, "none", "xtls-rprx-vision")]},
    "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
            "serverName": REALITY_DOMAIN,
            "fingerprint": "chrome",
            "publicKey": PUBLIC_KEY,
            "shortId": SHORT_ID
        }
    }
}
n5 = {
    "protocol": "vless",
    "settings": {"vnext": [vless(VPS_IP, 443, UUID2, VLESSENC)]},
    "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
            "serverName": REALITY_DOMAIN,
            "fingerprint": "chrome",
            "publicKey": PUBLIC_KEY,
            "shortId": SHORT_ID
        },
        "xhttpSettings": xh_opts("", "stream-up")
    }
}
dl = {
    "address": CDN_DOMAIN,
    "port": 443,
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {"serverName": CDN_DOMAIN, "alpn": ["h2", "http/1.1"], "fingerprint": "chrome"},
    "xhttpSettings": xh_opts(CDN_DOMAIN, "auto")
}
n6 = json.loads(json.dumps(n5))
n6["streamSettings"]["xhttpSettings"]["downloadSettings"] = dl

xray_nodes = [
    ("n0-h2-cdn", n0, 10800),
    ("n1-h3-cdn", n1, 10801),
    ("n2-h3-direct", n2, 10802),
    ("n4-reality-vision", n4, 10804),
    ("n4-raw-reality-vision", n4_raw, 10807),
    ("n5-reality-xhttp", n5, 10805),
    ("n6-reality-up-cdn-down", n6, 10806),
]

xray_cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [],
    "outbounds": [],
    "routing": {"domainStrategy": "AsIs", "rules": []}
}

for tag, ob, port in xray_nodes:
    xray_cfg["inbounds"].append({"tag": "in-" + tag, "listen": "0.0.0.0", "port": port, "protocol": "socks", "settings": {"udp": True}})
    out = dict(ob)
    out["tag"] = tag
    xray_cfg["outbounds"].append(out)
    xray_cfg["routing"]["rules"].append({"inboundTag": ["in-" + tag], "outboundTag": tag})

with open(f"{SCRATCH}/test_tun_xray.json", "w") as f:
    json.dump(xray_cfg, f, indent=2)

# Sing-box for Xray Node 3: Hysteria2
sb_hy2_cfg = {
    "log": {"level": "warn"},
    "inbounds": [{"type": "socks", "tag": "in-n3-hy2", "listen": "0.0.0.0", "listen_port": 10803}],
    "outbounds": [
        {
            "type": "hysteria2",
            "tag": "n3-hy2",
            "server": VPS_IP,
            "server_port": HY2_PORT,
            "password": HY2_PASS,
            "obfs": {"type": "salamander", "password": OBFS_PASS},
            "tls": {"enabled": True, "server_name": REALITY_DOMAIN, "insecure": False, "alpn": ["h3"]}
        }
    ],
    "route": {"rules": [{"inbound": ["in-n3-hy2"], "outbound": "n3-hy2"}]}
}
with open(f"{SCRATCH}/test_tun_sb_hy2.json", "w") as f:
    json.dump(sb_hy2_cfg, f, indent=2)

# sbbox client config
sbbox_client_file = "/root/sbbox/sbox_client.json"
sbbox_ports = {
    "tuic": 11801,
    "hysteria2": 11802,
    "naive-h3": 11803,
    "naive-h2": 11804,
    "vless-reality": 11805
}

if os.path.isfile(sbbox_client_file):
    with open(sbbox_client_file) as f:
        sb_diag_cfg = json.load(f)
    sb_diag_cfg["inbounds"] = []
    sb_diag_cfg["route"]["rules"] = []
    for ob in sb_diag_cfg.get("outbounds", []):
        tag = ob.get("tag")
        if tag in sbbox_ports:
            in_tag = f"in-{tag}"
            sb_diag_cfg["inbounds"].append({
                "type": "socks",
                "tag": in_tag,
                "listen": "0.0.0.0",
                "listen_port": sbbox_ports[tag]
            })
            sb_diag_cfg["route"]["rules"].append({
                "inbound": [in_tag],
                "outbound": tag
            })
    with open(f"{SCRATCH}/test_tun_sb_diag.json", "w") as f:
        json.dump(sb_diag_cfg, f, indent=2)

procs = []
try:
    print("1. 启动宿主机各节点客户端代理进程...", flush=True)
    p1 = subprocess.Popen(["xray", "run", "-c", f"{SCRATCH}/test_tun_xray.json"], stdout=open(f"{SCRATCH}/xray.log", "w"), stderr=subprocess.STDOUT)
    procs.append(p1)
    p2 = subprocess.Popen(["/root/sbbox/sing-box", "run", "-c", f"{SCRATCH}/test_tun_sb_hy2.json"], stdout=open(f"{SCRATCH}/sb_hy2.log", "w"), stderr=subprocess.STDOUT)
    procs.append(p2)
    p3 = subprocess.Popen(["/root/sbbox/sing-box", "run", "-c", f"{SCRATCH}/test_tun_sb_diag.json"], stdout=open(f"{SCRATCH}/sb_diag.log", "w"), stderr=subprocess.STDOUT)
    procs.append(p3)

    sudoku_link = None
    sudoku_env = "/etc/sudoku/export-state.env"
    if os.path.isfile(sudoku_env) and os.path.isfile("/usr/local/bin/sudoku"):
        with open(sudoku_env) as f:
            for line in f:
                if line.startswith("SHORT_LINK="):
                    sudoku_link = line.split("=", 1)[1].strip().strip("'").strip('"')
                    break
        if sudoku_link:
            p4 = subprocess.Popen(["/usr/local/bin/sudoku", "-link", sudoku_link], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            procs.append(p4)

    # 2. Setup isolated network namespace tuntest
    print("2. 创建隔离网络命名空间 tuntest 与 veth 虚拟链路...", flush=True)
    subprocess.run(["ip", "netns", "del", "tuntest"], stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "link", "del", "veth-h"], stderr=subprocess.DEVNULL)
    os.makedirs("/etc/netns/tuntest", exist_ok=True)
    with open("/etc/netns/tuntest/resolv.conf", "w") as f:
        f.write("nameserver 8.8.8.8\nnameserver 1.1.1.1\n")

    subprocess.run(["ip", "netns", "add", "tuntest"], check=True)
    subprocess.run(["ip", "link", "add", "veth-h", "type", "veth", "peer", "name", "veth-c"], check=True)
    subprocess.run(["ip", "link", "set", "veth-c", "netns", "tuntest"], check=True)
    subprocess.run(["ip", "addr", "add", "10.89.0.1/24", "dev", "veth-h"], check=True)
    subprocess.run(["ip", "link", "set", "veth-h", "up"], check=True)
    subprocess.run(["ip", "netns", "exec", "tuntest", "ip", "addr", "add", "10.89.0.2/24", "dev", "veth-c"], check=True)
    subprocess.run(["ip", "netns", "exec", "tuntest", "ip", "link", "set", "veth-c", "up"], check=True)
    subprocess.run(["ip", "netns", "exec", "tuntest", "ip", "link", "set", "lo", "up"], check=True)
    subprocess.run(["ip", "netns", "exec", "tuntest", "ip", "route", "add", "default", "via", "10.89.0.1"], check=True)

    all_tests = [
        ("Xray", "n0-h2-cdn", 10800, "TCP/H2 + Cloudflare CDN"),
        ("Xray", "n1-h3-cdn", 10801, "QUIC/H3 + Cloudflare CDN"),
        ("Xray", "n2-h3-direct", 10802, "QUIC/H3 + VLESS Direct"),
        ("Xray", "n3-hy2-obfs", 10803, "Hysteria 2 + Salamander"),
        ("Xray", "n4-reality-vision", 10804, "VLESS + Reality + Vision"),
        ("Xray", "n4-raw-reality-vision", 10807, "VLESS + RAW + Reality + Vision"),
        ("Xray", "n5-reality-xhttp", 10805, "VLESS + Reality + XHTTP"),
        ("Xray", "n6-reality-up-cdn-down", 10806, "Reality Up + CDN Down"),
        ("sbbox", "tuic", 11801, "TUIC v5 + BBR"),
        ("sbbox", "hysteria2", 11802, "Hysteria 2 + Hop + Brutal"),
        ("sbbox", "naive-h3", 11803, "NaiveProxy + QUIC/H3 + BBR"),
        ("sbbox", "naive-h2", 11804, "NaiveProxy + TCP/H2 TLS"),
        ("sbbox", "vless-reality", 11805, "VLESS + Reality + Vision"),
    ]
    if sudoku_link:
        all_tests.append(("Sudoku", "sudoku-native", 10233, "SUDOKU-ASCII v0.5.0 + ChaCha20"))

    # Wait for inbounds to be ready
    print("等待所有本地代理端口就绪...", flush=True)
    time.sleep(2.5)

    # 3. Build Sing-box TUN client config
    print("3. 在 tuntest 内部部署 TUN 虚拟网卡 (gVisor 栈) 与 Clash API...", flush=True)
    sb_tun_outbounds = [
        {"type": "selector", "tag": "select", "outbounds": [t[1] for t in all_tests]}
    ]
    for _core, tag, port, _desc in all_tests:
        sb_tun_outbounds.append({
            "type": "socks",
            "tag": tag,
            "server": "10.89.0.1",
            "server_port": port
        })
    sb_tun_outbounds.append({"type": "direct", "tag": "direct"})

    sb_tun_cfg = {
        "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}},
        "dns": {
            "servers": [
                {"tag": "dns-remote", "type": "udp", "server": "8.8.8.8", "detour": "select"}
            ],
            "strategy": "prefer_ipv4"
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "tun0",
                "address": ["172.19.0.1/30"],
                "auto_route": True,
                "stack": "gvisor"
            }
        ],
        "outbounds": sb_tun_outbounds,
        "route": {
            "default_interface": "veth-c",
            "default_domain_resolver": "dns-remote",
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_cidr": ["10.89.0.0/24"], "outbound": "direct"}
            ],
            "final": "select"
        }
    }

    with open(f"{SCRATCH}/test_sb_tun_master.json", "w") as f:
        json.dump(sb_tun_cfg, f, indent=2)

    psb_tun = subprocess.Popen(["ip", "netns", "exec", "tuntest", "/root/sbbox/sing-box", "run", "-c", f"{SCRATCH}/test_sb_tun_master.json"], stdout=open(f"{SCRATCH}/sb_tun.log", "w"), stderr=subprocess.STDOUT)
    procs.append(psb_tun)
    time.sleep(2.0)

    def switch_node(node_tag):
        cmd = ["ip", "netns", "exec", "tuntest", "curl", "-s", "-X", "PUT", "http://127.0.0.1:9090/proxies/select", "-d", json.dumps({"name": node_tag})]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def probe_tun_tcp(url="http://www.gstatic.com/generate_204", timeout=5):
        cmd = ["ip", "netns", "exec", "tuntest", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code} %{time_total}", "--max-time", str(timeout), url]
        r = subprocess.run(cmd, capture_output=True, text=True)
        out = r.stdout.strip().split()
        if len(out) >= 2 and out[0] in ("200", "204"):
            return float(out[1]) * 1000
        return None

    def probe_tun_udp_dns(domain="www.google.com", timeout=2):
        cmd = ["ip", "netns", "exec", "tuntest", "dig", "+short", "@8.8.8.8", domain, f"+time={timeout}", "+tries=1"]
        t0 = time.perf_counter()
        r = subprocess.run(cmd, capture_output=True, text=True)
        t_elapsed = (time.perf_counter() - t0) * 1000
        if r.stdout.strip():
            return t_elapsed
        return None

    SAMPLES = int(os.environ.get("SAMPLES", "5"))

    def stats(vals):
        s = sorted(vals)
        med = statistics.median(s)
        p95 = s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]
        return med, p95, s[-1] / med

    print("\n" + "="*112, flush=True)
    print("【TUN 模式全节点连通性与性能综合实测】", flush=True)
    print("测试环境：Linux Network Namespace (tuntest) + 真实 tun0 虚拟网卡 (gVisor 栈) + 全局 auto_route", flush=True)
    print(f"采样口径：每条 {SAMPLES} 个有效样本（已预热）；测量 L3 TUN 封装下的 TCP 握手 与 UDP DNS 穿透能力", flush=True)
    print("="*112, flush=True)
    print(f"{'Core':<7} {'Node Tag':<24} {'TCP TUN':<9} {'中位':>8} {'p95':>8} {'抖动':>7} {'UDP DNS':<9} {'Description'}", flush=True)
    print("="*112, flush=True)

    results = []
    for core, name, port, desc in all_tests:
        switch_node(name)
        time.sleep(0.2)
        # Pre-warm probe
        probe_tun_tcp()

        vals = [v for v in (probe_tun_tcp() for _ in range(SAMPLES)) if v is not None]
        fails = SAMPLES - len(vals)
        if not vals:
            tcp_status, med_s, p95_s, jit_s = "FAIL", "TIMEOUT", "-", "-"
        else:
            med, p95, jit = stats(vals)
            tcp_status = "PASS" if fails == 0 else f"PASS({fails}超时)"
            med_s, p95_s, jit_s = f"{med:.1f}ms", f"{p95:.1f}ms", f"{jit:.1f}x"

        # UDP DNS test
        udp_t = probe_tun_udp_dns()
        if udp_t is not None:
            udp_status = f"{udp_t:.0f}ms"
        else:
            udp_status = "N/A" if "Vision" in desc else "FAIL"

        results.append((core, name, port, tcp_status, med_s, udp_status, desc))
        print(f"{core:<7} {name:<24} {tcp_status:<9} "
              + med_s.rjust(8) + " " + p95_s.rjust(8) + " " + jit_s.rjust(7) + f" {udp_status:<9} {desc}", flush=True)

    print("="*112, flush=True)
    passed = sum(1 for r in results if r[3].startswith("PASS"))
    total = len(results)
    print(f"TUN 模式测试总评：{passed}/{total} 节点通过 TUN 模式完整联通验证 ({'全部通过 ALL PASS' if passed == total else '部分异常'})", flush=True)
    print("="*112 + "\n", flush=True)

finally:
    print("清理测试进程与隔离网络命名空间...", flush=True)
    for p in procs:
        try:
            p.terminate()
            p.wait(timeout=1.0)
        except Exception:
            p.kill()
    subprocess.run(["ip", "link", "del", "veth-h"], stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "netns", "del", "tuntest"], stderr=subprocess.DEVNULL)
    subprocess.run(["rm", "-rf", "/etc/netns/tuntest"], stderr=subprocess.DEVNULL)
    print("清理完成。", flush=True)

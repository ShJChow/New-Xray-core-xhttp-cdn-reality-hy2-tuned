#!/usr/bin/env python3
"""用 Xray 内核按「订阅链接」原样建客户端，逐节点测兼容性。
用法: xray_compat_test.py <订阅目录>   例: xray_compat_test.py /usr/local/nginx/html/sub/<token>/
模拟 v2rayN(Xray core) 导入订阅：参数只从链接里取，不读服务端配置。"""
import json, subprocess, sys, time, statistics, urllib.parse as up, os, tempfile, shutil, atexit
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_td = tempfile.TemporaryDirectory(prefix="xc_test_")
atexit.register(lambda: _td.cleanup() if os.path.exists(_td.name) else None)
S = os.environ.get("BENCH_TMP", _td.name)
SUB = sys.argv[1]; N_DL = int(os.environ.get("N_DL", "2"))
SOURCES = [("xray-v2rayn", f"{SUB}/v2rayn-raw.txt"), ("xray-tun", f"{SUB}/v2rayn-tun-raw.txt"), ("sbbox", "/root/sbbox/nodes.txt")]
URLS = ["https://speedtest.fremont.linode.com/100MB-fremont.bin", "https://sjo-ca-us-ping.vultr.com/vultr.com.100MB.bin"]
NEED = 52428800

from xlinks import vless, hy2, XRAY_PROTOS  # 解析逻辑与 xray_rtt_bench.py 共用

nodes = []
for label, f in SOURCES:
    try: lines = [l.strip() for l in open(f) if l.strip()]
    except OSError: continue
    for l in lines:
        scheme = l.split("://")[0].lower(); name = up.unquote(l.split("#")[-1]) if "#" in l else scheme
        u = up.urlsplit(l); qs = up.parse_qs(u.query)
        node = {"src": label, "name": name, "scheme": scheme}
        if scheme not in XRAY_PROTOS:
            node["status"] = "Xray 不支持该协议"; nodes.append(node); continue
        try: node["ob"] = vless(u, qs) if scheme == "vless" else hy2(u, qs)
        except Exception as e: node["status"] = f"链接解析失败: {e}"
        nodes.append(node)

testable = [n for n in nodes if "ob" in n]
# 逐个单独校验，定位是哪条节点的配置 Xray 不接受
for i, n in enumerate(testable):
    cfg = {"log": {"loglevel": "none"}, "outbounds": [dict(n["ob"], tag="t")]}
    p = f"{S}/xc_one.json"; json.dump(cfg, open(p, "w"))
    r = subprocess.run(["xray", "run", "-test", "-c", p], capture_output=True, text=True)
    if r.returncode: n["status"] = "Xray 拒绝配置: " + (r.stdout + r.stderr).strip().split("\n")[-1][-160:]
ok = [n for n in testable if "status" not in n]
inb, outs, rules = [], [], []
for i, n in enumerate(ok):
    tag = f"n{i}"; n["port"] = 13000 + i
    inb.append({"listen": "127.0.0.1", "port": n["port"], "protocol": "socks", "settings": {"udp": True}, "tag": f"in{i}"})
    outs.append(dict(n["ob"], tag=tag)); rules.append({"type": "field", "inboundTag": [f"in{i}"], "outboundTag": tag})
cfg = {"log": {"loglevel": "warning"}, "inbounds": inb, "outbounds": outs, "routing": {"rules": rules}}
json.dump(cfg, open(f"{S}/xc_all.json", "w"), indent=1)
proc = subprocess.Popen(["xray", "run", "-c", f"{S}/xc_all.json"], stdout=open(f"{S}/xc.log", "w"), stderr=subprocess.STDOUT)
try:
    time.sleep(3)
    def curl(port, args):
        return subprocess.run(f"curl -s -o /dev/null --socks5-hostname 127.0.0.1:{port} {args}", shell=True, capture_output=True, text=True).stdout.split()
    for n in ok:
        curl(n["port"], "--max-time 10 http://www.gstatic.com/generate_204")   # 预热
        lat = [float(o[1])*1000 for o in (curl(n["port"], "-w '%{http_code} %{time_starttransfer}' --max-time 10 http://www.gstatic.com/generate_204") for _ in range(8)) if len(o)==2 and o[0]=="204"]
        bw, bad = [], 0
        for k in range(N_DL):
            o = curl(n["port"], f"-w '%{{http_code}} %{{size_download}} %{{speed_download}}' --max-time 60 -r 0-{NEED-1} {URLS[k%2]}")
            if len(o)==3 and o[0] in ("200","206") and int(o[1])>=NEED: bw.append(float(o[2])*8/1e6)
            else: bad += 1
        # UDP：经 socks UDP 发 DNS 查询验证 UDP 转发
        n["lat"] = statistics.median(lat) if lat else None
        n["bw"] = statistics.median(bw) if bw else None; n["bad"] = bad
        n["status"] = "PASS" if lat and bw else ("仅握手通/下载失败" if lat else "FAIL")
finally:
    proc.terminate(); proc.wait(timeout=5)

print(f"\n{'来源':<12}{'节点':<32}{'协议':<11}{'结果':<14}{'首字节':>8}{'吞吐Mbps':>10}")
for n in nodes:
    lat = f"{n['lat']:.1f}ms" if n.get("lat") else "—"; bw = f"{n['bw']:.0f}" if n.get("bw") else "—"
    print(f"{n['src']:<12}{n['name'][:31]:<32}{n['scheme']:<11}{n['status'][:60]:<14}{lat:>8}{bw:>10}")
json.dump([{k:v for k,v in n.items() if k!="ob"} for n in nodes], open(f"{S}/xc_result.json","w"), ensure_ascii=False, indent=1)

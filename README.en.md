# xray-xhttp

**Languages:** [简体中文](./README.md) · **English** · [فارسی](./README.fa.md)

**Tested on Oracle 4 OCPU / 24 GB, Ubuntu 26.04 and Debian 13 (recommended).**

A one-command deployment of **XHTTP + CDN** built on Xray-core, with **xpadding,
Hysteria2 obfuscation and all 7 nodes enabled by default** (ECH is off by default;
set `CDN_ECH=y` to enable it). Kernel-level network tuning (BBR + fq, buffers, file
descriptors) is applied automatically at install time, and a resident management
command `xh` is installed alongside.

Works with V2rayN / Shadowrocket / Mihomo / onexray, over both IPv4 and IPv6.

> ⚠️ **Read the [Disclaimer](#disclaimer) before deploying** — legal risk (especially
> for users in mainland China) and an honest note on why nothing here is guaranteed
> to stay undetected or keep working.

> **Background reading**: XHTTP, split upload/download, and why it resists censorship —
> <https://habr.com/en/articles/990208/>
>
> **Note**: this setup uses VLESS Encryption. Your client (V2rayN, Mihomo) must be new
> enough to support `vlessenc` and `xhttp`.
>
> **Note**: V2rayN v7.19.5+ can be unstable in TUN mode; enable the legacy TUN-protection
> option ([PR #9005](https://github.com/2dust/v2rayN/pull/9005)).

`xh tuning on` runs **automatically at the end of installation** (kernel tuning,
best-effort; skip it with `FEATURE_AUTO_TUNING=false`, roll it back with `xh tuning off`).

> **Note on documentation**: the `docs/` directory is Chinese-only. This file is a
> translation of the [Chinese README](./README.md), which remains the source of truth.

---

## Features

| Capability | Details |
|---|---|
| Node set (v4.7.4) | 7 nodes by default, all served by a single Xray core: 4 over QUIC/h3 (including Hysteria2 obfs and the newer h3-cdn) plus 3 TCP fallbacks. No separate hysteria binary needed |
| xpadding | On by default. `xPaddingObfsMode` plus a custom header and parameter name, to defeat XHTTP fingerprinting on the CDN side |
| ECH | **Off by default**. Encrypts the SNI in the TLS handshake; enable it in Cloudflare Edge Certificates first, then set `CDN_ECH=y` |
| VLESS Encryption | On by default (ML-KEM-768), stops the CDN from decrypting traffic in the middle |
| **Full tuning** | BBR + fq, TFO, MTU probing, 1048576 file descriptors, Xray `sockopt` and `policy.bufferSize`, nginx gRPC long-connection timeouts |
| **Adapts to the machine** | Three tiers by RAM (≥16G / ≥4G / <4G) scaling buffers and queues; ARM64 sets `bufferSize` explicitly (the default is only 4 KB) |
| flow / Vision | Node 1 uses `xtls-rprx-vision` (the only node that can use Splice); the rest are XHTTP and cannot carry a flow by protocol. `VISION_UDP443=1` switches to `-udp443` |
| **`xh` command** | Status / node details / subscription / logs / core updates / tuning toggle / keepalive / uninstall |
| **Non-interactive** | Driven by environment variables; `AUTO=1` reinstalls with zero prompts |
| **Self-healing** | cron health check every 5 minutes plus start-on-boot |
| **Automatic core updates** | Weekly Xray-core update, with automatic rollback if the config self-test fails |
| Extensions | `add-quic-h3` (3 XHTTP-over-h3 nodes) / `add-quic` (Hysteria2) / different CDNs for upload and download / IPv4 up, IPv6 down |

---

## Node list

Since v4.7.4 the installer emits **the 7 nodes below**, all served by a single Xray core —
Hysteria2 now uses Xray's native inbound (v26.3.27+), so no separate hysteria binary is
required.

**Node order**: nodes 1 and 2 go through the CDN (over TCP/h2 and UDP/h3 respectively),
nodes 3 and 4 are direct XHTTP (a QUIC node and its TCP twin), node 5 is Hysteria2, and
the last two are direct TCP fallbacks. Mihomo's proxy groups use `include-all: true`, so
this ordering carries straight through.

Since v4.6.0 the Mihomo subscription ships an **`自动选择` (url-test)** group, used as the
default entry of `节点选择`: it routes by measured latency and switches away automatically
when a node degrades or fails, so you do not have to diagnose it by hand. You can still
pick a specific node manually in `节点选择`.

v4.7.0 added the **`直连择优`** group (called `直连回落` before v4.7.3, where it was a
fallback group): it contains only the 4 direct nodes and picks by measured latency. The
`h2-tcp-direct` node exists precisely for this — it is the TCP twin of `h3-direct` (same
UUID, same path, same decryption, only the transport differs), where previously the only
direct TCP fallback was Reality.

Why url-test replaced fallback: a fallback group only asks whether a node is *up*, not
whether it is *fast*. At peak hours, when `h3-direct` is stuck at 200 ms with heavy loss,
it is still "healthy", stays selected, and the nodes behind it never get a turn — which is
exactly the moment you most want to move off it. url-test switches away under that kind of
degradation, and it still switches when UDP is fully blocked (h3 simply fails its latency
test), so it is a superset of fallback behaviour.

How it divides with `自动选择`: that group is `include-all` (it contains the CDN nodes too),
while this one contains only direct nodes, for when you explicitly want to stay direct.
**Note** that url-test measures handshake latency — not throughput and not loss rate — so
Hysteria2's throughput advantage under heavy loss does not show up, and during bad-loss
periods you may still want to switch to it manually.

Node 1 goes through the CDN and its server is a domain name, so **in V2rayN TUN mode you
must add the CDN domain to the direct/bypass list** or the connection loops back on itself.
Nodes 2–5 connect to the bare IP and only need a direct route for the VPS IP. The installer
writes `~/client-config-v2rayn-tun.txt` with that list filled in for your machine.

Node names are plain ASCII plus a suffix (`<host>` = `NODE_TAG`, falling back to
`hostname -s`; `vps` is used when that is empty or `localhost`). To use full
airport-style names instead, see [Custom node names](#custom-node-names).

| # | Node name | Path | Transport |
|---|---|---|---|
| 1 | `Vless-xhttp-tls-cdn-<host>` | Via CDN, **TCP 443** | XHTTP + TLS, alpn h2 + http/1.1 (v4.6.0 switched this back from h3 to TCP; the `UDP` in the name is a leftover from before that change, kept so existing clients do not lose their node selection) |
| 2 | `Vless-xhttp-h3-cdn-<host>` | Via CDN, **UDP 443** | XHTTP + TLS, alpn h3 only (added in v4.7.4 as node 1's QUIC twin; no server-side change) |
| 3 | `Vless-xhttp-h3-direct-<host>` | Direct to VPS, **UDP 8444** | XHTTP + TLS, alpn h3, `mode=stream-up` (v4.7.13, ~50 ms faster than auto) |
| 4 | `Vless-xhttp-h2-tcp-direct-<host>` | Direct to VPS, **TCP 8445** | XHTTP + TLS, alpn h2 + http/1.1, `mode=stream-up` (v4.7.13, ~50 ms faster than auto); added in v4.7.0 as node 3's TCP twin. Recommended on mobile |
| 5 | `Hysteria2-obfs-<host>` | Direct to VPS, **UDP 8443** | Hysteria2 + Salamander obfuscation |
| 6 | `Vless-reality-vision-<host>` | Direct to VPS, TCP 443 | Reality + Vision; the fallback when UDP is blocked |
| 7 | `Vless-xhttp-reality-<host>` | Direct to VPS, TCP 443 | XHTTP + Reality, upload and download together |
| 8 | `Vless-xhttp-reality-up-cdn-down-<host>` | Upload Reality direct 443, Download TLS CDN 443 | XHTTP Split-Routing (Uplink via Reality direct, Downlink via CDN) |

Nodes 3 and 5 are bare UDP to the VPS and node 4 is TCP 8445, so all three need to be
opened in your **cloud provider's security group** (UDP 8444, UDP 8443, TCP 8445). Node 2
goes through the CDN over Cloudflare's UDP 443 and needs **no** port opened at all — that
layer sits outside the machine, where the script can neither see nor change anything. If
the Xray core is older than 26.6.1, nodes 2 and 4 are disabled automatically. Node 4's port
can be set with `H2_PORT=<port>`, or turned off entirely with `FEATURE_H2_DIRECT=false`.

> **Known limitation of node 2** (downgraded to opt-in in v4.0.3, back on by default in
> v4.2.0): XHTTP over h3 has two upstream issues that are unfixed and closed as not
> planned — [#4391](https://github.com/XTLS/Xray-core/issues/4391) (`alpn=h3` silently
> ignored, falling back to TCP) and [#5849](https://github.com/XTLS/Xray-core/issues/5849)
> (h3 not working for a long stretch). The port is now a separate **8444**, so falling
> back to TCP no longer contends with Reality on 443; the worst case is that this node
> alone fails to connect. Turn it off with `FEATURE_H3_DIRECT=false` if you do not need it.

### Upgrading from older versions

Machines that previously ran `add-quic.sh` (the standalone hysteria binary) or
`add-quic-h3.sh` are **migrated automatically** when you re-run the installer: the old
components are stopped, their configs are backed up to `/var/backups/xray-xhttp-migrate/`,
the quic listener blocks are removed from nginx, and the UDP ports are handed over to
Xray's native implementation.

The old standalone hysteria had **no Salamander obfuscation**; you only get it after
migrating. To keep the old components instead, set `KEEP_LEGACY_UDP=true` — the two new
UDP nodes are then disabled automatically to avoid port conflicts.

If the Xray core is older than 26.6.1, the installer **upgrades the core automatically**
(except on Alpine) rather than silently disabling those two nodes.

> **No TUIC v5**: Xray-core has no TUIC inbound, so it cannot be provided under an
> Xray-only constraint. Node 2 (XHTTP over h3, direct) uses QUIC as its transport and is
> the closest equivalent.

---

## Measured handshake latency (v4.7.13)

**Conditions**: measured from the VPS itself (Oracle 4 OCPU ARM, San Jose), target
`https://www.cloudflare.com/cdn-cgi/trace`, median of 10 fresh connections per node,
no connection reuse. Direct baseline (no node at all) = **20 ms**.

| Node | First byte | Note |
|---|---|---|
| `Vless-reality-vision` | 18 ms | Matches the direct baseline |
| `Vless-xhttp-reality` | 19 ms | Its `auto` already picks stream-up |
| `Hysteria2-obfs` | 18 ms | |
| `Vless-xhttp-h3-direct` | **18 ms** | Was 69 ms; v4.7.13 switched it to `stream-up` |
| `Vless-xhttp-h2-tcp-direct` | **18 ms** | Was 68 ms; same change |
| `Vless-xhttp-tls-cdn` | 73 ms | Inherent packet-up cost, see below |
| `Vless-xhttp-h3-cdn` | 73 ms | Same |

### The ~50 ms on the two CDN nodes is structural and cannot be optimised away

Breaking the 73 ms down, each layer measured separately:

| Component | Cost | Optimisable |
|---|---|---|
| Target site itself (direct baseline) | 20 ms | — |
| **packet-up mode overhead** | **~48 ms** | ❌ structural |
| Cloudflare edge processing | 5 ms | ❌ already small |
| The Reality-fallback hop | 0.1–0.8 ms | ❌ negligible |

Two decisive controls: **the same XHTTP config bypassing Cloudflare and hitting local
nginx directly is 68 ms, versus 73 ms through Cloudflare** — so Cloudflare accounts for
only 5 ms. And this box's Cloudflare edge is in the same facility (`colo=SJC`, 0.86 ms
ping), so it is not a distance problem either.

The remaining ~48 ms is the same packet-up penalty measured on the direct nodes, but the
CDN nodes **cannot** switch to `stream-up` the way the direct ones did: measured through
Cloudflare with stream-up, CDN-TLS throughput drops to 0 and CDN-H3 times out.
Cloudflare does not support streaming request bodies — that is precisely why packet-up
exists.

The following were all tested and made no difference (interleaved sampling, 15–20 runs
each, all landing within noise at 73–75 ms):

- `scMinPostsIntervalMs` at 0 / 5 / 30
- Larger `scMaxEachPostBytes` (slightly worse, 75 ms)
- `xmux maxConcurrency` 16-32 → 64-128
- Dropping xmux entirely (only p90 got worse)
- Changing the Cloudflare origin port to bypass the Reality fallback (that hop is
  0.1–0.8 ms)
- Cache rules — the XHTTP path is already `cf-cache-status: DYNAMIC`

**Conclusion**: do not try to optimise those 50 ms away; solve it with selection instead.
The Mihomo subscription's `自动选择` (url-test) group routes by measured latency, so the
18 ms direct nodes naturally win. The CDN nodes exist as the fallback for when direct
access is blocked, and 50 ms is what they cost in exchange for presenting a Cloudflare IP
instead of your VPS.

> **These numbers do not transfer to your client.** They were measured on the VPS itself
> and describe how much headroom is left on the server side. On a real client the maths
> is different: the Cloudflare edge sits near **you**, and the edge-to-origin leg runs
> over Cloudflare's backbone, which can beat the public internet. On a poor
> intercontinental route a CDN node may well have *lower* total latency than a direct one.
> Measure it on your own client.

---

## Version history

The nine fixes since v4.7.4 are all included in the current **v4.7.13**. None of them
**change the node list or the subscription format** (still the 7 nodes above) — just
re-run the installer to pick them up.

| Version | Fix |
|---|---|
| v4.7.5 | **CDN origin-pull throughput +25%.** nginx's `grpc_buffer_size` was left at the 4k default, so Xray's downstream data was chopped into 4k pieces and forwarded over HTTP/2, multiplying syscalls and frame-header overhead. Raising it to 512k took a 100 MB loopback download from 131–162 MB/s to 177–193 MB/s. Also added `upstream xray_xhttp` with keepalive, so each POST/GET stream no longer opens a fresh connection to 8001 (packet-up upload is a stream of small POSTs, and that handshake cost was landing on every packet). |
| v4.7.6 | **Fixed loss of the real client IP on CDN connections.** `sockopt.trustedXForwardedFor` takes a list of trusted **header names**, not trusted peer IPs. It was set to `["127.0.0.1"]`, which never matched any header name, so `X-Forwarded-For` was always judged forged (8290 `ignored potentially forged` errors in 90 minutes of production logs, the overwhelming majority of the log volume) and every CDN connection was recorded as 127.0.0.1 in logs and routing. Now set to `["X-Real-IP"]` — a header nginx overwrites unconditionally, so clients cannot forge it. |
| v4.7.7 | **Fixed reinstalls silently disabling the h2-direct node.** The port-in-use probe used `ss -lnt` without `-p`, so it never printed the `users:(("proc",pid=…))` column and the owner was always an empty string. "Something is listening on 8445" was therefore read as "an external process holds it" — when in fact the process holding 8445 during a reinstall was the previous version's own xray. Every reinstall set `FEATURE_H2_DIRECT` to false, dropping the subscription from 7 nodes to 6. |
| v4.7.8 | **The Mihomo subscription no longer ships dead nodes.** The Mihomo template rendered h3-direct / h2-direct / Hysteria2 unconditionally, ignoring the `FEATURE_*` switches (the URI side had that mechanism; the Mihomo side never did). Whenever one of those nodes was disabled — missing certificate, occupied port, or an explicit `FEATURE_*=false` — the V2rayN subscription correctly lost a node while the Mihomo subscription still listed it, handing clients a dead node pointing at a nonexistent inbound, which the `直连择优` url-test group then probed every 60s. Now pruned by `FEATURE_*`. |
| v4.7.9 | ⚠️ **This fix was wrong and has been superseded by v4.7.12 — if you are on v4.7.9 through v4.7.11, Hysteria2 does not work under v2rayN/sing-box; please upgrade.** **Fixed Hysteria2 never having passed traffic.** The hysteria inbound's users were written as `settings.clients[].auth`, while Xray 26.x reads `clients[].password` — the extra key was silently ignored, the config still passed `xray run -test`, but no valid user was parsed and every client got `auth failed code 404` at authentication. It was hard to spot because the QUIC/TLS handshake succeeded, obfs worked, the port was listening, and `xh diag`'s server-side checks were all green; the symptom was "the node looks up, it just cannot pass traffic". Also added custom node naming: `NODE_TAG` for the suffix (a `localhost` hostname is no longer used directly, falling back to `vps`), and `NODE_NAME_MAP` for whole-name replacement in `old=new` form. |
| v4.7.10 | **Misspelled environment variables are no longer silently ignored.** This script is configured entirely through environment variables, and bash gives no feedback for a name that does not exist — write `CDN_DIRECT_PORT=2053` or `FEATURE_XRAY_AUTO_UPGRADE=true` (plausible-looking names that simply are not in the script) and the install succeeds, the logs look fine, and you believe the setting took effect. Almost nobody would think to check this while debugging. The installer now lists every variable that "looks like one of this project's parameters but is never referenced by the script" and warns (without aborting). The known-variable list is not hardcoded: the script greps itself for the name, so it can never drift from the implementation. |
| v4.7.11 | **ECH is now off by default, and `FEATURE_*` environment variables can finally actually override.** ECH requires enabling it in Cloudflare's Edge Certificates first; turning it on without that prerequisite makes the CDN nodes fail the handshake outright — a trap for anyone who did not read prerequisite 6 — so it now defaults to off and must be requested explicitly with `CDN_ECH=y`. xpadding stays on by default (it defends against traffic fingerprinting; turning it off does not affect confidentiality, but does make the node easier to identify). This release also fixed a long-standing bug: the build script injected unconditional assignments `FEATURE_XPADDING=true`, which **overwrote** whatever the user passed in, meaning the documented `FEATURE_XPADDING=false bash install.sh` had never actually worked. Changed to `${VAR:-default}`. |
| v4.7.12 | **Fixed the regression introduced in v4.7.9: Hysteria2 broken under v2rayN / sing-box.** v4.7.9 changed the inbound users from `clients[].auth` to `clients[].password`, based on "testing with Xray's own hysteria outbound showed only this form authenticates" — but that test client put auth in `settings.auth`, whereas the [official docs](https://xtls.github.io/config/transports/hysteria.html) place the outbound auth in `streamSettings.hysteriaSettings.auth`. Two non-standard configs happened to match each other, producing a wrong conclusion that broke standard clients instead: sing-box (v2rayN's Hysteria2 core) reported `authentication failed, status code: 404` ever since. The correct form is the documented `settings.users[].auth`. Verified against three cores, each with a negative control confirming a wrong password really does fail: sing-box 236 Mbps, Xray 253 Mbps, mihomo working. |
| v4.7.13 | **Handshake latency configured per node type; fixed the Reality nodes being unusable under mihomo.** ① The two direct XHTTP nodes (h3-direct / h2-direct) now use `mode=stream-up`: under `security=tls`, `auto` conservatively picks packet-up, which splits the upload into a series of POSTs with a minimum interval and costs about 50 ms of extra first-byte latency. Measured first byte went from 68/69 ms to **18 ms** (equal to the no-proxy baseline), with throughput unchanged. **The CDN nodes must stay on packet-up** — packet-up exists precisely because CDNs do not support streaming request bodies, and measured through Cloudflare with stream-up, CDN-TLS throughput dropped to 0 and CDN-H3 timed out. The Reality nodes need no change; their `auto` already picks stream-up. ② Reality gained `minClientVer: "1.8.0"`: Xray 26.x's Reality defaults to a minimum client version of Xray-core v26.3.27 (the `other clients may be refused to connect` line in the startup log), so mihomo failed the handshake outright with `REALITY authentication failed` and **both Reality nodes were unusable** under mihomo / Clash-family clients. After relaxing it, all seven nodes work under mihomo. |

---

## Prerequisites

Complete these in Cloudflare before running the script. (For a free domain that can be
hosted on Cloudflare, try <https://my.dnshe.com/index.php?m=domain_hub> or
<https://dash.domain.digitalplat.org/dashboard>.)

1. Reality domain DNS → **DNS only** (grey cloud), pointing at your VPS IP; used to issue
   the certificate.
2. CDN domain DNS → **Proxied** (orange cloud), pointing at your VPS IP.
3. SSL/TLS encryption → **Full (strict)**.
4. Network → **gRPC enabled**.
5. Cache rules (recommended) → set the XHTTP path to bypass cache; the script prints the
   expression once deployment finishes.
6. For ECH → enable ECH in Edge Certificates first. It is off by default.

Alternatively, each entry domain can use its own `dist/<domain>/index.html` as the
fallback page; you can capture a real page with
[SingleFile](https://chromewebstore.google.com/detail/singlefile/mpiodijhokgodhhofbcjdecpffjipkle)
and upload it.

If certificate issuance fails for the Reality domain, acme.sh can be used instead:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh)
```

---

## One-command deployment

> **Version requirements**: Xray core ≥ `26.6.1`, Mihomo core ≥ `1.19.24`.
> The Xray floor comes from the two direct UDP nodes: the Hysteria2 inbound needs 26.3.27+,
> and the finalmask UDP-listener crash (issue #6184) is only fixed in 26.6.1+. Below that
> version the installer disables those two nodes automatically.
>
> Since v4.7.4 **all 7 nodes and all features are on by default**: xpadding (XHTTP padding
> obfuscation), Hysteria2 finalmask + Salamander obfuscation, VLESS Encryption
> (ML-KEM-768), and the h3-direct node — with kernel tuning applied at install time
> (`xh tuning on`, best-effort). ECH is the exception: off by default, enable with
> `CDN_ECH=y`.
> For a minimal setup, use
> `FEATURE_H3_DIRECT=false FEATURE_XPADDING=false FEATURE_CDN_ECH=false FEATURE_AUTO_TUNING=false bash install.sh`.

Debian / Ubuntu:

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/Xray-core-xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

The script is re-runnable — use it to change domains, fallback sites and other parameters.

### Extension: XHTTP over HTTP/3 (3 h3 nodes)

```bash
curl -fsSL https://github.com/ShJChow/Xray-core-xhttp-cdn-tuned/releases/latest/download/add-quic-h3.sh -o ~/add-quic-h3.sh && bash ~/add-quic-h3.sh
```

Ported from the upstream `add-quic.sh`, this appends `Vless-xhttp-tls-h3`,
`Vless-xhttp-split-h2up-h3down` and `Vless-xhttp-split-h3up-h2down`. All three use the CDN
domain for `sni`/`host`, and nginx's `listen ... quic` is inserted into the **CDN domain's
server block**, reusing the `location` already there — unlike `add-quic.sh` (Hysteria2),
which inserts into the Reality block. The two use different config markers and can be
installed side by side.

## Extension scripts

Add these after the main deployment as needed. They reuse the existing
`UUID / Path / VLESS Encryption` and update the client configs and subscription.

```bash
# Direct Hysteria2 (the XHTTP+TLS+H3 node in the same extension is known to be broken, see below)
curl -fsSL https://github.com/ShJChow/Xray-core-xhttp-cdn-tuned/releases/latest/download/add-quic.sh -o ~/add-quic.sh && bash ~/add-quic.sh
```

> Since v2.0.1 this extension **only emits `Hysteria2-direct` by default**.
> `Vless-xhttp-tls-h3-direct` requires `FEATURE_XHTTP_H3_NODE=true`.
> **That node is measurably broken under Shadowrocket** (the same cause as the direct h3
> node the main script already disables by default). If you want Hysteria2, run the
> extension as usual and ignore the h3 node.

### Non-interactive (scripted reinstall)

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/Xray-core-xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
AUTO=1 \
REALITY_DOMAIN=reality.example.com \
CDN_DOMAIN=cdn.example.com \
IP_CHOICE=1 \
FALLBACK_MODE=proxy \
REALITY_FALLBACK_ORIGIN=https://www.sjsu.edu \
CDN_FALLBACK_ORIGIN=https://www.harvard.edu \
CDN_ECH=n \
bash ~/install.sh
```

Available environment variables:

| Variable | Meaning | Default |
|---|---|---|
| `AUTO` | `1` for zero prompts | `0` |
| `REALITY_DOMAIN` / `CDN_DOMAIN` | The two domains, **required** | — |
| `IP_CHOICE` | `1`=IPv4, `2`=IPv6 | `1` |
| `FALLBACK_MODE` | `static` (local page) / `proxy` (reverse proxy) | `proxy` |
| `REALITY_FALLBACK_ORIGIN` / `CDN_FALLBACK_ORIGIN` | Fallback sites in `proxy` mode | sjsu / harvard |
| `FEATURE_XPADDING` | `false` disables XHTTP padding obfuscation (xpadding) | `true` |
| `FEATURE_CDN_ECH` | `false` skips the ECH prompt (ECH itself still needs `CDN_ECH=y`) | `true` |
| `XHTTP_PADDING_HEADER` / `XHTTP_PADDING_KEY` | xpadding fields | `Referer` / `x_padding` |
| `CDN_ECH` | `y` enables ECH (must be enabled in Cloudflare Edge Certificates first, or the CDN nodes fail the handshake) | `n` |
| `VISION_UDP443` | `1` makes node 1 use `xtls-rprx-vision-udp443` (client support required) | `0` |
| `FEATURE_H3_DIRECT` | `false` disables the direct h3 node (UDP 8444; known upstream issues, on by default) | `true` |
| `FEATURE_HY2` | `false` disables the Hysteria2-obfs node (UDP 8443) | `true` |
| `FEATURE_AUTO_TUNING` | `false` skips the automatic kernel tuning at install time (`xh tuning off` rolls it back at any point) | `true` |
| `H3_PORT` / `HY2_PORT` | Ports for the two direct UDP nodes (`H3_PORT` may not be 443; it is forced back to 8444) | `8444` / `8443` |
| `KEEP_LEGACY_UDP` | `true` keeps the old standalone hysteria / quic-h3 extensions (the two new UDP nodes are then disabled) | `false` |
| `FEATURE_XHTTP_H3_NODE` | Switch for the Hysteria2 extension: `true` restores the `Vless-xhttp-tls-h3-direct` node and its nginx quic listener | `false` |
| `FEATURE_KEEPALIVE` | `false` skips the keepalive cron | `true` |
| `FEATURE_AUTOUPDATE` | `false` skips the auto-update cron | `true` |
| `NODE_TAG` | Node-name suffix, replacing the hostname | hostname (`vps` when empty or `localhost`) |
| `NODE_NAME_MAP` / `NODE_NAME_FILE` | Custom node names, one `old=new` per line; `NODE_NAME_FILE` points at a file in the same format | — |

With `AUTO=1` and `FALLBACK_MODE=static`, a placeholder `index.html` is generated and the
manual confirmation is skipped; replace it afterwards as you like.

#### Custom node names

The default node name is `Vless-xhttp-h3-cdn-${hostname}`. Most VPS images have `localhost`
as their hostname, which makes that suffix useless for telling machines apart in a
multi-server subscription — so `localhost` is treated as unset and falls back to `vps`.
For a meaningful suffix, set `NODE_TAG=hk-oracle`.

To use full airport-style names (emoji plus region), use `NODE_NAME_MAP`, with the
generated full node name (including suffix) on the left and the display name on the right:

```bash
NODE_TAG=vps \
NODE_NAME_MAP='Vless-xhttp-tls-cdn-vps=🇺🇸 VLESS-XHTTP-TLS-CF-h2
Vless-xhttp-h3-cdn-vps=🇺🇸 VLESS-XHTTP-TLS-CF-h3
Vless-xhttp-h3-direct-vps=🇺🇸 VLESS-XHTTP-TLS-QUIC
Vless-xhttp-h2-tcp-direct-vps=🇺🇸 VLESS-XHTTP-TLS-TCP
Hysteria2-obfs-vps=🇺🇸 Hysteria2-QUIC-TLS
Vless-reality-vision-vps=🇺🇸 VLESS-TCP-REALITY-Vision
Vless-xhttp-reality-vps=🇺🇸 VLESS-XHTTP-REALITY' \
AUTO=1 ... bash install.sh
```

Renaming applies to `client-config.txt`, both Mihomo YAML files (including the references
inside proxy-groups) and the subscription generated from them. URI fragments are
percent-encoded automatically — an unencoded node name containing a space gets truncated at
the space by clients such as Shadowrocket.

---

## Optional: general VPS optimisation script

```bash
# 1. Download
curl -O https://raw.githubusercontent.com/ShJChow/Xray-core-xhttp-cdn-tuned/main/tools/ubuntu_vps_optimize.sh

# 2. Make it executable
chmod +x ubuntu_vps_optimize.sh

# 3. Look without touching — detect and print the plan, change nothing
sudo bash ubuntu_vps_optimize.sh --dry-run

# 4. Run it for real once you are satisfied
sudo bash ubuntu_vps_optimize.sh
```

Three modes:

| Command | Effect |
|---|---|
| `--dry-run` | Detect and print what would change; writes nothing |
| *(no argument)* | Detect → back up → optimise → verify |
| `--rollback` | Full rollback to the pre-run state |

Restart the services afterwards: `systemctl restart xray nginx docker`.

---

## The `xh` command

Available as soon as deployment finishes.

```text
xh                      Interactive menu
xh status               Service status / listening ports / tuning state / versions
xh info                 Node parameters and client node links
xh sub                  Subscription links and QR codes
xh log [xray|nginx]     Follow the logs
xh start|stop|restart   Service control
xh update [--auto]      Update Xray-core (automatic rollback if the self-test fails)
xh tuning [show|on|off] Show / enable / roll back the system-level tuning
xh diag                 Server-side self-check for when a node will not connect
xh conflict             Detect other files in /etc/sysctl.d/ that override this project's parameters
xh keepalive [on|off]   Keepalive toggle
xh autoupdate [on|off]  Core auto-update toggle
xh uninstall            Remove all components
```

---

## System tuning

### What `xh tuning on` does

BBR + fq, `rmem/wmem` (64/32/16 MB by RAM tier), `tcp_fastopen=3`, `tcp_mtu_probing=1`,
`tcp_slow_start_after_idle=0`, `tcp_notsent_lowat`, `somaxconn=65535`, UDP buffers and
`udp_mem` (for QUIC/H3), plus `limits.d` and a systemd drop-in (`nofile=1048576`).

Everything is written to its own files — `/etc/sysctl.d/99-xray-xhttp.conf` and
`/etc/security/limits.d/99-xray-xhttp.conf` — so **your existing `sysctl.conf` is left
alone**, and the official Xray unit is not modified either (a drop-in is used, so core
updates will not overwrite it).

All tuning is **best-effort**: on read-only-sysctl environments such as OpenVZ / LXC each
failing item is skipped with a warning rather than aborting. Roll back with
`xh tuning off`.

> **Unverified**: whether these parameters actually improve throughput on your machine has
> not been measured comparatively by this project. That is exactly why they are opt-in —
> get the nodes working first, then enable and compare if you want to.

---

## Manual deployment

If you would rather not run the script, read `docs/` in order. **These documents are
currently Chinese-only.**

1. [1.环境配置.md](./docs/1.环境配置.md) — Environment setup
2. [2.文件配置.md](./docs/2.文件配置.md) — File configuration
3. [3.xpadding配置.md](./docs/3.xpadding配置.md) — xpadding
4. [4.ECH配置.md](./docs/4.ECH配置.md) — ECH
5. [5.流程图.md](./docs/5.流程图.md) — Flow diagrams
6. [6.拓展-上下行不同CDN.md](./docs/6.拓展-上下行不同CDN.md) — Different CDNs up/down
7. [7.拓展-上下行IPv4IPv6.md](./docs/7.拓展-上下行IPv4IPv6.md) — IPv4 up, IPv6 down
8. [8.拓展-QUIC添加.md](./docs/8.拓展-QUIC添加.md) — Adding QUIC
9. [9.卸载.md](./docs/9.卸载.md) — Uninstalling
10. [10.流控调优.md](./docs/10.流控调优.md) — Tuning reference
11. [11.管理命令.md](./docs/11.管理命令.md) — The `xh` command
12. [12.机型调优-OracleARM.md](./docs/12.机型调优-OracleARM.md) — Oracle ARM specifics
13. [客户端模板.txt](./客户端模板.txt) / [客户端模板-mihomo.yaml](./客户端模板-mihomo.yaml) — Client templates

---

## Output files

- `~/client-config.txt` — V2RayN / Shadowrocket nodes
- `~/client-config-mihomo-full.yaml` — full Mihomo config with routing rules
- `~/client-config-mihomo-nodes.yaml` — Mihomo nodes only
- `~/subscription-links.txt`, `~/subscription-*.png` — subscription links and QR codes
- `/etc/xhttp-cdn/node.env` — node parameters (mode 0600, read by `xh`)

If you already have a Mihomo config, use `mihomo-nodes.yaml`.

---

## If something breaks: clean up and re-run

```bash
pkill -9 -x xray; pkill -9 -f 'xray run'
rm -f  /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
rm -f  /usr/local/bin/xray
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
systemctl daemon-reload && systemctl reset-failed

pgrep -a xray || echo "✅ clean"
bash ~/install.sh
```

Pushing a `v*` tag makes GitHub Actions build and publish a Release automatically.

---

## Disclaimer

**Please read this section in full before deploying.**

### Legal and compliance

This project is an **open-source deployment script for network transports**. It provides
automation only: it operates no nodes, runs no service, and never touches user traffic.
Whether to deploy it, how to use it, and every consequence that follows are entirely the
user's own responsibility.

**Note for users in mainland China**: within mainland China, establishing or using an
unauthorised channel for international networking without approval from the telecom
authorities may violate the *Interim Provisions on the Administration of International
Networking of Computer Information Networks* (Article 6) and its implementing measures,
along with related regulations. Consequences can include orders to disconnect, warnings,
fines, and confiscation of unlawful gains. Using it commercially — selling or sharing
access for profit — is treated far more seriously, and there are decided cases charged as
"illegal business operation" or "providing programs or tools for intruding into or
unlawfully controlling computer information systems".

The author does not encourage anyone to break the law in their own jurisdiction.
**If you fall under such laws, assess the risk yourself and own your choice.** Neither
this project nor its author bears any legal responsibility for what users do with it.

**Strictly prohibited**: selling or distributing proxy access to the public, telecom and
online fraud, cross-border gambling, money laundering, distributing unlawful content, or
any other criminal activity.

### Honest technical notes

- **Nothing here guarantees you will not be detected, or that it will keep working.**
  Reality, xpadding and Salamander obfuscation raise the cost of traffic analysis; they
  do not make traffic unidentifiable. Censorship technology keeps moving, and a config
  that works today can fail tomorrow. Distrust anything claiming to be block-proof.
- **Getting an IP blocked is normal.** The direct nodes expose the VPS's bare IP; once it
  is blocked, every direct node on that IP fails at once. That is inherent to this class
  of setup, not a misconfiguration.
- **UDP / QUIC is frequently throttled or blocked in mainland China.** Four of the seven
  nodes depend on UDP (h3-cdn, h3-direct, Hysteria2, and the CDN's UDP 443). Some ISPs
  apply QoS to UDP at peak hours: those nodes work at first, then slow down or stop,
  while the TCP nodes stay fine. **That is not a server fault** —
  `Vless-reality-vision` and `Vless-xhttp-h2-tcp-direct` are the TCP fallbacks kept
  precisely for this.
- **Cloudflare's real-world speed varies a lot by region.** Reaching Cloudflare's anycast
  IPs from mainland China gives highly variable PoPs and route quality, potentially far
  worse than the numbers above. Measure on your own client before choosing a node.
- **Every performance figure in this repository is a single measurement** on one machine,
  at one time, over one route. None of it is a performance promise for any other
  environment.

### No warranty

This project is provided "as is" under the MIT licence, without warranty of any kind,
express or implied, including but not limited to merchantability, fitness for a
particular purpose, and non-infringement. The author is not liable for any direct or
indirect loss arising from use or inability to use it, including but not limited to
server suspension, data loss, account loss, or legal liability.

---

## Credits and licence

Derived from [Yulinanami/my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config) (MIT).
The product shape — management command, non-interactive deployment, self-healing keepalive
and automatic core updates — is inspired by
[yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) (GPL-3.0); that code is
reimplemented here rather than copied.

See [NOTICE.md](./NOTICE.md). Licence: [MIT](./LICENSE).

## References

- Xray beginner's guide: <https://xtls.github.io/document/level-0/ch07-xray-server.html>
- XHTTP: Beyond REALITY: <https://github.com/XTLS/Xray-core/discussions/4113>
- XHTTP + CDN split upload/download discussion: <https://github.com/XTLS/Xray-core/discussions/4118>
- Xray SockoptObject docs: <https://xtls.github.io/config/transports/sockopt.html>
- Xray-core v26.2.6 (xpadding): <https://github.com/XTLS/Xray-core/releases/tag/v26.2.6>
- xpadding leak discussion: <https://github.com/XTLS/Xray-core/issues/4346>, <https://github.com/XTLS/BBS/issues/25>
- Mihomo XHTTP discussion: <https://github.com/MetaCubeX/mihomo/discussions/2669>

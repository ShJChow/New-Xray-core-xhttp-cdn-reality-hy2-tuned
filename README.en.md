# xray-xhttp

**Languages:** [简体中文](./README.md) · **English** · [فارسی](./README.fa.md)

> **The `xhttp+udp+cdn` node is extremely fast under onexray (iOS) — faster than Hysteria2 in our tests** (measured on Oracle 4 OCPU / 24 GB).

A one-command deployment of **XHTTP with split upload/download over CDN**, built on Xray-core and served on port 443. **xpadding is on by default** (ECH optional), and a resident management command `xh` is installed alongside it.

Works with V2rayN / Shadowrocket / Mihomo / onexray, over both IPv4 and IPv6.

> **Background reading**: XHTTP, split upload/download, and why it resists censorship — <https://habr.com/en/articles/990208/>
>
> **Note**: this setup uses VLESS Encryption. Your client (V2rayN, Mihomo) must be new enough to support `vlessenc` and `xhttp`.
>
> **Note**: V2rayN v7.19.5+ can be unstable in TUN mode; enable the legacy TUN-protection option ([PR #9005](https://github.com/2dust/v2rayN/pull/9005)).

After installing the nodes and the Hysteria2 extension, run **`xh tuning on`**.

---

## Features

| Capability | Details |
|---|---|
| Node set (v4.0.0) | 5 nodes, all served by a single Xray core: 3 over QUIC/h3 (including Hysteria2 with obfs) + 2 TCP fallbacks. No separate hysteria binary needed |
| xpadding | On by default — `xPaddingObfsMode` plus a custom header and parameter name, to defeat XHTTP fingerprinting on the CDN side |
| ECH | Optional; encrypts the SNI inside the TLS handshake |
| VLESS Encryption | On by default (ML-KEM-768), so the CDN cannot decrypt traffic as a man in the middle |
| **System tuning** | BBR + fq, TFO, MTU probing, file handles at 1048576, Xray `sockopt`, and Nginx gRPC long-connection timeouts |
| **Hardware-adaptive** | Three tiers picked from installed RAM (≥16 GB / ≥4 GB / <4 GB) scale buffers and queues; page size is queried at runtime rather than assumed |
| flow / Vision | Node 1 uses `xtls-rprx-vision` (the only node that can use Splice). The rest are XHTTP, which by protocol cannot carry a flow. `VISION_UDP443=1` switches to `-udp443` |
| **`xh` command** | Status / node details / subscription / logs / core update / tuning switch / keepalive / uninstall |
| **Non-interactive** | Driven entirely by environment variables; `AUTO=1` reinstalls with zero prompts |
| **Self-healing** | A cron health check every 5 minutes, plus start-on-boot |
| **Automatic core updates** | Xray-core is updated weekly and rolled back automatically if the config self-check fails |
| Extensions | Different CDN for up/down · IPv4 up + IPv6 down · Hysteria2 |

---

## Node list

Since v4.0.0 the installer emits **the 5 nodes below**, all served by a single Xray core — Hysteria2 now uses Xray's native inbound (v26.3.27+), so no separate hysteria binary is required.

**The node order is the HTTP/3-first order**: the first three run over QUIC, the last two are TCP fallbacks for when UDP is blocked. Mihomo's proxy groups use `include-all: true`, so this ordering carries straight through.

Node 1 goes through the CDN and its server is a domain name, so **in V2rayN TUN mode you must add the CDN domain to the direct/bypass list** or the connection loops back on itself. Nodes 2/3 connect to the bare IP and only need a direct route for the VPS IP. The installer writes `~/client-config-v2rayn-tun.txt` with that list filled in for your machine.

Node names are plain ASCII plus a hostname suffix (`<host>` = `hostname -s`):

| # | Node name | Path | Transport |
|---|---|---|---|
| 1 | `Vless-xhttp-tls-UDP-cdn-<host>` | Via CDN, **UDP 443** | XHTTP + TLS, alpn h3 — **fastest in testing** |
| 2 | `Vless-xhttp-h3-direct-<host>` | Direct to VPS, **UDP 443** | XHTTP + TLS, alpn h3, no CDN |
| 3 | `Hysteria2-obfs-<host>` | Direct to VPS, **UDP 8443** | Hysteria2 + Salamander obfuscation |
| 4 | `Vless-reality-vision-<host>` | Direct to VPS, TCP 443 | Reality + Vision; fallback when UDP is blocked |
| 5 | `Vless-xhttp-reality-<host>` | Direct to VPS, TCP 443 | XHTTP + Reality, upload and download together |

Nodes 2/3 are bare UDP to the VPS, so you must open **UDP 443 and UDP 8443 in your cloud provider's security group** — that layer sits outside the machine and the script can neither see nor change it. If the Xray core is older than 26.6.1 these two nodes are disabled automatically and only the other three are emitted.

> **No TUIC v5**: Xray-core has no TUIC inbound, so it cannot be provided under an Xray-only constraint. Node 2 (XHTTP over h3, direct) uses QUIC as its transport and is the closest equivalent.

## Prerequisites

Configure the following in Cloudflare before running the script:

1. Reality domain DNS → **DNS only** (grey cloud)
2. CDN domain DNS → **Proxied** (orange cloud)
3. SSL/TLS encryption → **Full (strict)**
4. Network → **gRPC enabled**
5. Cache rules (recommended) → set the XHTTP path to bypass cache; the script prints the exact expression once deployment finishes
6. For ECH → enable ECH under Edge Certificates first

Each entry domain uses its own `dist/<domain>/index.html` as the fallback page. You can capture a real page with [SingleFile](https://chromewebstore.google.com/detail/singlefile/mpiodijhokgodhhofbcjdecpffjipkle) and upload it.

---

## One-command deployment (recommended: XHTTP with xpadding)

> **Version requirements**: Xray core ≥ `26.6.1`, Mihomo core ≥ `1.19.24`.
> The Xray floor comes from the two direct UDP nodes: Hysteria2 inbound needs 26.3.27+, and the finalmask UDP listener crash (issue #6184) is only fixed in 26.6.1+. Below that the installer disables those two nodes automatically.
> xpadding is on by default; ECH is optional and off by default.

Debian / Ubuntu:

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```

### Plain version, without xpadding

> Mihomo core ≥ `1.19.23` is enough.

```bash
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

The script is safe to re-run — use it to change domains, fallback sites and other parameters.

**Re-running regenerates every UUID and key**, so existing client configs stop working. Back up first if that matters:

```bash
cp -a /etc/xhttp-cdn/node.env ~/node.env.bak.$(date +%F)
cp -a ~/client-config.txt ~/client-config.txt.bak.$(date +%F)
```

---

## Extensions

Run these after the main script. They reuse the existing `UUID / Path / VLESS Encryption` and update your client config and subscription.

```bash
# Hysteria2, direct
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/add-quic.sh -o ~/add-quic.sh && bash ~/add-quic.sh
```

> Since v2.0.1 this extension **only produces `Hysteria2-direct`** by default. `Vless-xhttp-tls-h3-direct` requires `FEATURE_XHTTP_H3_NODE=true`.
> That node **does not work under Shadowrocket in practice** (same root cause as the direct h3 node the main script already disabled) — see the erratum in [docs/8](./docs/8.拓展-QUIC添加.md). If you just want Hysteria2, run the extension as usual and ignore the h3 node.

### Non-interactive install (scripted reinstall)

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/xhttp-cdn-tuned/releases/latest/download/install-xpadding.sh -o ~/install-xpadding.sh
AUTO=1 \
REALITY_DOMAIN=reality.example.com \
CDN_DOMAIN=cdn.example.com \
IP_CHOICE=1 \
FALLBACK_MODE=proxy \
REALITY_FALLBACK_ORIGIN=https://www.sjsu.edu \
CDN_FALLBACK_ORIGIN=https://www.harvard.edu \
CDN_ECH=n \
bash ~/install-xpadding.sh
```

Available environment variables:

| Variable | Meaning | Default |
|---|---|---|
| `AUTO` | `1` means zero prompts | `0` |
| `REALITY_DOMAIN` / `CDN_DOMAIN` | The two domains — **required** | — |
| `IP_CHOICE` | `1` = IPv4, `2` = IPv6 | `1` |
| `FALLBACK_MODE` | `static` (local page) or `proxy` (reverse proxy) | `proxy` |
| `REALITY_FALLBACK_ORIGIN` / `CDN_FALLBACK_ORIGIN` | Fallback sites in `proxy` mode | sjsu / harvard |
| `XHTTP_PADDING_HEADER` / `XHTTP_PADDING_KEY` | xpadding fields | `Referer` / `x_padding` |
| `CDN_ECH` | `y` enables ECH | `n` |
| `VISION_UDP443` | `1` makes node 1 use `xtls-rprx-vision-udp443` (needs client support) | `0` |
| `FEATURE_H3_DIRECT` | `false` disables the direct h3 node (UDP 443) | `true` |
| `FEATURE_HY2` | `false` disables the Hysteria2-obfs node (UDP 8443) | `true` |
| `H3_PORT` / `HY2_PORT` | Ports for the two direct UDP nodes | `443` / `8443` |
| `FEATURE_XHTTP_H3_NODE` | Hysteria2-extension switch: `true` restores `Vless-xhttp-tls-h3-direct` and its nginx quic listener | `false` |
| `FEATURE_KEEPALIVE` | `false` skips the keepalive cron | `true` |
| `FEATURE_AUTOUPDATE` | `false` skips the auto-update cron | `true` |

With `AUTO=1` and `FALLBACK_MODE=static`, a placeholder `index.html` is generated and the manual confirmation is skipped; replace it later at your convenience.

---

## The `xh` command

Available as soon as deployment finishes. See [docs/11](./docs/11.管理命令.md) for details.

```text
xh                      Interactive menu
xh status               Service status / listening ports / tuning state / versions
xh info                 Node parameters and client node links
xh sub                  Subscription links and QR codes
xh log [xray|nginx]     Follow logs
xh start|stop|restart   Service control
xh update [--auto]      Update Xray-core (auto-rollback if the self-check fails)
xh tuning [show|on|off] Show / apply / roll back system-level tuning
xh diag                 Server-side self-check when a node will not connect
xh conflict             Find files in /etc/sysctl.d/ that would override this project's values
xh keepalive [on|off]   Keepalive switch
xh autoupdate [on|off]  Core auto-update switch
xh version              Project and Xray-core version
xh uninstall            Remove every component
```

---

## System tuning

### What `xh tuning on` does

BBR + fq, `rmem/wmem` (64/32/16 MB by RAM tier), `tcp_fastopen=3`, `tcp_mtu_probing=1`, `tcp_slow_start_after_idle=0`, `tcp_notsent_lowat`, `somaxconn=65535`, UDP buffers (for QUIC/H3), and `limits.d` + a systemd drop-in (`nofile=1048576`).

Everything is written to its own files — `/etc/sysctl.d/99-xray-xhttp.conf` and `/etc/security/limits.d/99-xray-xhttp.conf`. **Your existing `sysctl.conf` is never modified**, and the official Xray unit is left alone (a drop-in is used, so core updates will not overwrite it).

All tuning is **best-effort**: on read-only-sysctl environments such as OpenVZ or LXC, individual settings are skipped with a warning instead of aborting. `xh tuning off` rolls everything back. The full parameter table is in [docs/10](./docs/10.流控调优.md).

> **Not verified**: whether these values actually improve throughput on *your* machine. No controlled measurement has been done for this project. That is exactly why tuning is off by default — get the nodes working first, then enable it and compare if you want to.

There is also a standalone script, `tools/vps-tune.sh`, for machines where you would rather not use `xh`. It supports `--dry-run` and `--rollback`, and it refuses to run while `xh tuning` is active so that neither one silently overwrites the other's rollback.

---

## Manual deployment

If you would rather not run the script, read `docs/` in order (Chinese):

1. [1.环境配置.md](./docs/1.环境配置.md) — environment setup
2. [2.文件配置.md](./docs/2.文件配置.md) — file configuration
3. [3.xpadding配置.md](./docs/3.xpadding配置.md) — xpadding
4. [4.ECH配置.md](./docs/4.ECH配置.md) — ECH
5. [5.流程图.md](./docs/5.流程图.md) — flow diagram
6. [6.拓展-上下行不同CDN.md](./docs/6.拓展-上下行不同CDN.md) — different CDN per direction
7. [7.拓展-上下行IPv4IPv6.md](./docs/7.拓展-上下行IPv4IPv6.md) — IPv4 up / IPv6 down
8. [8.拓展-QUIC添加.md](./docs/8.拓展-QUIC添加.md) — QUIC / Hysteria2
9. [9.卸载.md](./docs/9.卸载.md) — uninstall
10. [10.流控调优.md](./docs/10.流控调优.md) — tuning reference
11. [11.管理命令.md](./docs/11.管理命令.md) — `xh` reference
12. [12.机型调优-OracleARM.md](./docs/12.机型调优-OracleARM.md) — Oracle ARM notes

---

## Output files

- `~/client-config.txt` — V2RayN / Shadowrocket nodes
- `~/client-config-v2rayn-tun.txt` — the direct/bypass list for V2rayN TUN mode, filled in for this machine
- `~/client-config-mihomo-full.yaml` — full Mihomo config with routing
- `~/client-config-mihomo-nodes.yaml` — Mihomo nodes only
- `~/subscription-links.txt`, `~/subscription-*.png` — subscription links and QR codes
- `/etc/xhttp-cdn/node.env` — node parameters (mode 0600, read by `xh`)

If you already have a Mihomo config, use `mihomo-nodes.yaml`.

---

## If something breaks: clean up and re-run

An interrupted uninstall can leave a state where the process is still running while its unit file and binary are already gone. The official Xray installer then fails with `Unit xray.service not loaded`. Clear it like this:

```bash
pkill -9 -x xray; pkill -9 -f 'xray run'
rm -f  /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
rm -f  /usr/local/bin/xray
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
systemctl daemon-reload && systemctl reset-failed

pgrep -a xray || echo "clean"
bash ~/install.sh
```

Pushing a `v*` tag makes GitHub Actions build and publish a Release automatically.

---

## Credits and licence

Derived from [Yulinanami/my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config) (MIT).

The product shape — management command, non-interactive deployment, self-healing and automatic core updates — is inspired by [yonggekkk/argosbx](https://github.com/yonggekkk/argosbx) (GPL-3.0); that code is our own implementation and none of its source was copied.

See [NOTICE.md](./NOTICE.md). Licence: [MIT](./LICENSE).

## References

- Xray beginner's guide: <https://xtls.github.io/document/level-0/ch07-xray-server.html>
- XHTTP: Beyond REALITY: <https://github.com/XTLS/Xray-core/discussions/4113>
- Split upload/download over CDN: <https://github.com/XTLS/Xray-core/discussions/4118>
- Xray SockoptObject: <https://xtls.github.io/config/transports/sockopt.html>
- Xray-core v26.2.6 (xpadding): <https://github.com/XTLS/Xray-core/releases/tag/v26.2.6>
- xpadding leak discussion: <https://github.com/XTLS/Xray-core/issues/4346> · <https://github.com/XTLS/BBS/issues/25>
- Mihomo XHTTP discussion: <https://github.com/MetaCubeX/mihomo/discussions/2669>
- Mihomo docs (Transport): <https://wiki.metacubex.one/config/proxies/transport/>
- Cloudflare ECH: <https://developers.cloudflare.com/ssl/edge-certificates/ech/>

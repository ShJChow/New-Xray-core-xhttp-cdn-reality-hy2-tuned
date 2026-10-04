# xray-xhttp

**Languages:** [简体中文](./README.md) · **English** · [فارسی](./README.fa.md)

> **Deeply tested and tuned on Oracle ARM (4 Core / 24G) and Ubuntu 26.04.** Specifically tuned to maintain stable connectivity and avoid AI account blocks.

An all-in-one high-availability deployment solution for **XHTTP + CDN + Reality + Hysteria2** based on Xray-core. Pre-configured with **xpadding traffic obfuscation / Hysteria2 Salamander obfuscation / 8 core nodes**, and automatically applies **system and network flow control tuning (BBR+fq, 64MB buffers, 1048576 file descriptors, security hardening)** during installation, alongside the resident management CLI **`xh`**.

Supports all major client platforms: V2rayN, Clash Verge Rev, Mihomo Party, Sing-box, Shadowrocket, Loon, Surge, onexray, etc. *Note: Ensure your client core is updated to support newer protocols such as HTTP/3.*

---

## Table of Contents

- [1. Prerequisites (Domains, Cloudflare & Certificates)](#1-prerequisites)
  - [1.1 DNS Resolution Setup](#11-dns-resolution-setup)
  - [1.2 Cloudflare Dashboard Settings](#12-cloudflare-dashboard-settings)
  - [1.3 SSL Certificate Issuance (acme-yg / acme.sh)](#13-ssl-certificate-issuance)
- [2. One-Command Deployment](#2-one-command-deployment)
  - [2.1 Interactive Deployment](#21-interactive-deployment)
  - [2.2 Zero-Interaction Environment Variable Deployment](#22-zero-interaction-environment-variable-deployment)
- [3. Resident Management Command `xh`](#3-resident-management-command-xh)
- [4. Client Tuning Guide for Gigabit Networks](#4-client-tuning-guide-for-gigabit-networks)
- [5. Node Topology & Dual-Track Architecture](#5-node-topology--dual-track-architecture)
- [6. Troubleshooting & FAQ](#6-troubleshooting--faq)
- [7. Release History & Core Tuning Evolution (v4.8 - v4.9.51)](#7-release-history--core-tuning-evolution-v48---v4951)
- [8. Disclaimer](#8-disclaimer)
- [Credits & License](#credits--license)

---

## 1. Prerequisites

Before running the deployment script, prepare **2 subdomains resolving to your VPS IP** (Cloudflare recommended):
- **Domain 1 (Direct / Reality Domain)**: e.g., `reality.example.com`
- **Domain 2 (CDN Domain)**: e.g., `cdn.example.com`

---

### 1.1 DNS Resolution Setup

Add two `A` records in the Cloudflare DNS dashboard pointing to your VPS public IP:

| Record Type | Name | Target IP | Proxy Status | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **A Record** | `reality.example.com` | `Your VPS IP` | **DNS only (Grey Cloud)** | Certificate issuance & Reality / Hy2 direct link |
| **A Record** | `cdn.example.com` | `Your VPS IP` | **Proxied (Orange Cloud)** | XHTTP CDN node to hide origin IP |

---

### 1.2 Cloudflare Dashboard Settings

Enable the following options in your Cloudflare dashboard:

1. **SSL/TLS** ➡️ **Overview**: Select **Full (strict)** encryption mode;
2. **SSL/TLS** ➡️ **Edge Certificates**: Minimum TLS Version: **TLS 1.2**;
3. **Network**:
   - Enable **gRPC**
   - Enable **WebSockets**
   - Enable **HTTP/3 (with QUIC)**
   - Enable **0-RTT Connection Resumption**
4. **Rules** ➡️ **Cache Rules (Optional)**:
   - Set **Bypass Cache** on your XHTTP path (prevents streaming responses from chunked buffering).

---

### 1.3 SSL Certificate Issuance

The installer automatically requests certificates using `acme.sh`. To issue certificates in advance with `acme-yg`:

```bash
# Step 1: Free port 80 if occupied
systemctl stop nginx xray 2>/dev/null || true

# Step 2: Run acme-yg script
bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh)

# Step 3: Copy certificates to standard path
mkdir -p /etc/ssl/private
cp -f /root/ygkkkca/reality.example.com/fullchain.cer /etc/ssl/private/fullchain.cer
cp -f /root/ygkkkca/reality.example.com/private.key /etc/ssl/private/private.key
chmod 600 /etc/ssl/private/*.key
```

---

## 2. One-Command Deployment

### 2.1 Interactive Deployment

Log in to your VPS terminal as root:

```bash
sudo -i
curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh -o ~/install.sh
bash ~/install.sh
```

Follow the prompts to enter:
1. **Reality / Direct domain** (e.g. `reality.example.com`)
2. **CDN domain** (e.g. `cdn.example.com`)

---

### 2.2 Zero-Interaction Environment Variable Deployment

Recommended single-line positional parameter installation:

```bash
sudo bash <(curl -fsSL https://github.com/ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned/releases/latest/download/install.sh) AUTO=1 REALITY_DOMAIN="reality.example.com" CDN_DOMAIN="cdn.example.com" NODE_TAG="vps"
```

> **If the CDN domain is proxied by Cloudflare (orange cloud), append `CF_Token="<API Token>"`** (Zone.Zone read + Zone.DNS edit): certificates are issued and renewed via DNS-01, no port 80 and no nginx stop on renewal. Without it the installer uses standalone (HTTP-01), which fails to renew once the CDN is proxied; on existing installs run `CF_Token=<API Token> xh cert dnscf`, and check with `xh cert show` / `xh diag`.


#### Core Environment Variables

| Variable | Default | Description |
| :--- | :---: | :--- |
| `AUTO` | `0` | Set `1` for automated non-interactive install. |
| `REALITY_DOMAIN` | — | **Direct / Reality domain** (Cloudflare Grey Cloud). |
| `CDN_DOMAIN` | — | **CDN proxied domain** (Cloudflare Orange Cloud). |
| `FEATURE_AUTO_TUNING` | `true` | Enables BBR+fq, 64MB buffers, 1048576 handles, etc. |
| `FEATURE_XPADDING` | `true` | Enables XHTTP traffic padding to eliminate length fingerprints. |
| `FEATURE_CDN_ECH` | `false` | Cloudflare ECH (Encrypted SNI). Requires CF ECH enabled. |
| `FEATURE_CDN_H2` | `true` | Enables TCP(h2) node over CDN (VLESS-XHTTP-CDN-H2, enabled by default). |
| `FEATURE_CDN_H3` | `true` | Enables QUIC(h3) node over CDN (VLESS-XHTTP-CDN-H3, enabled by default). |
| `FEATURE_H3_DIRECT` | `true` | Enables direct HTTP/3 (QUIC) node (UDP `H3_PORT`, enabled by default). |
| `FEATURE_REALITY_UP_CDN_DOWN` | `true` | Enables split-routing node (Up via Reality / Down via CDN, enabled by default). |
| `FEATURE_HY2` | `false` | Hysteria2 master switch (not installed by default; enable via `xh hy2 on`). |
| `FEATURE_HY2_OBFS` | `false` | Hysteria2 Salamander obfs node (needs Hysteria2 first, default off; enable via `xh hy2 obfs on`). |
| `HY2_PORT` | `random` | Hysteria2-Obfs node UDP port (random port in 10000-65000, customizable). |
| `HY2_H3_PORT` | `random` | Hysteria2 direct node UDP port (random port in 10000-65000, customizable). |
| `XRAY_DEFAULT_VERSION` | `26.9.30` | Default Xray-core release version, supporting XDRIVE, MASQUE and performance optimizations. |
| `FEATURE_BRUTAL` | `true` | Enables TCP Brutal congestion control (95% host speed). |
| `REALITY_MIN_CLIENT_VER` | `1.8.0` | Minimum client version compatibility (`1.8.0` for Mihomo/Clash/sing-box). |

---

## 3. Resident Management Command `xh`

Run `xh` directly in terminal to open the interactive management menu:

```text
=== xray-xhttp Management Menu ===
  1) Service & Tuning Status     16) CDN TCP(h2) Node Switch
  2) Node Parameters & Config    17) CDN QUIC(h3) Node Switch
  3) Subscription & QR Code      18) Outbound Filter (Block CN/Ads)
  4) Restart Services            19) Reality maxTimeDiff Check
  5) View Logs (xray)            20) Spare XHTTP-Direct-H2 Node
  6) Update Xray-core            21) Hysteria2 & Obfs Management (hy2)
  7) System Layer Tuning         22) MASQUE Standard L3 Tunnel (masque)
  8) TCP Brutal Acceleration     23) XDRIVE Cloud Storage Proxy (xdrive)
  9) Daemon Keepalive Switch     24) Finalmask Noise exp Obfs (noise)
 10) Weekly Core Auto-Update     25) Reality-Up / CDN-Down Split Node
 11) UDP Diagnostics (diag)      26) Spare CDN-Up / Reality-Down Node
 12) sysctl Conflict Check       27) Regenerate All Subscriptions (resub)
 13) Reality Compatibility (1.8) 28) Certificate Mode / DNS-01 (cert)
 14) CDN ECH Encrypted SNI Switch 29) Nginx Version Check & Upgrade (nginx)
 15) TCP ECN Congestion Switch  30) Uninstall
                                 0) Exit
```

#### Complete CLI Shortcuts Matrix (Non-Interactive)

| Category | Command | Menu # | Description |
| :--- | :--- | :---: | :--- |
| **Status & Subs** | `xh status` | 1 | Show service status, listening ports, TCP/BBR tuning stats & versions |
| | `xh info` | 2 | Show node parameters, raw links, and client configurations |
| | `xh sub` | 3 | Show subscription URLs and terminal QR codes |
| | `xh resub` | 27 | Regenerate all subscription files based on current configuration |
| | `xh diag` | 11 | Perform server-side UDP/HTTP3 and certificate connectivity diagnostics |
| | `xh conflict` | 12 | Check for conflicting or overriding sysctl settings |
| | `xh version` | — | Display Xray-core and xh management script versions |
| **Operations** | `xh start` \| `stop` \| `restart` | 4 | Start, stop, or restart all core services |
| | `xh log [xray\|nginx] [lines]` | 5 | View real-time service and connection logs |
| | `xh update [<ver>] [--auto]` | 6 | Update or install specific Xray-core version (auto-rollback on check failure) |
| | `xh keepalive [on\|off\|show]` | 9 | Service watchdog daemon and automatic crash recovery switch |
| | `xh autoupdate [on\|off\|show]` | 10 | Weekly scheduled Xray-core auto-update switch |
| | `xh cert [show\|dnscf]` | 28 | Show cert renewal mode / switch to Cloudflare DNS-01 |
| | `xh nginx [show\|check\|update]` | 29 | Check Nginx mainline version and perform smooth upgrade (PGP-verified) |
| | `xh guard` | — | Health check & self-healing daemon runner (invoked by cron) |
| | `xh uninstall` | 30 | Completely uninstall all components and purge configurations |
| **Network & Tuning** | `xh tuning [show\|on\|off\|win\|mac\|linux\|sb]` | 7 | System BBR+fq tuning / output client-side acceleration commands |
| | `xh brutal [show\|on\|off\|speed]` | 8 | TCP Brutal congestion control switch / rate adjustments |
| | `xh minversion [show\|on\|off\|<ver>]` | 13 | Reality minimum client version control (default 1.8.0 for Clash/sing-box) |
| | `xh ech [show\|on\|off]` | 14 | Cloudflare CDN ECH (Encrypted SNI) switch & subscription sync |
| | `xh ecn [show\|on\|off]` | 15 | TCP ECN (Explicit Congestion Notification) switch and status |
| | `xh block [show\|cn on\|off\|ads on\|off]` | 18 | Outbound routing filter: block Mainland China IPs / Ads domains |
| | `xh timediff [show\|on [ms]\|off]` | 19 | Reality client-server maxTimeDiff tolerance control |
| | `xh noise [show\|on\|off\|set <exp>]` | 24 | Finalmask Noise exp dynamic obfs (anti-DPI AWG expression templates) |
| **Node Switches** | `xh cdnh2 [show\|on\|off]` | 16 | Enable / disable CDN TCP(h2) node |
| | `xh cdnh3 [show\|on\|off]` | 17 | Enable / disable CDN QUIC(h3) node |
| | `xh h2direct [show\|on\|off]` | 20 | Enable / disable spare direct TCP node (XHTTP-Direct-H2) |
| | `xh hy2 [show\|on\|off]` | 21 | Hysteria2 direct node master switch (random high UDP port, not installed by default) |
| | `xh hy2 obfs [show\|on\|off]` | 21 | Enable / disable Hysteria2-Obfs obfuscated node (alias: `xh hy2obfs`) |
| | `xh masque [show\|on\|off]` | 22 | Enable / disable MASQUE standard L3 tunnel (RFC 9484 CONNECT-IP, UDP random high port) |
| | `xh xdrive [show\|setup\|on\|off]` | 23 | Configure / enable XDRIVE cloud storage proxy (Google Drive relay, zero public IP) |
| | `xh split [show\|reality-up\|cdn-up]` | 25, 26 | Split-routing node switches (Reality-up enabled by default) |

---

## 4. Client Tuning Guide for Gigabit Networks

For high-BDP transoceanic gigabit links, apply client network tuning:

- **Windows 10 / 11 (Admin PowerShell)**:
  ```powershell
  irm https://reality.example.com/sub/<Token>/win.ps1 | iex  # Or run "xh tuning win" on server
  ```
- **macOS (Terminal - expand socket buffer to 32MB)**:
  ```bash
  sudo sysctl -w kern.ipc.maxsockbuf=33554432 net.inet.tcp.recvspace=4194304 net.inet.tcp.autorcvbuf=1 net.inet.tcp.autorcvbufmax=33554432 net.inet.tcp.fastopen=3
  ```
- **Linux Client**:
  ```bash
  sudo sysctl -w net.core.rmem_max=67108864 net.ipv4.tcp_rmem="4096 262144 67108864" net.ipv4.tcp_fastopen=3
  ```

---

## 5. Node Topology & Dual-Track Architecture

```mermaid
flowchart TD
    Client[Client Device] --> Router{Routing / URL-Test}
    
    subgraph Scenario B: Extreme Performance (Daily 90% Traffic)
        Router -->|Ultra-low latency direct| Reality[VLESS-Reality-Vision<br>TCP 443 Splice Zero-Copy]
        Router -->|High throughput loss resistance| Hy2[Hysteria 2<br>UDP 443 Brutal Engine]
        Reality --> VPS[VPS Origin Real IP]
        Hy2 --> VPS
    end
    
    subgraph Scenario A: Disaster Recovery & Unblocking
        Router -->|Anti-censorship / Hide Origin| XHTTP[VLESS-XHTTP<br>TCP/UDP 443 xmux Multiplex]
        XHTTP --> CF[Cloudflare CDN Edge]
        CF -->|HTTP/2 Stream Back-to-Origin| Nginx[Nginx grpc_pass<br>Zero-buffer pass-through]
        Nginx --> XrayInbound[Xray Local 8001 Inbound]
    end
```

| # | Node Name (v4.9.78) | Transport | Topology | Highlights |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-CDN-H3` | XHTTP (h3/QUIC) + vlessenc | Via CDN UDP 443 | QUIC to the Cloudflare origin |
| **2** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | Direct UDP 8446 | Direct QUIC, `mode=stream-up` |
| **3** | `Hysteria2-H3-Direct` | Hysteria 2 | Direct random high UDP port | Standard HTTP/3 shape, fastest downlink measured (v4.9.26) |
| **4** | `Hysteria2-Obfs-Direct` | Hysteria 2 + salamander | Direct random high UDP port | Obfuscated variant for networks that fingerprint QUIC |
| **5** | `VLESS-Reality-Vision-Direct` | VLESS-Reality | Direct TCP 443 | **xtls-rprx-vision zero-copy**, fastest single stream |
| **6** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | Direct TCP 443 | Reality camouflage + XHTTP padding |

> Not installed by default; switch on with `xh` (every one has a menu item): `VLESS-XHTTP-CDN-H2` (`xh cdnh2 on`, TCP fallback through the CDN), `VLESS-Reality-Up-CDN-Down` (`xh split reality-up on`, client-link only), `VLESS-CDN-Up-Reality-Down` (`xh split cdn-up on`), `VLESS-XHTTP-Direct-H2` (`xh h2direct on`), `MASQUE-CONNECT-IP` (`xh masque on`), `XDRIVE-Google-Drive` (`xh xdrive setup` / `on`) and Finalmask Noise exp (`xh noise on`). Hysteria2 is installed by default; turn it off with `xh hy2 off` (the obfs node goes with it) or only the obfs node with `xh hy2 obfs off`.

---

## 6. Troubleshooting & FAQ

| Symptom | Root Cause | Quick Solution |
| :--- | :--- | :--- |
| **Reality node fails to connect** | Client system clock offset > 30s | Enable "Set time automatically" in OS settings (replay defense) |
| **Mihomo split-routing error** | Mihomo inherits parent Reality config | Explicitly declare `reality-opts: { public-key: "" }` in `download-settings` |
| **Direct UDP / Hysteria 2 timeout** | Cloud firewall / Security Group blocking | Allow inbound UDP 443 / 8443 / 8446 and TCP 443 / 8445 in cloud dashboard |
| **Kernel parameters conflict / overwritten** | External script injected `/etc/sysctl.d/` | Run `xh conflict` to automatically detect and heal sysctl conflicts |

---

## 7. Release History & Core Tuning Evolution (v4.8 - v4.9.51)

After dozens of iterative rounds across high-latency cross-Pacific topologies (160ms+ / 1% packet loss), core technical milestones are summarized below:

| Area | Versions | Technical Strategy & Tuning Findings |
| :--- | :--- | :--- |
| **Comprehensive Upgrade to Xray-core v26.9.30: XDRIVE Cloud Storage Proxy, MASQUE & Radical Memory Optimization** | v4.9.74 | 1. **Core Upgrade**: Default core and host updated to Xray-core latest release v26.9.30; 2. **Cutting-Edge Protocol Support**: Introduced XDRIVE transport for extreme IP whitelist bypass via Google Drive relays, standard IETF MASQUE (RFC 9484 CONNECT-IP) L3 tunneling, and Finalmask Noise dynamic expression template obfuscation; 3. **High Performance**: Geodata MPH matcher refactored with 60%–75% reduction in runtime memory usage and GC latency down to 0.04ms; 4. **Hardened Security**: Integrated Windows WFP kernel anti-leak protection (`autoSystemWfpBlockLeak`) against multi-adapter DNS leaks, aligned FakeIPv6Pool with RFC 5180 `2001:2::/48` to suppress Chrome 141+ PNA warnings. |
| **Official Stable Core Invariant** | v4.9.8–v4.9.18 | Strictly locked to `releases/latest` (v26.3.27), eliminating pre-release MLKEM768 handshake failures; sanitized subscriptions for third-party clients. |
| **Split-Routing Topology** | v4.9.19–v4.9.29 | Deployed Reality-Up-CDN-Down (0-RTT direct up + CDN full speed down) and CDN-Up-Reality-Down; solved Mihomo shallow copy bug; enabled vlessenc on 8001 against CDN eavesdropping. |
| **Network & Flow Optimization** | v4.8.x–v4.9.30 | Coordinated BBRv3 with TCP Brutal (locked to 3800 Mbps); maintained **64MB** socket buffer ceiling; RPS/RFS multi-queue softirq balancing; TLS 1.3, TFO, and ECH/ECN integration. |
| **End-to-End Security & Anti-Flood** | v4.9.17–v4.9.33 | Disabled high-risk wide port hopping by default, converging on single-port Hy2 (UDP 443); Netfilter hashlimit token bucket anti-flood; `fs.suid_dumpable=0`; reserved port protection. |
| **Slowdown Review** | v4.9.34 | All-node re-bench (netns 160ms/1% loss, 300↓/50↑): no server-side regression (Vision 124↓ vs 119 on 9-23); 443 inbound brutal vs bbr 120/112 and 146/142 overlap → keep brutal; upload via CF is a flat 10 Mbps on h2 vs 34 on h3 → `CDN-Up-Reality-Down` upload leg back to h3; `tools/xray_rtt_bench.py` no longer rewrites CDN nodes to the local address (which bypassed CF and made CDN-H3 hit the Hy2 UDP 443 inbound). |
| **Topology Streamlining** | v4.9.35 | Streamlined default installation by removing `VLESS-XHTTP-CDN-H2` (10M upload ceiling) and `VLESS-Reality-Up-CDN-Down` from default setup; focused on 6 high-performance core nodes. |
| **Split-Routing Optimization** | v4.9.36 | Swapped split routing node to `VLESS-Reality-Up-CDN-Down` (Reality Direct Up + CDN H2 Down) to replace CDN-Up-Reality-Down as one of the 6 core pillars; resolved missing downloadSettings extra parameter without xpadding. |
| **Credential Injection Hardening** | v4.9.37 | Added `rawurlencode` definition and `HY2_PASSWORD` fallback to client config generation, fixing dropped/unauthenticated Hysteria 2 nodes during standalone generation or subscription refresh. |
| **CDN-H2 Default Restored** | v4.9.38 | Restored `VLESS-XHTTP-CDN-H2` to default enabled (7 core nodes in total), providing an out-of-the-box TCP escape hatch during UDP 443 QoS throttling or ISP blocks. |
| **CDN-H3 Default Streamlined** | v4.9.39 | Pruned `VLESS-XHTTP-CDN-H3` by default (converging to 6 core pillar nodes) to prevent Cloudflare edge UDP 443 QoS throttling and jitter; retained `FEATURE_CDN_H3` and `xh cdnh3` for on-demand activation. |
| **HTTP/1.1 Fully Deprecated** | v4.9.40 | Purged `http/1.1` from server inbounds, client URIs, and Mihomo configs, strictly enforcing modern multiplexed ALPN (`h2` / `h3`) to eliminate protocol downgrade and head-of-line blocking; synchronized with sbbox v2.7.24. |
| **Nginx Fallback Loopback & Routing Optimization** | v4.9.41 | Bound Nginx camouflage port 8003 strictly to `127.0.0.1:8003` to prevent public exposure and scanner probing; enhanced Mihomo routing rules by fixing iCloud misrouting to Microsoft services and adding dedicated `iCloud Services` proxy group and Microsoft rule set. |
| **Complete ALPN Purification** | v4.9.42 | Completely eliminated legacy `http/1.1` from manage CLI commands (`xh cdnh2`/`cdnh3`), client example templates, and benchmark scripts, strictly locking the multiplexed ALPN floor to HTTP/2 (`h2`) and HTTP/3 (`h3`) to avoid any accidental protocol fallback. |
| **Split-Routing Deprecated by Default** | v4.9.43 | Deprecated `VLESS-Reality-Up-CDN-Down` from default installation to converge on 5 core high-performance nodes, significantly reducing multi-path connection overhead; preserved `FEATURE_REALITY_UP_CDN_DOWN` flag for on-demand use. |
| **fq Qdisc Persisted Across Reboots** | v4.9.44 | Fixed fq being lost on reboot: `net.core.default_qdisc=fq` only applies to qdiscs created afterwards, and the NIC exists before sysctl.d is loaded, so after a reboot the egress NIC was actually `mq` + `pfifo_fast`; fq, `initcwnd 32`, `txqueuelen` and RPS/RFS used to run only once during `xh tuning on`. They are now written to `/usr/local/sbin/xray-xhttp-nic-tune` + `xray-xhttp-nic.service` (OpenRC: `/etc/local.d`) and re-applied at boot; `xh tuning off` and uninstall remove them. Single-core hosts now get fq too (RPS still multi-core only). Verify with `tc qdisc show dev <nic>` (expect `fq` under `mq`), not with sysctl. The co-hosted sbbox adds the same in v2.7.32; both now use mq + per-queue fq, so whichever runs last yields the same result. Also fixed `xh version` falsely reporting an updated xh because the node.env value is quoted. **Not adopted**: switching the 443 Reality inbound from Brutal back to BBR — with retransmissions measured (netns 160ms, N=3): 1% loss 300↓/50↑ 121 vs 108 Mbps, retrans 1.33% vs 0.71%; 0% loss 300↓/50↑ 143 vs 130, 0.86% vs 0.06%; 100↓/20↑ 71 vs 69, 0.06% vs 0.01%. Brutal is no slower and does not flood the line, so it stays. |
| **Certificate Renewal via DNS-01** | v4.9.45 | Fixed **certain auto-renewal failure** once the CDN domain is proxied by Cloudflare: the installer only used standalone (HTTP-01); issuance succeeds while the CDN record is still DNS-only, but afterwards CF's Always Use HTTPS 301-redirects the challenge to https and back to origin 443 (Reality / camouflage site), and the pre-hook even stops nginx — renewal fails silently, and on expiry the CDN returns 526 and h3-direct / hy2 handshakes fail. Passing `CF_Token` at install now issues with `dns_cf` (acme.sh saves the token for renewals). New `xh cert [show\|dnscf]` shows / switches the renewal mode (validates the token against the zone via the CF API first; the token reaches curl via stdin, never argv). `xh diag` now flags "standalone + CDN proxied". Verified with a full LE-staging `--renew` on a copy of the real config. The co-hosted sbbox adds DNS-01 issuance and automatic renewal-hook installation in v2.7.33. |
| **tcp-brutal 2.0.1** | v4.9.46 | Upstream tcp-brutal 2.0.1 handles the new-kernel `tso_segs` hook itself (`BRUTAL_HAVE_TSO_SEGS`, detected from the target kernel headers), so `patch_tcp_brutal_tso_segs` now skips such sources. The patch wired the new hook to `min_tso_segs`, which always returns 2, while `tso_segs` returns the burst size — capping TSO at 2 segments on 7.1+ kernels; upstream returns a rate-based estimate. On the stock 7.0 kernel (`min_tso_segs` path) runtime behaviour is unchanged (Reality-Vision 160ms/1%, 300↓/50↑: 121 → 129 Mbps, overlapping). The co-hosted sbbox adds the same in v2.7.34. |
| **Update Notices & Verified Manual Updates (nginx / tcp-brutal)** | v4.9.47 | The weekly `xh update --auto` now also **checks only** for new nginx mainline and tcp-brutal releases: notices go to `/etc/xhttp-cdn/updates-available` and are shown at root login and in `xh status`; **nothing is installed automatically** (log: `journalctl -t xh-autoupdate`; existing cron lines keep working). Manual updates: `xh nginx update` downloads the source and `.asc`, imports the release keys from nginx.org and verifies the signature, requiring the signer's primary fingerprint to be one of 4 pinned nginx developer fingerprints, then builds with the host's own `nginx -V` configure arguments, tests the live config with the new binary, swaps it and re-checks port 8003, rolling back on failure. `xh brutal update [--now]` requires the tarball's sha256 to match both the publisher's `hashes.txt` and GitHub's independently computed asset digest, and only builds into DKMS (active on next boot); `--now` / `xh brutal reload` reloads immediately (Xray stops for a few seconds). Tested: tampered downloads, missing checksums and unpinned signers are all rejected; a full sandboxed nginx update took 28 s with identical configure arguments. The co-hosted sbbox adds notices and verified updates for external Hysteria2 and tcp-brutal in v2.7.35. |
| **Server DNS Reordered by CDN Edge Proximity · Useful Bits of a Third-Party Tuner Absorbed** | v4.9.48 | **DNS**: Xray's built-in DNS now prefers `9.9.9.10` (Quad9, unfiltered), then `1.1.1.1`. Resolution time is paid once per domain, but the CDN edge it returns sets the latency of every later connection. On this host, 32 popular domains × 3 queries each, domains whose edge was more than 3 ms slower than the best: 8.8.8.8 10, 1.1.1.1 5, 9.9.9.10 only 1 (Akamai-hosted Apple / iCloud / Microsoft differ by 10–50 ms; 8.8.8.8 sends ECS and still picks farther edges). Uncached resolution for 9.9.9.10 is on par with 1.1.1.1 (2–9 ms). **System tuning**: `net.core.rmem_max / wmem_max` reduced from 128 MB to 64 MB (same as the `tcp_rmem / wmem` ceiling); new `vm.min_free_kbytes` (64 MB on the large tier, 32 MB on medium, headroom for atomic allocations in softirq at high packet rates) and `kernel.sched_autogroup_enabled = 0`; `nf_conntrack` is listed in `/etc/modules-load.d/xray-xhttp-conntrack.conf`, because at boot systemd-sysctl runs before iptables / Docker load the module and `nf_conntrack_max` is silently skipped (removed by `tuning off`); `kernel.core_pattern = core` is now written by the tuning code (it was only mentioned in comments and added by hand, so re-running `tuning on` dropped it). These are the non-conflicting parts of a third-party one-click tuner (vps-tcp-tune). Not adopted: `udp_rmem_min 8192`, `somaxconn 4096`, `notsent_lowat 16384` conflict with existing values; its boot-time single root `fq` would replace `mq` + per-queue fq; system DNS over TLS made no measurable difference to uncached lookups (9–25 ms); THP never / `overcommit_memory=1` / dirty ratios bring nothing to a forwarding host. **Handshake measurement**: new `tools/xray_handshake_bench.py` (netns with pure RTT; per node it measures cold start, warm connection and first request after idle, in RTT units; supports Xray / sing-box / mihomo clients). At 160 ms: Hy2 / XHTTP / AnyTLS / TUIC / naive warm connections all take 1.0 RTT, already the floor; Vision needs 3 RTT per connection (no multiplexing; client TFO was negotiated but saved nothing end to end); XHTTP nodes take one extra RTT on cold start because VLESS Encryption has no ticket yet and falls back to 1-RTT, inherent to the protocol. **Client note**: Xray-core as a Hysteria2 client sends no QUIC keep-alives by default, so the tunnel drops after 65 s idle and the next request costs 2 extra RTT (~330 ms); sing-box / mihomo clients are unaffected. Server-side `finalmask.quicParams.keepAlivePeriod` was tested and has no effect, so it is not used; in v2rayN keep Hysteria2 on its default sing-box core. Re-run: `python3 tools/xray_handshake_bench.py 160 3 65,200,700`. The co-hosted sbbox adds the 64 MB change and the three system settings in v2.7.37, and moves sing-box's and the external Hysteria2's outbound DNS to 9.9.9.10 as well. |
| **Xray-core Client Hysteria2 Idle Disconnect Fixed** | v4.9.49 | The `Hysteria2-H3-Direct` link now carries an `fm` parameter (the finalmask JSON understood by v2rayN / v2rayNG) that turns on QUIC keep-alive `keepAlivePeriod: 10` for Xray-core clients. **Root cause** (v26.3.27 source): in the client's `transport/internet/hysteria/dialer.go` the 10 s default keep-alive is commented out, so `KeepAlivePeriod` is 0; the server's `hub.go` never passes `KeepAlivePeriod` to its QUIC config at all (which is why the inbound keep-alive tried in v4.9.48 had no effect); the idle timeout is the smaller of both sides, 30 s. So when v2rayN runs Hy2 on the Xray core, the tunnel drops after 30 s idle and the next request redoes the QUIC handshake and auth, costing 2 extra RTT. **Measured** (`tools/xray_handshake_bench.py`, 160 ms RTT): first request after 65 s idle 3.1 → 1.0 RTT, after 200 s 3.2 → 1.0 RTT, matching the sing-box client; shaped throughput (160 ms / 1 % loss, 300↓/50↑, the two variants in separate processes, alternated 2 × 3 runs each, re-measured in v4.9.50) downlink medians 127 / 132 vs 127 / 130 and uplink 41 for both, no effect. **Compatibility**: v2rayN (7.24.9 source) and v2rayNG (2.2.6) **replace** the finalmask they build from `upmbps` / `downmbps` with `fm` wholesale, so `fm` reproduces that part (`congestion: brutal` plus the declared bandwidth, or `bbr` when none is declared); both keep their own config if the JSON is invalid. v2rayN's sing-box core, mihomo and the official Hysteria client ignore the parameter; `fm` is stripped when the Shadowrocket subscription is generated (`shadowrocket.txt` is byte-identical to before), and the Mihomo subscription is unchanged. It is added only to the H3 node without obfuscation or port hopping: replacing the finalmask of the salamander `Hysteria2-Obfs-Direct` (off by default) would drop its obfuscation mask. `tools/xlinks.py` now parses `fm` the same way v2rayN does. On an existing install, add `fm` to the Hy2-H3 line of `client-config.txt` before `xh resub` (or re-run the installer); clients pick it up after refreshing the subscription. |
| **Keep-Alive for the Obfuscated Node Too · Benchmarks Fixed for Xray Hy2 Connection Sharing** | v4.9.50 | **Obfuscated node**: the `Hysteria2-Obfs-Direct` link (off by default) now carries `fm` as well. v2rayN / v2rayNG replace their own finalmask with `fm` wholesale, so besides `quicParams` (brutal + declared bandwidth + `keepAlivePeriod: 10`) it reproduces `udp: [{type: salamander, settings: {password}}]`, plus `udpHop: {ports: mport, interval: "30"}` when port hopping is on (the default interval in both clients' source). The builder is now `hy2_client_fm_param`; the H3 node's output is byte-identical to v4.9.49, and no `fm` is emitted if a password contains `"` or `\` (old behaviour). Measured against a temporary obfuscated server at 160 ms RTT: first request after 65 s / 200 s idle 3.1 → 1.0 RTT; the negative controls ("`fm` without the obfuscation mask", "wrong obfs password", "no obfuscation") all fail to connect. **Benchmarks**: Xray's hysteria client caches connections globally by destination IP:port (`manger.m[addr]` in v26.3.27 `dialer.go`), so several Hy2 outbounds to the same server in one process share the first outbound's connection and config. The same-process throughput A/B done before v4.9.49 was therefore invalid (re-measured in separate processes here, and the row above is corrected), and a same-process "broken" variant would even appear to connect. `tools/xray_handshake_bench.py` now runs each Xray variant in its own process and accepts a `uri` variant key; `tools/xray_rtt_bench.py` refuses to run several Hy2 variants that share an address; the handshake tool's cleanup no longer uses a broad `pkill -f` (it could kill the calling shell) and only matches its own temp dir; `tools/xlinks.py` gains `parse_link` for a single link. |
| **Cap NIC MTU at 1500 (PMTU black-hole safeguard)** | v4.9.51 | Some clouds default the NIC to MTU 9000 (jumbo frames) while the public path is 1500: the server emits TCP segments above 1500 bytes (e.g. a 3.7 KB TLS certificate chain) that are silently dropped at the edge, so the TCP handshake succeeds but TLS times out or resets — Reality / CDN-origin TCP nodes all fail while QUIC nodes (packets < 1280) work. The boot-time `xray-xhttp-nic-tune` now lowers an MTU above 1500 to 1500 and adds `TCPMSS --clamp-mss-to-pmtu` (mangle POSTROUTING, v4/v6, not duplicated, saved via `netfilter-persistent save`); the firewall is touched only when the MTU was actually lowered. This host's `enp0s6` is 1480, so nothing changes here. Verified in a netns: veth MTU 9000 → 1500 with a single rule, no duplicate on re-run, MTU 1400 left alone. The co-hosted sbbox adds the same in v2.7.38. |
| **Default CDN Node Switched to CDN-H3** | v4.9.52 | The first node installed by default is now `VLESS-XHTTP-CDN-H3` (UDP 443 / QUIC via CDN) instead of `VLESS-XHTTP-CDN-H2`: `FEATURE_CDN_H3` defaults to `true` and `FEATURE_CDN_H2` to `false`, synchronized across the installer, client config generation, node env file and `xh cdnh3` fallbacks; README node table and command list updated. If UDP 443 is throttled or blocked, enable the TCP(h2) fallback node with `xh cdnh2 on` or `FEATURE_CDN_H2=true`. |
| **Outbound filter switches (`xh block`)** | v4.9.53 | Modeled on the optional rules in zxcvos/Xray-script: new **default-off** `xh block cn on\|off` (reject CN IPs via freedom `finalRules`, evaluated after domain resolution) and `xh block ads on\|off` (routing rule for `geosite:category-ads-all`). Each rule is a single line tagged `xh-block-*`, so toggling only adds or removes that line; the config is checked with `xray -test` first and rolled back on failure; state is kept in `node.env` (`FEATURE_BLOCK_CN` / `FEATURE_BLOCK_ADS`) across reinstalls. Menu item 18 added (uninstall moves to 19) and the `xh tuning` prompt now lists win / mac / linux / sb. Blocking CN IPs breaks clients that use this proxy to reach mainland sites, so enable it only when the exit does not need that traffic. |
| **Reality time-diff check and spiderX (`xh timediff`)** | v4.9.54 | Per the XTLS/REALITY README: new **default-off** `xh timediff on [ms]\|off` (Reality `maxTimeDiff`, default 60000, replay protection; clients whose clock is off by more than that cannot connect, so enable automatic time sync). The config is checked with `xray -test` first and rolled back on failure; `REALITY_MAX_TIME_DIFF` is kept in `node.env` across reinstalls. Client Reality links now carry `spx` by default (derived from the UUID, different per deployment, disable with `FEATURE_REALITY_SPX=false`). Menu item 19 added (uninstall moves to 20). |
| **Xray inbounds and outbound drop tcpMptcp (TFO only)** | v4.9.55 | The same A/B benchmark as sbbox was run on an Xray Reality inbound (4 tfo / mptcp server variants x 3 client variants, 2ms and 160ms RTT with 0.5% loss per direction, fetching `http://www.apple.com` through the proxy): on Xray **no combination timed out** and TFO showed no measurable latency gain; throughput was within noise, and an MPTCP client was slower on a short path (upload about 1.5 vs 1.9-2.0 Gbps). Go 1.24+ listeners enable MPTCP by default, so setting it explicitly adds nothing. The Reality / XHTTP / XHTTP+TLS inbounds and the freedom outbound therefore drop `tcpMptcp`, and the mihomo Reality node drops `mptcp: true`, matching sbbox's TFO-only policy (the freedom outbound change was not benchmarked separately). Existing installs need their config regenerated. |
| **Platform-aware defaults (ARM / AMD) and rollback of the tcpMptcp change** | v4.9.56 | At install time the platform is detected and printed: architecture (aarch64 / x86_64), CPU, cores, memory, kernel, virtualization and cloud provider (from DMI: Oracle / AWS / GCP / Azure / Alibaba). With under 1.5GB of RAM (e.g. Oracle free-tier AMD 1GB) TCP Brutal is not installed by default (it builds a kernel module on the spot, which is memory-hungry and slow; an explicit `FEATURE_BRUTAL=true` is still honored), a swap hint is shown when there is none, and xray gets a `GOMEMLIMIT` (60% of RAM). `python3` is installed and required commands are checked (without it `xh minversion` / `ech` / `block` / `timediff` and similar commands fail silently). **Rolls back v4.9.55**: that benchmark only covered the Reality inbound, where no combination timed out and none showed a measurable gain; the other inbounds, the freedom outbound and the mihomo change were an extension that was never measured on its own, so everything returns to the original `tcpMptcp` and is left alone. |
| **Mihomo TUN adapts to the client platform** | v4.9.57 | The subscription directory gains `mihomo-full-windows.yaml` / `-linux.yaml` / `-macos.yaml` / `-android.yaml`, changing only TUN fields that really differ: Windows enables `strict-route`; Linux enables `strict-route` + `auto-redirect`; macOS / Android keep the base values (macOS has no strict-route, Android routing is owned by the system VPN). The original `mihomo-full.yaml` is unchanged; install and `xh resub` both generate them |
| **All XHTTP nodes use mode stream-up** | v4.9.58 | As requested, CDN-H2 / CDN-H3 and the remaining `auto` nodes (Reality-XHTTP, CDN/Reality split nodes) now carry `mode=stream-up` in client links and the Mihomo subscription (direct nodes already did). Measured with Cloudflare gRPC / WebSockets on (one 20MB upload per run, very small sample): stream-up works and downloads are unaffected, but 2 of 6 uploads did not complete (0/6 for auto) and H3 upload is low and erratic. If uploads stall on some network, change that node's `mode=stream-up` back to `auto`; no server change needed. Installed boxes must refresh `client-config.txt` and the Mihomo files before `xh resub` |
| **Disable nginx and Xray access logs by default** | v4.9.59 | nginx `access_log` was on at http level (only some locations turned it off), so visitor IPs, subscription token paths and User-Agents landed in `access.log`. Now `access_log off` globally, nginx `error_log` `notice`→`error`, and Xray gets `"access": "none"` plus `loglevel: error`. **Fresh installs only**: installed boxes must hand-edit `/etc/nginx/nginx.conf` and `/usr/local/etc/xray/config.json` (reload after `nginx -t` / `xray -test`); an existing `access.log` is not cleaned. No transport parameters changed. |
| **Download leg and server mode unified to stream-up** | v4.9.60 | As requested, the `downloadSettings` leg of Reality/CDN split nodes (including the dual-cdn / dual-ip / quic-h3 extensions) and the server-side xhttpSettings `mode` move from `auto` to `stream-up`, matching the upload leg. **Not measured** (same trade-off as v4.9.58; if uploads/downloads stall, set the relevant `mode` back to `auto`). Installed boxes must hand-edit `"mode": "auto"` in `/usr/local/etc/xray/config.json`, `xray -test`, then restart; the upload-leg `mode=auto` in the extensions' own node links was not changed. (since v4.9.66 the CDN legs are back to auto) |
| **All nodes: upload and download mode unified to stream-up** | v4.9.61 | The CDN split-node download `xhttpSettings` in `src/11-client-config.sh` and the leftover `mode=auto` in node links / Mihomo snippets of the dual-cdn, dual-ip, quic-h3 and common-nodes extensions now use `stream-up`; no `auto` remains in the scripts. **Not measured**; if a node stalls, set its `mode` back to `auto` (no server change needed). (since v4.9.66 the CDN legs are back to auto) |
| **nginx: allow TLS1.2, tickets off, no explicit buffering-off on the origin leg** | v4.9.62 | As requested: `ssl_protocols` goes from TLS1.3-only to `TLSv1.3 TLSv1.2` (with TLS1.2 `ssl_ciphers`), `ssl_session_tickets` from `on` to `off`; the XHTTP origin location drops `proxy_buffering off` / `proxy_request_buffering off` / `X-Accel-Buffering` (`grpc_pass` ignores `proxy_*` buffering directives, so behaviour is largely unchanged). Side effects: with tickets off, `ssl_early_data` (0-RTT) has no session to resume and stops working; enabling TLS1.2 loosens the former downgrade protection. Installed boxes must hand-edit `/etc/nginx/nginx.conf` and reload after `nginx -t`. **Not measured**. (v4.9.65 also allows TLS1.1) (tickets were turned back on in v4.9.69) |
| **Default 5 nodes; spare nodes switched from the xh menu** | v4.9.63 | The 5 install-time default nodes (Reality-Vision, Reality-XHTTP, XHTTP-Direct-H3, CDN-H3, Hysteria2-H3) were already the source defaults and are unchanged. The remaining spare nodes get xh switches: `xh h2direct` (TCP 8445, adds the server inbound and opens the port), `xh hy2obfs` (UDP 8443 salamander, same), `xh split reality-up|cdn-up` (client links only); menu items 20–23, uninstall moves to 24. How: at install the client files are rendered once more with every spare node enabled and stored in `/etc/xhttp-cdn/all/` (node lines, Mihomo entries, both server inbound texts); the switches only copy from that store, so results match a fresh install exactly. Server inbounds are written between paired `// >>xh:` markers and removed as a block, restoring the config byte for byte. **Boxes installed by an older version have no store** and must be redeployed to get these switches. Cloud security-list rules are still yours to open. Stale wording about "6 core nodes" / "spare" in the cdnh2 / cdnh3 text was fixed. (the default node set changed in v4.9.64) |
| **Default node set changed to the 6 nodes in use** | v4.9.64 | Install-time defaults now follow the nodes actually in use: `FEATURE_HY2_OBFS` defaults to `true` (Hysteria2-Obfs-Direct, UDP 8443), `FEATURE_REALITY_UP_CDN_DOWN` to `true` (Reality-Up-CDN-Down), `FEATURE_CDN_H3` to `false` (CDN-H3 becomes a spare, `xh cdnh3 on`). Defaults: Direct-H3, Hysteria2-H3, Hysteria2-Obfs, Reality-Vision, Reality-XHTTP, Reality-Up-CDN-Down; the other spares are xh switches. Wording about "default / spare" in the xh menu and help was corrected and the README node table updated. **New installs only**; already installed boxes keep their node set. |
| **nginx: TLS1.1 allowed again** | v4.9.65 | As requested `ssl_protocols` is `TLSv1.3 TLSv1.2 TLSv1.1`. OpenSSL 3's default security level rejects 1.1, so `ssl_ciphers` gains four `ECDHE-*-AES*-SHA` CBC suites plus `@SECLEVEL=0`; without them the server answers 1.1 clients with a protocol-version alert. Side effects: `@SECLEVEL=0` applies to all nginx TLS and loosens the minimum key / signature strength checks for 1.2 as well; 1.1's CBC-SHA1 suites are weaker than AEAD. Only the nginx 8003 path (CDN / fallback) is affected; Xray's direct inbounds still pin TLS1.3. Verified locally: 1.1 / 1.2 / 1.3 all handshake. Installed boxes must hand-edit `/etc/nginx/nginx.conf` and reload after `nginx -t`. |
| **Speed instability fix: Hy2 no longer declares Brutal bandwidth, CDN legs back to auto** | v4.9.66 | After a report of slow and unstable speeds, a server-side check (CPU / memory / NIC fine, all connections on BBR, TCP retransmits ~0.9%, no UDP loss) found no bottleneck, so the cause is the client path and node parameters: 1. `HY2_UP_MBPS` / `HY2_DOWN_MBPS` now default to **empty** (was 100 / 1000): links carry no `upmbps` / `downmbps`, `fm` uses BBR, and Mihomo entries drop `up` / `down` — previously sing-box / Mihomo clients sent at the declared rate with Brutal, overshooting a path that could not carry it; set `HY2_UP_MBPS=… HY2_DOWN_MBPS=…` only when you know your line; 2. Every leg that crosses a CDN (CDN-H2 / CDN-H3, the up leg of CDN-Up-Reality-Down, the down leg of Reality-Up-CDN-Down, the dual-cdn / quic-h3 extensions) goes from `stream-up` back to `auto`; direct and Reality legs stay on `stream-up` (basis: the v4.9.58 test, 2 of 6 uploads through Cloudflare did not finish with stream-up vs 0 with auto). Mihomo's split-node download leg has no own `mode`, so it follows its parent. **Not speed-tested**: this rests on the server-side check and earlier tests, not a measurement of your line; if it is still slow, tell me which node, client and ISP. (the CDN upload legs went back to stream-up in v4.9.70) |
| **Review fixes: server 8001 back to auto; switches are atomic and reversible** | v4.9.67 | Fixes after a code review. 1. **Server 8001 inbound `mode` goes from `stream-up` back to `auto`**: v4.9.66 made the CDN legs `auto`, but a `stream-up` 8001 inbound rejects packet-up uploads; tested with a real Xray client, `stream-up` worked and `auto` / `packet-up` failed, and after the change all three work; direct inbounds still accept only `stream-up`; 2. `h2direct` / `hy2obfs` inbounds written at install now carry `// >>xh:` markers so `xh … off` can remove them as a block; when no marker exists but the port is in the config, xh reports an error instead of silently passing; 3. Switch order is now client files (atomic write) → server → flag, and any failure undoes the earlier steps and prints the cause; xray validation output, the rollback restart result and firewall write failures are no longer swallowed; 4. `xh cdnh2` / `cdnh3` take the node from the spare-node store (only old installs use the clone fallback), fixing a wrong clone once CDN-H3 became off by default; 5. The spare-node store is rendered into a temp directory, checked for all 6 nodes, then swapped in; errors go to `/etc/xhttp-cdn/all-render.log`; 6. Menu items 20–23 run in a subshell so one failure no longer closes the menu; 7. Stale comments and text corrected. Limits: the store is an install-time snapshot, so later `xh ech` changes are not copied into it; a node renamed with `NODE_NAME_MAP` makes the switches report an error. |
| **Install robustness: optional inbounds can no longer take Reality down** | v4.9.68 | Report: on a freshly installed Ubuntu / Debian server the Reality node does not work. **The root cause is not confirmed** (no log from the failing machine). This is a defensive fix for one hypothesis: Xray is a single process, so one inbound failing to bind stops all of Xray. 1. The installer now checks the optional inbound ports first: if UDP `HY2_PORT` (Hysteria2-Obfs, on by default since v4.9.64) or TCP `H2_PORT` (h2-direct) is held by another process, that node is turned off with a notice naming the holder; 2. If `xray -test` fails while those two optional inbounds are on, they are turned off and the config is regenerated from the same template and retried, so core nodes (Reality etc.) are unaffected; an error in the core config still aborts; 3. A listening self-check after start: TCP 443 (Reality) and each enabled UDP / TCP node port are checked and a missing one is reported, which separates "server not listening" from "cloud security group not open". If it still fails, run `systemctl status xray`, `journalctl -u xray -n 40`, `xray -test -config /usr/local/etc/xray/config.json`, `ss -ltnup \| grep -E ':443 \|xray'` and `xh diag` on the failing machine and report the output. |
| **nginx: session tickets back on (faster reconnect)** | v4.9.69 | As the user chose, `ssl_session_tickets` goes from `off` back to `on`. A reconnecting client can resume the session, send less certificate data and skip one full handshake; tickets are also required for `ssl_early_data` (0-RTT) and the `Early-Data` header to work, and both were idle since v4.9.62. Verified locally: the second connection shows `Reused` on both TLS1.3 and TLS1.2. Cost: the ticket key lives only inside the nginx process, so old tickets stop working after a restart, and forward secrecy is weaker than with full handshakes. **Not speed-tested**: nginx carries only CDN origin traffic, the subscription and the decoy site (about a fifth of total traffic, very low CPU), so this shortens reconnects and does not raise steady-state throughput. Installed boxes must hand-edit `/etc/nginx/nginx.conf`, then `nginx -t` and reload. |
| **CDN upload legs back to stream-up** | v4.9.70 | After the request to raise CDN throughput, a small comparison: from this server, an Xray client looped back to itself through Cloudflare, 40 transfers each (20 MB down / 10 MB up) with no stall; upload **stream-up ≈ 365–441 Mbps vs auto ≈ 163–261 Mbps (1.7–2.7× faster)**, download similar (≈ 490–640 Mbps). So the upload legs of CDN-H2 / CDN-H3 and CDN-Up-Reality-Down, and of the dual-cdn / quic-h3 extensions, go back to `stream-up`; the **download leg** over CDN (Reality-Up-CDN-Down's downloadSettings) stays `auto`. Server 8001 stays `auto` (accepts every mode). This replaces v4.9.66's "all CDN legs auto", which rested on an earlier test (2 of 6 stream-up uploads through CF did not finish) that did not reproduce after Cloudflare gRPC / WebSockets were turned on. **Limits: it measures this server to Cloudflare only, not the user's client path; the sample is small and noisy (single runs 60–720 Mbps).** The Reality-Up-CDN-Down node in use uploads over Reality and downloads over CDN, so it is not affected. |
| **Default node set: no Hysteria2, two CDN nodes by default; Hysteria2 moves into the xh menu** | v4.9.71 | As requested: 1. The install command **no longer installs Hysteria2 by default**: `FEATURE_HY2` defaults to `false` (Hysteria2-H3 goes with it) and `FEATURE_HY2_OBFS` to `false`; 2. **Both CDN nodes are installed by default**: `FEATURE_CDN_H2` and `FEATURE_CDN_H3` default to `true`; 3. The default set is CDN-H2, CDN-H3, Direct-H3, Reality-Vision, Reality-XHTTP, Reality-Up-CDN-Down (6 nodes); 4. New `xh hy2 [show\|on\|off]` and menu item 24 (uninstall moves to 25): on = add the server inbound + open UDP 443 + add the client node + write the flag, undone on any failure; off also removes the obfs node; `xh hy2obfs on` now needs Hysteria2 first; 5. The Hysteria2-H3 inbound also carries `// >>xh:` markers and the spare-node store gains `inbound-hy2h3.json`; 6. The "already present" check for inbound markers now goes by tag (Hysteria2's UDP 443 shares a number with Reality's TCP 443). Local round trip: `xh hy2 off` (with obfs) → `xh hy2 on` → `xh hy2obfs on` leaves client files and subscriptions byte-identical, and `xh diag` shows TCP 443, UDP 443 and UDP 8443 listening. **New installs only**; already installed boxes keep their node set. The Hysteria2 inbound on this machine had no markers and was wrapped in the same markers, so `xh hy2` works here. |
| **Randomize Hysteria2 ports & merge Obfs management into xh menu** | v4.9.73 | 1. **Randomized Hysteria2 ports**: `HY2_H3_PORT` and `HY2_PORT` now default to dynamic random high ports in the 10000-65000 range (preventing targeted ISP QoS throttling/blocking on fixed 443/8443, while still supporting explicit environment overrides); 2. **Consolidated xh menu**: Merged the previously separate "Hysteria2 master switch" and "Hysteria2-Obfs node switch" into option 21 (with interactive prompts and support for `xh hy2 on\|off` and `xh hy2 obfs on\|off`), streamlining the total menu to 27 options; 3. Optimized server inbound tag resolution with full backwards compatibility for existing configs and legacy `xh hy2obfs` commands. |
| **Hysteria2 links carry no noise by default: older cores cannot parse `noise.exp`** | v4.9.81 | Report: the Hysteria2 nodes fail in v2rayN with "core failed to run". Cause: v4.9.80 put a Noise `exp` item into the link's `fm`; that type exists only from Xray 26.9.30. Tested with the 26.3.27, 26.7.28 and 26.9.9 cores: every config with noise failed with `failed to build outbound config` and every config without it passed, and the core bundled with v2rayN is older than 26.9.30. There is now a switch `FEATURE_NOISE_LINKS` (default `false`): **the server inbounds keep their noise** (it is sender-side only and does not affect older clients) and links no longer carry noise by default; turn it on with `xh noise links on` only after every client core is >= 26.9.30. Applied locally with `xh noise links off`: the Hysteria2 links in the subscription no longer carry noise and Xray was not restarted; all 7 current links parse on the three older cores, and both Hysteria2 links were re-tested with their real links (about 0.05–0.08 s). The five vless links (including the enlarged QUIC receive windows on the H3 links) were also checked and parse on those three older cores. |
| **`xh noise` now syncs client links; new `xh noise sync`** | v4.9.80 | Until now `xh noise on/off/set` changed only the server Hysteria2 inbounds and the inbound texts in the spare-node store; the `fm` parameter of the Hysteria2 links in `client-config.txt` did not follow, so the switch said on while the links had no noise. Now on / off / set also rewrite the `fm` of those links in `client-config.txt` and in the store copy (a `noise` item goes first in the `udp` array, `salamander` and `quicParams` are kept, every other link is left alone); new `xh noise sync` only aligns the links with the current switch and does not restart Xray. The output matches the installer's `fm` character for character, and turning it off restores the original. Applied locally: both Hysteria2 links now carry noise and were re-tested with their real links (about 0.10 s with noise vs 0.07 s without; Noise's 15–45 ms delay adds a few tens of milliseconds to the handshake). Mihomo and Shadowrocket have no finalmask and are not affected. The stale `FEATURE_H2_DIRECT` in this machine's `node.env` was also set to `true` (the Direct-H2 inbound, subscription node and Mihomo entry were all there already). |
| **Full ALPN audit: Hy2-Obfs link gets an explicit alpn=h3; nginx can accept HTTP/2 only** | v4.9.79 | After the request "set all ALPN to h2 and h3 or above" the live config and sources were audited: Xray inbounds are h3 / h3 / h3 / h2, sing-box inbounds h2 / h3 / h3 / h3+h2, and there is **no http/1.1** in any node or inbound. Two changes: 1. The Hysteria2-Obfs link had no alpn and now carries an explicit `alpn=h3`; 2. **New `xh nginx h2only [show\|on\|off]`, written at install by default**: nginx cannot remove http/1.1 from the ALPN handshake, only reject it at the request layer, so HTTP/1.x requests get `return 444`, with `/sub/` and `/.well-known/` exempt (some subscription clients only speak HTTP/1.1). Turned on locally (only nginx was reloaded, Xray was not restarted): an HTTP/1.1 request to the home page is dropped, HTTP/2 returns 200, subscription pages return 200 over both, and five nodes (CDN-H3, Direct-H3, Direct-H2, Reality-Vision, Reality-XHTTP) were re-tested with their real links. **Risks:** behind Cloudflare, CF may use HTTP/1.1 for ordinary pages, so a browser opening the CDN domain's home page sees a CF 52x error; an active prober using HTTP/1.1 on the decoy site gets an empty reply unlike a real website, a small loss of stealth; xhttp / gRPC are HTTP/2 already and are unaffected. Turn it off with `xh nginx h2only off`. **Not done: "write h3,h2 on every TLS node"**: the Xray XHTTP client uses HTTP/2 whenever alpn has more than one entry (source: `decideHTTPVersion`), which would silently downgrade Direct-H3 and CDN-H3 to TCP; those two kinds already have h2 twin nodes (Direct-H2, CDN-H2) as fallback. |
| **Default node set follows the machine's current settings; the other nodes become spares in the xh menu** | v4.9.78 | As requested, the install-time default node set is now the 6 nodes in use on this machine: CDN-H3, Direct-H3, Hysteria2-H3, Hysteria2-Obfs, Reality-Vision, Reality-XHTTP. Changes: `FEATURE_HY2` and `FEATURE_HY2_OBFS` default to `true` again (Hysteria2 ports stay random high ports); `FEATURE_CDN_H2` and `FEATURE_REALITY_UP_CDN_DOWN` default to `false` and, with `CDN-Up-Reality-Down`, `Direct-H2`, `MASQUE`, `XDRIVE` and `Noise exp`, become spares that all have an xh menu item (16 CDN-H2, 20 Direct-H2, 21 Hysteria2, 22 MASQUE, 23 XDRIVE, 24 Noise, 25 / 26 split up/down). The installer profile, the `node.env` fallbacks, the "default / spare" wording in the xh menu and help, and the README node table were updated to match. **New installs only**; already installed boxes keep their node set. `node.env` on this machine was already in this state. **Non-node settings not made default**: this machine also has Finalmask Noise exp (`FEATURE_NOISE_EXP`) and blocking of CN IPs / ad domains (`FEATURE_BLOCK_CN` / `FEATURE_BLOCK_ADS`) turned on; these are link / egress policies, not nodes, so a fresh install still has them off (`xh noise on`, `xh block`). |
| **Shadowrocket subscription: Reality node `type=raw` becomes `type=tcp`** | v4.9.77 | Report: the Reality node works in the latest v2rayN but not in Shadowrocket. The Reality-Vision link carries `type=raw` (Xray's newer name for TCP, understood by v2rayN); Shadowrocket's link parser only knows `type=tcp` and the node fails to connect when it meets `raw`; for the Xray core the two are the same. The Shadowrocket-only subscription `shadowrocket.txt` (written at install and by `xh resub`) now rewrites `type=raw` to `type=tcp` and drops the client-only `spx` (along with the existing `fm`). **The v2rayN / Mihomo subscriptions do not change.** **This is an inference about the root cause, not tested on Shadowrocket** (there is no iOS environment here): if it still fails, report the Shadowrocket version, the error text from its connection log, and the output of `journalctl -u xray -n 40` on the server (with IPs, domains and keys replaced by placeholders). Ruled out: the server's `minClientVer` is explicitly 1.8.0 on this machine, so it does not reject Shadowrocket. |
| **Tuned for Xray 26.9.30: H3 receive windows, CDN-leg maxConnections, native Xray TUN configs, TUN subscription with CDN nodes** | v4.9.76 | After reading the 277 commits from 26.3.27 to 26.9.30, only items with test evidence were changed. 1. **XHTTP/3 links gain an `fm` parameter that enlarges the QUIC receive windows** (Direct-H3, CDN-H3): stream 4 MB / 32 MB, connection 8 MB / 64 MB. netns + netem (RTT 160 ms, 1% downlink loss, 300 Mbit cap), 40 MB download, 3 rounds per group: default windows 109–119 Mbps (5 runs), 8 MB / 16 MB 127, 16 MB / 32 MB 168, **32 MB / 64 MB 196–215**; at RTT 60 ms / 0.5% loss every setting gave 264–270 Mbps, no difference. Only the client (receiver) windows grow; the server's do not. Direct-H3 was measured; CDN-H3's QUIC runs from the client to a Cloudflare edge, which netem cannot reproduce, so it was not measured separately. 2. **`quicParams.bbrProfile` (conservative / standard / aggressive) made no measurable difference for XHTTP/3** (109–119 Mbps under the same conditions, 223 Mbps for all three without loss), so it is not set. 3. **The xmux of CDN legs now uses `maxConnections: 3`** (the 26.9.x client default; it cannot be combined with `maxConcurrency`): looped back through Cloudflare, 8 parallel downloads, 2 rounds each, h2 413 / 426 Mbps (3 / 6) vs 344 / 359 Mbps (`maxConcurrency` 16-32), h3 391 / 394 vs 358 / 373 Mbps; upload was too noisy to conclude. CDN legs only; direct and Reality legs unchanged. 4. **New native Xray TUN configs** `xray-tun-{windows,linux,macos}.json` (subscription directory, written at install and by `xh resub`): `autoSystemRoutingTable` + `autoOutboundsInterface: auto` (Xray's own outbounds bind to the physical NIC, so no loop and no hand-made direct route for the server), `autoSystemWfpBlockLeak` on Windows, observatory + leastPing for automatic selection, CN and private ranges direct. The Linux file was tested in a netns: TUN and routes came up by themselves, all 6 vless nodes were alive, non-CN traffic went through the proxy, CN traffic went direct, DNS worked; **the Windows and macOS files were only checked with `xray run -test`, not run on real machines.** 5. **The v2rayN TUN subscription (`v2rayn-tun.txt`) no longer excludes CDN nodes** (the old rule was written for a DNS-loss problem of the old TUN), **not tested on v2rayN**; if CDN nodes time out on DNS under TUN, add the CDN domain to v2rayN's direct rules. 6. `xh tuning` reads `/sys/module/tcp_bbr/version` first to identify the BBR version (a BBRv3 kernel shows `v3`). **Note a change in Xray 26.9.30**: the freedom outbound refuses private / loopback targets by default and needs an `allow` in `finalRules` to permit them (the live config already has explicit `finalRules`). |
| **Comprehensive upgrade to Xray-core v26.9.30: XDRIVE cloud proxy, MASQUE L3 tunnel, Noise exp obfs & 30-item symmetrical menu** | v4.9.75 | 1. **Core & Protocols**: Upgraded to Xray-core v26.9.30; 2. **MASQUE L3 Tunnel**: Integrated IETF RFC 9484 (CONNECT-IP) / RFC 8441 Extended CONNECT tunnel with netstack virtual IP pool (`10.13.0.1/24`, `fd13::1/64`), managed via `xh masque [show\|on\|off]`; 3. **XDRIVE Storage Proxy**: Native Google Drive relay transport for extreme IP whitelist bypass without public IP, managed via `xh xdrive [show\|setup\|on\|off]` and client outbound JSON export; 4. **Finalmask Noise exp Obfs**: Anti-DPI AWG expression templates (`<b hex>`, `<r N>`, `<t>`, `<c>`, `<rd N>`), managed via `xh noise [show\|on\|off\|set]`; 5. **30-Item Symmetrical Menu**: Perfectly balanced 15x15 menu layout and updated CLI shortcuts matrix; 6. **Anti-Leak & Compliance**: Client templates aligned with Windows WFP anti-leak (`autoSystemWfpBlockLeak`) and Linux `autoSystemDnsToGateway`, FakeDNS IPv6 updated to RFC 5180 `2001:2::/48` to eliminate Chrome 141+ PNA alerts. |
| **Align defaults with host: pin Xray official stable core v26.3.27 & solidify 6 core nodes** | v4.9.72 | 1. Xray-core install default locked to official stable release v26.3.27 (`XRAY_DEFAULT_VERSION="26.3.27"`, matching this host's running environment) to prevent upstream pre-release breaking changes; 2. Default node set fully aligned with this machine to 6 primary nodes (CDN-H2, CDN-H3, Direct-H3, Reality-Vision, Reality-XHTTP, Reality-Up-CDN-Down, with Hysteria2 disabled by default and available in the xh menu); 3. Synchronized environment matrix, build profile and release scripts. |

---

## 8. Disclaimer

1. This project is an open-source network transmission research and automation deployment tool. It does not provide public proxy services and never accesses user data.
2. Users must comply with local laws and regulations.
3. Network technologies evolve rapidly; uninterrupted service is not guaranteed. Users bear all responsibilities arising from using this software.

---

## Credits & License

- Built on top of [Xray-core](https://github.com/XTLS/Xray-core) and [sing-box](https://github.com/SagerNet/sing-box).
- Released under the [MIT License](./LICENSE). Issues and Pull Requests are welcome!

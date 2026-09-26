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
- [7. Release History & Core Tuning Evolution (v4.8 - v4.9.34)](#7-release-history--core-tuning-evolution-v48---v4934)
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

#### Core Environment Variables

| Variable | Default | Description |
| :--- | :---: | :--- |
| `AUTO` | `0` | Set `1` for automated non-interactive install. |
| `REALITY_DOMAIN` | — | **Direct / Reality domain** (Cloudflare Grey Cloud). |
| `CDN_DOMAIN` | — | **CDN proxied domain** (Cloudflare Orange Cloud). |
| `FEATURE_AUTO_TUNING` | `true` | Enables BBR+fq, 64MB buffers, 1048576 handles, etc. |
| `FEATURE_XPADDING` | `true` | Enables XHTTP traffic padding to eliminate length fingerprints. |
| `FEATURE_CDN_ECH` | `false` | Cloudflare ECH (Encrypted SNI). Requires CF ECH enabled. |
| `FEATURE_BRUTAL` | `true` | Enables TCP Brutal congestion control (95% host speed). |
| `REALITY_MIN_CLIENT_VER` | `1.8.0` | Minimum client version compatibility (`1.8.0` for Mihomo/Clash/sing-box). |

---

## 3. Resident Management Command `xh`

```bash
xh                     # Open interactive management menu
xh status              # Show service status, listening ports, tuning stats
xh info                # Show node parameters and subscription links
xh sub                 # Output subscription links and terminal QR code
xh resub               # Regenerate all client subscriptions
xh minversion [on|off] # Reality minimum client version control
xh ech [show|on|off]   # Cloudflare CDN ECH toggle & subscription sync
xh ecn [show|on|off]   # TCP ECN toggle & status inspection
xh cdnh2 [show|on|off] # CDN TCP(h2) fallback node toggle
xh brutal              # TCP Brutal status and bandwidth rate setting
xh tuning [win|mac|sb] # Display client OS gigabit tuning commands
xh conflict            # sysctl conflict detection and self-healing
xh log [xray|nginx]    # Live logs inspection
xh update [--auto]     # Update Xray-core with automated rollback
xh restart             # Restart xray and nginx services
```

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

| # | Node Name (v4.9.39) | Transport | Topology | Highlights |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-CDN-H2` | XHTTP (h2) + vlessenc | Via CDN TCP 443 | **Robust TCP fallback**, anti-blocking CDN escape hatch |
| **2** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | Direct UDP 8443 | Direct QUIC, `mode=stream-up` |
| **3** | `Hysteria2-H3-Direct` | Hysteria 2 | Direct UDP 443 | Standard HTTP/3 format, fastest measured download |
| **4** | `VLESS-Reality-Vision-Direct` | VLESS-Reality | Direct TCP 443 | **xtls-rprx-vision zero-copy**, max single-stream |
| **5** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | Direct TCP 443 | Reality camouflage + XHTTP padding |
| **6** | `VLESS-Reality-Up-CDN-Down` | Split Routing + vlessenc | Up Reality Direct / Down CDN (h2) | 0-RTT direct up + CDN full speed down anti-blocking |

> Disabled by default, toggleable on demand: `VLESS-XHTTP-CDN-H3` (`FEATURE_CDN_H3`), `VLESS-CDN-Up-Reality-Down` (`FEATURE_CDN_UP_REALITY_DOWN`), `VLESS-XHTTP-Direct-H2` (`FEATURE_H2_DIRECT`), `Hysteria2-Obfs-Direct` (`FEATURE_HY2_OBFS`).

---

## 6. Troubleshooting & FAQ

| Symptom | Root Cause | Quick Solution |
| :--- | :--- | :--- |
| **Reality node fails to connect** | Client system clock offset > 30s | Enable "Set time automatically" in OS settings (replay defense) |
| **Mihomo split-routing error** | Mihomo inherits parent Reality config | Explicitly declare `reality-opts: { public-key: "" }` in `download-settings` |
| **Direct UDP / Hysteria 2 timeout** | Cloud firewall / Security Group blocking | Allow inbound UDP 443 / 8443 / 8446 and TCP 443 / 8445 in cloud dashboard |
| **Kernel parameters conflict / overwritten** | External script injected `/etc/sysctl.d/` | Run `xh conflict` to automatically detect and heal sysctl conflicts |

---

## 7. Release History & Core Tuning Evolution (v4.8 - v4.9.39)

After dozens of iterative rounds across high-latency cross-Pacific topologies (160ms+ / 1% packet loss), core technical milestones are summarized below:

| Area | Versions | Technical Strategy & Tuning Findings |
| :--- | :--- | :--- |
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

---

## 8. Disclaimer

1. This project is an open-source network transmission research and automation deployment tool. It does not provide public proxy services and never accesses user data.
2. Users must comply with local laws and regulations.
3. Network technologies evolve rapidly; uninterrupted service is not guaranteed. Users bear all responsibilities arising from using this software.

---

## Credits & License

- Built on top of [Xray-core](https://github.com/XTLS/Xray-core) and [sing-box](https://github.com/SagerNet/sing-box).
- Released under the [MIT License](./LICENSE). Issues and Pull Requests are welcome!

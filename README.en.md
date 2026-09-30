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

| # | Node Name (v4.9.43) | Transport | Topology | Highlights |
| :--- | :--- | :--- | :--- | :--- |
| **1** | `VLESS-XHTTP-CDN-H2` | XHTTP (h2) + vlessenc | Via CDN TCP 443 | **Robust TCP fallback**, anti-blocking CDN escape hatch |
| **2** | `VLESS-XHTTP-Direct-H3` | XHTTP (QUIC) + vlessenc | Direct UDP 8443 | Direct QUIC, `mode=stream-up` |
| **3** | `Hysteria2-H3-Direct` | Hysteria 2 | Direct UDP 443 | Standard HTTP/3 format, fastest measured download |
| **4** | `VLESS-Reality-Vision-Direct` | VLESS-Reality | Direct TCP 443 | **xtls-rprx-vision zero-copy**, max single-stream |
| **5** | `VLESS-Reality-XHTTP-Direct` | XHTTP-Reality + vlessenc | Direct TCP 443 | Reality camouflage + XHTTP padding |

> Disabled by default, toggleable on demand: `VLESS-Reality-Up-CDN-Down` (`FEATURE_REALITY_UP_CDN_DOWN`), `VLESS-XHTTP-CDN-H3` (`FEATURE_CDN_H3`), `VLESS-CDN-Up-Reality-Down` (`FEATURE_CDN_UP_REALITY_DOWN`), `VLESS-XHTTP-Direct-H2` (`FEATURE_H2_DIRECT`), `Hysteria2-Obfs-Direct` (`FEATURE_HY2_OBFS`).

---

## 6. Troubleshooting & FAQ

| Symptom | Root Cause | Quick Solution |
| :--- | :--- | :--- |
| **Reality node fails to connect** | Client system clock offset > 30s | Enable "Set time automatically" in OS settings (replay defense) |
| **Mihomo split-routing error** | Mihomo inherits parent Reality config | Explicitly declare `reality-opts: { public-key: "" }` in `download-settings` |
| **Direct UDP / Hysteria 2 timeout** | Cloud firewall / Security Group blocking | Allow inbound UDP 443 / 8443 / 8446 and TCP 443 / 8445 in cloud dashboard |
| **Kernel parameters conflict / overwritten** | External script injected `/etc/sysctl.d/` | Run `xh conflict` to automatically detect and heal sysctl conflicts |

---

## 7. Release History & Core Tuning Evolution (v4.8 - v4.9.50)

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

---

## 8. Disclaimer

1. This project is an open-source network transmission research and automation deployment tool. It does not provide public proxy services and never accesses user data.
2. Users must comply with local laws and regulations.
3. Network technologies evolve rapidly; uninterrupted service is not guaranteed. Users bear all responsibilities arising from using this software.

---

## Credits & License

- Built on top of [Xray-core](https://github.com/XTLS/Xray-core) and [sing-box](https://github.com/SagerNet/sing-box).
- Released under the [MIT License](./LICENSE). Issues and Pull Requests are welcome!

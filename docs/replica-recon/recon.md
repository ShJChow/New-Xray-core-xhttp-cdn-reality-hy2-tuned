# Recon Map: my-xhttp-cdn-config (Xray + XHTTP + CDN Server Architecture)

Scope: Full-stack network proxy architecture with asymmetric uplink/downlink, Reality fallback, vlessenc, xpadding, ECH, QUIC/H3, and Nginx reverse proxy
For: Optimizing user's active Xray deployment (`reality.example.com` & `cdn.example.com`) on Oracle Cloud ARM
Date: 2026-10-09

---

## Sources

| # | Source | URL | Notes |
|---|---|---|---|
| 1 | Upstream Repository | https://github.com/Yulinanami/my-xhttp-cdn-config | Architecture, docs, scripts, templates (v1.2.7) |
| 2 | XHTTP Architecture & Principles | https://habr.com/en/articles/990208/ | Deep dive into XHTTP multiplexing, packet padding, and asymmetric routing |
| 3 | DNS Leak Prevention Guide | https://github.com/meooxx/blog/issues/31 | DNS routing and ECS considerations |
| 4 | Local Running Configuration | `/usr/local/etc/xray/config.json` | Active Xray-core configuration on server |
| 5 | Local Gateway Configuration | `/etc/nginx/nginx.conf` | Active Nginx SNI routing & reverse proxy configuration |
| 6 | Local Management Tool | `/usr/local/bin/xh` | Active `xh` CLI manager on server |

---

## Core Loop

Multiplexes high-speed direct Reality traffic and survivable CDN-tunneled XHTTP traffic through a single port (443) using clean fallback routing and cryptographic anti-DPI defenses (vlessenc + xpadding + ECH).

---

## Topology Endpoints (Network Screens)

| ID | Endpoint / Screen | Route / How to Reach | Purpose | Key Components | States Seen |
|---|---|---|---|---|---|
| S01 | Edge Port 443 TCP | `0.0.0.0:443 (TCP)` | Primary edge entry point; Reality inspection & routing | Xray raw reality, xtls-rprx-vision, shortId validation | Active, listening |
| S02 | Internal Inbound 8001 | `127.0.0.1:8001 (TCP)` | Core XHTTP inbound with post-quantum vlessenc | VLESS xhttp, mlkem768x25519plus decryption, xpadding | Active, healthy |
| S03 | Internal Inbound 8002 | `127.0.0.1:8002 (TCP)` | Shadowrocket / legacy client XHTTP inbound | VLESS xhttp, decryption none, path `/sr*` | Active, legacy fallback |
| S04 | Gateway Port 8003 | `127.0.0.1:8003 (TCP)` | Nginx SSL termination, SNI demux, fallback website | Nginx SSL, grpc_pass upstream, camouflage proxy | Active, healthy |
| S05 | QUIC/H3 Gateway | `0.0.0.0:443 (UDP)` vs `8446 (UDP)` | High-speed HTTP/3 transport for mobile networks | Nginx QUIC module vs Xray direct H3 inbound | Partial (8446 open, 443 UDP closed) |
| S06 | Hysteria 2 Ports | UDP 33385 / 37987 | High-latency / high-loss network acceleration | Hysteria 2 protocol, Salamander obfuscation mask | Active, listening |
| S07 | Subscription Gateway | `https://reality.example.com/sub/<TOKEN>/` | Dynamic client configuration delivery | Nginx static `/sub/`, rate limiter `sub_limit` | Active, rate-limited |

---

## User Traffic Flows

```
F01 Mode 1: VLESS Reality + Vision Direct (Lowest Latency & Maximum Speed)
    Client -> VPS:443 (TCP) -> Xray S01 (UUID1 + xtls-rprx-vision matched) -> Direct Outbound
    Happy path latency: 1 RTT handshake
    Edge cases: SNI mismatch falls back to S04; client without vision falls back to S02

F02 Mode 2: XHTTP + Reality Direct (Symmetric, Anti-QoS)
    Client -> VPS:443 (TCP) -> Xray S01 -> Fallback dest:8001 -> Xray S02 (UUID2 + xpadding) -> Outbound
    Happy path: Multiplexed streams over HTTP/2 connection
    Edge cases: CDN throttling avoided completely

F03 Mode 3: Asymmetric Uplink CDN + Downlink Reality (Recommended for Blocked VPS IP)
    Uplink: Client -> Cloudflare CDN -> VPS:443 -> S01 -> Target S04 -> grpc_pass -> S02 (UUID2)
    Downlink: Client initiates downloadSettings -> VPS:443 -> S01 -> S02 -> Direct back to client
    Happy path: Asymmetric bidirectional pipe bypassing unilateral DPI block
    Edge cases: CDN WebSocket/gRPC buffer saturation; solved by scMinPostsIntervalMs

F04 Mode 4: XHTTP + TLS + H2 via CDN (Total Origin Concealment)
    Client -> Cloudflare CDN -> VPS:443 -> S01 -> S04 (Nginx SNI cdn.*) -> grpc_pass -> S02 -> Outbound
    Happy path: Fully masked behind Cloudflare Anycast IPs
    Edge cases: CDN intermediate nodes inspect plaintext unless vlessenc is activated

F05 Mode 5: Asymmetric Uplink Reality + Downlink CDN
    Uplink: Client direct to VPS:443 (high bandwidth upload without CDN limits)
    Downlink: Client receives via CDN Anycast edge (circumventing downlink RST)

F06 Mode 6: HTTP/3 (QUIC) Transport Flow
    Client -> UDP 443 (or 8446) -> Nginx QUIC (or Xray H3) -> S02 -> Outbound
    Happy path: 0-RTT resumption, immune to TCP head-of-line blocking
    Current state: Direct 8446 works; standard 443 UDP is currently not listening on Nginx

F07 Active Probing & Censorship Defense Flow
    Scanner -> VPS:443 (Direct IP or foreign SNI) -> S01 -> S04 Default Server -> ssl_reject_handshake (444)
    Scanner -> VPS:443 (Valid SNI, no auth) -> S01 -> S04 -> Reverse proxy / Local static HTML 200 OK
```

---

## Component Inventory

| Component | Variants / Modules | States | Used In |
|---|---|---|---|
| **Xray Reality Inbound** | Port 443 TCP, raw stream | Active, fallbacks configured | S01 |
| **Xray XHTTP Inbound** | Port 8001 (vlessenc), Port 8002 (plain) | Active, trustedXForwardedFor enabled | S02, S03 |
| **VLESS Encryption** | ML-KEM-768 + X25519 (0-RTT/600s) | Active on 8001, Inactive on 8002 | S02, S03 |
| **xPadding Module** | `queryInHeader` in Referer, `tokenish` method, 100-1000B | Active | S02, S03, S05 |
| **Nginx SNI Router** | TLS 1.3/1.2, HTTP/2, upstream keepalive (256 conn) | Active, worker_connections 65535 | S04 |
| **Nginx QUIC / H3** | `--with-http_v3_module`, Alt-Svc h3=":443" | Compiled, but UDP 443 listen inactive | S04, S05 |
| **Hysteria 2 Inbounds** | UDP 33385 (raw H3), UDP 37987 (Salamander finalmask) | Active, bbr congestion, masquerade to 8003 | S06 |
| **Subscription Delivery** | `location ^~ /sub/`, rate limit 5r/s, burst 10 | Active | S07 |
| **DNS Subsystem** | 9.9.9.9 (primary), 1.1.1.1, 8.8.8.8, UseIPv4 | Active, low latency | Outbound |

---

## Inferred Data Model

```
InboundConfig {
    port: int,
    protocol: "vless" | "hysteria",
    security: "reality" | "tls" | "none",
    network: "raw" | "xhttp" | "hysteria",
    fallbacks: [{ dest: string, xver: int }],
    realitySettings: {
        serverNames: string[],
        privateKey: string,
        shortIds: string[],
        target: string
    },
    xhttpSettings: {
        path: string,
        mode: "auto" | "stream-up",
        xPaddingBytes: string,
        xPaddingObfsMode: bool,
        xPaddingKey: string,
        xPaddingHeader: string,
        xPaddingPlacement: string,
        xPaddingMethod: string
    }
}
Confidence: High (Verified against local /usr/local/etc/xray/config.json)

ClientConfig {
    address: string,
    port: int,
    uuid: string,
    flow: string,
    encryption: string,
    sni: string,
    alpn: string[],
    downloadSettings: InboundConfig (optional for asymmetric Mode 3/5),
    echConfigList: string (optional)
}
Confidence: High (Verified against client-config.txt and mihomo-full.yaml)
```

---

## Feature Matrix Summary

See [`features.csv`](file:///root/replica/features.csv).
- **Must**: 9 features (8 implemented, 1 partial)
- **Should**: 6 features (2 implemented, 4 ready for optimization)
- **Could**: 3 features (1 implemented, 2 optional extensions)
- **Total Parity**: ~78% implemented, with 4 key high-value optimizations identified.

---

## Out of Scope / Environmental Constraints

- **Oracle Cloud Network Security List (VCN)**: External cloud firewall controls UDP port ingress outside the VM; must be permitted in OCI console.
- **Third-Party Upstream Availability**: External university sites (`sjsu.edu`, `harvard.edu`) are outside server control and subject to remote downtime and Cloudflare rate limits.

---

## Size & Complexity

- **Endpoints/Inbounds**: 7
- **Traffic Flows**: 7
- **Config Modules**: 9
- **Complexity Rating**: **M** (Production-grade reverse-proxy mesh)
- **Hard Parts**: Asymmetric state synchronization between client downloadSettings and Xray server, UDP QUIC coexistence on single port 443, and ACME DNS-01 automation through CDN proxies.

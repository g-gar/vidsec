# Virtual Network Adapters Specification (`v2/specs/networks.md`)

This document specifies the **Reactive Virtual Network Adapters (`networks:`)** layer in `flowdata` / `vidsec v2`, governing network isolation, L4/L7 egress policies, reactive connection pooling, TCP window backpressure, multi-proxy routing, asynchronous DNS/TLS pinning, and Wireshark-compatible `PCAPNG` packet persistence.

---

## 1. Architectural Vision: Docker CNM vs. Reactive L4/L7 Dataflow

Following the `docker network` and `compose.yml` precedent, `networks:` elevates network access from an implicit OS side-effect to a first-class declarative primitive governed by the pipeline graph.

While `flowdata` inherits the best topological concepts from Docker's **Container Network Model (CNM)**:
* **Isolated Topologies by Default:** Internal networks (`driver: none`) that block external egress by default.
* **Explicit Multi-Homing (`networks: [net_a, net_b]`):** Ability to attach a single step to multiple virtual interfaces simultaneously (e.g., an `ingress_only` broker interface and an `egress` enrichment interface).
* **Scoped Embedded DNS Resolution:** Isolated DNS resolver scope and cache per network adapter.

It overcomes the four intrinsic L3/L4 bottlenecks of container networking by operating as a **Reactive L4/L7 Channel Manager**:

| Dimension | Docker / OS Approach (L3/L4) | `flowdata` Reactive Pipeline Approach (L4/L7) |
| :--- | :--- | :--- |
| **Isolation** | Linux `netns`, `nftables`/`iptables` rules | L7 Policy Engine (Host + Verb + Path Prefix), Anti-SSRF IP validation, optional `netns`/Landlock |
| **Flow Control** | Silent packet drops in kernel queues (`ENOBUFS`) | Reactive-Streams Backpressure bound to TCP Window (`SO_RCVBUF` / `auto_read = false`) |
| **DNS Resolution** | Blocking UDP server on `127.0.0.11` | Non-blocking async resolver, DoH/DoT, X.509 pinning, Reactive TTL Cache with `stale-while-revalidate` |
| **Proxying & Pooling** | Port mapping / L4 NAT (`nf_conntrack` exhaustion) | Dynamic L7 routing, reactive proxy rotation, circuit breakers, multiplexed `h2`/`h3` connection pools |
| **Observability** | External `pcap` capture (`Wireshark`/`tcpdump` as root) | Zero-privilege `.pcapng` synthesis with embedded TLS `DSB` keys + typed `network.captured_events` stream |

---

## 2. Virtual Network Drivers (`driver:`)

```
                                  ┌──────────────────────────────────────────────┐
                                  │           flowdata Pipeline Engine           │
                                  └──────────────────────┬───────────────────────┘
                                                         │
      ┌───────────────────────────┬──────────────────────┴───────┬───────────────────────────┐
      │ network: isolated         │ network: broker_in           │ network: api_egress       │ network: virtual_tap
      ▼                           ▼                              ▼                           ▼
┌───────────────┐         ┌──────────────────┐           ┌──────────────────┐        ┌──────────────────┐
│ driver: none  │         │driver:ingress_only│          │  driver: egress  │        │ driver: sinkhole │
│               │         │                  │           │                  │        │                  │
│• Zero sockets │         │• Inbound stream  │           │• L7 Host/Verb ACL│        │• 100% Offline    │
│• Pure compute │         │• Egress blocked  │           │• Anti-SSRF & DoH │        │• Mock / Catch    │
│• Air-gapped   │         │  (Fast EACCES)   │           │• Pool & Backpress│        │• Emits Stream    │
└───────────────┘         └──────────────────┘           │• Proxy + RateLim │        └────────┬─────────┘
                                                         └────────┬─────────┘                 │
                                                                  │                           ▼
                                                                  ▼                  [ Pipeline Channel ]
                                                        [ Allowed External ]         (network.captured_events)
                                                        [   API / Broker   ]
```

### 2.1. Air-Gapped Driver (`driver: none`)
* **Behavior:** Rejects all outbound and inbound network socket operations (allowing only in-memory channels or local UNIX domain sockets when explicitly permitted).
* **Guarantee:** Isolates untrusted parsing libraries and enforces strict functional reproducibility ($Inputs \rightarrow Outputs$).

### 2.2. Inbound-Only Driver (`driver: ingress_only`)
* **Behavior:** Permits listening on designated local endpoints or consuming inbound data streams, while physically disabling outbound connection initiation.
* **Fast-Fail Semantics:** Any outbound connection attempt to an external host immediately returns a deterministic policy error (`HostError_ABI.network_policy_denied` / `EACCES`) in $O(1)$ time, never stalling worker threads on a socket connection timeout.

### 2.3. Virtual Sinkhole / Tap Driver (`driver: sinkhole`)
* **Behavior:** Attaches the task to an isolated virtual network environment with no route to the external internet. Every connection attempt (DNS resolution, HTTP request, SMB handshake, raw TCP/UDP packet) is intercepted by the `flowdata` runtime.
* **Capabilities:**
  1. **Service Mocking / Interception:** Returns synthetic responses for deterministic offline pipeline testing.
  2. **Network-as-a-Stream Telemetry (`network.captured_events`):** Serializes intercepted requests into a typed stream routable into `pipeline_memory` or `sqlite`.
  3. **Security Detonation:** Catches SSRF (`CWE-918`), SMB/NTLM hash exfiltration (`T1187`), or tracking beacons triggered when parsing untrusted media containers.

---

## 3. Controlled L4/L7 Egress Subsystems (`driver: egress`)

An `egress` adapter governs outbound connections at the **task execution boundary** through eight integrated subsystems:

### 3.1. Protocol-Agnostic L4/L7 Policy Engine & Anti-SSRF Validation (`policy:`)
Modern pipelines rarely rely on a single protocol: a workflow may combine **HTTPS** (REST/OpenAPI), **gRPC** (HTTP/2 streaming), **WebSockets (`ws`/`wss`)**, **RTMP/RTSP/SRT** (media transport), **AMQP/MQTT** (brokers), or custom binary protocols over raw **TCP/UDP/QUIC**.

To support **any** protocol without polluting the specification with protocol-specific keywords, `flowdata` models network policies using a **two-layer Envoy/Wireshark-inspired architecture**:
1. **Universal L4 Transport Base (`tcp`, `udp`, `tls`, `quic`, `unix`):** Every protocol is fundamentally either a byte-stream or a datagram flow governed by destination IP/CIDR, port (or `port_range`), TLS **SNI**, **ALPN**, connection rate, and byte-stream bandwidth (`max_bandwidth_mbps`). Even proprietary binary protocols work out-of-the-box at L4.
2. **Normalized L7 URI Dissectors (`schemes`, `resources`, `operations`):** For application protocols (`http`, `https`, `ws`, `wss`, `grpc`, `rtmp`, `rtsp`, `amqp`, etc.), modular L7 dissectors normalize wire metadata into three universal RFC 3986 primitives—eliminating bespoke per-protocol YAML fields:

| Normalized Primitive | HTTP / HTTPS | WebSockets (`ws`/`wss`) | gRPC (`h2`) | Media (`rtmp`/`rtsp`) | Raw L4 (`tcp`/`udp`/`tls`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`schemes`** | `http`, `https` | `ws`, `wss` | `grpc`, `grpcs` | `rtmp`, `rtmps`, `rtsp` | `tcp`, `udp`, `tls`, `quic` |
| **`resources`** *(URI path/glob)* | `/manga/*`, `/chapter/*` | `/ws/events/*` | `/pkg.Service/Method` | `/live/stream_*` | *(N/A — matched by host/port)* |
| **`operations`** *(verb/action)* | `GET`, `POST`, `HEAD` | `HANDSHAKE`, `TEXT`, `BINARY` | `UNARY`, `STREAM` | `PLAY`, `PUBLISH`, `SETUP` | `CONNECT`, `DATAGRAM` |

```yaml
policy:
  block_private_ranges: true
  allow_rules:
    # 1. REST / OpenAPI & WebSockets over TLS
    - schemes: [https, wss]
      hosts: ["api.mangadex.org", "*.mangadex.network"]
      ports: [443]
      operations: [GET, HANDSHAKE]
      resources: ["/manga/*", "/chapter/*", "/at-home/server/*", "/data/*", "/data-saver/*"]

    # 2. gRPC Microservices (HTTP/2 paths map to /package.Service/Method)
    - schemes: [grpcs]
      hosts: ["index.internal.svc"]
      ports: [8443]
      resources: ["/flowdata.v2.Coordinator/*"]

    # 3. Any Streaming or Custom Binary Protocol over TCP/UDP/QUIC
    - schemes: [rtmps, quic, udp]
      hosts: ["ingest.stream.example.com"]
      ports: [443, "9000-9050"]
      operations: [PUBLISH, PLAY, DATAGRAM]
      resources: ["/live/*"]
```

* **Pre-Connect Anti-SSRF Firewall (`block_private_ranges: true`):** Resolves and validates destination IP addresses *prior* to opening the TCP/UDP/QUIC socket, blocking DNS rebinding attacks targeting loopback (`127.0.0.0/8`, `::1`), RFC1918 private networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and cloud metadata endpoints (`169.254.169.254`).

### 3.2. Reactive Connection Pooling, Multiplexing & Deadlines (`pool:` & `timeouts:`)
* **Pool Acquisition Envelopes (`pool`):**
  * `max_connections`: Maximum active connections maintained by the adapter.
  * `max_pending_acquires`: Strict upper bound on requests waiting for a free connection before fast-failing (prevents heap exhaustion when an upstream proxy stalls).
  * `acquire_timeout_ms`: Maximum wait time to acquire a pooled channel.
  * `alpn: [h2, http1_1, h3]`: Negotiates HTTP/2 (`h2`) and HTTP/3 (`quic`) to multiplex logical streams over a single TLS connection and avoid `nf_conntrack` exhaustion.
* **Granular Deadlines (`timeouts`):**
  * `connect_ms`: Deadline for the TCP/QUIC handshake.
  * `tls_handshake_ms`: Deadline for cryptographic TLS/SNI negotiation.
  * `read_idle_ms` / `write_idle_ms`: Detects zombie/stalled connections (whether HTTP, RTMP, or raw TCP) without waiting for OS TCP keep-alive timers.

### 3.3. Flow Control, Reactive Backpressure & Memory Bounds (`backpressure:`)
* **Reactive-Streams to TCP Window Binding (`bind_tcp_window: true`):** Maps downstream pipeline consumption demand directly to the socket's `SO_RCVBUF` and read-interest state (`auto_read`). When a downstream queue saturates, the adapter suspends socket reads (`auto_read = false`), forcing a **TCP Zero-Window Advertisement** that pushes backpressure physically to the remote producer.
* **Strict Memory Envelopes (`max_buffer_memory_mb`):** Hard cap on pooled off-heap/direct network buffer memory per adapter.

### 3.4. Dual Rate Limiting: Transactional & Byte-Stream Bandwidth Shaping (`rate_limit:`)
Because a pipeline may mix discrete transactional calls (HTTP/DNS) with long-lived continuous streams (RTMP, RTSP, raw TCP/UDP), the adapter enforces a dual thread-safe **Token Bucket**:
* **Transactional Rate Limits (L7 Requests & L4 Handshakes):**
  * `requests_per_second` & `burst`: Sustained L7 request rate (e.g. `5` req/s for MangaDex API).
  * `connections_per_second`: Limits new TCP/UDP/RTMP session establishment rate.
  * `max_inflight`: Maximum simultaneous active requests/streams.
  * `respect_retry_after`: Automatically parses `Retry-After` and `X-RateLimit-Retry-After` headers on `429` / `503` responses.
* **Continuous Stream Bandwidth Shaping (L4 Byte Pacing):**
  * `max_bandwidth_mbps` (or `bytes_per_second`): Paces socket `recv`/`send` throughput across long-lived connections (such as RTMP streams or bulk image downloads) so a single continuous stream cannot saturate link capacity.

### 3.5. Proxy Pool, Active/Passive Circuit Breaker & Load Balancing (`proxies:`)
* **Supported Protocols:** `http_connect` (`http://`, `https://`), `socks5` (`socks5://` with UDP support), and `shadowsocks` (`ss://`), with L7 credential injection (`auth`).
* **Load-Balancing Strategies (`proxies.strategy`):**

| Strategy | Behavior | Ideal Use Case |
| :--- | :--- | :--- |
| **`round_robin`** | Cycles sequentially across all healthy proxy endpoints ($P_0 \rightarrow P_1 \rightarrow \dots \rightarrow P_{n-1}$). | Distributing stateless REST API calls evenly across multiple exit IPs to multiply per-IP rate limits. |
| **`weighted`** | Distributes requests proportionally to each endpoint's declared `weight` (Smooth Weighted Round-Robin). | Combining high-capacity datacenter proxies (`weight: 5`) with lower-capacity residential backups (`weight: 1`). |
| **`failover`** | Sends 100% of traffic through `endpoints[0]` and switches to `endpoints[1..N]` only on failure or `429`/`403`. | Using a fast primary connection with automatic fallback to secondary proxies only if throttled. |
| **`least_latency`** | Tracks an Exponentially Weighted Moving Average (EWMA) of response times and active in-flight transfers, picking the fastest exit. | Bulk media/chapter downloads (e.g., distributed `*.mangadex.network` `@Home` nodes) where peering varies per proxy. |
| **`sticky_host`** | Computes a consistent hash (`fnv1a(dst_host)`) so all requests to the same target host consistently exit via the same proxy IP. | Upstream CDNs or authenticated endpoints that bind session tokens or TLS tickets to the client IP. |
| **`random`** | Stateless uniform random selection across healthy proxy endpoints. | Lightweight randomized distribution without state synchronization overhead. |

* **Active Health-Checking & Integrated Circuit Breaker (`circuit_breaker`):**
  * `health_check_interval_ms`: Out-of-band probing to evict dead proxies before task traffic hits them.
  * `failure_threshold`, `cooldown_ms`, `half_open_max_calls`, `failover_on_status`: Degrades a failing proxy's effective weight to `0` (`OPEN`) during the cooldown window before testing recovery in `HALF_OPEN`.

### 3.6. Async DNS Subsystem, Reactive Cache, DoH/DoT & X.509 Pinning (`dns:` & `tls:`)
* **Reactive TTL Cache:** Non-blocking resolver with `min_ttl_sec`, `max_ttl_sec`, `stale_while_revalidate_sec`, and automatic fallback across multiple `A`/`AAAA` records.
* **Encrypted DNS & Static Pinning:** `doh_endpoint` / `dot_endpoint` to bypass ISP DNS poisoning, plus static host-to-IP `overrides`.
* **X.509 Fingerprint Pinning (`tls.pinned_sha256`):** Validates server SPKI SHA-256 fingerprints independent of the host OS CA store.

### 3.7. Traffic Redirection, Mirroring & Split-Tunnel Routing (`redirects:` & `routes:`)
* **`redirects`:** Rewrites outbound URLs matching a source prefix across one or more target mirrors (`round_robin` or `failover`) transparently.
* **`routes`:** Applies per-domain overrides for proxy strategy and rate limits within the same adapter (e.g. `api.mangadex.org` vs `*.mangadex.network`).

### 3.8. Wireshark-Grade Packet Persistence (`capture:`)
Every virtual adapter supports native **IETF PCAPNG (`.pcapng`)** persistence for deep inspection in Wireshark:
1. **Zero-Privilege Synthesis (Tier 1) & Namespace Tap (Tier 2):** Synthesizes clean `Enhanced Packet Blocks (EPB)` directly from mediated task streams without `root` privileges or host noise.
2. **Per-Adapter `IDB` & Step Metadata (`opt_comment`):** Each adapter registers its own `Interface Description Block` (`frame.interface_name == "api_egress"`), and every packet is stamped with `step_id`, `task`, `proxy`, and `verdict`.
3. **Automatic TLS 1.2 / 1.3 Decryption (`DSB`):** When `include_tls_keys: true` is enabled, ephemeral `CLIENT_RANDOM` secrets are written into an embedded **Decryption Secrets Block (`DSB`)** inside the `.pcapng`, enabling out-of-the-box HTTPS/HTTP2 decryption in Wireshark.
4. **Payload Slicing (`snaplen`) & Ring Buffer (`ring_buffer`):** Truncates heavy media payloads while preserving full L3/L4/L7 headers and rotates capture files automatically.

---

## 4. Enforcement Architecture, External Binaries & Driver Policy Matrix

| Dimension | Tier 1: User-Space Runtime Mediation (Default) | Tier 2: OS-Level Kernel Confinement (`isolation: strict` & External Binaries) |
| :--- | :--- | :--- |
| **Mechanism** | Mediated via `HostApiVTable_ABI` (`net_fetch`, `net_connect`, `net_send`, `net_recv`) and `LD_PRELOAD` socket interposition. | Unprivileged Linux Network Namespaces (`CLONE_NEWUSER \| CLONE_NEWNET`) bridged to the Host Adapter via a virtual `TUN`/`veth` fd + Landlock ABI v4+. |
| **Privileges** | **Zero (`0` privileges required).** | Rootless on Linux via unprivileged user namespaces + Landlock. |
| **Execution Model** | **In-Process & Zero-Copy** on Host `ThreadPool`. | **Subprocess / Thread Boundary** (mandatory for external binaries like `ffmpeg`). |

### 4.1. How Policies Apply Across Drivers (`none` vs. `sinkhole` vs. `egress`)

A common architectural question is which policies (redirection, filters, rate-limiting, `.pcapng` capture) apply when an interface is isolated (`driver: none` or `driver: sinkhole`):

| Subsystem | `driver: none` (Pure Air-Gap) | `driver: sinkhole` (Offline Virtual Network) | `driver: egress` (Controlled Outbound) |
| :--- | :--- | :--- | :--- |
| **External Internet Route** | ❌ Physically absent (`ENETUNREACH` / `EACCES` in $O(1)$). | ❌ Physically absent (100% offline). | ✅ Permitted only for `policy.allow_rules` matches. |
| **Redirection (`redirects:`)** | ⚠️ **Local-Only:** Only permitted if redirecting to an in-memory datasource or loopback mock (`allow_loopback: true`). | ✅ **Active:** Rewrites URLs/IPs toward internal mock responders. | ✅ **Active:** Rewrites toward external mirrors or local caches. |
| **L4/L7 Filters (`policy:`)** | Unconditional deny-all. | ✅ **Active:** Classifies attempted calls as `CAPTURED` vs `BLOCKED` in `network.captured_events`. | ✅ **Active:** Enforces Host + Verb + Path / RTMP app / Port ACLs + Anti-SSRF. |
| **Rate-Limit & Bandwidth** | N/A (0 external packets). | ✅ **Active (Optional):** Can throttle synthetic mock responses to simulate slow links or prevent flood DoS in detonation. | ✅ **Active:** Enforces Token Bucket (`requests_per_second` + `max_bandwidth_mbps`). |
| **Proxy Pool (`proxies:`)** | ❌ Disabled. | ❌ Disabled (traffic terminates inside the Host sinkhole). | ✅ **Active:** Rotates across HTTP/SOCKS5/Shadowsocks pool with Circuit Breaker. |
| **Wireshark `.pcapng`** | Optional (records blocked connection attempts if enabled). | ✅ **Active:** Records 100% of synthetic/detonated frames (`EPB` + `DSB`). | ✅ **Active:** Records all outbound/inbound frames (`EPB` + `DSB`). |

> [!TIP]
> **Rule of Thumb (`none` vs. `sinkhole`):**
> * Use **`driver: none`** when the task or external binary **must not touch the network stack at all** (any `socket`/`connect` syscall fails immediately).
> * Use **`driver: sinkhole`** when you want an untrusted binary or task to **believe it has a real network** (applying DNS overrides, redirections to local mocks, rate-limiting, L4/L7 filters, and `.pcapng` capture) while guaranteeing **zero packets ever leave the host**.

### 4.2. Governing External Binaries (`ffmpeg`, `rtmpdump`, CLI Tools)

Native Zig plugins interact through `HostApiVTable_ABI`. However, external binaries (`ffmpeg -i rtmp://...`, Python/C# CLIs, or legacy C libraries) invoke raw OS `socket()` and `connect()` syscalls directly. `flowdata` governs external binaries without modifying their code through two mechanisms:

```
┌──────────────────────────────────────────────┐      ┌─────────────────────────────────────────────────────┐
│   Isolated Subprocess (e.g. `ffmpeg` CLI)    │      │             flowdata Host Engine (Zig)              │
│   inside `CLONE_NEWUSER | CLONE_NEWNET`      │      │                                                     │
│                                              │      │  ┌───────────────────────────────────────────────┐  │
│  [ raw socket() / connect() : RTMP / HTTPS ] │      │  │        Virtual Network Adapter Instance       │  │
│                      │                       │      │  │                                               │  │
│                      ▼                       │      │  │ 1. L4/L7 Inspector (HTTP, RTMP, TLS SNI, DNS) │  │
│        [ Virtual Interface `tun0` ] ═════════╪══════╪═►│ 2. Redirects & Split-Tunnel Route Matcher     │  │
│          (Default Gateway 10.254.0.1)        │ (fd) │  │ 3. Token Bucket (req/s + max_bandwidth_mbps)  │  │
└──────────────────────────────────────────────┘      │  │ 4. SOCKS5 / HTTP Proxy Pool Rotator           │  │
                                                      │  │ 5. Wireshark `.pcapng` + TLS `DSB` Writer     │  │
                                                      │  └───────────────────────┬───────────────────────┘  │
                                                      └──────────────────────────┼──────────────────────────┘
                                                                                 ▼
                                                                   [ Physical Egress / Sinkhole ]
```

1. **Unprivileged `CLONE_NEWNET` + Host Virtual Gateway (`tun`/`veth` file descriptor — Linux):**
   * The external binary is spawned inside an unprivileged network namespace with zero physical interfaces—only a virtual `tun0`/`veth0` interface whose file descriptor is owned by the `flowdata` Host process in user-space.
   * When `ffmpeg` opens an **RTMP (`tcp/1935`)**, **HTTPS (`tcp/443`)**, or **RTP (`udp`)** socket, the kernel routes the raw packets through the file descriptor directly into `flowdata`'s Virtual Network Adapter.
   * The Host adapter inspects the L4/L7 headers (DNS query, TLS ClientHello SNI, HTTP request, or RTMP `connect` packet), applies **redirections, L7 filters, byte-rate bandwidth limits (`max_bandwidth_mbps`), `.pcapng` recording, and transparently wraps the stream into the configured SOCKS5 / HTTP proxy pool**!
2. **User-Space Posix Socket Shim (`LD_PRELOAD` / `DYLD_INSERT_LIBRARIES` — Cross-Platform Fallback):**
   * On platforms without unprivileged network namespaces (such as standard unprivileged macOS), `flowdata` injects `libvidsec_netshim` into child processes to intercept libc `socket()`, `connect()`, `sendto()`, and `getaddrinfo()`, forwarding them over a local UNIX domain socket to the Host's Virtual Network Adapter.

### 4.3. Core Engineering Invariants:
1. **Task-Level Attachment (Zero Network State in SDKs):** Domain modules never instantiate their own network interfaces or proxy pools; the Host binds the step's `network:` adapter to `TaskContext_ABI`.
2. **Deterministic Resource Release:** Every pooled channel and buffer is bound to the step's lifetime and released deterministically (`defer release`) even on early pipeline termination (`halt_pipeline`).
3. **Mandatory Low-Level Telemetry:** Exports `active_connections`, `pending_acquires`, `dns_lookup_avg_ms`, `circuit_breaker_trips`, and `backpressure_stall_ms`.

---

## 5. Canonical `networks:` YAML Reference

```yaml
networks:
  isolated:
    driver: none

  broker_ingress:
    driver: ingress_only

  api_egress:
    driver: egress
    policy:
      block_private_ranges: true
      allow_rules:
        - schemes: [https]
          hosts: ["api.mangadex.org", "uploads.mangadex.org"]
          ports: [443]
          operations: [GET]
          resources: ["/manga/*", "/chapter/*", "/at-home/server/*", "/covers/*"]
        - schemes: [https]
          hosts: ["*.mangadex.network"]
          ports: [443]
          operations: [GET]
          resources: ["/data/*", "/data-saver/*"]

    pool:
      max_connections: 32
      max_pending_acquires: 128
      acquire_timeout_ms: 2000
      alpn: [h2, http1_1]

    timeouts:
      connect_ms: 3000
      tls_handshake_ms: 3000
      read_idle_ms: 10000
      write_idle_ms: 5000

    backpressure:
      bind_tcp_window: true
      so_rcvbuf_bytes: 262144
      max_buffer_memory_mb: 64

    rate_limit:
      requests_per_second: 5
      burst: 5
      connections_per_second: 10
      max_bandwidth_mbps: 100
      max_inflight: 8
      respect_retry_after: true

    proxies:
      strategy: round_robin # round_robin | weighted | failover | least_latency | sticky_host | random
      health_check_interval_ms: 15000
      circuit_breaker:
        failure_threshold: 3
        cooldown_ms: 30000
        half_open_max_calls: 2
        failover_on_status: [403, 429, 502, 503, 504]
      endpoints:
        - url: "http://proxy-eu-1.internal:8080"
          weight: 3
        - url: "http://proxy-eu-2.internal:8080"
          weight: 3
        - url: "socks5://proxy-backup.internal:1080"
          weight: 1

    dns:
      doh_endpoint: "https://1.1.1.1/dns-query"
      min_ttl_sec: 60
      max_ttl_sec: 3600
      stale_while_revalidate_sec: 120
      overrides:
        "api.mangadex.local": "127.0.0.1"

    tls:
      verify_certificates: true
      pinned_sha256: []

    redirects:
      - from: "https://uploads.mangadex.org"
        to:
          - "https://mirror-a.cdn.internal/mangadex-uploads"
          - "https://mirror-b.cdn.internal/mangadex-uploads"
        strategy: failover

    routes:
      - match_host: "*.mangadex.network"
        proxy_strategy: least_latency
        rate_limit:
          requests_per_second: 20
          burst: 10

    capture:
      enabled: true
      format: pcapng
      path: "./logs/mangadex_egress.pcapng"
      snaplen: 4096
      include_tls_keys: true
      ring_buffer:
        max_file_size_mb: 100
        max_files: 5

  virtual_tap:
    driver: sinkhole
    subnet: "10.254.0.0/24"
    capture_protocols: [dns, http, smb, tcp, udp]
    isolation: runtime
    capture:
      enabled: true
      format: pcapng
      path: "./logs/sinkhole_detonation.pcapng"
      snaplen: 65535
      include_tls_keys: true
```

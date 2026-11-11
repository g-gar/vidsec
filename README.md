# Flowdata

> **High-Performance Reactive Dataflow Microkernel & Declarative Pipeline Engine in Zig**

Flowdata is an ultra-fast, embeddable reactive dataflow engine designed to build, prototype, and run complex analytical pipelines in minutes. 

Instead of hand-coding thread pools, transport sockets, rate limiters, and intermediate database schemas for every new project, Flowdata lets you declare **reactive dataflow topologies in YAML** while implementing **pure, atomic business tasks in Zig**.

---

## Why Flowdata?

Prototyping modern data-intensive apps typically means fighting boilerplate: coordinating threads, managing network rate limits, dealing with database staging tables, and gluing components together. 

Flowdata solves this with 6 core design principles:

1. **Declarative Pipelines (`pipeline.yaml`)**  
   Wire up multi-step DAGs, branch streams (fan-out), filter records with declarative expressions (`where:`), and merge results (fan-in) without writing procedural glue code.
2. **Compile-Time Dependency Injection (`DiContainer`)**  
   Inspired by modern enterprise frameworks (like Spring Boot) but engineered idiomatically for Zig with **zero runtime reflection and zero heap overhead**. Services declare what they need (interfaces, loggers, clients), and Flowdata resolves and injects them at compile time.
3. **Engine-Driven Concurrency (Auto-Lifting)**  
   Write clean, atomic, single-item tasks (`1 -> 1`). Need to process 50 items in parallel? Simply set `concurrency: 4` in the pipeline configuration. The engine automatically lifts the task over incoming streams using worker pools and preserves deterministic ordering.
4. **Intelligent Virtual Networking**  
   Outbound HTTP adapters feature built-in token-bucket rate limiting, backpressure handling, proxy routing, and security policies (ACLs, private IP blocking). Your tasks never get banned by remote APIs.
5. **RAM-First, Zero-Copy Dataflow**  
   Route intermediate records and binary blobs between tasks via `pipeline_memory` using zero-copy fat pointers (`PayloadHandle`). Persist to disk or SQLite only when you explicitly choose to.
6. **Reactive Emitter Datasources (`emitRecord` & Event-Driven Push)**  
   Datasources aren't just passive storage sinks; they can act as live reactive event emitters. Whether streaming Server-Sent Events (SSE), WebSockets, live file watchers (`inotify` for hot-reloading configurations), or message queues, Flowdata's push reactor dispatches incoming items into running pipelines in real time without inefficient polling loops.

---

## Showcase Applications

Flowdata is domain-agnostic. The repository includes two full showcase applications demonstrating very different workloads and architectural complexities:

### VidSec (`apps/vidsec`) — Video Stream Forensics & Network Security
* **What it does:** Real-time deep packet inspection (DPI) of network captures, carving multimedia streams (RTSP / RTP / H.264 / PCAPNG), validating transport framing, and applying automated security and quarantine heuristics on binary payloads.
* **Components & Technologies Used:**
  * **Zero-copy byte stream windowing:** `BoundedStreamReader` and `WindowReader` for direct slicing of large PCAPNG files without memory duplication.
  * **H.264 NAL Unit Parser:** Frame-level boundary detection and streaming video reconstruction.
  * **Virtual Network Guard:** Outbound proxy interception, DNS resolution middleware, and rule-based network policy guards.
  * **Quarantine Engine:** Automated carving of suspicious payload segments into SHA-256 verified quarantine storage.
  * **OpenTelemetry Bus:** Hierarchical distributed tracing (`traceparent`) and DAG graph visualization (`extensions/opentelemetry`, `extensions/dag_viz`).
* **Why check it out?**  
  It is an ideal reference for **low-level binary protocol forensics, zero-copy packet carving, and real-time streaming analysis** without operating system or runtime overhead.

---

### MangaDex & Media Harvester (`apps/mangadex`) — Multi-Source Content Pipeline
* **What it does:** Automated multi-source catalog synchronization, chapter discovery, rate-limited CDN image downloading, XML metadata generation, and high-speed packaging into `.cbz` archives integrated with personal media servers (Komga).
* **Components & Technologies Used:**
  * **Polymorphic Source Drivers:** Abstract `MangaSource` interface supporting both MangaDex REST APIs and generic HTML scrapers with dynamic capability matching (`canHandle`).
  * **Compile-Time Dependency Injection:** Application container (`DiContainer(MangaContext)`) injecting HTTP adapters, drivers, and loggers into pure declarative task services (`defineTaskService`).
  * **Custom SDKs & Protocols:**
    * `mangadex_sdk`: Standalone HTTP client with OAuth/Personal Client/Static token authentication.
    * `komga_sdk`: REST client for remote library sync and book scanning.
    * `comicinfo`: High-performance XML serializer/deserializer implementing the Anansi ComicInfo v2.1 spec.
    * `zip_archive`: Embedded `miniz` ZIP engine writing Deflate metadata and zero-compression `STORE` mode image archives.
  * **Egress Rate Limiting:** Outbound network adapter enforcing 5 req/s token-bucket throttling to prevent CDN bans.
  * **In-Memory Fork & Join:** Parallel image downloading running concurrently with `ComicInfo.xml` generation, joining in RAM before CBZ creation.
* **Why check it out?**  
  It serves as a blueprint for **enterprise-grade microservice orchestration**: external REST/HTML scraping, compile-time DI, third-party API clients, rate-limited network egress, and binary file packaging—all running in RAM without intermediate database bottlenecks.

---

## Virtual Network Drivers & Datasource Synergy

One of Flowdata's proudest architectural achievements is its **composable outbound virtual network subsystem** (`src/transport/outbound/`). Instead of letting tasks make raw, unmonitored socket calls, all network communication flows through policy-governed virtual network adapters that seamlessly connect to datasources:

### Pluggable Network Drivers & Middlewares
* **4 Specialized Adapters:**
  * `egress`: Full-featured outbound engine with rate limiting, DNS caching, and proxy routing.
  * `isolated`: Zero-trust network sandbox restricting communication strictly to whitelisted targets.
  * `sinkhole`: Blackhole adapter for offline verification, unit testing, and safe malware/packet analysis.
  * `ingress_only`: Enforces unidirectional traffic, preventing data exfiltration.
* **Intelligent Middlewares & Proxy Strategies:**
  * **Traffic Throttling:** Token-bucket rate limiter with burst control and backpressure management.
  * **Anti-SSRF & ACL Guard:** Blocks RFC1918 private subnets (10.0.0.0/8, 192.168.0.0/16, 127.0.0.0/8) and cloud metadata services (169.254.169.254) out-of-the-box.
  * **6 Load Balancing Strategies:** `round_robin`, `least_latency`, `smooth_weighted`, `sticky_host`, `failover`, and `random`.

### The Network-to-Datasource Connection (The MangaDex Pattern)
In Flowdata, **Network I/O and Storage I/O are completely decoupled from business tasks**:
1. You declare a virtual network adapter in `pipeline.yaml` (e.g. `mangadex_api` with custom headers and a 5 req/s rate limit).
2. The task receives an injected, thread-safe transport bridge through DI. It doesn't know (or care) whether it's talking through a rotating proxy, a rate limiter, or a mock sinkhole.
3. As network responses arrive, the pipeline engine automatically routes the resulting domain entities into declared datasources (`pipeline_memory` for fast in-RAM coordination, or `catalog_db` for persistent SQLite storage).

Tasks write pure domain logic—Flowdata handles all security, routing, rate-limiting, and storage mapping.

---

## Quick Start

### Prerequisites
* [Zig](https://ziglang.org/download/) `0.16.x`

### Run Core Tests
```bash
zig build test
```

### Run Application Tests & Builds
```bash
# Test the MangaDex application suite (33 tests, 0 leaks)
cd apps/mangadex
zig build test

# Build the standalone MangaDex CLI & shared plugin library (libmanga_catalog.so)
zig build
```

# 019 — Standalone Collectors Architecture and Inbound Agents

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-019` |
| **Depends On** | [`ARCH-014`](./014-inbound-emitter-datasources-and-reactive-dispatch.md), [`ARCH-018`](./018-type-driven-inbound-router-and-service-catalog.md) |
| **Area** | `collectors/`, `src/transport/inbound/`, `src/engine/` |
| **Status** | `COMPLETED` |

---

## 1. Context & Motivation

To maintain strict domain decoupling and prevent engine bloat:
* The Flowdata core engine (`src/engine/`) and native datasource extensions (`extensions/datasource/`) must never contain operating-system-specific polling threads, file watchers (`inotify`, `kqueue`, `ReadDirectoryChangesW`), web scrapers, or network ingest daemons.
* All data gathering, external polling, web scraping, and filesystem observation logic is elevated to **Standalone Inbound Collectors** living in a dedicated top-level directory: `/collectors/`.

```
vidsec/
├── src/                  # Flowdata Core Engine (Agnostic Push Reactor, DAG Coordinator)
├── extensions/           # Pure Datasource Drivers (Memory, SQLite, YamlFile, FileStore)
├── apps/                 # Domain Applications & Pipelines (vidsec, mangadex)
└── collectors/           # Autonomous Inbound Collection Daemons & Micro-Agents
    ├── common/           # Minimal Shared SDK & JobEnvelope Contract
    ├── file_watcher/     # OS Inotify / File System Change Collector
    └── <collector_name>/ # Domain-specific collectors (RSS, API pollers, webhooks)
```

---

## 2. Minimal Shared Protocol (`collectors/common/`)

Collectors are completely independent processes that do not compile or depend on the heavy engine or AST modules. They only share a minimal contract:

### 2.1. The `JobEnvelope` Contract
```zig
pub const JobEnvelope = struct {
    id: []const u8,
    datasource: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    timestamp_ns: u64 = 0,
    params: []const KeyValueParam = &.{},
    payload_raw: ?[]const u8 = null,
};
```

### 2.2. Egress Channel from Collector to Engine
A collector delivers gathered jobs into the Flowdata engine through decoupled channels:
1. **Inbound HTTP/gRPC Transport**: Calling the daemon endpoint (`POST /v1/ingest/:source` or `/v1/jobs`).
2. **Local IPC / Unix Domain Socket**: Streaming serialized `JobEnvelope`s directly to the engine's reactive listener.
3. **Appended Queue / Spool**: Writing to an intermediate append log observed by an ingest agent.

### 2.3. Job ID Generation & Idempotency Strategy

#### Evaluated Architectural Options

| Option | Strategy | Pros | Cons |
| :--- | :--- | :--- | :--- |
| **Option A** | Simple Timestamp + Monotonic Counter | Simple to implement, fast | Risk of collisions across distributed collectors or rapid sub-nanosecond bursts; no idempotency. |
| **Option B** | Content-Addressed Hash (`SHA-256(topic + body)`) | Perfect natural deduplication of identical payloads | Expensive computational overhead; identical legitimate events spaced in time get collapsed. |
| **Option C** | **ULID (Universally Unique Lexicographically Sortable Identifier)** | **K-sortable by time**, 128-bit collision-proof entropy, 26-char Base32 URL/disk safe, zero DB B-Tree index fragmentation | Requires 128-bit bit-packing encoder (implemented in `collectors/common/ulid.zig`). |

#### Architectural Decision & Rationale: **Option C (ULID + Client Idempotency Override)**

The chosen implementation standard for Flowdata collectors adopts **Option C** (with hybrid support for client idempotency headers):

1. **K-Sortable Chronological Order by Design**:
   The first 48 bits encode UNIX epoch timestamp in milliseconds (characters `0..9`), guaranteeing that standard alphabetical sort (`std.mem.order`) matches physical occurrence time.
2. **Disk Spool FIFO Optimization**:
   Files saved as `<spool_dir>/<ULID>.job` naturally sort in exact chronological FIFO order without needing secondary index files or zero-padded decimal strings.
3. **Zero Collision Guarantee**:
   The trailing 80 bits provide cryptographically secure entropy, preventing collisions even if thousands of events arrive within the exact same millisecond.
4. **Database & Index Efficiency**:
   Unlike UUIDv4 which causes random page thrashing in SQLite B-Trees, monotonically increasing ULIDs append smoothly to indexes.
5. **Client Idempotency Header Support**:
   For HTTP webhooks, if the incoming request specifies an explicit `X-Request-ID`, `X-Event-ID`, or `Idempotency-Key` header, the collector adopts that identifier to maintain upstream idempotency; otherwise, it emits a generated `wh_<ULID>`.

---

## 3. Dedicated Collectors

### 3.1. `collectors/file_watcher` (`inotify` Daemon)
* Runs as a standalone micro-agent.
* Watches target files (such as `jobs.yaml`) using Linux `inotify` (`IN_MODIFY`, `IN_CLOSE_WRITE`).
* Extracts new items / delta rows upon file updates.
* Emits discovered jobs directly to the engine's reactive ingress without requiring engine restarts.

### 3.2. Web and Network Collectors
* Standalone scrapers (e.g. MangaDex API poller, RTSP camera stream frame capture).
* Emits structured payloads into the Flowdata engine where the `PushReactor` (and `ARCH-018` Router) automatically dispatches them to matching tasks.

---

## 4. Summary & Architecture Boundary

| Component | Responsibility |
| :--- | :--- |
| **`/collectors/`** | Independent collector daemons and micro-agents gathering data from files (`inotify`), APIs, and network feeds. |
| **`collectors/common/`** | Minimal shared serialization and `JobEnvelope` protocol. |
| **`src/engine/` (`ARCH-014`)** | Pure, debloated Push Reactor receiving `emit(source_id, payload)` without OS watcher logic. |
| **`extensions/datasource/`** | Passive storage and passive stream providers without background OS watcher threads. |

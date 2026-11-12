# 019 — Standalone Collectors Architecture and Inbound Agents

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-019` |
| **Depends On** | [`ARCH-014`](./014-inbound-emitter-datasources-and-reactive-dispatch.md), [`ARCH-018`](./018-type-driven-inbound-router-and-service-catalog.md) |
| **Area** | `collectors/`, `src/transport/inbound/`, `src/engine/` |
| **Status** | `DESIGN & ARCHITECTURE SPECIFICATION` |

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

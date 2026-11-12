# Flowdata

> **High-Performance Reactive Dataflow Microkernel & Declarative Pipeline Engine in Zig**

Flowdata is an embeddable, zero-copy dataflow engine and plugin microkernel for building declarative ETL, streaming, and binary-analysis pipelines in Zig. You describe topology, policies, and datasources in YAML while implementing pure, testable domain tasks in Zig.

---

## What the Flowdata Engine Provides

1. **Pluggable Routing Strategies (`directed` & `type_driven`)**
   * **`directed`**: Explicit DAG edges (`inputs:` / `outputs:` / `after:`) with deterministic execution and refcounted step arenas.
   * **`type_driven`**: Dynamic signature matching via `canHandle()`, `inputFields()`, unary `where:` filters, and automatic **multi-input Join accumulation** across converging parallel branches without declaring `inputs:` in YAML.
2. **Concurrent DAG Scheduler & Bounded Memory**
   * `scheduler: dag | sequential` backed by a bounded `WorkerPool` (help-while-waiting), per-step `StepArena` reclamation, and `max_inflight_bytes` backpressure.
   * **Elemental Auto-Lifting**: Write single-item tasks (`1 -> 1`) and scale out with `concurrency: N` in YAML.
3. **Zero-Copy Dataflow & C-ABI Plugin SDK (`flowdata_plugin`)**
   * Type-erased `PayloadHandle` fat pointers across steps with zero intermediate serialization.
   * Compile-time dependency injection (`DiContainer`) and declarative services (`defineTaskService`) compiled into isolated `.so` modules over a strict C-ABI boundary (`TaskContext_ABI`, `HostApiVTable_ABI`).
4. **Datasources with Explicit Roles & Unified Batch/Push Execution**
   * Built-in drivers (`memory`, `sqlite` with declarative `schemas.yaml` DDL provisioning, `file_store`, `yaml_file`) with `role: source | sink | duplex` enforcement.
   * Decoupled `BatchSource` and `RecordEmitter` / `PushReactor` unify offline CLI batch runs and live daemon/collector ingestion through the same execution path.
5. **Least-Privilege Virtual Egress Networks**
   * Pluggable adapters (`egress`, `isolated`, `sinkhole`, `ingress_only`) with token-bucket rate limiting, anti-SSRF/private-range blocking, host/scheme ACLs, and proxy load-balancing strategies.
6. **Open Kernel Extensions & Transports**
   * Modular `KernelContext` and `TelemetryBus` powering `inbound_cli`, `inbound_http`, `inbound_grpc`, `opentelemetry`, `dag_viz`, `pcapng`, `trace_jsonl`, and `artifact`.
7. **Standalone Collectors (`collectors/`)**
   * Decoupled ingress daemons (`flowdata-collector-filewatcher` using inotify, `flowdata-collector-webhook`) with ULID disk spooling when the engine is offline.

---

## Showcase Applications

### 1. VidSec (`apps/vidsec/`)
Binary media forensics and container inspection pipeline (ISOBMFF/MP4, EBML/MKV, RIFF, H.264 NAL units) using zero-copy `BoundedStreamReader`/`WindowReader`, virtual network guards, and automated quarantine/remediation plugins (`libanalyzer.so`, `libremediation.so`).

### 2. MangaDex Catalog & Packaging Pipeline (`apps/mangadex/`)
Multi-source manga synchronization and `.cbz` archiver running on `routing: type_driven` with `role: source` batch emission, rate-limited HTTP egress, `ComicInfo.xml` v2.1 serialization, and in-memory ZIP (`STORE`) packaging.
* See [`apps/mangadex/README.md`](./apps/mangadex/README.md) for detailed topology, configuration, and usage.

---

## Building, Testing, and Running

### Prerequisites
* [Zig](https://ziglang.org/download/) `0.16.x`
* SQLite3 development library (`libsqlite3`)

### 1. Core Engine & Tests
```bash
# Build all core artifacts and collectors
zig build

# Run the core engine, routing, ABI, and collector test suites
zig build test --summary all
```

### 2. Running Applications

#### VidSec (`apps/vidsec`)
```bash
cd apps/vidsec

# Build binary and shared plugin libraries (libanalyzer.so, libremediation.so)
zig build

# Run VidSec test suite
zig build test --summary all

# Run the CLI against a pipeline/input
./zig-out/bin/vidsec --help
```

#### MangaDex (`apps/mangadex`)
```bash
cd apps/mangadex

# Build binary and shared plugin library (libmanga_catalog.so)
zig build

# Run MangaDex test suite
zig build test --summary all

# Mode A: Offline batch CLI (emits enabled targets from configs/jobs.yaml)
./run_pipeline.sh

# Mode B: Persistent HTTP daemon (/v1/jobs)
./run_pipeline.sh --serve

# Mode C: Dispatch a single JobEnvelope to a running daemon
./send_mangadex_job.sh --series-id "<uuid>" --title "Series" --chapters "1..3" --lang "en"
```

### 3. Running Standalone Collectors
From the repository root, build or run the collectors directly:

```bash
# Inotify file watcher collector (streams file updates to a running Flowdata daemon)
zig build run-collector-watcher -- \
  --watch apps/mangadex/configs/jobs.yaml \
  --topic manga_subscription \
  --endpoint http://127.0.0.1:8080/v1/jobs

# Standalone Webhook collector
zig build run-collector-webhook -- --help
```

Or run the installed binaries directly from `./zig-out/bin/`:
* `./zig-out/bin/flowdata-collector-filewatcher`
* `./zig-out/bin/flowdata-collector-webhook`

---

## Architecture Documentation
See [`docs/development/000-architecture-roadmap.md`](./docs/development/000-architecture-roadmap.md) for the full architectural specifications (`ARCH-001` through `ARCH-027`).

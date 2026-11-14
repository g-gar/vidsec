# 009C — Optional SQLite Kernel Extensions (Tooling, Inspection & Ops)

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-009C` |
| **Parent Master** | [`ARCH-009`](./009-unified-sqlite-storage-and-schema.md) |
| **Depends On** | [`ARCH-009B`](./009b-sqlite-datasource-and-engine.md), [`ARCH-002`](./002-open-kernel-extension-system.md) |
| **Area** | `extensions/sqlite_inspector/`, `extensions/sqlite_maintenance/`, `extensions/sqlite_profiler/`, `extensions/sqlite_snapshot/` |
| **Status** | `SPECIFICATION (OPTIONAL / FUTURE)` |

---

## 1. Purpose & Architectural Boundary

`ARCH-009B` separates the **pure synchronous SQLite library** (`libs/sqlite/`) from the **cohesive runtime storage driver** (`drivers/sqlite/`).

To keep the runtime driver lean and avoid coupling operational/debugging utilities into pipeline execution, **optional SQLite capabilities** follow the microkernel's `Kernel.Extension` model (similar to `dag_viz`, `pcapng`, or `opentelemetry`):

1. **Opt-in only:** Pipelines and apps that only need storage use the `009B` driver without compiling or registering any `009C` extension.
2. **Consume `libs/sqlite/` directly:** Extensions use `libs/sqlite/` primitives (`Db`, `Stmt`, `PRAGMA`, C hooks) without modifying `src/` or `drivers/sqlite/`.
3. **Zero runtime overhead when disabled:** No tracing hooks, HTTP endpoints, or background maintenance jobs are attached unless explicitly registered via `KernelContext.use(...)`.

---

## 2. Candidate Extensions

### 2.1. `sqlite_inspector` (Observability & `.db` Browser)
* **Purpose:** Live read-only inspection of SQLite databases used by an app or pipeline.
* **Capabilities:**
  * Expose HTTP/gRPC or CLI commands to list tables, row counts, `PRAGMA table_info`, `PRAGMA index_list`, and WAL size.
  * Execute bounded, read-only `SELECT` queries (`openReadOnly` + row limit) for UI panels (e.g., [`ARCH-032`](./032-typescript-webapp-and-realtime-transport.md)).

### 2.2. `sqlite_maintenance` (Operations & Online Backups)
* **Purpose:** Operational housekeeping without stopping running pipelines.
* **Capabilities:**
  * Kernel commands or scheduled hooks for `PRAGMA incremental_vacuum(pages)`, `PRAGMA optimize`, and `PRAGMA wal_checkpoint(TRUNCATE)`.
  * Online hot backups via SQLite's `sqlite3_backup_*` API to a destination path.

### 2.3. `sqlite_profiler` (Query Tracing & Plan Diagnostics)
* **Purpose:** Development and staging performance diagnostics.
* **Capabilities:**
  * Attach `sqlite3_trace_v2` callbacks to measure statement execution latency and flag slow queries.
  * Optionally run `EXPLAIN QUERY PLAN` on registered queries to detect unintended full table `SCAN`s vs index `SEARCH`es, emitting spans/events to `opentelemetry` or `trace_jsonl`.

### 2.4. `sqlite_snapshot` (Export & Support Dumps)
* **Purpose:** Portable data export for debugging, bug reproduction, and support.
* **Capabilities:**
  * Export selected tables or query results to JSONL, CSV, or SQL dump files.


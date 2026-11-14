# 009A — Universal Repository Contract, Core Schema & Concurrency Decorators

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-009A` |
| **Parent Master** | [`ARCH-009`](./009-unified-sqlite-storage-and-schema.md) |
| **Depends On** | [`ARCH-002`](./002-open-kernel-extension-system.md), [`ARCH-016`](./016-reactive-bifurcation-parallel-expansion-and-join.md), [`ARCH-025`](./025-datasource-roles-and-batch-emission-decoupling.md) |
| **Area** | `src/schema/`, `src/repository/`, `src/dataflow/`, `src/plugin/`, `src/engine/` |
| **Status** | `PARTIALLY IMPLEMENTED (CORE COMPLETE)` |

---

## 1. Purpose & Design Principles

Flowdata separates **what** data looks like and **how** pipeline steps wire inputs/outputs from **where** and **how** it is stored. Binding a step output or input to a datasource in `pipeline.yaml` must transparently drive inserts, partial updates, deletes, and reads without task code embedding SQL or engine-specific logic.

Non-negotiable core rules:
1. **Engine-agnostic core:** `src/schema/`, `src/repository/`, and `schemas.yaml` contain zero SQL and zero project-specific concepts.
2. **Schema is authoritative:** Tables/collections are never inferred from runtime payloads unless `schemaless: true` is explicitly configured. Initialization and schema errors fail loudly.
3. **Struct shape = projection:** On write, every field declared in the emitted struct (including `null`) is written; fields absent from the struct are untouched. On read, the target input struct defines the projected fields.
4. **Decoupled concurrency:** Core storage drivers remain thread-agnostic and single-responsibility; concurrency synchronization and batch queueing are layered via composable Decorators.

---

## 2. Core Contracts (`src/`)

### 2.1. Universal Schema Catalog (`src/schema/`)
Extract `SchemaCatalog`, `TableSchema`, `ColumnSpec`, `IndexSpec`, and `SeedRow` out of `src/yaml/loaders/schema_loader.zig` into `src/schema/`. Remove all SQL rendering from the YAML loader (YAML loader only decodes into `SchemaCatalog`).

* **Logical types:** `int64`, `uint64`, `float64`, `bool`, `text`, `bytes`, `timestamp`, `json`, `enum`. Remove `any`.
  * `timestamp` is standardized as `int64` (Unix epoch timestamp, microsecond precision) across all core contracts and storage backends, eliminating string-parsing overhead and enabling single-cycle integer B-Tree comparisons.
* **Defaults:** Typed literals matching the column type, plus portable generators (`now`, `uuid`) evaluated by Flowdata.
* **Schema layering:**
  * *Mandatory semantics* (types, `nullable`, `pk` / `primary_key`): enforced by all drivers (or by Flowdata before write).
  * *Constraints* (`ref` foreign keys, `unique`, `check`): enforced natively or flagged in preflight via driver `Capabilities`.
  * *Hints* (`indexes`): used by drivers that support them; safely ignored otherwise.
  * *Engine extensions*: optional driver-namespaced block (e.g. `sqlite: { strict: true, without_rowid: false }`), ignored by other drivers.

### 2.2. Preflight Type Validation (`src/plugin/` & `src/engine/`)
* Extend `TaskDescriptor_ABI` with typed field metadata `(name, logical_type, nullable)` for both inputs and outputs, generated at `comptime` by the Zig plugin SDK.
* `validatePreFlight()` cross-checks:
  1. Task input/output struct fields vs. target table columns in `SchemaCatalog` (type compatibility, nullability, PK presence).
  2. Pipeline directives (`mode`, `where`, `order_by`) vs. driver `Capabilities`.

### 2.3. Predicate AST (`src/dataflow/predicate.zig`)
Replace runtime string-splitting evaluation with a parsed **Predicate AST** (`PredicateNode`: `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `and`, `or`, `is_null`, `in`, literals) operating with an `ArenaAllocator`:
* **Frontends (Decoupled Construction):**
  * *Declarative parser:* `PredicateParser.fromYaml(arena, expr)` for expressions declared in `pipeline.yaml` (`where: "status == 'active' and age >= 18"`).
  * *Programmatic builder:* `PredicateBuilder.init(arena)` for compile-time/test programmatic query construction.
* **Backends (Decoupled Evaluation):**
  * *Dialect Pushdown:* Drivers with `filter_pushdown` compile the AST to native parameterized queries with positional bindings (`WHERE "status" = ?1 AND "age" >= ?2`) with zero SQL injection.
  * *In-Memory Evaluator:* `evalPredicateNode(node, getter)` pure evaluator for drivers without pushdown or memory channels.

### 2.4. Universal `Repository` Contract (`src/repository/`)
Designed as **collection + key + typed record** so it applies uniformly to relational DBs, KV/document stores, `memory`, object storage (`file_store`/S3), and files (`yaml_file`, `json_store`):

```zig
pub const Capabilities = struct {
    transactions: bool = false,
    savepoints: bool = false,
    partial_update: bool = false,
    filter_pushdown: bool = false,
    order_pushdown: bool = false,
    relational_constraints: bool = false,
    schema_ddl: bool = false,
};
```

Core vtable operations:
* `capabilities() Capabilities`
* `ensureSchema(catalog: *const SchemaCatalog) !void`
* `write(spec: WriteSpec) !void` — `WriteSpec` carries `{ table, mode, payload, record_map }`.
  * `mode`: `upsert` (default when table has PK), `append` (default when table has no PK), `update`, `replace_all`, `delete`.
  * `RecordMap`: compiled once per `(type_name, table)` to avoid per-row string reflection lookups. Encapsulates dual-payload execution:
    * **Typed Contiguous Path (`Lowered(T)`)**: Fast-path for payloads with `.typed` representation and `schema_id`. Column access is performed via direct memory byte offsets (`base + row * stride + offset`) without allocations or boxing.
    * **Dynamic Field Path (`DynamicRecord`)**: Runtime fallback for `.dynamic` payloads (schemaless, CSV/ad-hoc ingestion, dynamic YAML queries). Column access is performed via linear field lookup.
* `read(spec: ReadSpec) !PayloadHandle` — Convenient block read for small lookups.
* `readStream(spec: ReadSpec) !RowIterator` — Primary streaming primitive. Yields rows or chunked batches step-by-step with $O(1)$ memory consumption, integrating natively with DAG scheduler backpressure (`max_inflight_bytes: 512MiB`) by pausing cursor stepping when worker queues are full.
* `count(table: []const u8) !usize`
* Optional transaction hooks (`beginTx`, `commit`, `rollback`, null when `capabilities().transactions == false`).
* Optional savepoint hooks (`beginSavepoint`, `rollbackSavepoint`, `releaseSavepoint`, null when `capabilities().savepoints == false`) for step-level retries and checkpointing (`ARCH-020`).

### 2.5. Concurrency & Decorator Architecture (`src/repository/`)
To preserve the Single Responsibility Principle and avoid coupling thread synchronization into storage drivers, underlying implementations (`SqliteRepository`, `MemoryRepository`) remain thread-agnostic. Concurrency modes are layered via composable **Decorators** implementing the `Repository` VTable:
* **`SynchronizedRepository`:** Wraps any underlying `Repository` with a `std.Thread.Mutex`. Applied automatically by the engine when `scheduler: dag` is active to serialize concurrent writes from parallel DAG workers transparently without file-level contention or busy deadlocks.
* **`AsyncBatchRepository`:** Wraps any `Repository` with a bounded MPSC channel and a dedicated background writer thread. Pipeline workers push `WriteSpec`s asynchronously under semaphore backpressure; the background writer thread drains the queue and flushes batch writes inside a single transaction.

---

## 3. Reference Driver (`extensions/datasource/memory/`)

`MemoryRepository` serves as the **behavioral oracle** for all drivers:
* **Ephemeral channels** (undeclared in `schemas.yaml`): retain zero-copy `PayloadHandle` snapshot semantics.
* **Schema-backed tables** (declared in `schemas.yaml`): enforce types, nullability, PK uniqueness, `WriteSpec` modes (`upsert`, `append`, `update`, `replace_all`, `delete`), and `ReadSpec` via the in-memory Predicate AST evaluator.

---

## 4. Driver Conformance Suite (`tests/core/repository_conformance.zig`)

Shared test battery run identically against `memory` and all future driver implementations:
* `upsert` partial update preserves untouched columns and writes explicit `null`s.
* `upsert` on a parent row does **not** trigger `ON DELETE CASCADE` on child rows.
* `append`, `update`, `delete`, `replace_all` semantics match across drivers.
* `ReadSpec` and `readStream` with Predicate AST (`where`, `order_by`, `limit`, `offset`, projection) produce identical results.
* Undeclared tables fail with `UnknownTable` when `schemaless == false`.
* Preflight rejects type/nullability mismatches between task `TaskDescriptor_ABI` and `SchemaCatalog`.

---

## 5. Pending Follow-Ups (Post-009A)

1. **Engine wiring in `PipelineRunner` (`src/engine/runner.zig`):**
   * Automatically wrap shared `Repository` instances with `SynchronizedRepository` when `scheduler: dag` is active (and `AsyncBatchRepository` when configured).
   * Wire `preflight.validateDirectivesCapabilities()` during pipeline preflight once drivers declare `Capabilities` in `009B`.
2. **Legacy `ColumnType.any` & `ColumnType.blob` removal (`src/schema/types.zig`):**
   * Currently retained as temporary backward-compatibility aliases during the `009A` → `009B` transition; remove once all existing `schemas.yaml` and driver mappings are migrated to `bytes` / explicit logical types.


# 009 — Portable Repository Contract, Core Schema & SQLite Refactor

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-009` |
| **Depends On** | [`ARCH-002`](./002-open-kernel-extension-system.md), [`ARCH-025`](./025-datasource-roles-and-batch-emission-decoupling.md) |
| **Area** | `src/schema/`, `src/repository/`, `src/dataflow/`, `src/plugin/`, `src/engine/`, `libs/sqlite/`, `extensions/datasource/` |
| **Status** | `SPECIFICATION (REFACTOR)` |

---

## 1. Purpose & Design Principles

Flowdata separates **what** data looks like and **how** pipeline steps wire inputs/outputs from **where** it is stored. Binding a step output or input to a datasource in `pipeline.yaml` must transparently drive inserts, partial updates, deletes, and reads without task code embedding SQL or engine-specific logic.

Non-negotiable rules:
1. **Engine-agnostic core:** `src/schema/`, `src/repository/`, and `schemas.yaml` contain zero SQL and zero project-specific concepts.
2. **Schema is authoritative:** Tables are never inferred from runtime payloads unless `schemaless: true` is explicitly configured. Initialization and schema errors fail loudly.
3. **Struct shape = projection:** On write, every field declared in the emitted struct (including `null`) is written; fields absent from the struct are untouched. On read, the target input struct defines the projected fields.
4. **Core-first execution order:** Core contracts → `memory` reference driver → `libs/sqlite` → `extensions/datasource/sqlite` (and subsequently other drivers like `blob_store` / `json`).

---

## 2. Layer 1 — Core Contracts (`src/`)

### 2.1. Portable Schema (`src/schema/`)
Extract `SchemaCatalog`, `TableSchema`, `ColumnSpec`, `IndexSpec`, and `SeedRow` out of `src/yaml/loaders/schema_loader.zig` into `src/schema/`. Remove `renderSeedInsertSql` and `renderAllSeedsSql` from the YAML layer (YAML loader only decodes into `SchemaCatalog`).

* **Logical types:** `int64`, `uint64`, `float64`, `bool`, `text`, `bytes`, `timestamp`, `json`, `enum`. Remove `any`.
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
Replace runtime string-splitting evaluation with a parsed **Predicate AST** (`eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `and`, `or`, `is_null`, `in`, literals). Drivers with pushdown support compile the AST to native queries; others let Flowdata evaluate the AST in memory.

### 2.4. Universal `Repository` Contract (`src/repository/`)
Designed as **collection + key + typed record** so it applies uniformly to relational DBs, KV/document stores, `memory`, and object storage (`file_store`/S3, where collection = bucket/prefix, PK = object key, `bytes` = object body, and scalar fields = metadata/sidecar):

```zig
pub const Capabilities = struct {
    transactions: bool = false,
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
  * `RecordMap`: compiled once per `(type_name, table)` to avoid per-row string reflection lookups.
* `read(spec: ReadSpec) !PayloadHandle` — `ReadSpec` carries `{ table, projection, where_ast, order_by, limit, offset }`.
* `count(table: []const u8) !usize`
* Optional transaction hooks (`beginTx`, `commit`, `rollback`, null when `capabilities().transactions == false`).

### 2.5. Engine Integration (`src/engine/`)
* Inputs bound to a datasource read via `Repository.read(ReadSpec)` (pushdown if `filter_pushdown`/`order_pushdown` is true; in-memory AST evaluation fallback otherwise).
* Each pipeline step executes its writes to a transactional datasource within a single transaction.

---

## 3. Layer 2 — Reference Driver (`extensions/datasource/memory/`)

`MemoryRepository` serves as the **behavioral oracle** for all drivers:
* **Ephemeral channels** (undeclared in `schemas.yaml`): retain zero-copy `PayloadHandle` snapshot semantics.
* **Schema-backed tables** (declared in `schemas.yaml`): enforce types, nullability, PK uniqueness, `WriteSpec` modes (`upsert`, `append`, `update`, `replace_all`, `delete`), and `ReadSpec` via the Predicate AST.

---

## 4. Layer 3 — Pure SQLite Library (`libs/sqlite/`)

Extract and harden `db.zig` and `ddl.zig` from `extensions/datasource/sqlite/src/sqlite_lib/` into `libs/sqlite/` (zero `flowdata` dependency; compatible with system `sqlite3` and static `sqlite3.c` for `ARCH-031`). Delete `query.zig`.

Required improvements:
* **Rich error reporting:** Surface `sqlite3_errmsg`, `sqlite3_extended_errcode`, and the failing SQL statement. No silent `catch {}`.
* **Full engine configuration:** `OpenOptions` + `PragmaConfig` exposing `read_only`, `create`, `full_mutex`, `busy_timeout_ms`, `foreign_keys`, `journal_mode`, `synchronous`, `auto_vacuum`, `cache_size`, `mmap_size`, `temp_store`, `journal_size_limit`, `wal_autocheckpoint`.
* **Execution primitives:** `StmtCache` (keyed by SQL), explicit transactions (`BEGIN IMMEDIATE` / `DEFERRED`), `incrementalVacuum(pages)`, `optimize()`.
* **Null-safe `Row`:** `text()` and `blob()` return `?[]const u8` (`null` on `SQLITE_NULL`).

---

## 5. Layer 4 — SQLite Datasource Adapter (`extensions/datasource/sqlite/`)

Thin adapter connecting `Repository` + `SchemaCatalog` + Predicate AST to `libs/sqlite/`:

### 5.1. Declarative Configuration (Zero Hardcoding)
All options come from `ConfigParam` in `pipeline.yaml` (interpolated via `EnvInterpolator`), with documented defaults and **no CWD fallback** to `configs/schemas.yaml`:
* `path` (default `:memory:`), `schema` (required unless `schemaless: true`), `read_only`, `migrate` (`auto | verify | off`, default `auto`), `on_conflict` (`update | ignore | fail`, default `update`), `schemaless` (default `false`).
* All `PragmaConfig` fields exposed as optional params (`journal_mode`, `synchronous`, `busy_timeout_ms`, `foreign_keys`, `auto_vacuum`, `cache_size`, `mmap_size`, `temp_store`, `journal_size_limit`, `wal_autocheckpoint`, `full_mutex`).

### 5.2. Schema Provisioning & Migrations
* **Full DDL mapping:** `schema_provisioner.zig` maps every `SchemaCatalog` attribute (`default`, `check`, `collate`, `generated_as`, `unique_keys`, `strict`, `without_rowid`, `indexes` with `order`/`where`/`expressions`) to `DdlBuilder`.
* **Seeds:** Inserted via parameterized `Stmt` binds (`INSERT OR IGNORE`), never SQL string concatenation.
* **Schema tracking:** `PRAGMA user_version` + `_flowdata_schema` metadata table storing catalog version and schema hash.
* **Phase 1 migrations (non-destructive, automatic under `migrate: auto`):**
  * `CREATE TABLE` for new tables.
  * `ALTER TABLE ... ADD COLUMN` for new `nullable` columns or columns with a `default`.
  * `CREATE INDEX` / `DROP INDEX` for index changes.
* **Destructive changes** (type changes, column drops, PK/FK modifications): **Deferred to a dedicated migration spec**; for now, detect via schema diff and abort startup with a clear diff message.

### 5.3. Operation Compilation (`SqliteRepository`)
* **Writes:**
  * `upsert`: `INSERT INTO "t" (...) VALUES (...) ON CONFLICT("pk"...) DO UPDATE SET "col" = excluded."col", ...` touching **only** the columns present in the payload's `RecordMap`. (`INSERT OR REPLACE` is forbidden to prevent `ON DELETE CASCADE` data loss.)
  * `append`: `INSERT INTO ...`.
  * `update`: `UPDATE "t" SET ... WHERE "pk" = ...`.
  * `delete`: `DELETE FROM "t" WHERE "pk" = ...`.
  * `replace_all`: `DELETE FROM "t";` + batch `INSERT` inside the same transaction.
  * All batch writes execute inside `BEGIN IMMEDIATE ... COMMIT` using `StmtCache`. Supports all `PayloadHandle` types via `RecordMap`, not just `DynamicRecord`.
* **Reads:** Compile `ReadSpec` (projected columns, Predicate AST → parameterized `WHERE ?1..N`, `ORDER BY`, `LIMIT`, `OFFSET`) and return `DynamicRecord` payloads.
* **Count:** `SELECT COUNT(*) FROM "t"` using `writeQuotedIdent` and propagating errors.

---

## 6. Verification & Acceptance Criteria

1. **Driver Conformance Suite (core):** Shared test battery run identically against `memory` (table mode) and `sqlite`:
   * `upsert` partial update preserves untouched columns and writes explicit `null`s.
   * `upsert` on a parent row does **not** trigger `ON DELETE CASCADE` on child rows.
   * `append`, `update`, `delete`, `replace_all` semantics match across drivers.
   * `ReadSpec` with Predicate AST (`where`, `order_by`, `limit`, `offset`, projection) produces identical results.
   * Undeclared tables fail with `UnknownTable` when `schemaless == false`.
   * Preflight rejects type/nullability mismatches between task `TaskDescriptor_ABI` and `SchemaCatalog`.
2. **SQLite-Specific Suite:**
   * Strict tables reject `NULL` in PKs and enforce types.
   * All `PragmaConfig` options from `ConfigParam` take effect and errors include `sqlite3_errmsg`.
   * Non-destructive migration adds nullable/defaulted columns; destructive schema diff aborts cleanly.
   * Parameterized seeds escape values safely.

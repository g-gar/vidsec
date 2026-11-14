# 009B — Pure SQLite Library & SQLite Datasource Adapter

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-009B` |
| **Parent Master** | [`ARCH-009`](./009-unified-sqlite-storage-and-schema.md) |
| **Depends On** | [`ARCH-009A`](./009a-universal-repository-contract-and-core-schema.md) |
| **Related** | [`ARCH-009C (Optional SQLite Extensions)`](./009c-sqlite-optional-extensions.md) |
| **Area** | `libs/sqlite/`, `drivers/sqlite/` |
| **Status** | `IMPLEMENTED` |

---

## 1. Purpose & Design Principles

This specification implements the runtime storage driver for **SQLite** adhering strictly to the universal repository contract defined in [`ARCH-009A`](./009a-universal-repository-contract-and-core-schema.md).

Key Driver Principles:
1. **Isolated Pure Library (`libs/sqlite/`):** Completely independent from Flowdata; zero internal engine imports (`src/`). Exposed as a Zig module (`flowdata_sqlite`) in `build.zig` / `build.zig.zon` (`paths` must include `"libs"`), reusable across drivers, apps, CLI tools, and future Android native builds (`ARCH-031`).
2. **Synchronous Core:** `libs/sqlite/` and `SqliteRepository` are **100% synchronous** and single-connection (`*c.sqlite3`). Concurrency, async batching, and reactive backpressure are layered upstream via `SynchronizedRepository`, `AsyncBatchRepository`, and pull-based `RowIterator` (`ARCH-009A §2.5`).
3. **Cohesive Runtime Driver (`drivers/sqlite/`):** Connects the universal `Repository` interface (`WriteSpec`, `ReadSpec`, `readStream`, `SchemaCatalog`, `PredicateNode` pushdown, and `migrate` provisioning) to `libs/sqlite/` as one cohesive driver unit, toggled declaratively via `ConfigParam` and `Capabilities`. Optional tooling (inspectors, profilers, backups) is **not** part of the runtime driver and lives separately in [`ARCH-009C`](./009c-sqlite-optional-extensions.md).
4. **Data Safety First:** Prohibits `INSERT OR REPLACE` (which resets rowids and triggers cascading deletes); enforces `ON CONFLICT (...) DO UPDATE SET` touching only specified columns.

### Prerequisites (Before `009B` Functional Tests)
1. **Decouple `src/schema/` from `src/yaml/`:** Remove `../yaml/` imports from `src/schema/` (`yaml.Map`, `yaml.Scalar`, `parseYaml`) so `SchemaCatalog` is a pure in-memory AST, moving YAML decoding into `src/yaml/loaders/schema_loader.zig`.
2. **Migrate `extensions/datasource/` → `drivers/`:** Move `memory`, `file_store`, `yaml_file`, and `ssh_store` out of `extensions/datasource/` into `drivers/<name>/` with independent driver registration in `build.zig` (avoiding forced `sqlite3` linkage when unused).

---

## 2. Layer 1 — Pure SQLite Library (`libs/sqlite/`)

Extract and harden `db.zig` and `ddl.zig` from `extensions/datasource/sqlite/src/sqlite_lib/` into `libs/sqlite/`. Delete legacy `query.zig`.

### 2.1. Required Features & Primitives
* **Rich Error Reporting:** Surface `sqlite3_errmsg`, `sqlite3_extended_errcode`, and the failing SQL query string. No silent `catch {}`.
* **Full Engine Configuration:** `OpenOptions` + `PragmaConfig` exposing:
  * `read_only`, `create`, `full_mutex`, `busy_timeout_ms` (default 5000ms), `foreign_keys` (default on).
  * `journal_mode` (`wal`, `delete`, `truncate`, `memory`), `synchronous` (`normal`, `full`, `off`).
  * `auto_vacuum`, `cache_size`, `mmap_size`, `temp_store`, `journal_size_limit`, `wal_autocheckpoint`.
* **Execution Primitives:**
  * `StmtCache` (keyed by SQL query string for fast statement reuse).
  * Explicit transaction controls (`BEGIN IMMEDIATE` / `DEFERRED`).
  * Savepoint controls (`SAVEPOINT <id>`, `RELEASE <id>`, `ROLLBACK TO <id>`) for retries and checkpointing (`ARCH-020`).
  * Maintenance operations: `incrementalVacuum(pages)`, `optimize()`.
* **Null-Safe Row & Memory Lifetimes:**
  * `text()` and `blob()` return `?[]const u8` (`null` on `SQLITE_NULL`).
  * *Lifetime Rule:* SQLite column pointers are valid only until the next `step()` or statement finalization. Streaming cursor consumers must duplicate values into an `ArenaAllocator` when materializing long-lived records.
* **Strict Tables:** DDL generator emits `CREATE TABLE ... STRICT` for strong schema fidelity.

---

## 3. Layer 2 — SQLite Runtime Driver (`drivers/sqlite/`)

### 3.1. Declarative Configuration
Configured entirely via `ConfigParam` in `pipeline.yaml` (interpolated via `EnvInterpolator`), with **no CWD fallback**:
* `path` (default `:memory:`), `schema` (required unless `schemaless: true`), `read_only` (default `false`), `migrate` (`auto | verify | off`, default `auto`), `on_conflict` (`update | ignore | fail`, default `update`), `schemaless` (default `false`).
* Optional `PragmaConfig` overrides (`journal_mode`, `synchronous`, `busy_timeout_ms`, etc.).

### 3.2. Schema Provisioning & Phase 1 Migrations
* **DDL Mapping (`schema_provisioner.zig`):** Maps every `SchemaCatalog` attribute (`default`, `check`, `collate`, `generated_as`, `unique_keys`, `strict`, `without_rowid`, `indexes`) to SQLite DDL.
* **Seeds:** Parameterized `Stmt` bindings (`INSERT OR IGNORE`), never raw SQL string concatenation.
* **Tracking:** `PRAGMA user_version` + `_flowdata_schema` metadata table storing schema hash.
* **Phase 1 Non-Destructive Migrations (`migrate: auto`):**
  * `CREATE TABLE` for newly declared tables.
  * `ALTER TABLE ... ADD COLUMN` for new `nullable` columns or columns with a `default`.
  * `CREATE INDEX` / `DROP INDEX` for index changes.
* **Destructive Changes (Safety Guard):** Type changes, dropped columns, and modified primary keys abort startup with a detailed diff message. Complex transitions are deferred to pipeline-driven evolution.

### 3.3. Operation Compilation (`SqliteRepository`)
* **Writes (`WriteSpec`):**
  * `upsert`: `INSERT INTO "t" (...) VALUES (...) ON CONFLICT("pk"...) DO UPDATE SET "col" = excluded."col", ...` updating **only** columns in `RecordMap`.
  * `append`: `INSERT INTO ...`.
  * `update`: `UPDATE "t" SET ... WHERE "pk" = ...`.
  * `delete`: `DELETE FROM "t" WHERE "pk" = ...`.
  * `replace_all`: `DELETE FROM "t";` + batch `INSERT` within the same transaction.
  * Batch writes execute within `BEGIN IMMEDIATE ... COMMIT` using `StmtCache`. Supports dual payload execution via `RecordMap`:
    * **`Lowered(T)`**: Direct bind from contiguous struct memory via precomputed byte offsets (zero allocations per row).
    * **`DynamicRecord`**: Dynamic bind from `DynamicField` slices.
* **Reads & Streaming (`ReadSpec`):**
  * `readStream`: Primary path. Steps through SQLite cursor in chunked batches ($O(1)$ memory), pausing when worker queues reach backpressure capacity.
  * `read`: Block read returning contiguous `[]Lowered(T)` if `target_schema_id != null`, or `DynamicRecord` if schemaless/ad-hoc.
* **Count:** `SELECT COUNT(*) FROM "t"` using identifier quoting.

---

## 4. Verification & SQLite-Specific Suite

Run alongside the `ARCH-009A` Conformance Suite:
1. Strict tables reject invalid types and nulls in PKs.
2. `upsert` partial updates preserve untouched fields and do not trigger cascading foreign key deletions.
3. All `PragmaConfig` parameters take effect; errors report `sqlite3_errmsg`.
4. Non-destructive migrations add columns safely; destructive schema diffs abort cleanly without data loss.
5. Parameterized seeds escape values safely.


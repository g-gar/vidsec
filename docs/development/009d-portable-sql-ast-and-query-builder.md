# 009D — Portable SQL AST & Expressive Query Builder (`libs/sql/`)

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-009D` |
| **Parent Master** | [`ARCH-009`](./009-unified-sqlite-storage-and-schema.md) |
| **Depends On** | [`ARCH-009A`](./009a-universal-repository-contract-and-core-schema.md), [`ARCH-009B`](./009b-sqlite-datasource-and-engine.md) |
| **Area** | `libs/sql/`, `libs/sqlite/`, `drivers/sqlite/` |
| **Status** | `IMPLEMENTED` |

---

## 1. Purpose & Design Principles

`ARCH-009B` intentionally removed the legacy `query.zig` string-builder so the SQLite driver could ship cleanly with `StmtCache`, `PredicateNode` pushdown, and `Repository` conformance. However, building SQL statements via manual `ArrayListUnmanaged(u8)` appends inside `drivers/sqlite/` (and future SQL drivers like PostgreSQL or MySQL) is repetitive and error-prone.

`ARCH-009D` introduces **`libs/sql/`**, a pure, zero-dependency **SQL AST & Dialect Compiler** library:

1. **AST First, Strings Last:** Queries (`Select`, `Insert`, `Update`, `Delete`, `Expr`, `OnConflict`) are constructed as structured Zig data — **zero SQL string concatenation** until `.compile(dialect, allocator)` is called.
2. **Engine-Agnostic AST + Dialect Backend:**
   * The AST captures the ~80% common SQL surface (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `WHERE`, `ORDER BY`, `LIMIT`/`OFFSET`, `ON CONFLICT`).
   * Engine quirks are isolated in `Dialect` implementations:
     * **Identifier quoting:** `"col"` (SQLite / Postgres) vs `` `col` `` (MySQL).
     * **Placeholders:** `?1, ?2` (SQLite) vs `$1, $2` (Postgres) vs `?, ?` (MySQL).
     * **Upsert syntax:** `ON CONFLICT(...) DO UPDATE SET` (SQLite / Postgres) vs `ON DUPLICATE KEY UPDATE` (MySQL).
3. **Output Contract:** `compile()` returns a `CompiledQuery { sql: []const u8, bindings: []const SqlValue }` ready to feed directly into `StmtCache` or any remote SQL client.
4. **Zero Flowdata Coupling:** `libs/sql/` has zero imports from `src/` (only `std`), making it usable by `libs/sqlite/`, `drivers/sqlite/`, future SQL drivers, and standalone apps.

---

## 2. Planned Scope

### 2.1. `libs/sql/` (Pure Library, `flowdata_sql`)
* `ast.zig`: `SelectQuery`, `InsertQuery`, `UpdateQuery`, `DeleteQuery`, `Expr` (binary ops, `is_null`, `in_list`, literals, column refs), `OrderBy`, `OnConflictClause`.
* `dialect.zig`: `Dialect` enum/vtable (`sqlite`, `postgres`, `mysql`) with identifier quoting, placeholder formatting, and upsert rendering.
* `compiler.zig`: `compile(dialect, allocator, query) -> CompiledQuery`.

### 2.2. `libs/sqlite/` & `drivers/sqlite/` Integration
* Expose `libs/sqlite/` adapter helpers to execute `CompiledQuery` directly via `Db` / `StmtCache`.
* Refactor `drivers/sqlite/src/sqlite_repository.zig` and `predicate_compiler.zig` to build `SelectQuery` / `InsertQuery` / `UpdateQuery` / `DeleteQuery` ASTs instead of manual buffer `appendSlice` calls.


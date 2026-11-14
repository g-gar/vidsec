# Global Coding Agent Directives (`AGENTS.md`)

This file defines the cross-cutting engineering rules and invariants for any AI agent (Gemini, Claude, etc.) implementing milestones `M0` through `M5` of the **`vidsec`** project (located in `specs/M0_*.md` .. `specs/M5_*.md`).

---

## 1. Environment, Compiler, and Base Dependency (`SQLite3`)
- **Language & Version:** Zig `0.13.0` / `0.14.0` (Avoid deprecated `0.11` or earlier APIs in `std.Build` and `std.ArrayListUnmanaged`).
- **State Engine & Relational IR:** All shared state across stages (`ContainerIR`, `audit_findings`, traces, and the clean artifact chain `working_artifacts`) resides in a **SQLite3** database (`*sqlite3`).
- **Strict Single-Link Rule for `libsqlite3` (`build.zig`):**
  - **Never link SQLite statically separately in the host and in `.so` plugins** (having multiple static copies of `sqlite3.c` in the same process corrupts mutexes and global page-allocator state when sharing a `*sqlite3` pointer across `dlopen`).
  - Both the main `vidsec` executable (`M0`) and all `addSharedLibrary` dynamic libraries (`M1`–`M5`) **must dynamically link against the same system shared library** (`step.linkSystemLibrary("sqlite3")` + `step.linkLibC()`), guaranteeing a single `libsqlite3.so` instance in the process address space.
- **Default Build Mode:** Safe mode (`ReleaseSafe`, or `Debug` in tests) to guarantee runtime bounds checking.

---

## 2. Strict Security, SQLite, and Plugin Versioning Rules

1. **Literal Adherence to Public Contracts, SQL Schemas, and UML Diagrams:**
   - Every `struct`, `extern struct`, `enum`, `union(enum)`, `error` set, SQL table, and `pub fn` signature defined in Sections 2 and 3 of each milestone must be respected character for character.
   - Plugins from `M1` to `M5` communicate with the engine (`M0`) exclusively through `src/core/plugin_abi.zig` (`VidsecPluginABI` and `PipelineContext_ABI` with `callconv(.C)`), which hands them the active `*sqlite3` pointer.

2. **SQLite Safety & Performance (`Prepared Statements` + Transactions + Deferred Indexes):**
   - **Never concatenate strings to build SQL from file data:** Every `INSERT` or `SELECT` that includes box names, paths, URIs, or metadata extracted from a container must use prepared statements (`sqlite3_prepare_v2` + `sqlite3_bind_*`).
   - **Transactional batch inserts and trailing indexes:** Plugins that insert thousands of rows (`M1` dumping `ir_regions` or `M3` dumping `ir_sample_extents`) must wrap the dump in an explicit transaction (`BEGIN IMMEDIATE;` ... `COMMIT;`), reusing a single `sqlite3_stmt` with `sqlite3_reset()`, and **execute `CREATE INDEX IF NOT EXISTS` statements after the insert loop** (just before `COMMIT`) to avoid rebalancing B-Trees on every row.
   - **Future concurrency:** The database is configured with `PRAGMA busy_timeout = 5000;` (and `PRAGMA journal_mode = WAL;` when operating on disk) to allow multiple read-only audit steps (`M2`/`M3`) to run in parallel without lock contention.

3. **3-Tier Versioning & Dependency Matrix (ABI vs SemVer + Hard Plugin Dependencies vs SQLite DDL Banks):**
   - To allow a stable plugin (e.g., `M1 v1.0.0`) to coexist with fast-evolving plugins (e.g., `M2 v5.2.0`), and to support both `ContainerIR`-based plugins and raw-binary plugins, every plugin declares in `VidsecPluginABI`:
     1. `abi_version: u32`: Binary version of `PipelineContext_ABI` (must match the `M0` engine exactly, `VIDSEC_ABI_VERSION = 1`).
     2. `plugin_version: SemVer_ABI` and `requires_plugins_ptr: ?[*]const PluginDependency_ABI` (`requires_plugins_len: usize`): The plugin's own version and list of **Hard Dependencies** (IDs of other plugins that must execute earlier in `pipeline.yaml`, with their `min_version`). A specialized plugin operating directly on raw bytes via `cursor_read_at` may declare `requires_plugins_len = 0`.
     3. `requires_schemas_ptr: ?[*]const SchemaContract_ABI` (`requires_schemas_len: usize`): **SQLite schema banks** (`domain`, `version`, `writable`) that the plugin needs mapped. At startup (*pre-flight*), `PluginLoader` lazily loads the physical DDL file `configs/schemas/<domain>_v<version>.sql` for each requested bank and configures the `sqlite3_set_authorizer` firewall to allow writes only on banks with `writable = true`.

4. **Mandatory Safe Arithmetic on Untrusted Data:**
   - Every input media file is considered **hostile by default** (*Zero-Trust*).
   - Any addition, subtraction, or multiplication involving offsets, lengths, or counts read from a binary container must use `std.math.add(u64, a, b)`, `std.math.sub(u64, a, b)`, or `std.math.mul(u64, a, b)`.
   - **Forbidden:** using raw `+`, `-`, or `*` operators on sizes declared in binary headers.

5. **No `unreachable` or `@panic` on Data or Plugin Paths:**
   - A truncated, corrupt, or malicious file, a malformed YAML, a SQLite error, or a faulty external plugin **must never abort the main process**.
   - Every anomaly must be returned as a typed error or recorded in the `audit_findings` table (`AuditFindingRow`) / notified via `emit_event` / `StepVerdict_ABI.abort_threat`.

6. **Heap Isolation and Zero Memory Leaks:**
   - All unit and integration tests must run using `std.testing.allocator` and close every `sqlite3_finalize` statement and `sqlite3_close_v2` connection.

---

## 3. Per-Milestone Workflow (`specs/M0` $\rightarrow$ `specs/M5`)

When implementing a milestone `MX`:
1. Read this file (`AGENTS.md`) and only the corresponding `specs/MX_*.md` specification.
2. Implement the modules in the `classDiagram` (`Section 2`), the Zig signatures and SQL schemas (`Section 3`), and the memory model (`Section 4`).
3. Run `zig build` and `zig build test`.
4. **Do not mark the milestone complete** until 100% of the test vectors (`Section 7`) pass with 0 errors, 0 warnings, and 0 memory leaks or unfinalized SQLite cursors.

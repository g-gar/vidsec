# Standard Milestone Specification Template (`MILESTONE_TEMPLATE.md`)

> [!IMPORTANT]
> **Purpose of this document:**
> This template defines the **mandatory** structure that documents `M0` through `M5` must follow inside `docs/v1/specs/`.
> Each milestone is designed as a **modular, independent package** that plugs into the engine (`M0`) and operates against the **SQLite** state and IR database, enabling a coding agent (Gemini, Claude, etc.) to implement and verify each milestone autonomously with `zig build test`.

---

## Mandatory Structure of Each `M[0-5]_*.md` Document

> [!NOTE]
> Global Zig compiler directives, safe SQLite usage (`prepared statements` and transactions), the 3-tier versioning matrix, and the ban on `@panic`/`unreachable` are centralized in [`../AGENTS.md`](../AGENTS.md) and are not repeated in each milestone.

---

### 1. Functional Scope and Compatibility Contracts
*Direct summary of what this milestone builds, the SQLite tables it produces or consumes, and its version contract.*

- **Milestone Objective (1 paragraph):** What capability this package contributes to the `vidsec` ecosystem.
- **Plugin Versioning & Dependency Contract (`VidsecPluginABI`):**
  - `abi_version`: `1`
  - `plugin_version`: `SemVer_ABI` (e.g., `1.0.0`)
  - `requires_schemas_ptr` / `requires_schemas_len`: Slice of SQLite DDL banks `SchemaContract_ABI` (`domain`, `version`, `writable`) that `M0` provisions from `configs/schemas/<domain>_v<version>.sql` when loading the plugin.
  - `requires_plugins_ptr` / `requires_plugins_len`: Slice of *Hard Dependencies* `PluginDependency_ABI` (`plugin_id`, `min_version`) that must execute earlier in the pipeline (or empty if the plugin is standalone).

---

### 2. Milestone UML Architecture (`classDiagram`)
*UML Class Diagram adapted to Zig (where each `.zig` file is a `struct`/module). Each node title indicates its path (`path/module.zig :: StructName`), showing at a glance the milestone's modules, their fields, methods, and interaction with `PipelineContext_ABI` / `sqlite3`.*

```mermaid
classDiagram
    direction TB

    class VidsecPluginABI["src/core/plugin_abi.zig :: VidsecPluginABI"] {
        <<extern struct (C-ABI)>>
        +abi_version: u32
        +plugin_id: [*:0]const u8
        +plugin_version: SemVer_ABI
        +requires_schemas_ptr: ?[*]const SchemaContract_ABI
        +requires_schemas_len: usize
        +requires_plugins_ptr: ?[*]const PluginDependency_ABI
        +requires_plugins_len: usize
        +execute_step(ctx: *PipelineContext_ABI) callconv(.C) StepVerdict_ABI
    }

    class FormatDriver["src/m1_parsers/driver.zig :: FormatDriver"] {
        <<interface>>
        +format: FormatKind
        +walkFn(cursor: *SafeCursor, db: *sqlite3, ...) DriverError!void
    }

    class IsobmffDriver["src/m1_parsers/drivers/isobmff.zig :: IsobmffDriver"] {
        +walkBoxes(cursor: *SafeCursor, stmt: *sqlite3_stmt, depth: u8) DriverError!void
    }

    IsobmffDriver ..|> FormatDriver : vtable
```

---

### 3. Zig Type Contracts and SQLite Schema (`DDL / Queries`)
*The core of the specification. Divided into two mandatory subsections:*

#### 3.A. Zig Types, Errors, and Public Signatures
- **Explicit `Error Sets`** (`DriverError`, `SqliteError`, etc.).
- **Data structures (`struct` / `extern struct`)** and `export const vidsec_plugin_descriptor` descriptors.

#### 3.B. Required / Produced SQLite Schema Contract (`SQL Schema & Queries`)
- **Created or Modified Tables and Indexes (`CREATE TABLE`, `CREATE INDEX`):** Exact SQL definition with types (`INTEGER`, `TEXT`, `BLOB`, `REAL`) and constraints.
- **Standard Queries or Inserts (`Prepared Statements`):** The parameterized SQL queries (`?1`, `?2`) executed by each step of this milestone on the shared SQLite database.

---

### 4. Memory Model, Arenas, and SQLite Transactions
*Establishes memory ownership rules and SQLite statement lifecycles.*

| Resource / Structure | Owner / Storage | Lifetime | Who frees / closes |
| :--- | :--- | :--- | :--- |
| Intermediate Representation (`ir_*`), Findings (`audit_findings`), and Artifacts (`working_artifacts`) | `sqlite3*` database (`:memory:` or `.sqlite` file) | Entire pipeline run on the current file. | `PipelineContext.deinit()` in `M0` (`sqlite3_close_v2`). |
| Prepared statements (`*sqlite3_stmt`) of a Step | Executing plugin | Only during the `execute_step` call. | `defer sqlite3_finalize(stmt)` before returning from `execute_step`. |
| Temporary read buffers (`SafeCursor`) | Step-local `ArenaAllocator` or stack `[4096]u8` | Only during `execute_step`. | `defer local_arena.deinit()`. |

- **DoS Protection Constants (Hard Limits):**
  - E.g.: `MAX_BOX_DEPTH = 32`, `MAX_IR_REGIONS = 250_000`, `SQLITE_BATCH_COMMIT_SIZE = 10_000`.

---

### 5. Algorithmic Flow (`sequenceDiagram`) and Edge Cases
*Combines a UML sequence diagram to visualize dynamic interaction between the plugin, `SafeCursor`, and `SQLite` with a table of mandatory edge cases.*

1. **Sequence Diagram (`sequenceDiagram`) and step-by-step flow:**
   ```mermaid
   sequenceDiagram
       participant Host as PipelineEngine (M0)
       participant Plugin as Step Plugin (.so)
       participant Cursor as SafeCursor
       participant DB as SQLite3 (:memory: / WAL)

       Host->>Plugin: execute_step(ctx_abi)
       Plugin->>DB: BEGIN IMMEDIATE TRANSACTION
       Plugin->>DB: sqlite3_prepare_v2("INSERT INTO ir_regions ...")
       loop Each container box
           Plugin->>Cursor: readU32Be() + readFourCC()
           Plugin->>DB: sqlite3_bind_* + sqlite3_step() + sqlite3_reset()
       end
       Plugin->>DB: sqlite3_finalize(stmt) + COMMIT
       Plugin-->>Host: StepVerdict_ABI.proceed
   ```
2. **Mandatory Edge Cases Table:**
   - Binary format boundary cases and SQLite error handling (`SQLITE_BUSY`, `SQLITE_CONSTRAINT`, transaction rollback on error).

---

### 6. Declaration in `pipeline.yaml` and Optional Plugin Configuration
*Shows how the plugin is registered in the `plugins:` array (with its `.so` path, optional version constraint, and optional `config:` file) and how it is invoked in the `pipeline:` tree.*

---

### 7. Raw Binary Vectors and Acceptance Test Suite (`zig build test`)
*Provides binary micro-containers encoded as Zig byte arrays (`[_]u8{ ... }`) and SQL verification queries so the milestone's tests are 100% self-contained.*

- **Test Vector 1 (Clean Case / Happy Path):** Exact hex bytes + verification via `SELECT COUNT(*) FROM ...` in SQLite.
- **Test Vector 2 (Malicious Case / Synthetic Exploit):** Exact hex bytes with the injected anomaly + verification of the row recorded in `audit_findings`.
- **Autonomous Verification Checklist:**
  1. `zig build` compiles with 0 errors and 0 warnings.
  2. `zig build test` passes 100% of tests with no leaks in `std.testing.allocator` and no unfinalized SQLite statements (`sqlite3_next_stmt == null`).

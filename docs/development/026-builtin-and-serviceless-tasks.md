# 026 — Builtin Engine Tasks & Service-Less Glue Tasks (Architectural Analysis)

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-026` |
| **Depends On** | [`ARCH-016`](./016-reactive-bifurcation-parallel-expansion-and-join.md) (§9), [`ARCH-023`](./023-pluggable-routing-strategy-decoupling.md), [`ARCH-025`](./025-datasource-roles-and-batch-emission-decoupling.md) |
| **Area** | `src/plugin/`, `src/engine/`, `src/ast/` |
| **Status** | `SPECIFICATION` |

---

## 1. Context & Problem Statement

Pipelines frequently need **engine-provided basic tasks** and **service-less glue steps** that do not belong to a domain `.so` plugin:

1. **Generic reusable SDK tasks** (already specified in [`ARCH-016 §9`](./016-reactive-bifurcation-parallel-expansion-and-join.md), Phase 16.6, `PENDING`): `core/download_resource`, `core/validate_payload`, `core/file_sink`.
2. **Infrastructure / edge-case glue tasks without a domain `Service`:**
   * Assembling a typed `JobItem` by reading and combining **multiple datasources** (e.g. `tracked_targets` + `catalog_db`) so downstream domain `Service`s can match via `canHandle()`.
   * Running an ad-hoc raw SQL query against a `sqlite` datasource (escape hatch so the framework does not artificially restrict the developer).

### Core Architectural Tension
* [`flowdata_plugin`](../../src/plugin.zig) (`src/plugin/`) is the zero-dependency C-ABI & Guest SDK compiled into external `.so` plugins. It **cannot** directly import `src/engine/`, `src/ast/`, or `src/repository/` (otherwise every `.so` plugin would bundle the host runtime and create circular dependencies).
* At the same time, builtin tasks **should** reuse the exact same definitions declared in `src/plugin/` (`TaskDescriptor_ABI`, `TaskContext_ABI`, `HostApiVTable_ABI`, `defineTaskService`) rather than inventing a parallel execution path in `Coordinator`, and they must be **built into the engine automatically** (not packaged as an optional `extensions/` module that every app has to manually install).

---

## 2. Options Analysis

### Option A — Host-Registered Builtin Module Implementing `TaskDescriptor_ABI`
* **Where it lives:** `src/plugin/builtin/` (for pure SDK tasks) + host registration in `ModuleRegistry` (`src/plugin/loader/`) / `PipelineRunner`, auto-loaded for every pipeline.
* **How it works:**
  * Pure tasks (`core/download_resource`, `core/validate_payload`, `core/file_sink`) use `defineTaskService` from `flowdata_plugin` directly.
  * Host-privileged tasks (`core/sql_query`, `core/assemble_inputs`) live on the host side (`src/engine/builtin/` or `src/plugin/loader/builtin/`) where `RepositoryRegistry` is visible, but **still expose the exact same `TaskDescriptor_ABI` / `ModuleManifest_ABI`** from `src/plugin/`.
* **Pros:**
  * Zero changes needed to `Coordinator`, `RoutingStrategy`, `WorkerPool`, or `StepArena`.
  * Zero manual extension wiring in apps (`apps/mangadex`, `apps/vidsec`, etc.).
  * Uniform `uses: core/<task>` syntax in `pipeline.yaml`.
* **Cons:**
  * Host-privileged builtins cannot use `defineTaskService` with a DI-injected datasource handle unless `HostApiVTable_ABI` exposes a datasource bridge (which leads to Option B).

### Option B — Extend `HostApiVTable_ABI` with a `DatasourceBridge` (Mirrors `NetworkBridge`) — **Recommended**
* **Precedent in this codebase:** `core/download_resource` in `ARCH-016 §9` does **not** import `src/engine/network.zig` into `src/plugin/`. Instead, `HostApiVTable_ABI` exposes a generic network call, and `flowdata_plugin` provides a DI-injectable `NetworkBridge`!
* **How it works:**
  * Add generic C-ABI callbacks to `HostApiVTable_ABI` (`src/plugin/types/`), e.g. `read_datasource`, `query_datasource` (raw SQL / filter), `emit_record`.
  * Add a lightweight `DatasourceBridge` in `src/plugin/sdk/` (zero dependency on `src/repository/`).
  * Enforce **least privilege** in `TaskStepSpec` (just like `networks:`): a step only sees the datasources bound to it (or declared in `datasources:` with matching `role:`).
  * Builtin tasks (both pure `core/*` and datasource-aware `core/sql_query`, `core/emit_items`) are auto-registered in `ModuleRegistry` using the **same `src/plugin/` SDK** (`defineTaskService` or raw `TaskDescriptor_ABI` without a `Service` struct).
* **Pros:**
  * Keeps `flowdata_plugin` 100% dependency-free while letting builtin tasks (and authorized plugins) use `src/plugin/` definitions natively.
  * Unifies `Service`-backed tasks and service-less raw `TaskDescriptor_ABI` handlers under one ABI.
  * Auto-available in every app without installing an extension.
* **Cons:**
  * Requires a minor C-ABI version bump (`FLOWDATA_ABI_VERSION`) and wiring the host callbacks in `task_executor.zig` / `Coordinator`.

### Option C — External Extension (`extensions/builtin_tasks`) — *Not Recommended for Core Builtins*
* **How it works:** Package builtin tasks as an `Extension` in `extensions/` registered via `KernelContext`.
* **Why it falls short:** Forces every application (`apps/mangadex`, `apps/vidsec`, new projects) to explicitly import and install an extension for basic engine primitives. Good for optional third-party integrations, poor ergonomics for core engine tasks.

### Option D — Inline AST / YAML Step Variant (`sql:`, `assemble:` without `uses:`) — *Optional Sugar Only*
* **How it works:** Allow `TaskStepSpec` / `StepNode` to omit `uses:` when an inline directive like `sql:` is present, lowering it at AST-load or pre-flight time to `uses: core/sql_query` with `static_params`.
* **Assessment:** Useful as declarative YAML sugar **on top of Option B**, never as a separate execution path in `Coordinator`.

---

## 3. Recommended Direction (Option B + Option A, with Optional D Sugar)

1. **Keep one unified task contract (`TaskDescriptor_ABI`):** Both `defineTaskService` tasks and service-less ad-hoc tasks (`can_handle == null` or schema-based `can_handle`) execute through the same `TaskExecutor` + `StepArena` + `Coordinator` pipeline.
2. **Auto-register `core` builtins in `ModuleRegistry`:** Every `PipelineRunner` / `PipelineEngine` initializes the `core` builtin module automatically—zero boilerplate in `apps/*`.
3. **Add `DatasourceBridge` to `HostApiVTable_ABI`:** Mirrors `NetworkBridge`, preserving `flowdata_plugin`'s isolation while unlocking `core/sql_query` and multi-datasource `JobItem` assembly tasks.

---

## 4. Proposed Builtin Catalog (`core/*`)

| Task | Source | Purpose |
| :--- | :--- | :--- |
| `core/download_resource` | `ARCH-016 §9` | Elemental HTTP/resource fetch via `NetworkBridge`. |
| `core/validate_payload` | `ARCH-016 §9` | Schema / predicate validation gate. |
| `core/file_sink` | `ARCH-016 §9` | Atomic file output sink. |
| `core/sql_query` | `ARCH-026` | Escape-hatch raw SQL query against a `sqlite` (`source`/`duplex`) datasource via `DatasourceBridge`. |
| `core/emit_items` | `ARCH-025` / `026` | Reads/combines 1..N datasources and fans out individual `JobItem`s downstream. |

---

## 5. Open Decisions Before Implementation
1. **Least-privilege binding:** Should `DatasourceBridge` require steps to list accessible datasources (e.g. `datasources: [tracked_targets, catalog_db]` on `TaskStepSpec`, mirroring `networks:`), or allow any `source`/`duplex` datasource for `core/*` builtins?
2. **ABI bump timing:** Coordinate the `HostApiVTable_ABI` addition with `ARCH-025` Phase 4 (multi-datasource pseudo-emission).

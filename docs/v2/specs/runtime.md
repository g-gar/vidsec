# Runtime, Environment, and Modules Specification (`v2/specs/runtime.md`)

This document specifies the global execution environment of a `flowdata` / `vidsec v2` pipeline: `.env` interpolation, the `runtime:` configuration block, and the `modules:` dynamic plugin catalog.

---

## 1. Environment Variable Interpolation (`.env`)

Before parsing scalar values in `pipeline.yaml`, the environment preprocessor (`src/yaml/env.zig`) resolves variables from `.env` files or the operating system environment:
* `${VAR_NAME}`: Replaced by the variable value; fails at pre-flight (`error.MissingRequiredEnvVar`) if undefined.
* `${VAR_NAME:-default_value}`: Replaced by the variable value, or falls back to `default_value` if undefined.

Example `.env`:
```dotenv
VIDSEC_WORKERS=auto
VIDSEC_DEFAULT_NET=isolated
VIDSEC_DB_PATH=./state/pipeline.db
VIDSEC_MAX_MEM_MB=512
VIDSEC_TRACE_FILE=./logs/trace.jsonl
```

---

## 2. Engine Runtime Configuration (`runtime:`)

The `runtime:` block defines global thread budgets, default isolation policies, memory envelopes, and execution telemetry for the pipeline engine.

```yaml
version: 2

runtime:
  workers: "${VIDSEC_WORKERS:-auto}"              # "auto" (CPU core count) | integer (1, 4, 8, 16)
  default_network: "${VIDSEC_DEFAULT_NET:-isolated}" # Default virtual network adapter for steps
  max_task_memory_mb: "${VIDSEC_MAX_MEM_MB:-512}" # Per-task arena/heap quota
  trace_file: "${VIDSEC_TRACE_FILE:-./logs/trace.jsonl}"
```

### 2.1. Concurrency and Determinism (`runtime.workers`)

The engine unifies strict determinism and multi-core data parallelism under a single canonical parameter (`workers`):
* `workers: auto`: Detects available host CPU cores and dispatches data-parallel chunks across the `ThreadPool`.
* `workers: 1`: Forces deterministic single-threaded execution on the caller thread (ideal for step-by-step debugging and reproducible test suites).
* **CLI Override:** Passing `-j <N>` or `--workers <N>` on the CLI (`vidsec run pipeline.yaml -j 1`) overrides `runtime.workers` without modifying the YAML file.

### 2.2. Default Network Isolation (`runtime.default_network`)

Specifies which Virtual Network Adapter ([`v2/specs/networks.md`](./networks.md)) is bound to steps that omit an explicit `network:` attribute:
* Setting `default_network: isolated` (`driver: none`) enforces **air-gapped execution by default**, guaranteeing that pure computational steps cannot accidentally perform network I/O unless explicitly granted an egress or tap adapter.

---

## 3. Dynamic Module Catalog (`modules:`)

The `modules:` block registers external native plugins (`.so` / `.dylib` / `.dll`) compiled against the `flowdata` / `vidsec` C-ABI (`VIDSEC_ABI_VERSION = 2`).

```yaml
modules:
  triage:   { path: "./plugins/libtriage.so" }
  isobmff:  { path: "./plugins/libisobmff.so" }
  mangadex: { path: "./plugins/libmangadex.so" }
  archiver: { path: "./plugins/libarchiver.so" }
```

### 3.1. Pre-Flight Verification and Loading Rules
1. **Permission & Ownership Verification:** Before invoking `dlopen`, the Host verifies that the `.so` binary is not world-writable (`verify_safe_module_permissions.zig`).
2. **Manifest Handshake (`vidsec_module_manifest`):** Each module exports a single C-ABI symbol returning `ModuleManifest_ABI`, declaring its `abi_version`, module name, semantic version, and array of `TaskDescriptor_ABI` entrypoints.
3. **Task Addressing (`uses: <module>/<task>`):**
   * `uses: <module_name>/<task_name>` resolves the specific named `TaskDescriptor_ABI` inside the module.
   * `uses: <module_name>` resolves the module's default task (`tasks_ptr[0]`).

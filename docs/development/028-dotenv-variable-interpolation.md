# 028 — Dotenv Variable Reuse & Intra-File Interpolation

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-028` |
| **Area** | `src/yaml/env.zig`, `apps/*/configs/.env*` |
| **Status** | `IMPLEMENTED (Option 1)` |

---

## 1. Context & Problem Statement

In `src/yaml/env.zig`, `EnvInterpolator` currently performs `${VAR}` / `${VAR:-default}` expansion only when `interpolate()` is invoked via `scalarHook()` while parsing YAML files (`pipeline.yaml`).

Inside `parseDotEnv()` (`src/yaml/env.zig`), values are stored verbatim into `self.vars` and `setenv()` without running `self.interpolate()`. As a result, `.env` files cannot reference previously defined variables—for example, reusing a shared host across SSH and HTTP settings:

```dotenv
KOMGA_HOST=192.168.1.50
KOMGA_SSH_HOST=${KOMGA_HOST}
KOMGA_URL=http://${KOMGA_HOST}:25600
```

Without intra-`.env` interpolation, users must duplicate `192.168.1.50` across `KOMGA_HOST`, `KOMGA_SSH_HOST`, and `KOMGA_URL`, increasing configuration drift and error risk.

---

## 2. Options Analysis

### Option 1 — Native `${VAR}` Interpolation in `parseDotEnv()` *(Selected)*

* **Where it lives:** `src/yaml/env.zig` (`EnvInterpolator.parseDotEnv`).
* **How it works:**
  * Track whether `raw_val` was single-quoted (`'...'`). Following standard dotenv semantics, single-quoted values are preserved literally (no expansion).
  * For unquoted or double-quoted (`"..."`) values, pass `raw_val` through `try self.interpolate(arena, raw_val)` before storing it in `self.vars` and calling `setenv()`.
  * Because `parseDotEnv()` processes lines top-to-bottom, any variable declared earlier in the file (or already present in the process environment when `use_process_env = true`) is immediately available to subsequent lines, including `${VAR:-default}` fallbacks.
* **Pros:**
  * **Single source of truth in `.env`:** Shared values like `KOMGA_HOST` are defined once and composed cleanly into `KOMGA_SSH_HOST`, `KOMGA_URL`, etc.
  * **Consistent across the entire stack:** Works identically for `pipeline.yaml` loading (`PipelineRunner`) and direct `AppConfig.load()` consumers without duplicating composition logic.
  * **Minimal, self-contained change:** Reuses the existing `EnvInterpolator.interpolate()` implementation with zero new syntax or external dependencies.
* **Cons:**
  * Declaration order matters within `.env` (a variable must be defined above the line that references it, which matches standard shell/dotenv behavior).

### Option 2 — Composing Derived Values in `pipeline.yaml` / `AppConfig` *(Not Selected)*

* **Where it lives:** `apps/mangadex/configs/pipeline.yaml` and `apps/mangadex/src/config.zig`.
* **How it works:**
  * Keep `parseDotEnv()` strictly literal and construct derived values downstream (e.g., `http://${KOMGA_HOST:-localhost}:${KOMGA_PORT:-25600}` in `pipeline.yaml` or `AppConfig.load()`).
* **Why it falls short:**
  * Leaks URL/connection composition into application code (`AppConfig`) and YAML templates instead of keeping `.env` self-contained.
  * Forces extra granular variables (`KOMGA_SCHEME`, `KOMGA_PORT`) even when a user simply wants to override `KOMGA_URL` directly.
  * Does not solve variable reuse for any other `.env` keys outside those explicitly hardcoded in `AppConfig` or `pipeline.yaml`.

---

## 3. Decision

**Option 1 is selected** as the cleaner, more idiomatic, and universally extensible solution.

### Implementation Summary (`src/yaml/env.zig`)
1. In `parseDotEnv()`, record `const is_single_quoted = (raw_val.len >= 2 and raw_val[0] == '\'' and raw_val[raw_val.len - 1] == '\'');` before stripping quotes.
2. Compute `const resolved_val = if (is_single_quoted) raw_val else try self.interpolate(arena, raw_val);`.
3. Store `resolved_val` in `self.vars` and `setenv()`.
4. Add unit tests covering:
   * Sequential variable reuse (`A=foo`, `B=${A}/bar`).
   * `${VAR:-default}` fallback inside `.env`.
   * Single-quoted literal preservation (`C='${A}'` stays `${A}`).


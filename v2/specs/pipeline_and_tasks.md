# Task and Pipeline Execution Specification (`v2/specs/pipeline_and_tasks.md`)

This document specifies the *Black Box* task model, dataflow stream processing semantics, multi-stream operations, concurrency budgets, and routing logic in `vidsec v2`.

---

## 1. Black Box Task Model

In `vidsec v2`, a task is a deterministic, pure computational unit:

```
Inputs (Stream / Parameters / Memory) ──► [ Native Zig Task ] ──► Outputs (Typed Struct)
```

### Core Design Rules:
1. **Zero SQL:** Native task code never imports `sqlite3.h`, prepares SQL statements, or assumes database table structures.
2. **Zero Intermediate `emitRow` Calls:** Tasks consume inputs and return their completed output struct or slice upon termination.
3. **Determinism:** Given identical inputs, a task produces byte-for-byte identical outputs with zero side-effects outside its assigned memory.

---

## 2. Dataflow Methodology and Cardinality Matrix

To eliminate micro-step fragmentation and obscure reactive syntax, the engine governs execution through **Type Inference and Automatic Lifting**.

### 2.1. Canonical Cardinality Matrix (2x2)

| Operation | Zig Signature | Pipeline Input | Resulting Output | Engine Behavior | Concrete Example |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Elemental** ($1 \rightarrow 1$) | `T -> U` | Scalar `T` | Scalar `U` | Single direct invocation | `probe_file(file) -> triage` |
| **2. Expansion** ($1 \rightarrow N$) | `T -> []U` | Scalar `T` | Collection `[]U` | Generator / Unpacking | `lower_mp4(file) -> []IrRegion` |
| **3. Aggregation** ($N \rightarrow 1$) | `[]T -> U` | Collection `[]T` | Scalar `U` | **Reduction / Packaging** | `bundle_cbz([]Image) -> File` |
| **4. Batch Transform** ($N \rightarrow M$) | `[]T -> []U` | Collection `[]T` | Collection `[]U` | **Bulk Transformation** | `coalesce_samples([]Sample) -> []Sample` |

### 2.2. Automatic Lifting
* **Elemental Tasks ($T \rightarrow U$):**
  If the pipeline delivers a stream collection `[]T`, the engine **automatically lifts the task element-by-element** across the stream ($N \rightarrow N$), without requiring loop syntax or specialized keywords.
  *(Example: `download_page(url: text) -> ImageBuffer` mapped over an array of URLs).*
* **Collection Tasks ($[]T \rightarrow U$ or $[]T \rightarrow []U$):**
  The engine supplies the entire slice so the native task can execute holistic algorithms (such as interval coalescence, topological sorting, or archive compression).

---

## 3. The Boundary: Engine Algebra vs. Task Computation

To prevent conflicts between declarative engine filtering and bulk task logic in Zig, the lifecycle strictly enforces three distinct phases:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   PHASE 1: Host Engine Algebra                         │
│                                                                        │
│  1. Multi-Input:   merge(stream_a, stream_b) | zip(stream_a, stream_b) │
│  2. Selection:     where: "item.length > 64" (Declarative Filter)      │
│  3. Slicing:       limit: 100, skip: 10                                │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ (Clean, pre-filtered collection)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   PHASE 2: Native Task Computation (Zig)               │
│                                                                        │
│  • If task expects `T`:     Element-by-element streaming / lifting     │
│  • If task expects `[]T`:   Holistic set algorithm                     │
│                             (coalescence, topological sort, packaging) │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   PHASE 3: Output Dispatch to Datasources              │
└────────────────────────────────────────────────────────────────────────┘
```

The engine handles combination and high-speed in-RAM filtering (`where:`), ensuring native Zig tasks receive only relevant data.

---

## 4. Multi-Stream Operations (`Array + Array -> Array`)

The engine provides native algebraic operators to combine multiple collections prior to task invocation:

### 4.1. Concatenation (`merge`)
Merges two or more collections of the same type into a single contiguous slice:
```yaml
inputs:
  findings: merge(video_probe.findings, audio_probe.findings)
where: "findings.severity >= 2"
```

### 4.2. Index Pairing (`zip`)
Pairs element $i$ of Stream A with element $i$ of Stream B (1:1 alignment):
```yaml
inputs:
  aligned_pairs: zip(lower_mp4.regions, scan_entropy.scores)
```

### 4.3. Key-Based Hash Join (`join`)
Performs an equi-join on shared correlation keys ($O(N)$ hash join):
```yaml
inputs:
  chapters: join(api.chapters, api.translations, on: "chapter_id")
```

---

## 5. Unified Step Structure (`step`)

```yaml
      - id: <step_identifier>
        uses: <module>/<task_name>
        inputs:
          # Direct parameters or multi-stream algebra:
          <param_name>: <data_source> | merge(...) | zip(...) | join(...)
        
        # Optional declarative filter:
        where: <predicate_expression>

        # Optional concurrency quota (inherits from runtime.workers):
        concurrency: 1 | auto | max | <thread_count>
        
        # Static task configuration parameters:
        params:
          <param_name>: <constant_value>

        # Output dispatch channels:
        outputs:
          <channel_name>:
            from: <task_output_field>
            schema: <schema_reference | inline_schema>
            datasource: <logical_datasource_id>
            filter: <optional_filter_expression>
```

---

## 6. Concurrency, Thread Budgets, and Data Parallelism

The engine unifies strict determinism and multi-core parallelism under a **single canonical parameter: `workers`**, eliminating ambiguous flags like `deterministic: true`.

### 6.1. Engine-Level Configuration (`runtime.workers`)

The global worker thread budget is defined at the root of `pipeline.yaml`:

```yaml
runtime:
  workers: auto         # "auto" detects host CPU cores (or integer: 4, 8, 16)
  # workers: 1         # Forces single-threaded execution for deterministic debugging
```

In the VidSec CLI:
* `vidsec run pipeline.yaml` $\rightarrow$ Honors YAML configuration (defaults to `auto`).
* `vidsec run pipeline.yaml -j 1` (or `--workers 1`) $\rightarrow$ Immediately overrides execution to a single thread on the caller.

### 6.2. Task-Level Concurrency Quota (`concurrency`)

Individual steps can adjust their concurrency within the available budget:
* `concurrency: 1`: Tasks calling non-reentrant legacy C code or sensitive parsers requiring strict isolation.
* `concurrency: auto` (default): Inherits from `runtime.workers`.
* `concurrency: max` or `<N>`: Allows compute-heavy tasks (hashing, bulk entropy analysis, matrix operations) to burst across all available cores.

### 6.3. Deterministic Output Order Guarantee

Because tasks are pure black boxes and output memory is pre-allocated:
* The output slice `out = alloc(Out, N)` is pre-allocated before worker chunks are dispatched.
* Each thread $k$ processes subrange `start..end` and writes directly into `out[start..end]`.
* **The resulting output stream preserves 100% canonical input order ($0..N$)**, regardless of which worker thread completes first.

---

## 7. Routers (`router`): Branching and DAG Control Flow

While a **Task (`step`)** is a pure computational unit ($Inputs \rightarrow Outputs$), a **Router (`router`)** is a control-flow node that branches execution into distinct sub-pipelines or terminal flows based on analysis state.

### 7.1. Structure and Semantics

```yaml
      - router: <router_identifier>
        cases:
          - when: <predicate_expression>
            goto: <sub_pipeline_name>
          - when: <predicate_expression_2>
            goto: <sub_pipeline_name_2>
        default: <default_sub_pipeline_name>
```

#### Evaluation Rules:
1. **Sequential Short-Circuit ($O(1)$):** The engine evaluates `when:` clauses strictly in declared order. Once a condition evaluates to `true`, control branches immediately to `goto:`, ignoring subsequent cases.
2. **Mandatory Fallback (`default:`):** If no `when:` conditions match, execution branches to `default:` (or a terminal state).
3. **Zero Embedded SQL:** Predicates never contain SQL strings (`SELECT ...`). They evaluate declaratively against coordination variables or channels in `pipeline_memory` using native reflection.

### 7.2. Concrete Branching Examples

#### A. Container Format Dispatch (Post-Triage)
Routes the file into format-specific analyzers based on in-memory triage results:

```yaml
      - router: dispatch_after_triage
        cases:
          - when: "stage0_probe_file.coordination.should_quarantine"
            goto: quarantine_flow
          - when: "stage0_probe_file.coordination.detected_family == 'isobmff'"
            goto: mp4_pipeline
          - when: "stage0_probe_file.coordination.detected_family == 'ebml'"
            goto: mkv_pipeline
          - when: "stage0_probe_file.coordination.detected_family == 'riff'"
            goto: riff_pipeline
        default: unsupported_format_flow
```

#### B. Security Gatekeeper and Forensic Verdict
Evaluates whether findings mandate quarantine or pass verification:

```yaml
      - router: dispatch_after_forensics
        cases:
          - when: "scan_entropy.coordination.anomalous_entropy_detected"
            goto: forensics_findings_detected
        default: video_verified_clean
```

### 7.3. Terminal Flows
The destination of a `goto:` can be a full sub-pipeline (with its own `steps:`) or an empty **terminal flow** (`steps: []`), signaling clean completion or quarantine disposition.

---

## 8. Cascaded Triage Architecture

Vidsec's standard defense-in-depth pipeline follows a 4-stage cascade:

```
[ Stage 0: Generic Triage ] (probe_file)
        │
        ▼ (On Pass)
[ Stage 1: Format Triage ] (probe_mp4 / probe_mkv / probe_riff)
        │
        ▼ (On Pass)
[ Stage 2: Lowering to IR ] (lower_mp4_container -> []IrRegion in RAM)
        │
        ▼
[ Stage 3: Forensic Audit ] (analyze_topology, scan_entropy over IR)
```

1. **Stage 0:** Drops files with mismatched magic bytes, anomalous sizes, or general entropy corruption.
2. **Stage 1:** Validates format-specific headers (`moov`, `trak`, codec tags) before expending CPU cycles on heavy parsing.
3. **Stage 2:** Parses container structures and emits the canonical region tree (`ir_regions`) into `pipeline_memory`.
4. **Stage 3:** Executes format-agnostic forensic analyzers over in-memory IR entities.

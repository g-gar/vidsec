# Evolution Roadmap and Advanced Cases (`vidsec v2 TODO`)

This document records desirable capabilities and architectural edge cases that are **outside the initial minimal scope of Framework v2**, but whose architecture has been proactively prepared to incorporate them without breaking the C-ABI (`VIDSEC_ABI_VERSION = 2`).

---

## 1. Concurrent Task Execution (`Fan-Out / Fan-In`) and Output Convergence

### Use Case
Execute multiple independent tasks in parallel (e.g., launching `entropy_scan` on padding regions concurrently with `signature_scan` on attachments, or running multiple metadata extractors at once) and **converging their outputs as inputs for a downstream task** (or a `router`).

### Planned `pipeline.yaml` Specification
```yaml
      # Fan-out block: all tasks within `parallel` observe the SQLite state
      # prior to the block and execute concurrently on a Host ThreadPool.
      - parallel: heuristic_scanners
        tasks:
          - task: scan_padding_entropy
            use: byte_scanners/entropy_scan
            input:
              windows:
                from: file
                table: ir_regions
                filter: "role = 'padding'"
                map: { id: region_id, offset: payload_offset, length: "effective_end_offset - payload_offset", tag: tag_name }
            output:
              into: audit_findings
              map: { rule_id: "'R07_ENTROPY'", file_offset: offset, region_tag: tag, severity: severity, measured_value: entropy }

          - task: scan_padding_signatures
            use: byte_scanners/sig_scan
            input:
              windows:
                from: file
                table: ir_regions
                filter: "role = 'padding'"
                map: { id: region_id, offset: payload_offset, length: "effective_end_offset - payload_offset", tag: tag_name }
            output:
              into: audit_findings
              map: { rule_id: "'R07_SIG'", file_offset: offset, region_tag: tag, severity: severity, message: sig_name }

      # Natural Fan-In: the subsequent step (task or router) executes when ALL branches
      # of the `parallel` block have completed, reading combined outputs in `audit_findings`:
      - task: correlate_heuristics
        use: correlator
        input:
          findings:
            table: audit_findings
            filter: "rule_id IN ('R07_ENTROPY', 'R07_SIG')"
            map: { rule: rule_id, offset: file_offset, severity: severity }
```

### Host Support Architecture (Zero Plugin Modifications)
Because v2 plugins **hold no direct `*sqlite3` pointer** and interact exclusively via `HostApiVTable_ABI`:
1. **Concurrent Reading (`next_window` / `next_row`):** Under SQLite `WAL` mode, each thread in a `parallel:` block opens its own **read-only** SQLite connection (`SQLITE_OPEN_READONLY`) and dedicated `SafeCursor` (thread-safe positional `pread` on the file descriptor).
2. **Convergent Writing (`emit_row`):** Calls to `emit_row` from worker threads queue into an MPSC (*Multi-Producer, Single-Consumer*) channel feeding the Host coordinator thread, which executes `INSERT` statements over the master connection within the parallel block's transaction.

---

## 2. Step-by-Step Interactive Debugger (GUI / CLI) and Post-Mortem Trace Analysis

### Use Case
Leverage the structured execution trace (`../zig-out/out/trace.jsonl`) and the engine controller (`DebugController`) to support both **live interactive inspection from a GUI or CLI** and **post-mortem triage** of past runs without altering `pipeline.yaml` or adding overhead to SQLite.

### Planned Capabilities
* **Live Control (Runtime Hooks for GUI / CLI `--step` or `--break-at <step_name>`):**
  * Pauses execution between steps via an external controller.
  * Allows single-stepping (`step_next`), running until a target step (`continue_until`), querying current SQLite table states, or aborting execution cleanly.
* **Post-Mortem Analysis (*Time-Travel / Post-Mortem* over `../zig-out/out/trace.jsonl`):**
  * The JSONL file logs each state transition (`step_start`, `task_log`, `step_end` with duration, rows read/emitted, and `router_decision`).
  * In diagnostic mode, can serialize incremental snapshots of rows emitted at each step into the JSON stream, reconstructing exact pipeline state offline.

---

## 3. Resource Management, Memory Quotas, and Remote Storage via `.env`

* **Task Memory Quotas (`max_task_memory_mb`):** Expose an allocator wrapper or `CountingAllocator` in the Host with `setrlimit` / `cgroup` thresholds to terminate rogue tasks exceeding memory limits.
* **Transparent Remote Streams and Quarantine (SSH / SFTP / S3):** Because plugins read bytes exclusively via `host.stream_read_at` and extract payloads via `host.carve_to_quarantine`, the Host can mount remote origins and destinations configured via `.env` credentials without altering plugin `.so` binaries.

---

## 4. Google Magika (`libmagika`) Integration for Dual Verification and VirusTotal Alignment

### Use Case
Complement the deterministic signature scanner ([`src/lib/magic/`](../src/lib/magic/)) with the **Google Magika** Deep Learning model used by **VirusTotal**, enabling pre-emptive evasion detection (header spoofing, disguised executables) and enriching metadata with probabilistic confidence metrics.

For the in-depth technical analysis and integration architecture, see the dedicated specification:
👉 [`v2/development/magika.md`](./development/magika.md)

### Key Architectural Pillars
1. **Dual-Engine Verification:**
   * SQLite / In-Memory correlation between physical structure (`vidsec_magic`) and neural classification (`magika_label` + `magika_score`).
   * Immediate anomaly alerting when initial bytes mimic a valid media container but the neural net identifies executable content (`pebin`, `elf`, `script`).
2. **Preserving Compilation Autonomy:**
   * Maintain the core `vidsec` engine 100% pure native Zig (zero external dependencies on Rust/Python/ONNX).
   * Encapsulate `libmagika` as an **optional C-ABI plugin** (`vidsec_magika.so`), dynamically loaded via `pipeline.yaml` when host libraries or the CLI are present.
3. **Schema and Reporting Standardization:**
   * Align `file_triage` attributes with Magika/VirusTotal conventions (`ct_label`, `score`, `group`, `mime_type`).
   * Expose Magika labels and confidence metrics in executive summary views (`v_executive_summary`) and audit reports (PDF/LaTeX).

---

## 5. Distributed Cluster Computing (Coordinator / Worker)

### Use Case
Scale heavy analytical workloads across server farms or heterogeneous clusters by deploying worker daemons (`vidsec worker`), enabling distributed stream chunking (*Distributed Chunked Map*) and concurrent multi-node DAG execution (*Distributed Fan-Out*).

For the in-depth technical analysis, network protocol, data locality strategies, and configuration schemas, see the dedicated specification:
👉 [`v2/development/cluster.md`](./development/cluster.md)

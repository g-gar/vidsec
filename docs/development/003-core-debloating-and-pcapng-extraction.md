# 003 — Core Debloating and Extraction of PCAPNG, Tracer, and Artifacts to Extensions

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-003` |
| **Depends On** | [`ARCH-001`](./001-transport-layer-unification.md), [`ARCH-002`](./002-open-kernel-extension-system.md) |
| **Blocks** | [`ARCH-004`](./004-observability-otel-and-dag-visualizer.md) |
| **Affected Modules** | `src/engine/`, `src/transport/outbound/`, `extensions/pcapng/` *(new)*, `extensions/trace_jsonl/` *(new)*, `extensions/artifact/` *(new)* |

---

## 1. Context and Current Problem (As-Is)

Following the introduction of `src/transport/` (`001`) and `KernelContext` with `TelemetryBus` (`002`), three pieces remain within the Flowdata core that do not belong inside a pure reactive dataflow engine:

1. **PCAPNG binary generation and file rotation in the Core**:
   * `src/transport/outbound/sinks/pcapng_sink.zig` (`PcapngSink`) is embedded directly within `EgressAdapter` and `SinkholeAdapter`.
   * `src/engine/network.zig` contains `flushCaptures` and `writePcapWithRotation`, coupling the engine directly to the IETF PCAPNG binary format (SHB, IDB, DSB, EPB blocks) and writing rotated `.0`, `.1` files to disk.
2. **Ad-hoc JSONL tracer in `src/engine/tracer.zig`**:
   * `ExecutionTracer` manually serializes events to JSONL inside `src/engine/`, duplicating the responsibility now handled by `TelemetryBus` in `src/kernel/telemetry.zig`.
3. **Artifact Store and SHA-256 Quarantine in `src/engine/artifact.zig`**:
   * `ArtifactStore` (`ManagedBuffer`, `carveToQuarantine` with SHA-256 hash) resides inside `src/engine/`, despite being a utility specific to binary inspection/remediation pipelines.

---

## 2. Target Architecture (To-Be)

The Core (`src/engine/` and `src/transport/outbound/`) is left completely clean of forensic formats and trace serializers:

```mermaid
flowchart LR
    subgraph CleanCore["Core Flowdata (Clean)"]
        OutAdapter["EgressAdapter / SinkholeAdapter"]
        Engine["PipelineEngine"]
        Bus["KernelContext.telemetry<br/>(TelemetryBus)"]
    end

    subgraph ExtractedExtensions["Decoupled Extensions (extensions/*)"]
        ExtPcap["extensions/pcapng/<br/>- Listens to outbound_wire_packet and pipeline_end<br/>- Assembles PCAPNG blocks (SHB, IDB, DSB, EPB)<br/>- Persists to Datasource and to disk with rotation"]
        ExtTrace["extensions/trace_jsonl/<br/>- Listens to all TelemetryBus events<br/>- Exports structured .jsonl trace"]
        ExtArtifact["extensions/artifact/<br/>- ArtifactStore & ManagedBuffer<br/>- Carve to quarantine with SHA-256"]
    end

    OutAdapter -->|"Emits PacketSink / WireTap"| Bus
    Engine -->|"Emits Step / Router / Pipeline"| Bus
    Bus -->|"Notifies"| ExtPcap & ExtTrace
```

---

### 2.1. How PCAPNG Capture Operates as an Extension (`extensions/pcapng/`)

```mermaid
sequenceDiagram
    participant App as App / Test
    participant Kernel as KernelContext
    participant OutReg as OutboundRegistry
    participant Adapter as EgressAdapter
    participant PcapExt as PcapngExtension
    participant Repo as RepositoryRegistry

    App->>Kernel: use(extensions.pcapng.extension)
    Kernel->>PcapExt: register(&kernel)
    PcapExt->>OutReg: registerSinkFactory(&PcapngExtension.createTapSink)
    PcapExt->>Kernel: telemetry.subscribe(pcap_subscriber)

    Note over Adapter,PcapExt: During Pipeline Execution
    Adapter->>PcapExt: PacketSink.onExchange(record, req_bytes, resp_bytes)
    PcapExt->>PcapExt: Encodes SHB/IDB/DSB/EPB blocks into its per-adapter_id buffer

    Note over Kernel,Repo: Upon Pipeline Completion (telemetry.flushAll)
    Kernel->>PcapExt: flush(&kernel.datasources, ast.networks)
    PcapExt->>Repo: writePayload(capture.channel, pcap_bytes)
    PcapExt->>PcapExt: writePcapWithRotation(capture.path, pcap_bytes, max_mb, max_files)
```

---

### 2.2. UML Class Diagram for Extracted Extensions

```mermaid
classDiagram
    class PcapngExtension {
        -Allocator allocator
        -StringHashMap~PcapngWriter~ writers_by_adapter
        +init(allocator) PcapngExtension
        +extension() Extension
        +createTapSink(allocator, config) !?PacketSink
        +onEvent(event: TelemetryEvent) void
        +flush(repos: *RepositoryRegistry) !void
    }

    class PcapngWriter {
        +u32 interface_id
        +u32 snaplen
        +bool include_tls_keys
        +ArrayList~u8~ buf
        +writeSectionHeader() !void
        +writeInterfaceDesc(name, snaplen) !void
        +writeDecryptionSecrets(key_log) !void
        +writeEnhancedPacket(...) !void
        +bytes() []const u8
    }

    class JsonlTraceExtension {
        -Allocator allocator
        -ExecutionTracer tracer
        -?[]const u8 output_path
        +extension() Extension
        +onEvent(event: TelemetryEvent) void
        +flush(repos: *RepositoryRegistry) !void
    }

    PcapngExtension *-- PcapngWriter
```

---

## 3. Detailed Changes in Core and in `extensions/`

### 3.1. Extraction of `extensions/pcapng/`
1. Move `src/transport/outbound/sinks/pcapng_sink.zig` → `extensions/pcapng/src/pcapng_writer.zig`.
2. Move `writePcapWithRotation` and `flushCaptures` logic from `src/engine/network.zig` → `extensions/pcapng/src/root.zig`.
3. In `EgressAdapter` and `SinkholeAdapter`:
   * Remove the field `pcap_sink: ?PcapngSink = null`.
   * Instead, `EgressAdapter` and `SinkholeAdapter` simply delegate to `PacketSink` instances registered in `OutboundRegistry` (`ctx.extra_sinks`).
   * When `extensions/pcapng` is registered in `KernelContext`, its `SinkFactoryFn` inspects `if (config.capture.enabled)` and automatically injects the PCAPNG `PacketSink` into the adapter.
   * Upon pipeline completion, `PcapngExtension.flush` writes `.pcapng` bytes to `capture.datasource` and to `capture.path` with ring-buffer rotation.

### 3.2. Extraction of `extensions/trace_jsonl/`
1. Move `src/engine/tracer.zig` → `extensions/trace_jsonl/src/root.zig`.
2. Implement `TelemetrySubscriber` on `ExecutionTracer` so that it automatically translates `TelemetryEvent` (`step_start`, `task_log`, `step_end`, `router_decision`) into `.jsonl` lines, and if `--trace-out <path>` is supplied in `RunnerOptions`, writes the file on completion.

### 3.3. Extraction of `extensions/artifact/`
1. Move `src/engine/artifact.zig` → `extensions/artifact/src/root.zig`.
2. Re-export in `extensions/mod.zig` (`extensions.artifact.ArtifactStore`, `extensions.artifact.ManagedBuffer`).

---

## 4. File Migration Map

| Origin (Core) | Destination (`extensions/`) | Action |
| :--- | :--- | :--- |
| `src/transport/outbound/sinks/pcapng_sink.zig` | `extensions/pcapng/src/pcapng_writer.zig` | Move outside core |
| `src/engine/network.zig` (`flushCaptures` / `writePcapWithRotation`) | `extensions/pcapng/src/root.zig` | Convert to `Extension` subscribed to `OutboundRegistry` and `TelemetryBus` |
| `src/engine/tracer.zig` | `extensions/trace_jsonl/src/root.zig` | Move outside `src/engine/` and connect to `TelemetryBus` |
| `src/engine/artifact.zig` | `extensions/artifact/src/root.zig` | Move outside `src/engine/` to `extensions/artifact/` |
| `extensions/mod.zig` | `extensions/mod.zig` | Export `datasource`, `pcapng`, `trace_jsonl`, `artifact`, and `registerDefaultExtensions(kernel)` |

---

## 5. Acceptance Criteria and Verification

1. **Core Purity**:
   * `grep -rn -i "pcapng" src/engine/ src/transport/` returns **0 matches** (with the sole exception of the declarative `CaptureSpec` configuration in `ast` / `contracts`).
   * `src/engine/` contains solely `engine.zig`, `network.zig` (adapter coordination and `NetworkEvent` events without PCAPNG), and `runner.zig`.
2. **Functional Parity**:
   * All `.pcapng` capture tests in `tests/core/network_test.zig` (magic bytes `0x0A0D0D0A`, TLS block `0x0000000A`, persistence in datasource `egress_pcap_dump`, and disk file rotation) continue to pass 100% using `extensions.pcapng`.
   * All `ArtifactStore` tests in `tests/core/artifact_test.zig` pass 100% using `extensions.artifact`.
3. **Green Test Suites**:
   * `zig build test --summary all` passes 100% at the root.
   * `cd apps/vidsec && zig build && zig build test --summary all` passes 100%.

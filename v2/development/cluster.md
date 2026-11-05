# Distributed Cluster Execution Design for Vidsec (`v2/development/cluster.md`)

## 1. Introduction and Architectural Rationale

The architecture of `vidsec v2` was engineered from the outset on two foundational principles that make distributed execution a natural extension of the core engine:
1. **Pure Black Box Tasks:** A native task is a pure deterministic transformation ($Inputs \rightarrow Outputs$) with zero direct SQL interaction, no shared mutable state, and no side-effects outside its dedicated memory space. The task remains completely agnostic as to whether its inputs originate from local RAM or a remote network socket.
2. **Universal Typed Contracts (`components.schemas`):** Every data entity flowing across pipeline boundaries conforms to a formal schema, enabling deterministic, high-throughput binary serialization across processes and network nodes.

This specification details the architecture for scaling Vidsec into a **Distributed Dataflow Cluster Engine**, enabling compute-heavy forensic analysis and multi-terabyte video processing across server clusters.

---

## 2. Cluster Topology: Coordinator and Workers (Leader-Worker Pattern)

The cluster implements a decoupled **Coordinator-Worker** (or *Leader-Agent*) topology, reflecting high-performance computing patterns seen in systems like Ray, Celery, and GStreamer Netcells:

```
                          ┌────────────────────────┐
                          │    COORDINATOR NODE    │
                          │                        │
                          │ • DAG Orchestrator     │
                          │ • Chunk Scheduler      │
                          │ • Ordered Assembler    │
                          └───────────┬────────────┘
                                      │
            ┌─────────────────────────┼─────────────────────────┐
            │ QUIC / TCP              │ QUIC / TCP              │ QUIC / TCP
            ▼                         ▼                         ▼
   ┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
   │    WORKER 1     │       │    WORKER 2     │       │    WORKER 3     │
   │ (vidsec daemon) │       │ (vidsec daemon) │       │ (vidsec daemon) │
   │                 │       │                 │       │                 │
   │ • CPU: 32 Cores │       │ • CPU: 16 Cores │       │ • CPU: 64 Cores │
   │ • RAM: 64 GB    │       │ • RAM: 32 GB    │       │ • RAM: 128 GB   │
   │ • Native Mod.so │       │ • Native Mod.so │       │ • Native Mod.so │
   └─────────────────┘       └─────────────────┘       └─────────────────┘
```

### 2.1. The Coordinator Node (Leader / Master)
* Parses and validates `pipeline.yaml`, constructing the DAG execution graph.
* Manages worker discovery, registration, and health monitoring via periodic heartbeats.
* Partitions unbounded streams into contiguous chunks and dispatches task workloads according to reported node capacity and load metrics.
* Collects completed task slices and reassembles them into final output streams in **strict canonical order** ($0..N$).

### 2.2. The Worker Node (Slave / Daemon)
* Runs the unified native Vidsec binary in worker daemon mode:
  ```bash
  vidsec worker --coordinator 10.0.0.1:9000 --tags "cpu=32,memory=64g"
  ```
* On boot, registers with the Coordinator over TCP/QUIC, advertising its available hardware resources (CPU cores, memory budget) and loaded module plugins (`.so`).
* Listens on an event loop for incoming job payloads (`ExecuteTaskPayload`).
* Executes tasks across local cores using `vidsec_dataflow`'s multi-threaded `parallelFor` engine.
* Serializes results and returns them to the Coordinator.

---

## 3. Cluster Distribution Strategies

The distributed engine provides two complementary modes of horizontal scaling:

### 3.1. Distributed Chunked Map (Data Parallelism)
Designed for high-cardinality element streams (e.g., analyzing 50,000 video frames, processing 5,000 document chapters, or scanning entropy across 20,000 regions):

$$\text{Stream of } N \text{ elements} \xrightarrow{\text{partitioning}} \text{Chunks of size } \frac{N}{K} \xrightarrow{\text{network}} K \text{ Remote Nodes}$$

1. The Coordinator partitions the input stream into contiguous index ranges:
   * Worker A: Range $[0 .. 12,500)$
   * Worker B: Range $[12,500 .. 25,000)$
   * Worker C: Range $[25,000 .. 37,500)$
   * Worker D: Range $[37,500 .. 50,000)$
2. Each worker processes its slice in parallel across its local CPU cores.
3. The Coordinator slots the returned slices directly into pre-allocated memory positions: the resulting output order is **100% deterministic and canonical**.

### 3.2. Distributed DAG Fan-Out (Task Parallelism)
When the pipeline graph contains independent computational branches:
* Branch A: `scan_padding_entropy` $\rightarrow$ Dispatched to Worker 1.
* Branch B: `scan_audio_signatures` $\rightarrow$ Dispatched to Worker 2.
* Both analytical pipelines execute concurrently on distinct physical machines, and the Coordinator synchronizes their results at the join barrier before correlation.

---

## 4. Data Locality and Shared Storage Architecture

Network bandwidth saturation is the primary bottleneck in distributed systems. Vidsec resolves this by separating structural metadata from raw media payloads:

| Data Category | Transport Strategy | Mechanism |
| :--- | :--- | :--- |
| **Metadata and Regions** (`IrRegion`, `TriageRecord`, etc.) | **Direct Socket Transfer** | High-throughput flat binary serialization (Zero-Copy unpacking on destination, compatible with contiguous Zig slices). |
| **Heavy Video Payloads** (10 GB – 100 GB) | **Shared POSIX / Object Storage** | Multi-gigabyte video files are **never** transferred over worker sockets. All nodes mount a shared storage datasource (`NFS`, `Ceph`, `Lustre`, `S3`, or `SMB`). Network payloads carry only positional descriptors (`file_path`, `offset`, `length`). |

---

## 5. Pipeline Configuration and CLI Controls

### 5.1. Declarative Pipeline Configuration
```yaml
runtime:
  workers: auto         # Local core count when running standalone
  
  # Distributed cluster execution configuration:
  cluster:
    enabled: true
    mode: coordinator   # coordinator | worker
    listen: "0.0.0.0:9000"
    static_workers:
      - "10.0.0.10:9000"
      - "10.0.0.11:9000"
      - "10.0.0.12:9000"
    heartbeat_interval_ms: 2000
    task_timeout_ms: 30000
```

### 5.2. Dynamic CLI Invocation
Enables cluster execution on demand without modifying YAML definitions:

```bash
# 1. Start worker daemons on remote machines:
ssh worker1 "vidsec worker --coordinator 10.0.0.1:9000"
ssh worker2 "vidsec worker --coordinator 10.0.0.1:9000"

# 2. Run the pipeline on the coordinator node with cluster distribution enabled:
vidsec run pipeline.yaml --cluster
```

---

## 6. Fault Tolerance and Idempotent Retries

Because tasks in `vidsec v2` are **pure deterministic black boxes** without persistent side-effects until the final output dispatch phase:
1. **Failure Detection:** If Worker 2 misses 3 consecutive heartbeats while processing range $[12,500 .. 25,000)$, the Coordinator flags the node as dead.
2. **Idempotent Rescheduling:** The Coordinator immediately reschedules the exact slice $[12,500 .. 25,000)$ to Worker 3.
3. Because the task is pure, re-execution on the replacement node yields the exact same deterministic output with zero data duplication or database corruption.

---

## 7. Implementation Roadmap

* **Phase 1 (Serialization Protocol):** Define the binary framing protocol in Zig to serialize and deserialize `PayloadHandle` over `std.net.Stream`.
* **Phase 2 (Worker Daemon):** Implement the `vidsec worker` CLI subcommand with an asynchronous socket event loop and heartbeat reporting.
* **Phase 3 (Distributed Lifter):** Extend `lifter.zig` so that `parallelFor` can distribute chunks transparently across both local `ThreadPool` workers and remote socket workers.
* **Phase 4 (Node Discovery):** Optional dynamic discovery via mDNS / DNS-SD for air-gapped forensic lab networks.

# Datasources Specification (`v2/specs/datasources.md`)

This document specifies the storage and logical sink layer (*datasources*) in `vidsec v2`.

---

## 1. Architectural Vision and Decoupling

Rather than binding tasks directly to fixed databases or hardcoded disk paths, the pipeline defines **logical datasource identifiers** in its header. Each output channel references one of these datasources:

```yaml
datasources:
  <datasource_id>:
    type: memory | sqlite | file_store | amqp
    # Type-specific parameters...
```

### Key Advantages:
1. **Zero-Disk Execution:** If SQLite is omitted or disabled, the pipeline runs 100% in memory without touching disk or compiling DDL schemas.
2. **Portable Environments:** The same pipeline definition can route outputs to `:memory:` in automated tests and to a persistent SQLite database in production simply by altering an environment variable.
3. **Multi-Target Routing:** A task can emit data to memory (for immediate $O(1)$ router evaluation) and to disk (for forensic audit retention) simultaneously.

---

## 2. Datasource Types

### 2.1. In-Memory Datasource (`type: memory`)

Memory serves as the primary sink for inter-task coordination and low-latency ($O(1)$) router condition evaluation.

```yaml
datasources:
  pipeline_memory:
    type: memory
```

#### Technical Characteristics:
* **Native In-Memory Representation:** Data is never serialized to SQL or string buffers. It resides as native Zig structs and slices inside a session `ArenaAllocator`.
* **Zero-Copy Reference Access:** Downstream tasks consume upstream slices directly (`inputs: { regions: lower_mp4.regions }`) with zero copying overhead.
* **Lifecycle:** The `ArenaAllocator` lives for the duration of the pipeline execution and is deallocated in a single operation upon completion, preventing fragmentation and memory leaks.

---

### 2.2. Relational SQLite Datasource (`type: sqlite`)

Serves as the structured, queryable persistence sink for security audit trails and forensic reporting.

```yaml
datasources:
  audit_db:
    type: sqlite
    path: "${VIDSEC_DB_PATH:-./vidsec_state.db}"
```

#### Technical Characteristics:
* **Embedded Engine:** Built on embedded SQLite compiled directly into the binary (no external driver dependencies or shared library conflicts).
* **Execution Modes:**
  * `path: ":memory:"`: High-speed in-RAM relational execution (ideal for integration tests and ephemeral runs).
  * `path: "file.db"`: Persistent disk storage using WAL mode (`Write-Ahead Logging`).
* **Automated DDL Compilation:** During pre-flight validation, the Host compiles schemas from `components.schemas` targeting this datasource into `STRICT` relational tables.
* **Transaction Isolation:** Each pipeline step executes within an isolated `SAVEPOINT`. If a task fails, the Host issues an automatic `ROLLBACK`.

---

### 2.3. File and Artifact Store Datasource (`type: file_store`)

Manages physical disk storage for file assets produced during analysis (quarantined files, raw carved streams, or remediated video containers).

```yaml
datasources:
  artifacts:
    type: file_store
    directory: "./artifacts/"
```

#### Technical Characteristics:
* **Path Containment:** Ensures all written files remain strictly confined within the declared directory boundary, preventing Path Traversal vulnerabilities.
* **Copy-on-Write (CoW):** Leverages CoW cloning on modern filesystems (Btrfs, XFS) or sparse files for multi-gigabyte forensic streams.

---

### 2.4. Message Queue Datasource (`type: amqp` - Extension)

Emits real-time security alerts and critical findings directly to message brokers (RabbitMQ, Kafka, etc.):

```yaml
datasources:
  threat_alerts:
    type: amqp
    url: "${AMQP_URL:-amqp://localhost:5672}"
    exchange: "security_findings"
```

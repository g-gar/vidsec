# ARCH-034: Filesystem Stream & Slice Datasource Refactor

**Status**: Proposed  
**Date**: 2026-11-14  
**Related**: [ARCH-015](015-declarative-task-services-and-comptime-di.md), [ARCH-025](025-datasource-roles-and-batch-emission-decoupling.md), [ARCH-033](033-transparent-memory-and-resource-monitoring.md)

---

## 1. Problem & Motivation

Currently, filesystem access and stream delivery in Flowdata / VidSec are split across two incomplete mechanisms:

1. **`drivers/file_store` (`FileStoreRepository`)** is designed as an artifact/quarantine sink (`put`/`get` full blobs by key), not as a random-access or streaming **source** for large media files.
2. **`src/plugin/loader/task_executor.zig`** backs `abi.BoundedStreamReader` (`streamSize` / `streamReadAt`) strictly with an in-memory `self.input_slice: []const u8`, meaning multi-GB video files must be loaded into heap memory before any task runs.

As `apps/vidsec` moves toward atomic, `TaskContext`-free Services (staged in `apps/vidsec/src/tasks2/`), the FS datasource needs to feed the pipeline in **two distinct modes** depending on what each downstream Service requires:

1. **Copied Sections (Bounded Range Slices)**: Extract specific byte ranges (`offset`, `len`, e.g., `head` 64 KB, `mid` 4 KB, `tail` 64 KB) as `[]const u8` buffers for pure, stateless tasks.
2. **Full-File Pointer / Zero-Copy View**: Provide a read-only pointer/slice to the whole file (e.g., `mmap`) or a lazy file-descriptor-backed stream powering `abi.BoundedStreamReader` without copying the entire file onto the Zig heap.

> **Current Interim Decision**: `apps/vidsec/src/tasks2/` retains `abi.BoundedStreamReader` so Stage 0 and container tasks remain decoupled from `std.fs` and work against both current in-memory test buffers and future lazy FS streams.

---

## 2. Target Capabilities for the FS Datasource

### 2.1 Mode A: Section / Range Copy (`readRange` -> `[]const u8`)
Ideal for Stage 0 triage, signature scanners, and small header/trailer parsers that only need bounded windows and should remain 100% pure over `[]const u8`:

- Reads `[offset, min(offset + len, file_size))` via `pread` (positional read, thread-safe without mutating a shared file cursor).
- Allocates only the requested window size (e.g. `<= 64 KB`) in the step/arena allocator.
- Supports declarative window presets or explicit offsets in `pipeline.yaml` (e.g., `head`, `mid`, `tail`, or `(offset, length)`).
- Allows downstream Services to drop `abi.BoundedStreamReader` completely in favor of `[]const u8` + `file_size: u64` when desired.

### 2.2 Mode B: Full-File Pointer / Zero-Copy Stream (`mmap` & Lazy `pread`)
Ideal for container lowering (`mp4`, `mkv`, `avi`, `ts`), structural carving, and tasks that perform arbitrary random-access seeks across gigabytes:

- **Option B1 — Read-only `mmap` View (`[]const u8` / pointer to whole file)**:
  - Maps the file read-only (`PROT_READ`, `MAP_PRIVATE`) into virtual address space and exposes a `[]const u8` slice covering `[0, file_size)`.
  - Zero heap allocation and OS page-cache-backed demand paging.
  - Requires lifecycle management (unmap when pipeline run/step completes) and a fallback when `mmap` is unavailable or file size exceeds 32-bit address space limits.
- **Option B2 — Lazy `std.fs.File`-backed `BoundedStreamReader`**:
  - `TaskExecutor.streamSize()` returns `stat.size` in O(1).
  - `TaskExecutor.streamReadAt(offset, dest)` executes `pread` directly against the open read-only file descriptor, bounded to `[0, file_size)`.
  - Preserves capability isolation: plugins never see host paths or `std.fs.File` descriptors, only `abi.BoundedStreamReader`.

---

## 3. Proposed Architecture & Touchpoints

```text
  FS Datasource (source / duplex)
   ├── stat() / metadata       ──► file_size: u64, extension / path metadata
   ├── readRange(off, len)     ──► []const u8 (copied section for pure window tasks)
   └── openFullView()
        ├── mmap (when enabled) ──► []const u8 (zero-copy whole-file pointer)
        └── fd + pread          ──► TaskExecutor.streamSize / streamReadAt (BoundedStreamReader)
```

### 3.1 Driver & Repository Layer (`drivers/file_store/` or new `drivers/fs_source/`)
- [ ] Define a clean read-only file handle / stream abstraction supporting `size()`, `readRange(offset, buf)`, and optional `mapReadOnly()`.
- [ ] Ensure positional `pread` is used so concurrent DAG workers can read different offsets of the same file safely without locking a shared seek cursor.
- [ ] Enforce path sandboxing (allowed root directories / no `..` escape) consistent with existing `FileStoreRepository` security boundaries.

### 3.2 Host `TaskExecutor` & `PayloadHandle` (`src/plugin/loader/task_executor.zig`)
- [ ] Extend `TaskExecutor` stream backing beyond `self.input_slice` to accept a `StreamBacking` union:
  - `.slice`: `[]const u8` (current behavior, also covers `mmap` views).
  - `.file`: `{ file: std.fs.File, size: u64 }` using `preadAll` in `streamReadAt`.
- [ ] Wire `PayloadHandle` / lifecycle cleanup so `mmap` mappings or open `std.fs.File` handles are deterministically released at the end of the pipeline run.

### 3.3 Declarative Pipeline Configuration (`pipeline.yaml`)
- [ ] Allow `datasources` with `driver: file_store` (or `fs`) and `role: source` / `duplex` to emit:
  - A full stream payload (consumed by `abi.BoundedStreamReader` or `[]const u8`).
  - Specific byte-range slices (e.g. `head`, `mid`, `tail`) for pure window-based Services.

---

## 4. Implementation Phases

1. **Phase 1 — Lazy `pread` backing in `TaskExecutor`**:
   - Support `.file` backing in `streamSize` / `streamReadAt` so existing `abi.BoundedStreamReader` tasks (including `apps/vidsec/src/tasks2/`) work on multi-GB files without loading them into RAM.
2. **Phase 2 — `mmap` full-file pointer support**:
   - Add opt-in read-only `mmap` backing with automatic fallback to `.file` (`pread`) on failure or unsupported platforms.
3. **Phase 3 — Range-copy source step / FS datasource read mode**:
   - Support extracting `[]const u8` sections (`offset`, `len`) directly from the FS datasource so pure window tasks can optionally migrate off `BoundedStreamReader` to `[]const u8`.

---

## 5. Acceptance Criteria

- [ ] A 4 GB+ video file can be triaged by `tasks2/` (`BoundedStreamReader`) with bounded RSS memory (no full-file heap read).
- [ ] Concurrent DAG tasks reading `head`, `mid`, and `tail` ranges in parallel produce deterministic results without data races on file offsets.
- [ ] Both access modes (copied byte range `[]const u8` and full-file `mmap` / lazy stream pointer) are covered by unit and integration tests.
- [ ] Plugins remain sandboxed from raw OS file paths and descriptors.


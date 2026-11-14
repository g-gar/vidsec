# ARCH-035: Pure Format Dissector Libraries (`libs/`) and Declarative Video Security & Sanitization in `apps/vidsec`

**Status**: In Progress (`TASK-035.1` Completed; `TASK-035.2`–`TASK-035.8` Ready for Sequential Execution)  
**Date**: 2026-11-14  
**Related**: [ARCH-015](015-declarative-task-services-and-comptime-di.md), [ARCH-034](034-filesystem-stream-and-slice-datasource.md), [ARCH-036](036-streaming-output-emitter-and-chunked-sinks.md), [Video Security & Forensics](../learning/video-security-and-forensic-analyses.md), [Universal Container IR](../learning/universal-container-ir-decoupling.md)

---

## 1. Motivation & Dual Objective

`vidsec` is designed as a **declarative video security analysis and Content Disarm & Reconstruction (CDR) framework** built on Flowdata 2.0. Rather than functioning as a closed binary scanner with hardcoded signatures, `libanalyzer.so` provides a composable library of atomic tasks orchestrated entirely from [pipeline.yaml](../../apps/vidsec/configs/pipeline.yaml) without recompilation.

This architecture serves two complementary objectives from the same underlying primitives:

### 1.1 Objective A — General Media Safety ("Is this video safe to open or play?")

Media files are passive data structures (boxes, VINT elements, chunks, sample tables, codec parameter sets). Exploits against players and transcoders (`FFmpeg`, `VLC`, `GStreamer`, `Stagefright`, browser demuxers) work by **lying in structural numbers** so that a C/C++ demuxer miscalculates buffer allocations or reads/writes out of bounds.

Instead of tracking individual CVEs one by one, `vidsec` detects unsafe media generically by verifying **four structural invariant families** that cover the overwhelming majority of container and codec parser vulnerabilities:

| Invariant Family | Underlying Vulnerability Class | Generic Property Verified by `vidsec` | Stage |
|---|---|---|---|
| **1. Internal Containment & Integer Overflows** | Heap buffer overflows, integer wraparound in demuxer tables (`stsc`, `ctts`, `stsz`, `avcC`, `esds`, EBML VINT, RIFF chunks) | Every table, array, TLV record, or codec descriptor claims `claimed_bytes <= enclosing.payload_size` with no arithmetic overflow | **Stage 1a** |
| **2. Spatial & Pointer Integrity** | Out-of-bounds reads/writes via manipulated frame/chunk offset tables (`stco`/`co64`, `Cues`, `idx1`) | 100% of indexed sample runs (`ir_sample_runs`) lie strictly inside valid `media_data` regions (`mdat`, `Cluster`, `movi`) and `<= file_size`, with no region overlaps | **Stage 1b → Stage 2** |
| **3. Container vs. Bitstream Consistency** | Frame-buffer / stride overflows caused by mismatched dimensions or codecs between container headers and codec bitstreams | Container track headers (`tkhd`, `Video`, `avih`/`strh`) match decoded codec configurations (`avcC`, `hvcC`, `esds`, `strf` `BITMAPINFOHEADER`) (`ir_codec_configs.is_mismatch == false`) | **Stage 1b → Stage 2** |
| **4. Polyglots, Smuggled Payloads & Two-Level Slack** | Polyglot files (`MP4+ZIP`, embedded `MZ`/`ELF`), trailing overlays past EOF, shellcode hidden between root regions or inside unreferenced `mdat`/`movi`/`JUNK`/`Void` gaps | Zero hostile signatures in head/tail (`Stage 0`), zero external gaps, zero interior `media_data` slack, or sanitized via CDR (`Stage 2`) | **Stage 0 & Stage 2** |

### 1.2 Objective B — Zero-Recompilation CVE Research & Custom Pipelines

A security researcher investigating a newly disclosed CVE or building a custom ingestion policy should not have to write Zig code or recompile `vidsec` to inspect a specific box path, table field, or byte range.

By dissecting containers into rich, structured tables (`isobmff_boxes`, `mp4_tracks`, `ebml_elements`, `mkv_tracks`, `riff_chunks`, `ir_sample_runs`, `ir_codec_configs`) and offering parametric field-reading/assertion primitives (`inspect_region_field`), researchers can express custom CVE reproductions, anomaly thresholds, or short-circuit rules purely in YAML (`pipeline.yaml` / `cve_compendium.yaml`).

### 1.3 Objective C — Predefined Sanitization (CDR) & Quarantine Options in `apps/vidsec`

Beyond passive auditing ("flag or drop"), `apps/vidsec` provides ready-to-use, composable remediation primitives wired via Flowdata's **type-driven Pub/Sub** router:

- **Truncation (`TruncateOrder` → `analyzer/apply_truncate`)**: Strips trailing overlays, appended archives (`ZIP`/`RAR`/`7z`), or junk past `highest_root_end` cleanly to `new_size`.
- **Zero-Out (`ZeroOutOrder` → `analyzer/apply_zero_out`)**: Overwrites unreferenced slack spaces inside `mdat`/`movi`/`JUNK`/`Void` or suspicious metadata regions with `0x00` while preserving valid structural framing.
- **Safety Guard & Chunked Streaming Path**: Both remediation tasks enforce a configurable `max_in_memory_bytes` guard (default `64 MiB`), with an evolution path toward windowed `StreamEmitter` emission for multi-gigabyte streams documented in [ARCH-036](036-streaming-output-emitter-and-chunked-sinks.md).
- **Quarantine Routing (`QuarantineOrder` → `quarantine` `file_store` sink)**: Isolates non-sanitizable or hostile artifacts directly to a quarantine store.
- **Bounded Re-Verification**: When remediation produces a modified artifact (`requires_reverify == true`), the pipeline routes it back for re-verification up to `max_rounds` before final release or escalation.

---

## 2. Why `libs/{isobmff,ebml,riff}` and `libs/media_ir` Must Be Refactored

### 2.1 Flaws in the Format Libraries (`libs/{isobmff,ebml,riff}`)

1. **Dissection Coupled with Hardcoded Security Policy**:
   - `Mp4Inspector`, `MkvInspector`, `checks/check_*`, and closed enums (`Mp4IssueCode`, `MkvIssueCode`, `ParserIssueCode`) bake security rules and fixed thresholds (`64 KB` `mdat` slack) directly into `libs/`.
   - Checking an unhandled box (`ctts`, `stsc`, `elst`, `sidx`, `hvcC`, `tx3g`, `avih`, `strf`) requires editing Zig in `libs/` and recompiling.
2. **Shallow Structural Output ("Opaque Tree Parsers")**:
   - `SafeBoxParser`, `SafeEbmlParser`, and `SafeRiffParser` emit only shallow spans (`{ offset, size, fourcc/id }`) and discard hierarchical paths (`moov/trak/mdia/minf/stbl/stsc`), `FullBox` headers (`version`, `flags`), and native structural records anticipated by [schemas.yaml](../../apps/vidsec/configs/schemas.yaml).
3. **Unnecessary Dependencies on `media_ir` and `tika`**:
   - Coupling `isobmff`/`ebml`/`riff` to `media_ir.common` prevents simplifying `media_ir` independently and limits reuse of the format dissectors in non-security tools.

### 2.2 Flaws in `libs/media_ir`

Reviewing `libs/media_ir` reveals four critical scaling, correctness, and cleanliness gaps that must be fixed once format libs no longer depend on `media_ir.common`:

1. **Unbounded Sample-Table Scaling (`IrSampleExtentRow` → `IrSampleRunRow`)**:
   - `IrSampleExtentRow` emits one row per frame/sample. A 2-hour 60fps video contains $10^6+$ samples, blowing up pipeline memory and SQLite insert latency.
   - **Fix**: Replace per-sample rows with **coalesced contiguous byte runs (`IrSampleRunRow`: `{ run_id, track_id, first_sample_index, sample_count, source_tag, start_offset, end_offset }`)**. Merging adjacent contiguous samples reduces $10^6$ frames to $O(10^2)$ intervals while preserving 100% spatial accuracy.
2. **Incomplete Pointer Containment Check in `inconsistencies.zig`**:
   - Currently `checkInconsistencies` only checks `extent.end_offset > file_size`. If an exploit points `stco` to offset `0` (covering `ftyp`/`moov`) or into `free`/`moov`, `checkInconsistencies` passes it as valid.
   - **Fix**: Enforce $\text{SampleRuns} \subseteq \text{Regions}(\text{role} == \text{media\_data})$ **and** $\text{end\_offset} \le \text{file\_size}$.
3. **Blind Spot Inside `media_data` in `topology.zig`**:
   - Currently `topology.zig` only scans gaps between root regions (`parent_region_id == null`). Any unreferenced payload appended inside `mdat`/`Cluster`/`movi` after real frames (`stco`/`stsz`) goes undetected as slack.
   - **Fix**: Compute **two-level unreferenced slack**:
     - *External / inter-region gaps*: bytes between root regions (`leading_slack`, `unreferenced_gap`, `trailing_overlay`).
     - *Interior `media_data` slack*: exact set difference $\text{Regions}(\text{media\_data}) \setminus \bigcup \text{SampleRuns}$.
4. **Internal Triplication and Pre-Formatted English Policy Strings**:
   - `libs/media_ir` currently duplicates interval logic across `analysis/topology.zig`, `common/services/*`, and `rows/compute_unreferenced_slack.zig`, duplicates `Region`/`IrRegionRow`/`ElementSpan`, duplicates `Finding`/`DiagnosticFinding`, and contains dead `TaskContext` helpers (`rows/emit_helpers.zig`).
   - Furthermore, `topology.zig` and `inconsistencies.zig` allocate English prose strings and set `.remediation_action = "UNRESOLVED"` instead of returning pure typed mathematical facts.
   - **Fix**: Delete `common/`, `rows/emit_helpers.zig`, `rows/compute_unreferenced_slack.zig`, and duplicate findings; unify everything on a single interval algebra engine returning typed facts (`TopologyGap`, `TopologyOverlap`, `TrailingOverlay`, `SampleRunEscape`, `CodecMismatch`).

### 2.3 Strict Three-Layer Boundary Principle

1. **`libs/{isobmff,ebml,riff}` (`std` only)**: 100% pure binary dissectors, positional field readers, and physical/syntactic measurements (`claimed_bytes`, `available_bytes`, `is_truncated`, `is_overflow`). Zero `media_ir`, zero `tika`, zero security rules.
2. **`libs/media_ir` (`std` only)**: Pure Universal IR types and mathematical interval/topology/inconsistency engine returning typed facts. Zero `TaskContext`, zero hardcoded remediation strings.
3. **`apps/vidsec`**:
   - **IR Lowering Bridge** (`tasks/containers/lower_*.zig`) translating `isobmff`/`ebml`/`riff` dissector outputs into `media_ir` entities.
   - **Generalist Algorithmic Checks** (`tasks/{triage,containers,forensics}/`) enforcing the 4 invariant families + formatting `AuditFindingRow` + emitting `TruncateOrder`/`ZeroOutOrder`/`QuarantineOrder`.
   - **Predefined CDR Subscribers** (`remediation/`).
   - **Declarative CVE Compendium** (`apps/vidsec/configs/`) evaluated in YAML over dissected tables and `inspect_region_field` with zero Zig recompilation.

---

## 3. Target Architecture Overview

### 3.1 Pure Libraries in `libs/` (All `std` Only)

| Library | Responsibility | Dependencies | Status |
|---|---|---|---|
| `libs/tika` | Pure format/MIME/family identification & extension validation | `std` only | **Done** (`TASK-035.1`) |
| `libs/isobmff` | Pure MP4/ISOBMFF tree + atom dissector, containment measurements, positional reader | `std` only | Planned (`TASK-035.2`) |
| `libs/ebml` | Pure EBML/MKV VINT + element dissector, containment measurements, positional reader | `std` only | Planned (`TASK-035.3`) |
| `libs/riff` | Pure RIFF/AVI chunk + header dissector, containment measurements, positional reader | `std` only | Planned (`TASK-035.4`) |
| `libs/media_ir` | Deduplicated Universal IR (`IrSampleRunRow`) + 2-level slack & containment engine | `std` only | Planned (`TASK-035.5`) |

### 3.2 `apps/vidsec` Target Layout

```text
apps/vidsec/configs/
├── pipeline.yaml                # Safety + Sanitization DAG (no recompilation required)
├── schemas.yaml                 # Native container tables + media_ir (`ir_sample_runs`) + audit
└── cve_compendium.yaml          # Declarative CVE assertions (YAML rules via inspect_region_field / where:)

apps/vidsec/src/tasks/
├── triage/                      # Stage 0 — Polyglot & Quick Bounds (Done)
├── containers/                  # Stage 1a (Dissectors + Invariant 1 + CVE primitive) & Stage 1b (Lowering Bridge)
│   ├── common.zig
│   ├── dissect_isobmff.zig
│   ├── dissect_mp4_atoms.zig
│   ├── dissect_ebml.zig
│   ├── dissect_mkv_structures.zig
│   ├── dissect_riff.zig
│   ├── inspect_region_field.zig
│   ├── lower_mp4_container.zig
│   ├── lower_ebml_container.zig
│   └── lower_riff_container.zig
├── forensics/                   # Stage 2 — Generalist Universal IR Analyses
│   ├── analyze_topology.zig     # External + Interior media_data slack, overlaps, trailing overlay (+ TruncateOrder)
│   ├── check_inconsistencies.zig# SampleRuns subset media_data, dimension/codec mismatch (+ QuarantineOrder)
│   └── scan_entropy.zig         # Shannon entropy on unreferenced slack (+ ZeroOutOrder / QuarantineOrder)
└── remediation/                 # Predefined Pub/Sub CDR Subscribers (Done)
    ├── orders.zig
    ├── apply_truncate.zig
    └── apply_zero_out.zig
```

---

## 4. Fragmented Implementation Tasks (`TASK-035.1` – `TASK-035.8`)

Each task below is bounded so an execution model can complete and compile-verify it cleanly without breaking the workspace between tasks. **Must be executed in order (`035.2` → `035.3` → `035.4` removes `media_ir.common` consumers before `035.5` deletes `common/`).**

---

### `TASK-035.1` — Foundation: `libs/tika`, Stage 0 Triage & CDR Subscribers *(COMPLETED)*
- **Completed artifacts**:
  - `libs/tika/` pure format/MIME identifier.
  - `apps/vidsec/src/math/` pruned to `entropy.zig` and `stats.zig`.
  - Stage 0 atomic tasks in `apps/vidsec/src/tasks/triage/` (`check_file_size`, `detect_magic`, `check_extension`, `scan_head_executables`, `scan_tail_archives`, `measure_mid_entropy`).
  - CDR Pub/Sub subscribers in `apps/vidsec/src/tasks/remediation/` (`apply_truncate`, `apply_zero_out`, `orders.zig`) with `max_in_memory_bytes` guard.
  - Verified by `zig build test --summary all`.

---

### `TASK-035.2` — Refactor `libs/isobmff` into a Pure `std`-Only Deep Dissector
- **Goal**: Strip `media_ir`, security rules, `IssueCode`, and `lower.zig` out of `libs/isobmff`, and turn it into a pure streaming MP4/ISOBMFF binary dissector with containment measurements and positional readers.
- **Scope (`libs/isobmff/` & root `build.zig`)**:
  1. Remove `media_ir` dependency from `isobmff_mod` in root [build.zig](../../build.zig) and `apps/vidsec/build.zig`. Delete `libs/isobmff/lower.zig`, `libs/isobmff/box/checks/*`, `libs/isobmff/mp4/mp4_issue*.zig`, and `libs/isobmff/box/parser_issue*.zig`.
  2. Add self-contained `libs/isobmff/byte_source.zig` (`ctx`, `read_at_fn`, `file_size`, `fromSlice`) and `libs/isobmff/field_reader.zig` (`readU8`, `readU16Be`, `readU32Be`, `readU64Be`, `readFourCC`, `readTlvLength`).
  3. Upgrade box walker (`libs/isobmff/box/`) to output `DissectedBox` nodes including: `id`, `parent_id`, `depth`, `fourcc`, hierarchical `path` (e.g. `moov/trak/mdia/minf/stbl/stsc`), `header_offset`, `payload_offset`, `declared_size`, `is_extended_size`, `is_full_box`, `version`, `flags`, `child_count`, and physical `ContainmentMeasurement` (`claimed_bytes`, `available_bytes`, `is_truncated`, `is_overflow`).
  4. Upgrade `libs/isobmff/mp4/` dissector to extract without policy thresholds:
     - `ftyp` (`major_brand`, `minor_version`, `compatible_brands`)
     - `TrackRecord` (`track_id`, `handler_type`, `width`, `height`, `timescale`, `duration`, `codec_fourcc`, `avcC`/`hvcC`/`esds` decoded fields)
     - Coalesced **sample runs** directly from `stsc` + `stco`/`co64` + `stsz`/`stz2` (`SampleRun { track_id, first_sample, sample_count, start_offset, end_offset }`), plus `TableMeasurement` rows (`table_fourcc`, `path`, `entry_count`, `entry_size`, `claimed_bytes`, `payload_size`) for `stts`, `ctts`, `stsc`, `stsz`, `stco`, `co64`, `avcC`, `esds`.
  5. temporarily update `apps/vidsec/src/tasks/containers/{common,check_mp4_*,lower_mp4_container}.zig` (and MP4 tests) just enough to compile cleanly against the new `isobmff` API (full task redesign happens in `TASK-035.6`).
- **Out of Scope**: Modifying `libs/ebml`, `libs/riff`, `libs/media_ir`, or Stage 2 tasks.
- **Verification**: `zig build test` (root) and `cd apps/vidsec && zig build && zig build test --summary all` pass cleanly.

---

### `TASK-035.3` — Refactor `libs/ebml` into a Pure `std`-Only Deep Dissector
- **Goal**: Strip `media_ir`, `tika`, security rules, `IssueCode`, and `lower.zig` out of `libs/ebml`, and expose full EBML/Matroska structural dissection and containment measurements.
- **Scope (`libs/ebml/` & root `build.zig`)**:
  1. Remove `media_ir` dependency from `ebml_mod` in root [build.zig](../../build.zig) and `apps/vidsec/build.zig`. Delete `libs/ebml/lower.zig`, `libs/ebml/ebml/checks/*`, and `*Issue*` files.
  2. Add self-contained `libs/ebml/byte_source.zig` and expose `field_reader.zig` (reusing `vint.zig` + `readUint`/`readFloat`/`readString`).
  3. Upgrade `libs/ebml/ebml/` element walker to output `DissectedElement` (`id`, `parent_id`, `depth`, `ebml_id`, `ebml_id_hex`, hierarchical `path`, `header_offset`, `payload_offset`, `data_size`, `total_size`, `is_unknown_size`, `child_count`) and `ContainmentMeasurement` (including VINT width/overflow and element vs parent bounds).
  4. Upgrade `libs/ebml/mkv/` dissector to extract without policy:
     - `SegmentInfo` (`timecode_scale`, `duration`, `muxing_app`, `writing_app`)
     - `MkvTrackRecord` (`track_number`, `track_uid`, `track_type`, `codec_id`, `width`, `height`, `sampling_frequency`, `channels`, raw `codec_private` bytes)
     - `MkvAttachment` (`file_name`, `declared_mime`, `payload_offset`, `payload_size`, leading header bytes — no `tika` import inside `libs/ebml`)
     - `ClusterSpan` & `SimpleBlock`/`BlockGroup` contiguous data runs (`SampleRun`) and `Cues` offset table records.
  5. Temporarily update `apps/vidsec/src/tasks/containers/{check_ebml_header,check_mkv_tracks,lower_ebml_container}.zig` and EBML tests to compile against the new `ebml` API.
- **Out of Scope**: Modifying `libs/media_ir` or `libs/riff`.
- **Verification**: `zig build test` (root) and `cd apps/vidsec && zig build && zig build test --summary all` pass cleanly.

---

### `TASK-035.4` — Refactor `libs/riff` into a Pure `std`-Only Deep Dissector
- **Goal**: Strip `media_ir`, security rules, `IssueCode`, and `lower.zig` out of `libs/riff`, and add full AVI header/index dissection.
- **Scope (`libs/riff/` & root `build.zig`)**:
  1. Remove `media_ir` dependency from `riff_mod` in root [build.zig](../../build.zig) and `apps/vidsec/build.zig`. Delete `libs/riff/lower.zig`, `libs/riff/riff/checks/*`, and `*Issue*` files.
  2. Add self-contained `libs/riff/byte_source.zig` and `libs/riff/field_reader.zig` (`readU8`, `readU16Le`, `readU32Le`, `readU64Le`, `readFourCC`).
  3. Upgrade `libs/riff/riff/` chunk walker to output `DissectedChunk` (`id`, `parent_id`, `depth`, `fourcc`, `list_type`, hierarchical `path`, `header_offset`, `payload_offset`, `data_size`, `total_size`, `is_padded`, `child_count`) and `ContainmentMeasurement` (declared chunk/RIFF size vs enclosing bounds / EOF).
  4. Add `libs/riff/avi/` dissector for `avih` (`MainAVIHeader`: width, height, total_frames, streams), `strh` (`AVIStreamHeader`: stream type, handler FourCC), `strf` (`BITMAPINFOHEADER` width/height/compression / `WAVEFORMATEX`), and `idx1`/`indx` coalesced `SampleRun` + table bounds (`entry_count * 16` vs `idx1` `payload_size`).
  5. Temporarily update `apps/vidsec/src/tasks/containers/{check_riff_chunks,lower_riff_container}.zig` and RIFF tests to compile against the new `riff` API.
- **Out of Scope**: Modifying `libs/media_ir`.
- **Verification**: `zig build test` (root) and `cd apps/vidsec && zig build && zig build test --summary all` pass cleanly.

---

### `TASK-035.5` — Deduplicate & Upgrade `libs/media_ir` (Coalesced `IrSampleRunRow` + Two-Level Slack + Strict Pointer Containment)
- **Goal**: Clean out inherited triplication inside `libs/media_ir` and fix the scaling and security blind spots identified in Section 2.2.
- **Prerequisites**: `TASK-035.2`–`035.4` complete (no format lib imports `media_ir.common` anymore).
- **Scope (`libs/media_ir/` only + updating existing lowering call sites in `apps/vidsec` if any types renamed)**:
  1. **Deduplicate & Prune**:
     - Delete `libs/media_ir/common/` (no longer imported anywhere), `libs/media_ir/rows/emit_helpers.zig`, `libs/media_ir/rows/compute_unreferenced_slack.zig`, and redundant finding/region wrappers (`findings/finding.zig`, `findings/finding_list.zig`). Keep a single canonical `RegionRole`, `ContainerFormat`, `IrRegionRow`, `ContainerMetadataRow`, `IrCodecConfigRow`, `IrAttachmentRow`, `IrExternalRefRow`.
  2. **Coalesced Sample Runs**:
     - Replace per-sample `IrSampleExtentRow` with `IrSampleRunRow` (`run_id`, `track_id`, `first_sample_index`, `sample_count`, `source_tag`, `start_offset`, `end_offset`) plus helper `coalesceSampleRuns` to merge contiguous runs in linear time.
  3. **Unified Interval Algebra Engine (`analysis/topology.zig` & `analysis/inconsistencies.zig`)**:
     - Upgrade `topology` to return pure typed facts (zero `std.fmt.allocPrint` English strings, zero `"UNRESOLVED"` policy strings) covering:
       - External gaps (`leading_gap`, `inter_region_gap`, `trailing_overlay`) across root regions and intra-container child intervals.
       - Region overlaps (`RegionOverlap`).
       - **Interior `media_data` slack** ($\text{Regions}(\text{role} == \text{media\_data}) \setminus \bigcup \text{IrSampleRunRow}$).
     - Upgrade `inconsistencies` to return pure typed facts covering:
       - EOF overflows (`end_offset > file_size` on regions or sample runs).
       - **Sample pointer escape** ($\text{IrSampleRunRow} \not\subseteq \bigcup \text{Regions}(\text{role} == \text{media\_data})$), catching pointers targeting `ftyp`/`moov`/`free` or unallocated holes.
       - **Container vs. Bitstream Mismatch** on `IrCodecConfigRow` (dimension/codec discrepancy).
  4. **Unit tests in `libs/media_ir/`**: verify interval subtraction $\text{media\_data} \setminus \text{SampleRuns}$, pointer escape detection (`stco` pointing to offset `0` / `ftyp`), coalescing 10,000 samples into 1 run, overlaps, and trailing overlays.
- **Verification**: `zig test libs/media_ir/mod.zig` and `zig build test` (root) pass cleanly.

---

### `TASK-035.6` — Stage 1 Atomic Dissectors, Parametric CVE Primitive & Deep IR Lowering Bridge in `apps/vidsec`
- **Goal**: Build the new `apps/vidsec/src/tasks/containers/` library of atomic Stage 1 tasks on top of the pure `libs/{isobmff,ebml,riff}` dissectors and upgraded `libs/media_ir`.
- **Scope (`apps/vidsec/src/tasks/containers/`, `src/tasks/mod.zig`, `src/catalog.zig`, `apps/vidsec/tests/containers/`)**:
  1. Implement Stage 1a Dissector + Invariant 1 Containment tasks (removing old `check_mp4_*` / `check_ebml_*` / `check_mkv_*` / `check_riff_*`):
     - `dissect_isobmff.zig`: emits `isobmff_boxes` rows + generic containment `AuditFindingRow`s (`claimed_bytes > available_bytes` or truncated box).
     - `dissect_mp4_atoms.zig`: emits `mp4_tracks` rows + table/codec containment violations (`stts`, `ctts`, `stsc`, `stsz`, `stco`, `avcC`, `hvcC`, `esds`).
     - `dissect_ebml.zig`: emits `ebml_elements` rows + VINT/element containment violations.
     - `dissect_mkv_structures.zig`: emits `mkv_tracks` + `ir_attachments` (classified via `libs/tika`) + MKV table/codec violations.
     - `dissect_riff.zig`: emits `riff_chunks` + AVI `avih`/`strh`/`strf`/`idx1` measurements + chunk/table containment violations.
  2. Implement **`inspect_region_field.zig`** (`analyzer/inspect_region_field`):
     - Accepts `stream: BoundedStreamReader`, `target_path: []const u8` (or `target_tag`), `container_family: []const u8`, `field_offset: u64`, `field_type: []const u8` (`u8`/`u16be`/`u16le`/`u32be`/`u32le`/`u64be`/`u64le`/`fourcc`), `rule_id: []const u8`, and assertion bounds (`min_value`, `max_value`, `max_stride_bytes` checked against `entry_count * max_stride_bytes <= payload_size`).
     - Emits matching values, `rule_passed: bool`, and `AuditFindingRow` / `QuarantineOrder` cleanly without recompilation.
  3. Upgrade **Deep IR Lowering Bridge** (`lower_mp4_container.zig`, `lower_ebml_container.zig`, `lower_riff_container.zig`) in `apps/vidsec` to emit `container_metadata`, `ir_regions`, `ir_sample_runs`, `ir_codec_configs`, `ir_attachments`, and `ir_external_refs`.
  4. Register all services in `catalog.zig` and add unit tests in `apps/vidsec/tests/containers/` covering table dissection, generic overflow invariants, `inspect_region_field` assertions, and coalesced IR lowering.
- **Verification**: `cd apps/vidsec && zig build && zig build test --summary all` passes cleanly.

---

### `TASK-035.7` — Stage 2 Generalist Universal IR Forensic Tasks in `apps/vidsec`
- **Goal**: Implement format-agnostic security tasks in `apps/vidsec/src/tasks/forensics/` operating solely on `media_ir` entities (plus `BoundedStreamReader` for bounded entropy sampling on discovered slack intervals).
- **Scope (`apps/vidsec/src/tasks/forensics/`, `src/tasks/mod.zig`, `src/catalog.zig`, `apps/vidsec/tests/forensics/`)**:
  1. **`analyze_topology.zig`**: runs `media_ir.analyzeTopology` on `ir_regions`, `ir_sample_runs`, and `container_metadata`; translates typed gaps (`leading_gap`, `inter_region_gap`, interior `media_data` slack, `trailing_overlay`, `RegionOverlap`) into `audit_findings`, `ir_unreferenced_slack`, and `TruncateOrder` when `trailing_overlay` violates policy params.
  2. **`check_inconsistencies.zig`**: runs `media_ir.checkInconsistencies` across `ir_sample_runs`, `ir_codec_configs`, and `ir_regions`; emits `audit_findings` and `QuarantineOrder` on pointer escapes ($\text{SampleRuns} \not\subseteq \text{media\_data}$), EOF overflows, or container/bitstream dimension/codec mismatches.
  3. **`scan_entropy.zig`**: reads bounded slices (up to `max_sample_bytes` window) at each `ir_unreferenced_slack` offset using `BoundedStreamReader` + `vidsec_math.entropy`, emitting `audit_findings` and `ZeroOutOrder` (or `QuarantineOrder` if configured) when entropy exceeds `min_entropy`.
  4. Register in `catalog.zig` and add comprehensive unit tests in `apps/vidsec/tests/forensics/` (including a synthetic test proving `mdat` slack behind real frames AND `stco` pointing into `ftyp` are both caught!).
- **Verification**: `cd apps/vidsec && zig build && zig build test --summary all` passes cleanly.

---

### `TASK-035.8` — Schema Alignment, Default `pipeline.yaml`, Declarative CVE Compendium & E2E Tests
- **Goal**: Wire Stage 0 → Stage 1a → Stage 1b → Stage 2 → CDR Subscribers + starter Declarative CVE Compendium in configuration, and verify end-to-end flows.
- **Scope (`apps/vidsec/configs/`, `apps/vidsec/tests/`)**:
  1. Update [schemas.yaml](../../apps/vidsec/configs/schemas.yaml): replace `ir_sample_extents` with `ir_sample_runs` (`run_id`, `track_id`, `first_sample_index`, `sample_count`, `source_tag`, `start_offset`, `end_offset`) and align Stage 1 native table columns.
  2. Update [pipeline.yaml](../../apps/vidsec/configs/pipeline.yaml) with the full 4-stage reactive DAG (`triage` → `dissect_*` + `inspect_region_field` → `lower_*_container` → `analyze_topology` / `check_inconsistencies` / `scan_entropy` → `apply_truncate` / `apply_zero_out` / `quarantine`).
  3. Add a starter declarative CVE compendium (`apps/vidsec/configs/cve_compendium.yaml` or documented YAML steps) demonstrating canonical CVE checks expressed solely in config (`CVE-2015-1538` `stsc` count overflow, `CVE-2015-3864` `tx3g` size bounds, `avcC` SPS length bounds).
  4. Add E2E pipeline tests in `apps/vidsec/tests/` verifying clean media pass-through, generic exploit quarantine, YAML-configured CVE detection without recompilation, and `TruncateOrder` / `ZeroOutOrder` execution.
- **Verification**: Full root `zig build test --summary all` and `cd apps/vidsec && zig build && zig build test --summary all` pass 100%.

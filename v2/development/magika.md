# Google Magika (`libmagika`) Integration in Vidsec (`v2/development/magika.md`)

## 1. Introduction and Context

**Google Magika** is an open-source (Apache 2.0) Deep Learning tool and model released by Google in 2024 for high-speed, highly accurate binary and textual content type identification. It has been adopted by large-scale platforms including **VirusTotal**, **Google Drive**, and **Gmail** as a modern replacement and complement to the classic Unix `file` command (`libmagic`).

This document provides an in-depth technical analysis of Magika's internal mechanics, evaluates differences relative to Vidsec's native `src/lib/magic/` engine, highlights the architectural advantages it brings to Vidsec, and specifies the recommended integration model to maintain autonomous zero-dependency compilation alongside surgical forensic capabilities.

---

## 2. Internal Mechanics of Google Magika

Unlike Large Language Models (LLMs) or heavyweight computer vision pipelines, Magika was engineered specifically for ultra-high-throughput production environments:

1. **Ultralight Neural Network (~1 MB):**
   - Compact neural network trained to classify over 100 file types (`ct_label`).
   - Exported to standard inference runtimes (**ONNX** and **TFLite**).
   - Inference latency of **$\sim 5 \text{ ms}$ per file** on a single standard CPU core (requires no GPU or dedicated hardware accelerators).

2. **Efficient Block Sampling:**
   - Magika **does not** read entire files into RAM (which would be prohibitive for multi-gigabyte video streams).
   - It samples 512-byte windows at strategic positions:
     - Initial file header (*Head Buffer*).
     - Exact midpoint (*Midpoint Buffer*).
     - Trailing file footer (*Tail Buffer*).
   - These windows are vectorized into features fed directly to the model.

3. **100% Local and Offline Inference:**
   - Executes strictly local inference without external API calls or network connectivity.
   - Core production engine written in **Rust** (`libmagika`), offering official bindings for C, Python, Go, and Node.js.

4. **Output Structure:**
   - `ct_label`: Canonical content identifier (e.g., `mp4`, `mkv`, `avi`, `pebin`, `elf`, `zip`, `pdf`, `javascript`).
   - `score`: Confidence probability metric between $0.0$ and $1.0$.
   - `group`: Functional classification group (`media`, `executable`, `archive`, `code`, `document`).
   - `mime_type`: Standardized MIME type (e.g., `video/mp4`).
   - `description`: Human-readable format description.

---

## 3. Comparative Analysis: `libmagika` vs. `vidsec_magic` (Native Zig)

| Dimension | `libmagika` (Google / VirusTotal) | `vidsec_magic` (Native Zig in Vidsec) |
| :--- | :--- | :--- |
| **Architectural Focus** | **Global probabilistic classifier.** Predicts what the file resembles overall. | **Deterministic offset-based forensic scanner.** Inspects exact byte signatures and structural contracts. |
| **Polyglot File Detection** | ⚠️ **Limited:** Assigns a single predominant label (or lowers confidence `score`). Cannot isolate embedded sub-payloads. | ✅ **Excellent:** Actively scans the *Tail Buffer* (`scanTailArchives`) for appended `ZIP EOCD`, `RAR`, or `7z` headers following media streams. |
| **Hidden Executable Detection** | ⚠️ Only triggered if the overall payload globally resembles an executable. | ✅ `scanHeadExecutables` detects `MZ`, `ELF`, Mach-O stubs, or script headers injected before or between container atoms. |
| **Offset Reporting** | ❌ Does not report spatial byte ranges (`file_offset`, `byte_length`). | ✅ Pinpoints the exact byte offset and length of every anomaly to populate `audit_findings`. |
| **Memory Footprint** | $\approx 20\text{--}50 \text{ MB}$ RSS to initialize the ONNX runtime and tensors. | **0 heap bytes** (static stack-and-register execution, bounded buffer $\le 128 \text{ KB}$). |
| **Build Toolchain** | Requires **Rust** toolchain (`cargo`), ONNX runtime (`ort`/`tract`), and C bindings. | **100% native Zig**, builds in $\sim 200 \text{ ms}$ and cross-compiles to any OS target without external dependencies. |

---

## 4. Architectural Value of `libmagika` for Vidsec

Integrating Magika into the Vidsec pipeline provides four distinct strategic capabilities:

### A. Anti-Evasion and Header Spoofing Detection
Sophisticated adversaries may forge the initial 16 bytes of an executable to match an MP4 header (`00 00 00 20 66 74 79 70 69 73 6F 6D`), while appending a packed PE/ELF binary or obfuscated script.
* A basic signature scanner might pass the file at Stage 0 based solely on magic bytes.
* **Magika detects the contextual dissonance:** its neural network evaluates the whole sample structure, flags `ct_label: pebin` (or confidence $< 0.50$), and immediately raises a critical header-spoofing alarm.

### B. Dual-Engine Verification
Correlating both analytical engines enables high-confidence gatekeeping rules within `pipeline.yaml`:
$$\text{High Confidence} \iff (\text{vidsec\_magic} = \text{ISOBMFF}) \land (\text{magika.ct\_label} = \text{"mp4"}) \land (\text{magika.score} \ge 0.95)$$

When the two engines disagree:
* The router diverts execution into deep quarantine or comprehensive sandbox forensics (`quarantine_sandbox`).

### C. Rich Classification of Carved Slack and Attachments (`ir_attachments`)
Modern containers (such as MKV / `EBML`) permit embedding arbitrary binary attachments (TTF fonts, cover images, subtitles, or binary executables).
* `vidsec_magic` relies on hardcoded signatures for common media sub-types.
* Magika instantly identifies carved slack data and attachments across 100+ formats without bloating Zig source code with handcrafted signature tables.

### D. Alignment with Industry Standards (VirusTotal)
Generating audit reports (PDF/LaTeX, `v_findings_report`) that expose canonical **Magika** fields identical to VirusTotal output establishes immediate technical credibility with Security Operations Center (SOC) teams and forensic analysts.

---

## 5. Proposed Integration Architecture

To preserve Vidsec's **self-contained zero-dependency build purity** while retaining granular forensic offset detection, integration follows a decoupled two-phase model:

```
[ Input Video File ]
         │
         ├───► [ Stage 0: vidsec_magic (Native Zig) ] ──────────► file_triage (Offsets, Polyglots, Fast Reject)
         │
         └───► [ Optional Plugin: vidsec_magika (C-ABI) ] ──────► magika_triage (ct_label, score, group)
                                                                        │
                                                                        ▼
                                                   [ Router: Dual Correlation in Memory / SQLite ]
```

### Phase 1: Schema and Contract Alignment
1. Standardize `file_triage` schema attributes:
   - `magika_label: text` (e.g. `'mp4'`, `'mkv'`, `'pebin'`).
   - `magika_score: real` (confidence score from $0.0$ to $1.0$).
   - `magika_group: text` (e.g. `'media'`, `'executable'`).
2. When Magika is inactive, `vidsec_magic` populates these fields with canonical equivalents and synthetic confidence `score = 1.0`.

### Phase 2: Decoupled Dynamic C-ABI Plugin (`vidsec_magika.so`)
1. Implement a standalone C-ABI plugin isolated from the primary Vidsec binary.
2. The plugin can compile optionally against `libmagika` C bindings or execute the standalone CLI subprocess `magika <file> --json`.
3. The Vidsec Host dynamically loads the plugin only when declared in `pipeline.yaml`, maintaining a 100% autonomous core binary for lightweight and embedded deployments.

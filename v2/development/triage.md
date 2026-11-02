# TASK SPECIFICATION: Lightweight Video Triaging Plugin

## 1. Objective
Implement the initial stage (Stage 0: Triaging) of an antivirus pipeline for media files. This component performs fast, heuristic, and signature-based checks over incoming files without invoking heavy parsing libraries (e.g., FFmpeg, libavformat, GPAC) or constructing full structural trees (MP4 boxes, EBML hierarchies).

The purpose of this plugin is to run in sub-millisecond time, consume minimal RAM, and act as a gatekeeper to flag or drop malformed files, extension mismatches, embedded payloads, or polyglots.

---

## 2. Constraints & Non-Functional Requirements
1. **Zero Full Parsing:** Do not recursively parse MP4 atom hierarchies, EBML elements, or full RIFF trees.
2. **Strict Memory Footprint:** Do not load full files into memory. Allocate at most $128 \text{ KB}$ per file during analysis.
3. **Execution Bound:** Maximum execution time per file must remain $< 5 \text{ ms}$.
4. **Buffer Policy:**
   - Read `Head Buffer`: First $64 \text{ KB}$ (or file size if smaller).
   - Read `Tail Buffer`: Last $64 \text{ KB}$ (from `st_size - 64 KB` to `st_size`).
   - Read `Mid Buffer`: $4 \text{ KB}$ sampled at offset $\lfloor \text{st\_size} / 2 \rfloor$.

---

## 3. Analysis Pipeline & Checks

### Check 1: File Size Bounds
- Reject or flag if `st_size < 128 bytes` (insufficient bytes for any valid video container header).
- Reject or flag if `st_size > MAX_ALLOWED_FILE_SIZE` (configurable).

### Check 2: Primary Magic Number vs. Extension Validation
Validate that the primary header matches the declared file extension:
- **MP4 / ISO Base Media (`.mp4`, `.mov`, `.m4v`):**
  - Offset `4..7` equals ASCII `ftyp`.
  - Bytes `0..3` interpreted as a big-endian uint32 must be between 16 and 4096 (standard `ftyp` box size), or flag if `0` or absurdly large.
- **MKV / WebM (`.mkv`, `.webm`):**
  - Offset `0..3` equals hex `1A 45 DF A3` (EBML Header ID).
- **AVI (`.avi`):**
  - Offset `0..3` equals `RIFF`, offset `8..11` equals `AVI `.
  - Optional size cross-check: Bytes `4..7` (uint32 little-endian) should equal `st_size - 8` (within a 4-byte padding tolerance). If delta $> 64 \text{ KB}$, flag as payload overlay.
- **MPEG-TS (`.ts`, `.mts`):**
  - Synchronization byte periodic check: Check offset `0`, `188`, `376`, `564`. All must equal `0x47`. If not, test with 204-byte stride. If both fail, flag as invalid TS.

### Check 3: Polyglot & Secondary Executable Signature Hunting
Inspect `Head Buffer` and `Tail Buffer` for signatures that should never exist natively at these positions:
- **Executable Binaries:**
  - `Head`: Look for `MZ` (`0x4D 0x5A`) or `\x7fELF` (`0x7F 0x45 0x4C 0x46`) in the first 16 bytes.
- **Archives / Appended Payloads:**
  - Search `Tail Buffer` (specifically the last 512 bytes) for:
    - `PK\x05\x06` (`0x50 0x4B 0x05 0x06` - ZIP End of Central Directory record).
    - `Rar!\x1A\x07` (`0x52 0x61 0x72 0x21 0x1A 0x07` - RAR volume marker).
    - `7z\xBC\xAF\x27\x1C` (`0x37 0x7A 0xBC 0xAF 0x27 0x1C` - 7z signature).

### Check 4: Fast Sampled Shannon Entropy
Compute the Shannon entropy $H$ over a 4096-byte window at the midpoint $\lfloor \text{st\_size} / 2 \rfloor$:
$$H = -\sum_{i=0}^{255} p_i \log_2(p_i)$$
- **Heuristic rule:**
  - Modern compressed video streams (H.264, HEVC, VP9, AV1) consistently exhibit high entropy: $H \ge 7.3$.
  - If $H < 5.5$ on `Mid Buffer`, flag as `SUSPICIOUS_LOW_ENTROPY` (likely uncompressed junk, text mock, or an empty padding placeholder).

### Check 5: Suspicious ASCII / Script Strings Scan
Scan only the `Head Buffer` (first $64 \text{ KB}$) for raw command execution stubs:
- Patterns: `#!/bin/`, `powershell`, `cmd.exe`, `wscript.exe`, `cscript.exe`.
- Dangerous URL schemes: `javascript:`, `file://`.

---

## 4. Expected Output Data Contract

The plugin must return a structured result without throwing unhandled exceptions:

```json
{
  "file_path": "/path/to/sample.mp4",
  "file_size": 10485760,
  "verdict": "FLAGGED", // "PASS", "FLAGGED", "DROP"
  "identified_format": "mp4",
  "extension_match": true,
  "metrics": {
    "mid_entropy": 7.84,
    "head_size_read": 65536,
    "tail_size_read": 65536
  },
  "flags": [
    "SECONDARY_SIGNATURE_ZIP_EOCD_FOUND",
    "SUSPICIOUS_STRING_DETECTED"
  ],
  "details": {
    "suspicious_strings": ["powershell -enc"],
    "zip_eocd_offset": 10485738
  }
}
```

---

## 5. Development Steps for the Implementer
1. Implement file stream reader allowing random seeks with read limits (`Head`, `Tail`, `Mid`).
2. Implement byte-level matcher for signatures avoiding unnecessary copies.
3. Implement $O(N)$ entropy function using a 256-integer histogram table over the 4 KB mid sample.
4. Integrate rule checks and assemble the output struct/JSON.
5. Create unit tests for:
   - Valid sample video files (MP4, MKV, AVI, TS).
   - Video file concatenated with a ZIP at the end (`cat sample.mp4 payload.zip > polyglot.mp4`).
   - Text file renamed to `.mp4`.
   - Sample with `MZ` stub or `/bin/sh` inserted in the first 4 KB.
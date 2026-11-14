# Análisis de Seguridad y Forense en Archivos de Vídeo (Genéricos y por Formato)

Recopilación de las operaciones de análisis definidas en las especificaciones (`docs/v1/specs/M1`–`M4`) y en la implementación actual de `apps/vidsec/src/analysis/`. Sirve como catálogo base para extraer librerías puras en `libs/` y definir tasks atómicos en el DAG de `pipeline.yaml`.

---

## 1. Análisis Genéricos (Agnósticos al Formato)

Operaciones que trabajan sobre bytes, ventanas (`head` / `mid` / `tail`), o sobre el **IR Universal** sin depender de si el archivo es MP4, MKV, AVI o TS.

### 1.1 Fase 0 — Triaje Rápido y Detección de Anomalías Iniciales
Diseñado para ejecutarse sobre ventanas acotadas (`<= 64 KB` en cabecera/cola y `4 KB` en mitad) antes de cualquier parsing pesado:

| Operación Atómica | Ventana / Input | Qué detecta / Calcula | Parámetros configurables (`.env` / YAML) |
|---|---|---|---|
| **Validación de límites físicos** (`check_file_bounds`) | `file_size` (`0 B` leídos) | Archivos vacíos/truncados (`FILE_TOO_SMALL`) o que exceden presupuesto (`FILE_EXCEEDS_MAX_SIZE`). | `min_file_size_bytes`, `max_file_size_bytes` |
| **Detección de Magic Header** (`detect_magic_header`) | Cabecera (`<= 64 KB`) | Firma mágica real, familia (`isobmff`, `ebml`, `riff`, `mpeg_ts`, `mpeg_ps`), MIME, si es vídeo válido o ejecutable primario. | — |
| **Validación de extensión declarada** (`validate_declared_extension`) | Metadatos (`0 B` leídos) | Discrepancia entre extensión del fichero y el formato mágico real (`EXTENSION_MAGIC_MISMATCH`, `INVALID_MPEG_TS_SYNC`). | `strict_extension`, `expected_extension` |
| **Escaneo de ejecutables en cabecera** (`scan_head_executables`) | Cabecera (`<= 4 KB`–`64 KB`) | Stubs PE (`MZ`), ELF (`\x7fELF`), Mach-O o payloads Go incrustados (`PRIMARY_EXECUTABLE_DETECTED`, `SECONDARY_EXECUTABLE_IN_HEAD`). | `scan_limit` |
| **Escaneo de cadenas sospechosas** (`scan_suspicious_strings`) | Cabecera (`<= 64 KB`) | Patrones de inyección o scripts (`#!/bin/`, `/bin/sh`, `powershell`, `cmd.exe`, `wscript.exe`, `cscript.exe`, `javascript:`, `file://`). | Lista de patrones |
| **Muestreo de entropía media** (`sample_mid_entropy`) | Mitad del fichero (`4 KB` en `file_size / 2`) | Entropía de Shannon baja en vídeos supuestamente comprimidos (`SUSPICIOUS_LOW_ENTROPY`, relleno/decoy). | `min_mid_entropy` (ej. `5.5`), `min_valid_video_size` |
| **Escaneo de archivos en cola** (`scan_tail_archives`) | Cola (`<= 64 KB` antes de EOF) | Políglotas o archivos adjuntos al final: ZIP EOCD (`0x06054B50`), RAR (`Rar!\x1a\x07`), 7z (`7z\xbc\xaf\x27\x1c`). | `tail_buffer_max` |

> El enrutamiento y decisión de corte en Fase 0 (`PASS` / `FLAGGED` / `DROP`) se resuelven declarativamente mediante `router` en `pipeline.yaml` sobre los flags emitidos por estos pasos, sin necesidad de un task reductor dedicado.

### 1.2 Análisis Forense sobre IR Universal (Post-Lowering)
Una vez que el contenedor se traduce al **IR Universal**, todas estas operaciones son 100% agnósticas al formato:

| Operación Atómica | Inputs (IR) | Qué detecta (`rule_id`) | Parámetros configurables |
|---|---|---|---|
| **Huecos no referenciados** (`detect_unreferenced_gaps`) | `IrRegionRow[]` (regiones raíz) | Huecos iniciales (`start > 0` → `leading_slack`) y huecos entre regiones (`start > prev_end` → `unreferenced_gap`, `R02_UNREFERENCED_GAP`). | `min_slack_bytes` |
| **Solapamientos de regiones** (`detect_region_overlaps`) | `IrRegionRow[]` (regiones raíz) | Regiones raíz que se solapan (`start < prev_end`, `R05_REGION_OVERLAP`), clásico en exploits de parsers o políglotas. | — |
| **Trailing Overlay** (`detect_trailing_overlay`) | `file_size`, `IrRegionRow[]` | Datos huérfanos tras `highest_root_end` hasta `file_size` (`R01_TRAILING_OVERLAY`). | `max_allowed_trailing_bytes` |
| **Entropía en zonas de slack/padding** (`scan_entropy`) | `IrUnreferencedSlackRow[]` + ventanas de stream | Payload cifrado/comprimido oculto en padding/slack (`R07_HIGH_ENTROPY_PAYLOAD`), descartando bloques todo-cero (`isAllZero`). | `entropy_threshold` (ej. `7.2` bits/byte), ventana de muestreo (`64 KB`) |
| **Desbordamiento de muestras** (`check_sample_overflows`) | `file_size`, `IrSampleExtentRow[]` | Muestras cuyo `end_offset > file_size` (`R08_SAMPLE_EXTENT_OVERFLOW`) o tablas de muestras con DoS (`sample_count * 4 > payload`). | `max_samples_per_track` |
| **Inconsistencia de dimensiones / codec** (`check_codec_mismatches`) | `IrCodecConfigRow[]` | Discrepancia entre dimensiones declaradas en contenedor (`tkhd`, `TrackVideo`, `strh`) y bitstream SPS (`R09` / `R10_DIMENSION_MISMATCH`). | Tolerancia estricta (igualdad exacta) |

### 1.3 Remediación / CDR (Content Disarm & Reconstruction)
- **Carving a cuarentena (`carve_quarantine`)**: extrae rangos críticos (overlays, slacks sospechosos, adjuntos ejecutables) al almacén de cuarentena antes de limpiar.
- **Saneamiento quirúrgico (`surgical_cdr`)**: trunca el archivo en `highest_root_end` (elimina trailing overlays), rellena con ceros o hace *hole punching* (`fallocate`) en huecos no referenciados, y marca hallazgos como remediados.
- **Remux en sandbox (`sandboxed_remux`)**: vía alternativa mediante `ffmpeg` en sandbox estricto (`-map 0:v:0 -map 0:a? -dn -map_metadata -1 -c copy`).

---

## 2. Análisis Específicos por Formato

Operaciones que requieren entender la sintaxis binaria concreta de un contenedor o bitstream para validarlo en **Nivel 1 (Estructural)** y **Nivel 2 (Semántico / Tablas de Muestras)** antes de emitir IR Universal.

### 2.1 ISOBMFF / MP4 / MOV
- **Sanidad rápida de `ftyp` (Fase 0)**: verifica en los primeros 8 bytes que la caja `ftyp` tenga tamaño en `[16, 4096]` y sea múltiplo de 4 (`ftyp_abnormal_box_size`).
- **Auditoría estructural L1 (`auditIsobmff`)**:
  - Recorre jerarquía de cajas (4-byte size big-endian, 8-byte `largesize`, FourCC).
  - Detecta: tamaños inválidos (`size == 0` en no-última caja o `< 8`), desbordamientos fuera de padre/EOF, cabeceras truncadas, múltiples `ftyp`, falta o duplicado de `moov`, ciclos/solapamientos, y `trailing_slack_bytes > 64`.
- **Auditoría semántica L2 (`auditMp4`)**:
  - Valida `track_id` (`0` o duplicados), ausencia de pistas en `moov`.
  - Valida tablas de muestras (`stco`/`co64` fuera de bounds, `stsc`, `stsz` extendiéndose más allá de EOF).
  - Detecta referencias externas peligrosas en `dref` (`url ` / `urn ` apuntando a `http://`, `https://`, `file://`, `\\` SMB — `R05_ExternalDataRef`).
  - Inspecciona descriptores de codec (`avcC` SPS/PPS length overflow, `esds` TLV length overflow).
  - Calcula `unreferenced_mdat_slack` (bytes dentro de `mdat` no cubiertos por ninguna muestra de `stsz`/`stco`).

### 2.2 EBML / Matroska (MKV) / WebM
- **Auditoría estructural L1 (`auditEbml`)**:
  - Decodifica IDs y tamaños VINT (1–4 octetos para ID, 1–8 octetos para tamaño).
  - Detecta: VINT que excede 8 octetos, ID > 4 bytes, cabecera truncada, elemento que excede EOF, ausencia o duplicado de `EBMLHeader`, y `trailing_slack_bytes > 64 KB`.
  - Extrae `doc_type` (`matroska` / `webm`) y `doc_type_version`.
- **Auditoría semántica L2 (`auditMkv`)**:
  - Valida `TrackNumber` (`0` o duplicados), ausencia de `Tracks` en `Segment`.
  - Inspecciona `CodecPrivate` (`avcC` SPS/PPS overflow).
  - **Adjuntos embebidos (`AttachedFile` `0x61A7` — `R06`)**: clasifica por magic bytes (fuentes TTF/OTF → warning; ejecutables `MZ`/`ELF` o archivos `ZIP` → critical).
  - **Referencias externas (`R05`)**: detecta `NextFilename` / `PrevFilename` apuntando a rutas externas.
  - Calcula `unreferenced_cluster_slack` dentro de `Cluster` / `SimpleBlock` / `BlockGroup`.

### 2.3 RIFF / AVI / WebP
- **Sanidad rápida de tamaño RIFF (Fase 0)**: compara tamaño little-endian en `[4..8]` contra `file_size - 8` con tolerancia `max_size_delta` (`AVI_RIFF_SIZE_MISMATCH`).
- **Auditoría estructural L1 (`auditRiff`)**:
  - Recorre chunks little-endian con alineación obligatoria a frontera de palabra de 2 bytes (`size % 2 == 1` añade 1 byte de padding).
  - Detecta: cabecera `RIFF` inválida, `root_size` menor que el mínimo, `chunk_size_overflow`, cabecera truncada, y `trailing_slack_bytes > 64 KB`.
  - Contabiliza `movi_bytes` y `junk_bytes`.
- **Auditoría profunda (`idx1`, `strh`, `strf` — spec M3)**:
  - Valida offsets/tamaños del índice `idx1` respecto a `LIST:movi`.
  - Cruza dimensiones declaradas en `strh` contra `BITMAPINFOHEADER` en `strf` (`R09`).

### 2.4 MPEG-TS / MPEG-PS
- **Sincronización de paquetes (`mpeg_ts`)**: verifica byte de sincronización `0x47` repetido en pasos de 188 bytes (`INVALID_MPEG_TS_SYNC` cuando la extensión es `.ts`/`.mts`/`.m2ts` y no sincroniza).
- **Walker de paquetes TS (planificado en M1)**: extracción de PIDs, PAT/PMT y PES streams hacia regiones/muestras del IR.

### 2.5 Bitstreams de Codecs (H.264/AVC, H.265/HEVC, AAC)
- **Parsing de `avcC` / `hvcC` / `esds` / `CodecPrivate`**:
  - Validación de límites internos (longitudes SPS/PPS, longitud de NAL length size `1|2|4`, TLV en `esds`).
  - Decodificación de dimensiones reales del bitstream (ej. SPS width/height) para cruzarlas con las declaradas por el contenedor (`R09` / `R10`).


# ARCH-035: Extracción de Librerías VidSec en `libs/` y Reconstrucción Limpia de `apps/vidsec`

**Status**: Proposed  
**Date**: 2026-11-14  
**Related**: [ARCH-015](015-declarative-task-services-and-comptime-di.md), [ARCH-034](034-filesystem-stream-and-slice-datasource.md), [Análisis de Vídeo](../learning/video-security-and-forensic-analyses.md), [IR Universal](../learning/universal-container-ir-decoupling.md)

---

## 1. Objetivo y Principio Rector

Reemplazar la estructura actual de `apps/vidsec/src/analysis/` y `apps/vidsec/src/tasks/` por el mismo patrón limpio que ya funciona en `apps/mangadex`:

- **`libs/`**: librerías Zig 100% puras de dominio (sin `flowdata_abi`, sin `TaskContext`, sin YAML/SQLite), testables de forma aislada con `zig build test`.
- **`apps/vidsec/src/`**: capa finísima de adaptación al framework Flowdata 2.0:
  - `main.zig`, `container.zig` (`VidsecPluginContainer`), `catalog.zig`
  - `tasks/*.zig`: Services atómicos (~30–70 líneas por archivo), cada uno con una única responsabilidad, sin `TaskContext` y parametrizables vía `.env` / `pipeline.yaml`.
- **`apps/vidsec/configs/pipeline.yaml`**: DAG coherente que compone esos tasks atómicos por fases (Fase 0 Triaje → Routing por formato → Lowering a IR → Forense Universal → CDR / Auditoría).

> **Regla de seguridad del refactor**: No se elimina `apps/vidsec/src/` ni los tests actuales hasta que las librerías en `libs/` estén extraídas, compiladas y cubiertas por tests equivalentes.

---

## 2. Mapa de Librerías a Extraer en `libs/`

| Librería en `libs/` | Responsabilidad | Origen actual / Referencia | Dependencias internas |
|---|---|---|---|
| **`libs/file_magic`** | Identificación pura estilo **Apache Tika** (enfocada a vídeo y firmas de adjuntos/embebidos): detección de *magic bytes*, MIME type, familia de contenedor, detección básica de codificación/metadatos y validación de extensión declarada. Sin heurísticas de seguridad. | `src/magic/*`, `analysis/triage.zig` (resolución de extensión / MIME) | Ninguna (solo `std`) |
| **`libs/media_ir`** | Única fuente de verdad del IR Universal (`ContainerFormat`, `RegionRole`, `Region`, `IrRegionRow`, `Track`, `IrCodecConfigRow`, `SampleExtent`, `IrSampleExtentRow`, `IrUnreferencedSlackRow`, `IrAttachmentRow`, `IrExternalRefRow`, `ContainerMetadataRow`, `Verdict`, `AuditFinding`) **+ motores agnósticos sobre el IR** (intervalos, topología: gaps/overlaps/trailing overlay, inconsistencias de muestras/dimensiones y planificación CDR). | `src/ir/*`, `src/math/intervals.zig`, `analysis/types.zig`, `analysis/lowering/container/types.zig`, `analysis/lowering/container/common.zig`, `analysis/forensics/{topology,inconsistencies}.zig`, `remediation/*` | Ninguna (solo `std`) |
| **`libs/isobmff`** | Parser L1 de cajas ISOBMFF/MP4, sanidad rápida `ftyp`, parser L2 semántico (`moov`/`trak`/`stco`/`stsz`/`dref`/`avcC`/`esds`), detección de `mdat` slack y lowering directo a `media_ir`. | `analysis/audit/isobmff.zig`, `analysis/audit/mp4.zig`, `lowering/container/isobmff_container.zig`, `lowering/media/mp4_strategy.zig` | `media_ir` |
| **`libs/ebml`** | Decodificador VINT, parser L1 EBML, parser L2 MKV/WebM (`Tracks`, `Cluster`, `CodecPrivate`, `AttachedFile` + magic check, `NextFilename`), y lowering directo a `media_ir`. | `analysis/audit/ebml.zig`, `analysis/audit/mkv.zig`, `lowering/container/ebml_container.zig`, `lowering/media/mkv_strategy.zig` | `media_ir`, `file_magic` |
| **`libs/riff`** | Parser L1 de chunks RIFF (little-endian + alineación 2B), sanidad rápida de tamaño RIFF, parser L2 (`idx1`, `strh`, `strf` `BITMAPINFOHEADER`), y lowering directo a `media_ir`. | `analysis/audit/riff.zig`, `lowering/container/riff_container.zig` + spec M3 (`idx1`/`strf`) | `media_ir` |
| **`libs/mpegts`** *(Fase posterior)* | Sincronización de paquetes `0x47` (188B), walker PAT/PMT/PES y lowering a `media_ir`. | `analysis/triage.zig` (`isTsExtension`) + spec M1 | `media_ir` |

---

## 3. Estructura Objetivo de `apps/vidsec/src/` tras el Corte

```text
apps/vidsec/src/
├── main.zig
├── container.zig            # VidsecContext + VidsecPluginContainer (sin TaskContext)
├── catalog.zig              # Registro de Services atómicos en C-ABI
└── tasks/
    ├── triage/              # Fase 0 (base actual de tasks2/)
    │   ├── check_file_bounds.zig
    │   ├── detect_magic_header.zig
    │   ├── check_ftyp_box_bounds.zig
    │   ├── check_riff_size_sanity.zig
    │   ├── validate_declared_extension.zig
    │   ├── scan_head_executables.zig
    │   ├── scan_suspicious_strings.zig
    │   ├── sample_mid_entropy.zig
    │   └── scan_tail_archives.zig
    ├── containers/          # Frontends L1/L2 + Lowering -> media_ir
    │   ├── parse_isobmff.zig
    │   ├── audit_mp4_semantics.zig
    │   ├── parse_ebml.zig
    │   ├── audit_mkv_semantics.zig
    │   ├── parse_riff.zig
    │   └── lower_to_ir.zig
    ├── forensics/           # 100% agnósticos al formato (consumen media_ir)
    │   ├── detect_unreferenced_gaps.zig
    │   ├── detect_region_overlaps.zig
    │   ├── detect_trailing_overlay.zig
    │   ├── scan_slack_entropy.zig
    │   └── check_ir_inconsistencies.zig
    └── remediation/
        ├── plan_cdr_actions.zig
        └── evaluate_final_verdict.zig
```

---

## 4. Plan de Ejecución por Fases

### Fase 1 — Núcleo Común (`file_magic` + `media_ir`)
1. Crear `libs/file_magic/` con identificación pura estilo Apache Tika (MIME, magic bytes, familia, validación de extensión y detección básica de encoding), registrada en `build.zig` y con unit tests propios.
2. Crear `libs/media_ir/` unificando el IR Universal + intervalos, topología, inconsistencias y planificación CDR, registrada en `build.zig` y con unit tests propios.

### Fase 2 — Frontends de Contenedor (`isobmff`, `ebml`, `riff`)
1. Extraer cada formato a su librería en `libs/` preservando la lógica binaria y sus checks forenses específicos, con unit tests propios en cada librería.
2. Hacer que cada librería emita directamente estructuras de `media_ir` (eliminando adaptadores intermedios duplicados).
3. Incorporar `idx1` + `strh`/`strf` en `riff` para paridad con MP4/MKV.

### Fase 3 — Corte Limpio en `apps/vidsec`
1. Construir el nuevo `apps/vidsec/src/tasks/` (moviendo `tasks2/` + añadiendo `containers/`, `forensics/`, `remediation/` y las heurísticas locales de entropía/escáneres de payload propias de VidSec) como wrappers finos sobre `libs/` (`file_magic`, `media_ir`, `isobmff`, `ebml`, `riff`).
2. Actualizar `catalog.zig` y reescribir `apps/vidsec/configs/pipeline.yaml` como DAG declarativo por fases.
3. Eliminar el antiguo `apps/vidsec/src/analysis/`, `tasks2/` y los tests legados de `apps/vidsec/tests/`.
4. *(En paralelo o inmediatamente después)* Ejecutar [ARCH-034](034-filesystem-stream-and-slice-datasource.md) para respaldar `BoundedStreamReader` con `pread`/`mmap` desde el datasource de FS.

---

## 5. Suite de Testing Completa (Librerías + App)

En lugar de reutilizar tests acoplados al código legado de `apps/vidsec/tests/`, cada capa tiene su propia suite limpia y enfocada:

### 5.1 Tests Unitarios en Cada Librería (`libs/*`)
Cada librería compila y ejecuta sus propios tests vía `zig build test` en la raíz:

| Librería | Cobertura requerida (sintéticos + fixtures) |
|---|---|
| **`libs/media_ir`** | • `ContainerIR`: jerarquía padre/hijo, contabilidad de espacio, consultas por tag/track/samples.<br>• `Interval`: detección de solapamientos (`hasOverlapInSorted`) y cálculo de huecos complementarios (`computeComplementGaps`).<br>• `StructuralAuditor` + `topology`: detección de *leading slack*, *unreferenced gaps*, *region overlaps* y *trailing overlay* emitiendo `RuleId` canónico.<br>• `inconsistencies`: `DIMENSION_MISMATCH` y `SAMPLE_OVERFLOW` sobre `IrCodecConfigRow` / `IrSampleExtentRow`.<br>• `lowerRegions`: cálculo de `highest_root_end` y detección de `REGION_OVERFLOW`. |
| **`libs/isobmff`** | • `FourCC` y lectura de cabeceras 32-bit / 64-bit `largesize`.<br>• Parsing sintético válido (`ftyp`, `moov`, `mdat`).<br>• Casos de fallo: tamaño inválido (`< 8`), desbordamiento más allá de EOF, *trailing overlay/slack*, `InLineCheck` + `StructuralAuditor`.<br>• `Mp4Inspector`: tracks, codecs y detección de `track_id` duplicado o `0`.<br>• `lowerContainer`: conversión de cajas a `media_ir`.<br>• Fixture real opcional: `video.mp4` (si está presente). |
| **`libs/ebml`** | • Decodificación VINT (1, 2, 3, 4+ octetos y marcadores de tamaño desconocido).<br>• Parsing EBML sintético: `EBMLHeader`, `doc_type`, tamaños truncados o que exceden EOF.<br>• `MkvInspector`: `Tracks`, codecs y detección de `TrackNumber` duplicado o `0`.<br>• `lowerContainer`: conversión de elementos EBML a `media_ir`.<br>• Fixture real opcional: `Jellyfish_1080_10s_30MB.mkv` (si está presente). |
| **`libs/riff`** | • Helpers `FourCC` y alineación obligatoria a 2 bytes.<br>• Parsing sintético `RIFF`/`AVI ` con `LIST:hdrl`, `LIST:movi`, `JUNK`, `idx1` y detección de `chunk_size_overflow`.<br>• `lowerContainer`: conversión de chunks RIFF a `media_ir`.<br>• Fixture real opcional: `bird.avi` (si está presente). |
| **`libs/file_magic`** *(al final)* | • Detección MIME/magic de vídeo (ISOBMFF, EBML, RIFF, MPEG-TS, FLV, OGV) y medios no-vídeo (M4A, WAV, WebP, HEIC, AVIF).<br>• Desambiguación (`CAFEBABE` Mach-O vs Java), adjuntos/firmas (ZIP, RAR, 7z, PE, ELF, TTF/OTF, scripts) y validación de extensión declarada. |

### 5.2 Tests de Integración y E2E en `apps/vidsec/tests/`
Solo tests propios de la aplicación VidSec sobre Flowdata 2.0:

1. **Tests unitarios de Services atómicos (`tasks/`)**:
   - Fase 0 (límites de tamaño, `ftyp` bounds, `RIFF` size sanity, extensión, ejecutables en cabecera, cadenas sospechosas, entropía media, archivos en cola).
   - Forense / Lowering / CDR (ejecución tipada con `std.testing.allocator` y `BoundedStreamReader` en memoria, sin `TaskContext`).
2. **Validación declarativa (`pipeline_yaml_ast_test.zig`)**:
   - Parseo de `configs/pipeline.yaml`, interpolación de envvars, detección de ciclos en routers y validación contra `schemas.yaml`.
3. **Persistencia SQLite (`audit_db_sqlite_test.zig`)**:
   - Escritura/lectura end-to-end de hallazgos y registros de auditoría usando `schemas.yaml` y el driver `sqlite`.
4. **Carga de plugin y E2E del DAG (`loader_test.zig`, `pipeline_e2e_test.zig`)**:
   - Carga dinámica de `libanalyzer.so` (permisos y ABI).
   - Flujo completo con fixtures sintéticos: MP4/MKV/AVI válido → ruta limpia; políglota MP4+ZIP / ejecutable MZ / texto renombrado a `.mp4` → ruta de cuarentena/drop.

### 5.3 Tests Legados a Eliminar en el Corte
- `tests/formats/*` y `tests/lib/{ir_domain_test,forensics_domain_test,magic_test}.zig` → reemplazados por las suites dentro de `libs/*`.
- `tests/lib/abi_test.zig`, `tests/core/dataflow_test.zig`, `tests/core/artifact_test.zig` → ya cubiertos por la suite raíz de Flowdata (`tests/`).
- `tests/plugins/analyzer_test.zig` y `tests/core/pipeline_test.zig` → reescritos contra el nuevo catálogo de tasks atómicos sin `Verdict` ni wrappers *black-box*.


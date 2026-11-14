# Desacoplamiento de Contenedores Específicos mediante IR Universal

Cómo VidSec abstrae las particularidades binarias de ISOBMFF (MP4/MOV), EBML (MKV/WebM), RIFF (AVI) y MPEG-TS/PS hacia una **Representación Intermedia Universal (IR)**, permitiendo que toda la capa forense, de auditoría y CDR sea 100% agnóstica al formato.

---

## 1. Por qué un IR Universal

Sin un IR, cada regla forense (`detect_unreferenced_gaps`, `detect_region_overlaps`, `scan_entropy`, `check_sample_overflows`, `surgical_cdr`) tendría que implementarse 4 veces: una para cajas MP4, otra para elementos EBML, otra para chunks RIFF y otra para paquetes MPEG-TS.

El patrón de compiladores aplicado a seguridad multimedia divide el análisis en dos mitades limpias:

```text
  [Frontends específicos por formato]         [IR Universal]         [Backends agnósticos al formato]
   • ISOBMFF/MP4 walker + L2 tables     ──┐
   • EBML/MKV walker + L2 tracks/cues   ──┼──►  Regions + Tracks   ──► • Topología (gaps/overlaps/overlay)
   • RIFF/AVI walker + idx1/strf        ──┤     Samples + Configs       • Entropía en slack/padding
   • MPEG-TS walker (futuro)            ──┘     Attachments + Refs      • Overflow de muestras / dimensiones
                                                                        • CDR quirúrgico / cuarentena
```

---

## 2. El Modelo de Datos del IR Universal

El IR reduce cualquier archivo de vídeo a **6 primitivas universales**:

### 2.1 `Region` / `IrRegionRow` (Geometría estructural)
Representa cualquier átomo del contenedor (Box, Elemento EBML, Chunk RIFF, Paquete):
- **Identidad y árbol**: `region_id`, `parent_region_id`, `depth`.
- **Etiqueta normalizada**: `tag_name` (FourCC ASCII `"ftyp"`, `"moov"`, `"RIFF"`, o ID EBML normalizado `"0x1A45DFA3"`).
- **Rol semántico (`RegionRole`)**: enum universal independiente del formato:
  `unknown`, `header`, `container`, `metadata`, `media_data`, `index`, `padding`, `codec_config`, `attachment`.
- **Intervalo físico exacto**: `[header_offset, payload_offset, effective_end_offset)` y flag `is_truncated_or_overflow`.

### 2.2 `ContainerMetadataRow` (Resumen del archivo)
- `file_size`, `detected_format`, `true_magic`, `true_magic_name`, `highest_root_end` (el fin máximo de las regiones raíz válidas, usado directamente para detectar *trailing overlays* y truncar en CDR).

### 2.3 `Track` & `IrCodecConfigRow` (Pistas y configuración de codec)
- Unifica `tkhd`/`stsd` (MP4), `TrackEntry` (MKV) y `strh`/`strf` (AVI) en:
  - `track_id`, `kind` (`video`, `audio`, `subtitle`, `data`), `codec_tag`.
  - Dimensiones declaradas por el contenedor (`container_width`, `container_height`) vs dimensiones reales extraídas del bitstream (`bitstream_width`, `bitstream_height`) + flag `is_mismatch`.

### 2.4 `SampleExtent` / `IrSampleExtentRow` (Extensión física de cada frame/muestra)
- Normaliza `stco`/`co64` + `stsc` + `stsz` (MP4), `SimpleBlock`/`BlockGroup` (MKV) e `idx1` (AVI) en un único rango de bytes:
  - `extent_id`, `track_id`, `sample_index`, `source_tag`, `target_offset`, `byte_size`, `end_offset` (`target_offset + byte_size`).

### 2.5 `IrUnreferencedSlackRow` (Espacios sin referenciar)
- Intervalos `[file_offset, file_offset + byte_length)` no cubiertos por regiones válidas (`leading_slack`, `unreferenced_gap`, `trailing_overlay`, `mdat_slack`, `cluster_slack`).

### 2.6 `IrAttachmentRow` & `IrExternalRefRow` (Superficie de ataque auxiliar)
- `IrAttachmentRow`: adjuntos embebidos (ej. `AttachedFile` en MKV, ítems en `meta`) con `file_offset`, `byte_length`, `mime_type`, `file_name`.
- `IrExternalRefRow`: referencias externas (`dref` URL/URN en MP4, `NextFilename`/`PrevFilename` en MKV) con `track_id`, `uri`.

---

## 3. Tabla de Mapeo: Formatos Específicos → IR Universal

| Concepto Universal | ISOBMFF / MP4 | EBML / MKV / WebM | RIFF / AVI |
|---|---|---|---|
| **Átomo (`Region`)** | Box (4B BE size o 8B `largesize` + FourCC) | Elemento (VINT ID + VINT size) | Chunk (FourCC + 4B LE size + pad a 2B) |
| **`RegionRole.header`** | `ftyp` | `EBMLHeader` (`0x1A45DFA3`) | `RIFF` / `avih` |
| **`RegionRole.container`** | `moov`, `trak`, `mdia`, `minf`, `stbl` | `Segment`, `Tracks`, `Cluster` | `LIST:hdrl`, `LIST:strl`, `LIST:movi` |
| **`RegionRole.metadata`** | `mvhd`, `tkhd`, `mdhd`, `udta`, `meta` | `Info`, `TrackEntry`, `Tags` | `strh`, `strf`, `INFO` |
| **`RegionRole.media_data`** | `mdat` | `SimpleBlock`, `BlockGroup` | Chunks `00dc`, `01wb` dentro de `movi` |
| **`RegionRole.index`** | `stco`, `co64`, `stsc`, `stsz`, `sidx` | `Cues`, `CuePoint`, `SeekHead` | `idx1`, `indx` |
| **`RegionRole.padding`** | `free`, `skip` | `Void` (`0xEC`) | `JUNK` |
| **`RegionRole.attachment`** | `meta` / `iloc` / `iinf` | `Attachments` / `AttachedFile` (`0x61A7`) | — |
| **Muestras (`SampleExtent`)** | `stco`/`co64` + `stsc` + `stsz` | `Cluster` base time/offset + `SimpleBlock` | Entradas de `idx1` relativas a `movi` |
| **Codec Config** | `avcC`, `hvcC`, `esds` | `CodecPrivate` | `BITMAPINFOHEADER` (`strf`) |

---

## 4. Acoplamientos Residuales Detectados (A Resolver en el Refactor)

Al revisar la implementación actual en `apps/vidsec/src/analysis/` se detectaron cuatro puntos donde el desacoplamiento aún no es completo:

1. **Dualidad de tipos IR (`ir.Region` vs `ir.IrRegionRow`)**: existen definiciones paralelas en memoria y para filas ABI. En `libs/media_ir` debe existir una única fuente de verdad con conversión trivial/zero-copy entre vistas.
2. **Nombres de campos dependientes de formato en inputs de lowering**: algunos tasks antiguos pasan `box_id`, `element_id` o `chunk_id` en lugar de usar un contrato común (`RegionInput`) desde el parser de cada formato.
3. **`RIFF/AVI` ausente en `MediaLoweringStrategy`**: `lowering/media/factory.zig` solo resuelve `isobmff`/`mp4` y `ebml`/`mkv`; falta incorporar `riff`/`avi` (`strh` + `strf` + `idx1`) al mismo contrato.
4. **Cálculo de offsets por formato antes del lowering**: los walkers L1 deben entregar siempre `[header_offset, payload_offset, total_size]` ya normalizados (incluyendo `largesize` en MP4, tamaño de VINT en EBML y byte de padding par en RIFF) para que `lowerRegions` sea una función única y pura.


# Integración de Google Magika (`libmagika`) en Vidsec

## 1. Introducción y Contexto

**Google Magika** es una herramienta y modelo de *Deep Learning* de código abierto (Apache 2.0) desarrollado por Google en 2024 para la identificación precisa y rápida de tipos de contenido binario y textual. Ha sido adoptado por servicios a gran escala como **VirusTotal**, **Google Drive** y **Gmail** como sustituto y complemento moderno al clásico comando `file` (`libmagic`) de Unix.

Este documento analiza en profundidad el funcionamiento de Magika, evalúa las diferencias técnicas respecto a la biblioteca interna `src/lib/magic/` de Vidsec, detalla el valor que aportaría al motor y describe la arquitectura de integración recomendada para no comprometer la compilación autónoma ni las capacidades forenses del framework.

---

## 2. Cómo Funciona Magika por Dentro

A diferencia de los LLMs o modelos de visión por computador pesados, Magika fue expresamente diseñado para entornos de producción de altísimo rendimiento:

1. **Modelo Neuronal Ultraligero (~1 MB):**
   - Red neuronal compacta entrenada para clasificar más de 100 tipos de archivo (`ct_label`).
   - Exportada a formatos estándar de inferencia (**ONNX** y **TFLite**).
   - Tiempos de inferencia de **$\sim 5 \text{ ms}$ por archivo** en un único núcleo de CPU convencional (no requiere GPU ni aceleradores hardware).

2. **Muestreo Eficiente de Bloques (*Block Sampling*):**
   - Magika **no** lee ficheros completos en memoria (lo cual sería inviable para vídeos de varios gigabytes).
   - Muestrea ventanas fijas de 512 bytes en posiciones estratégicas:
     - Cabecera inicial (*Head Buffer*).
     - Centro del archivo (*Midpoint Buffer*).
     - Pie / Final del archivo (*Tail Buffer*).
   - Estas ventanas se convierten en un vector de características que alimenta la red neuronal.

3. **Inferencia 100% Local y Offline:**
   - No realiza llamadas a APIs externas, ni clústeres de Google, ni requiere conexión a Internet.
   - Núcleo de producción escrito en **Rust** (`libmagika`), con bindings oficiales para C, Python, Go y Node.js.

4. **Estructura del Output:**
   - `ct_label`: Identificador canónico (e.g., `mp4`, `mkv`, `avi`, `pebin`, `elf`, `zip`, `pdf`, `javascript`).
   - `score`: Nivel de certidumbre probabilística entre $0.0$ y $1.0$.
   - `group`: Categoría funcional (`media`, `executable`, `archive`, `code`, `document`).
   - `mime_type`: Tipo MIME estandarizado (e.g., `video/mp4`).
   - `description`: Nombre descriptivo legible.

---

## 3. Comparativa: `libmagika` vs. `vidsec_magic` (Zig Nativo)

| Dimensión | `libmagika` (Google / VirusTotal) | `vidsec_magic` (Nativo en Vidsec) |
| :--- | :--- | :--- |
| **Enfoque** | **Clasificador probabilístico global.** Determina qué parece ser el archivo en su conjunto. | **Escáner forense determinista por offsets.** Inspecciona bytes exactos y valida firmas estructurales. |
| **Detección de Políglotas** | ⚠️ **Limitado:** Asigna un único label predominante (o reduce el `score`). No puede aislar cargas embebidas. | ✅ **Excelente:** Escanea activamente el *Tail Buffer* (`scanTailArchives`) buscando cabeceras `ZIP EOCD`, `RAR` o `7z` ocultas tras el vídeo. |
| **Caza de Ejecutables Ocultos** | ⚠️ Solo si la muestra globalmente se comporta como ejecutable. | ✅ `scanHeadExecutables` detecta stubs `MZ`, `ELF`, Mach-O o scripts insertados antes o entre átomos. |
| **Ubicación de Offsets** | ❌ No reporta rangos (`file_offset`, `byte_length`). | ✅ Localiza con precisión milimétrica el offset de cada anomalía para alimentar `audit_findings`. |
| **Consumo de Memoria** | $\approx 20\text{--}50 \text{ MB}$ de RSS para instanciar el runtime ONNX y los tensores. | **0 bytes en heap** (evaluación estática en registros y stack, buffer bound de $\le 128 \text{ KB}$). |
| **Cadena de Compilación** | Requiere toolchain de **Rust** (`cargo`), runtime ONNX (`ort`/`tract`) y bindings C. | **100% Zig nativo**, compila en $\sim 200 \text{ ms}$ y cross-compila a cualquier SO sin dependencias externas. |

---

## 4. ¿Qué Aportaría `libmagika` a Vidsec?

La integración de Magika aportaría cuatro ventajas estratégicas de primer nivel:

### A. Detección de Disfraz / Spoofing de Cabeceras (*Anti-Evasion*)
Un atacante sofisticado puede forjar los primeros 16 bytes de un binario malicioso para que contengan `00 00 00 20 66 74 79 70 69 73 6F 6D` (cabecera MP4 `ftyp`), pero el resto del contenido es un ejecutable PE/ELF o un script ofuscado.
- Un parser básico de firmas podría caer en la trampa en Stage 0.
- **Magika detectará la discordancia:** la red neuronal evaluará el contexto y asignará `ct_label: pebin` (o un `score` inferior a $0.50$), levantando inmediatamente una alerta crítica de engaño de cabecera.

### B. Validación Cruzada Dual (*Dual-Engine Verification*)
La correlación entre ambos motores permite definir reglas de confianza extremadamente robustas en `pipeline.yaml`:
$$\text{Confianza Alta} \iff (\text{vidsec\_magic} = \text{ISOBMFF}) \land (\text{magika.ct\_label} = \text{"mp4"}) \land (\text{magika.score} \ge 0.95)$$
Si ambos discrepan:
- Se fuerza el enrutado hacia pipelines de cuarentena profunda o análisis forense exhaustivo (`quarantine_sandbox`).

### C. Clasificación Rica de Adjuntos y Slack Data (`ir_attachments`)
Contenedores como MKV (`EBML`) permiten adjuntar archivos arbitrarios (fuentes TTF, imágenes, subtítulos o ficheros binarios).
- Actualmente `vidsec_magic` tiene firmas hardcodeadas para ciertos formatos.
- Magika puede identificar instantáneamente cualquiera de los más de 100 formatos soportados para cualquier payload tallado (*carved payload*) sin necesidad de inflar el código en Zig con firmas binarias artesanales.

### D. Alineación con Estándares de la Industria (VirusTotal)
Generar informes de auditoría (`v_findings_report`, PDF, LaTeX) que incluyan el campo canónico de **Magika** tal cual lo expone VirusTotal aporta credibilidad técnica inmediata ante equipos SOC (*Security Operations Center*) y analistas forenses.

---

## 5. Arquitectura de Integración Propuesta

Para **no romper la pureza de compilación de Zig** ni perder las capacidades forenses por offsets, la integración se estructura en dos fases:

```
[ Archivo de Vídeo ]
         │
         ├───► [ Stage 0: vidsec_magic (Zig nativo) ] ──────────► file_triage (Offsets, Polyglots, Fast Reject)
         │
         └───► [ Plugin Opcional: vidsec_magika (C-ABI) ] ──────► magika_triage (ct_label, score, group)
                                                                        │
                                                                        ▼
                                                   [ Router: Correlación Dual en SQLite ]
```

### Fase 1: Alineación de Esquema y Contratos ABI
1. Actualizar el esquema de `file_triage` para adoptar la nomenclatura estándar:
   - `magika_label: text` (ej: `'mp4'`, `'mkv'`, `'pebin'`).
   - `magika_score: real` (confianza de $0.0$ a $1.0$).
   - `magika_group: text` (ej: `'media'`, `'executable'`).
2. Si Magika no está activo, `vidsec_magic` puebla estos campos con sus equivalentes canónicos y `score = 1.0` (heurístico).

### Fase 2: Plugin C-ABI Dinámico (`vidsec_magika.so`)
1. Implementar un plugin C-ABI desacoplado del binario principal.
2. El plugin puede compilarse opcionalmente mediante la librería C de `libmagika` o ejecutar mediante subproceso el binario CLI `magika <file> --json`.
3. El Host de Vidsec carga dinámicamente el plugin si la directiva en `pipeline.yaml` lo solicita, preservando el binario `vidsec` 100% autosuficiente para despliegues ligeros.

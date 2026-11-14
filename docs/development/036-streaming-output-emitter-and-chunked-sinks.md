# ARCH-036: `StreamEmitter` y Sinks Chunked para Salidas en Streaming

- **Estado:** Propuesto / Pendiente de implementación en `flowdata`
- **Contexto:** `apps/vidsec` (sanitización de vídeos de gran tamaño) y `flowdata` SDK (`defineTaskService`)

---

## 1. Problema Actual

Actualmente, los `Service` definidos con `defineTaskService` en `flowdata` leen entradas grandes de forma segura por ventanas mediante `BoundedStreamReader` (`readAt`) o `WindowReader`, pero en la salida (`Outputs`) devuelven un struct completo al finalizar `execute()`.

Esto obliga a que una task que transforma un stream (como `apply_truncate` o `apply_zero_out` en VidSec) tenga que:
1. Materializar todo el archivo resultante en un slice `[]const u8` en RAM (`alloc.alloc`), lo que provoca riesgo de OOM en vídeos de varios GB; o
2. Depender de primitivas acopladas al host (`artifactTruncate`, `artifactZeroRange`), rompiendo la separación entre el motor genérico (`flowdata`) y la lógica de dominio de cada aplicación.

---

## 2. Propuesta: `StreamEmitter` (Modo Dual RAM / Ventanas)

Introducir en el SDK de `flowdata` un **`StreamEmitter`** (o `ChunkedOutput` inyectado vía DI) respaldado por los `StorageRepository` / `file_store` / `memory` sinks sin lógica específica de ningún dominio:

- **Modo en RAM (archivos pequeños):** cuando `size <= max_in_memory_bytes`, la task o el runtime puede mantener un único buffer contiguo en `pipeline_memory` para máxima velocidad y cero I/O intermedio.
- **Modo por ventanas / chunks (archivos grandes):** la task lee del `BoundedStreamReader` en bloques acotados (p. ej. 64 KiB – 1 MiB), aplica la transformación al vuelo y llama a `emitter.writeChunk(chunk)` + `emitter.finish()`.
- El diseñador del `pipeline.yaml` (no la task) elige qué `sink` recibe ese stream (`file_store`, `ssh_store`, `memory`, etc.) y el umbral `max_in_memory_bytes` o `chunk_size`.

---

## 3. Ventajas Arquitectónicas

1. **Memoria constante $O(1)$:** permite sanitizar o transformar vídeos de decenas de GB usando únicamente un buffer fijo de ventana en stack/heap.
2. **Desacoplamiento total del engine:** permite eliminar primitivas específicas heredadas de `vidsec` en `HostApiVTable_ABI` (`artifact_truncate`, `artifact_zero_range`, `artifact_write_at`, `carve_to_quarantine`).
3. **Elección declarativa desde el pipeline:** un mismo `Service` puede operar en RAM para lotes pequeños o en streaming para ficheros grandes sin duplicar lógica de negocio.
4. **Reutilizable en otras apps:** útil para cualquier pipeline que genere artefactos binarios grandes (empaquetado CBZ/ZIP, transcodificación, exportación CSV/JSON masiva).

---

## 4. Mitigación Temporal en VidSec

Mientras `StreamEmitter` no esté disponible en `flowdata`, `apply_truncate` y `apply_zero_out` incorporan una guarda configurable `max_in_memory_bytes` (64 MiB por defecto) que rechaza con `error.StreamExceedsInMemoryLimit` cualquier stream que supere el presupuesto en RAM.


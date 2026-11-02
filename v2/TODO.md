# Hoja de Ruta de Evolución y Casos Avanzados (`vidsec v2 TODO`)

Este documento recoge funcionalidades deseables y casos borde de diseño que **no forman parte del alcance mínimo inicial del Framework v2**, pero cuya arquitectura ya se ha dejado preparada para incorporarlos sin romper la C-ABI (`VIDSEC_ABI_VERSION = 2`).

---

## 1. Ejecución Simultánea de Tareas (`Fan-Out / Fan-In`) y Convergencia de Outputs

### Caso de Uso
Ejecutar varias tareas independientes en paralelo (por ejemplo, lanzar simultáneamente `entropy_scan` sobre regiones de *padding* y `signature_scan` sobre adjuntos, o ejecutar varios extractores de metadatos a la vez) y **juntar sus outputs como entrada de una tarea posterior** (o de un `router`).

### Diseño Previsto en `pipeline.yaml`
```yaml
      # Bloque fan-out: todas las tareas del bloque `parallel` ven el estado SQLite
      # previo al bloque y se ejecutan concurrentemente en un ThreadPool del Host.
      - parallel: heuristic_scanners
        tasks:
          - task: scan_padding_entropy
            use: byte_scanners/entropy_scan
            input:
              windows:
                from: file
                table: ir_regions
                filter: "role = 'padding'"
                map: { id: region_id, offset: payload_offset, length: "effective_end_offset - payload_offset", tag: tag_name }
            output:
              into: audit_findings
              map: { rule_id: "'R07_ENTROPY'", file_offset: offset, region_tag: tag, severity: severity, measured_value: entropy }

          - task: scan_padding_signatures
            use: byte_scanners/sig_scan
            input:
              windows:
                from: file
                table: ir_regions
                filter: "role = 'padding'"
                map: { id: region_id, offset: payload_offset, length: "effective_end_offset - payload_offset", tag: tag_name }
            output:
              into: audit_findings
              map: { rule_id: "'R07_SIG'", file_offset: offset, region_tag: tag, severity: severity, message: sig_name }

      # Fan-in natural: el siguiente paso (task o router) se ejecuta cuando TODAS las ramas
      # del bloque `parallel` han terminado, leyendo los outputs combinados en `audit_findings`:
      - task: correlate_heuristics
        use: correlator
        input:
          findings:
            table: audit_findings
            filter: "rule_id IN ('R07_ENTROPY', 'R07_SIG')"
            map: { rule: rule_id, offset: file_offset, severity: severity }
```

### Cómo lo soportará el Host sin tocar los Plugins
Gracias a que en `v2` los plugins **no tienen puntero `*sqlite3`** y solo usan `HostApiVTable_ABI`:
1. **Lectura concurrente (`next_window` / `next_row`):** En modo `WAL`, cada hilo del bloque `parallel:` abre su propia conexión SQLite de **solo lectura** (`SQLITE_OPEN_READONLY`) y su propio `SafeCursor` (`pread` posicional thread-safe sobre el descriptor del archivo).
2. **Escritura convergente (`emit_row`):** Las llamadas a `emit_row` desde los hilos de trabajo se encolan en un canal MPSC (*Multi-Producer, Single-Consumer*) hacia el hilo coordinador del Host, que ejecuta los `INSERT` sobre la conexión maestra dentro de la transacción del bloque paralelo.

---

## 2. Depurador Step-by-Step para GUI / CLI y Analizador Post-Ejecución sobre Traza JSON

### Caso de Uso
Aprovechar el fichero de traza estructurado (`../zig-out/out/trace.jsonl`) y el controlador de ejecución del motor (`DebugController`) para permitir tanto la **inspección en vivo desde una GUI o CLI** como el **análisis post-mortem** de ejecuciones pasadas para cazar bugs sin contaminar el `pipeline.yaml` ni sobrecargar SQLite.

### Capacidades Previstas
- **Control en Vivo (Runtime Hooks para GUI / CLI `--step` o `--break-at <step_name>`):**
  - Pausa la ejecución entre pasos desde el controlador externo (sin tocar el YAML).
  - Permite avanzar paso a paso (`step_next`), continuar hasta un paso específico (`continue_until`), consultar el estado actual de las tablas SQLite o abortar la corrida.
- **Análisis Post-Ejecución (*Time-Travel / Post-Mortem* sobre `../zig-out/out/trace.jsonl`):**
  - El fichero JSON registra cada transición (`step_start`, `task_log`, `step_end` con duración, filas leídas/emitidas y `router_decision`).
  - Opcionalmente, en modo diagnóstico, puede volcar snapshots incrementales de las filas emitidas en cada paso dentro del JSON para reconstruir exactamente qué vio y qué produjo cada tarea después de que el pipeline haya terminado.

---

## 3. Gestión de Recursos, Límites de Memoria y Almacenamiento Remoto vía `.env`

- **Cuota de Memoria por Tarea (`max_task_memory_mb`):** Exponer un asignador o `CountingAllocator` en el Host o límites `setrlimit` / `cgroup` para abortar tareas que superen el umbral configurado en `.env`.
- **Streams y Cuarentena Remota Transparente (SSH / SFTP / S3):** Dado que los plugins leen bytes exclusivamente mediante `host.stream_read_at` y extraen payloads mediante `host.carve_to_quarantine`, el Host podrá montar orígenes o destinos remotos configurados con credenciales en `.env` sin modificar ni recompilar ningún plugin `.so`.

---

## 4. Integración de Google Magika (`libmagika`) para Clasificación Dual y Alineación con VirusTotal

### Caso de Uso
Complementar el escáner forense determinista de firmas ([`src/lib/magic/`](file:///home/ubuntu/.gemini/antigravity/scratch/vidsec/src/lib/magic/)) con el modelo de *Deep Learning* **Google Magika** empleado por **VirusTotal**, permitiendo detección anticipada de evasión (*spoofing* de cabeceras, ejecutables camuflados como MP4) y enriquecimiento de metadatos con scores probabilísticos de confianza.

Para el análisis técnico detallado, comparativa de rendimiento y trade-offs de compilación, consultar el documento de diseño específico:
👉 [`v2/development/magika.md`](file:///home/ubuntu/.gemini/antigravity/scratch/vidsec/v2/development/magika.md)

### Puntos Clave de la Integración
1. **Validación Cruzada Dual (*Dual-Engine Verification*):**
   - Comparación en SQLite entre la estructura física analizada por `vidsec_magic` y la clasificación neuronal de Magika (`magika_label` + `magika_score`).
   - Detección inmediata de anomalías cuando los primeros bytes parecen un contenedor multimedia válido pero la red neuronal clasifica el cuerpo como `pebin`, `elf` o `script`.
2. **Preservación de la Autonomía de Compilación:**
   - Mantener el motor base `vidsec` 100% puro en Zig (cero dependencias externas de Rust/Python/ONNX).
   - Encapsular `libmagika` como un **plugin C-ABI opcional** (`vidsec_magika.so`), activable dinámicamente mediante `pipeline.yaml` cuando las librerías nativas o el CLI estén presentes en el entorno.
3. **Estandarización de Esquema e Informes:**
   - Alinear los campos de `file_triage` con las convenciones de Magika/VirusTotal (`ct_label`, `score`, `group`, `mime_type`).
   - Exponer la etiqueta y confianza de Magika en las vistas ejecutivas (`v_executive_summary`) e informes de auditoría (PDF/LaTeX).

# Directivas Globales para Agentes de Codificación (`AGENTS.md`)

Este archivo define las reglas transversales e invariantes de ingeniería para cualquier agente de IA (Gemini, Claude, etc.) que implemente los hitos `M0` a `M5` del proyecto **`vidsec`** (ubicados en `specs/M0_*.md` .. `specs/M5_*.md`).

---

## 1. Entorno, Compilador y Dependencia Base (`SQLite3`)
- **Lenguaje y Versión:** Zig `0.13.0` / `0.14.0` (Evitar APIs deprecadas de `0.11` o anteriores en `std.Build` y `std.ArrayListUnmanaged`).
- **Motor de Estado e IR Relacional:** Todo el estado compartido entre etapas (`ContainerIR`, hallazgos `audit_findings`, trazas y cadena de archivos limpios `working_artifacts`) reside en una base de datos **SQLite3** (`*sqlite3`).
- **Regla Estricta de Enlace Único de `libsqlite3` (`build.zig`):**
  - **Prohibido enlazar SQLite estáticamente por separado en el host y en los plugins `.so`** (tener múltiples copias estáticas de `sqlite3.c` en el mismo proceso corrompe los mutexes y el estado global del asignador de páginas al compartir un puntero `*sqlite3` vía `dlopen`).
  - Tanto el ejecutable principal `vidsec` (`M0`) como todas las librerías dinámicas `addSharedLibrary` (`M1`–`M5`) **deben enlazar dinámicamente contra la misma librería compartida del sistema** (`step.linkSystemLibrary("sqlite3")` + `step.linkLibC()`), garantizando una única instancia de `libsqlite3.so` en el espacio de direcciones del proceso.
- **Compilación por defecto:** Modo seguro (`ReleaseSafe` o `Debug` en tests) para garantizar comprobaciones de límites en tiempo de ejecución.

---

## 2. Reglas Estrictas de Seguridad, SQLite y Versionado de Plugins

1. **Respeto Literal de Contratos Públicos, Esquemas SQL y Diagramas UML:**
   - Todo `struct`, `extern struct`, `enum`, `union(enum)`, `error` set, tabla SQL y firma `pub fn` definida en las secciones 2 y 3 de cada hito debe respetarse carácter por carácter.
   - Los plugins de `M1` a `M5` se comunican con el motor (`M0`) exclusivamente a través de `src/core/plugin_abi.zig` (`VidsecPluginABI` y `PipelineContext_ABI` con `callconv(.C)`), que les entrega el puntero `*sqlite3` activo.

2. **Seguridad y Rendimiento en SQLite (`Prepared Statements` + Transacciones + Índices Diferidos):**
   - **Prohibido concatenar strings para construir SQL con datos del archivo:** Todo `INSERT` o `SELECT` que incluya nombres de cajas, rutas, URIs o metadatos extraídos de un contenedor debe usar sentencias preparadas (`sqlite3_prepare_v2` + `sqlite3_bind_*`).
   - **Inserción por lotes en transacción e índices al final:** Los plugins que insertan miles de registros (`M1` al volcar `ir_regions` o `M3` al volcar `ir_sample_extents`) deben envolver el volcado en una transacción explícita (`BEGIN IMMEDIATE;` ... `COMMIT;`), reutilizando un único `sqlite3_stmt` con `sqlite3_reset()`, y **ejecutar las sentencias `CREATE INDEX IF NOT EXISTS` después del bucle de inserción** (justo antes de `COMMIT`) para evitar rebalancear árboles B-Tree en cada fila.
   - **Concurrencia futura:** La base de datos se configura con `PRAGMA busy_timeout = 5000;` (y `PRAGMA journal_mode = WAL;` cuando opera en disco) para permitir que múltiples steps de auditoría de solo lectura (`M2`/`M3`) puedan paralelizarse sin bloqueos.

3. **Matriz de Versionado y Dependencias en 3 Niveles (ABI vs SemVer + Hard Plugin Dependencies vs Bancos DDL SQLite):**
   - Para permitir que un plugin estable (ej. `M1 v1.0.0`) conviva con plugins que evolucionan rápido (ej. `M2 v5.2.0`), y que existan tanto plugins sobre `ContainerIR` como plugins directos sobre binario crudo, todo plugin declara en `VidsecPluginABI`:
     1. `abi_version: u32`: Versión binaria de `PipelineContext_ABI` (debe coincidir exactamente con el motor `M0`, `VIDSEC_ABI_VERSION = 1`).
     2. `plugin_version: SemVer_ABI` y `requires_plugins_ptr: ?[*]const PluginDependency_ABI` (`requires_plugins_len: usize`): Versión propia del plugin y lista de **Hard Dependencies** (IDs de otros plugins que obligatoriamente deben ejecutarse antes en `pipeline.yaml`, con su `min_version`). Un plugin especializado que opere directamente sobre bytes crudos con `cursor_read_at` puede declarar `requires_plugins_len = 0`.
     3. `requires_schemas_ptr: ?[*]const SchemaContract_ABI` (`requires_schemas_len: usize`): **Bancos de esquema SQLite** (`domain`, `version`, `writable`) que el plugin necesita tener mapeados. En el arranque (*pre-flight*), `PluginLoader` carga bajo demanda el archivo DDL físico `configs/schemas/<domain>_v<version>.sql` para cada banco solicitado y configura el firewall `sqlite3_set_authorizer` permitiendo escritura solo en los bancos con `writable = true`.

4. **Aritmética Segura Obligatoria sobre Datos No Confiables:**
   - Todo archivo multimedia de entrada se considera **hostil por defecto** (*Zero-Trust*).
   - Cualquier suma, resta o multiplicación que involucre offsets, longitudes o contadores leídos de un contenedor binario debe usar `std.math.add(u64, a, b)`, `std.math.sub(u64, a, b)` o `std.math.mul(u64, a, b)`.
   - **Prohibido** usar operadores `+`, `-` o `*` directos sobre tamaños declarados en cabeceras binarias.

5. **Prohibido `unreachable` o `@panic` en Rutas de Datos o Plugins:**
   - Un archivo truncado, corrupto o malicioso, un YAML malformado, un error de SQLite o un plugin externo defectuoso **jamás debe abortar el proceso principal**.
   - Toda anomalía debe devolverse como un error tipado o registrarse en la tabla `audit_findings` (`AuditFindingRow`) / notificarse vía `emit_event` / `StepVerdict_ABI.abort_threat`.

6. **Aislamiento de Heap y Cero Fugas de Memoria:**
   - Todos los tests unitarios y de integración deben ejecutarse usando `std.testing.allocator` y cerrar todas las sentencias `sqlite3_finalize` y conexiones `sqlite3_close_v2`.

---

## 3. Flujo de Trabajo por Hito (`specs/M0` $\rightarrow$ `specs/M5`)

Al implementar un hito `MX`:
1. Leer este archivo (`AGENTS.md`) y únicamente la especificación `specs/MX_*.md` correspondiente.
2. Implementar los módulos del `classDiagram` (`Sección 2`), las firmas y esquemas SQL (`Sección 3`) y el modelo de memoria (`Sección 4`).
3. Ejecutar `zig build` y `zig build test`.
4. **No dar por completado el hito** hasta que el 100% de los vectores de prueba (`Sección 7`) pasen con 0 errores, 0 warnings y 0 fugas de memoria o cursores SQLite abiertos.

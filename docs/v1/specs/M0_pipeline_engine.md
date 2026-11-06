# Especificación de Hito M0: Chasis Declarativo YAML, Bus SQLite Agnóstico y Cargador de Plugins con Control de Versiones (`C-ABI`)

> **Directivas Globales:** Ver [`../AGENTS.md`](../AGENTS.md) antes de implementar este hito.

---

## 1. Alcance Funcional y Contratos de Compatibilidad

### Objetivo del Hito
Construir el **chasis universal, bus de estado en SQLite y motor de ejecución declarativo** de `vidsec`, **100% agnóstico del dominio** (no conoce conceptos de contenedores de vídeo, ni de hallazgos de auditoría, ni de transcodificación). Al finalizar `M0`, el binario `vidsec` es capaz de:
1. Inicializar una base de datos **SQLite3** (`:memory:` por defecto o archivo en disco con `--save-db <ruta>`) aplicando inicialmente el **Banco 0 de gobierno del motor (`configs/schemas/m0_engine_v1.sql`)**: `run_metadata`, `schema_registry`, `pipeline_gates` y `pipeline_trace`.
2. Leer **`configs/pipeline.yaml`**, que declara:
   - El bloque `database:` (configuración de SQLite y directorio `schemas_dir: "configs/schemas"`).
   - El array `plugins:` (lista explícita de `.so`/`.dll` a cargar, su restricción de versión SemVer opcional y su archivo `config:` opcional).
   - El árbol `pipeline:` (grupos jerárquicos `StageGroup`, pasos `LeafStep`, políticas de fallo y compuertas con nombre `open_gate_on_success` / `require_gate`).
3. Validar en el arranque (**Pre-Flight Compatibility Check & Schema Bank Provisioning**) la **Matriz de Versiones y Dependencias en 3 Niveles** (ver [`ADR-006`](../ADR/ADR-006_on_demand_ddl_banks_and_hard_plugin_dependencies.md)):
   - **Nivel 1 (`abi_version`):** Compatibilidad binaria del `.so` con `PipelineContext_ABI` (`M0`).
   - **Nivel 2 (`plugin_version` SemVer + Hard Plugin Dependencies `requires_plugins`):** Cumplimiento del rango `min_version` / `max_version` declarado en `pipeline.yaml` y verificación de que todo plugin requerido en `requires_plugins_ptr` (`PluginDependency_ABI`) aparezca antes en el orden de ejecución del pipeline (permitiendo también plugins autónomos con `requires_plugins_len = 0` que operen directamente sobre bytes crudos).
   - **Nivel 3 (Bancos DDL SQLite bajo demanda `requires_schemas`):** Por cada banco `SchemaContract_ABI` (`domain`, `version`, `writable`) solicitado por un plugin cargado, `M0` carga y ejecuta automáticamente el archivo DDL físico `configs/schemas/<domain>_v<version>.sql` (si aún no está registrado en `schema_registry`), garantizando que las tablas existan siempre aunque se omitan plugins opcionales.
4. Ejecutar el árbol del pipeline configurando en cada paso el firewall `sqlite3_set_authorizer` según los permisos `writable` de los bancos declarados por el plugin y entregando el puntero `*sqlite3`, el lector `SafeCursor` y el canal de eventos.

---

## 2. Arquitectura UML del Hito (`classDiagram`)

```mermaid
classDiagram
    direction TB

    class SafeCursor["src/core/io_cursor.zig :: SafeCursor"] {
        +source: SourceBacking
        +file_size: u64
        +pos: u64
        +limit_stack: [32]u64
        +depth: u8
        +initFile(file: std.fs.File) CursorError!SafeCursor
        +initSlice(buf: []const u8) SafeCursor
        +pushLimit(declared_size: u64) CursorError!void
        +popLimit() CursorError!void
        +seekTo(offset: u64) CursorError!void
        +readAt(offset: u64, dest: []u8) CursorError!void
        +readU32Be() CursorError!u32
        +readU64Be() CursorError!u64
        +readU32Le() CursorError!u32
    }

    class SemVer_ABI["src/core/plugin_abi.zig :: SemVer_ABI"] {
        <<extern struct>>
        +major: u16
        +minor: u16
        +patch: u16
    }

    class SchemaContract_ABI["src/core/plugin_abi.zig :: SchemaContract_ABI"] {
        <<extern struct>>
        +domain: [*:0]const u8
        +version: u32
        +writable: bool
    }

    class PluginDependency_ABI["src/core/plugin_abi.zig :: PluginDependency_ABI"] {
        <<extern struct>>
        +plugin_id: [*:0]const u8
        +min_version: SemVer_ABI
    }

    class PipelineContext_ABI["src/core/plugin_abi.zig :: PipelineContext_ABI"] {
        <<extern struct (C-ABI)>>
        +abi_version: u32
        +opaque_host_ctx: *anyopaque
        +sqlite_db: *sqlite3
        +input_path_ptr: [*:0]const u8
        +plugin_config_path_ptr: ?[*:0]const u8
        +file_size: u64
        +cursor_read_at: *const fn(ctx, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.C) u32
        +emit_event: *const fn(ctx, level: EventLevel_ABI, code: [*:0]const u8, msg: [*:0]const u8) callconv(.C) void
        +set_gate_state: *const fn(ctx, gate_name: [*:0]const u8, is_open: bool) callconv(.C) u32
        +get_param: *const fn(ctx, key: [*:0]const u8) callconv(.C) ?[*:0]const u8
        +report_progress: *const fn(ctx, pct: u8) callconv(.C) void
    }

    class VidsecPluginABI["src/core/plugin_abi.zig :: VidsecPluginABI"] {
        <<extern struct (C-ABI)>>
        +abi_version: u32
        +plugin_id: [*:0]const u8
        +plugin_version: SemVer_ABI
        +requires_schemas_ptr: ?[*]const SchemaContract_ABI
        +requires_schemas_len: usize
        +requires_plugins_ptr: ?[*]const PluginDependency_ABI
        +requires_plugins_len: usize
        +execute_step: *const fn(ctx: *PipelineContext_ABI) callconv(.C) StepVerdict_ABI
    }

    class StateDatabase["src/core/database.zig :: StateDatabase"] {
        +db: *sqlite3
        +initMemoryOrFile(db_path: ?[:0]const u8, schema_m0_sql: [:0]const u8) DbError!StateDatabase
        +execSql(sql: [:0]const u8) DbError!void
        +ensureSchemaBankLoaded(schemas_dir: []const u8, domain: []const u8, version: u32) DbError!void
        +setStepAuthorizer(schemas: []const SchemaContract_ABI) void
        +clearAuthorizer() void
        +setGateState(gate_name: []const u8, is_open: bool) DbError!void
        +isGateOpen(gate_name: []const u8) DbError!bool
        +recordStepTrace(node_name: []const u8, plugin_id: []const u8, elapsed_ns: u64, verdict: StepVerdict_ABI) DbError!void
        +deinit() void
    }

    class PluginLoader["src/core/plugin_loader.zig :: PluginLoader"] {
        +gpa: std.mem.Allocator
        +loaded_plugins: std.StringHashMapUnmanaged~LoadedPlugin~
        +loadDeclaredPlugin(spec: PluginDeclaration) PluginError!void
        +validatePipelineCompatibility(execution_order: []const []const u8) PluginError!void
        +reloadAll() PluginError!void
        +deinit() void
    }

    class YamlPipelineParser["src/core/yaml_config.zig :: YamlPipelineParser"] {
        +parseConfig(arena: Allocator, yaml_text: []const u8) YamlError!ParsedPipelineConfig
    }

    class PipelineEngine["src/core/engine.zig :: PipelineEngine"] {
        +executeRoot(root: PipelineNode, ctx: *PipelineContext) EngineError!StepVerdict
    }

    PipelineEngine --> StateDatabase : manages gates & trace
    PipelineEngine --> PluginLoader : invokes resolved steps
    PluginLoader ..> VidsecPluginABI : dlopen & checks 3-level versioning
    VidsecPluginABI *-- SchemaContract_ABI
    YamlPipelineParser --> PluginLoader : registers plugins[] array
    StateDatabase ..> PipelineContext_ABI : provides *sqlite3 handle
```

---

## 3. Contratos de Tipos en Zig y Esquema SQLite (`DDL / Queries`)

### 3.A. Tipos, Errores y Firmas Públicas en Zig (`src/core/plugin_abi.zig`)
> [!IMPORTANT]
> `M0` es completamente agnóstico de qué tablas usen los hitos `M1`–`M5`. Cada plugin declara qué bancos DDL SQLite necesita mapear (`requires_schemas_ptr`, ej. `"ir_core"` v1, `"audit_findings"` v1) y qué *Hard Dependencies* sobre otros plugins exige (`requires_plugins_ptr`).

```zig
const std = @import("std");

pub const VIDSEC_ABI_VERSION: u32 = 1;
pub const VIDSEC_PLUGIN_SYMBOL_NAME = "vidsec_plugin_descriptor";

pub const sqlite3 = opaque {};

pub const SemVer_ABI = extern struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub fn order(a: SemVer_ABI, b: SemVer_ABI) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

/// Define un banco de esquema SQLite (configs/schemas/<domain>_v<version>.sql) requerido por el plugin.
pub const SchemaContract_ABI = extern struct {
    domain: [*:0]const u8,      // Ej: "ir_core", "ir_deep", "audit_findings", "working_artifacts"
    version: u32,               // Ej: 1 -> carga configs/schemas/<domain>_v1.sql
    writable: bool = false,     // false = solo SELECT; true = permite INSERT/UPDATE en este banco
};

/// Define una dependencia dura (Hard Dependency) sobre un plugin anterior en el pipeline.
pub const PluginDependency_ABI = extern struct {
    plugin_id: [*:0]const u8,   // Ej: "vidsec.m1.ir_builder" o "vidsec.m3.deep_extractor"
    min_version: SemVer_ABI,
};

pub const EventLevel_ABI = enum(u32) {
    info = 0,
    warning = 1,
    critical = 2,
};

pub const StepVerdict_ABI = enum(u32) {
    proceed = 0,
    skip_group = 1,
    abort_threat = 2,
    step_error = 3,
};

pub const PipelineContext_ABI = extern struct {
    abi_version: u32 = VIDSEC_ABI_VERSION,
    opaque_host_ctx: *anyopaque,

    /// Conexión activa a la base de datos SQLite3 compartida entre los plugins del pipeline.
    sqlite_db: *sqlite3,

    /// Ruta del archivo de entrada proporcionado por CLI.
    input_path_ptr: [*:0]const u8,

    /// Ruta opcional al archivo YAML de configuración específico de este plugin (`config:` en pipeline.yaml).
    plugin_config_path_ptr: ?[*:0]const u8,

    file_size: u64,

    /// Lee `len` bytes desde `offset` usando el SafeCursor del host. Devuelve 0 en éxito, != 0 en error.
    cursor_read_at: *const fn (host_ctx: *anyopaque, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.C) u32,

    /// Emite un evento de telemetría/alerta en tiempo real al PipelineObserver (CLI / JSON Stream).
    emit_event: *const fn (
        host_ctx: *anyopaque,
        level: EventLevel_ABI,
        code: [*:0]const u8,
        message: [*:0]const u8,
    ) callconv(.C) void,

    /// Abre o cierra una compuerta con nombre en la tabla `pipeline_gates` de M0 (ej. "sanitized_gate" = true).
    set_gate_state: *const fn (host_ctx: *anyopaque, gate_name: [*:0]const u8, is_open: bool) callconv(.C) u32,

    /// Obtiene un parámetro inline configurado en `params:` del step actual dentro de `pipeline.yaml`.
    get_param: *const fn (host_ctx: *anyopaque, key: [*:0]const u8) callconv(.C) ?[*:0]const u8,

    /// Notifica porcentaje de progreso (0..100) al PipelineObserver.
    report_progress: *const fn (host_ctx: *anyopaque, pct: u8) callconv(.C) void,
};

pub const VidsecPluginABI = extern struct {
    /// Nivel 1: Versión binaria del contrato C-ABI con el motor M0 (debe ser 1).
    abi_version: u32 = VIDSEC_ABI_VERSION,
    plugin_id: [*:0]const u8,

    /// Nivel 2: Versión SemVer propia del binario `.so` (ej. M1 = 1.0.0, M2 = 5.2.0).
    plugin_version: SemVer_ABI,

    /// Nivel 3A: Bancos de esquema SQLite (configs/schemas/<domain>_v<version>.sql) que M0 aprovisiona al cargar el plugin:
    requires_schemas_ptr: ?[*]const SchemaContract_ABI = null,
    requires_schemas_len: usize = 0,

    /// Nivel 3B: Hard Dependencies (plugins que obligatoriamente deben ejecutarse antes en pipeline.yaml):
    /// Si es null/0, el plugin es autónomo (ej. M1 o un analizador directo sobre bytes crudos de MP4).
    requires_plugins_ptr: ?[*]const PluginDependency_ABI = null,
    requires_plugins_len: usize = 0,

    execute_step: *const fn (ctx: *PipelineContext_ABI) callconv(.C) StepVerdict_ABI,
};
```

---

### 3.B. Contrato de Esquema SQLite Exclusivo de `M0` (`configs/schema_m0.sql`)

`M0` solo crea las 4 tablas de gobierno del propio motor de ejecución. Cada hito posterior (`M1`–`M5`) creará sus propias tablas de dominio y las registrará en `schema_registry`:

```sql
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

-- 1. Metadatos de la sesión de ejecución del motor
CREATE TABLE IF NOT EXISTS run_metadata (
    run_id INTEGER PRIMARY KEY CHECK (run_id = 1),
    input_path TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    started_at_ns INTEGER NOT NULL
);

-- 2. Registro de dominios de esquema SQLite activos (poblado a medida que se ejecutan plugins productores)
CREATE TABLE IF NOT EXISTS schema_registry (
    schema_domain TEXT PRIMARY KEY,     -- Ej. "ir_core" (M1), "audit_findings" (M2), "ir_deep" (M3), "working_artifacts" (M4)
    schema_version INTEGER NOT NULL,
    producer_plugin_id TEXT NOT NULL,
    producer_plugin_version TEXT NOT NULL
);

-- 3. Estado de compuertas lógicas entre etapas (ej. "sanitized_gate")
CREATE TABLE IF NOT EXISTS pipeline_gates (
    gate_name TEXT PRIMARY KEY,
    is_open INTEGER NOT NULL DEFAULT 0, -- 0 = cerrada (bloquea grupos con require_gate), 1 = abierta
    updated_by_step TEXT NOT NULL
);

-- 4. Traza de telemetría y tiempos de cada paso ejecutado
CREATE TABLE IF NOT EXISTS pipeline_trace (
    trace_id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_name TEXT NOT NULL,
    plugin_id TEXT,
    plugin_version TEXT,
    elapsed_ns INTEGER NOT NULL,
    verdict INTEGER NOT NULL
);
```

---

## 4. Modelo de Memoria, Arenas y Ciclo de Vida de SQLite

| Recurso / Estructura | Propietario / Almacenamiento | Tiempo de Vida (Lifetime) | Quién libera / cierra |
| :--- | :--- | :--- | :--- |
| Gobierno del pipeline (`run_metadata`, `schema_registry`, `pipeline_gates`, `pipeline_trace`) | Instancia `sqlite3*` en `StateDatabase` | Toda la ejecución del pipeline sobre el archivo actual. | `StateDatabase.deinit()` cierra con `sqlite3_close_v2(db)`. |
| Árbol declarativo `PipelineNode` y declaraciones `PluginDeclaration` | `pipeline_arena` (respaldado por `gpa`) | Desde el parseo de `pipeline.yaml` hasta el cierre o `reloadAll()`. | `PipelineEngine` al salir o recargar. |
| Librerías dinámicas (`std.DynLib`) | `PluginLoader` (`gpa`) | Mientras el catálogo de plugins esté activo. | `PluginLoader.deinit()` llama a `dyn_lib.close()`. |

### Invariante de Enlace Dinámico Único de `libsqlite3` en `build.zig`
Para que el puntero `*sqlite3` creado por `StateDatabase` en `M0` sea operado de forma segura por cualquier plugin cargado mediante `std.DynLib`, `build.zig` debe definir una función auxiliar común (ej. `linkSharedSqlite(compile_step: *std.Build.Step.Compile)`) que invoque `compile_step.linkSystemLibrary("sqlite3")` y `compile_step.linkLibC()`. **Queda prohibido compilar `sqlite3.c` estáticamente dentro de los artefactos `.so`**, evitando duplicar el estado global de SQLite (mutexes y caché de páginas) en el proceso.

### Firewall de Capacidades en SQLite (`sqlite3_set_authorizer` — Ver `ADR-003`) y Auto-Aislamiento Landlock (`ADR-005`)
1. **Protección de Tablas de Gobierno (`setStepAuthorizer`):**
   - Antes de invocar `plugin.execute_step(&ctx_abi)`, `PipelineEngine` activa `sqlite3_set_authorizer` para impedir que cualquier plugin modifique por SQL directo las tablas exclusivas de `M0` (`run_metadata`, `schema_registry`, `pipeline_gates`, `pipeline_trace` $\rightarrow$ devuelve `SQLITE_DENY` ante `INSERT`/`UPDATE`/`DELETE`/`DROP`). El estado de las compuertas solo puede actualizarse a través del callback auditado `ctx.set_gate_state`.
   - Asimismo, si un plugin no es el productor del dominio `"ir_core"`, el autorizador deniega cualquier `UPDATE`/`DELETE`/`DROP` sobre `container_metadata` e `ir_regions`, garantizando la inmutabilidad del `ContainerIR`.
2. **Confinamiento sin Privilegios con Linux Landlock LSM (Opcional / Graceful Fallback):**
   - Una vez cargados los `.so` en el *pre-flight check*, `M0` aplica `prctl(PR_SET_NO_NEW_PRIVS, 1)` y, si el kernel Linux soporta Landlock ($\ge 5.13$), restringe las rutas accesibles por el proceso al archivo de entrada (solo lectura), `/usr`, `/lib`, `configs/` y los directorios de trabajo/cuarentena.

---

## 5. Flujo Algorítmico (`sequenceDiagram`) y Validación de Versiones por Dominio

### 5.1. Algoritmo de Validación Pre-Flight y Aprovisionamiento de Bancos SQLite (`validatePipelineCompatibility`)
Antes de iniciar la ejecución sobre el archivo de entrada, `PluginLoader` recorre la secuencia de pasos declarados en `pipeline.yaml`:
1. **Nivel 1 (`ABI`):** `descriptor.abi_version == 1`. Si no $\rightarrow$ `error.AbiVersionMismatch`.
2. **Nivel 2 (`SemVer del Plugin`):** Verifica que `descriptor.plugin_version` esté dentro de `[min_version, max_version]` si fueron declarados en el bloque `plugins:` del YAML. Si no $\rightarrow$ `error.PluginVersionOutOfBounds`.
3. **Nivel 3A (`Aprovisionamiento de Bancos SQLite bajo Demanda` — `SchemaContract_ABI`):**
   - Por cada banco `bank` en `descriptor.requires_schemas_ptr[0..descriptor.requires_schemas_len]`:
     - Si `bank.domain` aún no está en `schema_registry`, `StateDatabase.ensureSchemaBankLoaded` carga `configs/schemas/{domain}_v{version}.sql`, lo ejecuta en SQLite y registra `(domain, version)` en `schema_registry`.
     - Si `bank.domain` ya fue cargado por un plugin anterior pero con una `version != bank.version` $\rightarrow$ devuelve `error.SchemaVersionMismatchBetweenPlugins`.
     - Si el archivo `.sql` del banco no existe $\rightarrow$ devuelve `error.SchemaBankDdlNotFound`.
4. **Nivel 3B (`Hard Dependencies entre Plugins` — `PluginDependency_ABI`):**
   - Por cada dependencia dura `dep` en `descriptor.requires_plugins_ptr[0..descriptor.requires_plugins_len]`:
     - Comprueba que `dep.plugin_id` haya aparecido en un paso anterior del recorrido de ejecución y que su `plugin_version` sea $\ge \text{dep.min\_version}$.
     - Si no apareció antes $\rightarrow$ devuelve `error.MissingHardPluginDependency`.
   - Añade `(descriptor.plugin_id, descriptor.plugin_version)` al conjunto `executed_plugins_so_far`.

### 5.2. Diagrama de Secuencia: Pre-Flight Check, Carga y Ejecución contra SQLite

```mermaid
sequenceDiagram
    participant CLI as main.zig
    participant Yaml as YamlPipelineParser
    participant Loader as PluginLoader
    participant DB as StateDatabase (SQLite3)
    participant Engine as PipelineEngine
    participant Plugin as Plugin (.so)

    CLI->>Yaml: parseConfig("configs/pipeline.yaml")
    Yaml-->>CLI: ParsedPipelineConfig (db_cfg, plugins[], root_node)

    loop Cada item en plugins[]
        CLI->>Loader: loadDeclaredPlugin(spec)
        Loader->>Loader: Verifica permisos seguros (mode & 0o022 == 0)
        Loader->>Loader: DynLib.open + verifica Nivel 1 (ABI) y Nivel 2 (SemVer)
    end

    CLI->>Loader: validatePipelineCompatibility(execution_order)
    Note over Loader: Verifica Nivel 3: Cada SchemaContract_ABI requerido ha sido producido con versión compatible

    CLI->>DB: initMemoryOrFile(":memory:", schema_m0.sql)
    CLI->>Engine: executeRoot(root_node, ctx)

    loop Cada LeafStep del árbol
        Engine->>DB: setStepAuthorizer(produces_domain, is_append_plugin)
        Engine->>Plugin: execute_step(&ctx_abi)
        Plugin->>DB: Crea/consulta sus tablas permitidas en ctx_abi.sqlite_db
        Plugin->>Engine: set_gate_state("sanitized_gate", true) (vía callback host)
        Plugin-->>Engine: StepVerdict_ABI
        Engine->>DB: clearAuthorizer() + Registra schema_registry y pipeline_trace
    end
```

### 5.3. Tabla de Casos Borde (Edge Cases) Obligatorios

| Componente | Caso Borde | Comportamiento Exacto Requerido |
| :--- | :--- | :--- |
| `SafeCursor` | `pushLimit(size)` donde `pos + size` desborda `u64` o supera `currentLimit()` | Devolver `error.IntegerOverflow` o `error.BoundsViolation` sin alterar `limit_stack`. |
| `PluginLoader` | Un plugin consumidor requiere `domain = "ir_core"` versión `2..2`, pero el productor anterior declara versión `1` | Abortar en el *pre-flight check* con `error.SchemaVersionMismatchBetweenPlugins`. |
| `PluginLoader` | Un plugin consumidor requiere `domain = "ir_core"` y ningún step anterior lo produce | Abortar en el *pre-flight check* con `error.MissingSchemaProducerBeforeConsumer`. |
| `PipelineEngine` | Un `StageGroup` declara `require_gate: "sanitized_gate"`, pero en la tabla `pipeline_gates` esa compuerta no existe o tiene `is_open = 0` | Abortar la entrada al grupo devolviendo `error.PipelineGateLocked`. |
| `StateDatabase` (`Authorizer`) | Un plugin intenta ejecutar por SQL directo `UPDATE pipeline_gates SET is_open = 1` o `DELETE FROM ir_regions` | `sqlite3_prepare_v2` falla con `SQLITE_AUTH` (`23`) gracias al callback `sqlite3_set_authorizer` (`ADR-003`). |

---

## 6. Declaración en `configs/pipeline.yaml`

```yaml
database:
  mode: "memory"
  base_schema: "configs/schema_m0.sql"

plugins:
  - id: "vidsec.m1.ir_builder"
    path: "./zig-out/lib/plugins/parsers/libm1_ir_builder.so"
    min_version: "1.0.0"
    config: "configs/stages/m1_parsers.yaml"

  - id: "vidsec.m2.r01_magic"
    path: "./zig-out/lib/plugins/audit/libr01_magic.so"
    min_version: "1.0.0"

  - id: "vidsec.m4.surgical_cdr"
    path: "./zig-out/lib/plugins/sanitizers/libm4_surgical_cdr.so"

  - id: "vidsec.m5.normalize_audio"
    path: "./zig-out/lib/plugins/processors/libm5_audio.so"

pipeline:
  name: "vidsec_master_pipeline"
  policy: "run_all"
  steps:
    - group: "Phase1_Reconstruction"
      policy: "fail_fast_on_warning"
      steps:
        - step: "BuildContainerIR"
          plugin: "vidsec.m1.ir_builder"

    - group: "Phase2_SecurityAudit"
      policy: "run_all"
      steps:
        - step: "MagicMismatch"
          plugin: "vidsec.m2.r01_magic"

    - group: "Phase3_SanitizationGate"
      policy: "run_all"
      steps:
        - step: "SurgicalZeroAndTruncate"
          plugin: "vidsec.m4.surgical_cdr"

    - group: "Phase4_MediaProcessing"
      policy: "run_all"
      require_gate: "sanitized_gate"
      steps:
        - step: "NormalizeAudioEBU"
          plugin: "vidsec.m5.normalize_audio"
```

---

## 7. Vectores Binarios en Crudo y Suite de Tests de Aceptación (`zig build test`)

### Test 1: `SafeCursor` — Límites Aritméticos y Pila de Profundidad
- Verifica con el vector de 16 bytes `[_]u8{ 0x00, 0x00, 0x00, 0x10, 'f', 't', 'y', 'p', ... }` que `pushLimit` captura `error.BoundsViolation` y `error.IntegerOverflow`.

### Test 2: Validación Pre-Flight de Bancos SQLite (`SchemaContract_ABI`) y Hard Dependencies (`PluginDependency_ABI`)
- **Caso A (Compatible con SemVer dispares + Aprovisionamiento de Banco):**
  - Mock Plugin A (`1.0.0`) declara `requires_schemas = &.{ .{ .domain = "mock_domain", .version = 1, .writable = true } }`.
  - Mock Plugin B (`5.4.0`) declara `requires_schemas = &.{ .{ .domain = "mock_domain", .version = 1, .writable = false } }` y `requires_plugins = &.{ .{ .plugin_id = "mock.plugin.a", .min_version = .{ .major = 1, .minor = 0, .patch = 0 } } }`.
  - Resultado: `validatePipelineCompatibility` carga `configs/schemas/mock_domain_v1.sql` una sola vez y aprueba la topología.
- **Caso B (Choque de versión de banco SQLite o falta de Hard Dependency):**
  - Mock Plugin B (`6.0.0`) pide `"mock_domain"` `version = 2` mientras Mock Plugin A (`1.0.0`) pidió `version = 1` $\rightarrow$ `error.SchemaVersionMismatchBetweenPlugins`.
  - Si se elimina Mock Plugin A del pipeline mientras Mock Plugin B lo mantiene en `requires_plugins` $\rightarrow$ `error.MissingHardPluginDependency`.

### Test 3: Compuertas con Nombre en SQLite (`pipeline_gates` + `require_gate`) y Firewall `sqlite3_set_authorizer` (`ADR-003`)
- Ejecuta un pipeline donde un step abre `"test_gate"` mediante `ctx.set_gate_state(ctx, "test_gate", true)` y verifica que el siguiente grupo con `require_gate: "test_gate"` se ejecuta; luego repite con `is_open = false` y verifica que devuelve `error.PipelineGateLocked`.
- Verifica que si un plugin intenta ejecutar directamente `sqlite3_exec(ctx.sqlite_db, "UPDATE pipeline_gates SET is_open = 1;", ...)` o `DROP TABLE run_metadata;`, SQLite rechaza la sentencia con `SQLITE_AUTH` (`23`).

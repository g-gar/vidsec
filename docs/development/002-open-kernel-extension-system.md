# 002 — Diseño del Microkernel Reactivo Abierto (`src/kernel/`) y Sistema de Extensiones en 5 Planos

| Metadatos | Valor |
| :--- | :--- |
| **ID** | `ARCH-002` |
| **Depende de** | [`ARCH-001`](./001-transport-layer-unification.md) (`src/transport/{inbound,outbound}`) |
| **Bloquea a** | [`ARCH-003`](./003-core-debloating-and-pcapng-extraction.md), [`ARCH-004`](./004-observability-otel-and-dag-visualizer.md) |
| **Módulos afectados** | `src/kernel/` *(nuevo)*, `src/engine/`, `src/dataflow/predicate.zig`, `src/yaml/env.zig`, `src/transport/`, `extensions/` |

---

## 1. Contexto y Problema Actual (As-Is)

Actualmente, el mecanismo de "extensiones" de Flowdata es extremadamente limitado:
1. En `src/engine/runner.zig` (`RunnerOptions`) y `src/transport/inbound/app.zig` (`AppConfig`), solo existe un puntero a función `driver_initializer: ?*const fn (registry: *RepositoryRegistry) anyerror!void`.
2. Eso significa que una extensión hoy **solo puede registrar drivers de almacenamiento (`StorageRepository`)**.
3. No existe una interfaz formal `Extension`, ni un objeto `KernelContext` que dé acceso controlado al resto de subsistemas del motor:
   * Una extensión **no puede** inspeccionar o transformar el `PipelineAST` tras la carga del YAML (necesario para generar grafos del DAG, linters o inyectores de pasos).
   * Una extensión **no puede** suscribirse al ciclo de vida de ejecución ni al tráfico de red (necesario para OpenTelemetry, captura PCAPNG desacoplada o depuradores en vivo).
   * Una extensión **no puede** añadir nuevos subcomandos al Dispatcher (como `graph` o `trace`).
   * Una extensión **no puede** añadir funciones personalizadas al evaluador de predicados (`where:`) ni esquemas de resolución de secretos (`${vault:...}`) al interpolador YAML.

---

## 2. Arquitectura Objetivo (To-Be): El Kernel Abierto de 5 Planos

Se introduce el paquete **`src/kernel/`**, que define el contrato polimórfico **`Extension`** y el **`KernelContext`** que el motor entrega a cada extensión durante el arranque.

### 2.1. Los 5 Planos de Extensibilidad del Kernel

```mermaid
flowchart TB
    subgraph ExtLayer["Cualquier Extensión (impl Extension)"]
        E["fn register(self, kernel: *KernelContext) !void"]
    end

    E --> P1 & P2 & P3 & P4 & P5

    subgraph P1["Plano 1: Compilador & AST Passes"]
        AstReg["AstPassRegistry<br/>- onAstLoaded(ast: *PipelineAST)<br/>- Inspectores de DAG / Mutadores / Linters"]
    end

    subgraph P2["Plano 2: Bus de Telemetría & Ciclo de Vida"]
        TelBus["TelemetryBus (Zero-overhead if empty)<br/>- onPipelineStart / onPipelineEnd<br/>- onStepStart / onStepEnd<br/>- onRouterDecision / onFilterEvaluated<br/>- onTaskLog<br/>- onOutboundExchange / onOutboundWirePacket"]
    end

    subgraph P3["Plano 3: Comandos del Dispatcher"]
        CmdReg["CommandRegistry (InboundDispatcher)<br/>- registerCommand('graph', handler)<br/>- Accesible por CLI, HTTP y gRPC"]
    end

    subgraph P4["Plano 4: Álgebra Dataflow & Config DSL"]
        DslReg["DslRegistry<br/>- registerPredicateFn('entropy', fn)<br/>- registerEnvScheme('vault', fn)"]
    end

    subgraph P5["Plano 5: Registros de I/O & Plugins"]
        IoReg["I/O Registries<br/>- datasources: *RepositoryRegistry<br/>- inbound: *InboundRegistry<br/>- outbound: *OutboundRegistry<br/>- plugins: *PluginRegistry"]
    end
```

---

### 2.2. Diagrama UML de Clases de `src/kernel/`

```mermaid
classDiagram
    class Extension {
        +*anyopaque ptr
        +*VTable vtable
        +name() []const u8
        +register(kernel: *KernelContext) anyerror!void
        +deinit(allocator: Allocator) void
    }

    class KernelContext {
        +Allocator allocator
        +RepositoryRegistry datasources
        +InboundRegistry inbound
        +OutboundRegistry outbound
        +PluginRegistry plugins
        +AstPassRegistry ast_passes
        +TelemetryBus telemetry
        +DslRegistry dsl
        +CommandRegistry commands
        +use(ext: Extension) !void
    }

    class AstPass {
        +*anyopaque ptr
        +*VTable vtable
        +name() []const u8
        +runPass(allocator: Allocator, ast: *PipelineAST) anyerror!void
    }

    class TelemetrySubscriber {
        +*anyopaque ptr
        +*VTable vtable
        +onEvent(event: TelemetryEvent) void
        +flush(repos: *RepositoryRegistry) anyerror!void
    }

    class TelemetryBus {
        -ArrayList~TelemetrySubscriber~ subscribers
        +subscribe(sub: TelemetrySubscriber) !void
        + hasSubscribers() bool
        +emit(event: TelemetryEvent) void
        +flushAll(repos: *RepositoryRegistry) !void
    }

    KernelContext *-- AstPassRegistry
    KernelContext *-- TelemetryBus
    KernelContext *-- DslRegistry
    KernelContext *-- CommandRegistry
    Extension ..> KernelContext : enriches via register()
    TelemetryBus o-- TelemetrySubscriber : broadcasts to
```

---

### 2.3. Diagrama de Secuencia: Ciclo de Vida Completo con `KernelContext`

```mermaid
sequenceDiagram
    participant Main as main.zig
    participant App as TransportApp
    participant Kernel as KernelContext
    participant Ext as Extensiones (SQLite, OTel, Pcapng, DagViz)
    participant Runner as PipelineRunner
    participant Engine as PipelineEngine

    Main->>App: run(.{ extensions = &.{ ds_ext, otel_ext, pcap_ext, dag_ext } })
    App->>Kernel: init(allocator)
    loop Para cada Extension
        App->>Ext: ext.register(&kernel)
        Ext->>Kernel: Registra drivers, AstPasses, TelemetrySubscribers, Commands, DSL hooks
    end

    App->>Runner: initFromFiles(allocator, options, &kernel)
    Runner->>Runner: Parsea .env (usando kernel.dsl.env_schemes) y pipeline.yaml -> PipelineAST
    Runner->>Kernel: ast_passes.runAll(&ast)

    Note over App,Engine: Ejecución de comando 'run'
    App->>Engine: run(input_payload, &kernel)
    Engine->>Kernel: telemetry.emit(.{ .pipeline_start = ... })
    loop Para cada Step / Router del DAG
        Engine->>Kernel: telemetry.emit(.{ .step_start = ... })
        Engine->>Engine: Ejecuta tarea C-ABI / Red Outbound
        Engine->>Kernel: telemetry.emit(.{ .outbound_wire_packet = ... })
        Engine->>Kernel: telemetry.emit(.{ .step_end = ... })
    end
    Engine->>Kernel: telemetry.emit(.{ .pipeline_end = ... })
    Engine->>Kernel: telemetry.flushAll(&kernel.datasources)
```

---

## 3. Contratos e Interfaces en Zig a Implementar

### 3.1. `src/kernel/extension.zig` (`Extension` Contract)

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const KernelContext = @import("context.zig").KernelContext;

pub const Extension = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *const anyopaque) []const u8,
        register: *const fn (ptr: *anyopaque, kernel: *KernelContext) anyerror!void,
        deinit: ?*const fn (ptr: *anyopaque, allocator: Allocator) void = null,
    };

    pub fn assertImplements(comptime T: type) void {
        if (!@hasDecl(T, "name") or !@hasDecl(T, "register")) {
            @compileError(@typeName(T) ++ " must implement name() and register(*KernelContext)");
        }
    }

    pub fn name(self: Extension) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn register(self: Extension, kernel: *KernelContext) anyerror!void {
        return self.vtable.register(self.ptr, kernel);
    }

    pub fn deinit(self: Extension, allocator: Allocator) void {
        if (self.vtable.deinit) |df| df(self.ptr, allocator);
    }

    /// Helper para extensiones sin estado (stateless module extensions).
    pub fn fromStateless(
        comptime ext_name: []const u8,
        comptime register_fn: *const fn (kernel: *KernelContext) anyerror!void,
    ) Extension {
        const S = struct {
            var dummy: u8 = 0;
            fn getName(_: *const anyopaque) []const u8 {
                return ext_name;
            }
            fn doRegister(_: *anyopaque, k: *KernelContext) anyerror!void {
                return register_fn(k);
            }
            const vtable = VTable{
                .name = &getName,
                .register = &doRegister,
                .deinit = null,
            };
        };
        return .{ .ptr = @ptrCast(&S.dummy), .vtable = &S.vtable };
    }
};
```

### 3.2. `src/kernel/telemetry.zig` (`TelemetryEvent`, `SpanContext` y `TelemetryBus`)

Diseñado con semántica compatible con **OpenTelemetry** (`trace_id: [16]u8`, `span_id: [8]u8`, `parent_span_id: [8]u8`, `timestamp_ns: u64`) y con tap de paquetes en crudo para que `pcapng` funcione fuera del core:

```zig
pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const PacketDirection = enum(u8) {
    tx,
    rx,
};

pub const TelemetryEvent = union(enum) {
    pipeline_start: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        ast: *const ast_mod.PipelineAST,
        input_bytes_len: usize,
    },
    pipeline_end: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        duration_ns: u64,
        steps_executed: usize,
        routers_evaluated: usize,
        halted_early: bool,
        final_pipeline: []const u8,
    },
    step_start: struct {
        trace_id: TraceId,
        span_id: SpanId,
        parent_span_id: SpanId,
        timestamp_ns: u64,
        pipeline_name: []const u8,
        step_id: []const u8,
        module_name: []const u8,
        task_name: []const u8,
        input_count: usize,
    },
    step_end: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        duration_ns: u64,
        pipeline_name: []const u8,
        step_id: []const u8,
        status: []const u8,
        output_count: usize,
    },
    filter_evaluated: struct {
        trace_id: TraceId,
        span_id: SpanId,
        step_id: []const u8,
        expression: []const u8,
        items_in: usize,
        items_out: usize,
    },
    router_decision: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        pipeline_name: []const u8,
        router_id: []const u8,
        matched_expression: ?[]const u8,
        target_pipeline: ?[]const u8,
    },
    task_log: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        step_id: []const u8,
        level: u32,
        message: []const u8,
    },
    outbound_exchange: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        step_id: []const u8,
        adapter_id: []const u8,
        record: outbound_mod.CapturedExchangeRecord,
    },
    outbound_wire_packet: struct {
        trace_id: TraceId,
        span_id: SpanId,
        timestamp_ns: u64,
        step_id: []const u8,
        adapter_id: []const u8,
        direction: PacketDirection,
        src_ip: [4]u8,
        dst_ip: [4]u8,
        src_port: u16,
        dst_port: u16,
        payload: []const u8,
        comment: []const u8,
        include_tls_keys: bool,
        snaplen: u32,
    },
};
```

### 3.3. `src/kernel/ast_pass.zig` (`AstPassRegistry`)

Permite que cualquier extensión analice, valide o transforme el `PipelineAST` recién cargado:

```zig
pub const AstPassFn = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    ast: *ast_mod.PipelineAST,
) anyerror!void;
```

### 3.4. `src/kernel/dsl.zig` (`DslRegistry`)

1. **Predicados personalizados en `dataflow/predicate.zig`**:
   * Permite registrar funciones `CustomPredicateFn = *const fn (arg: ReflectedValue, param_literal: []const u8) bool`.
   * Sintaxis soportada en `where:` / `when:`: `fn_name(field_name, 'arg')` (por ejemplo: `cidr_match(dst_host, '10.0.0.0/8')`).
2. **Esquemas de interpolación en `yaml/env.zig`**:
   * Permite registrar resolvers `EnvSchemeResolverFn = *const fn (allocator: Allocator, key: []const u8) ?[]const u8`.
   * Cuando `EnvInterpolator` encuentra `${scheme:key}` (y no es `${VAR:-default}`), busca `scheme` en los resolvers registrados.

---

## 4. Adaptación de `extensions/datasource/` al Nuevo Contrato `Extension`

En `extensions/datasource/mod.zig`, además de mantener `registerDefaultDrivers(&repos)` por retrocompatibilidad, se expone una `Extension` oficial:

```zig
pub const extension = flowdata.kernel.Extension.fromStateless(
    "flowdata.datasources.default",
    &registerExtension,
);

pub fn registerExtension(kernel: *flowdata.kernel.KernelContext) !void {
    try registerDefaultDrivers(&kernel.datasources);
}
```

Y en `apps/vidsec/src/main.zig`, la aplicación puede registrar sus extensiones de forma declarativa:

```zig
pub fn main() !u8 {
    return vidsec.flowdata.transport.inbound.TransportApp.run(.{
        .app_name = "vidsec",
        .description = "Zero-Copy Declarative Video Security & Forensics Engine",
        .version = build_options.version_string,
        .extensions = &.{
            vidsec.extensions.datasource.extension,
        },
    });
}
```

---

## 5. Criterios de Aceptación y Verificación

1. **Creación de `src/kernel/`**: Existen `src/kernel/{mod.zig,context.zig,extension.zig,telemetry.zig,ast_pass.zig,dsl.zig,commands.zig}` exportados en `src/root.zig` (`flowdata.kernel`).
2. **Test de los 5 Planos (`tests/core/kernel_extension_test.zig`)**:
   * **Plano 1**: Una extensión de prueba registra un `AstPass` que cuenta los nodos del `PipelineAST` al cargar el YAML.
   * **Plano 2**: Una extensión de prueba se suscribe al `TelemetryBus` y verifica que recibe en orden `pipeline_start` → `step_start` → `step_end` → `router_decision` → `pipeline_end` con el mismo `trace_id`.
   * **Plano 3**: Una extensión de prueba registra un comando `custom_ping` en `kernel.commands` y lo invoca a través del `InboundDispatcher`.
   * **Plano 4**: Una extensión de prueba registra un esquema `${mock_secret:api_token}` y verifica su interpolación en el YAML.
   * **Plano 5**: `extensions/datasource/mod.zig` se registra mediante `extensions = &.{ ... }`.
3. **Suites en verde**: `zig build test` en raíz y en `apps/vidsec` pasan al 100%.

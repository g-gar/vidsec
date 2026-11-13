const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");
const ast_mod = @import("../ast/ast.zig");
const modules_mod = @import("../plugin/mod.zig");
const repository_mod = @import("../repository/mod.zig");
const network_mod = @import("../transport/outbound/mod.zig");
const engine_net_mod = @import("network.zig");
const WorkerPool = @import("../concurrency/mod.zig").WorkerPool;
pub const plan = @import("plan.zig");
pub const ExecutionPlan = plan.ExecutionPlan;
pub const compilePlan = plan.compilePlan;
pub const Coordinator = @import("coordinator.zig").Coordinator;
pub const reactor = @import("reactor.zig");
pub const RecordEmitter = reactor.RecordEmitter;
pub const PushReactor = reactor.PushReactor;
pub const router = @import("router.zig");
pub const ReactiveRouter = router.ReactiveRouter;
pub const routing = @import("routing/mod.zig");
pub const RoutingStrategy = routing.RoutingStrategy;
pub const RouterRegistry = routing.RouterRegistry;
pub const sources = @import("sources/mod.zig");
pub const BatchSource = sources.BatchSource;
pub const preflight = @import("preflight.zig");

pub const PipelineAST = ast_mod.PipelineAST;
pub const ModuleRegistry = modules_mod.ModuleRegistry;
pub const RepositoryRegistry = repository_mod.RepositoryRegistry;
pub const NetworkRegistry = network_mod.NetworkRegistry;
pub const NetworkAdapter = network_mod.NetworkAdapter;
pub const EngineNetworkController = engine_net_mod.EngineNetworkController;
pub const NetworkEvent = engine_net_mod.NetworkEvent;
pub const PayloadHandle = dataflow.PayloadHandle;
pub const AmbientContext = @import("ambient_context.zig").AmbientContext;

pub const ExecutionSummary = struct {
    steps_executed: usize = 0,
    routers_evaluated: usize = 0,
    halted_early: bool = false,
    final_pipeline: []const u8 = "main",

    // ARCH-017 Phase 17.4: Memory lifecycle and backpressure metrics
    arenas_created: usize = 0,
    arenas_freed_early: usize = 0,
    peak_inflight_bytes: usize = 0,
    throttle_count: usize = 0,
};

pub const EngineError = error{
    MissingMainPipeline,
    UnknownSubPipeline,
    UnknownTaskModule,
    UnknownTaskEntrypoint,
    TaskExecutionFailed,
    OutOfMemory,
};

pub const StepNetworkContext = struct {
    step_id: []const u8,
    task_name: []const u8,
    primary_adapter: ?NetworkAdapter,
    net_ctrl: *EngineNetworkController,

    fn request(
        ptr: *anyopaque,
        network_id: []const u8,
        url: []const u8,
        operation: []const u8,
        headers: []const network_mod.HttpHeader,
        body: []const u8,
    ) network_mod.NetError!network_mod.NetResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.net_ctrl.executeRequest(self.step_id, self.task_name, self.primary_adapter, network_id, url, operation, headers, body);
    }

    fn connect(
        ptr: *anyopaque,
        network_id: []const u8,
        url: []const u8,
        operation: []const u8,
    ) network_mod.NetError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.net_ctrl.connectStream(self.step_id, self.task_name, self.primary_adapter, network_id, url, operation);
    }

    fn send(ptr: *anyopaque, handle: u64, payload: []const u8) network_mod.NetError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.net_ctrl.sendStream(handle, payload);
    }

    fn recv(ptr: *anyopaque, handle: u64, dest: []u8) network_mod.NetError!usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.net_ctrl.recvStream(handle, dest);
    }

    fn close(ptr: *anyopaque, handle: u64) network_mod.NetError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.net_ctrl.closeStream(handle);
    }

    const vtable = modules_mod.NetworkBridge.VTable{
        .request = &request,
        .connect = &connect,
        .send = &send,
        .recv = &recv,
        .close = &close,
    };

    pub fn bridge(self: *StepNetworkContext) modules_mod.NetworkBridge {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var global_prng: ?std.Random.DefaultPrng = null;

pub fn fillRandomBytes(buf: []u8) void {
    if (global_prng == null) {
        var seed: u64 = nowNs();
        if (seed == 0) seed = 0x12345678_9abcdef0;
        global_prng = std.Random.DefaultPrng.init(seed);
    }
    global_prng.?.random().bytes(buf);
}

/// Modern Black Box Native Zig Pipeline Execution Engine.
/// Consumes format-agnostic PipelineAST, executes pure tasks via C-ABI,
/// evaluates RAM predicates zero-copy, and routes payloads to polymorphic repositories.
pub const PipelineEngine = struct {
    allocator: Allocator,
    ast: PipelineAST,
    modules: *ModuleRegistry,
    repos: *RepositoryRegistry,
    networks: ?*NetworkRegistry = null,
    kernel: ?*@import("../kernel/mod.zig").KernelContext = null,
    workers: usize = 1,
    outputs_arena: std.heap.ArenaAllocator,
    ambient: AmbientContext,
    routers: RouterRegistry,

    pub fn init(
        allocator: Allocator,
        ast: PipelineAST,
        modules: *ModuleRegistry,
        repos: *RepositoryRegistry,
    ) PipelineEngine {
        var w = ast.runtime.workers;
        if (w == 0) w = 1;
        return .{
            .allocator = allocator,
            .ast = ast,
            .modules = modules,
            .repos = repos,
            .networks = null,
            .kernel = null,
            .workers = w,
            .outputs_arena = std.heap.ArenaAllocator.init(allocator),
            .ambient = AmbientContext.init(allocator),
            .routers = RouterRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *PipelineEngine) void {
        self.routers.deinit();
        self.outputs_arena.deinit();
    }

    pub fn withRouter(self: *PipelineEngine, name: []const u8, factory: routing.RouterFactoryFn) !void {
        try self.routers.register(name, factory);
    }

    pub fn createRoutingStrategyForPipeline(
        self: *PipelineEngine,
        pipe: ast_mod.PipelineDecl,
        active_mask: ?[]const bool,
        external_outputs: ?*const std.StringHashMapUnmanaged(PayloadHandle),
    ) anyerror!RoutingStrategy {
        if (!self.routers.has("directed")) {
            try self.routers.register("directed", routing.DirectedRouter.factory);
        }
        if (!self.routers.has("type_driven")) {
            try self.routers.register("type_driven", routing.TypeDrivenRouter.factory);
        }
        const mode = pipe.routing orelse self.ast.runtime.routing;
        return self.routers.createForMode(mode, .{
            .allocator = self.allocator,
            .ast = self.ast,
            .pipeline = pipe,
            .modules = self.modules,
            .ambient = &self.ambient,
            .repos = self.repos,
            .active_mask = active_mask,
            .external_outputs = external_outputs,
        });
    }

    pub fn withAmbient(self: *PipelineEngine, amb: AmbientContext) void {
        self.ambient = amb;
    }

    pub fn withNetworks(self: *PipelineEngine, nets: *NetworkRegistry) void {
        self.networks = nets;
    }

    pub fn withKernel(self: *PipelineEngine, k: ?*@import("../kernel/mod.zig").KernelContext) void {
        self.kernel = k;
    }

    pub fn createReactor(self: *PipelineEngine, pipeline_name: []const u8) anyerror!*PushReactor {
        return PushReactor.init(self.allocator, self, pipeline_name);
    }

    pub fn createRouter(self: *PipelineEngine, pipeline_name: []const u8) anyerror!*ReactiveRouter {
        return ReactiveRouter.init(self.allocator, self, pipeline_name);
    }

    pub fn run(self: *PipelineEngine, input_payload: PayloadHandle) anyerror!ExecutionSummary {
        return self.runInternal(input_payload, &.{});
    }

    pub fn runWithSource(self: *PipelineEngine, source: BatchSource) anyerror!ExecutionSummary {
        return self.runInternal(null, &.{source});
    }

    fn runInternal(
        self: *PipelineEngine,
        maybe_input_payload: ?PayloadHandle,
        explicit_sources: []const BatchSource,
    ) anyerror!ExecutionSummary {
        var summary = ExecutionSummary{};
        const start_ns: u64 = nowNs();
        var trace_id: [16]u8 = undefined;
        var root_span_id: [8]u8 = undefined;
        fillRandomBytes(&trace_id);
        fillRandomBytes(&root_span_id);

        const input_bytes_len: usize = if (maybe_input_payload) |p| p.len * p.element_size else 0;
        if (self.kernel) |k| {
            k.telemetry.emit(.{
                .pipeline_start = .{
                    .trace_id = trace_id,
                    .span_id = root_span_id,
                    .timestamp_ns = start_ns,
                    .ast = &self.ast,
                    .input_bytes_len = input_bytes_len,
                },
            });
        }

        // 1. Resolve or instantiate all declared datasources
        for (self.ast.datasources) |ds_spec| {
            _ = try self.repos.resolveOrCreate(ds_spec);
        }

        // 1b. Initialize EngineNetworkController to coordinate all virtual network adapters,
        // C-ABI streams, and `network.captured_events`.
        var net_ctrl = try EngineNetworkController.init(self.allocator, self.ast, self.networks);
        defer net_ctrl.deinit();

        // 1c. Bounded worker pool shared by DAG steps and intra-step lifting (ARCH-017 §3.3)
        var pool: ?*WorkerPool = null;
        if (self.workers > 1) {
            pool = try WorkerPool.init(self.allocator, self.workers);
        }
        defer if (pool) |p| p.deinit();

        // 2. Track intermediate step outputs by step ID
        const outputs_alloc = self.outputs_arena.allocator();
        const entrypoint = self.ast.getEntrypoint() orelse "main";
        summary.final_pipeline = entrypoint;

        // 3. Execute via explicit BatchSources, or auto-emit from `role: source` datasources
        // in `type_driven` mode when CLI/offline input is empty (ARCH-025).
        if (explicit_sources.len > 0) {
            try self.emitSources(explicit_sources, entrypoint, outputs_alloc, &net_ctrl, &summary, trace_id, root_span_id, pool);
        } else {
            const input_payload = maybe_input_payload.?;
            const is_empty_cli = (input_payload.repr == .bytes and input_payload.len == 0);
            const pipe_decl = self.ast.getPipeline(entrypoint);
            const effective_routing = if (pipe_decl) |p| (p.routing orelse self.ast.runtime.routing) else self.ast.runtime.routing;

            var auto_sources: std.ArrayListUnmanaged(sources.DatasourceSliceSource) = .empty;
            defer auto_sources.deinit(self.allocator);

            if (is_empty_cli and effective_routing == .type_driven) {
                for (self.ast.datasources) |ds_spec| {
                    if (ds_spec.role == .source) {
                        if (self.repos.get(ds_spec.id)) |repo| {
                            try auto_sources.append(self.allocator, sources.DatasourceSliceSource.init(
                                self.allocator,
                                ds_spec.id,
                                repo,
                                ds_spec.id,
                            ));
                        }
                    }
                }
            }

            if (auto_sources.items.len > 0) {
                var batch_handles = try self.allocator.alloc(BatchSource, auto_sources.items.len);
                defer self.allocator.free(batch_handles);
                for (auto_sources.items, 0..) |*src, idx| {
                    batch_handles[idx] = src.batchSource();
                }
                try self.emitSources(batch_handles, entrypoint, outputs_alloc, &net_ctrl, &summary, trace_id, root_span_id, pool);
            } else {
                var outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty;
                try self.executeSubPipeline(entrypoint, input_payload, &outputs, outputs_alloc, &net_ctrl, &summary, trace_id, root_span_id, pool);
            }
        }

        if (self.kernel) |k| {
            const end_ns: u64 = nowNs();
            k.telemetry.emit(.{
                .pipeline_end = .{
                    .trace_id = trace_id,
                    .span_id = root_span_id,
                    .timestamp_ns = end_ns,
                    .duration_ns = end_ns - start_ns,
                    .steps_executed = summary.steps_executed,
                    .routers_evaluated = summary.routers_evaluated,
                    .halted_early = summary.halted_early,
                    .final_pipeline = summary.final_pipeline,
                },
            });
            try k.telemetry.flushAll(self.repos);
        }

        return summary;
    }

    fn emitSources(
        self: *PipelineEngine,
        batch_sources: []const BatchSource,
        entrypoint: []const u8,
        outputs_alloc: Allocator,
        net_ctrl: *EngineNetworkController,
        summary: *ExecutionSummary,
        trace_id: [16]u8,
        root_span_id: [8]u8,
        pool: ?*WorkerPool,
    ) anyerror!void {
        const EmitCtx = struct {
            engine: *PipelineEngine,
            entrypoint: []const u8,
            outputs_alloc: Allocator,
            net_ctrl: *EngineNetworkController,
            summary: *ExecutionSummary,
            trace_id: [16]u8,
            root_span_id: [8]u8,
            pool: ?*WorkerPool,

            fn onEmit(raw: *anyopaque, _: []const u8, record: PayloadHandle) anyerror!void {
                const ctx: *@This() = @ptrCast(@alignCast(raw));
                var item_outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty;
                try ctx.engine.executeSubPipeline(
                    ctx.entrypoint,
                    record,
                    &item_outputs,
                    ctx.outputs_alloc,
                    ctx.net_ctrl,
                    ctx.summary,
                    ctx.trace_id,
                    ctx.root_span_id,
                    ctx.pool,
                );
            }
        };

        var emit_ctx = EmitCtx{
            .engine = self,
            .entrypoint = entrypoint,
            .outputs_alloc = outputs_alloc,
            .net_ctrl = net_ctrl,
            .summary = summary,
            .trace_id = trace_id,
            .root_span_id = root_span_id,
            .pool = pool,
        };
        const emitter = sources.RecordEmitter{
            .ptr = &emit_ctx,
            .emit_fn = &EmitCtx.onEmit,
        };
        for (batch_sources) |src| {
            _ = try src.emitAll(self.allocator, emitter);
        }
    }

    pub fn resolveStreamExpr(
        self: *PipelineEngine,
        expr: ast_mod.InboundStreamExpr,
        active_input: PayloadHandle,
        outputs: *const std.StringHashMapUnmanaged(PayloadHandle),
    ) anyerror!PayloadHandle {
        switch (expr.op) {
            .none => {
                if (expr.stream_ref) |ref| {
                    if (std.mem.eql(u8, ref, "stream") or std.mem.eql(u8, ref, "file")) {
                        return active_input;
                    }
                    if (std.mem.eql(u8, ref, "jobs")) {
                        if (self.ast.jobs.len > 0) {
                            return PayloadHandle.fromSlice(ast_mod.JobSpec, self.ast.jobs);
                        }
                    }

                    // ARCH-018: Ambient context streams (system.*, env.*)
                    if (std.mem.startsWith(u8, ref, "system.") or std.mem.startsWith(u8, ref, "env.")) {
                        if (try self.ambient.asPayload(self.outputs_arena.allocator(), ref)) |amb_payload| {
                            return amb_payload;
                        }
                    }

                    if (outputs.get(ref)) |prev_out| {
                        return prev_out;
                    }
                    if (self.repos.get(ref)) |repo| {
                        if (repo.readPayload(ref)) |payload| {
                            return payload;
                        }
                    }

                    // Dynamic field projection for dotted references: `task.field` or `channel.field`
                    if (std.mem.indexOfScalar(u8, ref, '.')) |dot_idx| {
                        const target_name = ref[0..dot_idx];
                        const field_name = ref[dot_idx + 1 ..];

                        const base_payload = if (outputs.get(target_name)) |bo|
                            bo
                        else if (self.repos.get(target_name)) |repo|
                            repo.readPayload(target_name) orelse null
                        else
                            null;

                        if (base_payload) |bp| {
                            if (bp.getReflected(field_name)) |rval| {
                                const dyn_fields = try self.allocator.alloc(dataflow.DynamicField, 1);
                                dyn_fields[0] = .{
                                    .name = try self.allocator.dupe(u8, field_name),
                                    .value = rval,
                                };
                                const dyn_record = try self.allocator.alloc(dataflow.DynamicRecord, 1);
                                dyn_record[0] = dataflow.DynamicRecord.init(dyn_fields);
                                return PayloadHandle.fromSlice(dataflow.DynamicRecord, dyn_record);
                            }
                        }
                    }
                }
                return active_input;
            },
            .slice => {
                var target = active_input;
                if (expr.sub_streams.len > 0) {
                    target = try self.resolveStreamExpr(expr.sub_streams[0], active_input, outputs);
                }
                return dataflow.algebra.slicePayload(target, expr.slice_offset, expr.slice_count);
            },
            .merge => {
                if (expr.sub_streams.len == 0) return active_input;
                var sub_payloads = try self.allocator.alloc(PayloadHandle, expr.sub_streams.len);
                defer self.allocator.free(sub_payloads);
                for (expr.sub_streams, 0..) |sub_expr, i| {
                    sub_payloads[i] = try self.resolveStreamExpr(sub_expr, active_input, outputs);
                }
                return try dataflow.algebra.mergePayloads(self.allocator, sub_payloads);
            },
            .zip, .join => {
                if (expr.sub_streams.len > 0) {
                    return try self.resolveStreamExpr(expr.sub_streams[0], active_input, outputs);
                }
                return active_input;
            },
        }
    }

    pub fn executeSubPipeline(
        self: *PipelineEngine,
        name: []const u8,
        active_input: PayloadHandle,
        outputs: *std.StringHashMapUnmanaged(PayloadHandle),
        outputs_alloc: Allocator,
        net_ctrl: *EngineNetworkController,
        summary: *ExecutionSummary,
        trace_id: [16]u8,
        parent_span_id: [8]u8,
        pool: ?*WorkerPool,
    ) anyerror!void {
        return self.executeSubPipelineSelective(name, null, active_input, outputs, outputs_alloc, net_ctrl, summary, trace_id, parent_span_id, pool);
    }

    pub fn executeSubPipelineSelective(
        self: *PipelineEngine,
        name: []const u8,
        active_mask: ?[]const bool,
        active_input: PayloadHandle,
        outputs: *std.StringHashMapUnmanaged(PayloadHandle),
        outputs_alloc: Allocator,
        net_ctrl: *EngineNetworkController,
        summary: *ExecutionSummary,
        trace_id: [16]u8,
        parent_span_id: [8]u8,
        pool: ?*WorkerPool,
    ) anyerror!void {
        const pipe = self.ast.getPipeline(name) orelse return error.UnknownSubPipeline;
        summary.final_pipeline = name;

        var exec_plan = try compilePlan(self.allocator, pipe, self.ast);
        defer exec_plan.deinit();

        var strategy = try self.createRoutingStrategyForPipeline(pipe, active_mask, outputs);
        defer strategy.deinit();

        const exec_pool: ?*WorkerPool = if (self.ast.runtime.scheduler == .dag and pool != null and exec_plan.nodes.len > 1)
            pool.?
        else
            null;

        try Coordinator.runWithStrategy(
            self,
            &exec_plan,
            strategy,
            active_input,
            outputs,
            outputs_alloc,
            net_ctrl,
            summary,
            trace_id,
            parent_span_id,
            exec_pool,
        );
    }
};

pub fn extractCountRef(predicate_expr: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, predicate_expr, "count(") orelse return null;
    const after = predicate_expr[idx + "count(".len ..];
    const close = std.mem.indexOfScalar(u8, after, ')') orelse return null;
    const inner = std.mem.trim(u8, after[0..close], " \t");
    return if (inner.len > 0) inner else null;
}

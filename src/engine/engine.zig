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

pub const PipelineAST = ast_mod.PipelineAST;
pub const ModuleRegistry = modules_mod.ModuleRegistry;
pub const RepositoryRegistry = repository_mod.RepositoryRegistry;
pub const NetworkRegistry = network_mod.NetworkRegistry;
pub const NetworkAdapter = network_mod.NetworkAdapter;
pub const EngineNetworkController = engine_net_mod.EngineNetworkController;
pub const NetworkEvent = engine_net_mod.NetworkEvent;
pub const PayloadHandle = dataflow.PayloadHandle;

pub const ExecutionSummary = struct {
    steps_executed: usize = 0,
    routers_evaluated: usize = 0,
    halted_early: bool = false,
    final_pipeline: []const u8 = "main",
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
        };
    }

    pub fn deinit(self: *PipelineEngine) void {
        self.outputs_arena.deinit();
    }

    pub fn withNetworks(self: *PipelineEngine, nets: *NetworkRegistry) void {
        self.networks = nets;
    }

    pub fn withKernel(self: *PipelineEngine, k: ?*@import("../kernel/mod.zig").KernelContext) void {
        self.kernel = k;
    }

    pub fn run(self: *PipelineEngine, input_payload: PayloadHandle) anyerror!ExecutionSummary {
        var summary = ExecutionSummary{};
        const start_ns: u64 = nowNs();
        var trace_id: [16]u8 = undefined;
        var root_span_id: [8]u8 = undefined;
        fillRandomBytes(&trace_id);
        fillRandomBytes(&root_span_id);

        if (self.kernel) |k| {
            k.telemetry.emit(.{
                .pipeline_start = .{
                    .trace_id = trace_id,
                    .span_id = root_span_id,
                    .timestamp_ns = start_ns,
                    .ast = &self.ast,
                    .input_bytes_len = input_payload.len * input_payload.element_size,
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

        var outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty;

        // 3. Execute main pipeline
        try self.executeSubPipeline("main", input_payload, &outputs, outputs_alloc, &net_ctrl, &summary, trace_id, root_span_id, pool);

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
        const pipe = self.ast.getPipeline(name) orelse return error.UnknownSubPipeline;
        summary.final_pipeline = name;

        var exec_plan = try compilePlan(self.allocator, pipe, self.ast);
        defer exec_plan.deinit();

        if (self.ast.runtime.scheduler == .dag and pool != null and exec_plan.nodes.len > 1) {
            try Coordinator.run(self, &exec_plan, active_input, outputs, outputs_alloc, net_ctrl, summary, trace_id, parent_span_id, pool.?);
            return;
        }

        var current_input = active_input;

        for (exec_plan.topological_order) |node_idx| {
            if (summary.halted_early) break;
            const step = exec_plan.nodes[node_idx].step;

            switch (step) {
                .task => |task_spec| {
                    var step_span_id: [8]u8 = undefined;
                    fillRandomBytes(&step_span_id);
                    const step_start_ns: u64 = nowNs();

                    // Resolve input stream expressions via Dataflow algebra (ARCH-016 multi-input support)
                    var step_input = current_input;
                    var bound_inputs_list: std.ArrayListUnmanaged(modules_mod.BoundInput) = .empty;
                    if (task_spec.inputs.len > 0) {
                        for (task_spec.inputs, 0..) |in_binding, in_idx| {
                            var resolved_payload = try self.resolveStreamExpr(in_binding.expr, current_input, outputs);
                            if (in_binding.where_filter) |wf| {
                                resolved_payload = try dataflow.predicate.filterPayload(self.allocator, resolved_payload, wf);
                            }
                            try bound_inputs_list.append(outputs_alloc, .{
                                .name = in_binding.param_name,
                                .payload = resolved_payload,
                            });
                            if (in_idx == 0) {
                                step_input = resolved_payload;
                            }
                        }
                    } else {
                        try bound_inputs_list.append(outputs_alloc, .{
                            .name = "stream",
                            .payload = current_input,
                        });
                    }

                    if (self.kernel) |k| {
                        k.telemetry.emit(.{
                            .step_start = .{
                                .trace_id = trace_id,
                                .span_id = step_span_id,
                                .parent_span_id = parent_span_id,
                                .timestamp_ns = step_start_ns,
                                .pipeline_name = name,
                                .step_id = task_spec.id,
                                .module_name = task_spec.module,
                                .task_name = task_spec.task,
                                .input_count = step_input.len,
                            },
                        });
                    }

                    // Apply step-level declarative predicate filter if configured
                    if (task_spec.where_filter) |filter_expr| {
                        step_input = try dataflow.predicate.filterPayload(self.allocator, step_input, filter_expr);
                    }

                    // Resolve task-scoped primary virtual network adapter via EngineNetworkController
                    const step_adapter = try net_ctrl.resolveStepAdapter(task_spec);
                    const records_before = step_adapter.capturedRecordsSlice().len;

                    // Resolve task descriptor from module registry
                    const desc = try self.modules.resolveTask(task_spec.module, task_spec.task);

                    const byte_count = step_input.len * step_input.element_size;
                    const input_bytes: []const u8 = if (byte_count > 0)
                        @as([*]const u8, @ptrCast(step_input.ptr))[0..byte_count]
                    else
                        &.{};

                    var step_net_ctx = StepNetworkContext{
                        .step_id = task_spec.id,
                        .task_name = task_spec.task,
                        .primary_adapter = step_adapter,
                        .net_ctrl = net_ctrl,
                    };

                    const workers: u32 = if (task_spec.concurrency) |c| @intCast(c) else @intCast(self.workers);
                    const outcome = modules_mod.executeTask(desc, .{
                        .allocator = outputs_alloc,
                        .input_payload = step_input,
                        .input_bytes = input_bytes,
                        .params = task_spec.static_params,
                        .workers = workers,
                        .net_bridge = step_net_ctx.bridge(),
                        .bound_inputs = bound_inputs_list.items,
                        .worker_pool = pool,
                    });

                    switch (outcome.status) {
                        .ok, .recoverable_warning => {},
                        .halt_pipeline => {
                            summary.halted_early = true;
                        },
                        .fatal_error => return error.TaskExecutionFailed,
                    }

                    const task_output = outcome.output;

                    if (self.kernel) |k| {
                        const step_end_ns: u64 = nowNs();
                        k.telemetry.emit(.{
                            .step_end = .{
                                .trace_id = trace_id,
                                .span_id = step_span_id,
                                .timestamp_ns = step_end_ns,
                                .duration_ns = step_end_ns - step_start_ns,
                                .pipeline_name = name,
                                .step_id = task_spec.id,
                                .status = if (outcome.status == .ok) "ok" else "warning",
                                .output_count = task_output.len,
                            },
                        });
                    }

                    // Route to declared output channels and datasources, capturing processed payload
                    var last_processed_output = task_output;

                    for (task_spec.outputs) |out_ch| {
                        var channel_payload = if (outcome.channel_outputs.get(out_ch.name)) |ch_pl|
                            ch_pl
                        else
                            task_output;

                        if (out_ch.from_field) |src_field| {
                            if (outcome.channel_outputs.get(src_field)) |ch_pl| {
                                channel_payload = ch_pl;
                            } else if (std.mem.eql(u8, src_field, "network.captured_events")) {
                                const new_events = try net_ctrl.collectStepEvents(task_spec.id, step_adapter, records_before);
                                channel_payload = PayloadHandle.fromSlice(NetworkEvent, new_events);
                            } else if (task_output.getReflected(src_field)) |rval| {
                                const dyn_fields = try self.allocator.alloc(dataflow.DynamicField, 1);
                                dyn_fields[0] = .{
                                    .name = try self.allocator.dupe(u8, src_field),
                                    .value = rval,
                                };
                                const dyn_record = try self.allocator.alloc(dataflow.DynamicRecord, 1);
                                dyn_record[0] = dataflow.DynamicRecord.init(dyn_fields);
                                channel_payload = PayloadHandle.fromSlice(dataflow.DynamicRecord, dyn_record);
                            }
                        }

                        // Apply channel-specific filter if present
                        if (out_ch.filter) |flt| {
                            channel_payload = try dataflow.predicate.filterPayload(self.allocator, channel_payload, flt);
                        }

                        // Write to repository
                        if (self.repos.get(out_ch.datasource)) |repo| {
                            try repo.writePayload(out_ch.name, channel_payload);
                        }

                        // Save channel output under channel name and scoped step_id.channel_name
                        try outputs.put(outputs_alloc, out_ch.name, channel_payload);
                        const scoped_name = try std.fmt.allocPrint(outputs_alloc, "{s}.{s}", .{ task_spec.id, out_ch.name });
                        try outputs.put(outputs_alloc, scoped_name, channel_payload);
                        last_processed_output = channel_payload;
                    }

                    // Store final processed output by task ID and update current_input
                    try outputs.put(outputs_alloc, task_spec.id, last_processed_output);
                    current_input = last_processed_output;

                    summary.steps_executed += 1;
                },

                .router => |router_spec| {
                    summary.routers_evaluated += 1;
                    var branched = false;
                    var matched_expr: ?[]const u8 = null;
                    var target_pipe: ?[]const u8 = null;

                    for (router_spec.cases) |case| {
                        var eval_handle = current_input;
                        if (extractCountRef(case.when_predicate)) |ref_name| {
                            if (outputs.get(ref_name)) |named_out| {
                                eval_handle = named_out;
                            }
                        }
                        const matched = dataflow.predicate.evaluatePredicateHandle(eval_handle, case.when_predicate);
                        if (matched) {
                            branched = true;
                            matched_expr = case.when_predicate;
                            target_pipe = case.goto_pipeline;
                            if (self.kernel) |k| {
                                var router_span_id: [8]u8 = undefined;
                                fillRandomBytes(&router_span_id);
                                k.telemetry.emit(.{
                                    .router_decision = .{
                                        .trace_id = trace_id,
                                        .span_id = router_span_id,
                                        .timestamp_ns = nowNs(),
                                        .pipeline_name = name,
                                        .router_id = router_spec.id,
                                        .matched_expression = matched_expr,
                                        .target_pipeline = target_pipe,
                                    },
                                });
                            }
                            if (std.mem.eql(u8, case.goto_pipeline, "continue")) {
                                break;
                            } else {
                                try self.executeSubPipeline(case.goto_pipeline, current_input, outputs, outputs_alloc, net_ctrl, summary, trace_id, parent_span_id, pool);
                                break;
                            }
                        }
                    }

                    if (!branched) {
                        if (router_spec.default_pipeline) |def_pipe| {
                            target_pipe = def_pipe;
                            if (self.kernel) |k| {
                                var router_span_id: [8]u8 = undefined;
                                fillRandomBytes(&router_span_id);
                                k.telemetry.emit(.{
                                    .router_decision = .{
                                        .trace_id = trace_id,
                                        .span_id = router_span_id,
                                        .timestamp_ns = nowNs(),
                                        .pipeline_name = name,
                                        .router_id = router_spec.id,
                                        .matched_expression = null,
                                        .target_pipeline = target_pipe,
                                    },
                                });
                            }
                            if (!std.mem.eql(u8, def_pipe, "continue")) {
                                try self.executeSubPipeline(def_pipe, current_input, outputs, outputs_alloc, net_ctrl, summary, trace_id, parent_span_id, pool);
                            }
                        }
                    }
                },
            }
        }
    }
};

pub fn extractCountRef(predicate_expr: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, predicate_expr, "count(") orelse return null;
    const after = predicate_expr[idx + "count(".len ..];
    const close = std.mem.indexOfScalar(u8, after, ')') orelse return null;
    const inner = std.mem.trim(u8, after[0..close], " \t");
    return if (inner.len > 0) inner else null;
}

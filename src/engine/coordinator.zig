//! Flowdata Concurrent DAG Coordinator (ARCH-017 §3.2, §3.3 & §3.8).
//!
//! Owns the single-threaded scheduling state (ready queue, in-degree counters, channel publication),
//! dispatches independent step jobs to the shared WorkerPool, processes completions via a thread-safe
//! MPSC completion queue, and guarantees deterministic failure reporting and clean cancellation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/ast.zig");
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const modules_mod = @import("../plugin/mod.zig");
const sync = @import("../concurrency/sync.zig");
const WorkerPool = @import("../concurrency/worker_pool.zig").WorkerPool;
const engine_mod = @import("engine.zig");
const PipelineEngine = engine_mod.PipelineEngine;
const ExecutionSummary = engine_mod.ExecutionSummary;
const StepNetworkContext = engine_mod.StepNetworkContext;
const EngineNetworkController = @import("network.zig").EngineNetworkController;
const NetworkEvent = @import("network.zig").NetworkEvent;
const NetworkAdapter = @import("../transport/outbound/mod.zig").NetworkAdapter;
const plan_mod = @import("plan.zig");
const ExecutionPlan = plan_mod.ExecutionPlan;
const NodeId = plan_mod.NodeId;
const ChannelId = plan_mod.ChannelId;

pub const StepArenaRecord = struct {
    arena: std.heap.ArenaAllocator,
    live_channels_count: usize,
    retained: bool = false,
};

pub const ChannelState = struct {
    id: ChannelId,
    name: []const u8,
    payload: PayloadHandle,
    ref_count: usize,
    retained: bool,
    byte_size: usize,
    arena_rec: ?*StepArenaRecord = null,
};

pub const StepCompletion = struct {
    node_id: NodeId,
    status: modules_mod.TaskOutcomeStatus,
    output: PayloadHandle,
    channel_outputs: std.StringHashMapUnmanaged(PayloadHandle),
    step_span_id: [8]u8,
    start_ns: u64,
    end_ns: u64,
    step_adapter: ?NetworkAdapter,
    records_before: usize,
    step_arena: ?std.heap.ArenaAllocator = null,
};

pub const CompletionQueue = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    items: std.ArrayListUnmanaged(StepCompletion) = .empty,

    pub fn deinit(self: *CompletionQueue, alloc: Allocator) void {
        self.mutex.lock();
        self.items.deinit(alloc);
        self.mutex.unlock();
        self.mutex.deinit();
        self.cond.deinit();
    }

    pub fn push(self: *CompletionQueue, alloc: Allocator, item: StepCompletion) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(alloc, item);
        self.cond.signal();
    }

    pub fn pop(self: *CompletionQueue) ?StepCompletion {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    pub fn waitAndPop(self: *CompletionQueue) StepCompletion {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.items.items.len == 0) {
            self.cond.wait(&self.mutex);
        }
        return self.items.orderedRemove(0);
    }
};

const StepJobContext = struct {
    coordinator: *Coordinator,
    node_id: NodeId,
    task_spec: ast.TaskStepSpec,
    step_input: PayloadHandle,
    input_bytes: []const u8,
    bound_inputs: []modules_mod.BoundInput,
    step_adapter: ?NetworkAdapter,
    records_before: usize,
    step_span_id: [8]u8,
    step_start_ns: u64,
    workers: u32,
};

pub const Coordinator = struct {
    engine: *PipelineEngine,
    plan: *const ExecutionPlan,
    active_input: PayloadHandle,
    outputs: *std.StringHashMapUnmanaged(PayloadHandle),
    outputs_alloc: Allocator,
    net_ctrl: *EngineNetworkController,
    summary: *ExecutionSummary,
    trace_id: [16]u8,
    parent_span_id: [8]u8,
    pool: *WorkerPool,
    pipeline_name: []const u8,

    indegrees: []usize,
    ready_queue: std.ArrayListUnmanaged(NodeId) = .empty,
    completion_queue: CompletionQueue = .{},
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    min_fail_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(std.math.maxInt(usize)),
    has_fatal_error: bool = false,
    in_flight: usize = 0,
    completed_nodes: usize = 0,
    current_input: PayloadHandle,
    active_mask: ?[]const bool = null,
    total_active: usize = 0,

    // ARCH-017 Phase 17.4: Memory Lifecycle & Channel Refcounting
    step_arenas: std.ArrayListUnmanaged(*StepArenaRecord) = .empty,
    channel_states: std.AutoHashMapUnmanaged(ChannelId, ChannelState) = .empty,
    channel_name_to_id: std.StringHashMapUnmanaged(ChannelId) = .empty,
    live_inflight_bytes: usize = 0,
    max_inflight_bytes: ?usize = null,
    retain_all: bool = false,

    pub fn deinit(self: *Coordinator) void {
        self.ready_queue.deinit(self.engine.allocator);
        self.completion_queue.deinit(self.engine.allocator);
        for (self.step_arenas.items) |ar| {
            ar.arena.deinit();
            self.engine.allocator.destroy(ar);
        }
        self.step_arenas.deinit(self.engine.allocator);
        self.channel_states.deinit(self.engine.allocator);
        self.channel_name_to_id.deinit(self.engine.allocator);
    }

    pub fn run(
        engine: *PipelineEngine,
        plan: *const ExecutionPlan,
        active_input: PayloadHandle,
        outputs: *std.StringHashMapUnmanaged(PayloadHandle),
        outputs_alloc: Allocator,
        net_ctrl: *EngineNetworkController,
        summary: *ExecutionSummary,
        trace_id: [16]u8,
        parent_span_id: [8]u8,
        pool: *WorkerPool,
    ) anyerror!void {
        return runSelective(engine, plan, null, active_input, outputs, outputs_alloc, net_ctrl, summary, trace_id, parent_span_id, pool);
    }

    pub fn runSelective(
        engine: *PipelineEngine,
        plan: *const ExecutionPlan,
        active_mask: ?[]const bool,
        active_input: PayloadHandle,
        outputs: *std.StringHashMapUnmanaged(PayloadHandle),
        outputs_alloc: Allocator,
        net_ctrl: *EngineNetworkController,
        summary: *ExecutionSummary,
        trace_id: [16]u8,
        parent_span_id: [8]u8,
        pool: *WorkerPool,
    ) anyerror!void {
        const nodes_count = plan.nodes.len;
        if (nodes_count == 0) return;

        var total_active: usize = 0;
        const indegrees = try engine.allocator.alloc(usize, nodes_count);
        defer engine.allocator.free(indegrees);

        for (plan.nodes, 0..) |n, i| {
            if (active_mask) |mask| {
                if (!mask[i]) {
                    indegrees[i] = std.math.maxInt(usize);
                    continue;
                }
                total_active += 1;
                var in_count: usize = 0;
                for (n.predecessors) |p| {
                    if (mask[p]) in_count += 1;
                }
                indegrees[i] = in_count;
            } else {
                indegrees[i] = n.indegree;
                total_active += 1;
            }
        }
        if (total_active == 0) return;

        var coord = Coordinator{
            .engine = engine,
            .plan = plan,
            .active_input = active_input,
            .outputs = outputs,
            .outputs_alloc = outputs_alloc,
            .net_ctrl = net_ctrl,
            .summary = summary,
            .trace_id = trace_id,
            .parent_span_id = parent_span_id,
            .pool = pool,
            .pipeline_name = plan.pipeline_name,
            .indegrees = indegrees,
            .current_input = active_input,
            .active_mask = active_mask,
            .total_active = total_active,
            .max_inflight_bytes = engine.ast.runtime.max_inflight_bytes,
            .retain_all = engine.ast.runtime.retain_all,
        };
        defer coord.deinit();

        for (plan.channels) |ch_slot| {
            try coord.channel_name_to_id.put(engine.allocator, ch_slot.name, ch_slot.id);
        }

        // Initialize ready queue with indegree == 0 nodes (in priority & declaration order)
        for (0..nodes_count) |i| {
            if (indegrees[i] == 0) {
                try coord.enqueueReady(i);
            }
        }

        // Coordinator Main Event Loop
        while (coord.completed_nodes < total_active) {
            // 1. Dispatch ready nodes respecting memory backpressure
            while (coord.ready_queue.items.len > 0 and !coord.has_fatal_error and !coord.summary.halted_early) {
                const next_node_id = coord.ready_queue.items[0];
                if (coord.shouldThrottle(next_node_id)) {
                    coord.summary.throttle_count += 1;
                    var found_consumer = false;
                    for (coord.ready_queue.items, 0..) |cand_id, idx| {
                        if (!coord.shouldThrottle(cand_id)) {
                            _ = coord.ready_queue.orderedRemove(idx);
                            const node = plan.nodes[cand_id];
                            if (node.isRouter()) {
                                try coord.executeRouter(node);
                            } else {
                                try coord.dispatchTask(cand_id);
                            }
                            found_consumer = true;
                            break;
                        }
                    }
                    if (!found_consumer) {
                        // All ready tasks are producers and memory budget is reached;
                        // wait for in-flight tasks to complete and release memory.
                        break;
                    }
                    continue;
                }

                const node_id = coord.ready_queue.orderedRemove(0);
                const node = plan.nodes[node_id];
                if (node.isRouter()) {
                    try coord.executeRouter(node);
                } else {
                    try coord.dispatchTask(node_id);
                }
            }

            if (coord.in_flight == 0) {
                // No tasks currently running in the worker pool
                break;
            }

            // 2. Wait for completion message from MPSC queue (with help-while-waiting)
            var maybe_comp = coord.completion_queue.pop();
            if (maybe_comp == null) {
                // Actively help execute any pending jobs from the pool
                if (coord.pool.popJob()) |job| {
                    job.run();
                } else {
                    maybe_comp = coord.completion_queue.waitAndPop();
                }
            }

            if (maybe_comp) |comp| {
                coord.in_flight -= 1;
                try coord.processCompletion(comp);
            }
        }

        if (coord.has_fatal_error) {
            return error.TaskExecutionFailed;
        }
    }

    fn shouldThrottle(self: *Coordinator, node_id: NodeId) bool {
        if (self.max_inflight_bytes) |budget| {
            if (self.live_inflight_bytes >= budget and self.in_flight > 0) {
                const node = self.plan.nodes[node_id];
                if (node.produced_channels.len > 0 and node.consumed_channels.len == 0) {
                    return true;
                }
            }
        }
        return false;
    }

    fn nodePriority(self: *const Coordinator, node_id: NodeId) u32 {
        const node = self.plan.nodes[node_id];
        var score: u32 = 0;
        // Prioritize nodes that consume channels so intermediate buffers are freed earlier
        if (node.consumed_channels.len > 0) {
            score += 1000;
            score += @min(999, @as(u32, @intCast(node.consumed_channels.len * 10)));
        }
        return score;
    }

    fn enqueueReady(self: *Coordinator, node_id: NodeId) !void {
        const priority = self.nodePriority(node_id);
        var insert_idx: usize = 0;
        while (insert_idx < self.ready_queue.items.len) : (insert_idx += 1) {
            const cand_id = self.ready_queue.items[insert_idx];
            const cand_priority = self.nodePriority(cand_id);
            if (priority > cand_priority) {
                break;
            } else if (priority == cand_priority and node_id < cand_id) {
                break;
            }
        }
        try self.ready_queue.insert(self.engine.allocator, insert_idx, node_id);
    }

    fn dispatchTask(self: *Coordinator, node_id: NodeId) !void {
        const node = self.plan.nodes[node_id];
        const task_spec = node.step.task;

        var step_span_id: [8]u8 = undefined;
        engine_mod.fillRandomBytes(&step_span_id);
        const step_start_ns: u64 = engine_mod.nowNs();

        var step_input = self.current_input;
        var bound_inputs_list: std.ArrayListUnmanaged(modules_mod.BoundInput) = .empty;

        if (task_spec.inputs.len > 0) {
            for (task_spec.inputs) |in_binding| {
                var resolved_payload = try self.engine.resolveStreamExpr(in_binding.expr, self.current_input, self.outputs);
                if (in_binding.where_filter) |wf| {
                    resolved_payload = try dataflow.predicate.filterPayload(self.engine.allocator, resolved_payload, wf);
                    if (resolved_payload.len == 0) {
                        // ARCH-018: Short-circuit rejection: unary where: condition not met.
                        self.completion_queue.push(self.engine.allocator, .{
                            .node_id = node_id,
                            .status = .ok,
                            .output = PayloadHandle.empty(),
                            .channel_outputs = .empty,
                            .step_span_id = step_span_id,
                            .start_ns = step_start_ns,
                            .end_ns = engine_mod.nowNs(),
                            .step_adapter = null,
                            .records_before = 0,
                            .step_arena = null,
                        }) catch {};
                        return;
                    }
                }
                try bound_inputs_list.append(self.engine.allocator, .{
                    .name = in_binding.param_name,
                    .payload = resolved_payload,
                });
                if (std.mem.eql(u8, in_binding.param_name, "primary") or std.mem.eql(u8, in_binding.param_name, "stream")) {
                    step_input = resolved_payload;
                }
            }
        }

        try bound_inputs_list.append(self.engine.allocator, .{
            .name = "stream",
            .payload = self.current_input,
        });
        try bound_inputs_list.append(self.engine.allocator, .{
            .name = "input",
            .payload = self.current_input,
        });

        // Innate ambient merge (ARCH-018 §3.2)
        if (try self.engine.ambient.asPayload(self.engine.allocator, "system.timestamp")) |ts_p| {
            try bound_inputs_list.append(self.engine.allocator, .{ .name = "system.timestamp", .payload = ts_p });
            try bound_inputs_list.append(self.engine.allocator, .{ .name = "timestamp", .payload = ts_p });
        }
        if (try self.engine.ambient.asPayload(self.engine.allocator, "system.hour")) |hr_p| {
            try bound_inputs_list.append(self.engine.allocator, .{ .name = "system.hour", .payload = hr_p });
            try bound_inputs_list.append(self.engine.allocator, .{ .name = "hour", .payload = hr_p });
        }
        if (try self.engine.ambient.asPayload(self.engine.allocator, "system.cpu_load")) |cpu_p| {
            try bound_inputs_list.append(self.engine.allocator, .{ .name = "system.cpu_load", .payload = cpu_p });
            try bound_inputs_list.append(self.engine.allocator, .{ .name = "cpu_load", .payload = cpu_p });
            try bound_inputs_list.append(self.engine.allocator, .{ .name = "cpu_usage", .payload = cpu_p });
        }

        if (self.engine.kernel) |k| {
            k.telemetry.emit(.{
                .step_start = .{
                    .trace_id = self.trace_id,
                    .span_id = step_span_id,
                    .parent_span_id = self.parent_span_id,
                    .timestamp_ns = step_start_ns,
                    .pipeline_name = self.pipeline_name,
                    .step_id = task_spec.id,
                    .module_name = task_spec.module,
                    .task_name = task_spec.task,
                    .input_count = step_input.len,
                },
            });
        }

        if (task_spec.where_filter) |filter_expr| {
            step_input = try dataflow.predicate.filterPayload(self.engine.allocator, step_input, filter_expr);
        }

        const step_adapter = try self.net_ctrl.resolveStepAdapter(task_spec);
        const records_before = step_adapter.capturedRecordsSlice().len;

        const byte_count = step_input.len * step_input.element_size;
        const input_bytes: []const u8 = if (byte_count > 0)
            @as([*]const u8, @ptrCast(step_input.ptr))[0..byte_count]
        else
            &.{};

        const workers: u32 = if (task_spec.concurrency) |c| @intCast(c) else @intCast(self.engine.workers);

        const owned_bound_inputs = try bound_inputs_list.toOwnedSlice(self.engine.allocator);
        errdefer self.engine.allocator.free(owned_bound_inputs);

        const job_ctx = try self.engine.allocator.create(StepJobContext);
        job_ctx.* = .{
            .coordinator = self,
            .node_id = node_id,
            .task_spec = task_spec,
            .step_input = step_input,
            .input_bytes = input_bytes,
            .bound_inputs = owned_bound_inputs,
            .step_adapter = step_adapter,
            .records_before = records_before,
            .step_span_id = step_span_id,
            .step_start_ns = step_start_ns,
            .workers = workers,
        };

        self.in_flight += 1;

        try self.pool.submit(.{
            .run_fn = &workerRun,
            .ctx = job_ctx,
        });
    }

    fn workerRun(raw_ctx: *anyopaque) void {
        const job_ctx: *StepJobContext = @ptrCast(@alignCast(raw_ctx));
        defer {
            if (job_ctx.bound_inputs.len > 0) {
                job_ctx.coordinator.engine.allocator.free(job_ctx.bound_inputs);
            }
            job_ctx.coordinator.engine.allocator.destroy(job_ctx);
        }

        const coord = job_ctx.coordinator;
        if (coord.cancel_flag.load(.acquire)) {
            coord.completion_queue.push(coord.engine.allocator, .{
                .node_id = job_ctx.node_id,
                .status = .fatal_error,
                .output = PayloadHandle.empty(),
                .channel_outputs = .empty,
                .step_span_id = job_ctx.step_span_id,
                .start_ns = job_ctx.step_start_ns,
                .end_ns = engine_mod.nowNs(),
                .step_adapter = job_ctx.step_adapter,
                .records_before = job_ctx.records_before,
                .step_arena = null,
            }) catch {};
            return;
        }

        var step_arena = std.heap.ArenaAllocator.init(coord.engine.allocator);
        const step_alloc = step_arena.allocator();

        const desc = coord.engine.modules.resolveTask(job_ctx.task_spec.module, job_ctx.task_spec.task) catch {
            coord.cancel_flag.store(true, .release);
            coord.completion_queue.push(coord.engine.allocator, .{
                .node_id = job_ctx.node_id,
                .status = .fatal_error,
                .output = PayloadHandle.empty(),
                .channel_outputs = .empty,
                .step_span_id = job_ctx.step_span_id,
                .start_ns = job_ctx.step_start_ns,
                .end_ns = engine_mod.nowNs(),
                .step_adapter = job_ctx.step_adapter,
                .records_before = job_ctx.records_before,
                .step_arena = step_arena,
            }) catch {
                step_arena.deinit();
            };
            return;
        };

        var step_net_ctx = StepNetworkContext{
            .step_id = job_ctx.task_spec.id,
            .task_name = job_ctx.task_spec.task,
            .primary_adapter = job_ctx.step_adapter,
            .net_ctrl = coord.net_ctrl,
        };

        const outcome = modules_mod.executeTask(desc, .{
            .allocator = step_alloc,
            .input_payload = job_ctx.step_input,
            .input_bytes = job_ctx.input_bytes,
            .params = job_ctx.task_spec.static_params,
            .workers = job_ctx.workers,
            .net_bridge = step_net_ctx.bridge(),
            .bound_inputs = job_ctx.bound_inputs,
            .worker_pool = coord.pool,
        });

        const end_ns = engine_mod.nowNs();

        coord.completion_queue.push(coord.engine.allocator, .{
            .node_id = job_ctx.node_id,
            .status = outcome.status,
            .output = outcome.output,
            .channel_outputs = outcome.channel_outputs,
            .step_span_id = job_ctx.step_span_id,
            .start_ns = job_ctx.step_start_ns,
            .end_ns = end_ns,
            .step_adapter = job_ctx.step_adapter,
            .records_before = job_ctx.records_before,
            .step_arena = step_arena,
        }) catch {
            step_arena.deinit();
        };
    }

    fn freeArena(self: *Coordinator, ar: *StepArenaRecord) void {
        for (self.step_arenas.items, 0..) |item, idx| {
            if (item == ar) {
                _ = self.step_arenas.orderedRemove(idx);
                ar.arena.deinit();
                self.engine.allocator.destroy(ar);
                self.summary.arenas_freed_early += 1;
                break;
            }
        }
    }

    fn processCompletion(self: *Coordinator, comp: StepCompletion) !void {
        const node = self.plan.nodes[comp.node_id];
        const task_spec = node.step.task;

        if (self.engine.kernel) |k| {
            k.telemetry.emit(.{
                .step_end = .{
                    .trace_id = self.trace_id,
                    .span_id = comp.step_span_id,
                    .timestamp_ns = comp.end_ns,
                    .duration_ns = comp.end_ns - comp.start_ns,
                    .pipeline_name = self.pipeline_name,
                    .step_id = task_spec.id,
                    .status = if (comp.status == .ok) "ok" else "warning",
                    .output_count = comp.output.len,
                },
            });
        }

        switch (comp.status) {
            .ok, .recoverable_warning => {},
            .halt_pipeline => {
                self.summary.halted_early = true;
            },
            .fatal_error => {
                self.cancel_flag.store(true, .release);
                while (true) {
                    const cur = self.min_fail_idx.load(.acquire);
                    if (comp.node_id >= cur) break;
                    if (self.min_fail_idx.cmpxchgWeak(cur, comp.node_id, .acq_rel, .acquire) == null) break;
                }
                self.has_fatal_error = true;
            },
        }

        if (comp.status == .fatal_error) {
            if (comp.step_arena) |*st_arena| {
                st_arena.deinit();
            }
        }

        if (comp.status != .fatal_error) {
            var maybe_arena_rec: ?*StepArenaRecord = null;
            if (comp.step_arena) |st_arena| {
                const ar = try self.engine.allocator.create(StepArenaRecord);
                ar.* = .{
                    .arena = st_arena,
                    .live_channels_count = 0,
                    .retained = self.retain_all,
                };
                try self.step_arenas.append(self.engine.allocator, ar);
                maybe_arena_rec = ar;
                self.summary.arenas_created += 1;
            }

            var last_processed_output = comp.output;

            for (task_spec.outputs) |out_ch| {
                var channel_payload = if (comp.channel_outputs.get(out_ch.name)) |ch_pl|
                    ch_pl
                else
                    comp.output;

                if (out_ch.from_field) |src_field| {
                    if (comp.channel_outputs.get(src_field)) |ch_pl| {
                        channel_payload = ch_pl;
                    } else if (std.mem.eql(u8, src_field, "network.captured_events")) {
                        if (comp.step_adapter) |sa| {
                            const new_events = try self.net_ctrl.collectStepEvents(task_spec.id, sa, comp.records_before);
                            channel_payload = PayloadHandle.fromSlice(NetworkEvent, new_events);
                        }
                    } else if (comp.output.getReflected(src_field)) |rval| {
                        const dyn_fields = try self.engine.allocator.alloc(dataflow.DynamicField, 1);
                        dyn_fields[0] = .{
                            .name = try self.engine.allocator.dupe(u8, src_field),
                            .value = rval,
                        };
                        const dyn_record = try self.engine.allocator.alloc(dataflow.DynamicRecord, 1);
                        dyn_record[0] = dataflow.DynamicRecord.init(dyn_fields);
                        channel_payload = PayloadHandle.fromSlice(dataflow.DynamicRecord, dyn_record);
                    }
                }

                if (out_ch.filter) |flt| {
                    channel_payload = try dataflow.predicate.filterPayload(self.engine.allocator, channel_payload, flt);
                }

                if (self.engine.repos.get(out_ch.datasource)) |repo| {
                    repo.writePayload(out_ch.name, channel_payload) catch |err| {
                        std.log.err("[Coordinator Step '{s}'] Failed to write channel '{s}' to datasource '{s}': {s}", .{
                            task_spec.id,
                            out_ch.name,
                            out_ch.datasource,
                            @errorName(err),
                        });
                        return err;
                    };
                }

                try self.outputs.put(self.outputs_alloc, out_ch.name, channel_payload);
                const scoped_name = try std.fmt.allocPrint(self.outputs_alloc, "{s}.{s}", .{ task_spec.id, out_ch.name });
                try self.outputs.put(self.outputs_alloc, scoped_name, channel_payload);
                last_processed_output = channel_payload;

                // ARCH-017 §3.5: Channel Refcounting & Lifetime Tracking
                const ch_byte_size = channel_payload.len * channel_payload.element_size;
                self.live_inflight_bytes += ch_byte_size;
                if (self.live_inflight_bytes > self.summary.peak_inflight_bytes) {
                    self.summary.peak_inflight_bytes = self.live_inflight_bytes;
                }

                var consumers_count: usize = 0;
                var ch_id_opt: ?ChannelId = null;

                if (self.channel_name_to_id.get(out_ch.name)) |cid| {
                    ch_id_opt = cid;
                    consumers_count = self.plan.channels[cid].consumers_count;
                } else if (self.channel_name_to_id.get(scoped_name)) |cid| {
                    ch_id_opt = cid;
                    consumers_count = self.plan.channels[cid].consumers_count;
                }

                const is_retained = out_ch.retain or self.retain_all or std.mem.eql(u8, out_ch.datasource, "pipeline_memory") or (node.successors.len == 0);
                if (is_retained and maybe_arena_rec != null) {
                    maybe_arena_rec.?.retained = true;
                }

                if (maybe_arena_rec) |ar| {
                    ar.live_channels_count += 1;
                }

                if (ch_id_opt) |cid| {
                    try self.channel_states.put(self.engine.allocator, cid, .{
                        .id = cid,
                        .name = out_ch.name,
                        .payload = channel_payload,
                        .ref_count = consumers_count,
                        .retained = is_retained,
                        .byte_size = ch_byte_size,
                        .arena_rec = maybe_arena_rec,
                    });

                    if (consumers_count == 0 and !is_retained) {
                        if (self.live_inflight_bytes >= ch_byte_size) {
                            self.live_inflight_bytes -= ch_byte_size;
                        } else {
                            self.live_inflight_bytes = 0;
                        }
                        if (maybe_arena_rec) |ar| {
                            ar.live_channels_count -= 1;
                            if (ar.live_channels_count == 0 and !ar.retained) {
                                self.freeArena(ar);
                            }
                        }
                    }
                }
            }

            if (task_spec.outputs.len == 0) {
                const ch_name = task_spec.id;
                const ch_byte_size = last_processed_output.len * last_processed_output.element_size;
                self.live_inflight_bytes += ch_byte_size;
                if (self.live_inflight_bytes > self.summary.peak_inflight_bytes) {
                    self.summary.peak_inflight_bytes = self.live_inflight_bytes;
                }

                var consumers_count: usize = 0;
                const is_retained = self.retain_all or (node.successors.len == 0);
                if (is_retained and maybe_arena_rec != null) {
                    maybe_arena_rec.?.retained = true;
                }

                if (self.channel_name_to_id.get(ch_name)) |cid| {
                    consumers_count = self.plan.channels[cid].consumers_count;
                    if (maybe_arena_rec) |ar| {
                        ar.live_channels_count += 1;
                    }
                    try self.channel_states.put(self.engine.allocator, cid, .{
                        .id = cid,
                        .name = ch_name,
                        .payload = last_processed_output,
                        .ref_count = consumers_count,
                        .retained = is_retained,
                        .byte_size = ch_byte_size,
                        .arena_rec = maybe_arena_rec,
                    });
                    if (consumers_count == 0 and !is_retained) {
                        if (self.live_inflight_bytes >= ch_byte_size) {
                            self.live_inflight_bytes -= ch_byte_size;
                        } else {
                            self.live_inflight_bytes = 0;
                        }
                        if (maybe_arena_rec) |ar| {
                            ar.live_channels_count -= 1;
                            if (ar.live_channels_count == 0 and !ar.retained) {
                                self.freeArena(ar);
                            }
                        }
                    }
                }
            }

            try self.outputs.put(self.outputs_alloc, task_spec.id, last_processed_output);
            self.current_input = last_processed_output;
            self.summary.steps_executed += 1;

            // Decrement refcount of channels consumed by this node
            for (node.consumed_channels) |ch_id| {
                if (self.channel_states.getPtr(ch_id)) |ch_st| {
                    if (ch_st.ref_count > 0) {
                        ch_st.ref_count -= 1;
                        if (ch_st.ref_count == 0 and !ch_st.retained) {
                            if (self.live_inflight_bytes >= ch_st.byte_size) {
                                self.live_inflight_bytes -= ch_st.byte_size;
                            } else {
                                self.live_inflight_bytes = 0;
                            }
                            if (ch_st.arena_rec) |ar| {
                                if (ar.live_channels_count > 0) {
                                    ar.live_channels_count -= 1;
                                    if (ar.live_channels_count == 0 and !ar.retained) {
                                        self.freeArena(ar);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Decrement successors' indegree and unlock ready nodes
            for (node.successors) |succ_id| {
                if (self.active_mask) |mask| {
                    if (!mask[succ_id]) continue;
                }
                self.indegrees[succ_id] -= 1;
                if (self.indegrees[succ_id] == 0) {
                    try self.enqueueReady(succ_id);
                }
            }
        }

        self.completed_nodes += 1;
    }

    fn executeRouter(self: *Coordinator, node: plan_mod.PlanNode) !void {
        const router_spec = node.step.router;
        self.summary.routers_evaluated += 1;
        var branched = false;
        var matched_expr: ?[]const u8 = null;
        var target_pipe: ?[]const u8 = null;

        for (router_spec.cases) |case| {
            var eval_handle = self.current_input;
            if (engine_mod.extractCountRef(case.when_predicate)) |ref_name| {
                if (self.outputs.get(ref_name)) |named_out| {
                    eval_handle = named_out;
                }
            }
            const matched = dataflow.predicate.evaluatePredicateHandle(eval_handle, case.when_predicate);
            if (matched) {
                branched = true;
                matched_expr = case.when_predicate;
                target_pipe = case.goto_pipeline;
                if (self.engine.kernel) |k| {
                    var router_span_id: [8]u8 = undefined;
                    engine_mod.fillRandomBytes(&router_span_id);
                    k.telemetry.emit(.{
                        .router_decision = .{
                            .trace_id = self.trace_id,
                            .span_id = router_span_id,
                            .timestamp_ns = engine_mod.nowNs(),
                            .pipeline_name = self.pipeline_name,
                            .router_id = router_spec.id,
                            .matched_expression = matched_expr,
                            .target_pipeline = target_pipe,
                        },
                    });
                }
                if (std.mem.eql(u8, case.goto_pipeline, "continue")) {
                    break;
                } else {
                    try self.engine.executeSubPipeline(case.goto_pipeline, self.current_input, self.outputs, self.outputs_alloc, self.net_ctrl, self.summary, self.trace_id, self.parent_span_id, self.pool);
                    break;
                }
            }
        }

        if (!branched) {
            if (router_spec.default_pipeline) |def_pipe| {
                target_pipe = def_pipe;
                if (self.engine.kernel) |k| {
                    var router_span_id: [8]u8 = undefined;
                    engine_mod.fillRandomBytes(&router_span_id);
                    k.telemetry.emit(.{
                        .router_decision = .{
                            .trace_id = self.trace_id,
                            .span_id = router_span_id,
                            .timestamp_ns = engine_mod.nowNs(),
                            .pipeline_name = self.pipeline_name,
                            .router_id = router_spec.id,
                            .matched_expression = null,
                            .target_pipeline = target_pipe,
                        },
                    });
                }
                if (!std.mem.eql(u8, def_pipe, "continue")) {
                    try self.engine.executeSubPipeline(def_pipe, self.current_input, self.outputs, self.outputs_alloc, self.net_ctrl, self.summary, self.trace_id, self.parent_span_id, self.pool);
                }
            }
        }

        // Router completes: decrement refcount of any channels it consumed
        for (node.consumed_channels) |ch_id| {
            if (self.channel_states.getPtr(ch_id)) |ch_st| {
                if (ch_st.ref_count > 0) {
                    ch_st.ref_count -= 1;
                    if (ch_st.ref_count == 0 and !ch_st.retained) {
                        if (self.live_inflight_bytes >= ch_st.byte_size) {
                            self.live_inflight_bytes -= ch_st.byte_size;
                        } else {
                            self.live_inflight_bytes = 0;
                        }
                        if (ch_st.arena_rec) |ar| {
                            if (ar.live_channels_count > 0) {
                                ar.live_channels_count -= 1;
                                if (ar.live_channels_count == 0 and !ar.retained) {
                                    self.freeArena(ar);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Router complete: unlock successors
        for (node.successors) |succ_id| {
            self.indegrees[succ_id] -= 1;
            if (self.indegrees[succ_id] == 0) {
                try self.enqueueReady(succ_id);
            }
        }

        self.completed_nodes += 1;
    }
};

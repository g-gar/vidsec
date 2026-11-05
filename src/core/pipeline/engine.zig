const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("vidsec_abi");
const dataflow = @import("vidsec_dataflow");
const ast_mod = @import("ast.zig");
const loader_mod = @import("loader/mod.zig");
const repository_mod = @import("repository/mod.zig");
const tracer_mod = @import("tracer.zig");

pub const PipelineAST = ast_mod.PipelineAST;
pub const ModuleRegistry = loader_mod.ModuleRegistry;
pub const RepositoryRegistry = repository_mod.RepositoryRegistry;
pub const PayloadHandle = dataflow.PayloadHandle;
pub const TaskDescriptor_ABI = abi.TaskDescriptor_ABI;

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

/// Modern Black Box Native Zig Pipeline Execution Engine.
/// Consumes format-agnostic PipelineAST, executes pure tasks via C-ABI,
/// evaluates RAM predicates zero-copy, and routes payloads to polymorphic repositories.
pub const PipelineEngine = struct {
    allocator: Allocator,
    ast: PipelineAST,
    modules: *ModuleRegistry,
    repos: *RepositoryRegistry,
    workers: usize = 1,

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
            .workers = w,
        };
    }

    pub fn run(self: *PipelineEngine, input_payload: PayloadHandle) anyerror!ExecutionSummary {
        var summary = ExecutionSummary{};

        // 1. Resolve or instantiate all declared datasources
        for (self.ast.datasources) |ds_spec| {
            _ = try self.repos.resolveOrCreate(ds_spec);
        }

        // 2. Track intermediate step outputs by step ID
        var outputs: std.StringHashMapUnmanaged(PayloadHandle) = .empty;
        defer outputs.deinit(self.allocator);

        // 3. Execute main pipeline
        try self.executeSubPipeline("main", input_payload, &outputs, &summary);

        return summary;
    }

    fn executeSubPipeline(
        self: *PipelineEngine,
        name: []const u8,
        active_input: PayloadHandle,
        outputs: *std.StringHashMapUnmanaged(PayloadHandle),
        summary: *ExecutionSummary,
    ) anyerror!void {
        const pipe = self.ast.getPipeline(name) orelse return error.UnknownSubPipeline;
        summary.final_pipeline = name;

        var current_input = active_input;

        for (pipe.steps) |step| {
            if (summary.halted_early) break;

            switch (step) {
                .task => |task_spec| {
                    // Resolve input stream
                    var step_input = current_input;
                    if (task_spec.inputs.len == 1) {
                        const in_expr = task_spec.inputs[0].expr;
                        if (in_expr.stream_ref) |ref| {
                            if (!std.mem.eql(u8, ref, "stream") and !std.mem.eql(u8, ref, "file")) {
                                if (outputs.get(ref)) |prev_out| {
                                    step_input = prev_out;
                                }
                            }
                        }
                    }

                    // Resolve task descriptor from module registry
                    const desc = try self.modules.resolveTask(task_spec.module, task_spec.task);

                    var task_output: PayloadHandle = undefined;

                    if (desc.execute_blackbox) |bb_fn| {
                        const mem = abi.MemContext_ABI.fromAllocator(&self.allocator);
                        const in_abi = abi.PayloadHandle_ABI{
                            .ptr = step_input.ptr,
                            .len = step_input.len,
                            .element_size = step_input.element_size,
                            .element_align = step_input.element_align,
                            .is_stream = step_input.is_stream,
                        };

                        const workers: u32 = if (task_spec.concurrency) |c| @intCast(c) else @intCast(self.workers);
                        const options = abi.ExecutionOptions_ABI{
                            .workers = workers,
                        };

                        const res = bb_fn(&mem, in_abi, options);
                        switch (res.status) {
                            .ok => {},
                            .recoverable_warning => {},
                            .halt_pipeline => {
                                summary.halted_early = true;
                            },
                            .fatal_error => return error.TaskExecutionFailed,
                        }

                        task_output = .{
                            .ptr = res.payload.ptr orelse &{},
                            .len = res.payload.len,
                            .element_size = res.payload.element_size,
                            .element_align = @truncate(res.payload.element_align),
                            .is_stream = res.payload.is_stream,
                            .type_name = step_input.type_name,
                            .reflect_abi_fn = res.payload.reflect_fn,
                        };
                    } else {
                        return error.TaskExecutionFailed;
                    }

                    // Store output
                    try outputs.put(self.allocator, task_spec.id, task_output);
                    current_input = task_output;

                    // Route to declared output datasources
                    for (task_spec.outputs) |out_ch| {
                        if (self.repos.get(out_ch.datasource)) |repo| {
                            try repo.writePayload(out_ch.name, task_output);
                        }
                    }

                    summary.steps_executed += 1;
                },

                .router => |router_spec| {
                    summary.routers_evaluated += 1;
                    var branched = false;

                    for (router_spec.cases) |case| {
                        const matched = dataflow.predicate.evaluatePredicateHandle(current_input, case.when_predicate);
                        if (matched) {
                            branched = true;
                            if (std.mem.eql(u8, case.goto_pipeline, "continue")) {
                                break;
                            } else {
                                try self.executeSubPipeline(case.goto_pipeline, current_input, outputs, summary);
                                break;
                            }
                        }
                    }

                    if (!branched) {
                        if (router_spec.default_pipeline) |def_pipe| {
                            if (!std.mem.eql(u8, def_pipe, "continue")) {
                                try self.executeSubPipeline(def_pipe, current_input, outputs, summary);
                            }
                        }
                    }
                },
            }
        }
    }
};

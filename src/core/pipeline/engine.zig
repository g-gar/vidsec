const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("vidsec_abi");
const yaml_core = @import("../yaml/mod.zig");
const sqlite_core = @import("../sqlite/mod.zig");
const artifact_mod = @import("artifact.zig");
const tracer_mod = @import("tracer.zig");
const host_context_mod = @import("host_context.zig");

pub const PipelineConfig = yaml_core.PipelineConfig;
pub const SchemaCatalog = yaml_core.SchemaCatalog;
pub const TaskTarget = yaml_core.TaskTarget;
pub const ModuleRegistry = abi.ModuleRegistry;
pub const TaskDescriptor_ABI = abi.TaskDescriptor_ABI;
pub const TaskStatus_ABI = abi.TaskStatus_ABI;
pub const SqliteRuntime = sqlite_core.SqliteRuntime;
pub const ArtifactStore = artifact_mod.ArtifactStore;
pub const ExecutionTracer = tracer_mod.ExecutionTracer;
pub const DebugController = tracer_mod.DebugController;
pub const HostExecutionContext = host_context_mod.HostExecutionContext;

pub const EngineError = error{
    MissingRequiredTaskParam,
    UndeclaredPluginOutputField,
    TaskFatalError,
    AbortedByDebugger,
    OutOfMemory,
} || sqlite_core.RuntimeError || abi.LoaderError || artifact_mod.ArtifactError;

/// Summary metrics returned after a pipeline run completes or halts.
pub const ExecutionSummary = struct {
    steps_executed: usize = 0,
    routers_evaluated: usize = 0,
    total_rows_emitted: usize = 0,
    halted_early: bool = false,
    final_pipeline: []const u8 = "main",
};

/// Core `vidsec v2` Pipeline Execution Engine.
/// Coordinates pre-flight validation (YAML + SQLite DDL/DML + Plugin C-ABI manifests),
/// per-step `SAVEPOINT` transactions, lazy C-ABI cursors, routers, and structured JSON tracing.
pub const PipelineEngine = struct {
    allocator: Allocator,
    config: *const PipelineConfig,
    catalog: *const SchemaCatalog,
    registry: *ModuleRegistry,
    db_runtime: *SqliteRuntime,
    tracer: ExecutionTracer,
    debug_controller: DebugController = .{},

    pub fn init(
        allocator: Allocator,
        config: *const PipelineConfig,
        catalog: *const SchemaCatalog,
        registry: *ModuleRegistry,
        db_runtime: *SqliteRuntime,
    ) PipelineEngine {
        return .{
            .allocator = allocator,
            .config = config,
            .catalog = catalog,
            .registry = registry,
            .db_runtime = db_runtime,
            .tracer = ExecutionTracer.init(allocator),
        };
    }

    pub fn deinit(self: *PipelineEngine) void {
        self.tracer.deinit();
    }

    /// Dynamically loads all `.so` modules declared in `config.modules` that are not already registered
    /// in `self.registry` (enforcing `stat` permission checks and `VIDSEC_ABI_VERSION` verification).
    pub fn loadConfiguredModules(self: *PipelineEngine) abi.LoaderError!void {
        for (self.config.modules.entries) |mod_entry| {
            const alias = mod_entry.key;
            const decl = mod_entry.value;
            if (self.registry.getModule(alias) == null) {
                _ = try self.registry.loadSharedLibrary(alias, decl.path);
            }
        }
    }

    /// Resolves a `TaskTarget` (`use: <module>` or `use: <module>/<task>`) against `ModuleRegistry`.
    pub fn resolveTaskDescriptor(
        self: *const PipelineEngine,
        target: TaskTarget,
    ) abi.LoaderError!*const TaskDescriptor_ABI {
        return switch (target) {
            .sql_rule => unreachable,
            .module_default => |mod_name| self.registry.resolveTask(mod_name, null),
            .module_task => |mt| self.registry.resolveTask(mt.module, mt.task),
        };
    }

    /// Performs full pre-flight validation across:
    /// 1. `PipelineConfig` + `SchemaCatalog` + `SqliteRuntime` (read-only queries, `sql_rule` projections, `router` `when` clauses, output mutations).
    /// 2. `ModuleRegistry` + `TaskDescriptor_ABI` (existence of every referenced module/task, required task `params`, and declared `output_fields` in `output.map`).
    pub fn preflightValidate(self: *PipelineEngine) EngineError!void {
        try self.db_runtime.preflightValidatePipeline(self.allocator, self.config);

        for (self.config.pipelines.entries) |sub_entry| {
            for (sub_entry.value.steps) |step| {
                switch (step) {
                    .router => {},
                    .task => |t_step| {
                        if (t_step.target == .sql_rule) continue;

                        const task_desc = try self.resolveTaskDescriptor(t_step.target);

                        // 1. Verify all required parameters declared by the plugin task exist in `params:`
                        for (task_desc.requiredParams()) |req_param_z| {
                            const req_name = std.mem.span(req_param_z);
                            if (t_step.getParam(req_name) == null) {
                                return error.MissingRequiredTaskParam;
                            }
                        }

                        // 2. Verify all plugin fields referenced in `output.map` or `output.fields` are declared by the plugin task
                        if (t_step.output) |out_spec| {
                            if (out_spec.target()) |out_target| {
                                switch (out_target) {
                                    .schema_domain => {},
                                    .into_table => |into_tbl| {
                                        if (into_tbl.map) |mappings| {
                                            for (mappings.entries) |m| {
                                                switch (m.value) {
                                                    .constant_literal => {},
                                                    .plugin_field => |pf| {
                                                        if (!task_desc.declaresOutputField(pf)) {
                                                            return error.UndeclaredPluginOutputField;
                                                        }
                                                    },
                                                }
                                            }
                                        } else if (into_tbl.fields) |field_list| {
                                            for (field_list) |pf| {
                                                if (!task_desc.declaresOutputField(pf)) {
                                                    return error.UndeclaredPluginOutputField;
                                                }
                                            }
                                        }
                                    },
                                }
                            }
                        }
                    },
                }
            }
        }
    }

    /// Executes the pipeline starting at sub-pipeline `"main"` against `artifacts`.
    pub fn run(self: *PipelineEngine, artifacts: *ArtifactStore) EngineError!ExecutionSummary {
        return self.runFrom(artifacts, "main");
    }

    /// Executes the pipeline starting at `start_pipeline` against `artifacts`.
    pub fn runFrom(
        self: *PipelineEngine,
        artifacts: *ArtifactStore,
        start_pipeline: []const u8,
    ) EngineError!ExecutionSummary {
        var summary = ExecutionSummary{};
        var current_pipeline_name: []const u8 = start_pipeline;

        pipeline_loop: while (true) {
            summary.final_pipeline = current_pipeline_name;
            const sub = self.config.pipelines.get(current_pipeline_name) orelse
                return error.UnknownTargetSubPipeline;

            for (sub.steps) |*step| {
                switch (step.*) {
                    .task => |*t_step| {
                        const seq = try self.tracer.recordStepStart(current_pipeline_name, t_step.name);

                        if (t_step.target == .sql_rule) {
                            const out_into = t_step.output.?.target().?.into_table;
                            const inserted = try self.db_runtime.executeSqlRule(
                                self.allocator,
                                t_step.name,
                                t_step.query.?,
                                out_into,
                            );

                            try self.tracer.recordStepEnd(
                                seq,
                                current_pipeline_name,
                                t_step.name,
                                .ok,
                                0,
                                0,
                                inserted,
                            );

                            summary.steps_executed += 1;
                            summary.total_rows_emitted += inserted;

                            if (self.debug_controller.notifyAfterStep(current_pipeline_name, t_step.name) == .abort_run) {
                                return error.AbortedByDebugger;
                            }
                        } else {
                            const task_desc = try self.resolveTaskDescriptor(t_step.target);

                            var sp = try self.db_runtime.savepoint(t_step.name);
                            errdefer sp.rollback();

                            var host_ctx = try HostExecutionContext.init(
                                self.allocator,
                                current_pipeline_name,
                                seq,
                                t_step,
                                self.db_runtime,
                                artifacts,
                                &self.tracer,
                            );
                            defer host_ctx.deinit();

                            var abi_ctx = host_ctx.toAbiContext();
                            const status = task_desc.execute(&abi_ctx);

                            if (status == .fatal_error or host_ctx.had_db_error) {
                                sp.rollback();
                                try self.tracer.recordStepEnd(
                                    seq,
                                    current_pipeline_name,
                                    t_step.name,
                                    .fatal_error,
                                    host_ctx.windows_read,
                                    host_ctx.rows_read,
                                    host_ctx.rows_emitted,
                                );
                                return error.TaskFatalError;
                            }

                            try host_ctx.commitStagedArtifact();
                            try sp.release();

                            try self.tracer.recordStepEnd(
                                seq,
                                current_pipeline_name,
                                t_step.name,
                                status,
                                host_ctx.windows_read,
                                host_ctx.rows_read,
                                host_ctx.rows_emitted,
                            );

                            summary.steps_executed += 1;
                            summary.total_rows_emitted += host_ctx.rows_emitted;

                            if (self.debug_controller.notifyAfterStep(current_pipeline_name, t_step.name) == .abort_run) {
                                return error.AbortedByDebugger;
                            }

                            if (status == .halt_pipeline) {
                                summary.halted_early = true;
                                return summary;
                            }
                        }
                    },
                    .router => |r_step| {
                        summary.routers_evaluated += 1;
                        const maybe_next = try self.db_runtime.evaluateRouter(r_step);
                        try self.tracer.recordRouterDecision(current_pipeline_name, r_step.name, maybe_next);

                        if (self.debug_controller.notifyAfterStep(current_pipeline_name, r_step.name) == .abort_run) {
                            return error.AbortedByDebugger;
                        }

                        if (maybe_next) |next_pipe| {
                            current_pipeline_name = next_pipe;
                            continue :pipeline_loop;
                        } else {
                            return summary;
                        }
                    },
                }
            }

            // Reached the end of the current sub-pipeline without a router transition
            break;
        }

        return summary;
    }
};

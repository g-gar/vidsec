const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");
const runner_mod = @import("../engine/runner.zig");
const engine_mod = @import("../engine/engine.zig");

pub const InvocationRequest = contracts.InvocationRequest;
pub const InvocationResponse = contracts.InvocationResponse;
pub const InvocationCommand = contracts.InvocationCommand;
pub const OutputFormat = contracts.OutputFormat;
pub const DriverInitializerFn = contracts.DriverInitializerFn;
pub const PipelineRunner = runner_mod.PipelineRunner;
pub const ExecutionSummary = engine_mod.ExecutionSummary;

/// Metadata describing the host application implementing Flowdata.
pub const AppInfo = struct {
    app_name: []const u8,
    description: []const u8 = "",
    version: []const u8 = "2.0.0",
    driver_initializer: ?DriverInitializerFn = null,
};

/// Central coordinator handling lifecycle, pre-flight verification, and pipeline execution
/// independently of the incoming transport protocol (CLI, HTTP, gRPC, IPC).
pub const HostDispatcher = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    app_info: AppInfo,
    cached_runner: ?PipelineRunner = null,

    pub fn init(allocator: Allocator, app_info: AppInfo) HostDispatcher {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .app_info = app_info,
            .cached_runner = null,
        };
    }

    pub fn deinit(self: *HostDispatcher) void {
        if (self.cached_runner) |*r| {
            r.deinit();
            self.cached_runner = null;
        }
        self.arena.deinit();
    }

    /// Pre-warms and caches a `PipelineRunner` for low-latency daemon execution (`serve` mode).
    pub fn warmCache(self: *HostDispatcher, options: contracts.RunnerOptions) anyerror!void {
        if (self.cached_runner) |*r| {
            r.deinit();
            self.cached_runner = null;
        }
        var opts = options;
        if (opts.driver_initializer == null) {
            opts.driver_initializer = self.app_info.driver_initializer;
        }
        self.cached_runner = try PipelineRunner.initFromFiles(self.allocator, opts);
    }

    /// Dispatches an abstract `InvocationRequest` and returns a normalized `InvocationResponse`.
    pub fn handle(self: *HostDispatcher, req: InvocationRequest) anyerror!InvocationResponse {
        return switch (req.command) {
            .version => self.handleVersion(req.format),
            .help => self.handleHelp(req.format),
            .health => self.handleHealth(req.format),
            .validate => self.handleValidate(req),
            .run => self.handleRun(req),
            .serve => .{
                .status = .invalid_request,
                .message = "HostDispatcher cannot execute 'serve' synchronously; use HostTransport.serve()",
                .exit_code = 1,
            },
            .custom => .{
                .status = .not_found,
                .message = "Unknown custom command",
                .exit_code = 1,
            },
        };
    }

    /// Static C-style function trampoline for polymorphic `DispatchFn`.
    pub fn dispatchOpaque(ctx: contracts.HostDispatcherPtr, req: InvocationRequest) anyerror!InvocationResponse {
        const self: *HostDispatcher = @ptrCast(@alignCast(ctx));
        return try self.handle(req);
    }

    fn handleVersion(self: *HostDispatcher, format: OutputFormat) InvocationResponse {
        const a = self.arena.allocator();
        if (format == .json) {
            const json_str = std.fmt.allocPrint(
                a,
                "{{\"app\":\"{s}\",\"version\":\"{s}\"}}\n",
                .{ self.app_info.app_name, self.app_info.version },
            ) catch return .{ .status = .execution_failed, .message = "Out of memory", .exit_code = 1 };

            return .{
                .status = .ok,
                .message = json_str,
                .output_bytes = json_str,
                .exit_code = 0,
            };
        }

        const text_str = std.fmt.allocPrint(
            a,
            "{s} {s}\n",
            .{ self.app_info.app_name, self.app_info.version },
        ) catch return .{ .status = .execution_failed, .message = "Out of memory", .exit_code = 1 };

        return .{
            .status = .ok,
            .message = text_str,
            .output_bytes = text_str,
            .exit_code = 0,
        };
    }

    fn handleHelp(self: *HostDispatcher, format: OutputFormat) InvocationResponse {
        const a = self.arena.allocator();
        if (format == .json) {
            const json_str = std.fmt.allocPrint(
                a,
                "{{\"app\":\"{s}\",\"description\":\"{s}\",\"version\":\"{s}\"}}\n",
                .{ self.app_info.app_name, self.app_info.description, self.app_info.version },
            ) catch return .{ .status = .execution_failed, .message = "Out of memory", .exit_code = 1 };

            return .{
                .status = .ok,
                .message = json_str,
                .output_bytes = json_str,
                .exit_code = 0,
            };
        }

        const text_str = std.fmt.allocPrint(
            a,
            \\{s} - {s}
            \\
            \\Usage:
            \\  {s} validate --pipeline <pipeline.yaml> [--schemas <schemas.yaml>] [--env <.env>] [--skip-so]
            \\  {s} run      --pipeline <pipeline.yaml> [--schemas <schemas.yaml>] [--env <.env>]
            \\               [--db <state.db>] [--trace-out <trace.jsonl>]
            \\               [--artifact-out <artifact_id>=<out_path>] <input_file>
            \\  {s} serve    --pipeline <pipeline.yaml> [--transport http|grpc] [--listen <host:port>]
            \\  {s} version  (--version, -v)
            \\  {s} help     (--help, -h)
            \\
        ,
            .{
                self.app_info.app_name,
                self.app_info.description,
                self.app_info.app_name,
                self.app_info.app_name,
                self.app_info.app_name,
                self.app_info.app_name,
                self.app_info.app_name,
            },
        ) catch return .{ .status = .execution_failed, .message = "Out of memory", .exit_code = 1 };

        return .{
            .status = .ok,
            .message = text_str,
            .output_bytes = text_str,
            .exit_code = 0,
        };
    }

    fn handleHealth(self: *HostDispatcher, format: OutputFormat) InvocationResponse {
        const a = self.arena.allocator();
        const json_msg = std.fmt.allocPrint(
            a,
            "{{\"status\":\"healthy\",\"app\":\"{s}\",\"version\":\"{s}\"}}\n",
            .{ self.app_info.app_name, self.app_info.version },
        ) catch return .{ .status = .execution_failed, .message = "Out of memory", .exit_code = 1 };

        if (format == .json) {
            return .{
                .status = .ok,
                .message = json_msg,
                .output_bytes = json_msg,
                .exit_code = 0,
            };
        }

        return .{
            .status = .ok,
            .message = "healthy\n",
            .output_bytes = json_msg,
            .exit_code = 0,
        };
    }

    fn handleValidate(self: *HostDispatcher, req: InvocationRequest) anyerror!InvocationResponse {
        var opts = req.options;
        if (opts.driver_initializer == null) {
            opts.driver_initializer = self.app_info.driver_initializer;
        }

        var local_runner: ?PipelineRunner = null;
        defer if (local_runner) |*r| r.deinit();

        const active_runner: *PipelineRunner = if (self.cached_runner) |*cr| cr else blk: {
            local_runner = PipelineRunner.initFromFiles(self.allocator, opts) catch |err| {
                const a = self.arena.allocator();
                const err_msg = try std.fmt.allocPrint(a, "Failed to initialize pipeline from files: {s}\n", .{@errorName(err)});
                const json_err = try std.fmt.allocPrint(a, "{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
                return .{
                    .status = .validation_failed,
                    .message = err_msg,
                    .output_bytes = json_err,
                    .exit_code = 1,
                };
            };
            break :blk &local_runner.?;
        };

        active_runner.validatePreFlight(opts.wal_db_path, opts.load_shared_modules) catch |err| {
            const a = self.arena.allocator();
            const err_msg = try std.fmt.allocPrint(a, "Pre-flight validation failed: {s}\n", .{@errorName(err)});
            const json_err = try std.fmt.allocPrint(a, "{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
            return .{
                .status = .validation_failed,
                .message = err_msg,
                .output_bytes = json_err,
                .exit_code = 1,
            };
        };

        const a = self.arena.allocator();
        if (req.format == .json) {
            const json_msg = try std.fmt.allocPrint(a, "{{\"status\":\"ok\",\"command\":\"validate\",\"message\":\"Pre-flight validation passed (YAML, DAG, and Plugin ABI)\"}}\n", .{});
            return .{
                .status = .ok,
                .message = json_msg,
                .output_bytes = json_msg,
                .exit_code = 0,
            };
        }

        const msg = "[OK] Pre-flight validation passed (YAML, DAG, and Plugin ABI).\n";
        return .{
            .status = .ok,
            .message = msg,
            .output_bytes = msg,
            .exit_code = 0,
        };
    }

    fn handleRun(self: *HostDispatcher, req: InvocationRequest) anyerror!InvocationResponse {
        var opts = req.options;
        if (opts.driver_initializer == null) {
            opts.driver_initializer = self.app_info.driver_initializer;
        }

        var local_runner: ?PipelineRunner = null;
        defer if (local_runner) |*r| r.deinit();

        const active_runner: *PipelineRunner = if (self.cached_runner) |*cr| cr else blk: {
            local_runner = PipelineRunner.initFromFiles(self.allocator, opts) catch |err| {
                const a = self.arena.allocator();
                const err_msg = try std.fmt.allocPrint(a, "Failed to initialize pipeline from files: {s}\n", .{@errorName(err)});
                const json_err = try std.fmt.allocPrint(a, "{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
                return .{
                    .status = .execution_failed,
                    .message = err_msg,
                    .output_bytes = json_err,
                    .exit_code = 1,
                };
            };
            break :blk &local_runner.?;
        };

        const summary: ExecutionSummary = switch (req.input) {
            .file_path => |p| active_runner.runFile(p, opts) catch |err| {
                const a = self.arena.allocator();
                const err_msg = try std.fmt.allocPrint(a, "Pipeline execution failed: {s}\n", .{@errorName(err)});
                const json_err = try std.fmt.allocPrint(a, "{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
                return .{
                    .status = .execution_failed,
                    .message = err_msg,
                    .output_bytes = json_err,
                    .exit_code = 1,
                };
            },
            .memory_bytes => |b| active_runner.runMemory(b, opts) catch |err| {
                const a = self.arena.allocator();
                const err_msg = try std.fmt.allocPrint(a, "Pipeline execution failed: {s}\n", .{@errorName(err)});
                const json_err = try std.fmt.allocPrint(a, "{{\"status\":\"error\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
                return .{
                    .status = .execution_failed,
                    .message = err_msg,
                    .output_bytes = json_err,
                    .exit_code = 1,
                };
            },
            .none => return .{
                .status = .invalid_request,
                .message = "Missing input file or payload for 'run' command",
                .exit_code = 1,
            },
        };

        const a = self.arena.allocator();
        if (req.format == .json) {
            const json_msg = try std.fmt.allocPrint(
                a,
                "{{\"status\":\"ok\",\"command\":\"run\",\"summary\":{{\"steps_executed\":{d},\"routers_evaluated\":{d},\"halted_early\":{},\"final_pipeline\":\"{s}\"}}}}\n",
                .{
                    summary.steps_executed,
                    summary.routers_evaluated,
                    summary.halted_early,
                    summary.final_pipeline,
                },
            );
            return .{
                .status = .ok,
                .summary = summary,
                .message = json_msg,
                .output_bytes = json_msg,
                .exit_code = 0,
            };
        }

        const text_msg = try std.fmt.allocPrint(
            a,
            "[OK] Pipeline completed: steps={d}, routers={d}, halted={any}, final_pipeline={s}\n",
            .{
                summary.steps_executed,
                summary.routers_evaluated,
                summary.halted_early,
                summary.final_pipeline,
            },
        );
        return .{
            .status = .ok,
            .summary = summary,
            .message = text_msg,
            .output_bytes = text_msg,
            .exit_code = 0,
        };
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");
const runner_mod = @import("../../engine/runner.zig");
const engine_mod = @import("../../engine/engine.zig");
const kernel_mod = @import("../../kernel/mod.zig");

pub const InvocationRequest = contracts.InvocationRequest;
pub const InvocationResponse = contracts.InvocationResponse;
pub const InvocationCommand = contracts.InvocationCommand;
pub const OutputFormat = contracts.OutputFormat;
pub const DriverInitializerFn = contracts.DriverInitializerFn;
pub const PipelineRunner = runner_mod.PipelineRunner;
pub const ExecutionSummary = engine_mod.ExecutionSummary;
pub const Extension = kernel_mod.Extension;
pub const KernelContext = kernel_mod.KernelContext;

/// Handler callback for custom commands dynamically registered in `InboundDispatcher`.
pub const CustomCommandHandler = struct {
    ptr: ?*anyopaque = null,
    handler: *const fn (ctx: ?*anyopaque, allocator: Allocator, req: InvocationRequest) anyerror!InvocationResponse,
};

/// Metadata describing the host application implementing Flowdata.
pub const AppInfo = struct {
    app_name: []const u8,
    description: []const u8 = "",
    version: []const u8 = "2.0.0",
    driver_initializer: ?DriverInitializerFn = null,
    extensions: []const Extension = &.{},
    kernel: ?*KernelContext = null,
};

/// Central coordinator handling lifecycle, pre-flight verification, and pipeline execution
/// independently of the incoming transport protocol (CLI, HTTP, gRPC, IPC).
pub const InboundDispatcher = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    app_info: AppInfo,
    cached_runner: ?PipelineRunner = null,
    custom_commands: std.StringHashMapUnmanaged(CustomCommandHandler) = .empty,

    pub fn init(allocator: Allocator, app_info: AppInfo) InboundDispatcher {
        var d = InboundDispatcher{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .app_info = app_info,
            .cached_runner = null,
            .custom_commands = .empty,
        };
        if (app_info.kernel) |k| {
            k.commands.bindToDispatcher(&d) catch {};
        }
        return d;
    }

    pub fn deinit(self: *InboundDispatcher) void {
        if (self.cached_runner) |*r| {
            r.deinit();
            self.cached_runner = null;
        }
        var it = self.custom_commands.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.custom_commands.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Dynamically registers a custom sub-command handler.
    pub fn registerCommand(self: *InboundDispatcher, name: []const u8, handler: CustomCommandHandler) !void {
        if (!self.custom_commands.contains(name)) {
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.custom_commands.put(self.allocator, owned, handler);
        } else {
            try self.custom_commands.put(self.allocator, name, handler);
        }
    }

    pub fn registerCommandFn(
        self: *InboundDispatcher,
        name: []const u8,
        fn_ptr: *const fn (allocator: Allocator, req: InvocationRequest) anyerror!InvocationResponse,
    ) !void {
        const Wrapper = struct {
            fn call(_: ?*anyopaque, alloc: Allocator, req: InvocationRequest) anyerror!InvocationResponse {
                return fn_ptr(alloc, req);
            }
        };
        try self.registerCommand(name, .{ .ptr = null, .handler = &Wrapper.call });
    }

    /// Pre-warms and caches a `PipelineRunner` for low-latency daemon execution (`serve` mode).
    pub fn warmCache(self: *InboundDispatcher, options: contracts.RunnerOptions) anyerror!void {
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
    pub fn handle(self: *InboundDispatcher, req: InvocationRequest) anyerror!InvocationResponse {
        return switch (req.command) {
            .version => self.handleVersion(req.format),
            .help => self.handleHelp(req.format),
            .health => self.handleHealth(req.format),
            .validate => self.handleValidate(req),
            .run => self.handleRun(req),
            .serve => .{
                .status = .invalid_request,
                .message = "InboundDispatcher cannot execute 'serve' synchronously; use InboundTransport.serve()",
                .exit_code = 1,
            },
            .custom => self.handleCustom(req),
        };
    }

    /// Static C-style function trampoline for polymorphic `DispatchFn`.
    pub fn dispatchOpaque(ctx: contracts.DispatcherPtr, req: InvocationRequest) anyerror!InvocationResponse {
        const self: *InboundDispatcher = @ptrCast(@alignCast(ctx));
        return try self.handle(req);
    }

    fn handleCustom(self: *InboundDispatcher, req: InvocationRequest) anyerror!InvocationResponse {
        if (req.custom_command_name.len > 0) {
            if (self.custom_commands.get(req.custom_command_name)) |handler| {
                return try handler.handler(handler.ptr, self.arena.allocator(), req);
            }
        }
        return .{
            .status = .not_found,
            .message = "Unknown custom command",
            .exit_code = 1,
        };
    }

    fn handleVersion(self: *InboundDispatcher, format: OutputFormat) InvocationResponse {
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

    fn handleHelp(self: *InboundDispatcher, format: OutputFormat) InvocationResponse {
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
            \\  {s} serve    --pipeline <pipeline.yaml> [--transport http|grpc|<custom>] [--listen <host:port>]
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

    fn handleHealth(self: *InboundDispatcher, format: OutputFormat) InvocationResponse {
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

    fn handleValidate(self: *InboundDispatcher, req: InvocationRequest) anyerror!InvocationResponse {
        var opts = req.options;
        if (opts.driver_initializer == null) {
            opts.driver_initializer = self.app_info.driver_initializer;
        }
        if (opts.kernel == null) {
            opts.kernel = self.app_info.kernel;
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

    fn handleRun(self: *InboundDispatcher, req: InvocationRequest) anyerror!InvocationResponse {
        var opts = req.options;
        if (opts.driver_initializer == null) {
            opts.driver_initializer = self.app_info.driver_initializer;
        }
        if (opts.kernel == null) {
            opts.kernel = self.app_info.kernel;
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
            .none => active_runner.runMemory(&.{}, opts) catch |err| {
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

pub const HostDispatcher = InboundDispatcher;

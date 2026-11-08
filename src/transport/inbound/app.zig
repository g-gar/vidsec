const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");
const dispatcher_mod = @import("dispatcher.zig");
const registry_mod = @import("registry.zig");
const drivers_mod = @import("drivers/mod.zig");

pub const AppInfo = dispatcher_mod.AppInfo;
pub const AppConfig = AppInfo;
pub const InboundDispatcher = dispatcher_mod.InboundDispatcher;
pub const HostDispatcher = dispatcher_mod.HostDispatcher;
pub const InboundRegistry = registry_mod.InboundRegistry;
pub const CliTransport = drivers_mod.CliTransport;
pub const HttpServerTransport = drivers_mod.HttpServerTransport;
pub const HttpTransport = drivers_mod.HttpTransport;
pub const GrpcTransport = drivers_mod.GrpcTransport;

/// Top-level Application Coordinator for Flowdata binaries.
/// Connects standard process entrypoints to transport handlers and the core pipeline dispatcher.
pub const TransportApp = struct {
    /// Standard application entrypoint receiving `std.process.Init`.
    pub fn runCliEntry(init: std.process.Init, config: AppConfig) !u8 {
        const allocator = init.gpa;
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        return runArgs(allocator, args, config);
    }

    /// Evaluates process CLI arguments using the configured `AppConfig`.
    pub fn run(config: AppConfig) !u8 {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        return runArgs(allocator, args, config);
    }

    /// Evaluates CLI arguments using the configured `AppConfig`.
    pub fn runArgs(allocator: Allocator, args: []const []const u8, config: AppConfig) !u8 {
        return runArgsWithRegistry(allocator, args, config, null);
    }

    /// Evaluates CLI arguments with an optional pre-configured `InboundRegistry`.
    pub fn runArgsWithRegistry(
        allocator: Allocator,
        args: []const []const u8,
        config: AppConfig,
        custom_registry: ?*const InboundRegistry,
    ) !u8 {
        var local_kernel: ?@import("../../kernel/mod.zig").KernelContext = null;
        defer if (local_kernel) |*k| k.deinit();

        var cfg = config;
        if (cfg.kernel == null and cfg.extensions.len > 0) {
            local_kernel = try @import("../../kernel/mod.zig").KernelContext.init(allocator);
            try local_kernel.?.useAll(cfg.extensions);
            cfg.kernel = &local_kernel.?;
        }

        var dispatcher = InboundDispatcher.init(allocator, cfg);
        defer dispatcher.deinit();

        // Check if the command is `serve` to launch daemon transport
        if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
            return try runServe(allocator, args, &dispatcher, custom_registry);
        }

        var cli = CliTransport.init(allocator, args);
        return try cli.executeWithDispatch(&dispatcher, &InboundDispatcher.dispatchOpaque);
    }

    fn runServe(
        allocator: Allocator,
        args: []const []const u8,
        dispatcher: *InboundDispatcher,
        custom_registry: ?*const InboundRegistry,
    ) !u8 {
        var transport_type: []const u8 = "http";
        var listen_addr: []const u8 = "127.0.0.1:8080";
        var pipeline_path: []const u8 = "";

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--transport") or std.mem.eql(u8, arg, "-t")) {
                i += 1;
                if (i >= args.len) return error.MissingArgumentValue;
                transport_type = args[i];
            } else if (std.mem.eql(u8, arg, "--listen") or std.mem.eql(u8, arg, "-l")) {
                i += 1;
                if (i >= args.len) return error.MissingArgumentValue;
                listen_addr = args[i];
            } else if (std.mem.eql(u8, arg, "--pipeline") or std.mem.eql(u8, arg, "-p")) {
                i += 1;
                if (i >= args.len) return error.MissingArgumentValue;
                pipeline_path = args[i];
            }
        }

        if (pipeline_path.len > 0) {
            dispatcher.warmCache(.{ .pipeline_yaml_path = pipeline_path }) catch |err| {
                std.debug.print("Failed to warm cache for pipeline {s}: {any}\n", .{ pipeline_path, err });
                return 1;
            };
        }

        var local_reg: ?InboundRegistry = null;
        defer if (local_reg) |*r| r.deinit();

        const active_reg: *const InboundRegistry = if (custom_registry) |r| r else blk: {
            local_reg = try InboundRegistry.init(allocator);
            break :blk &local_reg.?;
        };

        var transport = try active_reg.create(transport_type, .{
            .listen_address = listen_addr,
            .pipeline_path = pipeline_path,
        });
        defer transport.deinit(allocator);

        return try transport.serve(dispatcher, &InboundDispatcher.dispatchOpaque);
    }
};

pub const HostApp = TransportApp;

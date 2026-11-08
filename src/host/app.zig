const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("contracts/mod.zig");
const dispatcher_mod = @import("dispatcher.zig");
const transports_mod = @import("transports/mod.zig");

pub const AppInfo = dispatcher_mod.AppInfo;
pub const AppConfig = AppInfo;
pub const HostDispatcher = dispatcher_mod.HostDispatcher;
pub const CliTransport = transports_mod.CliTransport;
pub const HttpServerTransport = transports_mod.HttpServerTransport;
pub const GrpcTransport = transports_mod.GrpcTransport;

/// Top-level Application Coordinator for Flowdata binaries.
/// Connects standard process entrypoints to transport handlers and the core pipeline dispatcher.
pub const HostApp = struct {
    /// Standard application entrypoint receiving `std.process.Init`.
    pub fn runCliEntry(init: std.process.Init, config: AppConfig) !u8 {
        const allocator = init.gpa;
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        return runArgs(allocator, args, config);
    }

    /// Evaluates CLI arguments using the configured `AppConfig`.
    pub fn runArgs(allocator: Allocator, args: []const []const u8, config: AppConfig) !u8 {
        var dispatcher = HostDispatcher.init(allocator, config);
        defer dispatcher.deinit();

        // Check if the command is `serve` to launch daemon transport
        if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
            return try runServe(allocator, args, &dispatcher);
        }

        var cli = CliTransport.init(allocator, args);
        return try cli.executeWithDispatch(&dispatcher, &HostDispatcher.dispatchOpaque);
    }

    fn runServe(allocator: Allocator, args: []const []const u8, dispatcher: *HostDispatcher) !u8 {
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

        var port: u16 = 8080;
        var host: []const u8 = "127.0.0.1";
        if (std.mem.indexOfScalar(u8, listen_addr, ':')) |colon| {
            host = listen_addr[0..colon];
            port = std.fmt.parseInt(u16, listen_addr[colon + 1 ..], 10) catch 8080;
        } else if (std.fmt.parseInt(u16, listen_addr, 10)) |p| {
            port = p;
        } else |_| {}

        if (pipeline_path.len > 0) {
            dispatcher.warmCache(.{ .pipeline_yaml_path = pipeline_path }) catch |err| {
                std.debug.print("Failed to warm cache for pipeline {s}: {any}\n", .{ pipeline_path, err });
                return 1;
            };
        }

        if (std.ascii.eqlIgnoreCase(transport_type, "grpc")) {
            var grpc_transport = GrpcTransport.init(allocator, host, port, pipeline_path);
            var ht = grpc_transport.hostTransport();
            return try ht.serve(dispatcher, &HostDispatcher.dispatchOpaque);
        }

        var http_transport = HttpServerTransport.init(allocator, host, port, pipeline_path);
        var ht = http_transport.hostTransport();
        return try ht.serve(dispatcher, &HostDispatcher.dispatchOpaque);
    }
};

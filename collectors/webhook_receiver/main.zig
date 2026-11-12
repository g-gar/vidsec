const std = @import("std");
const common = @import("collectors_common");
const SpoolForwarder = common.SpoolForwarder;
const WebhookServer = @import("server.zig").WebhookServer;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var port: u16 = 9090;
    var host: []const u8 = "0.0.0.0";
    var engine_url: []const u8 = "http://127.0.0.1:8080";
    var spool_dir: []const u8 = "./spool/webhook";

    const args = init.minimal.args.vector;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) {
                port = std.fmt.parseInt(u16, std.mem.span(args[i]), 10) catch 9090;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < args.len) host = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--engine") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i < args.len) engine_url = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--spool-dir") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i < args.len) spool_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    std.debug.print(
        \\=======================================================
        \\ Flowdata Webhook Collector (ARCH-019 Standalone Agent)
        \\=======================================================
        \\ Listening:   http://{s}:{d}
        \\ Forwarding:  {s}/v1/jobs
        \\ Spool Dir:   {s}
        \\ Mode:        Foreground Interactive CLI
        \\ Status:      Running (Press Ctrl+C to terminate)
        \\=======================================================
        \\
    , .{ host, port, engine_url, spool_dir });

    var forwarder = try SpoolForwarder.init(alloc, "webhook_collector", engine_url, spool_dir);
    defer forwarder.deinit();

    // Check existing spool on startup and try an initial flush
    const initial_spool = forwarder.spool.count();
    if (initial_spool > 0) {
        std.debug.print("[Webhook] Discovered {d} pending jobs in spool. Attempting initial flush...\n", .{initial_spool});
        _ = forwarder.flush() catch {};
    }

    var server = WebhookServer.init(alloc, host, port, &forwarder);
    try server.run();
}

fn printUsage() void {
    std.debug.print(
        \\Usage: flowdata-collector-webhook [options]
        \\
        \\Options:
        \\  -p, --port <port>        Port to listen on (default: 9090)
        \\      --host <ip>          Host address to bind (default: 0.0.0.0)
        \\  -e, --engine <url>       Flowdata engine URL (default: http://127.0.0.1:8080)
        \\  -s, --spool-dir <path>   Local persistent disk spool directory (default: ./spool/webhook)
        \\  -h, --help               Show this help message
        \\
    , .{});
}

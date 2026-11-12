const std = @import("std");
const common = @import("collectors_common");
const SpoolForwarder = common.SpoolForwarder;
const InotifyWatcher = @import("inotify_watcher.zig").InotifyWatcher;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var watch_path: ?[]const u8 = null;
    var engine_url: []const u8 = "http://127.0.0.1:8080";
    var spool_dir: []const u8 = "./spool/watcher";
    var topic: []const u8 = "file_event";

    const args = init.minimal.args.vector;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i < args.len) watch_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--engine") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i < args.len) engine_url = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--spool-dir") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i < args.len) spool_dir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--topic") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i < args.len) topic = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
    }

    const path = watch_path orelse {
        std.debug.print("Error: Missing required option --watch <path>\n\n", .{});
        printUsage();
        return;
    };

    std.debug.print(
        \\=======================================================
        \\ Flowdata File Watcher (ARCH-019 Standalone inotify)
        \\=======================================================
        \\ Watching:    {s}
        \\ Topic:       {s}
        \\ Forwarding:  {s}/v1/jobs
        \\ Spool Dir:   {s}
        \\ Mode:        Foreground Interactive CLI
        \\ Status:      Running (Press Ctrl+C to terminate)
        \\=======================================================
        \\
    , .{ path, topic, engine_url, spool_dir });

    var forwarder = try SpoolForwarder.init(alloc, "file_watcher", engine_url, spool_dir);
    defer forwarder.deinit();

    // Check existing spool on startup and try an initial flush
    const initial_spool = forwarder.spool.count();
    if (initial_spool > 0) {
        std.debug.print("[Watcher] Discovered {d} pending jobs in spool. Attempting initial flush...\n", .{initial_spool});
        _ = forwarder.flush() catch {};
    }

    var watcher = InotifyWatcher.init(alloc, path, topic, &forwarder);
    try watcher.run();
}

fn printUsage() void {
    std.debug.print(
        \\Usage: flowdata-collector-watcher [options] --watch <path>
        \\
        \\Options:
        \\  -w, --watch <path>       File or directory path to observe (required)
        \\  -t, --topic <name>       Topic identifier for emitted events (default: file_event)
        \\  -e, --engine <url>       Flowdata engine URL (default: http://127.0.0.1:8080)
        \\  -s, --spool-dir <path>   Local persistent disk spool directory (default: ./spool/watcher)
        \\  -h, --help               Show this help message
        \\
    , .{});
}

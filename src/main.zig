const std = @import("std");
const vidsec = @import("vidsec");
const build_options = @import("build_options");

fn printStdout(msg: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, msg.ptr, msg.len);
}

const CliCommand = enum {
    validate,
    run,
    help,
    version,
};

fn printUsage() void {
    const usage =
        \\vidsec v2 - Declarative Multimedia Security & Transformation Engine
        \\
        \\Usage:
        \\  vidsec validate --pipeline <pipeline.yaml> [--schemas <schemas.yaml>] [--env <.env>] [--skip-so]
        \\  vidsec run      --pipeline <pipeline.yaml> [--schemas <schemas.yaml>] [--env <.env>]
        \\                  [--db <state.db>] [--trace-out <trace.jsonl>]
        \\                  [--artifact-out <artifact_id>=<out_path>] <input_file>
        \\  vidsec version  (--version, -v)
        \\
    ;
    printStdout(usage);
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage();
        return 1;
    }

    const cmd_str = args[1];
    const cmd: CliCommand = if (std.mem.eql(u8, cmd_str, "validate"))
        .validate
    else if (std.mem.eql(u8, cmd_str, "run"))
        .run
    else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h"))
        .help
    else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-v"))
        .version
    else {
        printUsage();
        return 1;
    };

    if (cmd == .help) {
        printUsage();
        return 0;
    }

    if (cmd == .version) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "vidsec {s}\n", .{build_options.version_string}) catch "vidsec 2.0.0\n";
        printStdout(msg);
        return 0;
    }

    var pipeline_path: ?[]const u8 = null;
    var schemas_path: ?[]const u8 = null;
    var dotenv_path: ?[]const u8 = null;
    var wal_db_path: ?[]const u8 = null;
    var trace_out_path: ?[]const u8 = null;
    var entry_pipeline: ?[]const u8 = null;
    var input_file_path: ?[]const u8 = null;
    var load_shared: bool = true;

    var exports_list: std.ArrayListUnmanaged(vidsec.pipeline.ArtifactExportSpec) = .empty;
    defer exports_list.deinit(allocator);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--pipeline") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            pipeline_path = args[i];
        } else if (std.mem.eql(u8, arg, "--schemas") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            schemas_path = args[i];
        } else if (std.mem.eql(u8, arg, "--env") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            dotenv_path = args[i];
        } else if (std.mem.eql(u8, arg, "--db")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            wal_db_path = args[i];
        } else if (std.mem.eql(u8, arg, "--trace-out") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            trace_out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--artifact-out") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            const pair = args[i];
            const eq_idx = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidArtifactExportSpec;
            try exports_list.append(allocator, .{
                .artifact_id = pair[0..eq_idx],
                .output_path = pair[eq_idx + 1 ..],
            });
        } else if (std.mem.eql(u8, arg, "--entry") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            entry_pipeline = args[i];
        } else if (std.mem.eql(u8, arg, "--skip-so")) {
            load_shared = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_file_path = arg;
        } else {
            return error.UnknownCliFlag;
        }
    }

    const p_path = pipeline_path orelse {
        printUsage();
        return 1;
    };

    const opts = vidsec.pipeline.RunnerOptions{
        .pipeline_yaml_path = p_path,
        .schemas_yaml_path = schemas_path,
        .dotenv_path = dotenv_path,
        .wal_db_path = wal_db_path,
        .trace_out_path = trace_out_path,
        .entry_pipeline = entry_pipeline,
        .artifact_exports = exports_list.items,
        .load_shared_modules = load_shared,
    };

    var runner = try vidsec.pipeline.PipelineRunner.initFromFiles(allocator, opts);
    defer runner.deinit();

    switch (cmd) {
        .validate => {
            try runner.validatePreFlight(wal_db_path, load_shared);
            const msg = "[OK] Pre-flight validation passed (YAML, DAG, and Plugin ABI).\n";
            printStdout(msg);
        },
        .run => {
            const in_path = input_file_path orelse {
                printUsage();
                return 1;
            };
            const summary = try runner.runFile(in_path, opts);
            var out_buf: [512]u8 = undefined;
            const line = try std.fmt.bufPrint(
                &out_buf,
                "[OK] Pipeline completed: steps={d}, routers={d}, halted={any}, final_pipeline={s}\n",
                .{
                    summary.steps_executed,
                    summary.routers_evaluated,
                    summary.halted_early,
                    summary.final_pipeline,
                },
            );
            printStdout(line);
        },
        .help, .version => unreachable,
    }

    return 0;
}

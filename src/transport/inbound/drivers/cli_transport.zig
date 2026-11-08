const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");

pub const InboundTransport = contracts.InboundTransport;
pub const HostTransport = contracts.HostTransport;
pub const InvocationRequest = contracts.InvocationRequest;
pub const InvocationResponse = contracts.InvocationResponse;
pub const InvocationCommand = contracts.InvocationCommand;
pub const OutputFormat = contracts.OutputFormat;
pub const ArtifactExportSpec = contracts.ArtifactExportSpec;

const builtin = @import("builtin");

pub const OutputWriterFn = *const fn (msg: []const u8) void;
pub var custom_output_writer: ?OutputWriterFn = null;

pub fn printStdout(msg: []const u8) void {
    if (msg.len == 0) return;
    if (custom_output_writer) |w| {
        w(msg);
        return;
    }
    if (builtin.is_test) return;
    _ = std.c.write(std.c.STDOUT_FILENO, msg.ptr, msg.len);
}

pub fn printStderr(msg: []const u8) void {
    if (msg.len == 0) return;
    if (custom_output_writer) |w| {
        w(msg);
        return;
    }
    if (builtin.is_test) return;
    _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
}

/// Command-Line Interface Transport for Flowdata applications.
/// Implements polymorphic `InboundTransport` and executes invocations from standard OS arguments.
pub const CliTransport = struct {
    comptime {
        InboundTransport.assertImplements(@This());
    }

    allocator: Allocator,
    args: []const []const u8 = &.{},

    pub fn init(allocator: Allocator, args: []const []const u8) CliTransport {
        return .{
            .allocator = allocator,
            .args = args,
        };
    }

    pub fn inboundTransport(self: *CliTransport) InboundTransport {
        const Trampoline = struct {
            fn doName(_: *const anyopaque) []const u8 {
                return "cli";
            }

            fn doServe(
                ctx: *anyopaque,
                dispatcher_ctx: contracts.DispatcherPtr,
                dispatch_fn: contracts.DispatchFn,
            ) anyerror!u8 {
                const s: *CliTransport = @ptrCast(@alignCast(ctx));
                return s.executeWithDispatch(dispatcher_ctx, dispatch_fn);
            }

            fn doDeinit(ctx: *anyopaque, _: Allocator) void {
                _ = ctx;
            }

            const vtable = InboundTransport.VTable{
                .name = &doName,
                .serve = &doServe,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }

    pub const hostTransport = inboundTransport;

    pub fn executeWithDispatch(
        self: *CliTransport,
        dispatcher_ctx: contracts.DispatcherPtr,
        dispatch_fn: contracts.DispatchFn,
    ) anyerror!u8 {
        if (self.args.len < 2) {
            const help_req = InvocationRequest{
                .command = .help,
                .options = .{ .pipeline_yaml_path = "" },
            };
            const resp = try dispatch_fn(dispatcher_ctx, help_req);
            printStdout(resp.message);
            return 1;
        }

        const cmd_str = self.args[1];
        const cmd_opt = InvocationCommand.fromString(cmd_str);
        const is_custom = (cmd_opt == null and !std.mem.startsWith(u8, cmd_str, "-"));

        const cmd = if (is_custom) InvocationCommand.custom else (cmd_opt orelse {
            const help_req = InvocationRequest{
                .command = .help,
                .options = .{ .pipeline_yaml_path = "" },
            };
            const resp = try dispatch_fn(dispatcher_ctx, help_req);
            printStdout(resp.message);
            return 1;
        });

        if (cmd == .help or cmd == .version) {
            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = cmd,
                .options = .{ .pipeline_yaml_path = "" },
            });
            printStdout(resp.message);
            return resp.exit_code;
        }

        var pipeline_path: ?[]const u8 = null;
        var schemas_path: ?[]const u8 = null;
        var dotenv_path: ?[]const u8 = null;
        var wal_db_path: ?[]const u8 = null;
        var trace_out_path: ?[]const u8 = null;
        var entry_pipeline: ?[]const u8 = null;
        var input_file_path: ?[]const u8 = null;
        var load_shared: bool = true;
        var format: OutputFormat = .text;

        var exports_list: std.ArrayListUnmanaged(ArtifactExportSpec) = .empty;
        defer exports_list.deinit(self.allocator);

        var i: usize = 2;
        while (i < self.args.len) : (i += 1) {
            const arg = self.args[i];
            if (std.mem.eql(u8, arg, "--pipeline") or std.mem.eql(u8, arg, "-p")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                pipeline_path = self.args[i];
            } else if (std.mem.eql(u8, arg, "--schemas") or std.mem.eql(u8, arg, "-s")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                schemas_path = self.args[i];
            } else if (std.mem.eql(u8, arg, "--env") or std.mem.eql(u8, arg, "-e")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                dotenv_path = self.args[i];
            } else if (std.mem.eql(u8, arg, "--db")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                wal_db_path = self.args[i];
            } else if (std.mem.eql(u8, arg, "--trace-out") or std.mem.eql(u8, arg, "-t")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                trace_out_path = self.args[i];
            } else if (std.mem.eql(u8, arg, "--artifact-out") or std.mem.eql(u8, arg, "-o")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                const pair = self.args[i];
                const eq_idx = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidArtifactExportSpec;
                try exports_list.append(self.allocator, .{
                    .artifact_id = pair[0..eq_idx],
                    .output_path = pair[eq_idx + 1 ..],
                });
            } else if (std.mem.eql(u8, arg, "--entry") or std.mem.eql(u8, arg, "-n")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                entry_pipeline = self.args[i];
            } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
                i += 1;
                if (i >= self.args.len) return error.MissingArgumentValue;
                format = OutputFormat.fromString(self.args[i]);
            } else if (std.mem.eql(u8, arg, "--skip-so")) {
                load_shared = false;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                input_file_path = arg;
            } else {
                return error.UnknownCliFlag;
            }
        }

        const p_path = pipeline_path orelse (if (is_custom) "" else {
            const help_resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .help,
                .options = .{ .pipeline_yaml_path = "" },
            });
            printStdout(help_resp.message);
            return 1;
        });

        const runner_options = contracts.RunnerOptions{
            .pipeline_yaml_path = p_path,
            .schemas_yaml_path = schemas_path,
            .dotenv_path = dotenv_path,
            .wal_db_path = wal_db_path,
            .trace_out_path = trace_out_path,
            .entry_pipeline = entry_pipeline,
            .artifact_exports = exports_list.items,
            .load_shared_modules = load_shared,
        };

        const input_src: contracts.InputSource = if (input_file_path) |fpath|
            .{ .file_path = fpath }
        else
            .none;

        if (cmd == .run and input_src == .none) {
            const help_resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .help,
                .options = .{ .pipeline_yaml_path = "" },
            });
            printStdout(help_resp.message);
            return 1;
        }

        const req = InvocationRequest{
            .command = cmd,
            .custom_command_name = if (is_custom) cmd_str else "",
            .options = runner_options,
            .input = input_src,
            .format = format,
        };

        const resp = try dispatch_fn(dispatcher_ctx, req);
        if (resp.status == .ok) {
            printStdout(resp.message);
            return 0;
        } else {
            printStderr(resp.message);
            return if (resp.exit_code != 0) resp.exit_code else 1;
        }
    }
};

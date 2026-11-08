const std = @import("std");
const runner_mod = @import("../../../engine/runner.zig");
const engine_mod = @import("../../../engine/engine.zig");
const ast_mod = @import("../../../ast/ast.zig");

pub const RunnerOptions = runner_mod.RunnerOptions;
pub const ArtifactExportSpec = runner_mod.ArtifactExportSpec;
pub const DriverInitializerFn = runner_mod.DriverInitializerFn;
pub const ExecutionSummary = engine_mod.ExecutionSummary;
pub const KeyValueParam = ast_mod.KeyValueParam;

/// High-level commands executable through any Inbound Transport (CLI, HTTP, gRPC, IPC).
pub const InvocationCommand = enum {
    validate,
    run,
    version,
    help,
    health,
    serve,
    custom,

    pub fn fromString(str: []const u8) ?InvocationCommand {
        if (std.mem.eql(u8, str, "validate")) return .validate;
        if (std.mem.eql(u8, str, "run")) return .run;
        if (std.mem.eql(u8, str, "version") or std.mem.eql(u8, str, "--version") or std.mem.eql(u8, str, "-v")) return .version;
        if (std.mem.eql(u8, str, "help") or std.mem.eql(u8, str, "--help") or std.mem.eql(u8, str, "-h")) return .help;
        if (std.mem.eql(u8, str, "health")) return .health;
        if (std.mem.eql(u8, str, "serve")) return .serve;
        return null;
    }
};

/// Configuration for long-running daemon servers (`serve` command).
pub const ServeConfig = struct {
    transport_name: []const u8 = "http",
    listen_address: []const u8 = "127.0.0.1:8080",
    pipeline_path: []const u8 = "",
    max_requests: ?usize = null,
};

/// Source of input media/payload for pipeline execution.
pub const InputSource = union(enum) {
    none,
    file_path: []const u8,
    memory_bytes: []const u8,
};

/// Serialization/formatting requested for response output.
pub const OutputFormat = enum {
    text,
    json,

    pub fn fromString(str: []const u8) OutputFormat {
        if (std.ascii.eqlIgnoreCase(str, "json")) return .json;
        return .text;
    }
};

/// Protocol-agnostic request envelope passed to `InboundDispatcher`.
pub const InvocationRequest = struct {
    command: InvocationCommand = .run,
    options: RunnerOptions,
    input: InputSource = .none,
    format: OutputFormat = .text,
    custom_command_name: []const u8 = "",
    extra_params: []const KeyValueParam = &.{},
};

/// Outcome classification of an invocation.
pub const InvocationStatus = enum {
    ok,
    invalid_request,
    validation_failed,
    execution_failed,
    not_found,

    pub fn asText(self: InvocationStatus) []const u8 {
        return switch (self) {
            .ok => "ok",
            .invalid_request => "invalid_request",
            .validation_failed => "validation_failed",
            .execution_failed => "execution_failed",
            .not_found => "not_found",
        };
    }
};

/// Protocol-agnostic response envelope returned by `InboundDispatcher`.
pub const InvocationResponse = struct {
    status: InvocationStatus = .ok,
    summary: ?ExecutionSummary = null,
    message: []const u8 = "",
    output_bytes: []const u8 = "",
    exit_code: u8 = 0,
};

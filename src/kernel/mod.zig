const std = @import("std");

pub const extension = @import("extension.zig");
pub const telemetry = @import("telemetry.zig");
pub const ast_pass = @import("ast_pass.zig");
pub const dsl = @import("dsl.zig");
pub const commands = @import("commands.zig");
pub const context = @import("context.zig");

// Extension Contract
pub const Extension = extension.Extension;

// Kernel Context
pub const KernelContext = context.KernelContext;

// Telemetry & Lifecycle
pub const TraceId = telemetry.TraceId;
pub const SpanId = telemetry.SpanId;
pub const PacketDirection = telemetry.PacketDirection;
pub const TelemetryEvent = telemetry.TelemetryEvent;
pub const TelemetrySubscriber = telemetry.TelemetrySubscriber;
pub const TelemetryBus = telemetry.TelemetryBus;

// Compiler AST Passes
pub const AstPass = ast_pass.AstPass;
pub const AstPassFn = ast_pass.AstPassFn;
pub const AstPassRegistry = ast_pass.AstPassRegistry;

// DSL & Interpolation
pub const DslRegistry = dsl.DslRegistry;
pub const CustomPredicateFn = dsl.CustomPredicateFn;
pub const EnvSchemeResolverFn = dsl.EnvSchemeResolverFn;

// Dispatcher Commands
pub const CommandRegistry = commands.CommandRegistry;
pub const CustomCommandHandler = commands.CustomCommandHandler;

test {
    std.testing.refAllDecls(@This());
}

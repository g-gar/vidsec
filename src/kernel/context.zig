const std = @import("std");
const Allocator = std.mem.Allocator;

const repository_mod = @import("../repository/mod.zig");
const transport_mod = @import("../transport/mod.zig");
const plugin_mod = @import("../plugin/mod.zig");
const extension_mod = @import("extension.zig");
const telemetry_mod = @import("telemetry.zig");
const ast_pass_mod = @import("ast_pass.zig");
const dsl_mod = @import("dsl.zig");
const commands_mod = @import("commands.zig");

pub const RepositoryRegistry = repository_mod.RepositoryRegistry;
pub const InboundRegistry = transport_mod.inbound.InboundRegistry;
pub const OutboundRegistry = transport_mod.outbound.OutboundRegistry;
pub const PluginRegistry = plugin_mod.PluginRegistry;
pub const Extension = extension_mod.Extension;
pub const TelemetryBus = telemetry_mod.TelemetryBus;
pub const AstPassRegistry = ast_pass_mod.AstPassRegistry;
pub const DslRegistry = dsl_mod.DslRegistry;
pub const CommandRegistry = commands_mod.CommandRegistry;

/// Central Microkernel Context managing the 5 extensibility planes of Flowdata.
/// Passed to all extensions during bootstrap, and orchestrated by `TransportApp` / `PipelineRunner`.
pub const KernelContext = struct {
    allocator: Allocator,
    datasources: RepositoryRegistry,
    inbound: InboundRegistry,
    outbound: OutboundRegistry,
    plugins: PluginRegistry,
    ast_passes: AstPassRegistry,
    telemetry: TelemetryBus,
    dsl: DslRegistry,
    commands: CommandRegistry,
    extensions: std.ArrayListUnmanaged(Extension) = .empty,

    pub fn init(allocator: Allocator) !KernelContext {
        var ds = RepositoryRegistry.init(allocator);
        errdefer ds.deinit();

        var in_reg = InboundRegistry.init(allocator);
        errdefer in_reg.deinit();

        var out_reg = OutboundRegistry.init(allocator);
        errdefer out_reg.deinit();

        var plugs = PluginRegistry.init(allocator);
        errdefer plugs.deinit();

        var passes = AstPassRegistry.init(allocator);
        errdefer passes.deinit();

        var bus = TelemetryBus.init(allocator);
        errdefer bus.deinit();

        var dsl_reg = DslRegistry.init(allocator);
        errdefer dsl_reg.deinit();

        var cmds = CommandRegistry.init(allocator);
        errdefer cmds.deinit();

        return .{
            .allocator = allocator,
            .datasources = ds,
            .inbound = in_reg,
            .outbound = out_reg,
            .plugins = plugs,
            .ast_passes = passes,
            .telemetry = bus,
            .dsl = dsl_reg,
            .commands = cmds,
            .extensions = .empty,
        };
    }

    pub fn deinit(self: *KernelContext) void {
        for (self.extensions.items) |ext| {
            ext.deinit(self.allocator);
        }
        self.extensions.deinit(self.allocator);

        self.commands.deinit();
        self.dsl.deinit();
        self.telemetry.deinit();
        self.ast_passes.deinit();
        self.plugins.deinit();
        self.outbound.deinit();
        self.inbound.deinit();
        self.datasources.deinit();
    }

    /// Attaches an `Extension` and invokes its `register()` callback against this kernel context.
    pub fn use(self: *KernelContext, ext: Extension) !void {
        try self.extensions.append(self.allocator, ext);
        try ext.register(self);
    }

    /// Attaches a slice of extensions in sequential order.
    pub fn useAll(self: *KernelContext, exts: []const Extension) !void {
        for (exts) |ext| {
            try self.use(ext);
        }
    }
};

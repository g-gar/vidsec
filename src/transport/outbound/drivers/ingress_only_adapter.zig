const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const IsolatedAdapter = @import("isolated_adapter.zig").IsolatedAdapter;

const NetworkAdapter = contracts.NetworkAdapter;
const AdapterConfig = contracts.AdapterConfig;

/// Ingress-Only Network Adapter (`driver: ingress_only`).
/// Permits inbound listener binding while rejecting all outbound client exchanges via `IsolatedAdapter` semantics.
pub const IngressOnlyAdapter = struct {
    comptime {
        NetworkAdapter.assertImplements(@This());
    }

    inner: IsolatedAdapter,
    listen_endpoint: ?[]const u8,

    pub fn createHeap(
        allocator: Allocator,
        config: AdapterConfig,
        ctx: @import("mod.zig").AdapterDriverContext,
    ) anyerror!NetworkAdapter {
        return try IsolatedAdapter.createHeap(allocator, config, ctx);
    }

    pub fn networkAdapter(self: *IngressOnlyAdapter) NetworkAdapter {
        return self.inner.networkAdapter();
    }

    pub const outboundAdapter = networkAdapter;
};

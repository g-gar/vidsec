const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/ast.zig");
const network_adapter = @import("network_adapter.zig");
pub const NetworkAdapter = network_adapter.NetworkAdapter;

/// Registry of live Virtual Network Adapter instances indexed by logical `network_id`.
pub const NetworkRegistry = struct {
    allocator: Allocator,
    adapters: std.StringHashMapUnmanaged(*NetworkAdapter) = .empty,

    pub fn init(allocator: Allocator) NetworkRegistry {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NetworkRegistry) void {
        var it = self.adapters.valueIterator();
        while (it.next()) |adapter_ptr| {
            adapter_ptr.*.deinit();
            self.allocator.destroy(adapter_ptr.*);
        }
        self.adapters.deinit(self.allocator);
    }

    pub fn resolveOrCreate(self: *NetworkRegistry, spec: ast.NetworkSpec) !*NetworkAdapter {
        if (self.adapters.get(spec.id)) |existing| {
            return existing;
        }
        const ptr = try self.allocator.create(NetworkAdapter);
        errdefer self.allocator.destroy(ptr);
        ptr.* = try NetworkAdapter.init(self.allocator, spec);
        try self.adapters.put(self.allocator, spec.id, ptr);
        return ptr;
    }

    pub fn ensureBuiltinIsolated(self: *NetworkRegistry, id: []const u8) !*NetworkAdapter {
        if (self.adapters.get(id)) |existing| {
            return existing;
        }
        return self.resolveOrCreate(.{
            .id = id,
            .driver = .none,
        });
    }

    pub fn get(self: *const NetworkRegistry, id: []const u8) ?*NetworkAdapter {
        return self.adapters.get(id);
    }
};

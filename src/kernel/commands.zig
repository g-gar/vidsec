const std = @import("std");
const Allocator = std.mem.Allocator;
const inbound_mod = @import("../transport/inbound/mod.zig");

pub const CustomCommandHandler = inbound_mod.CustomCommandHandler;
pub const InvocationRequest = inbound_mod.InvocationRequest;
pub const InvocationResponse = inbound_mod.InvocationResponse;

/// Registry for custom subcommands exposed dynamically through the Inbound Dispatcher (CLI, HTTP, gRPC).
pub const CommandRegistry = struct {
    allocator: Allocator,
    commands: std.StringHashMapUnmanaged(CustomCommandHandler) = .empty,

    pub fn init(allocator: Allocator) CommandRegistry {
        return .{
            .allocator = allocator,
            .commands = .empty,
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        var it = self.commands.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.commands.deinit(self.allocator);
    }

    pub fn registerCommand(self: *CommandRegistry, name: []const u8, handler: CustomCommandHandler) !void {
        if (!self.commands.contains(name)) {
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.commands.put(self.allocator, owned, handler);
        } else {
            try self.commands.put(self.allocator, name, handler);
        }
    }

    pub fn registerCommandFn(
        self: *CommandRegistry,
        name: []const u8,
        comptime fn_ptr: *const fn (allocator: Allocator, req: InvocationRequest) anyerror!InvocationResponse,
    ) !void {
        const Wrapper = struct {
            fn call(_: ?*anyopaque, alloc: Allocator, req: InvocationRequest) anyerror!InvocationResponse {
                return fn_ptr(alloc, req);
            }
        };
        try self.registerCommand(name, .{ .ptr = null, .handler = &Wrapper.call });
    }

    pub fn bindToDispatcher(self: *const CommandRegistry, dispatcher: *inbound_mod.InboundDispatcher) !void {
        var it = self.commands.iterator();
        while (it.next()) |entry| {
            try dispatcher.registerCommand(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

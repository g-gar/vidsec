const std = @import("std");
const Allocator = std.mem.Allocator;
const exchange_mod = @import("exchange.zig");
const NetExchange = exchange_mod.NetExchange;
const NetResult = exchange_mod.NetResult;

/// Polymorphic VTable interface for Packet Capture & Telemetry Sinks (`MemoryEventSink`, custom sinks, etc.).
pub const PacketSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onExchange: *const fn (ctx: *anyopaque, exchange: *const NetExchange, result: *const NetResult) anyerror!void,
        onTlsSecret: *const fn (ctx: *anyopaque, keylog_line: []const u8) anyerror!void,
        getBytes: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn onExchange(self: PacketSink, exchange: *const NetExchange, result: *const NetResult) !void {
        try self.vtable.onExchange(self.ptr, exchange, result);
    }

    pub fn onTlsSecret(self: PacketSink, keylog_line: []const u8) !void {
        try self.vtable.onTlsSecret(self.ptr, keylog_line);
    }

    pub fn getBytes(self: PacketSink) ?[]const u8 {
        if (self.vtable.getBytes) |f| {
            return f(self.ptr);
        }
        return null;
    }

    pub fn deinit(self: PacketSink, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "packetSink")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn packetSink(*" ++ @typeName(T) ++ ") PacketSink'");
            }
        }
    }
};

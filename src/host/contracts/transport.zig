const std = @import("std");
const Allocator = std.mem.Allocator;
const envelope = @import("envelope.zig");

pub const InvocationRequest = envelope.InvocationRequest;
pub const InvocationResponse = envelope.InvocationResponse;

// Forward declaration of HostDispatcher to break circular dependency
pub const HostDispatcherPtr = *anyopaque;
pub const DispatchFn = *const fn (ctx: HostDispatcherPtr, req: InvocationRequest) anyerror!InvocationResponse;

/// Polymorphic abstract interface for Inbound Host Transports (CLI, HTTP server, gRPC service, IPC).
pub const HostTransport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ctx: *const anyopaque) []const u8,
        serve: *const fn (ctx: *anyopaque, dispatcher_ctx: HostDispatcherPtr, dispatch_fn: DispatchFn) anyerror!u8,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn name(self: HostTransport) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn serve(self: HostTransport, dispatcher_ctx: HostDispatcherPtr, dispatch_fn: DispatchFn) anyerror!u8 {
        return try self.vtable.serve(self.ptr, dispatcher_ctx, dispatch_fn);
    }

    pub fn deinit(self: HostTransport, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "hostTransport")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn hostTransport(*" ++ @typeName(T) ++ ") HostTransport'");
            }
        }
    }
};

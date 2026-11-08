const std = @import("std");
const Allocator = std.mem.Allocator;
const envelope = @import("envelope.zig");

pub const InvocationRequest = envelope.InvocationRequest;
pub const InvocationResponse = envelope.InvocationResponse;

// Forward declaration of Dispatcher pointer to break circular dependency
pub const DispatcherPtr = *anyopaque;
pub const DispatchFn = *const fn (ctx: DispatcherPtr, req: InvocationRequest) anyerror!InvocationResponse;

pub const HostDispatcherPtr = DispatcherPtr;

/// Polymorphic abstract interface for Inbound Transports (CLI, HTTP server, gRPC service, IPC).
pub const InboundTransport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ctx: *const anyopaque) []const u8,
        serve: *const fn (ctx: *anyopaque, dispatcher_ctx: DispatcherPtr, dispatch_fn: DispatchFn) anyerror!u8,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn name(self: InboundTransport) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn serve(self: InboundTransport, dispatcher_ctx: DispatcherPtr, dispatch_fn: DispatchFn) anyerror!u8 {
        return try self.vtable.serve(self.ptr, dispatcher_ctx, dispatch_fn);
    }

    pub fn deinit(self: InboundTransport, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "inboundTransport") and !@hasDecl(T, "hostTransport")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn inboundTransport(*" ++ @typeName(T) ++ ") InboundTransport'");
            }
        }
    }
};

/// Backward compatibility alias
pub const HostTransport = InboundTransport;

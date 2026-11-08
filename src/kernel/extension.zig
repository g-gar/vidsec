const std = @import("std");
const Allocator = std.mem.Allocator;
const context_mod = @import("context.zig");

pub const KernelContext = context_mod.KernelContext;

/// First-class Extension interface for Flowdata Microkernel.
/// Grants extensions open access across the 5 internal planes of the engine:
/// 1. AST Compiler Passes
/// 2. Telemetry & Lifecycle Bus
/// 3. Inbound Dispatcher Commands
/// 4. Dataflow Algebra & DSL Resolvers
/// 5. I/O Registries (Datasources, Inbound, Outbound, Plugins)
pub const Extension = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *const anyopaque) []const u8,
        register: *const fn (ptr: *anyopaque, kernel: *KernelContext) anyerror!void,
        deinit: ?*const fn (ptr: *anyopaque, allocator: Allocator) void = null,
    };

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "name") or !@hasDecl(T, "register")) {
                @compileError(@typeName(T) ++ " must implement name() and register(*KernelContext)");
            }
        }
    }

    pub fn name(self: Extension) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn register(self: Extension, kernel: *KernelContext) anyerror!void {
        return self.vtable.register(self.ptr, kernel);
    }

    pub fn deinit(self: Extension, allocator: Allocator) void {
        if (self.vtable.deinit) |df| df(self.ptr, allocator);
    }

    /// Helper for stateless module extensions.
    pub fn fromStateless(
        comptime ext_name: []const u8,
        comptime register_fn: *const fn (kernel: *KernelContext) anyerror!void,
    ) Extension {
        const S = struct {
            var dummy: u8 = 0;
            fn getName(_: *const anyopaque) []const u8 {
                return ext_name;
            }
            fn doRegister(_: *anyopaque, k: *KernelContext) anyerror!void {
                return register_fn(k);
            }
            const vtable = VTable{
                .name = &getName,
                .register = &doRegister,
                .deinit = null,
            };
        };
        return .{ .ptr = @ptrCast(&S.dummy), .vtable = &S.vtable };
    }
};

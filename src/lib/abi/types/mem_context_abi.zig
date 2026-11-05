const std = @import("std");

/// C-ABI compliant memory context passed from host to plugin tasks.
/// Encapsulates host allocation and deallocation across shared library boundaries.
pub const MemContext_ABI = extern struct {
    opaque_ctx: *anyopaque,
    alloc_fn: *const fn (ctx: *anyopaque, len: usize, alignment: u32) callconv(.c) ?[*]u8,
    free_fn: *const fn (ctx: *anyopaque, ptr: [*]u8, len: usize, alignment: u32) callconv(.c) void,

    /// Wraps a native Zig `std.mem.Allocator` into a C-ABI `MemContext_ABI`.
    pub fn fromAllocator(alloc_ptr: *const std.mem.Allocator) MemContext_ABI {
        const Trampoline = struct {
            fn cAlloc(ctx: *anyopaque, len: usize, alignment: u32) callconv(.c) ?[*]u8 {
                const a: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
                const align_val = std.mem.Alignment.fromByteUnits(if (alignment == 0) 1 else alignment);
                return a.vtable.alloc(a.ptr, len, align_val, 0);
            }

            fn cFree(ctx: *anyopaque, ptr: [*]u8, len: usize, alignment: u32) callconv(.c) void {
                const a: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
                const align_val = std.mem.Alignment.fromByteUnits(if (alignment == 0) 1 else alignment);
                a.vtable.free(a.ptr, ptr[0..len], align_val, 0);
            }
        };

        return .{
            .opaque_ctx = @constCast(@ptrCast(alloc_ptr)),
            .alloc_fn = &Trampoline.cAlloc,
            .free_fn = &Trampoline.cFree,
        };
    }

    /// Converts a C-ABI `MemContext_ABI` into a native Zig `std.mem.Allocator`.
    pub fn toAllocator(self: *const MemContext_ABI) std.mem.Allocator {
        const ClientTrampoline = struct {
            fn zigAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
                _ = ret_addr;
                const mem_ctx: *const MemContext_ABI = @ptrCast(@alignCast(ctx));
                return mem_ctx.alloc_fn(mem_ctx.opaque_ctx, len, @intCast(alignment.toByteUnits()));
            }

            fn zigResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
                _ = ctx;
                _ = buf;
                _ = alignment;
                _ = new_len;
                _ = ret_addr;
                return false;
            }

            fn zigRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                _ = ctx;
                _ = memory;
                _ = alignment;
                _ = new_len;
                _ = ret_addr;
                return null;
            }

            fn zigFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
                _ = ret_addr;
                const mem_ctx: *const MemContext_ABI = @ptrCast(@alignCast(ctx));
                mem_ctx.free_fn(mem_ctx.opaque_ctx, buf.ptr, buf.len, @intCast(alignment.toByteUnits()));
            }

            const vtable = std.mem.Allocator.VTable{
                .alloc = &zigAlloc,
                .resize = &zigResize,
                .remap = &zigRemap,
                .free = &zigFree,
            };
        };

        return .{
            .ptr = @constCast(@ptrCast(self)),
            .vtable = &ClientTrampoline.vtable,
        };
    }
};

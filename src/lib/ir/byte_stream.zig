const std = @import("std");

/// Abstract byte reader interface for zero-copy or chunked stream inspection.
/// Independent of any file system or pipeline harness.
pub const ByteStream = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readAt: *const fn (ctx: *const anyopaque, offset: u64, dest: []u8) error{ ReadFailed, EndOfStream }!usize,
        size: *const fn (ctx: *const anyopaque) u64,
    };

    pub fn readAt(self: ByteStream, offset: u64, dest: []u8) error{ ReadFailed, EndOfStream }!usize {
        return self.vtable.readAt(self.ptr, offset, dest);
    }

    pub fn size(self: ByteStream) u64 {
        return self.vtable.size(self.ptr);
    }
};

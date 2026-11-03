/// Non-owning byte slice representation across the C-ABI boundary.
pub const Slice_ABI = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromSlice(s: []const u8) Slice_ABI {
        return .{
            .ptr = if (s.len > 0) s.ptr else "",
            .len = s.len,
        };
    }

    pub fn toSlice(self: Slice_ABI) []const u8 {
        if (self.len == 0) return &.{};
        return self.ptr[0..self.len];
    }
};

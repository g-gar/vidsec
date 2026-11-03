/// Bounded byte window view yielded lazily by `HostApiVTable_ABI.next_window`.
pub const WindowView_ABI = extern struct {
    window_id: i64,
    file_offset: u64,
    byte_length: u64,
    tag_ptr: [*]const u8,
    tag_len: usize,

    pub fn tagSlice(self: WindowView_ABI) []const u8 {
        if (self.tag_len == 0) return &.{};
        return self.tag_ptr[0..self.tag_len];
    }
};

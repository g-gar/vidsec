pub const ByteInterval = struct {
    start: u64,
    end: u64,
    tag: []const u8,

    pub fn lessThan(_: void, a: ByteInterval, b: ByteInterval) bool {
        if (a.start != b.start) return a.start < b.start;
        return a.end < b.end;
    }
};

pub const IrExternalRefRow = struct {
    ref_id: i64,
    track_id: ?i64 = null,
    uri: []const u8,
};

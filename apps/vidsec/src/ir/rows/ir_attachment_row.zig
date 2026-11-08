pub const IrAttachmentRow = struct {
    attachment_id: i64,
    file_offset: u64,
    byte_length: u64,
    mime_type: []const u8 = "application/octet-stream",
    file_name: []const u8 = "",
};

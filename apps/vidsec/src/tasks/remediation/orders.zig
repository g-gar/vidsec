/// Order emitted by any analysis task when trailing bytes past `highest_root_end`
/// (e.g., appended ZIP/RAR overlay) can be safely truncated.
pub const TruncateOrder = struct {
    new_size: u64,
    rule_id: []const u8,
    reason: []const u8 = "",
};

/// Order emitted by any analysis task when a bounded region (e.g., `free`/`JUNK` padding
/// or unreferenced slack) contains suspicious payload bytes that can be zero-filled.
pub const ZeroOutOrder = struct {
    offset: u64,
    length: u64,
    rule_id: []const u8,
    reason: []const u8 = "",
};

pub const RemediationOutcome = struct {
    data: []const u8,
    action: []const u8,
    rule_id: []const u8,
    offset: u64,
    length: u64,
    new_size: u64,
    applied: bool,
    requires_reverify: bool,
};

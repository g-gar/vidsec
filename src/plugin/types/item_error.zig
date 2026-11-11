/// Strongly-typed error descriptor emitted on the implicit `"errors"` channel
/// when an elemental task uses `on_item_error: collect` (ARCH-016 §8.6).
pub const ItemError = struct {
    index: u64,
    error_name: []const u8,
    message: []const u8 = "",
};

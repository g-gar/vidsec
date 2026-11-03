/// Discriminant for `Value_ABI` with a strict 1:1 mapping to `schemas.yaml` and SQLite `STRICT` types.
pub const ValueTag_ABI = enum(u32) {
    null_val = 0,
    int64 = 1,
    float64 = 2,
    boolean = 3,
    text = 4,
    blob = 5,
};

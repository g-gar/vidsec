const std = @import("std");
const yaml = @import("../yaml/lib/mod.zig");

/// Universal column logical types supported across all Flowdata storage engines.
pub const ColumnType = enum {
    int64,
    uint64,
    float64,
    bool,
    text,
    bytes,
    timestamp, // Standardized as int64 Unix epoch (microsecond precision)
    json,
    enum_type,
    // Backward-compatibility alias during refactoring
    blob,
    any,

    pub fn isInteger(self: ColumnType) bool {
        return self == .int64 or self == .uint64 or self == .timestamp;
    }

    pub fn isFloat(self: ColumnType) bool {
        return self == .float64;
    }

    pub fn isText(self: ColumnType) bool {
        return self == .text or self == .json or self == .enum_type;
    }

    pub fn isBinary(self: ColumnType) bool {
        return self == .bytes or self == .blob;
    }
};

pub const DefaultValue = union(enum) {
    null_val,
    int64: i64,
    uint64: u64,
    float64: f64,
    boolean: bool,
    text: []const u8,
    raw_expr: []const u8,
};

pub const SortOrder = enum {
    asc,
    desc,
};

pub const ForeignKeyAction = enum {
    no_action,
    restrict,
    set_null,
    set_default,
    cascade,
};

/// Custom scalar reference for `ref: <table_name>.<column_name>`.
pub const ForeignKeyRef = struct {
    table: []const u8,
    column: []const u8,

    pub fn yamlParseScalar(
        arena: std.mem.Allocator,
        scalar: yaml.Scalar,
        _: yaml.SourceLoc,
    ) !ForeignKeyRef {
        const s = scalar.value;
        const dot_idx = std.mem.indexOfScalar(u8, s, '.') orelse return error.InvalidForeignKeyRef;
        const ref_tbl = s[0..dot_idx];
        const ref_col = s[dot_idx + 1 ..];
        if (ref_tbl.len == 0 or ref_col.len == 0 or std.mem.indexOfScalar(u8, ref_col, '.') != null) {
            return error.InvalidForeignKeyRef;
        }
        return ForeignKeyRef{
            .table = try arena.dupe(u8, ref_tbl),
            .column = try arena.dupe(u8, ref_col),
        };
    }
};

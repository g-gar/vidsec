const std = @import("std");

/// Generic ordered key-value map for engine-agnostic schema definitions.
pub fn NamedMap(comptime V: type) type {
    return struct {
        entries: []const Entry = &.{},

        pub const Entry = struct {
            key: []const u8,
            value: V,
        };

        pub fn get(self: @This(), key: []const u8) ?V {
            for (self.entries) |e| {
                if (std.mem.eql(u8, e.key, key)) return e.value;
            }
            return null;
        }

        pub fn contains(self: @This(), key: []const u8) bool {
            return self.get(key) != null;
        }

        pub fn count(self: @This()) usize {
            return self.entries.len;
        }
    };
}

/// Scalar value in a declarative seed row, preserving whether it was unquoted (`plain`)
/// so literal `null` can be distinguished from the string `"null"`.
pub const SeedScalar = struct {
    value: []const u8,
    quote_style: enum { plain, quoted } = .plain,
};

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

/// Reference to `<table_name>.<column_name>`.
pub const ForeignKeyRef = struct {
    table: []const u8,
    column: []const u8,
};

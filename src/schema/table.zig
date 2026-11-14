const std = @import("std");
const types = @import("types.zig");
const NamedMap = types.NamedMap;
const SeedScalar = types.SeedScalar;
const column = @import("column.zig");
const ColumnSpec = column.ColumnSpec;
const index = @import("index.zig");
const IndexSpec = index.IndexSpec;

pub const SeedRow = NamedMap(SeedScalar);

pub const TableSchema = struct {
    columns: NamedMap(ColumnSpec) = .{},
    indexes: []const IndexSpec = &.{},
    primary_key: []const []const u8 = &.{},
    unique_keys: []const []const []const u8 = &.{},
    checks: []const []const u8 = &.{},
    strict: bool = true,
    without_rowid: bool = false,
    temp: bool = false,
    seeds: []const SeedRow = &.{},

    pub fn findColumn(self: *const TableSchema, col_name: []const u8) ?ColumnSpec {
        return self.columns.get(col_name);
    }

    pub fn validate(self: *const TableSchema) !void {
        if (self.columns.count() == 0) return error.EmptyTableColumns;

        for (self.columns.entries) |col_entry| {
            try col_entry.value.validate();
        }

        for (self.primary_key) |pk_col| {
            if (!self.columns.contains(pk_col)) return error.CompositeKeyColumnNotFound;
        }

        for (self.unique_keys) |uk_group| {
            if (uk_group.len == 0) return error.CompositeKeyColumnNotFound;
            for (uk_group) |uk_col| {
                if (!self.columns.contains(uk_col)) return error.CompositeKeyColumnNotFound;
            }
        }

        for (self.indexes) |idx_spec| {
            for (idx_spec.columns) |idx_col| {
                if (!self.columns.contains(idx_col)) return error.IndexedColumnNotFound;
            }
        }

        for (self.seeds) |seed_row| {
            for (seed_row.entries) |entry| {
                if (!self.columns.contains(entry.key)) return error.SeedColumnNotFound;
            }
        }
    }
};

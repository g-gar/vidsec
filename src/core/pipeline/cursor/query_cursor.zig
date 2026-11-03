const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("vidsec_abi");
const sqlite_core = @import("../../sqlite/mod.zig");
const Stmt = sqlite_core.sqlite_lib.Stmt;
const SqlValue = sqlite_core.sqlite_lib.Value;
const Value_ABI = abi.Value_ABI;
const NamedField_ABI = abi.NamedField_ABI;
const RowView_ABI = abi.RowView_ABI;
const WindowView_ABI = abi.WindowView_ABI;

/// SQLite-backed relational query cursor for steps querying SQLite tables or SQL rules.
pub const QueryCursor = struct {
    stream_source: ?[]const u8,
    stmt: Stmt,
    col_names_z: [][:0]u8,
    row_fields_buf: []NamedField_ABI,

    pub fn init(allocator: Allocator, stream_source: ?[]const u8, mut_stmt: Stmt) !QueryCursor {
        var stmt = mut_stmt;
        const count = stmt.columnCount();
        var col_names = try allocator.alloc([:0]u8, count);
        errdefer allocator.free(col_names);

        for (0..count) |i| {
            col_names[i] = try allocator.dupeZ(u8, stmt.columnName(i));
        }

        const fields_buf = try allocator.alloc(NamedField_ABI, count);
        return .{
            .stream_source = stream_source,
            .stmt = stmt,
            .col_names_z = col_names,
            .row_fields_buf = fields_buf,
        };
    }

    pub fn deinit(self: *QueryCursor, allocator: Allocator) void {
        for (self.col_names_z) |c_name| {
            allocator.free(c_name);
        }
        allocator.free(self.col_names_z);
        allocator.free(self.row_fields_buf);
        self.stmt.deinit();
    }

    pub fn findColIndex(self: *const QueryCursor, name: []const u8) ?usize {
        for (self.col_names_z, 0..) |col_z, idx| {
            if (std.ascii.eqlIgnoreCase(col_z, name)) return idx;
        }
        return null;
    }

    pub fn nextRow(self: *QueryCursor) !?RowView_ABI {
        const maybe_row = try self.stmt.step();
        const row = maybe_row orelse return null;

        for (0..self.col_names_z.len) |i| {
            const sql_val = row.value(i);
            self.row_fields_buf[i] = .{
                .name_ptr = self.col_names_z[i].ptr,
                .value = valueToAbi(sql_val),
            };
        }

        return RowView_ABI{
            .fields_ptr = if (self.row_fields_buf.len > 0) self.row_fields_buf.ptr else undefined,
            .fields_len = self.row_fields_buf.len,
        };
    }

    pub fn nextWindow(self: *QueryCursor) !?WindowView_ABI {
        const maybe_row = try self.stmt.step();
        const row = maybe_row orelse return null;

        const col_count = row.columnCount();
        if (col_count < 3) return error.InvalidArgument;

        const id_idx = self.findColIndex("id") orelse self.findColIndex("window_id") orelse 0;
        const off_idx = self.findColIndex("offset") orelse self.findColIndex("file_offset") orelse 1;
        const len_idx = self.findColIndex("length") orelse self.findColIndex("byte_length") orelse 2;
        const tag_idx = self.findColIndex("tag") orelse self.findColIndex("region_tag") orelse
            (if (col_count >= 4) @as(?usize, 3) else null);

        const win_id = row.int64(id_idx);
        const raw_offset = row.int64(off_idx);
        const raw_length = row.int64(len_idx);

        if (raw_offset < 0 or raw_length < 0) return error.OutOfBounds;
        const offset_u64: u64 = @intCast(raw_offset);
        const length_u64: u64 = @intCast(raw_length);

        const tag_slice: []const u8 = if (tag_idx) |t_i| row.text(t_i) else "";

        return WindowView_ABI{
            .window_id = win_id,
            .file_offset = offset_u64,
            .byte_length = length_u64,
            .tag_ptr = if (tag_slice.len > 0) tag_slice.ptr else "",
            .tag_len = tag_slice.len,
        };
    }

    pub fn valueToAbi(v: SqlValue) Value_ABI {
        return switch (v) {
            .null_val => Value_ABI.nullVal(),
            .int64 => |i| Value_ABI.fromInt(i),
            .float64 => |f| Value_ABI.fromFloat(f),
            .boolean => |b| Value_ABI.fromBool(b),
            .text => |t| Value_ABI.fromText(t),
            .blob => |b| Value_ABI.fromBlob(b),
        };
    }
};

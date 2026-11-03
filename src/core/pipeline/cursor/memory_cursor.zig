const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("vidsec_abi");
const sqlite_core = @import("../../sqlite/mod.zig");
const Value = sqlite_core.Value;
const Value_ABI = abi.Value_ABI;
const NamedField_ABI = abi.NamedField_ABI;
const RowView_ABI = abi.RowView_ABI;
const WindowView_ABI = abi.WindowView_ABI;
const StoredRecord = @import("../repository/memory_repository.zig").StoredRecord;

/// In-memory record and window cursor for zero-disk, zero-SQL streaming between pipeline tasks.
pub const MemoryCursor = struct {
    stream_source: ?[]const u8,
    records: []const StoredRecord,
    current_idx: usize = 0,
    fields_buf: std.ArrayListUnmanaged(NamedField_ABI) = .empty,

    pub fn init(stream_source: ?[]const u8, records: []const StoredRecord) MemoryCursor {
        return .{
            .stream_source = stream_source,
            .records = records,
            .current_idx = 0,
            .fields_buf = .empty,
        };
    }

    pub fn deinit(self: *MemoryCursor, allocator: Allocator) void {
        self.fields_buf.deinit(allocator);
    }

    pub fn nextRow(self: *MemoryCursor, allocator: Allocator) !?RowView_ABI {
        if (self.current_idx >= self.records.len) return null;
        const rec = self.records[self.current_idx];
        self.current_idx += 1;

        self.fields_buf.clearRetainingCapacity();
        try self.fields_buf.ensureTotalCapacity(allocator, rec.fields.len);

        for (rec.fields) |f| {
            self.fields_buf.appendAssumeCapacity(.{
                .name_ptr = f.name.ptr,
                .value = valueToAbi(f.value),
            });
        }

        return RowView_ABI{
            .fields_ptr = if (self.fields_buf.items.len > 0) self.fields_buf.items.ptr else undefined,
            .fields_len = self.fields_buf.items.len,
        };
    }

    pub fn nextWindow(self: *MemoryCursor) !?WindowView_ABI {
        if (self.current_idx >= self.records.len) return null;
        const rec = self.records[self.current_idx];
        self.current_idx += 1;

        var win_id: i64 = @intCast(self.current_idx);
        var offset: u64 = 0;
        var length: u64 = 0;
        var tag_slice: []const u8 = "";

        for (rec.fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, "id") or std.ascii.eqlIgnoreCase(f.name, "window_id")) {
                win_id = switch (f.value) {
                    .int64 => |v| v,
                    else => win_id,
                };
            } else if (std.ascii.eqlIgnoreCase(f.name, "offset") or
                std.ascii.eqlIgnoreCase(f.name, "file_offset") or
                std.ascii.eqlIgnoreCase(f.name, "header_offset"))
            {
                offset = switch (f.value) {
                    .int64 => |v| if (v >= 0) @intCast(v) else 0,
                    else => 0,
                };
            } else if (std.ascii.eqlIgnoreCase(f.name, "length") or
                std.ascii.eqlIgnoreCase(f.name, "byte_length"))
            {
                length = switch (f.value) {
                    .int64 => |v| if (v >= 0) @intCast(v) else 0,
                    else => 0,
                };
            } else if (std.ascii.eqlIgnoreCase(f.name, "tag") or
                std.ascii.eqlIgnoreCase(f.name, "region_tag") or
                std.ascii.eqlIgnoreCase(f.name, "tag_name"))
            {
                tag_slice = switch (f.value) {
                    .text => |t| t,
                    else => "",
                };
            }
        }

        return WindowView_ABI{
            .window_id = win_id,
            .file_offset = offset,
            .byte_length = length,
            .tag_ptr = if (tag_slice.len > 0) tag_slice.ptr else "",
            .tag_len = tag_slice.len,
        };
    }

    pub fn valueToAbi(v: Value) Value_ABI {
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

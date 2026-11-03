const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const NamedValue = sqlite_core.NamedValue;
const Value = sqlite_core.Value;
const StorageRepository = @import("storage_repository.zig").StorageRepository;

pub const StoredField = struct {
    name: [:0]const u8,
    value: Value,
};

pub const StoredRecord = struct {
    fields: []StoredField,
};

pub const MemoryTable = struct {
    name: []const u8,
    records: std.ArrayListUnmanaged(StoredRecord) = .empty,

    pub fn deinit(self: *MemoryTable, allocator: Allocator) void {
        for (self.records.items) |r| {
            for (r.fields) |f| {
                allocator.free(f.name);
                switch (f.value) {
                    .text => |t| allocator.free(t),
                    .blob => |b| allocator.free(b),
                    else => {},
                }
            }
            allocator.free(r.fields);
        }
        self.records.deinit(allocator);
        allocator.free(self.name);
    }
};

/// High-performance in-memory repository for zero-copy streaming between pipeline tasks.
pub const MemoryRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    tables: std.StringHashMapUnmanaged(MemoryTable) = .empty,

    pub fn init(allocator: Allocator) MemoryRepository {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryRepository) void {
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
    }

    pub fn storageRepository(self: *MemoryRepository) StorageRepository {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn getOrCreateTable(self: *MemoryRepository, name: []const u8) !*MemoryTable {
        const entry = try self.tables.getOrPut(self.allocator, name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, name);
            entry.value_ptr.* = .{
                .name = try self.allocator.dupe(u8, name),
            };
        }
        return entry.value_ptr;
    }

    pub fn saveRecord(self: *MemoryRepository, table_name: []const u8, fields: []const NamedValue) !void {
        const table = try self.getOrCreateTable(table_name);
        const stored_fields = try self.allocator.alloc(StoredField, fields.len);
        errdefer self.allocator.free(stored_fields);

        for (fields, 0..) |f, i| {
            const owned_name = try self.allocator.dupeZ(u8, f.name);
            const owned_val = switch (f.value) {
                .text => |t| Value{ .text = try self.allocator.dupe(u8, t) },
                .blob => |b| Value{ .blob = try self.allocator.dupe(u8, b) },
                else => f.value,
            };
            stored_fields[i] = .{
                .name = owned_name,
                .value = owned_val,
            };
        }

        try table.records.append(self.allocator, .{ .fields = stored_fields });
    }

    pub fn recordCount(self: *MemoryRepository, table_name: []const u8) usize {
        if (self.tables.get(table_name)) |tbl| {
            return tbl.records.items.len;
        }
        return 0;
    }

    const vtable = StorageRepository.VTable{
        .saveRecord = saveRecordImpl,
        .recordCount = recordCountImpl,
        .deinit = deinitImpl,
    };

    fn saveRecordImpl(ctx: *anyopaque, table_name: []const u8, fields: []const NamedValue) anyerror!void {
        const self: *MemoryRepository = @ptrCast(@alignCast(ctx));
        try self.saveRecord(table_name, fields);
    }

    fn recordCountImpl(ctx: *anyopaque, table_name: []const u8) usize {
        const self: *MemoryRepository = @ptrCast(@alignCast(ctx));
        return self.recordCount(table_name);
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *MemoryRepository = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const NamedValue = sqlite_core.NamedValue;
const Value = sqlite_core.Value;

/// Thread-safe in-memory registry capturing outputs emitted by executed pipeline tasks.
/// Enables downstream steps to resolve inputs via `task_name.field_name` with zero disk I/O.
pub const TaskOutputStore = struct {
    allocator: Allocator,
    tasks: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Value)) = .empty,

    pub fn init(allocator: Allocator) TaskOutputStore {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskOutputStore) void {
        var task_iter = self.tasks.iterator();
        while (task_iter.next()) |task_entry| {
            self.allocator.free(task_entry.key_ptr.*);
            var field_iter = task_entry.value_ptr.iterator();
            while (field_iter.next()) |f_entry| {
                self.allocator.free(f_entry.key_ptr.*);
                switch (f_entry.value_ptr.*) {
                    .text => |t| self.allocator.free(t),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                }
            }
            task_entry.value_ptr.deinit(self.allocator);
        }
        self.tasks.deinit(self.allocator);
    }

    pub fn recordField(self: *TaskOutputStore, task_name: []const u8, field_name: []const u8, val: Value) !void {
        const task_entry = try self.tasks.getOrPut(self.allocator, task_name);
        if (!task_entry.found_existing) {
            task_entry.key_ptr.* = try self.allocator.dupe(u8, task_name);
            task_entry.value_ptr.* = .empty;
        }

        const owned_val = switch (val) {
            .text => |t| Value{ .text = try self.allocator.dupe(u8, t) },
            .blob => |b| Value{ .blob = try self.allocator.dupe(u8, b) },
            else => val,
        };

        const field_entry = try task_entry.value_ptr.getOrPut(self.allocator, field_name);
        if (!field_entry.found_existing) {
            field_entry.key_ptr.* = try self.allocator.dupe(u8, field_name);
        } else {
            // Free previous value if text/blob
            switch (field_entry.value_ptr.*) {
                .text => |t| self.allocator.free(t),
                .blob => |b| self.allocator.free(b),
                else => {},
            }
        }
        field_entry.value_ptr.* = owned_val;
    }

    pub fn recordRecord(self: *TaskOutputStore, task_name: []const u8, fields: []const NamedValue) !void {
        for (fields) |f| {
            try self.recordField(task_name, f.name, f.value);
        }
    }

    pub fn getField(self: *const TaskOutputStore, task_name: []const u8, field_name: []const u8) ?Value {
        const task_map = self.tasks.get(task_name) orelse return null;
        return task_map.get(field_name);
    }

    pub fn hasTask(self: *const TaskOutputStore, task_name: []const u8) bool {
        return self.tasks.contains(task_name);
    }
};

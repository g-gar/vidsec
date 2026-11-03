const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const NamedValue = sqlite_core.NamedValue;
const Value = sqlite_core.Value;
const OutputFieldSpec = @import("output_field_spec.zig").OutputFieldSpec;
const StorageRepository = @import("../repository/storage_repository.zig").StorageRepository;

/// Engine router that dispatches emitted fields to memory and/or storage repositories
/// with renaming, type-casting, and value transformations.
pub const FieldRouter = struct {
    allocator: Allocator,
    field_specs: std.StringHashMapUnmanaged(OutputFieldSpec) = .empty,
    default_table: []const u8,

    pub fn init(allocator: Allocator, default_table: []const u8) FieldRouter {
        return .{
            .allocator = allocator,
            .default_table = default_table,
        };
    }

    pub fn deinit(self: *FieldRouter) void {
        self.field_specs.deinit(self.allocator);
    }

    pub fn addFieldSpec(self: *FieldRouter, spec: OutputFieldSpec) !void {
        try self.field_specs.put(self.allocator, spec.name, spec);
    }

    /// Processes an emitted record and routes its projected fields to memory and/or persistent repositories using default_table.
    pub fn dispatchRecord(
        self: *const FieldRouter,
        fields: []const NamedValue,
        maybe_memory_repo: ?StorageRepository,
        maybe_storage_repo: ?StorageRepository,
    ) !void {
        return self.dispatchRecordToTable(self.default_table, fields, maybe_memory_repo, maybe_storage_repo);
    }

    /// Processes an emitted record and routes its projected fields to memory and/or persistent repositories targeting a specific table/channel.
    pub fn dispatchRecordToTable(
        self: *const FieldRouter,
        target_table: []const u8,
        fields: []const NamedValue,
        maybe_memory_repo: ?StorageRepository,
        maybe_storage_repo: ?StorageRepository,
    ) !void {
        const table = if (target_table.len > 0) target_table else self.default_table;

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var mem_fields: std.ArrayListUnmanaged(NamedValue) = .empty;
        var repo_fields: std.ArrayListUnmanaged(NamedValue) = .empty;

        for (fields) |f| {
            const spec = self.field_specs.get(f.name) orelse OutputFieldSpec{
                .name = f.name,
                .target = .both,
            };

            // 1. Apply math transformation (e.g. round, ceil, floor)
            const transformed_val = spec.transform.apply(f.value, spec.round_decimals);

            // 2. Apply type casting (e.g. float to int)
            const final_val = try spec.cast.apply(arena, transformed_val);

            // 3. Renaming
            const target_name = spec.destinationName();

            const projected_field = NamedValue{
                .name = target_name,
                .value = final_val,
            };

            if (spec.target.includesMemory()) {
                try mem_fields.append(arena, projected_field);
            }
            if (spec.target.includesRepo()) {
                try repo_fields.append(arena, projected_field);
            }
        }

        // Dispatch to Memory Repository if requested and available
        if (maybe_memory_repo) |mem_repo| {
            if (mem_fields.items.len > 0) {
                try mem_repo.saveRecord(table, mem_fields.items);
            }
        }

        // Dispatch to Persistent Storage Repository if requested and available
        if (maybe_storage_repo) |storage_repo| {
            if (repo_fields.items.len > 0) {
                try storage_repo.saveRecord(table, repo_fields.items);
            }
        }
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite_core = @import("../../sqlite/mod.zig");
const SqliteRuntime = sqlite_core.SqliteRuntime;
const Value = sqlite_core.Value;
const artifact_mod = @import("../artifact.zig");
const ArtifactStore = artifact_mod.ArtifactStore;
const memory_repo_mod = @import("../repository/memory_repository.zig");
const MemoryRepository = memory_repo_mod.MemoryRepository;
const task_output_store_mod = @import("task_output_store.zig");
const TaskOutputStore = task_output_store_mod.TaskOutputStore;
const input_binding_mod = @import("input_binding.zig");
const InputBinding = input_binding_mod.InputBinding;

pub const ResolverError = error{
    InvalidBindingPath,
    MissingBoundInputValue,
    DatabaseQueryFailed,
    OutOfMemory,
};

/// Universal resolver that binds input values declared as `<source>.<field>`
/// across in-memory task outputs, storage repositories, and artifacts.
pub const InputResolver = struct {
    task_outputs: *const TaskOutputStore,
    memory_repo: *const MemoryRepository,
    db_runtime: ?*SqliteRuntime = null,
    artifacts: ?*ArtifactStore = null,

    pub fn init(
        task_outputs: *const TaskOutputStore,
        memory_repo: *const MemoryRepository,
        db_runtime: ?*SqliteRuntime,
        artifacts: ?*ArtifactStore,
    ) InputResolver {
        return .{
            .task_outputs = task_outputs,
            .memory_repo = memory_repo,
            .db_runtime = db_runtime,
            .artifacts = artifacts,
        };
    }

    /// Resolves an input binding into its transformed, casted runtime Value.
    pub fn resolveValue(
        self: *const InputResolver,
        arena: Allocator,
        binding: InputBinding,
    ) ResolverError!Value {
        var raw_val = self.resolveRawValue(arena, binding.from_path) catch |err| switch (err) {
            error.MissingBoundInputValue, error.InvalidBindingPath => null,
            else => return err,
        };

        if (raw_val == null) {
            if (binding.default_val) |def| {
                raw_val = def;
            } else {
                return error.MissingBoundInputValue;
            }
        }

        const unwrapped = raw_val.?;

        // 1. Apply math transform (e.g. round, floor, ceil, abs)
        const transformed = binding.transform.apply(unwrapped, binding.round_decimals);

        // 2. Apply type cast (e.g. float to int, int to text)
        const casted = binding.cast.apply(arena, transformed) catch return error.OutOfMemory;

        return casted;
    }

    pub fn resolveRawValue(self: *const InputResolver, arena: Allocator, path: []const u8) ResolverError!?Value {
        var it = std.mem.splitScalar(u8, path, '.');
        const part0 = it.next() orelse return error.InvalidBindingPath;
        const part1 = it.next() orelse return error.InvalidBindingPath;
        const maybe_part2 = it.next();

        if (maybe_part2) |part2| {
            // 3 parts: e.g. "db.file_triage.verdict" or "memory.ir_regions.tag"
            if (std.mem.eql(u8, part0, "db") or std.mem.eql(u8, part0, "sqlite")) {
                return self.resolveFromDatabase(arena, part1, part2);
            } else if (std.mem.eql(u8, part0, "memory")) {
                return self.resolveFromMemoryTable(part1, part2);
            }
            return error.InvalidBindingPath;
        }

        // 2 parts: e.g. "parse_container.file_size" or "file_triage.verdict" or "artifacts.quarantine_sample"
        // 1. Check artifact store
        if (std.mem.eql(u8, part0, "artifacts") or std.mem.eql(u8, part0, "artifact")) {
            if (self.artifacts) |arts| {
                if (arts.getBuffer(part1)) |buf| {
                    return Value{ .text = try arena.dupe(u8, buf.slice()) };
                } else |_| {}
            }
            return null;
        }

        // 2. Check in-memory task output store
        if (self.task_outputs.getField(part0, part1)) |val| {
            return val;
        }

        // 3. Check in-memory repository table
        if (self.resolveFromMemoryTable(part0, part1)) |val| {
            return val;
        }

        // 4. Fallback: check SQLite table directly
        if (self.db_runtime) |_| {
            if (self.resolveFromDatabase(arena, part0, part1)) |val| {
                return val;
            } else |_| {}
        }

        return null;
    }

    fn resolveFromMemoryTable(self: *const InputResolver, table_name: []const u8, field_name: []const u8) ?Value {
        const tbl = self.memory_repo.tables.get(table_name) orelse return null;
        if (tbl.records.items.len == 0) return null;
        // Take latest record emitted
        const rec = tbl.records.items[tbl.records.items.len - 1];
        for (rec.fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, field_name)) {
                return f.value;
            }
        }
        return null;
    }

    fn resolveFromDatabase(
        self: *const InputResolver,
        arena: Allocator,
        table_name: []const u8,
        column_name: []const u8,
    ) ResolverError!?Value {
        const db = self.db_runtime orelse return null;
        const sql = std.fmt.allocPrint(
            arena,
            "SELECT {s} FROM {s} ORDER BY rowid DESC LIMIT 1",
            .{ column_name, table_name },
        ) catch return error.OutOfMemory;

        var stmt = db.db.prepareReadOnly(sql) catch return error.DatabaseQueryFailed;
        defer stmt.deinit();

        const maybe_row = stmt.step() catch return error.DatabaseQueryFailed;
        const row = maybe_row orelse return null;

        return row.value(0);
    }
};

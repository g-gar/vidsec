const std = @import("std");
const schema = @import("../schema/mod.zig");
const SchemaCatalog = schema.SchemaCatalog;
const TableSchema = schema.TableSchema;
const ColumnType = schema.ColumnType;
const plugin = @import("../plugin/mod.zig");
const TaskDescriptor_ABI = plugin.abi.TaskDescriptor_ABI;
const repository = @import("../repository/mod.zig");
const Capabilities = repository.Capabilities;
const WriteMode = repository.WriteMode;

pub const PreflightError = error{
    SchemaTypeMismatch,
    SchemaNullabilityMismatch,
    MissingPrimaryKeyField,
    UnsupportedDriverCapability,
};

/// Returns `true` if a task's logical field type string is compatible with a `SchemaCatalog` `ColumnType`.
pub fn areTypesCompatible(logical_type: []const u8, col_type: ColumnType) bool {
    return switch (col_type) {
        .int64, .timestamp => std.mem.eql(u8, logical_type, "int64") or std.mem.eql(u8, logical_type, "timestamp"),
        .uint64 => std.mem.eql(u8, logical_type, "uint64") or std.mem.eql(u8, logical_type, "int64"),
        .float64 => std.mem.eql(u8, logical_type, "float64") or std.mem.eql(u8, logical_type, "int64") or std.mem.eql(u8, logical_type, "uint64"),
        .bool => std.mem.eql(u8, logical_type, "bool"),
        .text, .json, .enum_type => std.mem.eql(u8, logical_type, "text") or std.mem.eql(u8, logical_type, "json") or std.mem.eql(u8, logical_type, "enum_type"),
        .bytes, .blob => std.mem.eql(u8, logical_type, "bytes") or std.mem.eql(u8, logical_type, "text"),
        .any => true,
    };
}

/// Cross-checks a task's `outputMeta()` against a target `TableSchema` (ARCH-009A §2.2).
pub fn validateTaskOutputSchema(desc: *const TaskDescriptor_ABI, table: TableSchema) PreflightError!void {
    const out_meta = desc.outputMeta();
    if (out_meta.len == 0) return;

    // 1. Check type and nullability compatibility for each emitted field
    for (out_meta) |fm| {
        const fname = fm.nameSlice();
        const col_spec = table.findColumn(fname) orelse continue;

        if (!areTypesCompatible(fm.logicalTypeSlice(), col_spec.col_type)) {
            return error.SchemaTypeMismatch;
        }

        const has_default = col_spec.default_raw != null or col_spec.default_expr != null or col_spec.autoincrement;
        if (fm.nullable and !col_spec.nullable and !has_default) {
            return error.SchemaNullabilityMismatch;
        }
    }

    // 2. Check that required primary key columns are present in outputMeta
    for (table.columns.entries) |entry| {
        const is_pk = entry.value.pk or blk: {
            for (table.primary_key) |pk_col| {
                if (std.mem.eql(u8, pk_col, entry.key)) break :blk true;
            }
            break :blk false;
        };
        if (!is_pk) continue;

        const has_default = entry.value.autoincrement or entry.value.default_raw != null or entry.value.default_expr != null;
        if (has_default) continue;

        var found = false;
        for (out_meta) |fm| {
            if (std.mem.eql(u8, fm.nameSlice(), entry.key)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingPrimaryKeyField;
    }
}

/// Cross-checks a task's `inputMeta()` against a source `TableSchema` (ARCH-009A §2.2).
pub fn validateTaskInputSchema(desc: *const TaskDescriptor_ABI, table: TableSchema) PreflightError!void {
    const in_meta = desc.inputMeta();
    if (in_meta.len == 0) return;

    for (in_meta) |fm| {
        const fname = fm.nameSlice();
        const col_spec = table.findColumn(fname) orelse continue;

        if (!areTypesCompatible(fm.logicalTypeSlice(), col_spec.col_type)) {
            return error.SchemaTypeMismatch;
        }

        if (col_spec.nullable and !fm.nullable) {
            return error.SchemaNullabilityMismatch;
        }
    }
}

/// Validates pipeline step directives against driver `Capabilities` (ARCH-009A §2.2).
pub fn validateDirectivesCapabilities(
    write_mode: ?WriteMode,
    requires_tx: bool,
    caps: Capabilities,
) PreflightError!void {
    if (write_mode) |mode| {
        if (mode == .update and !caps.partial_update) {
            return error.UnsupportedDriverCapability;
        }
    }
    if (requires_tx and !caps.transactions) {
        return error.UnsupportedDriverCapability;
    }
}

/// Convenience helper for `PipelineRunner`: validates a task descriptor against any matching
/// `TableSchema` in `catalog` (via `schema_ref` or channel name).
pub fn validateTaskAgainstCatalog(
    desc: *const TaskDescriptor_ABI,
    table_name: []const u8,
    catalog: *const SchemaCatalog,
    is_output: bool,
) PreflightError!void {
    const tbl = catalog.getTable(table_name) orelse return;
    if (is_output) {
        try validateTaskOutputSchema(desc, tbl);
    } else {
        try validateTaskInputSchema(desc, tbl);
    }
}


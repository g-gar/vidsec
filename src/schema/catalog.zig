const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/lib/mod.zig");
const EnvInterpolator = @import("../yaml/env.zig").EnvInterpolator;
const table = @import("table.zig");
const TableSchema = table.TableSchema;
const SeedRow = table.SeedRow;

pub const SchemaError = error{
    UnsupportedSchemaVersion,
    EmptyTableColumns,
    InvalidDefaultValue,
    InvalidForeignKeyRef,
    IndexedColumnNotFound,
    CompositeKeyColumnNotFound,
    DuplicateTableNameAcrossDomains,
    InvalidIndexSpec,
    SeedColumnNotFound,
    OutOfMemory,
};

pub const DomainSchema = yaml.Map(TableSchema);

/// Universal domain schema catalog decoded from declarative definitions (`schemas.yaml`).
pub const SchemaCatalog = struct {
    version: u32,
    schemas: yaml.Map(DomainSchema),

    pub fn parseYaml(
        arena: Allocator,
        yaml_src: []const u8,
        env: ?*const EnvInterpolator,
    ) anyerror!SchemaCatalog {
        const opts = yaml.ParseOptions{
            .scalar_hook = if (env) |e| e.scalarHook() else null,
        };
        return yaml.parse(SchemaCatalog, arena, yaml_src, opts);
    }

    pub fn validate(self: *const SchemaCatalog, arena: Allocator) SchemaError!void {
        if (self.version != 2) return error.UnsupportedSchemaVersion;

        var seen_tables: std.StringHashMapUnmanaged(TableSchema) = .empty;
        for (self.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                if (seen_tables.contains(tbl_entry.key)) {
                    return error.DuplicateTableNameAcrossDomains;
                }
                try seen_tables.put(arena, tbl_entry.key, tbl_entry.value);
            }
        }

        // Cross-check foreign keys
        for (self.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                for (tbl_entry.value.columns.entries) |col_entry| {
                    if (col_entry.value.ref) |fk| {
                        const target_tbl = seen_tables.get(fk.table) orelse return error.InvalidForeignKeyRef;
                        if (!target_tbl.columns.contains(fk.column)) return error.InvalidForeignKeyRef;
                    }
                }
            }
        }
    }

    pub fn yamlValidate(self: *const SchemaCatalog, arena: Allocator) SchemaError!void {
        return self.validate(arena);
    }

    pub fn getDomain(self: *const SchemaCatalog, domain_name: []const u8) ?DomainSchema {
        return self.schemas.get(domain_name);
    }

    pub fn getTable(self: *const SchemaCatalog, table_name: []const u8) ?TableSchema {
        for (self.schemas.entries) |dom_entry| {
            if (dom_entry.value.get(table_name)) |tbl| return tbl;
        }
        return null;
    }
};

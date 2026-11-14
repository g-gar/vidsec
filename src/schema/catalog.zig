const std = @import("std");
const Allocator = std.mem.Allocator;
const NamedMap = @import("types.zig").NamedMap;
const table = @import("table.zig");
const TableSchema = table.TableSchema;

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

pub const DomainSchema = NamedMap(TableSchema);

/// Universal, format-agnostic domain schema catalog.
/// Can be constructed programmatically or decoded by a frontend loader (e.g. `src/yaml/loaders/schema_loader.zig`).
pub const SchemaCatalog = struct {
    version: u32,
    schemas: NamedMap(DomainSchema),

    pub fn validate(self: *const SchemaCatalog, arena: Allocator) anyerror!void {
        if (self.version != 2) return error.UnsupportedSchemaVersion;

        var seen_tables: std.StringHashMapUnmanaged(TableSchema) = .empty;
        for (self.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                if (seen_tables.contains(tbl_entry.key)) {
                    return error.DuplicateTableNameAcrossDomains;
                }
                try tbl_entry.value.validate();
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

/// Universal, engine-agnostic and format-agnostic Schema AST (`SchemaCatalog`, `TableSchema`, `ColumnSpec`).
/// Invariant: must contain zero SQL, zero storage-driver specifics, and zero YAML/config-format imports.
pub const types = @import("types.zig");
pub const column = @import("column.zig");
pub const index = @import("index.zig");
pub const table = @import("table.zig");
pub const catalog = @import("catalog.zig");

pub const ColumnType = types.ColumnType;
pub const DefaultValue = types.DefaultValue;
pub const SortOrder = types.SortOrder;
pub const ForeignKeyAction = types.ForeignKeyAction;
pub const ForeignKeyRef = types.ForeignKeyRef;

pub const ColumnSpec = column.ColumnSpec;
pub const IndexSpec = index.IndexSpec;
pub const TableSchema = table.TableSchema;
pub const SeedRow = table.SeedRow;
pub const DomainSchema = catalog.DomainSchema;
pub const SchemaCatalog = catalog.SchemaCatalog;
pub const SchemaError = catalog.SchemaError;


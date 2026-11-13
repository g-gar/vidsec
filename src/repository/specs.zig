const std = @import("std");
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;

/// Write mode controlling how payload rows are merged with existing storage rows.
pub const WriteMode = enum {
    /// Insert if no row with the same PK exists; update only the payload columns
    /// if a row already exists (partial merge). Default when the table declares a PK.
    upsert,
    /// Always insert a new row; never updates. Default when the table has no PK.
    append,
    /// Update only the payload columns on matching PK rows; fails if the PK row
    /// does not exist (`error.RowNotFound`).
    update,
    /// Delete all existing rows in the table, then insert the payload rows.
    replace_all,
    /// Delete the rows whose PK matches the payload rows.
    delete,
};

/// Sort order for a single `ReadSpec` ordering column.
pub const SortOrder = enum { asc, desc };

/// One column in an `order_by` clause.
pub const OrderByColumn = struct {
    column: []const u8,
    order: SortOrder = .asc,
};

/// Projection mode for `ReadSpec`.
pub const ProjectionMode = union(enum) {
    /// Return all columns declared in the table schema (`SELECT *`).
    all,
    /// Return only the named columns (SQL `SELECT col1, col2 …`).
    include: []const []const u8,
    /// Return all columns except the named ones.
    exclude: []const []const u8,
};

/// Engine-agnostic write specification.
/// Drivers translate this into their native write operation (SQL INSERT/UPDATE/DELETE,
/// KV `put`, file append, etc.) without task code being aware of the backend.
pub const WriteSpec = struct {
    /// Target table or collection name (must match a declaration in `SchemaCatalog`
    /// unless `schemaless == true` on the driver).
    table: []const u8,
    /// How the payload rows interact with existing rows in the target.
    mode: WriteMode = .upsert,
    /// The data payload to write.
    payload: PayloadHandle,
    /// Pre-compiled row-to-column mapping for this `(struct_type, table)` pair.
    /// Pass `null` to let the driver perform per-row reflection (slower; useful for
    /// dynamic / ad-hoc payloads).
    record_map: ?*const RecordMap = null,
};

/// Pre-compiled mapping from a payload struct's fields to target table columns.
/// Computed once per `(type_name, table)` pair at pipeline initialization and reused
/// for every write call, eliminating per-row string reflection overhead.
///
/// For typed `Lowered(T)` payloads the mapping stores byte offsets; for dynamic
/// `DynamicRecord` payloads it stores field-name strings for linear lookup.
pub const RecordMap = struct {
    /// Name of the source type (for diagnostics).
    type_name: []const u8,
    /// Name of the target table.
    table_name: []const u8,
    /// Column mappings in declaration order.
    columns: []const ColumnMapping,

    pub const ColumnMapping = struct {
        /// Column name in the target table.
        column: []const u8,
        /// Byte offset within the struct for `Lowered(T)` payloads.
        /// `null` for dynamic payloads (field looked up by name at runtime).
        byte_offset: ?usize,
        /// Whether this column participates in the PK lookup for upsert / update / delete.
        is_pk: bool = false,
        /// Whether the target column accepts SQL NULL.
        nullable: bool = false,
    };
};

/// Engine-agnostic read specification.
pub const ReadSpec = struct {
    /// Target table or collection name.
    table: []const u8,
    /// Optional opaque Predicate AST node.
    /// Pass `null` to read all rows.
    where: ?*const anyopaque = null,
    /// Column ordering. Applied natively when the driver has `order_pushdown`; sorted
    /// in-memory otherwise.
    order_by: []const OrderByColumn = &.{},
    /// Maximum number of rows to return. `0` means no limit.
    limit: usize = 0,
    /// Number of rows to skip before returning results.
    offset: usize = 0,
    /// Which columns to return.
    projection: ProjectionMode = .all,
    /// Pre-compiled row mapping for typed deserialization. `null` = dynamic.
    record_map: ?*const RecordMap = null,
};


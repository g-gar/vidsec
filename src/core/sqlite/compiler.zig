const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("../../lib/sqlite/mod.zig");
const yaml_core = @import("../yaml/mod.zig");

pub const SchemaCatalog = yaml_core.SchemaCatalog;
pub const DomainSchema = yaml_core.DomainSchema;
pub const TableSchema = yaml_core.TableSchema;
pub const ColumnSpec = yaml_core.ColumnSpec;
pub const InputChannelSpec = yaml_core.InputChannelSpec;
pub const OutputSpec = yaml_core.OutputSpec;
pub const TableOutputTarget = yaml_core.output_spec.TableOutputTarget;
pub const OutputFieldSource = yaml_core.output_spec.OutputFieldSource;

pub const CompileError = error{
    UnknownDomainSchema,
    UnknownTableSchema,
    UnknownColumnInTable,
    CannotMutateView,
    EmptySortableExpression,
    OutOfMemory,
} || sqlite.DdlError || sqlite.QueryBuildError || yaml_core.schema_loader.SchemaLoadError;

/// Represents a compiled parameterized mutation (`INSERT` / `UPSERT` / `UPDATE`) for a single target table,
/// along with the ordered list of plugin-emitted field names bound to `?1 .. ?N`.
pub const CompiledOutputSink = struct {
    table_name: []const u8,
    sql: [:0]const u8,
    /// `param_fields[i]` is the plugin field name bound to SQLite parameter `?(i + 1)`.
    param_fields: []const []const u8,
};

/// Translates `vidsec v2` declarative YAML schemas and input/output blocks into SQLite DDL & DML
/// using the generic `src/lib/sqlite/` builders.
pub const CatalogCompiler = struct {
    /// Generates the complete SQLite DDL script (`CREATE TABLE ... STRICT; CREATE INDEX ...; CREATE VIEW ...;`)
    /// for all domains in `catalog`.
    pub fn emitCatalogDdl(allocator: Allocator, catalog: *const SchemaCatalog) CompileError![:0]u8 {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const temp = arena_state.allocator();

        var builder = sqlite.DdlBuilder.init(allocator);
        errdefer builder.deinit();

        for (catalog.schemas.entries) |dom_entry| {
            try appendDomainDdl(&builder, temp, dom_entry.value);
        }

        return builder.toOwnedSliceZ();
    }

    /// Generates the SQLite DDL script for a single domain (`ir_core`, `ir_deep`, `audit`, etc.).
    pub fn emitDomainDdl(
        allocator: Allocator,
        catalog: *const SchemaCatalog,
        domain_name: []const u8,
    ) CompileError![:0]u8 {
        const domain = catalog.getDomain(domain_name) orelse return error.UnknownDomainSchema;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const temp = arena_state.allocator();

        var builder = sqlite.DdlBuilder.init(allocator);
        errdefer builder.deinit();

        try appendDomainDdl(&builder, temp, domain);
        return builder.toOwnedSliceZ();
    }

    fn appendDomainDdl(
        builder: *sqlite.DdlBuilder,
        temp: Allocator,
        domain: DomainSchema,
    ) CompileError!void {
        for (domain.entries) |tbl_entry| {
            const table_name = tbl_entry.key;
            const tbl_schema = tbl_entry.value;

            if (tbl_schema.view_as) |select_sql| {
                var view_cols: std.ArrayListUnmanaged([]const u8) = .empty;
                for (tbl_schema.columns.entries) |c_entry| {
                    try view_cols.append(temp, c_entry.key);
                }
                try builder.addCreateView(.{
                    .name = table_name,
                    .temp = tbl_schema.temp,
                    .columns = view_cols.items,
                    .select_sql = select_sql,
                });
                continue;
            }

            const has_composite_pk = tbl_schema.primary_key.len > 0;
            var col_defs: std.ArrayListUnmanaged(sqlite.ColumnDef) = .empty;
            try col_defs.ensureTotalCapacity(temp, tbl_schema.columns.count());

            for (tbl_schema.columns.entries) |col_entry| {
                const col_name = col_entry.key;
                const spec = col_entry.value;

                const def_val: ?sqlite.DefaultSpec = if (try spec.parsedDefault()) |d|
                    d.toSqliteDefault()
                else
                    null;

                const check_expr: ?[]const u8 = try buildColumnCheckExpr(temp, col_name, spec);

                const gen_spec: ?sqlite.GeneratedColumnSpec = if (spec.generated_as) |g_expr|
                    .{
                        .expr = g_expr,
                        .storage = if (spec.stored) .stored else .virtual,
                    }
                else
                    null;

                const fk_spec: ?sqlite.ForeignKeyRefSpec = if (spec.ref) |fk|
                    .{
                        .table = fk.table,
                        .column = fk.column,
                        .on_delete = spec.on_delete,
                        .on_update = spec.on_update,
                    }
                else
                    null;

                const is_col_pk = spec.pk and !has_composite_pk;

                col_defs.appendAssumeCapacity(.{
                    .name = col_name,
                    .storage_type = spec.col_type.toStorageType(),
                    .primary_key = is_col_pk,
                    .autoincrement = spec.autoincrement,
                    .not_null = !spec.nullable and !is_col_pk,
                    .unique = spec.unique,
                    .default_val = def_val,
                    .check_expr = check_expr,
                    .collate = spec.collate,
                    .generated = gen_spec,
                    .references = fk_spec,
                });
            }

            var constraints: std.ArrayListUnmanaged(sqlite.TableConstraint) = .empty;
            if (has_composite_pk) {
                try constraints.append(temp, .{
                    .primary_key = .{ .columns = tbl_schema.primary_key },
                });
            }
            for (tbl_schema.unique_keys) |uk_cols| {
                try constraints.append(temp, .{
                    .unique = .{ .columns = uk_cols },
                });
            }
            for (tbl_schema.checks) |chk_sql| {
                try constraints.append(temp, .{
                    .check = .{ .expr = chk_sql },
                });
            }

            try builder.addCreateTable(.{
                .name = table_name,
                .temp = tbl_schema.temp,
                .strict = tbl_schema.strict,
                .without_rowid = tbl_schema.without_rowid,
                .columns = col_defs.items,
                .constraints = constraints.items,
            });

            // Emit all declared indexes on this table
            for (tbl_schema.indexes, 0..) |idx_spec, idx_pos| {
                var idx_cols: std.ArrayListUnmanaged(sqlite.IndexColumn) = .empty;
                for (idx_spec.columns) |col_name| {
                    try idx_cols.append(temp, .{
                        .name_or_expr = col_name,
                        .is_expr = false,
                        .order = idx_spec.order,
                    });
                }
                for (idx_spec.expressions) |expr_sql| {
                    try idx_cols.append(temp, .{
                        .name_or_expr = expr_sql,
                        .is_expr = true,
                        .order = idx_spec.order,
                    });
                }

                const idx_name = if (idx_spec.name) |explicit_name|
                    explicit_name
                else if (idx_spec.columns.len == 1 and idx_spec.expressions.len == 0)
                    try std.fmt.allocPrint(temp, "idx_{s}_{s}", .{ table_name, idx_spec.columns[0] })
                else
                    try std.fmt.allocPrint(temp, "idx_{s}_{d}", .{ table_name, idx_pos });

                try builder.addCreateIndex(.{
                    .name = idx_name,
                    .table = table_name,
                    .unique = idx_spec.unique,
                    .columns = idx_cols.items,
                    .where_expr = idx_spec.where,
                });
            }
        }
    }

    fn buildColumnCheckExpr(temp: Allocator, col_name: []const u8, spec: ColumnSpec) !?[]const u8 {
        if (spec.col_type == .bool) {
            var q_ident: std.ArrayListUnmanaged(u8) = .empty;
            try sqlite.ddl.writeQuotedIdent(&q_ident, temp, col_name);
            const quoted = q_ident.items;

            if (spec.check) |extra_chk| {
                return try std.fmt.allocPrint(temp, "{s} IN (0, 1) AND ({s})", .{ quoted, extra_chk });
            } else {
                return try std.fmt.allocPrint(temp, "{s} IN (0, 1)", .{quoted});
            }
        }
        return spec.check;
    }

    /// Compiles an `InputChannelSpec` (`input.<channel_name>`) into a read-only `SELECT` statement.
    /// Returns `null` if the channel is a pure byte stream (`stream: { from: file }`).
    pub fn compileInputSelect(
        allocator: Allocator,
        channel: InputChannelSpec,
    ) CompileError!?[:0]u8 {
        if (channel.query) |raw_q| {
            return try allocator.dupeZ(u8, std.mem.trim(u8, raw_q, " \t\r\n;"));
        }

        const tbl_name = channel.table orelse return null;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const temp = arena_state.allocator();

        var projections: []const sqlite.Projection = &.{};
        if (channel.map) |map| {
            var proj_buf = try temp.alloc(sqlite.Projection, map.count());
            for (map.entries, 0..) |entry, i| {
                proj_buf[i] = .{
                    .expr = entry.value,
                    .alias = entry.key,
                };
            }
            projections = proj_buf;
        } else {
            var proj_buf = try temp.alloc(sqlite.Projection, 1);
            proj_buf[0] = .{ .expr = "*" };
            projections = proj_buf;
        }

        var where_list: std.ArrayListUnmanaged([]const u8) = .empty;
        if (channel.filter) |f| {
            if (std.mem.trim(u8, f, " \t\r\n").len > 0) {
                try where_list.append(temp, f);
            }
        }

        var order_list: std.ArrayListUnmanaged(sqlite.OrderByTerm) = .empty;
        if (channel.order_by) |ob_raw| {
            const ob_trimmed = std.mem.trim(u8, ob_raw, " \t\r\n");
            if (ob_trimmed.len > 0) {
                try order_list.append(temp, .{ .expr = ob_trimmed });
            }
        }

        const sel = sqlite.SelectQuery{
            .distinct = channel.distinct,
            .projections = projections,
            .from_table_or_subquery = tbl_name,
            .where_clauses = where_list.items,
            .group_by = channel.group_by,
            .having_expr = channel.having,
            .order_by = order_list.items,
            .limit = channel.limit,
            .offset = channel.offset,
        };

        return try sel.toSqlZ(allocator);
    }

    /// Compiles a single-table `TableOutputTarget` (`output.into` + `mode` + `key` + `map`)
    /// into a `CompiledOutputSink`.
    pub fn compileTableOutput(
        allocator: Allocator,
        catalog: *const SchemaCatalog,
        target: TableOutputTarget,
    ) CompileError!CompiledOutputSink {
        const tbl_schema = catalog.getTable(target.table) orelse return error.UnknownTableSchema;
        if (tbl_schema.isView()) return error.CannotMutateView;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const temp = arena_state.allocator();

        var assignments: std.ArrayListUnmanaged(sqlite.ColumnAssignment) = .empty;
        var param_fields: std.ArrayListUnmanaged([]const u8) = .empty;

        if (target.map) |mappings| {
            for (mappings.entries) |entry| {
                const col_name = entry.key;
                if (tbl_schema.findColumn(col_name) == null) {
                    return error.UnknownColumnInTable;
                }
                switch (entry.value) {
                    .constant_literal => |lit| {
                        try assignments.append(temp, .{
                            .column = col_name,
                            .value = .{ .literal_text = lit },
                        });
                    },
                    .plugin_field => |pf| {
                        try param_fields.append(allocator, try allocator.dupe(u8, pf));
                        try assignments.append(temp, .{
                            .column = col_name,
                            .value = .{ .bind_param = param_fields.items.len },
                        });
                    },
                }
            }
        } else if (target.fields) |field_list| {
            // Subset selection: bind only the listed columns by their identical plugin field name
            for (field_list) |col_name| {
                if (tbl_schema.findColumn(col_name) == null) {
                    return error.UnknownColumnInTable;
                }
                try param_fields.append(allocator, try allocator.dupe(u8, col_name));
                try assignments.append(temp, .{
                    .column = col_name,
                    .value = .{ .bind_param = param_fields.items.len },
                });
            }
        } else {
            // Unmapped table output: bind every non-generated column by its own column name
            for (tbl_schema.columns.entries) |col_entry| {
                if (col_entry.value.generated_as != null) continue;
                const col_name = col_entry.key;
                try param_fields.append(allocator, try allocator.dupe(u8, col_name));
                try assignments.append(temp, .{
                    .column = col_name,
                    .value = .{ .bind_param = param_fields.items.len },
                });
            }
        }

        const key_slice: []const []const u8 = if (target.key_column) |k| blk: {
            if (tbl_schema.findColumn(k) == null) return error.UnknownColumnInTable;
            const s = try temp.alloc([]const u8, 1);
            s[0] = k;
            break :blk s;
        } else &.{};

        const mut_kind: sqlite.MutationKind = switch (target.mode) {
            .insert => .{ .insert = .{} },
            .upsert => .{ .upsert = .{ .conflict_columns = key_slice } },
            .update => .{ .update = .{ .key_columns = key_slice } },
        };

        const mut_q = sqlite.MutationQuery{
            .table = target.table,
            .kind = mut_kind,
            .assignments = assignments.items,
        };

        const sql_z = try mut_q.toSqlZ(allocator);
        return CompiledOutputSink{
            .table_name = try allocator.dupe(u8, target.table),
            .sql = sql_z,
            .param_fields = try param_fields.toOwnedSlice(allocator),
        };
    }

    /// Compiles all physical tables of a domain (`output.schema: ir_core`) into a list of `CompiledOutputSink`s.
    pub fn compileDomainOutputs(
        allocator: Allocator,
        catalog: *const SchemaCatalog,
        domain_name: []const u8,
    ) CompileError![]CompiledOutputSink {
        const domain = catalog.getDomain(domain_name) orelse return error.UnknownDomainSchema;

        var sinks: std.ArrayListUnmanaged(CompiledOutputSink) = .empty;
        errdefer sinks.deinit(allocator);

        for (domain.entries) |tbl_entry| {
            if (tbl_entry.value.isView()) continue;
            const sink = try compileTableOutput(allocator, catalog, .{
                .table = tbl_entry.key,
                .mode = .insert,
                .key_column = null,
                .map = null,
            });
            try sinks.append(allocator, sink);
        }

        return sinks.toOwnedSlice(allocator);
    }
};

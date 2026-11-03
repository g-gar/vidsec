const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("../../lib/sqlite/mod.zig");
const yaml_core = @import("../yaml/mod.zig");
const compiler = @import("compiler.zig");

pub const Db = sqlite.Db;
pub const Stmt = sqlite.Stmt;
pub const Row = sqlite.Row;
pub const Value = sqlite.Value;
pub const Savepoint = sqlite.Savepoint;
pub const SchemaCatalog = yaml_core.SchemaCatalog;
pub const PipelineConfig = yaml_core.PipelineConfig;
pub const EngineSettings = yaml_core.EngineSettings;
pub const RouterStep = yaml_core.RouterStep;
pub const TableOutputTarget = yaml_core.output_spec.TableOutputTarget;
pub const CatalogCompiler = compiler.CatalogCompiler;
pub const CompiledOutputSink = compiler.CompiledOutputSink;

pub const RuntimeError = error{
    MissingDbFilePathForWalMode,
    SqlRuleSelectColumnCountMismatch,
    SqlRuleUnknownTargetColumn,
    UnknownSinkField,
    OutOfMemory,
} || sqlite.SqliteError || compiler.CompileError || yaml_core.PipelineLoadError;

/// Named field pair emitted by a plugin (`emit_row`) or read from a row cursor.
pub const NamedValue = struct {
    name: []const u8,
    value: Value,
};

/// Prepared output sink ready to receive rows from a plugin's `emit_row` callback.
pub const PreparedSink = struct {
    sink_spec: CompiledOutputSink,
    stmt: Stmt,

    pub fn deinit(self: *PreparedSink) void {
        self.stmt.deinit();
    }

    /// Binds the fields emitted by a plugin according to `sink_spec.param_fields`
    /// (binding `NULL` for any omitted nullable field) and executes the prepared `INSERT`/`UPSERT`/`UPDATE`.
    pub fn emitRow(self: *PreparedSink, fields: []const NamedValue) sqlite.SqliteError!void {
        self.stmt.resetAndClear();
        for (self.sink_spec.param_fields, 1..) |expected_field, param_idx| {
            const val = findFieldValue(fields, expected_field) orelse Value.null_val;
            try self.stmt.bindValue(param_idx, val);
        }
        try self.stmt.execStep();
    }

    fn findFieldValue(fields: []const NamedValue, target_name: []const u8) ?Value {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, target_name)) return f.value;
        }
        return null;
    }
};

/// Host SQLite3 Runtime Engine (`src/core/sqlite/runtime.zig`).
/// Owns the `sqlite.Db` connection, initializes schemas from `SchemaCatalog`,
/// performs pre-flight read-only validation, and executes `sql_rule` and `router` steps.
pub const SqliteRuntime = struct {
    db: Db,
    catalog: *const SchemaCatalog,

    /// Initializes an in-memory SQLite database and creates all tables/indexes/views from `catalog`.
    pub fn initMemory(allocator: Allocator, catalog: *const SchemaCatalog) RuntimeError!SqliteRuntime {
        var db = try Db.openMemory(.{
            .busy_timeout_ms = 5000,
            .foreign_keys = true,
        });
        errdefer db.close();

        const ddl_sql = try CatalogCompiler.emitCatalogDdl(allocator, catalog);
        defer allocator.free(ddl_sql);

        try db.execZ(ddl_sql);
        if (catalog.getDomain("catalog") != null) {
            try populateCatalogSeeds(&db);
        }
        return SqliteRuntime{
            .db = db,
            .catalog = catalog,
        };
    }

    /// Initializes a SQLite database according to `EngineSettings` and `wal_db_path`,
    /// automatically creating the `.db` file on disk and initializing all tables/indexes/views from `catalog`.
    ///
    /// Precedence for database location:
    /// 1. Explicit CLI `wal_db_path` (`--db <path>`) always opens/creates a file-backed WAL database at `<path>`.
    /// 2. `settings.db_path` in `pipeline.yaml` (`engine.db_path`) opens/creates a file-backed WAL database at that path.
    /// 3. If `settings.db_mode == .wal_file` without an explicit path, defaults to `"./vidsec_state.db"`.
    /// 4. Otherwise (`settings.db_mode == .memory` and no path given), opens an in-memory database (`:memory:`).
    pub fn initWithSettings(
        allocator: Allocator,
        settings: EngineSettings,
        wal_db_path: ?[]const u8,
        catalog: *const SchemaCatalog,
    ) RuntimeError!SqliteRuntime {
        const effective_path: ?[]const u8 = wal_db_path orelse settings.db_path orelse
            (if (settings.db_mode == .wal_file) @as(?[]const u8, "./vidsec_state.db") else null);

        var db: Db = if (effective_path) |path|
            try Db.openFile(allocator, path, .{
                .busy_timeout_ms = settings.db_busy_timeout_ms,
                .foreign_keys = true,
                .journal_mode = .wal,
                .synchronous = .normal,
            })
        else
            try Db.openMemory(.{
                .busy_timeout_ms = settings.db_busy_timeout_ms,
                .foreign_keys = true,
            });
        errdefer db.close();

        const ddl_sql = try CatalogCompiler.emitCatalogDdl(allocator, catalog);
        defer allocator.free(ddl_sql);

        if (effective_path != null) {
            try resetCatalogTables(&db, allocator, catalog);
        }

        try db.execZ(ddl_sql);
        if (catalog.getDomain("catalog") != null) {
            try populateCatalogSeeds(&db);
        }
        return SqliteRuntime{
            .db = db,
            .catalog = catalog,
        };
    }

    fn populateCatalogSeeds(db: *Db) RuntimeError!void {
        const seeds =
            \\INSERT OR IGNORE INTO enum_container_format (id, code, display_name, default_mime) VALUES
            \\  (0, 'unknown', 'Unknown / Unrecognized Format', 'application/octet-stream'),
            \\  (1, 'isobmff', 'ISO Base Media File Format (MP4/MOV)', 'video/mp4'),
            \\  (2, 'ebml', 'Extensible Binary Meta Language (MKV/WebM)', 'video/x-matroska'),
            \\  (3, 'riff', 'Resource Interchange File Format (AVI/WAV)', 'video/x-msvideo');
            \\
            \\INSERT OR IGNORE INTO enum_severity (level, code, badge_color, description) VALUES
            \\  (0, 'INFO', '#3B82F6', 'Informational metric or clean indicator'),
            \\  (1, 'LOW', '#10B981', 'Minor structural anomaly without immediate threat'),
            \\  (2, 'MEDIUM', '#F59E0B', 'Suspicious unreferenced payload or slack data'),
            \\  (3, 'HIGH', '#EF4444', 'Dangerous polyglot, trailing overlay, or format tampering'),
            \\  (4, 'CRITICAL', '#7F1D1D', 'Confirmed exploit, corrupted header, or severe threat');
            \\
            \\INSERT OR IGNORE INTO enum_verdict (id, code, description) VALUES
            \\  (0, 'PASS', 'Media file passed triage validation'),
            \\  (1, 'FLAGGED', 'Media file triggered security or structural warnings'),
            \\  (2, 'DROP', 'Media file violates security policies and should be rejected');
            \\
            \\INSERT OR IGNORE INTO enum_region_role (id, code, description) VALUES
            \\  (0, 'unknown', 'Uncategorized container structure'),
            \\  (1, 'container', 'Top-level or nested container structural header'),
            \\  (2, 'media_data', 'Raw elementary audio/video/subtitle stream payload'),
            \\  (3, 'padding', 'Safe zero or filler padding byte sequence'),
            \\  (4, 'sample_table', 'Frame indexing and sample offset/chunk metadata'),
            \\  (5, 'codec_config', 'Decoder configuration record (AVCC, HEVC, Vorbis)'),
            \\  (6, 'metadata', 'Tags, chapters, user comments, or editorial metadata'),
            \\  (7, 'attachment', 'Embedded auxiliary file or font attachment'),
            \\  (8, 'external_ref', 'URL or external file path reference');
        ;
        try db.execZ(seeds);
    }

    fn resetCatalogTables(db: *Db, allocator: Allocator, catalog: *const SchemaCatalog) RuntimeError!void {
        var builder = sqlite.DdlBuilder.init(allocator);
        defer builder.deinit();

        try db.setForeignKeys(false);
        errdefer db.setForeignKeys(true) catch {};

        var dom_idx: usize = catalog.schemas.entries.len;
        while (dom_idx > 0) {
            dom_idx -= 1;
            const domain = catalog.schemas.entries[dom_idx].value;
            var tbl_idx: usize = domain.entries.len;
            while (tbl_idx > 0) {
                tbl_idx -= 1;
                const tbl_entry = domain.entries[tbl_idx];
                if (tbl_entry.value.isView()) {
                    try builder.addDropView(tbl_entry.key, true);
                } else {
                    try builder.addDropTable(tbl_entry.key, true);
                }
            }
        }

        const drop_sql = try builder.toOwnedSliceZ();
        defer allocator.free(drop_sql);
        if (drop_sql.len > 0) {
            try db.execZ(drop_sql);
        }
        try db.setForeignKeys(true);
    }

    pub fn deinit(self: *SqliteRuntime) void {
        // Flush any WAL frames into the main `.db` file before closing so external SQLite tools
        // see all tables and rows immediately even if they ignore `-wal` sidecar files.
        self.db.execZ("PRAGMA wal_checkpoint(TRUNCATE);") catch {};
        self.db.close();
    }

    pub fn savepoint(self: *SqliteRuntime, name: []const u8) sqlite.SqliteError!Savepoint {
        return self.db.savepoint(name);
    }

    /// Verifies that `sql` compiles against the active schema and is strictly read-only
    /// (`sqlite3_stmt_readonly(stmt) == 1`).
    pub fn validateReadOnlyQuery(self: *SqliteRuntime, sql: []const u8) sqlite.SqliteError!void {
        var stmt = try self.db.prepareReadOnly(sql);
        stmt.deinit();
    }

    /// Performs complete pre-flight SQL and schema validation for `pipeline` before opening any media file:
    /// 1. Validates all table/column/domain references against `SchemaCatalog`.
    /// 2. Compiles and verifies `isReadOnly()` on all `input` queries (`windows` and row cursors).
    /// 3. Compiles and verifies `isReadOnly()` and target column compatibility on all `use: sql_rule` steps.
    /// 4. Compiles and verifies `isReadOnly()` on all `router` `when` conditions.
    /// 5. Compiles and prepares all `output` mutations (`schema:` or `into:`) against SQLite.
    pub fn preflightValidatePipeline(
        self: *SqliteRuntime,
        allocator: Allocator,
        pipeline: *const PipelineConfig,
    ) RuntimeError!void {
        try pipeline.validateAgainstCatalog(self.catalog);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const temp = arena_state.allocator();

        for (pipeline.pipelines.entries) |sub_entry| {
            for (sub_entry.value.steps) |step| {
                switch (step) {
                    .router => |r_step| {
                        for (r_step.cases) |c| {
                            const trimmed = std.mem.trim(u8, c.when_sql, " \t\r\n");
                            if (std.ascii.startsWithIgnoreCase(trimmed, "select")) {
                                try self.validateReadOnlyQuery(c.when_sql);
                            }
                        }
                    },
                    .task => |t_step| {
                        if (t_step.input) |in_spec| {
                            for (in_spec.entries) |ch_entry| {
                                if (try CatalogCompiler.compileInputSelect(temp, ch_entry.value)) |sel_sql| {
                                    try self.validateReadOnlyQuery(sel_sql);
                                }
                            }
                        }

                        if (t_step.target == .sql_rule) {
                            const q_sql = t_step.query.?;
                            const out_target = t_step.output.?.target().?.into_table;
                            const insert_select_sql = try self.compileSqlRuleStatement(temp, q_sql, out_target);
                            var mut_stmt = try self.db.prepare(insert_select_sql);
                            mut_stmt.deinit();
                        } else if (t_step.output) |out_spec| {
                            if (out_spec.target()) |target| {
                                switch (target) {
                                    .schema_domain => |dom_name| {
                                        const sinks = try CatalogCompiler.compileDomainOutputs(temp, self.catalog, dom_name);
                                        for (sinks) |s| {
                                            var stmt = try self.db.prepare(s.sql);
                                            stmt.deinit();
                                        }
                                    },
                                    .into_table => |into_tbl| {
                                        const sink = try CatalogCompiler.compileTableOutput(temp, self.catalog, into_tbl);
                                        var stmt = try self.db.prepare(sink.sql);
                                        stmt.deinit();
                                    },
                                }
                            }
                        }
                    },
                }
            }
        }
    }

    /// Prepares a `PreparedSink` for a single-table `TableOutputTarget`.
    pub fn prepareTableSink(
        self: *SqliteRuntime,
        allocator: Allocator,
        target: TableOutputTarget,
    ) RuntimeError!PreparedSink {
        const sink_spec = try CatalogCompiler.compileTableOutput(allocator, self.catalog, target);
        const stmt = try self.db.prepare(sink_spec.sql);
        return PreparedSink{
            .sink_spec = sink_spec,
            .stmt = stmt,
        };
    }

    /// Executes a `use: sql_rule` step inside a `SAVEPOINT` and returns the number of inserted rows.
    pub fn executeSqlRule(
        self: *SqliteRuntime,
        allocator: Allocator,
        step_name: []const u8,
        select_query: []const u8,
        output_target: TableOutputTarget,
    ) RuntimeError!usize {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const temp = arena_state.allocator();

        const full_sql = try self.compileSqlRuleStatement(temp, select_query, output_target);

        var sp = try self.db.savepoint(step_name);
        errdefer sp.rollback();

        var stmt = try self.db.prepare(full_sql);
        defer stmt.deinit();

        try stmt.execStep();
        const inserted = self.db.changes();

        try sp.release();
        return inserted;
    }

    /// Compiles a `use: sql_rule` `SELECT` query + `output.into` into an `INSERT INTO "table" (...) SELECT ...`
    /// statement after verifying that `select_query` is strictly read-only.
    pub fn compileSqlRuleStatement(
        self: *SqliteRuntime,
        allocator: Allocator,
        select_query: []const u8,
        output_target: TableOutputTarget,
    ) RuntimeError![:0]u8 {
        const tbl_schema = self.catalog.getTable(output_target.table) orelse return error.UnknownTableSchema;
        if (tbl_schema.isView()) return error.CannotMutateView;

        // 1. Prepare the SELECT as read-only to both enforce security and introspect result column names
        var sel_stmt = try self.db.prepareReadOnly(select_query);
        defer sel_stmt.deinit();

        const col_count = sel_stmt.columnCount();
        if (col_count == 0) return error.SqlRuleSelectColumnCountMismatch;

        var target_cols: std.ArrayListUnmanaged([]const u8) = .empty;
        defer target_cols.deinit(allocator);

        // Check if every result column name in the SELECT matches a column in `tbl_schema`
        var all_named_match = true;
        for (0..col_count) |idx| {
            const c_name = sel_stmt.columnName(idx);
            if (c_name.len == 0 or tbl_schema.findColumn(c_name) == null) {
                all_named_match = false;
                break;
            }
        }

        if (all_named_match) {
            for (0..col_count) |idx| {
                try target_cols.append(allocator, try allocator.dupe(u8, sel_stmt.columnName(idx)));
            }
        } else {
            // Positional mapping: collect non-generated columns (excluding auto-integer PK if counts match)
            var all_writable: std.ArrayListUnmanaged([]const u8) = .empty;
            defer all_writable.deinit(allocator);
            var non_pk_writable: std.ArrayListUnmanaged([]const u8) = .empty;
            defer non_pk_writable.deinit(allocator);

            for (tbl_schema.columns.entries) |c_entry| {
                if (c_entry.value.generated_as != null) continue;
                try all_writable.append(allocator, c_entry.key);
                if (!(c_entry.value.pk and c_entry.value.col_type == .int64)) {
                    try non_pk_writable.append(allocator, c_entry.key);
                }
            }

            if (col_count == all_writable.items.len) {
                try target_cols.appendSlice(allocator, all_writable.items);
            } else if (col_count <= non_pk_writable.items.len) {
                try target_cols.appendSlice(allocator, non_pk_writable.items[0..col_count]);
            } else {
                return error.SqlRuleSelectColumnCountMismatch;
            }
        }

        const raw_sql = try sqlite.buildInsertFromSelect(
            allocator,
            output_target.table,
            target_cols.items,
            select_query,
        );
        defer allocator.free(raw_sql);

        return try allocator.dupeZ(u8, raw_sql);
    }

    /// Evaluates a `RouterStep` (`cases: [{ when: "SELECT ...", goto: "..." }]`, `default: ...`).
    /// Returns the name of the target sub-pipeline to jump to, or `null` if the pipeline should exit.
    pub fn evaluateRouter(self: *SqliteRuntime, router: RouterStep) RuntimeError!?[]const u8 {
        for (router.cases) |case_item| {
            if (try self.evaluateRouterWhen(case_item.when_sql)) {
                return case_item.goto_pipeline;
            }
        }
        return router.default_pipeline;
    }

    /// Evaluates a single `when` SQL query in read-only mode and returns `true` if it yields at least one row.
    pub fn evaluateRouterWhen(self: *SqliteRuntime, when_sql: []const u8) RuntimeError!bool {
        var stmt = try self.db.prepareReadOnly(when_sql);
        defer stmt.deinit();
        const maybe_row = try stmt.step();
        return maybe_row != null;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const dataflow = flowdata.dataflow;
const PayloadHandle = dataflow.PayloadHandle;
const ReflectedValue = dataflow.ReflectedValue;
const DynamicRecord = dataflow.DynamicRecord;
const DynamicField = dataflow.DynamicField;
const predicate_ast = dataflow.predicate_ast;
const PredicateNode = predicate_ast.PredicateNode;
const Literal = predicate_ast.Literal;
const schema = flowdata.schema;
const SchemaCatalog = schema.SchemaCatalog;
const TableSchema = schema.TableSchema;
const ColumnSpec = schema.ColumnSpec;
const ColumnType = schema.ColumnType;
const DefaultValue = schema.DefaultValue;
const repository_mod = flowdata.repository;
const Repository = repository_mod.Repository;
const StorageRepository = repository_mod.StorageRepository;
const Capabilities = repository_mod.Capabilities;
const WriteSpec = repository_mod.WriteSpec;
const WriteMode = repository_mod.WriteMode;
const ReadSpec = repository_mod.ReadSpec;
const RowIterator = repository_mod.RowIterator;
const OrderByColumn = repository_mod.OrderByColumn;
const ProjectionMode = repository_mod.ProjectionMode;
const Mutex = flowdata.concurrency.Mutex;

/// Behavioral oracle & in-memory repository (ARCH-009A §3).
///
/// - **Ephemeral channels** (undeclared in `SchemaCatalog` when `schemaless == true`):
///   retain zero-copy `PayloadHandle` snapshot semantics.
/// - **Schema-backed tables** (declared via `ensureSchema`):
///   enforce column types, nullability, defaults (`now`, `uuid`, literals),
///   PK uniqueness, `WriteSpec` modes (`upsert`, `append`, `update`, `replace_all`, `delete`),
///   and `ReadSpec` / `readStream` via the in-memory Predicate AST evaluator.
pub const MemoryRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    pub const StoredValue = union(enum) {
        null_val,
        int64: i64,
        uint64: u64,
        float64: f64,
        boolean: bool,
        text: []u8,
        bytes: []u8,

        fn deinit(self: StoredValue, allocator: Allocator) void {
            switch (self) {
                .text => |s| allocator.free(s),
                .bytes => |b| allocator.free(b),
                else => {},
            }
        }

        fn clone(self: StoredValue, allocator: Allocator) !StoredValue {
            return switch (self) {
                .null_val => .null_val,
                .int64 => |v| .{ .int64 = v },
                .uint64 => |v| .{ .uint64 = v },
                .float64 => |v| .{ .float64 = v },
                .boolean => |v| .{ .boolean = v },
                .text => |s| .{ .text = try allocator.dupe(u8, s) },
                .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
            };
        }

        fn eql(a: StoredValue, b: StoredValue) bool {
            return switch (a) {
                .null_val => b == .null_val,
                .int64 => |av| switch (b) {
                    .int64 => |bv| av == bv,
                    .uint64 => |bv| av >= 0 and @as(u64, @intCast(av)) == bv,
                    else => false,
                },
                .uint64 => |av| switch (b) {
                    .uint64 => |bv| av == bv,
                    .int64 => |bv| bv >= 0 and av == @as(u64, @intCast(bv)),
                    else => false,
                },
                .float64 => |av| b == .float64 and av == b.float64,
                .boolean => |av| b == .boolean and av == b.boolean,
                .text => |av| b == .text and std.mem.eql(u8, av, b.text),
                .bytes => |av| b == .bytes and std.mem.eql(u8, av, b.bytes),
            };
        }

        fn toLiteral(self: StoredValue) Literal {
            return switch (self) {
                .null_val => .null_val,
                .int64 => |v| .{ .int64 = v },
                .uint64 => |v| .{ .int64 = @intCast(v) },
                .float64 => |v| .{ .float64 = v },
                .boolean => |v| .{ .boolean = v },
                .text => |s| .{ .text = s },
                .bytes => |b| .{ .text = b },
            };
        }

        fn toReflected(self: StoredValue) ReflectedValue {
            return switch (self) {
                .null_val => .none,
                .int64 => |v| .{ .int = v },
                .uint64 => |v| .{ .uint = v },
                .float64 => |v| .{ .float = v },
                .boolean => |v| .{ .boolean = v },
                .text => |s| .{ .string = s },
                .bytes => |b| .{ .bytes = b },
            };
        }

        fn order(a: StoredValue, b: StoredValue) std.math.Order {
            if (a == .null_val and b == .null_val) return .eq;
            if (a == .null_val) return .lt;
            if (b == .null_val) return .gt;
            return switch (a) {
                .int64 => |av| switch (b) {
                    .int64 => |bv| std.math.order(av, bv),
                    .uint64 => |bv| if (av < 0) .lt else std.math.order(@as(u64, @intCast(av)), bv),
                    else => .eq,
                },
                .uint64 => |av| switch (b) {
                    .uint64 => |bv| std.math.order(av, bv),
                    .int64 => |bv| if (bv < 0) .gt else std.math.order(av, @as(u64, @intCast(bv))),
                    else => .eq,
                },
                .float64 => |av| if (b == .float64) std.math.order(av, b.float64) else .eq,
                .boolean => |av| if (b == .boolean) std.math.order(@intFromBool(av), @intFromBool(b.boolean)) else .eq,
                .text => |av| if (b == .text) std.mem.order(u8, av, b.text) else .eq,
                .bytes => |av| if (b == .bytes) std.mem.order(u8, av, b.bytes) else .eq,
                .null_val => .eq,
            };
        }
    };

    const StoredRow = struct {
        cells: std.StringHashMapUnmanaged(StoredValue) = .empty,

        fn deinit(self: *StoredRow, allocator: Allocator) void {
            var it = self.cells.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            self.cells.deinit(allocator);
        }

        fn setCell(self: *StoredRow, allocator: Allocator, col_name: []const u8, val: StoredValue) !void {
            if (self.cells.getPtr(col_name)) |existing| {
                existing.deinit(allocator);
                existing.* = val;
                return;
            }
            const owned_key = try allocator.dupe(u8, col_name);
            errdefer allocator.free(owned_key);
            try self.cells.put(allocator, owned_key, val);
        }

        fn getter(ctx: *const anyopaque, column: []const u8) ?Literal {
            const self: *const StoredRow = @ptrCast(@alignCast(ctx));
            const val = self.cells.get(column) orelse return null;
            return val.toLiteral();
        }
    };

    const OwnedColumn = struct {
        name: []const u8,
        spec: ColumnSpec,
        is_pk: bool,
    };

    const TableStore = struct {
        columns: []OwnedColumn,
        pk_columns: [][]const u8,
        rows: std.ArrayListUnmanaged(StoredRow) = .empty,
        next_autoincrement: i64 = 1,

        fn deinit(self: *TableStore, allocator: Allocator) void {
            for (self.rows.items) |*row| {
                row.deinit(allocator);
            }
            self.rows.deinit(allocator);
            for (self.columns) |col| {
                allocator.free(col.name);
                if (col.spec.default_raw) |dr| allocator.free(dr);
                if (col.spec.default_expr) |de| allocator.free(de);
            }
            allocator.free(self.columns);
            for (self.pk_columns) |pk| allocator.free(pk);
            allocator.free(self.pk_columns);
        }

        fn clearRows(self: *TableStore, allocator: Allocator) void {
            for (self.rows.items) |*row| {
                row.deinit(allocator);
            }
            self.rows.clearRetainingCapacity();
        }

        fn findColumn(self: *const TableStore, name: []const u8) ?OwnedColumn {
            for (self.columns) |c| {
                if (std.mem.eql(u8, c.name, name)) return c;
            }
            return null;
        }
    };

    allocator: Allocator,
    schemaless: bool = true,
    payloads: std.StringHashMapUnmanaged(PayloadHandle) = .empty,
    tables: std.StringHashMapUnmanaged(TableStore) = .empty,
    mutex: Mutex = .{},
    uuid_seq: u64 = 0,

    pub fn init(allocator: Allocator) MemoryRepository {
        return .{
            .allocator = allocator,
        };
    }

    pub fn initWithOptions(allocator: Allocator, schemaless: bool) MemoryRepository {
        return .{
            .allocator = allocator,
            .schemaless = schemaless,
        };
    }

    pub fn deinit(self: *MemoryRepository) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var p_iter = self.payloads.iterator();
        while (p_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.payloads.deinit(self.allocator);

        var t_iter = self.tables.iterator();
        while (t_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
    }

    pub fn getCapabilities(_: *const MemoryRepository) Capabilities {
        return .{
            .transactions = false,
            .savepoints = false,
            .partial_update = true,
            .filter_pushdown = false,
            .order_pushdown = false,
            .relational_constraints = false,
            .schema_ddl = true,
            .streaming = true,
        };
    }

    pub fn ensureSchema(self: *MemoryRepository, catalog: *const SchemaCatalog) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (catalog.schemas.entries) |dom_entry| {
            for (dom_entry.value.entries) |tbl_entry| {
                if (self.tables.contains(tbl_entry.key)) continue;

                const tbl_schema = tbl_entry.value;
                var cols = try self.allocator.alloc(OwnedColumn, tbl_schema.columns.entries.len);
                var pk_list: std.ArrayListUnmanaged([]const u8) = .empty;
                errdefer pk_list.deinit(self.allocator);

                for (tbl_schema.columns.entries, 0..) |col_entry, idx| {
                    var is_pk = col_entry.value.pk;
                    if (!is_pk) {
                        for (tbl_schema.primary_key) |pk_name| {
                            if (std.mem.eql(u8, pk_name, col_entry.key)) {
                                is_pk = true;
                                break;
                            }
                        }
                    }

                    var cloned_spec = col_entry.value;
                    cloned_spec.default_raw = if (col_entry.value.default_raw) |dr| try self.allocator.dupe(u8, dr) else null;
                    cloned_spec.default_expr = if (col_entry.value.default_expr) |de| try self.allocator.dupe(u8, de) else null;

                    const owned_col_name = try self.allocator.dupe(u8, col_entry.key);
                    cols[idx] = .{
                        .name = owned_col_name,
                        .spec = cloned_spec,
                        .is_pk = is_pk,
                    };
                    if (is_pk) {
                        try pk_list.append(self.allocator, try self.allocator.dupe(u8, col_entry.key));
                    }
                }

                const owned_tbl_name = try self.allocator.dupe(u8, tbl_entry.key);
                try self.tables.put(self.allocator, owned_tbl_name, .{
                    .columns = cols,
                    .pk_columns = try pk_list.toOwnedSlice(self.allocator),
                });
            }
        }
    }

    pub fn writePayload(self: *MemoryRepository, channel: []const u8, payload: PayloadHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.writePayloadLocked(channel, payload);
    }

    fn writePayloadLocked(self: *MemoryRepository, channel: []const u8, payload: PayloadHandle) !void {
        if (self.payloads.getPtr(channel)) |existing| {
            existing.* = payload;
            return;
        }
        const owned_channel = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(owned_channel);
        try self.payloads.put(self.allocator, owned_channel, payload);
    }

    pub fn readPayload(self: *const MemoryRepository, channel: []const u8) ?PayloadHandle {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.payloads.get(channel);
    }

    pub fn recordCount(self: *const MemoryRepository, channel_or_table: []const u8) usize {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        if (self.tables.get(channel_or_table)) |tbl| {
            return tbl.rows.items.len;
        }
        if (self.payloads.get(channel_or_table)) |h| return h.len;
        return 0;
    }

    pub fn write(self: *MemoryRepository, ws: WriteSpec) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tbl = self.tables.getPtr(ws.table) orelse {
            if (!self.schemaless) return error.UnknownTable;
            try self.writePayloadLocked(ws.table, ws.payload);
            return;
        };

        if (ws.mode == .replace_all) {
            tbl.clearRows(self.allocator);
        }

        if (ws.payload.len == 0) return;

        const row_count = if (ws.payload.is_stream and ws.payload.repr != .bytes) ws.payload.len else 1;
        for (0..row_count) |i| {
            const elem = ws.payload.elementAt(i) orelse continue;
            try self.applyRowWrite(tbl, ws.mode, elem);
        }
    }

    fn applyRowWrite(self: *MemoryRepository, tbl: *TableStore, mode: WriteMode, elem: PayloadHandle) !void {
        const effective_mode: WriteMode = if (mode == .replace_all) .append else mode;

        if (effective_mode == .delete) {
            if (tbl.pk_columns.len == 0) return error.MissingPrimaryKey;
            const match_idx = try self.findMatchingPkRow(tbl, elem) orelse return;
            var removed = tbl.rows.orderedRemove(match_idx);
            removed.deinit(self.allocator);
            return;
        }

        const existing_idx: ?usize = if (tbl.pk_columns.len > 0)
            try self.findMatchingPkRow(tbl, elem)
        else
            null;

        switch (effective_mode) {
            .append => {
                if (existing_idx != null) return error.DuplicatePrimaryKey;
                try self.insertNewRow(tbl, elem);
            },
            .upsert => {
                if (existing_idx) |idx| {
                    try self.updateExistingRow(tbl, &tbl.rows.items[idx], elem);
                } else {
                    try self.insertNewRow(tbl, elem);
                }
            },
            .update => {
                const idx = existing_idx orelse return error.RowNotFound;
                try self.updateExistingRow(tbl, &tbl.rows.items[idx], elem);
            },
            .replace_all, .delete => unreachable,
        }
    }

    fn findMatchingPkRow(self: *MemoryRepository, tbl: *const TableStore, elem: PayloadHandle) !?usize {
        if (tbl.pk_columns.len == 0) return null;

        for (tbl.rows.items, 0..) |*row, row_idx| {
            var all_match = true;
            for (tbl.pk_columns) |pk_col_name| {
                const col = tbl.findColumn(pk_col_name) orelse return error.MissingPrimaryKey;
                const incoming_ref = elem.getReflected(pk_col_name) orelse {
                    all_match = false;
                    break;
                };
                var incoming_val = try self.convertReflected(col.spec, incoming_ref);
                defer incoming_val.deinit(self.allocator);

                const stored_val = row.cells.get(pk_col_name) orelse {
                    all_match = false;
                    break;
                };
                if (!stored_val.eql(incoming_val)) {
                    all_match = false;
                    break;
                }
            }
            if (all_match) return row_idx;
        }
        return null;
    }

    fn insertNewRow(self: *MemoryRepository, tbl: *TableStore, elem: PayloadHandle) !void {
        var new_row: StoredRow = .{};
        errdefer new_row.deinit(self.allocator);

        for (tbl.columns) |col| {
            if (elem.getReflected(col.name)) |ref_val| {
                const sv = try self.convertReflected(col.spec, ref_val);
                try new_row.setCell(self.allocator, col.name, sv);
            } else {
                const def_val = try self.evaluateDefault(tbl, col.spec);
                try new_row.setCell(self.allocator, col.name, def_val);
            }
        }

        try tbl.rows.append(self.allocator, new_row);
    }

    fn updateExistingRow(self: *MemoryRepository, tbl: *TableStore, row: *StoredRow, elem: PayloadHandle) !void {
        for (tbl.columns) |col| {
            if (elem.getReflected(col.name)) |ref_val| {
                const sv = try self.convertReflected(col.spec, ref_val);
                try row.setCell(self.allocator, col.name, sv);
            }
        }
    }

    fn convertReflected(self: *MemoryRepository, spec: ColumnSpec, val: ReflectedValue) !StoredValue {
        if (val == .none) {
            if (!spec.nullable) return error.NullConstraintViolation;
            return .null_val;
        }

        return switch (spec.col_type) {
            .int64, .timestamp => switch (val) {
                .int => |v| .{ .int64 = v },
                .uint => |v| .{ .int64 = @intCast(v) },
                else => error.SchemaTypeMismatch,
            },
            .uint64 => switch (val) {
                .uint => |v| .{ .uint64 = v },
                .int => |v| if (v >= 0) .{ .uint64 = @intCast(v) } else error.SchemaTypeMismatch,
                else => error.SchemaTypeMismatch,
            },
            .float64 => switch (val) {
                .float => |v| .{ .float64 = v },
                .int => |v| .{ .float64 = @floatFromInt(v) },
                .uint => |v| .{ .float64 = @floatFromInt(v) },
                else => error.SchemaTypeMismatch,
            },
            .bool => switch (val) {
                .boolean => |v| .{ .boolean = v },
                else => error.SchemaTypeMismatch,
            },
            .text, .json, .enum_type => switch (val) {
                .string => |s| .{ .text = try self.allocator.dupe(u8, s) },
                else => error.SchemaTypeMismatch,
            },
            .bytes, .blob => switch (val) {
                .bytes => |b| .{ .bytes = try self.allocator.dupe(u8, b) },
                .string => |s| .{ .bytes = try self.allocator.dupe(u8, s) },
                else => error.SchemaTypeMismatch,
            },
            .any => switch (val) {
                .int => |v| .{ .int64 = v },
                .uint => |v| .{ .uint64 = v },
                .float => |v| .{ .float64 = v },
                .boolean => |v| .{ .boolean = v },
                .string => |s| .{ .text = try self.allocator.dupe(u8, s) },
                .bytes => |b| .{ .bytes = try self.allocator.dupe(u8, b) },
                .none => .null_val,
                .unsupported => error.SchemaTypeMismatch,
            },
        };
    }

    fn evaluateDefault(self: *MemoryRepository, tbl: *TableStore, spec: ColumnSpec) !StoredValue {
        if (spec.autoincrement and (spec.col_type == .int64 or spec.col_type == .uint64)) {
            const id = tbl.next_autoincrement;
            tbl.next_autoincrement += 1;
            return if (spec.col_type == .uint64) .{ .uint64 = @intCast(id) } else .{ .int64 = id };
        }

        if (spec.default_raw) |raw| {
            if (std.mem.eql(u8, raw, "now") and (spec.col_type == .timestamp or spec.col_type == .int64)) {
                return .{ .int64 = currentMicroTimestamp() };
            }
            if (std.mem.eql(u8, raw, "uuid") and spec.col_type == .text) {
                self.uuid_seq += 1;
                const uuid_str = try std.fmt.allocPrint(self.allocator, "00000000-0000-4000-8000-{x:0>12}", .{self.uuid_seq});
                return .{ .text = uuid_str };
            }
        }

        if (try spec.parsedDefault()) |def| {
            return switch (def) {
                .null_val => .null_val,
                .int64 => |v| .{ .int64 = v },
                .uint64 => |v| .{ .uint64 = v },
                .float64 => |v| .{ .float64 = v },
                .boolean => |v| .{ .boolean = v },
                .text => |s| .{ .text = try self.allocator.dupe(u8, s) },
                .raw_expr => |expr| .{ .text = try self.allocator.dupe(u8, expr) },
            };
        }

        if (spec.nullable) return .null_val;
        return error.MissingRequiredColumn;
    }

    pub fn read(self: *MemoryRepository, allocator: Allocator, rs: ReadSpec) !PayloadHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tbl = self.tables.get(rs.table) orelse {
            if (!self.schemaless) return error.UnknownTable;
            return self.payloads.get(rs.table) orelse error.RowNotFound;
        };

        const indices = try self.selectRowIndices(allocator, &tbl, rs);
        defer allocator.free(indices);

        var records = try allocator.alloc(DynamicRecord, indices.len);
        for (indices, 0..) |row_idx, out_idx| {
            records[out_idx] = try self.projectRow(allocator, &tbl, &tbl.rows.items[row_idx], rs.projection);
        }

        return PayloadHandle.fromSlice(DynamicRecord, records);
    }

    pub fn readStream(self: *MemoryRepository, allocator: Allocator, rs: ReadSpec) !RowIterator {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tbl = self.tables.get(rs.table) orelse {
            if (!self.schemaless) return error.UnknownTable;
            const payload = self.payloads.get(rs.table) orelse return error.RowNotFound;
            return makeEphemeralStream(allocator, payload);
        };

        const indices = try self.selectRowIndices(allocator, &tbl, rs);
        errdefer allocator.free(indices);

        var records = try allocator.alloc(DynamicRecord, indices.len);
        for (indices, 0..) |row_idx, out_idx| {
            records[out_idx] = try self.projectRow(allocator, &tbl, &tbl.rows.items[row_idx], rs.projection);
        }
        allocator.free(indices);

        const StreamState = struct {
            alloc: Allocator,
            rows: []DynamicRecord,
            cursor: usize = 0,

            fn next(ctx: *anyopaque) anyerror!?PayloadHandle {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                if (st.cursor >= st.rows.len) return null;
                const rec = &st.rows[st.cursor];
                st.cursor += 1;
                return PayloadHandle.fromScalar(DynamicRecord, rec);
            }

            fn deinitStream(ctx: *anyopaque) void {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                for (st.rows) |r| {
                    st.alloc.free(r.fields);
                }
                st.alloc.free(st.rows);
                st.alloc.destroy(st);
            }

            const vtable = RowIterator.VTable{
                .next = &next,
                .deinit = &deinitStream,
            };
        };

        const st = try allocator.create(StreamState);
        st.* = .{
            .alloc = allocator,
            .rows = records,
        };
        return .{ .ptr = st, .vtable = &StreamState.vtable };
    }

    fn selectRowIndices(self: *MemoryRepository, allocator: Allocator, tbl: *const TableStore, rs: ReadSpec) ![]usize {
        _ = self;
        var matched: std.ArrayListUnmanaged(usize) = .empty;
        errdefer matched.deinit(allocator);

        const where_node: ?*const PredicateNode = if (rs.where) |w| @ptrCast(@alignCast(w)) else null;

        for (tbl.rows.items, 0..) |*row, idx| {
            if (where_node) |node| {
                if (!predicate_ast.evalNode(node, &StoredRow.getter, row)) continue;
            }
            try matched.append(allocator, idx);
        }

        if (rs.order_by.len > 0) {
            const SortCtx = struct {
                rows: []const StoredRow,
                order_by: []const OrderByColumn,

                pub fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
                    const row_a = &ctx.rows[a_idx];
                    const row_b = &ctx.rows[b_idx];
                    for (ctx.order_by) |ob| {
                        const va = row_a.cells.get(ob.column) orelse StoredValue.null_val;
                        const vb = row_b.cells.get(ob.column) orelse StoredValue.null_val;
                        const ord = StoredValue.order(va, vb);
                        if (ord != .eq) {
                            return if (ob.order == .asc) ord == .lt else ord == .gt;
                        }
                    }
                    return false;
                }
            };
            std.mem.sort(usize, matched.items, SortCtx{
                .rows = tbl.rows.items,
                .order_by = rs.order_by,
            }, SortCtx.lessThan);
        }

        const start = @min(rs.offset, matched.items.len);
        const avail = matched.items.len - start;
        const take = if (rs.limit == 0) avail else @min(rs.limit, avail);

        const result = try allocator.alloc(usize, take);
        @memcpy(result, matched.items[start .. start + take]);
        matched.deinit(allocator);
        return result;
    }

    fn projectRow(
        _: *MemoryRepository,
        allocator: Allocator,
        tbl: *const TableStore,
        row: *const StoredRow,
        projection: ProjectionMode,
    ) !DynamicRecord {
        var fields: std.ArrayListUnmanaged(DynamicField) = .empty;
        errdefer fields.deinit(allocator);

        for (tbl.columns) |col| {
            const include = switch (projection) {
                .all => true,
                .include => |inc| blk: {
                    for (inc) |name| {
                        if (std.mem.eql(u8, name, col.name)) break :blk true;
                    }
                    break :blk false;
                },
                .exclude => |exc| blk: {
                    var excluded = false;
                    for (exc) |name| {
                        if (std.mem.eql(u8, name, col.name)) {
                            excluded = true;
                            break;
                        }
                    }
                    break :blk !excluded;
                },
            };
            if (!include) continue;

            const sv = row.cells.get(col.name) orelse StoredValue.null_val;
            const owned_val: ReflectedValue = switch (sv) {
                .text => |s| .{ .string = try allocator.dupe(u8, s) },
                .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
                else => sv.toReflected(),
            };
            try fields.append(allocator, .{
                .name = col.name,
                .value = owned_val,
            });
        }

        return DynamicRecord.init(try fields.toOwnedSlice(allocator));
    }

    pub fn repository(self: *MemoryRepository) Repository {
        return .{
            .ptr = self,
            .vtable = &static_vtable,
        };
    }

    pub fn storageRepository(self: *MemoryRepository) StorageRepository {
        return self.repository();
    }

    // ── VTable trampolines ────────────────────────────────────────────────────

    fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
        const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
        try s.writePayload(channel, payload);
    }

    fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
        const s: *const MemoryRepository = @ptrCast(@alignCast(ctx));
        return s.readPayload(channel);
    }

    fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
        const s: *const MemoryRepository = @ptrCast(@alignCast(ctx));
        return s.recordCount(channel);
    }

    fn doDeinitStatic(ctx: *anyopaque) void {
        const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
        s.deinit();
    }

    fn doDeinitHeap(ctx: *anyopaque) void {
        const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
        const alloc = s.allocator;
        s.deinit();
        alloc.destroy(s);
    }

    fn doGetCapabilities(ctx: *const anyopaque) Capabilities {
        const s: *const MemoryRepository = @ptrCast(@alignCast(ctx));
        return s.getCapabilities();
    }

    fn doEnsureSchema(ctx: *anyopaque, catalog_ptr: *const anyopaque) anyerror!void {
        const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
        const catalog: *const SchemaCatalog = @ptrCast(@alignCast(catalog_ptr));
        try s.ensureSchema(catalog);
    }

    fn doWrite(ctx: *anyopaque, ws: WriteSpec) anyerror!void {
        const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
        try s.write(ws);
    }

    fn doRead(ctx: *anyopaque, allocator: Allocator, rs: ReadSpec) anyerror!PayloadHandle {
        const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
        return s.read(allocator, rs);
    }

    fn doReadStream(ctx: *anyopaque, allocator: Allocator, rs: ReadSpec) anyerror!RowIterator {
        const s: *MemoryRepository = @ptrCast(@alignCast(ctx));
        return s.readStream(allocator, rs);
    }

    const static_vtable = Repository.VTable{
        .writePayload = &doWritePayload,
        .readPayload = &doReadPayload,
        .recordCount = &doRecordCount,
        .deinit = &doDeinitStatic,
        .getCapabilities = &doGetCapabilities,
        .ensureSchema = &doEnsureSchema,
        .write = &doWrite,
        .read = &doRead,
        .readStream = &doReadStream,
    };

    const heap_vtable = Repository.VTable{
        .writePayload = &doWritePayload,
        .readPayload = &doReadPayload,
        .recordCount = &doRecordCount,
        .deinit = &doDeinitHeap,
        .getCapabilities = &doGetCapabilities,
        .ensureSchema = &doEnsureSchema,
        .write = &doWrite,
        .read = &doRead,
        .readStream = &doReadStream,
    };

    pub fn createHeap(allocator: Allocator, params: []const repository_mod.ConfigParam) anyerror!StorageRepository {
        var schemaless = true;
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "schemaless") and std.mem.eql(u8, p.value, "false")) {
                schemaless = false;
            }
        }
        const self_ptr = try allocator.create(MemoryRepository);
        self_ptr.* = MemoryRepository.initWithOptions(allocator, schemaless);

        return .{
            .ptr = self_ptr,
            .vtable = &heap_vtable,
        };
    }
};

fn makeEphemeralStream(allocator: Allocator, payload: PayloadHandle) !RowIterator {
    const EphemeralIter = struct {
        alloc: Allocator,
        payload: PayloadHandle,
        done: bool = false,

        fn next(ctx: *anyopaque) anyerror!?PayloadHandle {
            const it: *@This() = @ptrCast(@alignCast(ctx));
            if (it.done) return null;
            it.done = true;
            return it.payload;
        }

        fn deinit(ctx: *anyopaque) void {
            const it: *@This() = @ptrCast(@alignCast(ctx));
            it.alloc.destroy(it);
        }

        const vtable = RowIterator.VTable{
            .next = &next,
            .deinit = &deinit,
        };
    };

    const it = try allocator.create(EphemeralIter);
    it.* = .{ .alloc = allocator, .payload = payload };
    return .{ .ptr = it, .vtable = &EphemeralIter.vtable };
}

fn currentMicroTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1_000_000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000);
}

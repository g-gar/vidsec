const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const extensions = @import("flowdata_extensions");
const MemoryRepository = extensions.datasource.memory.MemoryRepository;
const SqliteRepository = extensions.datasource.sqlite.SqliteRepository;
const Repository = flowdata.Repository;
const ConfigParam = flowdata.repository.ConfigParam;
const WriteSpec = flowdata.WriteSpec;
const ReadSpec = flowdata.ReadSpec;
const SchemaCatalog = flowdata.SchemaCatalog;
const PayloadHandle = flowdata.dataflow.PayloadHandle;
const DynamicRecord = flowdata.dataflow.DynamicRecord;
const predicate_ast = flowdata.dataflow.predicate_ast;
const PredicateParser = predicate_ast.PredicateParser;
const SynchronizedRepository = flowdata.SynchronizedRepository;
const AsyncBatchRepository = flowdata.AsyncBatchRepository;
const preflight = flowdata.engine.preflight;
const sdk = flowdata.plugin.sdk;

pub const RepoFactoryFn = *const fn (allocator: Allocator, params: []const ConfigParam) anyerror!Repository;

const TestSchemaYaml =
    \\version: 2
    \\schemas:
    \\  core:
    \\    users:
    \\      columns:
    \\        id: { type: int64, pk: true }
    \\        name: { type: text }
    \\        bio: { type: text, nullable: true }
    \\        age: { type: int64, default: "18" }
    \\        status: { type: text, default: "active" }
    \\    posts:
    \\      columns:
    \\        id: { type: int64, pk: true }
    \\        user_id: { type: int64, ref: users.id, on_delete: cascade }
    \\        title: { type: text }
;

/// Shared driver conformance suite (ARCH-009A §4).
/// Any driver implementing `Repository` (memory, sqlite, etc.) can invoke this
/// function to verify full 009A behavioral conformance.
pub fn runConformanceSuite(allocator: Allocator, makeRepo: RepoFactoryFn) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try flowdata.yaml.parseSchemaCatalog(arena, TestSchemaYaml, null);

    const strict_params = [_]ConfigParam{.{ .key = "schemaless", .value = "false" }};
    var repo = try makeRepo(allocator, &strict_params);
    defer repo.deinit();

    try repo.ensureSchema(&catalog);

    // 1. Undeclared table fails with UnknownTable when schemaless == false
    {
        const Dummy = struct { id: i64 };
        const d = Dummy{ .id = 1 };
        try testing.expectError(error.UnknownTable, repo.write(.{
            .table = "nonexistent_table",
            .mode = .upsert,
            .payload = PayloadHandle.fromScalar(Dummy, &d),
        }));
    }

    // 2. Insert parent + child rows, then upsert parent partial update:
    //    - preserves untouched columns (age, status)
    //    - writes explicit null (bio = null)
    //    - does NOT trigger ON DELETE CASCADE on child rows
    {
        const UserFull = struct {
            id: i64,
            name: []const u8,
            bio: ?[]const u8,
            age: i64,
            status: []const u8,
        };
        const user1 = UserFull{ .id = 1, .name = "Alice", .bio = "Author", .age = 30, .status = "active" };
        const user2 = UserFull{ .id = 2, .name = "Bob", .bio = "Reader", .age = 22, .status = "inactive" };
        const users = [_]UserFull{ user1, user2 };
        try repo.write(.{
            .table = "users",
            .mode = .append,
            .payload = PayloadHandle.fromSlice(UserFull, &users),
        });

        const Post = struct { id: i64, user_id: i64, title: []const u8 };
        const p1 = Post{ .id = 10, .user_id = 1, .title = "Hello World" };
        try repo.write(.{
            .table = "posts",
            .mode = .append,
            .payload = PayloadHandle.fromScalar(Post, &p1),
        });

        // Partial upsert on user 1: omit `age` and `status`, explicitly set `bio = null`
        const UserPartial = struct {
            id: i64,
            name: []const u8,
            bio: ?[]const u8,
        };
        const u1_patch = UserPartial{ .id = 1, .name = "Alice Updated", .bio = null };
        try repo.write(.{
            .table = "users",
            .mode = .upsert,
            .payload = PayloadHandle.fromScalar(UserPartial, &u1_patch),
        });

        // Child row must still exist!
        try testing.expectEqual(@as(usize, 1), repo.count("posts"));

        // Verify partial update preserved `age` and `status` and wrote `bio = null`
        const where_id1 = try PredicateParser.fromExpr(arena, "id == 1");
        const res = try repo.read(arena, .{
            .table = "users",
            .where = where_id1,
        });
        try testing.expectEqual(@as(usize, 1), res.len);
        const rec = res.elementAt(0).?;
        try testing.expectEqualStrings("Alice Updated", rec.getReflected("name").?.string);
        try testing.expect(rec.getReflected("bio").? == .none);
        try testing.expectEqual(@as(i64, 30), rec.getReflected("age").?.int);
        try testing.expectEqualStrings("active", rec.getReflected("status").?.string);
    }

    // 3. append duplicate PK fails; update missing PK fails; update existing PK succeeds
    {
        const UserMin = struct { id: i64, name: []const u8 };
        const dup = UserMin{ .id = 1, .name = "Dup" };
        try testing.expectError(error.DuplicatePrimaryKey, repo.write(.{
            .table = "users",
            .mode = .append,
            .payload = PayloadHandle.fromScalar(UserMin, &dup),
        }));

        const missing = UserMin{ .id = 999, .name = "Ghost" };
        try testing.expectError(error.RowNotFound, repo.write(.{
            .table = "users",
            .mode = .update,
            .payload = PayloadHandle.fromScalar(UserMin, &missing),
        }));

        const upd = UserMin{ .id = 2, .name = "Bob Updated" };
        try repo.write(.{
            .table = "users",
            .mode = .update,
            .payload = PayloadHandle.fromScalar(UserMin, &upd),
        });
    }

    // 4. ReadSpec + readStream with Predicate AST, order_by, limit, offset, projection
    {
        const UserMin = struct { id: i64, name: []const u8, age: i64 };
        const user3 = UserMin{ .id = 3, .name = "Charlie", .age = 25 };
        try repo.write(.{
            .table = "users",
            .mode = .append,
            .payload = PayloadHandle.fromScalar(UserMin, &user3),
        });

        const where_age = try PredicateParser.fromExpr(arena, "age >= 25");
        const order_desc = [_]flowdata.repository.OrderByColumn{.{ .column = "age", .order = .desc }};
        const inc_cols = [_][]const u8{ "id", "name" };

        const res = try repo.read(arena, .{
            .table = "users",
            .where = where_age,
            .order_by = &order_desc,
            .limit = 1,
            .offset = 1,
            .projection = .{ .include = &inc_cols },
        });
        try testing.expectEqual(@as(usize, 1), res.len);
        const row0 = res.elementAt(0).?;
        try testing.expectEqual(@as(i64, 3), row0.getReflected("id").?.int);
        try testing.expectEqualStrings("Charlie", row0.getReflected("name").?.string);
        try testing.expect(row0.getReflected("age") == null);

        // readStream yields rows step-by-step
        var iter = try repo.readStream(arena, .{
            .table = "users",
            .order_by = &order_desc,
        });
        defer iter.deinit();

        var stream_count: usize = 0;
        while (try iter.next()) |item| {
            try testing.expect(item.getReflected("id") != null);
            stream_count += 1;
        }
        try testing.expectEqual(@as(usize, 3), stream_count);
    }

    // 5. delete & replace_all
    {
        const IdOnly = struct { id: i64 };
        const del2 = IdOnly{ .id = 2 };
        try repo.write(.{
            .table = "users",
            .mode = .delete,
            .payload = PayloadHandle.fromScalar(IdOnly, &del2),
        });
        try testing.expectEqual(@as(usize, 2), repo.count("users"));

        const UserMin = struct { id: i64, name: []const u8 };
        const fresh = UserMin{ .id = 100, .name = "Fresh" };
        try repo.write(.{
            .table = "users",
            .mode = .replace_all,
            .payload = PayloadHandle.fromScalar(UserMin, &fresh),
        });
        try testing.expectEqual(@as(usize, 1), repo.count("users"));
    }
}

test "ARCH-009A: MemoryRepository satisfies driver conformance suite" {
    try runConformanceSuite(testing.allocator, MemoryRepository.createHeap);
}

test "ARCH-009A: SynchronizedRepository and AsyncBatchRepository decorators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try flowdata.yaml.parseSchemaCatalog(arena, TestSchemaYaml, null);

    const mem = try MemoryRepository.createHeap(testing.allocator, &.{});
    var synced = SynchronizedRepository.init(testing.allocator, mem);
    var async_repo = AsyncBatchRepository.init(testing.allocator, synced.repository(), .{
        .capacity = 16,
        .batch_size = 4,
    });
    defer async_repo.deinit();

    const repo = async_repo.repository();
    try repo.ensureSchema(&catalog);

    const UserRow = struct { id: i64, name: []const u8 };
    var rows: [10]UserRow = undefined;
    for (&rows, 0..) |*r, i| {
        r.* = .{ .id = @intCast(i + 1), .name = "User" };
        try repo.write(.{
            .table = "users",
            .mode = .append,
            .payload = PayloadHandle.fromScalar(UserRow, r),
        });
    }

    // Read triggers flush() for read-your-own-writes consistency
    try testing.expectEqual(@as(usize, 10), repo.count("users"));
}

test "ARCH-009A: Preflight TaskDescriptor_ABI metadata & SchemaCatalog validation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try flowdata.yaml.parseSchemaCatalog(arena, TestSchemaYaml, null);
    const users_tbl = catalog.getTable("users").?;

    // Valid output struct
    const ValidOut = struct { id: i64, name: []const u8, bio: ?[]const u8 };
    const valid_task = sdk.defineTask(.{
        .name = "valid_user_emitter",
        .run = struct {
            fn run() !ValidOut {
                return .{ .id = 1, .name = "A", .bio = null };
            }
        }.run,
    });
    try preflight.validateTaskOutputSchema(&valid_task, users_tbl);

    // Type mismatch: `age` is text instead of int64
    const BadTypeOut = struct { id: i64, name: []const u8, age: []const u8 };
    const bad_type_task = sdk.defineTask(.{
        .name = "bad_type_emitter",
        .run = struct {
            fn run() !BadTypeOut {
                return .{ .id = 1, .name = "A", .age = "thirty" };
            }
        }.run,
    });
    try testing.expectError(error.SchemaTypeMismatch, preflight.validateTaskOutputSchema(&bad_type_task, users_tbl));

    // Nullability mismatch: `name` is nullable `?[]const u8` when column `name` is NOT NULL without default
    const BadNullOut = struct { id: i64, name: ?[]const u8 };
    const bad_null_task = sdk.defineTask(.{
        .name = "bad_null_emitter",
        .run = struct {
            fn run() !BadNullOut {
                return .{ .id = 1, .name = null };
            }
        }.run,
    });
    try testing.expectError(error.SchemaNullabilityMismatch, preflight.validateTaskOutputSchema(&bad_null_task, users_tbl));

    // Missing PK: `id` omitted
    const MissingPkOut = struct { name: []const u8 };
    const missing_pk_task = sdk.defineTask(.{
        .name = "missing_pk_emitter",
        .run = struct {
            fn run() !MissingPkOut {
                return .{ .name = "A" };
            }
        }.run,
    });
    try testing.expectError(error.MissingPrimaryKeyField, preflight.validateTaskOutputSchema(&missing_pk_task, users_tbl));
}

test "ARCH-009A: ConcurrencyPolicy & ManagedRepository explicit policy selection" {
    const policies = [_]flowdata.ConcurrencyPolicy{
        .none,
        .mutex,
        .{ .async_batch = .{ .capacity = 8, .batch_size = 4 } },
    };

    for (policies) |policy| {
        const mem = try MemoryRepository.createHeap(testing.allocator, &.{});
        var managed = try flowdata.ManagedRepository.init(testing.allocator, mem, policy);
        defer managed.deinit();

        const repo = managed.repository();
        const Row = struct { id: i64 };
        const row = Row{ .id = 42 };
        try repo.write(.{
            .table = "items",
            .mode = .append,
            .payload = PayloadHandle.fromScalar(Row, &row),
        });
        try testing.expectEqual(@as(usize, 1), repo.count("items"));
    }
}

test "ARCH-009B: SqliteRepository passes 009A conformance suite" {
    try runConformanceSuite(testing.allocator, SqliteRepository.createHeap);
}

test "ARCH-009B: strict tables, parameterized seeds, and Phase 1 non-destructive migrations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v1_yaml =
        \\version: 2
        \\schemas:
        \\  core:
        \\    items:
        \\      columns:
        \\        id: { type: int64, pk: true }
        \\        code: { type: text, unique: true }
        \\        note: { type: text, nullable: true }
        \\      seeds:
        \\        - { id: 1, code: "a'b", note: null }
    ;
    const cat_v1 = try flowdata.yaml.parseSchemaCatalog(arena, v1_yaml, null);

    const strict_params = [_]ConfigParam{.{ .key = "schemaless", .value = "false" }};
    var repo = try SqliteRepository.createHeap(testing.allocator, &strict_params);
    defer repo.deinit();

    try repo.ensureSchema(&cat_v1);
    try testing.expectEqual(@as(usize, 1), repo.count("items"));

    // Read back seeded row and verify SQL injection-safe escaping + NULL handling
    const res = try repo.read(arena, .{ .table = "items" });
    try testing.expectEqual(@as(usize, 1), res.len);
    const rec = res.elementAt(0).?;
    try testing.expectEqualStrings("a'b", rec.getReflected("code").?.string);
    try testing.expect(rec.getReflected("note").? == .none);

    // Phase 1 non-destructive migration: add a nullable column
    const v2_yaml =
        \\version: 2
        \\schemas:
        \\  core:
        \\    items:
        \\      columns:
        \\        id: { type: int64, pk: true }
        \\        code: { type: text, unique: true }
        \\        note: { type: text, nullable: true }
        \\        extra: { type: int64, default: "0" }
    ;
    const cat_v2 = try flowdata.yaml.parseSchemaCatalog(arena, v2_yaml, null);
    try repo.ensureSchema(&cat_v2);

    // Destructive drift: drop a column -> must fail loudly
    const v3_bad_yaml =
        \\version: 2
        \\schemas:
        \\  core:
        \\    items:
        \\      columns:
        \\        id: { type: int64, pk: true }
        \\        code: { type: text, unique: true }
    ;
    const cat_v3 = try flowdata.yaml.parseSchemaCatalog(arena, v3_bad_yaml, null);
    try testing.expectError(error.DestructiveSchemaDrift, repo.ensureSchema(&cat_v3));
}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const types = @import("types.zig");
pub const ReflectedValue = types.ReflectedValue;
pub const reflectField = types.reflectField;
pub const reflectAny = types.reflectAny;
pub const PayloadHandle = types.PayloadHandle;
pub const DynamicField = types.DynamicField;
pub const DynamicRecord = types.DynamicRecord;

pub const algebra = @import("algebra.zig");
pub const merge = algebra.merge;
pub const zip = algebra.zip;
pub const join = algebra.join;
pub const slice = algebra.slice;
pub const slicePayload = algebra.slicePayload;
pub const mergePayloads = algebra.mergePayloads;
pub const Pair = algebra.Pair;
pub const Joined = algebra.Joined;

pub const predicate = @import("predicate.zig");
pub const evaluatePredicate = predicate.evaluatePredicate;
pub const evaluatePredicateHandle = predicate.evaluatePredicateHandle;
pub const filterStream = predicate.filterStream;
pub const filterPayload = predicate.filterPayload;

pub const parallel = @import("parallel.zig");
pub const parallelFor = parallel.parallelFor;
pub const ParallelError = parallel.ParallelError;

pub const lifter = @import("lifter.zig");
pub const ExecutionOptions = lifter.ExecutionOptions;
pub const ErasedTaskFn = lifter.ErasedTaskFn;
pub const wrapElemental = lifter.wrapElemental;
pub const wrapExpansion = lifter.wrapExpansion;
pub const wrapReduction = lifter.wrapReduction;
pub const wrapBatch = lifter.wrapBatch;

pub const dispatcher = @import("dispatcher.zig");
pub const ChannelSpec = dispatcher.ChannelSpec;
pub const DispatchedChannel = dispatcher.DispatchedChannel;
pub const dispatchStream = dispatcher.dispatchStream;

// =============================================================================
// COMPREHENSIVE UNIT TESTS (OPTION A: ZERO-COPY NATIVE DATAFLOW + PARALLELISM)
// =============================================================================

const TestRegion = struct {
    id: i64,
    role: []const u8,
    score: f64,
    is_clean: bool,
    tag: ?[]const u8 = null,
};

const TestChapter = struct {
    id: i64,
    title: []const u8,
};

const TestChapterDetail = struct {
    id: i64,
    pages: i64,
};

test "dataflow: native struct reflection without boxing" {
    const r = TestRegion{
        .id = 42,
        .role = "padding",
        .score = 0.95,
        .is_clean = true,
        .tag = "verified",
    };

    const id_val = reflectField(TestRegion, &r, "id");
    try std.testing.expect(id_val != null);
    try std.testing.expectEqual(id_val.?.asInt().?, 42);

    const role_val = reflectField(TestRegion, &r, "role");
    try std.testing.expect(role_val != null);
    try std.testing.expectEqualStrings(role_val.?.asString().?, "padding");

    const score_val = reflectField(TestRegion, &r, "score");
    try std.testing.expect(score_val != null);
    try std.testing.expectEqual(score_val.?.asFloat().?, 0.95);

    const clean_val = reflectField(TestRegion, &r, "is_clean");
    try std.testing.expect(clean_val != null);
    try std.testing.expectEqual(clean_val.?.asBool().?, true);

    const tag_val = reflectField(TestRegion, &r, "tag");
    try std.testing.expect(tag_val != null);
    try std.testing.expectEqualStrings(tag_val.?.asString().?, "verified");

    try std.testing.expect(reflectField(TestRegion, &r, "non_existent") == null);
}

test "dataflow: PayloadHandle zero-copy wrapping and unwrapping" {
    const items = [_]TestRegion{
        .{ .id = 1, .role = "header", .score = 0.8, .is_clean = true },
        .{ .id = 2, .role = "footer", .score = 0.5, .is_clean = false },
    };

    const handle = PayloadHandle.fromSlice(TestRegion, &items);
    try std.testing.expect(handle.is_stream);
    try std.testing.expectEqual(handle.len, 2);

    const reconstructed = handle.asSlice(TestRegion);
    try std.testing.expectEqual(reconstructed.len, 2);
    try std.testing.expectEqual(reconstructed[0].id, 1);
    try std.testing.expectEqualStrings(reconstructed[1].role, "footer");
}

test "dataflow: native algebra merge" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const stream_1 = [_]TestRegion{
        .{ .id = 1, .role = "a", .score = 0.1, .is_clean = true },
    };
    const stream_2 = [_]TestRegion{
        .{ .id = 2, .role = "b", .score = 0.2, .is_clean = true },
        .{ .id = 3, .role = "c", .score = 0.3, .is_clean = false },
    };

    const merged = try merge(TestRegion, alloc, &.{ &stream_1, &stream_2 });
    defer alloc.free(merged);

    try testing.expectEqual(merged.len, 3);
    try testing.expectEqual(merged[0].id, 1);
    try testing.expectEqual(merged[1].id, 2);
    try testing.expectEqual(merged[2].id, 3);
}

test "dataflow: native algebra zip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const chapters = [_]TestChapter{
        .{ .id = 10, .title = "Chapter 1" },
        .{ .id = 20, .title = "Chapter 2" },
    };
    const details = [_]TestChapterDetail{
        .{ .id = 10, .pages = 15 },
        .{ .id = 20, .pages = 22 },
    };

    const zipped = try zip(TestChapter, TestChapterDetail, alloc, &chapters, &details);
    defer alloc.free(zipped);

    try testing.expectEqual(zipped.len, 2);
    try testing.expectEqualStrings(zipped[0].first.title, "Chapter 1");
    try testing.expectEqual(zipped[0].second.pages, 15);
    try testing.expectEqualStrings(zipped[1].first.title, "Chapter 2");
    try testing.expectEqual(zipped[1].second.pages, 22);
}

test "dataflow: native algebra join on key" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const chapters = [_]TestChapter{
        .{ .id = 1, .title = "Intro" },
        .{ .id = 2, .title = "Climax" },
    };
    const details = [_]TestChapterDetail{
        .{ .id = 2, .pages = 32 },
        .{ .id = 1, .pages = 16 },
    };

    const joined = try join(TestChapter, TestChapterDetail, "id", "id", alloc, &chapters, &details);
    defer alloc.free(joined);

    try testing.expectEqual(joined.len, 2);
    try testing.expectEqual(joined[0].left.id, 1);
    try testing.expectEqualStrings(joined[0].left.title, "Intro");
    try testing.expectEqual(joined[0].right.pages, 16);

    try testing.expectEqual(joined[1].left.id, 2);
    try testing.expectEqualStrings(joined[1].left.title, "Climax");
    try testing.expectEqual(joined[1].right.pages, 32);
}

test "dataflow: native slice zero-copy" {
    const items = [_]i32{ 10, 20, 30, 40, 50 };
    const sub = slice(i32, &items, 1, 3);
    try std.testing.expectEqual(sub.len, 3);
    try std.testing.expectEqual(sub[0], 20);
    try std.testing.expectEqual(sub[2], 40);
}

test "dataflow: native predicate evaluation and stream filtering" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const regions = [_]TestRegion{
        .{ .id = 1, .role = "padding", .score = 0.95, .is_clean = true },
        .{ .id = 2, .role = "content", .score = 0.99, .is_clean = false },
        .{ .id = 3, .role = "padding", .score = 0.40, .is_clean = false },
    };

    const filtered = try filterStream(TestRegion, alloc, &regions, "role == 'padding' and score >= 0.8");
    defer alloc.free(filtered);

    try testing.expectEqual(filtered.len, 1);
    try testing.expectEqual(filtered[0].id, 1);
    try testing.expectEqualStrings(filtered[0].role, "padding");
}

// Native task mocks for Lifter testing
const NumberIn = struct { value: i64 };
const NumberOut = struct { doubled: i64 };

fn mockDoubleNumber(_: Allocator, in: NumberIn) anyerror!NumberOut {
    return .{ .doubled = in.value * 2 };
}

fn mockSumNumbers(_: Allocator, in: []const NumberIn) anyerror!NumberOut {
    var sum: i64 = 0;
    for (in) |n| sum += n.value;
    return .{ .doubled = sum };
}

fn mockExpandNumber(allocator: Allocator, in: NumberIn) anyerror![]const NumberOut {
    const res = try allocator.alloc(NumberOut, 2);
    res[0] = .{ .doubled = in.value };
    res[1] = .{ .doubled = in.value * 10 };
    return res;
}

test "dataflow: automatic lifting sequential (workers: 1)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const inputs = [_]NumberIn{
        .{ .value = 10 },
        .{ .value = 25 },
        .{ .value = 50 },
    };

    const input_payload = PayloadHandle.fromSlice(NumberIn, &inputs);
    const lifted_task = wrapElemental(NumberIn, NumberOut, mockDoubleNumber);

    const result_payload = try lifted_task(alloc, input_payload, .{ .workers = 1 });
    defer alloc.free(result_payload.asSlice(NumberOut));

    try testing.expect(result_payload.is_stream);
    try testing.expectEqual(result_payload.len, 3);

    const outputs = result_payload.asSlice(NumberOut);
    try testing.expectEqual(outputs[0].doubled, 20);
    try testing.expectEqual(outputs[1].doubled, 50);
    try testing.expectEqual(outputs[2].doubled, 100);
}

test "dataflow: automatic lifting with multi-core data parallelism (workers: 4)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create 100 items to distribute across 4 worker threads
    var inputs: [100]NumberIn = undefined;
    for (&inputs, 0..) |*item, i| {
        item.* = .{ .value = @as(i64, @intCast(i)) };
    }

    const input_payload = PayloadHandle.fromSlice(NumberIn, &inputs);
    const lifted_task = wrapElemental(NumberIn, NumberOut, mockDoubleNumber);

    const result_payload = try lifted_task(alloc, input_payload, .{ .workers = 4 });
    defer alloc.free(result_payload.asSlice(NumberOut));

    try testing.expect(result_payload.is_stream);
    try testing.expectEqual(result_payload.len, 100);

    const outputs = result_payload.asSlice(NumberOut);
    // Verify each element matches exact deterministic 2*i index order
    for (outputs, 0..) |out, i| {
        try testing.expectEqual(out.doubled, @as(i64, @intCast(i * 2)));
    }
}

test "dataflow: parallel expansion with deterministic ordering (workers: 4)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var inputs: [20]NumberIn = undefined;
    for (&inputs, 0..) |*item, i| {
        item.* = .{ .value = @as(i64, @intCast(i + 1)) };
    }

    const input_payload = PayloadHandle.fromSlice(NumberIn, &inputs);
    const expansion_task = wrapExpansion(NumberIn, NumberOut, mockExpandNumber);

    const result_payload = try expansion_task(alloc, input_payload, .{ .workers = 4 });
    defer {
        alloc.free(result_payload.asSlice(NumberOut));
    }

    try testing.expect(result_payload.is_stream);
    try testing.expectEqual(result_payload.len, 40);

    const outputs = result_payload.asSlice(NumberOut);
    for (0..20) |i| {
        const expected_val = @as(i64, @intCast(i + 1));
        try testing.expectEqual(outputs[i * 2].doubled, expected_val);
        try testing.expectEqual(outputs[i * 2 + 1].doubled, expected_val * 10);
    }
}

test "dataflow: reduction of native stream to scalar (N->1)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const inputs = [_]NumberIn{
        .{ .value = 10 },
        .{ .value = 20 },
        .{ .value = 30 },
    };

    const input_payload = PayloadHandle.fromSlice(NumberIn, &inputs);
    const reduction_task = wrapReduction(NumberIn, NumberOut, mockSumNumbers);

    const result_payload = try reduction_task(alloc, input_payload, .{ .workers = 1 });
    defer alloc.destroy(result_payload.asScalar(NumberOut));

    try testing.expect(!result_payload.is_stream);
    try testing.expectEqual(result_payload.asScalar(NumberOut).doubled, 60);
}

test "dataflow: native dispatcher with declarative filtering" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const regions = [_]TestRegion{
        .{ .id = 1, .role = "padding", .score = 0.95, .is_clean = true },
        .{ .id = 2, .role = "content", .score = 0.99, .is_clean = false },
        .{ .id = 3, .role = "padding", .score = 0.40, .is_clean = false },
    };

    const channels = [_]ChannelSpec{
        .{
            .name = "clean_padding",
            .datasource = "audit_db",
            .filter = "role == 'padding' and score >= 0.5",
        },
    };

    const dispatched = try dispatchStream(TestRegion, alloc, &regions, &channels);
    defer {
        alloc.free(dispatched[0].payload.asSlice(TestRegion));
        alloc.free(dispatched);
    }

    try testing.expectEqual(dispatched.len, 1);
    try testing.expectEqualStrings(dispatched[0].name, "clean_padding");
    try testing.expectEqualStrings(dispatched[0].datasource, "audit_db");

    const channel_items = dispatched[0].payload.asSlice(TestRegion);
    try testing.expectEqual(channel_items.len, 1);
    try testing.expectEqual(channel_items[0].id, 1);
}

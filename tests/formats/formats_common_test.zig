const std = @import("std");
const common = @import("vidsec_formats_common");

test "ByteSource: reads from slice correctly" {
    const data = "ABCDEFGHIJ0123456789";
    const source = common.ByteSource.fromSlice(data);

    try std.testing.expectEqual(@as(u64, 20), source.file_size);

    var buf: [5]u8 = undefined;
    const n = try source.readAt(&buf, 10);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("01234", &buf);

    // Read at or past EOF
    const n_eof = try source.readAt(&buf, 20);
    try std.testing.expectEqual(@as(usize, 0), n_eof);
}

test "Region / ElementSpan: computed offsets and boundaries" {
    const reg = common.Region{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'o', 'o', 'v' },
        .header_offset = 100,
        .payload_offset = 108,
        .size = 50,
        .depth = 0,
    };

    try std.testing.expectEqual(@as(u64, 150), reg.effectiveEnd());
    try std.testing.expectEqual(@as(u64, 150), reg.endOffset());
    try std.testing.expectEqual(@as(u64, 42), reg.payloadSize());
    try std.testing.expectEqual(@as(u64, 8), reg.headerSize());
    try std.testing.expectEqual(@as(u64, 100), reg.offset());
    try std.testing.expectEqualStrings("moov", reg.tagSlice());
    try std.testing.expectEqualStrings("moov", reg.idSlice());
}

test "StructuralAuditor: detects gaps, overlaps, and trailing overlay" {
    const allocator = std.testing.allocator;

    const reg1 = common.Region{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'f', 't', 'y', 'p' },
        .header_offset = 0,
        .payload_offset = 8,
        .size = 20,
        .depth = 0,
    };

    // reg2 has a gap between reg1 (ends at 20) and reg2 (starts at 30)
    const reg2 = common.Region{
        .id = 2,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'o', 'o', 'v' },
        .header_offset = 30,
        .payload_offset = 38,
        .size = 40,
        .depth = 0,
    };

    const regions = [_]common.Region{ reg1, reg2 };
    var diagnostics = common.DiagnosticList.init();
    defer {
        for (diagnostics.items.items) |d| {
            allocator.free(d.message);
        }
        diagnostics.deinit(allocator);
    }

    // File size is 100, so reg2 ends at 70, leaving 30 bytes of trailing overlay
    try common.StructuralAuditor.auditRegions(
        allocator,
        &regions,
        100, // file_size
        false, // allow_gaps = false
        &diagnostics,
    );

    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.items.len);
    try std.testing.expect(diagnostics.hasRuleId("structural.unreferenced_gap"));
    try std.testing.expect(diagnostics.hasRuleId("structural.trailing_overlay"));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.countBySeverity(.warning));
}

test "StructuralAuditor: detects overlaps between root elements" {
    const allocator = std.testing.allocator;

    const reg1 = common.Region{
        .id = 1,
        .parent_id = null,
        .tag = [_]u8{ 'f', 't', 'y', 'p' },
        .header_offset = 0,
        .payload_offset = 8,
        .size = 50,
        .depth = 0,
    };

    // reg2 starts at 40, while reg1 ends at 50 (10 bytes overlap)
    const reg2 = common.Region{
        .id = 2,
        .parent_id = null,
        .tag = [_]u8{ 'm', 'o', 'o', 'v' },
        .header_offset = 40,
        .payload_offset = 48,
        .size = 30,
        .depth = 0,
    };

    const regions = [_]common.Region{ reg1, reg2 };
    var diagnostics = common.DiagnosticList.init();
    defer {
        for (diagnostics.items.items) |d| {
            allocator.free(d.message);
        }
        diagnostics.deinit(allocator);
    }

    try common.StructuralAuditor.auditRegions(
        allocator,
        &regions,
        70, // file_size
        true, // allow_gaps = true
        &diagnostics,
    );

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.items.len);
    try std.testing.expect(diagnostics.hasRuleId("structural.element_overlap"));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.countBySeverity(.critical));
}

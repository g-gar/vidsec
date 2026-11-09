const std = @import("std");
const abi = @import("flowdata_abi");

const Value_ABI = abi.Value_ABI;
const RowView_ABI = abi.RowView_ABI;
const TaskContext = abi.TaskContext;
const TaskContext_ABI = abi.TaskContext_ABI;
const TaskStatus_ABI = abi.TaskStatus_ABI;
const NamedField_ABI = abi.NamedField_ABI;
const WindowView_ABI = abi.WindowView_ABI;
const HostError_ABI = abi.HostError_ABI;
const LogLevel_ABI = abi.LogLevel_ABI;
const HostApiVTable_ABI = abi.HostApiVTable_ABI;
const ModuleManifest_ABI = abi.ModuleManifest_ABI;
const TaskDescriptor_ABI = abi.TaskDescriptor_ABI;
const FLOWDATA_ABI_VERSION = abi.FLOWDATA_ABI_VERSION;
const defineTask = abi.defineTask;
const defineManifest = abi.defineManifest;

test "C-ABI Value_ABI, RowView_ABI, and TaskContext SDK roundtrip" {
    const MockHost = struct {
        stream_data: []const u8 = "FTYP_ISOBMFF_HEADER",
        window_yielded: bool = false,
        emitted_count: usize = 0,
        last_emitted_entropy: f64 = 0.0,
        last_log_msg: []const u8 = "",
        zeroed_len: u64 = 0,
        truncated_size: u64 = 0,

        fn streamSize(raw_ctx: *TaskContext_ABI) callconv(.c) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            return self.stream_data.len;
        }

        fn streamReadAt(raw_ctx: *TaskContext_ABI, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            const end = std.math.add(u64, offset, len) catch return .out_of_bounds;
            if (end > self.stream_data.len) return .out_of_bounds;
            const start: usize = @intCast(offset);
            @memcpy(dest_ptr[0..len], self.stream_data[start .. start + len]);
            return .ok;
        }

        fn nextWindow(raw_ctx: *TaskContext_ABI, _: ?[*:0]const u8, out_win: *WindowView_ABI) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            if (self.window_yielded) return .end_of_stream;
            self.window_yielded = true;
            const tag = "free";
            out_win.* = .{
                .window_id = 42,
                .file_offset = 5,
                .byte_length = 7,
                .tag_ptr = tag.ptr,
                .tag_len = tag.len,
            };
            return .ok;
        }

        fn windowReadAt(raw_ctx: *TaskContext_ABI, win: *const WindowView_ABI, rel_offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            const end = std.math.add(u64, rel_offset, len) catch return .out_of_bounds;
            if (end > win.byte_length) return .out_of_bounds;
            const abs_offset = win.file_offset + rel_offset;
            const start: usize = @intCast(abs_offset);
            @memcpy(dest_ptr[0..len], self.stream_data[start .. start + len]);
            return .ok;
        }

        fn nextRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }

        fn getParam(_: *TaskContext_ABI, key_ptr: [*:0]const u8, out_val: *Value_ABI) callconv(.c) HostError_ABI {
            const key = std.mem.span(key_ptr);
            if (std.mem.eql(u8, key, "entropy_threshold")) {
                out_val.* = Value_ABI.fromFloat(7.5);
                return .ok;
            }
            return .not_found;
        }

        fn emitRow(raw_ctx: *TaskContext_ABI, channel: ?[*:0]const u8, fields_ptr: [*]const NamedField_ABI, fields_len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.emitted_count += 1;
            if (channel != null) return .invalid_argument;
            if (fields_len != 3) return .invalid_argument;

            for (0..fields_len) |i| {
                const f = fields_ptr[i];
                if (std.mem.eql(u8, f.nameSlice(), "entropy")) {
                    self.last_emitted_entropy = f.value.asFloat() orelse 0.0;
                }
            }
            return .ok;
        }

        fn artifactWriteAt(_: *TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }

        fn artifactZeroRange(raw_ctx: *TaskContext_ABI, _: u64, len: u64) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.zeroed_len = len;
            return .ok;
        }

        fn artifactTruncate(raw_ctx: *TaskContext_ABI, new_size: u64) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            self.truncated_size = new_size;
            return .ok;
        }

        fn carveToQuarantine(_: *TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) HostError_ABI {
            return .ok;
        }

        fn logEvent(raw_ctx: *TaskContext_ABI, level: LogLevel_ABI, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            _ = level;
            self.last_log_msg = msg_ptr[0..msg_len];
        }

        const vtable = HostApiVTable_ABI{
            .stream_size = &streamSize,
            .stream_read_at = &streamReadAt,
            .next_window = &nextWindow,
            .window_read_at = &windowReadAt,
            .next_row = &nextRow,
            .get_param = &getParam,
            .emit_row = &emitRow,
            .artifact_write_at = &artifactWriteAt,
            .artifact_zero_range = &artifactZeroRange,
            .artifact_truncate = &artifactTruncate,
            .carve_to_quarantine = &carveToQuarantine,
            .log_event = &logEvent,
        };
    };

    // Define a plugin task via Zig SDK
    const SamplePlugin = struct {
        fn runEntropy(ctx: TaskContext) !TaskStatus_ABI {
            const threshold = try ctx.getParamFloat("entropy_threshold", 5.0);
            try std.testing.expectApproxEqAbs(@as(f64, 7.5), threshold, 0.001);

            while (try ctx.nextWindow()) |win| {
                try std.testing.expectEqualStrings("free", win.tagSlice());

                var buf: [4]u8 = undefined;
                try ctx.windowReadAt(&win, 0, &buf);
                try std.testing.expectEqualStrings("ISOB", &buf);

                try ctx.emitRow(&.{
                    NamedField_ABI.init("offset", Value_ABI.fromInt(@intCast(win.file_offset))),
                    NamedField_ABI.init("tag", Value_ABI.fromText(win.tagSlice())),
                    NamedField_ABI.init("entropy", Value_ABI.fromFloat(7.85)),
                });

                try ctx.artifactZeroRange(win.file_offset, win.byte_length);
            }

            ctx.logInfo("entropy_scan finished");
            return .ok;
        }

        const tasks = [_]TaskDescriptor_ABI{
            defineTask(.{
                .name = "entropy_scan",
                .description = "Scans byte windows for high Shannon entropy",
                .output_fields = &.{ "offset", "tag", "entropy" },
                .required_params = &.{"entropy_threshold"},
                .run = &runEntropy,
            }),
        };

        const manifest = defineManifest("scanners", .{ .major = 2, .minor = 0, .patch = 0 }, &tasks);
    };

    try std.testing.expectEqualStrings("scanners", SamplePlugin.manifest.nameSlice());
    try std.testing.expectEqual(@as(usize, 1), SamplePlugin.manifest.tasks_len);

    const task_desc = SamplePlugin.manifest.tasks_ptr[0];
    try std.testing.expect(task_desc.declaresOutputField("entropy"));
    try std.testing.expect(!task_desc.declaresOutputField("unknown_field"));

    var host_state = MockHost{};
    var raw_ctx = TaskContext_ABI{
        .opaque_host_state = &host_state,
        .host = &MockHost.vtable,
    };

    const status = task_desc.execute(&raw_ctx);
    try std.testing.expectEqual(TaskStatus_ABI.ok, status);
    try std.testing.expectEqual(@as(usize, 1), host_state.emitted_count);
    try std.testing.expectApproxEqAbs(@as(f64, 7.85), host_state.last_emitted_entropy, 0.001);
    try std.testing.expectEqual(@as(u64, 7), host_state.zeroed_len);
    try std.testing.expectEqualStrings("entropy_scan finished", host_state.last_log_msg);
}

test "BoundedStreamReader, subRegion clamping (R03)" {
    const MockStreamHost = struct {
        // 16-byte buffer: [0..4)=0x00000010 (16 BE), [4..8)="ftyp", [8..12)="isom", [12..16)=0x04030201 (LE)
        bytes: [16]u8 = .{
            0x00, 0x00, 0x00, 0x10,
            'f',  't',  'y',  'p',
            'i',  's',  'o',  'm',
            0x01, 0x02, 0x03, 0x04,
        },

        fn streamSize(raw_ctx: *TaskContext_ABI) callconv(.c) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            return self.bytes.len;
        }

        fn streamReadAt(raw_ctx: *TaskContext_ABI, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) HostError_ABI {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.opaque_host_state));
            const end = std.math.add(u64, offset, len) catch return .out_of_bounds;
            if (end > self.bytes.len) return .out_of_bounds;
            const start: usize = @intCast(offset);
            @memcpy(dest_ptr[0..len], self.bytes[start .. start + len]);
            return .ok;
        }

        fn stubNextWin(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *WindowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }
        fn stubWinRead(_: *TaskContext_ABI, _: *const WindowView_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) HostError_ABI {
            return .out_of_bounds;
        }
        fn stubNextRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }
        fn stubGetParam(_: *TaskContext_ABI, _: [*:0]const u8, _: *Value_ABI) callconv(.c) HostError_ABI {
            return .not_found;
        }
        fn stubEmitRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: [*]const NamedField_ABI, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubWrite(_: *TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubZero(_: *TaskContext_ABI, _: u64, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubTrunc(_: *TaskContext_ABI, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubCarve(_: *TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubLog(_: *TaskContext_ABI, _: LogLevel_ABI, _: [*]const u8, _: usize) callconv(.c) void {}

        const vtable = HostApiVTable_ABI{
            .stream_size = &streamSize,
            .stream_read_at = &streamReadAt,
            .next_window = &stubNextWin,
            .window_read_at = &stubWinRead,
            .next_row = &stubNextRow,
            .get_param = &stubGetParam,
            .emit_row = &stubEmitRow,
            .artifact_write_at = &stubWrite,
            .artifact_zero_range = &stubZero,
            .artifact_truncate = &stubTrunc,
            .carve_to_quarantine = &stubCarve,
            .log_event = &stubLog,
        };
    };

    var host = MockStreamHost{};
    var raw_ctx = TaskContext_ABI{
        .opaque_host_state = &host,
        .host = &MockStreamHost.vtable,
    };
    const ctx = TaskContext.init(&raw_ctx);

    var rdr = ctx.streamReader();
    try std.testing.expectEqual(@as(u64, 16), rdr.len());
    try std.testing.expectEqual(@as(u32, 16), try rdr.readU32Be());
    try std.testing.expectEqualStrings("ftyp", &(try rdr.readFourCC()));

    // Create a strict sub-region [8..16)
    var sub = try rdr.subRegion(8, 16);
    try std.testing.expectEqualStrings("isom", &(try sub.readFourCC()));
    try std.testing.expectEqual(@as(u32, 0x04030201), try sub.readU32Le());
    try std.testing.expect(sub.isEof());
    try std.testing.expectError(error.OutOfBounds, sub.readU8());
    // Sub-region cannot read before its base_offset (e.g. offset 0)
    try std.testing.expectError(error.OutOfBounds, sub.readU32BeAt(0));

    // Test subRegionWithLengthClamped for R03 detection
    const clamped = try rdr.subRegionWithLengthClamped(8, 999);
    try std.testing.expect(clamped.is_truncated_or_overflow);
    try std.testing.expectEqual(@as(u64, 8), clamped.reader.len());
}

test "ABI SDK: injectInputs auto-injects struct fields with defaults and conversions" {
    const TestInputs = struct {
        file_size: u64,
        allow_gaps: bool = false,
        name: []const u8 = "default_name",
        threshold: f64 = 5.5,
        maybe_slack: ?u32 = null,
        stream: abi.BoundedStreamReader,
    };

    const req_params = abi.computeRequiredParams(TestInputs);
    try std.testing.expectEqual(@as(usize, 1), req_params.len);
    try std.testing.expectEqualStrings("file_size", std.mem.span(req_params[0]));

    const MockHost = struct {
        fn streamSize(_: *TaskContext_ABI) callconv(.c) u64 {
            return 2048;
        }
        fn streamReadAt(_: *TaskContext_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubNextWin(_: *TaskContext_ABI, _: ?[*:0]const u8, _: *WindowView_ABI) callconv(.c) HostError_ABI {
            return .not_found;
        }
        fn stubWinRead(_: *TaskContext_ABI, _: *const WindowView_ABI, _: u64, _: [*]u8, _: usize) callconv(.c) HostError_ABI {
            return .not_found;
        }
        fn stubNextRow(_: *TaskContext_ABI, _: [*:0]const u8, _: *RowView_ABI) callconv(.c) HostError_ABI {
            return .end_of_stream;
        }
        fn stubGetParam(_: *TaskContext_ABI, key: [*:0]const u8, out_val: *Value_ABI) callconv(.c) HostError_ABI {
            const k = std.mem.span(key);
            if (std.mem.eql(u8, k, "file_size")) {
                out_val.* = Value_ABI.fromInt(2048);
                return .ok;
            } else if (std.mem.eql(u8, k, "threshold")) {
                out_val.* = Value_ABI.fromFloat(7.8);
                return .ok;
            }
            return .not_found;
        }
        fn stubEmitRow(_: *TaskContext_ABI, _: ?[*:0]const u8, _: [*]const NamedField_ABI, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubWrite(_: *TaskContext_ABI, _: u64, _: [*]const u8, _: usize) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubZero(_: *TaskContext_ABI, _: u64, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubTrunc(_: *TaskContext_ABI, _: u64) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubCarve(_: *TaskContext_ABI, _: u64, _: u64, _: [*:0]const u8, _: *[64]u8) callconv(.c) HostError_ABI {
            return .ok;
        }
        fn stubLog(_: *TaskContext_ABI, _: LogLevel_ABI, _: [*]const u8, _: usize) callconv(.c) void {}

        const vtable = HostApiVTable_ABI{
            .stream_size = &streamSize,
            .stream_read_at = &streamReadAt,
            .next_window = &stubNextWin,
            .window_read_at = &stubWinRead,
            .next_row = &stubNextRow,
            .get_param = &stubGetParam,
            .emit_row = &stubEmitRow,
            .artifact_write_at = &stubWrite,
            .artifact_zero_range = &stubZero,
            .artifact_truncate = &stubTrunc,
            .carve_to_quarantine = &stubCarve,
            .log_event = &stubLog,
        };
    };

    var raw_ctx = TaskContext_ABI{
        .abi_version = FLOWDATA_ABI_VERSION,
        .opaque_host_state = undefined,
        .host = &MockHost.vtable,
    };
    const ctx = TaskContext.init(&raw_ctx);

    const inputs = try abi.injectInputs(TestInputs, ctx);
    try std.testing.expectEqual(@as(u64, 2048), inputs.file_size);
    try std.testing.expectEqual(false, inputs.allow_gaps);
    try std.testing.expectEqualStrings("default_name", inputs.name);
    try std.testing.expectApproxEqAbs(@as(f64, 7.8), inputs.threshold, 0.001);
    try std.testing.expectEqual(@as(?u32, null), inputs.maybe_slack);
    try std.testing.expectEqual(@as(u64, 2048), inputs.stream.len());
}

test "ABI SDK: definePureTask auto-injects Inputs and auto-emits Outputs without TaskContext" {
    const In = struct {
        file_size: u64,
        brand: []const u8 = "isom",
    };
    const Out = struct {
        track_count: u32,
        is_clean: bool,
    };

    const out_fields = abi.computeOutputFields(Out);
    try std.testing.expectEqual(@as(usize, 2), out_fields.len);
    try std.testing.expectEqualStrings("track_count", std.mem.span(out_fields[0]));
    try std.testing.expectEqualStrings("is_clean", std.mem.span(out_fields[1]));

    const MyTask = struct {
        fn run(inputs: In) !Out {
            return .{
                .track_count = @intCast(inputs.file_size / 1000),
                .is_clean = std.mem.eql(u8, inputs.brand, "isom"),
            };
        }
    };

    const desc = abi.definePureTask(In, Out, .{
        .name = "my_pure_task",
        .run = &MyTask.run,
    });
    try std.testing.expectEqualStrings("my_pure_task", desc.nameSlice());
    try std.testing.expectEqual(@as(usize, 1), desc.requiredParams().len);
    try std.testing.expectEqualStrings("file_size", std.mem.span(desc.requiredParams()[0]));
    try std.testing.expectEqual(@as(usize, 2), desc.outputFields().len);
}

// =============================================================================
// MODERN BLACK BOX C-ABI TESTS
// =============================================================================

test "Black Box C-ABI: MemContext_ABI round-trip with testing.allocator" {
    var host_alloc = std.testing.allocator;
    const mem_abi = abi.MemContext_ABI.fromAllocator(&host_alloc);
    const client_alloc = mem_abi.toAllocator();

    const slice = try client_alloc.alloc(u64, 16);
    defer client_alloc.free(slice);

    for (slice, 0..) |*item, idx| {
        item.* = idx * 100;
    }
    try std.testing.expectEqual(@as(u64, 500), slice[5]);
}

test "Black Box C-ABI: PayloadHandle_ABI scalar, slice, and byte view" {
    const Point = struct { x: i32, y: i32 };
    const pt = Point{ .x = 10, .y = 20 };
    const handle_scalar = abi.PayloadHandle_ABI.fromScalar(Point, &pt);

    try std.testing.expect(!handle_scalar.is_stream);
    try std.testing.expectEqual(@as(usize, 1), handle_scalar.len);
    try std.testing.expectEqual(@as(i32, 10), handle_scalar.asScalar(Point).x);

    const pts = [_]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const handle_slice = abi.PayloadHandle_ABI.fromSlice(Point, &pts);

    try std.testing.expect(handle_slice.is_stream);
    try std.testing.expectEqual(@as(usize, 2), handle_slice.len);
    try std.testing.expectEqual(@as(i32, 3), handle_slice.asSlice(Point)[1].x);

    const raw_bytes = "HEADER_SIG";
    const handle_bytes = abi.PayloadHandle_ABI{
        .ptr = raw_bytes.ptr,
        .len = raw_bytes.len,
        .element_size = 1,
        .element_align = 1,
        .is_stream = true,
    };
    try std.testing.expectEqualStrings("HEADER_SIG", handle_bytes.asBytes());
}

test "Black Box C-ABI: defineBlackBoxTask scalar execution with reflection" {
    const In = struct { val: u32 };
    const Out = struct { score: f64, flag: bool };

    const Task = struct {
        fn run(alloc: std.mem.Allocator, in: In) !Out {
            _ = alloc;
            return .{
                .score = @as(f64, @floatFromInt(in.val)) * 2.5,
                .flag = in.val > 5,
            };
        }
    };

    const desc = abi.defineBlackBoxTask(.{
        .name = "score_calc",
        .description = "Calculates score from val",
        .run = Task.run,
    });

    try std.testing.expectEqualStrings("score_calc", desc.nameSlice());
    try std.testing.expectEqualStrings("Calculates score from val", desc.descriptionSlice());
    try std.testing.expectEqual(@as(usize, 2), desc.outputFields().len);
    try std.testing.expect(desc.declaresOutputField("score"));
    try std.testing.expect(desc.declaresOutputField("flag"));
    try std.testing.expect(!desc.declaresOutputField("nonexistent"));

    var host_alloc = std.testing.allocator;
    const mem_abi = abi.MemContext_ABI.fromAllocator(&host_alloc);
    const in_obj = In{ .val = 10 };
    const in_handle = abi.PayloadHandle_ABI.fromScalar(In, &in_obj);

    const res = desc.execute_blackbox.?(&mem_abi, in_handle, .{});
    try std.testing.expectEqual(abi.TaskStatus_ABI.ok, res.status);
    const out_ptr = res.payload.asScalar(Out);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), out_ptr.score, 0.001);
    try std.testing.expect(out_ptr.flag);

    host_alloc.destroy(out_ptr);
}

test "Black Box C-ABI: automatic elemental lifting and expansion flattening" {
    const In = struct { factor: u32 };
    const Out = struct { num: u32 };

    const Elemental = struct {
        fn run(_: std.mem.Allocator, in: In) !Out {
            return .{ .num = in.factor * 10 };
        }
    };

    const Expansion = struct {
        fn run(alloc: std.mem.Allocator, in: In) ![]Out {
            var sub = try alloc.alloc(Out, 2);
            sub[0] = .{ .num = in.factor };
            sub[1] = .{ .num = in.factor * 2 };
            return sub;
        }
    };

    const desc_elem = abi.defineBlackBoxTask(.{ .name = "elem_lift", .run = Elemental.run });
    const desc_exp = abi.defineBlackBoxTask(.{ .name = "exp_lift", .run = Expansion.run });

    var host_alloc = std.testing.allocator;
    const mem_abi = abi.MemContext_ABI.fromAllocator(&host_alloc);

    const in_stream = [_]In{ .{ .factor = 2 }, .{ .factor = 5 }, .{ .factor = 7 } };
    const in_handle = abi.PayloadHandle_ABI.fromSlice(In, &in_stream);

    // Test Elemental Lift (3 -> 3)
    {
        const res = desc_elem.execute_blackbox.?(&mem_abi, in_handle, .{});
        try std.testing.expectEqual(abi.TaskStatus_ABI.ok, res.status);
        const out_slice = res.payload.asSlice(Out);
        try std.testing.expectEqual(@as(usize, 3), out_slice.len);
        try std.testing.expectEqual(@as(u32, 20), out_slice[0].num);
        try std.testing.expectEqual(@as(u32, 50), out_slice[1].num);
        try std.testing.expectEqual(@as(u32, 70), out_slice[2].num);
        host_alloc.free(out_slice);
    }

    // Test Expansion Flattening (3 -> 6)
    {
        const res = desc_exp.execute_blackbox.?(&mem_abi, in_handle, .{});
        try std.testing.expectEqual(abi.TaskStatus_ABI.ok, res.status);
        const out_slice = res.payload.asSlice(Out);
        try std.testing.expectEqual(@as(usize, 6), out_slice.len);
        try std.testing.expectEqual(@as(u32, 2), out_slice[0].num);
        try std.testing.expectEqual(@as(u32, 4), out_slice[1].num);
        try std.testing.expectEqual(@as(u32, 5), out_slice[2].num);
        try std.testing.expectEqual(@as(u32, 10), out_slice[3].num);
        try std.testing.expectEqual(@as(u32, 7), out_slice[4].num);
        try std.testing.expectEqual(@as(u32, 14), out_slice[5].num);
        host_alloc.free(out_slice);
    }
}

test "Black Box C-ABI: error handling and telemetry logger" {
    const Dummy = struct { x: u32 };

    const FailingTask = struct {
        fn run(_: std.mem.Allocator, in: Dummy, logger: abi.AbiLogger) !Dummy {
            logger.info("Starting task");
            if (in.x == 0) {
                logger.err("Zero error detected");
                return error.InvalidZeroInput;
            }
            return in;
        }
    };

    const desc = abi.defineBlackBoxTask(.{
        .name = "failing_task",
        .run = FailingTask.run,
    });

    var host_alloc = std.testing.allocator;
    const mem_abi = abi.MemContext_ABI.fromAllocator(&host_alloc);

    const MockHost = struct {
        var count: usize = 0;
        fn logCallback(level: abi.LogLevel_ABI, msg_ptr: [*]const u8, len: usize) callconv(.c) void {
            _ = level;
            _ = msg_ptr;
            _ = len;
            count += 1;
        }
    };
    MockHost.count = 0;

    const options = abi.ExecutionOptions_ABI{
        .workers = 1,
        .log_fn = &MockHost.logCallback,
    };

    // Test failure path
    const in_zero = Dummy{ .x = 0 };
    const res_fail = desc.execute_blackbox.?(&mem_abi, abi.PayloadHandle_ABI.fromScalar(Dummy, &in_zero), options);
    try std.testing.expectEqual(abi.TaskStatus_ABI.fatal_error, res_fail.status);
    try std.testing.expectEqualStrings("InvalidZeroInput", res_fail.errorMessage().?);
    try std.testing.expect(MockHost.count >= 2); // info + err
}


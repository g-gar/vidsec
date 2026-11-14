const std = @import("std");
const abi = @import("flowdata_abi");
const vidsec = @import("vidsec");

const apply_truncate = vidsec.tasks.apply_truncate;
const apply_zero_out = vidsec.tasks.apply_zero_out;

const SliceStreamHost = struct {
    data: []const u8,
    ctx_abi: abi.TaskContext_ABI = undefined,
    vtable: abi.HostApiVTable_ABI = undefined,

    fn init(data: []const u8) SliceStreamHost {
        var self = SliceStreamHost{ .data = data };
        self.vtable = std.mem.zeroes(abi.HostApiVTable_ABI);
        self.vtable.stream_size = &streamSize;
        self.vtable.stream_read_at = &streamReadAt;
        return self;
    }

    fn reader(self: *SliceStreamHost) abi.BoundedStreamReader {
        self.ctx_abi = .{
            .abi_version = abi.FLOWDATA_ABI_VERSION,
            .host = &self.vtable,
            .opaque_host_state = self,
        };
        return abi.TaskContext.init(&self.ctx_abi).streamReader();
    }

    fn streamSize(raw: *abi.TaskContext_ABI) callconv(.c) u64 {
        const self: *const SliceStreamHost = @ptrCast(@alignCast(raw.opaque_host_state));
        return self.data.len;
    }

    fn streamReadAt(raw: *abi.TaskContext_ABI, offset: u64, dest_ptr: [*]u8, len: usize) callconv(.c) abi.HostError_ABI {
        const self: *const SliceStreamHost = @ptrCast(@alignCast(raw.opaque_host_state));
        if (offset + len > self.data.len) return .end_of_stream;
        @memcpy(dest_ptr[0..len], self.data[@intCast(offset)..][0..len]);
        return .ok;
    }
};

test "apply_truncate emits truncated slice and marks re-verification" {
    const alloc = std.testing.allocator;
    var input: [32]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i);

    var host = SliceStreamHost.init(&input);
    const svc = apply_truncate.Service{};

    const out = try svc.execute(alloc, .{
        .stream = host.reader(),
        .new_size = 20,
        .rule_id = "trailing_overlay",
        .reason = "Appended ZIP overlay",
    });
    defer alloc.free(out.data);

    try std.testing.expectEqualStrings("truncate", out.action);
    try std.testing.expect(out.applied);
    try std.testing.expect(out.requires_reverify);
    try std.testing.expectEqual(@as(usize, 20), out.data.len);
    try std.testing.expectEqualSlices(u8, input[0..20], out.data);
    try std.testing.expectEqual(@as(u64, 12), out.length);
}

test "apply_zero_out clamps range and zeros targeted bytes in emitted slice" {
    const alloc = std.testing.allocator;
    const input: [32]u8 = @splat(0xAA);

    var host = SliceStreamHost.init(&input);
    const svc = apply_zero_out.Service{};

    const out = try svc.execute(alloc, .{
        .stream = host.reader(),
        .offset = 24,
        .length = 20,
        .rule_id = "hidden_padding_payload",
        .reason = "High-entropy free box",
    });
    defer alloc.free(out.data);

    try std.testing.expectEqualStrings("zero_out", out.action);
    try std.testing.expect(out.applied);
    try std.testing.expect(out.requires_reverify);
    try std.testing.expectEqual(@as(u64, 24), out.offset);
    try std.testing.expectEqual(@as(u64, 8), out.length);
    try std.testing.expectEqualSlices(u8, input[0..24], out.data[0..24]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), out.data[24..32]);
}

test "remediation services enforce max_in_memory_bytes guard" {
    const alloc = std.testing.allocator;
    const input: [64]u8 = @splat(0x11);
    var host = SliceStreamHost.init(&input);

    const trunc_svc = apply_truncate.Service{};
    try std.testing.expectError(error.StreamExceedsInMemoryLimit, trunc_svc.execute(alloc, .{
        .stream = host.reader(),
        .new_size = 48,
        .rule_id = "trailing_overlay",
        .max_in_memory_bytes = 32,
    }));

    const zero_svc = apply_zero_out.Service{};
    try std.testing.expectError(error.StreamExceedsInMemoryLimit, zero_svc.execute(alloc, .{
        .stream = host.reader(),
        .offset = 0,
        .length = 16,
        .rule_id = "hidden_padding_payload",
        .max_in_memory_bytes = 32,
    }));
}

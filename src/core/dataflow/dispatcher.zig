const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const PayloadHandle = types.PayloadHandle;
const predicate = @import("predicate.zig");

pub const ChannelSpec = struct {
    name: []const u8,
    from: ?[]const u8 = null,
    datasource: []const u8 = "default",
    schema_ref: ?[]const u8 = null,
    filter: ?[]const u8 = null,
};

pub const DispatchedChannel = struct {
    name: []const u8,
    datasource: []const u8,
    schema_ref: ?[]const u8,
    payload: PayloadHandle,
};

/// Dispatches native stream `stream` across multiple channels according to their `ChannelSpec`.
/// Applies declarative `filter` predicates on native structs without boxing.
pub fn dispatchStream(
    comptime T: type,
    allocator: Allocator,
    stream: []const T,
    channels: []const ChannelSpec,
) Allocator.Error![]const DispatchedChannel {
    const results = try allocator.alloc(DispatchedChannel, channels.len);
    errdefer allocator.free(results);

    for (channels, 0..) |ch, i| {
        var current_stream = stream;

        // Apply declarative filter if specified
        if (ch.filter) |filter_expr| {
            current_stream = try predicate.filterStream(T, allocator, current_stream, filter_expr);
        }

        results[i] = .{
            .name = ch.name,
            .datasource = ch.datasource,
            .schema_ref = ch.schema_ref,
            .payload = PayloadHandle.fromSlice(T, current_stream),
        };
    }

    return results;
}

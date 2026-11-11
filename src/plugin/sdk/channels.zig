const std = @import("std");

/// Marker wrapper type identifying a multi-channel output struct.
pub fn Channels(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("Channels(T) expects a struct type, got " ++ @typeName(T));
    }
    return struct {
        pub const is_flowdata_channels = true;
        pub const ChannelsType = T;
        data: T,
    };
}

/// Helper function to construct a `Channels(T)` value conveniently.
pub fn channels(val: anytype) Channels(@TypeOf(val)) {
    return .{ .data = val };
}

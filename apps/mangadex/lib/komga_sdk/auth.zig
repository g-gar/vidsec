const std = @import("std");
const Allocator = std.mem.Allocator;
const HttpHeader = @import("http.zig").HttpHeader;

pub const KomgaAuth = union(enum) {
    none,
    api_key: []const u8,
    basic_auth: struct {
        username: []const u8,
        password: []const u8,
    },
    session_token: []const u8,

    pub fn applyHeaders(self: KomgaAuth, allocator: Allocator, headers_list: *std.ArrayListUnmanaged(HttpHeader)) !void {
        switch (self) {
            .none => {},
            .api_key => |key| {
                try headers_list.append(allocator, .{
                    .name = "X-API-Key",
                    .value = key,
                });
            },
            .basic_auth => |b| {
                var raw_creds: [512]u8 = undefined;
                const creds = try std.fmt.bufPrint(&raw_creds, "{s}:{s}", .{ b.username, b.password });
                const b64_len = std.base64.standard.Encoder.calcSize(creds.len);
                const b64_buf = try allocator.alloc(u8, b64_len);
                defer allocator.free(b64_buf);
                _ = std.base64.standard.Encoder.encode(b64_buf, creds);

                const auth_val = try std.fmt.allocPrint(allocator, "Basic {s}", .{b64_buf});
                try headers_list.append(allocator, .{
                    .name = "Authorization",
                    .value = auth_val,
                });
            },
            .session_token => |token| {
                try headers_list.append(allocator, .{
                    .name = "X-Auth-Token",
                    .value = token,
                });
            },
        }
    }
};

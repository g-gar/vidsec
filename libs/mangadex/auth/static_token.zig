const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http.zig");
const HttpTransport = http.HttpTransport;
const auth_mod = @import("mod.zig");
const AuthProvider = auth_mod.AuthProvider;
const AuthError = auth_mod.AuthError;

pub const StaticTokenAuth = struct {
    allocator: Allocator,
    header: []const u8,

    comptime {
        AuthProvider.assertImplements(@This());
    }

    pub fn create(allocator: Allocator, raw_token: []const u8) !AuthProvider {
        const self = try allocator.create(StaticTokenAuth);
        errdefer allocator.destroy(self);

        const trimmed = std.mem.trim(u8, raw_token, " \t\r\n");
        const formatted = if (std.mem.startsWith(u8, trimmed, "Bearer "))
            try allocator.dupe(u8, trimmed)
        else
            try std.fmt.allocPrint(allocator, "Bearer {s}", .{trimmed});
        errdefer allocator.free(formatted);

        self.* = .{
            .allocator = allocator,
            .header = formatted,
        };

        return self.authProvider();
    }

    pub fn authProvider(self: *StaticTokenAuth) AuthProvider {
        return .{
            .ptr = self,
            .vtable = &.{
                .getAuthorizationHeader = getAuthHeaderBridge,
                .deinit = deinitBridge,
            },
        };
    }

    fn getAuthHeaderBridge(ctx: *anyopaque, _: HttpTransport, _: u64) AuthError!?[]const u8 {
        const self: *StaticTokenAuth = @ptrCast(@alignCast(ctx));
        return self.header;
    }

    fn deinitBridge(ctx: *anyopaque) void {
        const self: *StaticTokenAuth = @ptrCast(@alignCast(ctx));
        self.allocator.free(self.header);
        self.allocator.destroy(self);
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http.zig");
const HttpTransport = http.HttpTransport;
const auth_mod = @import("mod.zig");
const AuthProvider = auth_mod.AuthProvider;
const AuthError = auth_mod.AuthError;
const personal = @import("personal.zig");
const TokenSession = personal.TokenSession;

/// Public client auth strategy for future PKCE / Device Authorization Grant flows.
pub const PublicClientAuth = struct {
    allocator: Allocator,
    client_id: []const u8,
    session: ?TokenSession = null,
    cached_header: ?[]const u8 = null,

    comptime {
        AuthProvider.assertImplements(@This());
    }

    pub fn create(allocator: Allocator, client_id: []const u8) !AuthProvider {
        const self = try allocator.create(PublicClientAuth);
        errdefer allocator.destroy(self);

        const duped_id = try allocator.dupe(u8, client_id);
        errdefer allocator.free(duped_id);

        self.* = .{
            .allocator = allocator,
            .client_id = duped_id,
            .session = null,
            .cached_header = null,
        };

        return self.authProvider();
    }

    pub fn authProvider(self: *PublicClientAuth) AuthProvider {
        return .{
            .ptr = self,
            .vtable = &.{
                .getAuthorizationHeader = getAuthHeaderBridge,
                .deinit = deinitBridge,
            },
        };
    }

    fn getAuthHeaderBridge(ctx: *anyopaque, _: HttpTransport, _: u64) AuthError!?[]const u8 {
        const self: *PublicClientAuth = @ptrCast(@alignCast(ctx));
        if (self.cached_header) |hdr| return hdr;
        return null;
    }

    fn deinitBridge(ctx: *anyopaque) void {
        const self: *PublicClientAuth = @ptrCast(@alignCast(ctx));
        self.allocator.free(self.client_id);
        if (self.session) |*s| s.deinit(self.allocator);
        if (self.cached_header) |h| self.allocator.free(h);
        self.allocator.destroy(self);
    }
};

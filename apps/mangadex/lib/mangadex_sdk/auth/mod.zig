const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http.zig");
const HttpTransport = http.HttpTransport;

pub const AuthError = error{
    AuthenticationFailed,
    InvalidCredentials,
    TokenRefreshFailed,
    NetworkFailure,
    OutOfMemory,
};

pub const AuthProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns the authorization header value (e.g. "Bearer eyJhbGciOi...")
        /// or `null` if the request should be anonymous.
        /// If the access token is expiring, the implementation must automatically refresh it
        /// using the supplied `transport`.
        getAuthorizationHeader: *const fn (
            ctx: *anyopaque,
            transport: HttpTransport,
            now_ms: u64,
        ) AuthError!?[]const u8,

        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn getAuthorizationHeader(
        self: AuthProvider,
        transport: HttpTransport,
        now_ms: u64,
    ) AuthError!?[]const u8 {
        return self.vtable.getAuthorizationHeader(self.ptr, transport, now_ms);
    }

    pub fn deinit(self: AuthProvider) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "authProvider")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn authProvider(*" ++ @typeName(T) ++ ") AuthProvider'");
            }
        }
    }
};

/// Anonymous authentication strategy that yields no Authorization header.
pub const AnonymousAuth = struct {
    allocator: Allocator,

    comptime {
        AuthProvider.assertImplements(@This());
    }

    pub fn create(allocator: Allocator) !AuthProvider {
        const self = try allocator.create(AnonymousAuth);
        self.* = .{ .allocator = allocator };
        return self.authProvider();
    }

    pub fn authProvider(self: *AnonymousAuth) AuthProvider {
        return .{
            .ptr = self,
            .vtable = &.{
                .getAuthorizationHeader = getAuthHeaderBridge,
                .deinit = deinitBridge,
            },
        };
    }

    fn getAuthHeaderBridge(_: *anyopaque, _: HttpTransport, _: u64) AuthError!?[]const u8 {
        return null;
    }

    fn deinitBridge(ctx: *anyopaque) void {
        const self: *AnonymousAuth = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
    }
};

pub const static_token = @import("static_token.zig");
pub const StaticTokenAuth = static_token.StaticTokenAuth;

pub const personal = @import("personal.zig");
pub const PersonalClientAuth = personal.PersonalClientAuth;
pub const PersonalClientCredentials = personal.PersonalClientCredentials;
pub const TokenSession = personal.TokenSession;

pub const public = @import("public.zig");
pub const PublicClientAuth = public.PublicClientAuth;

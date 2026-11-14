const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http.zig");
const HttpTransport = http.HttpTransport;
const HttpHeader = http.HttpHeader;
const formUrlEncode = http.formUrlEncode;
const auth_mod = @import("mod.zig");
const AuthProvider = auth_mod.AuthProvider;
const AuthError = auth_mod.AuthError;

pub const PersonalClientCredentials = struct {
    auth_url: []const u8 = "https://auth.mangadex.org/realms/mangadex/protocol/openid-connect/token",
    client_id: []const u8,
    client_secret: []const u8,
    username: []const u8,
    password: []const u8,
};

pub const TokenSession = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_at_ms: u64,

    pub fn deinit(self: *TokenSession, allocator: Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        self.* = undefined;
    }
};

const TokenResponsePayload = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: ?u64 = null,
    token_type: ?[]const u8 = null,
};

pub const PersonalClientAuth = struct {
    allocator: Allocator,
    auth_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    username: []const u8,
    password: []const u8,
    session: ?TokenSession = null,
    cached_header: ?[]const u8 = null,

    comptime {
        AuthProvider.assertImplements(@This());
    }

    pub fn create(allocator: Allocator, creds: PersonalClientCredentials) !AuthProvider {
        const self = try allocator.create(PersonalClientAuth);
        errdefer allocator.destroy(self);

        const auth_url = try allocator.dupe(u8, creds.auth_url);
        errdefer allocator.free(auth_url);
        const client_id = try allocator.dupe(u8, creds.client_id);
        errdefer allocator.free(client_id);
        const client_secret = try allocator.dupe(u8, creds.client_secret);
        errdefer allocator.free(client_secret);
        const username = try allocator.dupe(u8, creds.username);
        errdefer allocator.free(username);
        const password = try allocator.dupe(u8, creds.password);
        errdefer allocator.free(password);

        self.* = .{
            .allocator = allocator,
            .auth_url = auth_url,
            .client_id = client_id,
            .client_secret = client_secret,
            .username = username,
            .password = password,
            .session = null,
            .cached_header = null,
        };

        return self.authProvider();
    }

    pub fn authProvider(self: *PersonalClientAuth) AuthProvider {
        return .{
            .ptr = self,
            .vtable = &.{
                .getAuthorizationHeader = getAuthHeaderBridge,
                .deinit = deinitBridge,
            },
        };
    }

    pub fn login(self: *PersonalClientAuth, transport: HttpTransport, now_ms: u64) AuthError!void {
        const body = formUrlEncode(self.allocator, &.{
            .{ "grant_type", "password" },
            .{ "client_id", self.client_id },
            .{ "client_secret", self.client_secret },
            .{ "username", self.username },
            .{ "password", self.password },
        }) catch return error.OutOfMemory;
        defer self.allocator.free(body);

        const headers = [_]HttpHeader{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        };

        const res = transport.execute(
            self.allocator,
            .POST,
            self.auth_url,
            &headers,
            body,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.NetworkFailure,
        };

        if (res.status_code == 400 or res.status_code == 401) {
            return error.InvalidCredentials;
        }
        if (res.status_code != 200) {
            return error.AuthenticationFailed;
        }

        try self.applyTokenResponse(res.body, now_ms);
    }

    pub fn refresh(self: *PersonalClientAuth, transport: HttpTransport, now_ms: u64) AuthError!void {
        const current_refresh = if (self.session) |s| s.refresh_token else return self.login(transport, now_ms);
        if (current_refresh.len == 0) return self.login(transport, now_ms);

        const body = formUrlEncode(self.allocator, &.{
            .{ "grant_type", "refresh_token" },
            .{ "client_id", self.client_id },
            .{ "client_secret", self.client_secret },
            .{ "refresh_token", current_refresh },
        }) catch return error.OutOfMemory;
        defer self.allocator.free(body);

        const headers = [_]HttpHeader{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        };

        const res = transport.execute(
            self.allocator,
            .POST,
            self.auth_url,
            &headers,
            body,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.NetworkFailure,
        };

        if (res.status_code != 200) {
            // If refresh fails, attempt fresh login
            return self.login(transport, now_ms) catch error.TokenRefreshFailed;
        }

        try self.applyTokenResponse(res.body, now_ms);
    }

    fn applyTokenResponse(self: *PersonalClientAuth, json_body: []const u8, now_ms: u64) AuthError!void {
        const parsed = std.json.parseFromSlice(
            TokenResponsePayload,
            self.allocator,
            json_body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.AuthenticationFailed;
        defer parsed.deinit();

        const expires_in = parsed.value.expires_in orelse 900;
        const expires_at_ms = now_ms + (expires_in * 1000);

        const duped_access = self.allocator.dupe(u8, parsed.value.access_token) catch return error.OutOfMemory;
        errdefer self.allocator.free(duped_access);

        const duped_refresh = if (parsed.value.refresh_token) |rf|
            self.allocator.dupe(u8, rf) catch return error.OutOfMemory
        else if (self.session) |s|
            self.allocator.dupe(u8, s.refresh_token) catch return error.OutOfMemory
        else
            self.allocator.dupe(u8, "") catch return error.OutOfMemory;
        errdefer self.allocator.free(duped_refresh);

        const new_header = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{duped_access}) catch return error.OutOfMemory;
        errdefer self.allocator.free(new_header);

        // Free previous session
        if (self.session) |*s| s.deinit(self.allocator);
        if (self.cached_header) |h| self.allocator.free(h);

        self.session = .{
            .access_token = duped_access,
            .refresh_token = duped_refresh,
            .expires_at_ms = expires_at_ms,
        };
        self.cached_header = new_header;
    }

    fn getAuthHeaderBridge(ctx: *anyopaque, transport: HttpTransport, now_ms: u64) AuthError!?[]const u8 {
        const self: *PersonalClientAuth = @ptrCast(@alignCast(ctx));

        if (self.session == null) {
            try self.login(transport, now_ms);
        } else if (now_ms + 60_000 >= self.session.?.expires_at_ms) {
            try self.refresh(transport, now_ms);
        }

        return self.cached_header;
    }

    fn deinitBridge(ctx: *anyopaque) void {
        const self: *PersonalClientAuth = @ptrCast(@alignCast(ctx));
        self.allocator.free(self.auth_url);
        self.allocator.free(self.client_id);
        self.allocator.free(self.client_secret);
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        if (self.session) |*s| s.deinit(self.allocator);
        if (self.cached_header) |h| self.allocator.free(h);
        self.allocator.destroy(self);
    }
};

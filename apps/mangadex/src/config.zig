const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const EnvInterpolator = flowdata.yaml.EnvInterpolator;
const sdk = @import("mangadex_sdk");
const komga_sdk = @import("komga_sdk");

pub const AppConfig = struct {
    api_url: []const u8 = "https://api.mangadex.org",
    auth_url: []const u8 = "https://auth.mangadex.org/realms/mangadex/protocol/openid-connect/token",
    user_agent: []const u8 = "FlowdataMangaDex/1.0.0 (https://github.com/flowdata)",

    // Komga integration settings
    komga_url: []const u8 = "http://localhost:25600",
    komga_api_key: ?[]const u8 = null,
    komga_username: ?[]const u8 = null,
    komga_password: ?[]const u8 = null,
    komga_library_id: ?[]const u8 = null,

    /// Loads configuration by resolving environment variables and/or parsing an optional `.env` file.
    pub fn load(allocator: Allocator, dot_env_path: ?[]const u8) !AppConfig {
        var interp = EnvInterpolator.init(true);
        defer interp.deinit(allocator);

        if (dot_env_path) |path| {
            if (readDotEnvFile(allocator, path)) |content| {
                defer allocator.free(content);
                interp.parseDotEnv(allocator, content) catch {};
            }
        }

        var cfg = AppConfig{};

        if (interp.get("MANGADEX_API_URL")) |url| {
            cfg.api_url = try allocator.dupe(u8, url);
        }
        if (interp.get("MANGADEX_AUTH_URL")) |url| {
            cfg.auth_url = try allocator.dupe(u8, url);
        }
        if (interp.get("MANGADEX_USER_AGENT")) |ua| {
            cfg.user_agent = try allocator.dupe(u8, ua);
        }

        if (interp.get("KOMGA_URL") orelse interp.get("KOMGA_BASE_URL")) |url| {
            cfg.komga_url = try allocator.dupe(u8, url);
        }
        if (interp.get("KOMGA_API_KEY")) |k| {
            cfg.komga_api_key = try allocator.dupe(u8, k);
        }
        if (interp.get("KOMGA_USERNAME")) |u| {
            cfg.komga_username = try allocator.dupe(u8, u);
        }
        if (interp.get("KOMGA_PASSWORD")) |p| {
            cfg.komga_password = try allocator.dupe(u8, p);
        }
        if (interp.get("KOMGA_LIBRARY_ID")) |l| {
            cfg.komga_library_id = try allocator.dupe(u8, l);
        }

        return cfg;
    }

    pub fn readDotEnvFile(allocator: Allocator, path: []const u8) ?[]const u8 {
        const null_path = allocator.dupeZ(u8, path) catch return null;
        defer allocator.free(null_path);

        const fd = std.c.open(null_path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return null;
        defer _ = std.c.close(fd);

        const size_long = std.c.lseek(fd, 0, 2);
        if (size_long <= 0) return null;
        _ = std.c.lseek(fd, 0, 0);

        const size: usize = @intCast(@min(size_long, 64 * 1024));
        const buf = allocator.alloc(u8, size) catch return null;
        errdefer allocator.free(buf);

        const n = std.c.read(fd, buf.ptr, size);
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    }

    /// Builds the appropriate `AuthProvider` based on present variables:
    /// 1. If MANGADEX_ACCESS_TOKEN / MANGADEX_TOKEN is set -> StaticTokenAuth
    /// 2. If Personal Client credentials are set -> PersonalClientAuth
    /// 3. Otherwise -> null (anonymous mode for public browsing)
    pub fn resolveAuthProvider(self: AppConfig, allocator: Allocator, interp: *const EnvInterpolator) !?sdk.AuthProvider {
        if (interp.get("MANGADEX_ACCESS_TOKEN") orelse interp.get("MANGADEX_TOKEN")) |token| {
            if (token.len > 0) {
                return try sdk.StaticTokenAuth.create(allocator, token);
            }
        }

        const client_id = interp.get("MANGADEX_CLIENT_ID");
        const client_secret = interp.get("MANGADEX_CLIENT_SECRET");
        const username = interp.get("MANGADEX_USERNAME");
        const password = interp.get("MANGADEX_PASSWORD");

        if (client_id != null and client_secret != null and username != null and password != null) {
            if (client_id.?.len > 0 and client_secret.?.len > 0 and username.?.len > 0 and password.?.len > 0) {
                return try sdk.PersonalClientAuth.create(allocator, .{
                    .auth_url = self.auth_url,
                    .client_id = client_id.?,
                    .client_secret = client_secret.?,
                    .username = username.?,
                    .password = password.?,
                });
            }
        }

        return null;
    }

    /// Resolves KomgaAuth strategy from loaded configuration:
    /// 1. If `komga_api_key` is set -> api_key
    /// 2. If `komga_username` and `komga_password` are set -> basic_auth
    /// 3. Otherwise -> none
    pub fn resolveKomgaAuth(self: AppConfig) komga_sdk.KomgaAuth {
        if (self.komga_api_key) |k| {
            if (k.len > 0) return .{ .api_key = k };
        }
        if (self.komga_username) |u| {
            if (self.komga_password) |p| {
                if (u.len > 0 and p.len > 0) {
                    return .{ .basic_auth = .{ .username = u, .password = p } };
                }
            }
        }
        return .none;
    }
};

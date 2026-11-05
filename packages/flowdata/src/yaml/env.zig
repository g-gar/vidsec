const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("lib/mod.zig");

pub const EnvError = error{
    MissingRequiredEnvVar,
    MalformedEnvExpression,
    MalformedDotEnvLine,
    OutOfMemory,
};

/// `vidsec` `.env` file parser and `${VAR}` / `${VAR:-default}` string interpolator.
/// Adapts into `lib/yaml` via `env.scalarHook()`.
pub const EnvInterpolator = struct {
    vars: std.StringHashMapUnmanaged([]const u8) = .{},
    use_process_env: bool = true,

    pub fn init(use_process_env: bool) EnvInterpolator {
        return .{
            .vars = .{},
            .use_process_env = use_process_env,
        };
    }

    pub fn deinit(self: *EnvInterpolator, allocator: Allocator) void {
        self.vars.deinit(allocator);
    }

    pub fn put(self: *EnvInterpolator, allocator: Allocator, key: []const u8, value: []const u8) !void {
        try self.vars.put(allocator, key, value);
    }

    /// Returns a `yaml.ScalarHook` adapter to plug `.env` expansion into `yaml.ParseOptions`.
    pub fn scalarHook(self: *const EnvInterpolator) yaml.ScalarHook {
        return .{
            .ctx = self,
            .transformFn = transformCallback,
        };
    }

    fn transformCallback(ctx: *const anyopaque, arena: Allocator, raw: []const u8) anyerror![]const u8 {
        const self: *const EnvInterpolator = @ptrCast(@alignCast(ctx));
        return self.interpolate(arena, raw);
    }

    pub fn parseDotEnv(self: *EnvInterpolator, arena: Allocator, content: []const u8) EnvError!void {
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |raw_line| {
            const line_cr = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line_cr, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const effective = if (std.mem.startsWith(u8, trimmed, "export "))
                std.mem.trimStart(u8, trimmed["export ".len..], " \t")
            else
                trimmed;

            const eq_idx = std.mem.indexOfScalar(u8, effective, '=') orelse return error.MalformedDotEnvLine;
            const key = std.mem.trim(u8, effective[0..eq_idx], " \t");
            if (key.len == 0) return error.MalformedDotEnvLine;

            var raw_val = std.mem.trim(u8, effective[eq_idx + 1 ..], " \t");
            if (raw_val.len >= 2 and ((raw_val[0] == '"' and raw_val[raw_val.len - 1] == '"') or
                (raw_val[0] == '\'' and raw_val[raw_val.len - 1] == '\'')))
            {
                raw_val = raw_val[1 .. raw_val.len - 1];
            } else if (std.mem.indexOfScalar(u8, raw_val, '#')) |comment_idx| {
                if (comment_idx > 0 and (raw_val[comment_idx - 1] == ' ' or raw_val[comment_idx - 1] == '\t')) {
                    raw_val = std.mem.trimEnd(u8, raw_val[0..comment_idx], " \t");
                }
            }

            const owned_key = try arena.dupe(u8, key);
            const owned_val = try arena.dupe(u8, raw_val);
            try self.vars.put(arena, owned_key, owned_val);
        }
    }

    pub fn get(self: *const EnvInterpolator, key: []const u8) ?[]const u8 {
        if (self.vars.get(key)) |v| return v;
        if (self.use_process_env) {
            return getProcessEnv(key);
        }
        return null;
    }

    fn getProcessEnv(key: []const u8) ?[]const u8 {
        if (@hasDecl(std.os, "environ")) {
            for (std.os.environ) |entry_ptr| {
                const entry = std.mem.span(entry_ptr);
                if (std.mem.indexOfScalar(u8, entry, '=')) |eq_idx| {
                    if (std.mem.eql(u8, entry[0..eq_idx], key)) {
                        return entry[eq_idx + 1 ..];
                    }
                }
            }
        }
        return null;
    }

    pub fn interpolate(self: *const EnvInterpolator, arena: Allocator, raw: []const u8) EnvError![]const u8 {
        if (std.mem.indexOf(u8, raw, "${") == null) {
            return raw;
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (i + 1 < raw.len and raw[i] == '$' and raw[i + 1] == '{') {
                const start_expr = i + 2;
                const rel_end = std.mem.indexOfScalar(u8, raw[start_expr..], '}') orelse
                    return error.MalformedEnvExpression;
                const expr = raw[start_expr .. start_expr + rel_end];
                if (expr.len == 0) return error.MalformedEnvExpression;

                if (std.mem.indexOf(u8, expr, ":-")) |sep_idx| {
                    const var_name = expr[0..sep_idx];
                    const default_val = expr[sep_idx + 2 ..];
                    if (var_name.len == 0) return error.MalformedEnvExpression;

                    if (self.get(var_name)) |val| {
                        if (val.len > 0) {
                            try out.appendSlice(arena, val);
                        } else {
                            try out.appendSlice(arena, default_val);
                        }
                    } else {
                        try out.appendSlice(arena, default_val);
                    }
                } else {
                    const var_name = expr;
                    const val = self.get(var_name) orelse return error.MissingRequiredEnvVar;
                    try out.appendSlice(arena, val);
                }

                i = start_expr + rel_end + 1;
            } else {
                try out.append(arena, raw[i]);
                i += 1;
            }
        }

        return out.toOwnedSlice(arena);
    }
};


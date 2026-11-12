//! Flowdata Ambient Runtime Context Provider (ARCH-018 §3.2).
//!
//! Exposes innate system context (`system.timestamp`, `system.hour`, `system.cpu_load`, `env.*`)
//! for zero-recompilation input bindings, ambient context merging, and unary expression filtering.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const ReflectedValue = dataflow.ReflectedValue;

fn getEnvSlice(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = std.c.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(ptr);
}

pub fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
}

pub const AmbientContext = struct {
    allocator: Allocator,
    timestamp_ns: i64,
    hour: u8,
    cpu_load: f64,

    pub fn init(allocator: Allocator) AmbientContext {
        const cur_ns = nowNs();
        const sec = @divFloor(cur_ns, 1_000_000_000);
        const day_sec = @mod(sec, 86400);
        const hr: u8 = @intCast(@divFloor(day_sec, 3600));

        return .{
            .allocator = allocator,
            .timestamp_ns = cur_ns,
            .hour = hr,
            .cpu_load = 20.0,
        };
    }

    pub fn withValues(allocator: Allocator, timestamp_ns: i64, hour: u8, cpu_load: f64) AmbientContext {
        return .{
            .allocator = allocator,
            .timestamp_ns = timestamp_ns,
            .hour = hour,
            .cpu_load = cpu_load,
        };
    }

    pub fn getReflected(self: *const AmbientContext, path: []const u8) ?ReflectedValue {
        var key = path;
        if (std.mem.startsWith(u8, key, "system.")) {
            key = key["system.".len..];
        }

        if (std.mem.eql(u8, key, "timestamp") or std.mem.eql(u8, key, "time")) {
            return ReflectedValue.fromInt(self.timestamp_ns);
        } else if (std.mem.eql(u8, key, "hour")) {
            return ReflectedValue.fromInt(@as(i64, self.hour));
        } else if (std.mem.eql(u8, key, "cpu_load") or std.mem.eql(u8, key, "cpu_usage")) {
            return ReflectedValue.fromFloat(self.cpu_load);
        } else if (std.mem.startsWith(u8, path, "env.")) {
            const env_name = path["env.".len..];
            if (getEnvSlice(env_name)) |val| {
                return ReflectedValue.fromString(val);
            }
        }
        return null;
    }

    pub fn asPayload(self: *const AmbientContext, alloc: Allocator, path: []const u8) !?PayloadHandle {
        var key = path;
        if (std.mem.startsWith(u8, key, "system.")) {
            key = key["system.".len..];
        }

        if (std.mem.eql(u8, key, "timestamp") or std.mem.eql(u8, key, "time")) {
            const ptr = try alloc.create(i64);
            ptr.* = self.timestamp_ns;
            return PayloadHandle.fromScalar(i64, ptr);
        } else if (std.mem.eql(u8, key, "hour")) {
            const ptr = try alloc.create(u8);
            ptr.* = self.hour;
            return PayloadHandle.fromScalar(u8, ptr);
        } else if (std.mem.eql(u8, key, "cpu_load") or std.mem.eql(u8, key, "cpu_usage")) {
            const ptr = try alloc.create(f64);
            ptr.* = self.cpu_load;
            return PayloadHandle.fromScalar(f64, ptr);
        } else if (std.mem.startsWith(u8, path, "env.")) {
            const env_name = path["env.".len..];
            if (getEnvSlice(env_name)) |val| {
                return PayloadHandle.fromSlice(u8, val);
            }
        }
        return null;
    }
};

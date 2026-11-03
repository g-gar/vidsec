const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../../lib/yaml/mod.zig");
const sqlite_core = @import("../../sqlite/mod.zig");
const Value = sqlite_core.Value;
const field_router = @import("../field_router/mod.zig");
const FieldTransform = field_router.FieldTransform;
const FieldCast = field_router.FieldCast;

/// Declarative specification for a single input binding on a task step.
/// Binds a target task parameter/channel to an external path (`<source>.<field>`)
/// with optional transformations, casting, and fallback defaults.
pub const InputBinding = struct {
    from_path: []const u8,
    transform: FieldTransform = .none,
    round_decimals: ?u8 = null,
    cast: FieldCast = .none,
    default_val: ?Value = null,

    pub fn yamlParse(arena: Allocator, node: yaml.Node, _: yaml.ParseOptions) anyerror!InputBinding {
        // 1. Shorthand syntax: scalar string "parse_container.file_size"
        if (node.asScalar()) |scalar_str| {
            return InputBinding{
                .from_path = try arena.dupe(u8, scalar_str),
            };
        }

        // 2. Expanded syntax: map with from, transform, cast, default
        const raw_entries = node.asMap() orelse return error.TypeMismatch;
        var from_path: ?[]const u8 = null;
        var transform: FieldTransform = .none;
        var round_decimals: ?u8 = null;
        var cast: FieldCast = .none;
        var default_val: ?Value = null;

        for (raw_entries) |entry| {
            if (std.mem.eql(u8, entry.key, "from")) {
                const s = entry.value.asScalar() orelse return error.TypeMismatch;
                from_path = try arena.dupe(u8, s);
            } else if (std.mem.eql(u8, entry.key, "transform")) {
                const s = entry.value.asScalar() orelse return error.TypeMismatch;
                if (std.mem.startsWith(u8, s, "round_decimals")) {
                    transform = .round;
                    // parse round_decimals(N)
                    if (std.mem.indexOf(u8, s, "(")) |open_idx| {
                        if (std.mem.indexOf(u8, s, ")")) |close_idx| {
                            const num_str = std.mem.trim(u8, s[open_idx + 1 .. close_idx], " ");
                            round_decimals = std.fmt.parseInt(u8, num_str, 10) catch 0;
                        }
                    }
                } else {
                    transform = FieldTransform.parse(s);
                }
            } else if (std.mem.eql(u8, entry.key, "cast")) {
                const s = entry.value.asScalar() orelse return error.TypeMismatch;
                cast = FieldCast.parse(s);
            } else if (std.mem.eql(u8, entry.key, "default")) {
                if (entry.value.asScalar()) |s| {
                    if (std.fmt.parseInt(i64, s, 10) catch null) |i| {
                        default_val = Value{ .int64 = i };
                    } else if (std.fmt.parseFloat(f64, s) catch null) |f| {
                        default_val = Value{ .float64 = f };
                    } else if (std.mem.eql(u8, s, "true")) {
                        default_val = Value{ .boolean = true };
                    } else if (std.mem.eql(u8, s, "false")) {
                        default_val = Value{ .boolean = false };
                    } else {
                        default_val = Value{ .text = try arena.dupe(u8, s) };
                    }
                }
            }
        }

        const valid_path = from_path orelse return error.TypeMismatch;
        return InputBinding{
            .from_path = valid_path,
            .transform = transform,
            .round_decimals = round_decimals,
            .cast = cast,
            .default_val = default_val,
        };
    }
};

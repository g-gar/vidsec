const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RouterSpecError = error{
    MissingRouterName,
    MissingCaseWhen,
    MissingCaseGoto,
};

pub const RouterCase = struct {
    when_sql: []const u8,
    goto_pipeline: []const u8,

    pub const yaml_fields = .{
        .when_sql = "when",
        .goto_pipeline = "goto",
    };

    pub fn yamlValidate(self: *const RouterCase, _: Allocator) RouterSpecError!void {
        if (self.when_sql.len == 0) return error.MissingCaseWhen;
        if (self.goto_pipeline.len == 0) return error.MissingCaseGoto;
    }
};

/// Decoded conditional router step (`- router: <name>`).
pub const RouterStep = struct {
    name: []const u8,
    cases: []const RouterCase,
    /// Target sub-pipeline when no `when` clause matches (`null` if omitted or `"exit"`).
    default_pipeline: ?[]const u8 = null,

    pub const yaml_fields = .{
        .name = "router",
        .default_pipeline = "default",
    };

    pub fn yamlValidate(self: *RouterStep, _: Allocator) RouterSpecError!void {
        if (self.name.len == 0) return error.MissingRouterName;
        if (self.default_pipeline) |def_str| {
            if (def_str.len == 0 or std.mem.eql(u8, def_str, "exit")) {
                self.default_pipeline = null;
            }
        }
    }
};

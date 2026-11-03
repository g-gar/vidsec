const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../../../lib/yaml/mod.zig");
const input_spec = @import("input_spec.zig");
const output_spec = @import("output_spec.zig");
const router_spec = @import("router_spec.zig");
const input_binding_mod = @import("../../pipeline/binding/input_binding.zig");

pub const InputSpec = input_spec.InputSpec;
pub const OutputSpec = output_spec.OutputSpec;
pub const RouterStep = router_spec.RouterStep;
pub const InputBinding = input_binding_mod.InputBinding;

pub const StepLoadError = error{
    MissingMainPipeline,
    EmptyStepsSeq,
    AmbiguousStepKind,
    UnknownStepKind,
    MissingTaskName,
    InvalidTaskUseSpec,
    MissingSqlRuleQuery,
    UnexpectedQueryInPluginTask,
    SqlRuleRequiresOutputInto,
    DuplicateStepNameInPipeline,
    UnknownTargetSubPipeline,
    CyclicRouterGraph,
    OutOfMemory,
} || input_spec.InputSpecError || output_spec.OutputSpecError || router_spec.RouterSpecError;

/// Custom scalar type for `use: sql_rule | <module_name> | <module_name>/<task_name>`.
pub const TaskTarget = union(enum) {
    sql_rule,
    module_default: []const u8,
    module_task: struct {
        module: []const u8,
        task: []const u8,
    },

    pub fn yamlParseScalar(
        arena: Allocator,
        scalar: yaml.Scalar,
        _: yaml.SourceLoc,
    ) StepLoadError!TaskTarget {
        const raw = scalar.value;
        if (raw.len == 0) return error.InvalidTaskUseSpec;
        if (std.mem.eql(u8, raw, "sql_rule")) return .sql_rule;

        if (std.mem.indexOfScalar(u8, raw, '/')) |slash_idx| {
            const mod_name = raw[0..slash_idx];
            const task_name = raw[slash_idx + 1 ..];
            if (mod_name.len == 0 or task_name.len == 0 or std.mem.indexOfScalar(u8, task_name, '/') != null) {
                return error.InvalidTaskUseSpec;
            }
            return .{
                .module_task = .{
                    .module = try arena.dupe(u8, mod_name),
                    .task = try arena.dupe(u8, task_name),
                },
            };
        }

        return .{ .module_default = try arena.dupe(u8, raw) };
    }

    pub fn moduleName(self: TaskTarget) ?[]const u8 {
        return switch (self) {
            .sql_rule => null,
            .module_default => |m| m,
            .module_task => |mt| mt.module,
        };
    }
};

/// Custom scalar type for `params:` values (infers `boolean`, `int64`, `float64`, or `text`).
pub const ParamValue = union(enum) {
    int64: i64,
    float64: f64,
    boolean: bool,
    text: []const u8,

    pub fn yamlParseScalar(
        arena: Allocator,
        scalar: yaml.Scalar,
        _: yaml.SourceLoc,
    ) !ParamValue {
        if (scalar.quote_style != .plain) {
            return .{ .text = try arena.dupe(u8, scalar.value) };
        }

        const raw = scalar.value;
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };

        if (std.fmt.parseInt(i64, raw, 10)) |int_val| {
            return .{ .int64 = int_val };
        } else |_| {}

        if (std.mem.indexOfScalar(u8, raw, '.') != null) {
            if (std.fmt.parseFloat(f64, raw)) |float_val| {
                return .{ .float64 = float_val };
            } else |_| {}
        }

        return .{ .text = try arena.dupe(u8, raw) };
    }
};

/// Decoded task step (`- task: <name>`), automatically deserialized via `yaml_fields` and `yamlValidate`.
pub const TaskStep = struct {
    name: []const u8,
    target: TaskTarget,
    query: ?[]const u8 = null,
    input: ?InputSpec = null,
    inputs: ?yaml.Map(InputBinding) = null,
    params: yaml.Map(ParamValue) = .{},
    output: ?OutputSpec = null,

    pub fn yamlParse(
        arena: Allocator,
        node: yaml.Node,
        options: yaml.ParseOptions,
    ) anyerror!TaskStep {
        _ = node.asMap() orelse return error.TypeMismatch;

        // 1. Resolve step name: from "task" or "id"
        const name_node = node.get("task") orelse node.get("id") orelse return error.MissingTaskName;
        const name_str = name_node.asScalar() orelse return error.MissingTaskName;

        // 2. Resolve step target: from "use" or "uses"
        const use_node = node.get("use") orelse node.get("uses") orelse return error.InvalidTaskUseSpec;
        const use_scalar = use_node.asScalar() orelse return error.InvalidTaskUseSpec;
        const target = try TaskTarget.yamlParseScalar(arena, .{ .value = use_scalar, .quote_style = .plain }, .{ .line = 0, .column = 0 });

        // 3. Resolve query
        var query: ?[]const u8 = null;
        if (node.get("query")) |q_node| {
            if (q_node.asScalar()) |q_str| query = try arena.dupe(u8, q_str);
        }

        // 4. Resolve input
        var input: ?InputSpec = null;
        if (node.get("input")) |in_node| {
            input = try yaml.parseFromNode(InputSpec, arena, in_node, options);
        }

        // 5. Resolve inputs
        var inputs: ?yaml.Map(InputBinding) = null;
        if (node.get("inputs")) |ins_node| {
            inputs = try yaml.parseFromNode(yaml.Map(InputBinding), arena, ins_node, options);
        }

        // 6. Resolve params
        var params: yaml.Map(ParamValue) = .{};
        if (node.get("params")) |p_node| {
            params = try yaml.parseFromNode(yaml.Map(ParamValue), arena, p_node, options);
        }

        // 7. Resolve output / persist
        var output: ?OutputSpec = null;
        if (node.get("output")) |out_node| {
            output = try yaml.parseFromNode(OutputSpec, arena, out_node, options);
        } else if (node.get("persist")) |p_node| {
            if (output_spec.extractPersistTable(arena, p_node)) |tbl| {
                output = OutputSpec{
                    .into = tbl,
                };
            }
        }

        var step = TaskStep{
            .name = try arena.dupe(u8, name_str),
            .target = target,
            .query = query,
            .input = input,
            .inputs = inputs,
            .params = params,
            .output = output,
        };
        try step.yamlValidate(arena);
        return step;
    }

    pub fn getParam(self: *const TaskStep, key: []const u8) ?ParamValue {
        return self.params.get(key);
    }

    pub fn getInputBinding(self: *const TaskStep, key: []const u8) ?InputBinding {
        if (self.inputs) |m| {
            return m.get(key);
        }
        return null;
    }

    pub fn yamlValidate(self: *TaskStep, arena: Allocator) StepLoadError!void {
        if (self.name.len == 0) return error.MissingTaskName;

        if (self.query) |q_raw| {
            const trimmed = std.mem.trim(u8, q_raw, " \t\r\n");
            if (trimmed.len == 0) return error.MissingSqlRuleQuery;
            self.query = try arena.dupe(u8, trimmed);
        }

        if (self.target == .sql_rule) {
            if (self.query == null) return error.MissingSqlRuleQuery;
            const out = self.output orelse return error.SqlRuleRequiresOutputInto;
            if (out.into == null) return error.SqlRuleRequiresOutputInto;
        } else {
            if (self.query != null) return error.UnexpectedQueryInPluginTask;
        }
    }
};

/// Discriminated union for a pipeline step (`task` vs `router`).
pub const Step = union(enum) {
    task: TaskStep,
    router: RouterStep,

    pub fn name(self: Step) []const u8 {
        return switch (self) {
            .task => |t| t.name,
            .router => |r| r.name,
        };
    }

    pub fn yamlParse(
        arena: Allocator,
        node: yaml.Node,
        options: yaml.ParseOptions,
    ) anyerror!Step {
        _ = node.asMap() orelse return error.TypeMismatch;
        const has_task = node.get("task") != null or node.get("id") != null;
        const has_router = node.get("router") != null;

        if (has_task and has_router) return error.AmbiguousStepKind;
        if (!has_task and !has_router) return error.UnknownStepKind;

        if (has_router) {
            return .{ .router = try yaml.parseFromNode(RouterStep, arena, node, options) };
        } else {
            return .{ .task = try yaml.parseFromNode(TaskStep, arena, node, options) };
        }
    }
};

pub const SubPipeline = struct {
    steps: []const Step,

    pub fn yamlValidate(self: *const SubPipeline, _: Allocator) StepLoadError!void {
        if (self.steps.len == 0) return;
        for (self.steps, 0..) |s, i| {
            for (self.steps[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name(), s.name())) {
                    return error.DuplicateStepNameInPipeline;
                }
            }
        }
    }
};

pub const SubPipelineMap = yaml.Map(SubPipeline);

const VisitColor = enum { unvisited, visiting, visited };

/// Verifies that `main` exists, all router `goto` and `default` targets exist in `pipelines`,
/// and the directed transition graph has no cycles (DFS 3-color check).
pub fn validateRouterAcyclicGraph(arena: Allocator, pipelines: *const SubPipelineMap) StepLoadError!void {
    if (!pipelines.contains("main")) return error.MissingMainPipeline;

    var colors: std.StringHashMapUnmanaged(VisitColor) = .{};
    for (pipelines.entries) |entry| {
        try colors.put(arena, entry.key, .unvisited);
    }

    for (pipelines.entries) |entry| {
        if (colors.get(entry.key).? == .unvisited) {
            try dfsValidateSubPipeline(arena, pipelines, &colors, entry.key);
        }
    }
}

fn dfsValidateSubPipeline(
    arena: Allocator,
    pipelines: *const SubPipelineMap,
    colors: *std.StringHashMapUnmanaged(VisitColor),
    current_name: []const u8,
) StepLoadError!void {
    try colors.put(arena, current_name, .visiting);

    const sub = pipelines.get(current_name) orelse return error.UnknownTargetSubPipeline;
    for (sub.steps) |step| {
        switch (step) {
            .task => {},
            .router => |r| {
                for (r.cases) |c| {
                    try visitTargetEdge(arena, pipelines, colors, c.goto_pipeline);
                }
                if (r.default_pipeline) |def_target| {
                    try visitTargetEdge(arena, pipelines, colors, def_target);
                }
            },
        }
    }

    try colors.put(arena, current_name, .visited);
}

fn visitTargetEdge(
    arena: Allocator,
    pipelines: *const SubPipelineMap,
    colors: *std.StringHashMapUnmanaged(VisitColor),
    target_name: []const u8,
) StepLoadError!void {
    const color = colors.get(target_name) orelse return error.UnknownTargetSubPipeline;
    switch (color) {
        .visiting => return error.CyclicRouterGraph,
        .visited => return,
        .unvisited => try dfsValidateSubPipeline(arena, pipelines, colors, target_name),
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml_lib = @import("lib/mod.zig");
const ast = @import("../ast/ast.zig");
const env = @import("env.zig");

pub const PipelineAST = ast.PipelineAST;
pub const PipelineBuilder = ast.PipelineBuilder;
pub const DatasourceSpec = ast.DatasourceSpec;
pub const KeyValueParam = ast.KeyValueParam;
pub const TaskStepSpec = ast.TaskStepSpec;
pub const RouterStepSpec = ast.RouterStepSpec;
pub const RouterCaseSpec = ast.RouterCaseSpec;
pub const InputBindingSpec = ast.InputBindingSpec;
pub const InboundStreamExpr = ast.InboundStreamExpr;
pub const ChannelOutputSpec = ast.ChannelOutputSpec;
pub const StepNode = ast.StepNode;

pub const YamlAstLoaderError = error{
    InvalidYamlStructure,
    MissingPipelinesSection,
    MissingStepIdentifier,
    InvalidConcurrencyValue,
} || ast.ValidationError || yaml_lib.YamlAstError || Allocator.Error;

pub const AstLoadOptions = struct {
    env_interpolator: ?*const env.EnvInterpolator = null,
};

/// Parses raw stream expression strings such as:
/// - "stream"
/// - "lower_mp4.regions"
/// - "merge(stream_a, stream_b)"
/// - "zip(a, b)"
/// - "join(left, right, on: key)"
pub fn parseInboundStreamExpr(alloc: Allocator, raw: []const u8) !InboundStreamExpr {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "merge(") and std.mem.endsWith(u8, trimmed, ")")) {
        const inner = trimmed[6 .. trimmed.len - 1];
        var list: std.ArrayListUnmanaged(InboundStreamExpr) = .empty;
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            const part_trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (part_trimmed.len > 0) {
                try list.append(alloc, InboundStreamExpr.direct(part_trimmed));
            }
        }
        return .{
            .op = .merge,
            .sub_streams = try list.toOwnedSlice(alloc),
        };
    } else if (std.mem.startsWith(u8, trimmed, "zip(") and std.mem.endsWith(u8, trimmed, ")")) {
        const inner = trimmed[4 .. trimmed.len - 1];
        var list: std.ArrayListUnmanaged(InboundStreamExpr) = .empty;
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            const part_trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (part_trimmed.len > 0) {
                try list.append(alloc, InboundStreamExpr.direct(part_trimmed));
            }
        }
        return .{
            .op = .zip,
            .sub_streams = try list.toOwnedSlice(alloc),
        };
    } else if (std.mem.startsWith(u8, trimmed, "join(") and std.mem.endsWith(u8, trimmed, ")")) {
        const inner = trimmed[5 .. trimmed.len - 1];
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            const part_trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (part_trimmed.len > 0) {
                try list.append(alloc, part_trimmed);
            }
        }
        const parts = list.items;
        if (parts.len >= 2) {
            var key: ?[]const u8 = null;
            if (parts.len >= 3) {
                const k_trimmed = parts[2];
                if (std.mem.startsWith(u8, k_trimmed, "on:")) {
                    key = std.mem.trim(u8, k_trimmed[3..], " \t\r\n");
                } else {
                    key = k_trimmed;
                }
            }
            const sub = try alloc.alloc(InboundStreamExpr, 2);
            sub[0] = InboundStreamExpr.direct(parts[0]);
            sub[1] = InboundStreamExpr.direct(parts[1]);
            return .{
                .op = .join,
                .sub_streams = sub,
                .join_key = key,
            };
        }
    } else if (std.mem.startsWith(u8, trimmed, "slice(") and std.mem.endsWith(u8, trimmed, ")")) {
        const inner = trimmed[6 .. trimmed.len - 1];
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            const part_trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (part_trimmed.len > 0) {
                try list.append(alloc, part_trimmed);
            }
        }
        const parts = list.items;
        if (parts.len >= 1) {
            const stream_target = parts[0];
            const offset: usize = if (parts.len >= 2) std.fmt.parseInt(usize, parts[1], 10) catch 0 else 0;
            const count: usize = if (parts.len >= 3) std.fmt.parseInt(usize, parts[2], 10) catch 0 else 0;
            const sub = try alloc.alloc(InboundStreamExpr, 1);
            sub[0] = InboundStreamExpr.direct(stream_target);
            return .{
                .op = .slice,
                .sub_streams = sub,
                .slice_offset = offset,
                .slice_count = count,
            };
        }
    }

    return InboundStreamExpr.direct(trimmed);
}

fn parseInputs(alloc: Allocator, in_node: yaml_lib.Node) ![]const InputBindingSpec {
    if (in_node.asScalar()) |s| {
        const expr = try parseInboundStreamExpr(alloc, s);
        const single = try alloc.alloc(InputBindingSpec, 1);
        single[0] = .{ .param_name = "stream", .expr = expr };
        return single;
    } else if (in_node.asMap()) |entries| {
        var list: std.ArrayListUnmanaged(InputBindingSpec) = .empty;
        for (entries) |entry| {
            if (entry.value.asScalar()) |val_str| {
                const expr = try parseInboundStreamExpr(alloc, val_str);
                try list.append(alloc, .{
                    .param_name = entry.key,
                    .expr = expr,
                });
            }
        }
        return try list.toOwnedSlice(alloc);
    }
    return &.{};
}

fn parseKeyValueParams(alloc: Allocator, params_node: yaml_lib.Node) ![]const KeyValueParam {
    if (params_node.asMap()) |entries| {
        var list: std.ArrayListUnmanaged(KeyValueParam) = .empty;
        for (entries) |entry| {
            const val_str = entry.value.asScalar() orelse "";
            try list.append(alloc, .{
                .key = entry.key,
                .value = val_str,
            });
        }
        return try list.toOwnedSlice(alloc);
    }
    return &.{};
}

fn parseOutputs(alloc: Allocator, out_node: yaml_lib.Node) ![]const ChannelOutputSpec {
    if (out_node.asMap()) |entries| {
        var list: std.ArrayListUnmanaged(ChannelOutputSpec) = .empty;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "into")) {
                const target = entry.value.asScalar() orelse "default";
                try list.append(alloc, .{
                    .name = target,
                    .datasource = target,
                });
            } else if (entry.value.asMap() != null) {
                const ch = entry.value;
                const ds = if (ch.get("datasource")) |d| d.asScalar() orelse "default" else "default";
                const from = if (ch.get("from")) |f| f.asScalar() else null;
                const schema = if (ch.get("schema")) |s| s.asScalar() else null;
                const filter = if (ch.get("filter")) |fl| fl.asScalar() else null;
                try list.append(alloc, .{
                    .name = entry.key,
                    .from_field = from,
                    .schema_ref = schema,
                    .datasource = ds,
                    .filter = filter,
                });
            }
        }
        return try list.toOwnedSlice(alloc);
    } else if (out_node.asScalar()) |target_ds| {
        const single = try alloc.alloc(ChannelOutputSpec, 1);
        single[0] = .{
            .name = target_ds,
            .datasource = target_ds,
        };
        return single;
    }
    return &.{};
}

fn parseTaskStep(alloc: Allocator, step_node: yaml_lib.Node) !TaskStepSpec {
    const id = if (step_node.get("id")) |i|
        i.asScalar() orelse return error.MissingStepIdentifier
    else if (step_node.get("task")) |t|
        t.asScalar() orelse return error.MissingStepIdentifier
    else
        return error.MissingStepIdentifier;

    const uses_raw = if (step_node.get("uses")) |u|
        u.asScalar() orelse "core/noop"
    else if (step_node.get("use")) |u|
        u.asScalar() orelse "core/noop"
    else
        "core/noop";

    var module = uses_raw;
    var task = uses_raw;
    if (std.mem.indexOfScalar(u8, uses_raw, '/')) |idx| {
        module = uses_raw[0..idx];
        task = uses_raw[idx + 1 ..];
    }

    const where_filter = if (step_node.get("where")) |w|
        w.asScalar()
    else if (step_node.get("filter")) |f|
        f.asScalar()
    else
        null;

    const concurrency: ?usize = if (step_node.get("concurrency")) |c|
        if (c.asScalar()) |s|
            if (std.mem.eql(u8, s, "max") or std.mem.eql(u8, s, "auto"))
                std.Thread.getCpuCount() catch 1
            else
                std.fmt.parseInt(usize, s, 10) catch return error.InvalidConcurrencyValue
        else
            null
    else
        null;

    const inputs = if (step_node.get("inputs")) |in|
        try parseInputs(alloc, in)
    else if (step_node.get("in")) |in|
        try parseInputs(alloc, in)
    else
        &.{};

    const params = if (step_node.get("params")) |p|
        try parseKeyValueParams(alloc, p)
    else
        &.{};

    const outputs = if (step_node.get("outputs")) |o|
        try parseOutputs(alloc, o)
    else if (step_node.get("output")) |o|
        try parseOutputs(alloc, o)
    else
        &.{};

    return .{
        .id = id,
        .module = module,
        .task = task,
        .inputs = inputs,
        .where_filter = where_filter,
        .concurrency = concurrency,
        .static_params = params,
        .outputs = outputs,
    };
}

fn parseRouterStep(alloc: Allocator, step_node: yaml_lib.Node) !RouterStepSpec {
    const router_id = if (step_node.get("router")) |r|
        r.asScalar() orelse "router"
    else if (step_node.get("id")) |i|
        i.asScalar() orelse "router"
    else
        "router";

    const cases_node = step_node.get("cases") orelse step_node.get("routes");
    var cases_list: std.ArrayListUnmanaged(RouterCaseSpec) = .empty;

    if (cases_node) |cn| {
        if (cn.asSeq()) |seq| {
            for (seq) |case_node| {
                const when_val = if (case_node.get("when")) |w| w.asScalar() orelse "" else "";
                const goto_val = if (case_node.get("goto")) |g|
                    g.asScalar() orelse ""
                else if (case_node.get("then")) |t|
                    t.asScalar() orelse ""
                else
                    "";

                if (when_val.len > 0 and goto_val.len > 0) {
                    try cases_list.append(alloc, .{
                        .when_predicate = when_val,
                        .goto_pipeline = goto_val,
                    });
                }
            }
        }
    }

    const default_pipeline = if (step_node.get("default")) |d| d.asScalar() else null;

    return .{
        .id = router_id,
        .cases = try cases_list.toOwnedSlice(alloc),
        .default_pipeline = default_pipeline,
    };
}

/// Converts a declarative YAML pipeline string into a validated, format-agnostic `PipelineAST`.
pub fn loadPipelineAstFromYaml(
    allocator: Allocator,
    yaml_text: []const u8,
    options: AstLoadOptions,
) !PipelineAST {
    const ast_options = yaml_lib.AstOptions{
        .scalar_hook = if (options.env_interpolator) |interp| interp.scalarHook() else null,
    };

    const root_node = try yaml_lib.parseAst(allocator, yaml_text, ast_options);
    if (root_node.asMap() == null) {
        return error.InvalidYamlStructure;
    }

    var builder = PipelineBuilder.init(allocator);
    errdefer builder.deinit();

    // 1. Runtime / Engine Settings
    const runtime_node = root_node.get("runtime") orelse root_node.get("engine");
    if (runtime_node) |rt| {
        if (rt.get("workers")) |w_node| {
            if (w_node.asScalar()) |w_str| {
                if (std.mem.eql(u8, w_str, "auto")) {
                    const cpus = std.Thread.getCpuCount() catch 1;
                    builder.setWorkers(cpus);
                } else if (std.fmt.parseInt(usize, w_str, 10)) |w_val| {
                    builder.setWorkers(w_val);
                } else |_| {}
            }
        }
    }

    // 2. Datasources (Open-ended drivers)
    const datasources_node = root_node.get("datasources") orelse root_node.get("storages");
    if (datasources_node) |ds_node| {
        if (ds_node.asMap()) |entries| {
            for (entries) |entry| {
                const ds_val = entry.value;
                const driver = if (ds_val.get("driver")) |d|
                    d.asScalar() orelse "memory"
                else if (ds_val.get("type")) |t|
                    t.asScalar() orelse "memory"
                else if (ds_val.get("kind")) |k|
                    k.asScalar() orelse "memory"
                else
                    "memory";

                // Collect extra parameters (e.g. path, endpoint, index, directory)
                var params_list: std.ArrayListUnmanaged(KeyValueParam) = .empty;
                if (ds_val.asMap()) |param_entries| {
                    for (param_entries) |pe| {
                        if (!std.mem.eql(u8, pe.key, "driver") and
                            !std.mem.eql(u8, pe.key, "type") and
                            !std.mem.eql(u8, pe.key, "kind"))
                        {
                            const val_str = pe.value.asScalar() orelse "";
                            try params_list.append(allocator, .{
                                .key = pe.key,
                                .value = val_str,
                            });
                        }
                    }
                }

                try builder.addDatasource(.{
                    .id = entry.key,
                    .driver = driver,
                    .params = try params_list.toOwnedSlice(allocator),
                });
            }
        }
    }

    // 3. Pipelines & Steps
    const pipelines_node = root_node.get("pipelines") orelse return error.MissingPipelinesSection;
    if (pipelines_node.asMap()) |pipe_entries| {
        for (pipe_entries) |pipe_entry| {
            const pipe_name = pipe_entry.key;
            const pipe_val = pipe_entry.value;

            const steps_seq = if (pipe_val.get("steps")) |s|
                s.asSeq()
            else
                pipe_val.asSeq();

            var steps_list: std.ArrayListUnmanaged(StepNode) = .empty;

            if (steps_seq) |seq| {
                for (seq) |step_node| {
                    const is_router = step_node.get("router") != null or
                        step_node.get("cases") != null or
                        step_node.get("routes") != null;

                    if (is_router) {
                        const router_spec = try parseRouterStep(allocator, step_node);
                        try steps_list.append(allocator, .{ .router = router_spec });
                    } else {
                        const task_spec = try parseTaskStep(allocator, step_node);
                        try steps_list.append(allocator, .{ .task = task_spec });
                    }
                }
            }

            try builder.addPipeline(.{
                .name = pipe_name,
                .steps = try steps_list.toOwnedSlice(allocator),
            });
        }
    }

    return try builder.finish();
}

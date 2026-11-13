const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml_core = @import("../yaml/mod.zig");
const engine_mod = @import("engine.zig");
const ast_mod = @import("../ast/ast.zig");
const plugin_mod = @import("../plugin/mod.zig");
const repository_mod = @import("../repository/mod.zig");
const dataflow = @import("flowdata_dataflow");

const c_stdio = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
});

pub const RunnerError = error{
    FileOpenFailed,
    FileReadFailed,
    FileWriteFailed,
    FileTooLarge,
} || engine_mod.EngineError;

/// Reads an entire file from disk into an owned byte slice using `libc` (`fopen`/`fread`).
pub fn readFileBytes(allocator: Allocator, path: []const u8) RunnerError![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fp = c_stdio.fopen(path_z.ptr, "rb") orelse return error.FileOpenFailed;
    defer _ = c_stdio.fclose(fp);

    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_END) != 0) return error.FileReadFailed;
    const raw_pos = c_stdio.ftell(fp);
    if (raw_pos < 0) return error.FileReadFailed;
    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_SET) != 0) return error.FileReadFailed;

    const size_usize = std.math.cast(usize, raw_pos) orelse return error.FileTooLarge;
    const buf = try allocator.alloc(u8, size_usize);
    errdefer allocator.free(buf);

    if (size_usize > 0) {
        const read_n = c_stdio.fread(buf.ptr, 1, size_usize, fp);
        if (read_n != size_usize) return error.FileReadFailed;
    }

    return buf;
}

pub fn ensureParentDirs(allocator: Allocator, path: []const u8) void {
    const slash_idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash_idx == 0) return;
    const parent = path[0..slash_idx];

    var it = std.mem.splitScalar(u8, parent, '/');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    if (parent[0] == '/') {
        buf.append(allocator, '/') catch return;
    }

    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
            if (seg.len > 0) {
                buf.appendSlice(allocator, seg) catch return;
                buf.append(allocator, '/') catch return;
            }
            continue;
        }
        buf.appendSlice(allocator, seg) catch return;
        if (allocator.dupeZ(u8, buf.items)) |dir_z| {
            defer allocator.free(dir_z);
            _ = c_stdio.mkdir(dir_z.ptr, 0o755);
        } else |_| return;
        buf.append(allocator, '/') catch return;
    }
}

/// Writes `data` to `path` on disk using `libc` (`fopen`/`fwrite`), ensuring parent directories exist.
pub fn writeFileBytes(allocator: Allocator, path: []const u8, data: []const u8) RunnerError!void {
    ensureParentDirs(allocator, path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fp = c_stdio.fopen(path_z.ptr, "wb") orelse return error.FileOpenFailed;
    defer _ = c_stdio.fclose(fp);

    if (data.len > 0) {
        const written = c_stdio.fwrite(data.ptr, 1, data.len, fp);
        if (written != data.len) return error.FileWriteFailed;
    }
}

pub const ArtifactExportSpec = struct {
    artifact_id: []const u8,
    output_path: []const u8,
};

pub const DriverInitializerFn = *const fn (registry: *repository_mod.RepositoryRegistry) anyerror!void;

pub const RunnerOptions = struct {
    pipeline_yaml_path: []const u8,
    schemas_yaml_path: ?[]const u8 = null,
    dotenv_path: ?[]const u8 = null,
    wal_db_path: ?[]const u8 = null,
    trace_out_path: ?[]const u8 = null,
    entry_pipeline: ?[]const u8 = null,
    artifact_exports: []const ArtifactExportSpec = &.{},
    load_shared_modules: bool = true,
    driver_initializer: ?DriverInitializerFn = null,
    kernel: ?*@import("../kernel/mod.zig").KernelContext = null,
};

/// High-level coordinator that loads `.env` and `pipeline.yaml`,
/// resolves datasources via RepositoryRegistry, and runs the pipeline on media files.
pub const PipelineRunner = struct {
    allocator: Allocator,
    options: RunnerOptions,
    config_arena: std.heap.ArenaAllocator,
    env_interp: yaml_core.EnvInterpolator,
    ast: ast_mod.PipelineAST,
    registry: plugin_mod.ModuleRegistry,
    repos: repository_mod.RepositoryRegistry,

    pub fn initFromFiles(allocator: Allocator, options: RunnerOptions) anyerror!PipelineRunner {
        var config_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer config_arena.deinit();
        const arena = config_arena.allocator();

        var env_interp = yaml_core.EnvInterpolator.init(true);
        if (options.kernel) |k| {
            const S = struct {
                var kernel_ptr: ?*@import("../kernel/mod.zig").KernelContext = null;
                fn resolve(a: Allocator, scheme: []const u8, key: []const u8) ?[]const u8 {
                    if (kernel_ptr) |kp| {
                        return kp.dsl.resolveEnvScheme(a, scheme, key);
                    }
                    return null;
                }
            };
            S.kernel_ptr = k;
            env_interp.scheme_resolver = &S.resolve;
        }

        const default_env: ?[]const u8 = if (readFileBytes(arena, ".env")) |_|
            ".env"
        else |_| blk: {
            if (std.fs.path.dirname(options.pipeline_yaml_path)) |dir| {
                const sibling_env = try std.fs.path.join(arena, &.{ dir, ".env" });
                if (readFileBytes(arena, sibling_env)) |_| {
                    break :blk sibling_env;
                } else |_| {}
            }
            break :blk null;
        };
        const effective_env_path = options.dotenv_path orelse default_env;
        if (effective_env_path) |env_path| {
            if (readFileBytes(arena, env_path)) |env_bytes| {
                try env_interp.parseDotEnv(arena, env_bytes);
            } else |_| {}
        }

        const pipeline_yaml_bytes = try readFileBytes(arena, options.pipeline_yaml_path);
        var pipeline_ast = try yaml_core.loadPipelineAstFromYaml(arena, pipeline_yaml_bytes, .{
            .env_interpolator = &env_interp,
        });

        if (options.kernel) |k| {
            try k.ast_passes.runAll(&pipeline_ast);
        }

        var registry = plugin_mod.ModuleRegistry.init(allocator);
        errdefer registry.deinit();

        if (options.load_shared_modules) {
            for (pipeline_ast.modules) |mod_entry| {
                _ = try registry.loadSharedLibrary(mod_entry.name, mod_entry.path);
            }
        }

        var repos = repository_mod.RepositoryRegistry.init(allocator);
        errdefer repos.deinit();
        if (options.driver_initializer) |init_fn| {
            try init_fn(&repos);
        }
        if (options.kernel) |k| {
            var it = k.datasources.drivers.iterator();
            while (it.next()) |entry| {
                try repos.registerDriver(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        return PipelineRunner{
            .allocator = allocator,
            .options = options,
            .config_arena = config_arena,
            .env_interp = env_interp,
            .ast = pipeline_ast,
            .registry = registry,
            .repos = repos,
        };
    }

    pub fn deinit(self: *PipelineRunner) void {
        self.repos.deinit();
        self.registry.deinit();
        self.config_arena.deinit();
    }

    pub fn validatePreFlight(
        self: *PipelineRunner,
        wal_db_path: ?[]const u8,
        load_shared: bool,
    ) anyerror!void {
        _ = wal_db_path;

        // 1. Validate entrypoint pipeline exists
        const entrypoint = self.ast.getEntrypoint() orelse return error.MissingMainPipeline;
        if (self.ast.getPipeline(entrypoint) == null) {
            return error.MissingMainPipeline;
        }

        // 2. Validate schemas if specified or default configs/schemas.yaml exists
        const schemas_path: ?[]const u8 = if (self.options.schemas_yaml_path) |p| p else blk: {
            const fp = c_stdio.fopen("configs/schemas.yaml", "rb");
            if (fp != null) {
                _ = c_stdio.fclose(fp);
                break :blk "configs/schemas.yaml";
            } else {
                break :blk null;
            }
        };

        var loaded_catalog: ?yaml_core.SchemaCatalog = null;
        if (schemas_path) |s_path| {
            const arena = self.config_arena.allocator();
            const schema_yaml_bytes = try readFileBytes(arena, s_path);
            const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schema_yaml_bytes, &self.env_interp);
            try catalog.yamlValidate(arena);
            loaded_catalog = catalog;
        }

        // 3. Validate modules and step task bindings
        for (self.ast.pipelines) |pipe| {
            for (pipe.steps) |step| {
                switch (step) {
                    .task => |t| {
                        const resolved_desc = if (load_shared and self.options.load_shared_modules)
                            try self.registry.resolveTask(t.module, t.task)
                        else
                            null;

                        for (t.inputs) |in_b| {
                            if (in_b.expr.stream_ref) |sref| {
                                const ds_id = if (std.mem.indexOfScalar(u8, sref, '.')) |dot| sref[0..dot] else sref;
                                if (self.ast.getDatasource(ds_id)) |ds| {
                                    if (ds.role == .sink) return error.CannotReadFromSinkDatasource;
                                }
                                if (loaded_catalog) |*cat| {
                                    if (resolved_desc) |desc| {
                                        const tbl_name = if (std.mem.indexOfScalar(u8, sref, '.')) |dot| sref[dot + 1 ..] else sref;
                                        try engine_mod.preflight.validateTaskAgainstCatalog(desc, tbl_name, cat, false);
                                    }
                                }
                            }
                        }
                        for (t.outputs) |out_ch| {
                            if (self.ast.getDatasource(out_ch.datasource)) |ds| {
                                if (ds.role == .source) return error.CannotWriteToSourceDatasource;
                            }
                            if (loaded_catalog) |*cat| {
                                if (resolved_desc) |desc| {
                                    const tbl_name = out_ch.schema_ref orelse out_ch.name;
                                    try engine_mod.preflight.validateTaskAgainstCatalog(desc, tbl_name, cat, true);
                                }
                            }
                        }
                    },
                    .router => |r| {
                        for (r.cases) |c| {
                            if (!std.mem.eql(u8, c.goto_pipeline, "continue")) {
                                if (self.ast.getPipeline(c.goto_pipeline) == null) {
                                    return error.UnknownTargetSubPipeline;
                                }
                            }
                        }
                        if (r.default_pipeline) |def_pipe| {
                            if (!std.mem.eql(u8, def_pipe, "continue")) {
                                if (self.ast.getPipeline(def_pipe) == null) {
                                    return error.UnknownTargetSubPipeline;
                                }
                            }
                        }
                    },
                }
            }
        }
    }

    /// Runs the pipeline on `input_file_path`.
    pub fn runFile(
        self: *PipelineRunner,
        input_file_path: []const u8,
        options: RunnerOptions,
    ) anyerror!engine_mod.ExecutionSummary {
        _ = options;
        const file_bytes = try readFileBytes(self.allocator, input_file_path);
        defer self.allocator.free(file_bytes);

        const input_payload = dataflow.PayloadHandle.fromSlice(u8, file_bytes);
        return try self.runWithPayload(input_payload);
    }

    /// Runs the pipeline on an in-memory byte slice.
    pub fn runMemory(
        self: *PipelineRunner,
        bytes: []const u8,
        options: RunnerOptions,
    ) anyerror!engine_mod.ExecutionSummary {
        _ = options;
        const input_payload = dataflow.PayloadHandle.fromSlice(u8, bytes);
        return try self.runWithPayload(input_payload);
    }

    /// Parses a JSON job payload into a typed `JobSpec` record and runs the pipeline.
    /// Used by HTTP/RPC `POST /v1/jobs` so type-driven pipelines receive the same
    /// `JobSpec` representation as `yaml_file` batch sources.
    pub fn runJobJson(
        self: *PipelineRunner,
        json_bytes: []const u8,
        options: RunnerOptions,
    ) anyerror!engine_mod.ExecutionSummary {
        _ = options;
        var job_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer job_arena.deinit();
        const a = job_arena.allocator();

        const job_spec = try parseJobSpecFromJson(a, json_bytes);
        const job_slice = try a.dupe(ast_mod.JobSpec, &.{job_spec});
        const input_payload = dataflow.PayloadHandle.fromSlice(ast_mod.JobSpec, job_slice);
        return try self.runWithPayload(input_payload);
    }

    fn runWithPayload(
        self: *PipelineRunner,
        input_payload: dataflow.PayloadHandle,
    ) anyerror!engine_mod.ExecutionSummary {
        if (self.options.kernel) |k| {
            const S = struct {
                var kernel_ptr: ?*@import("../kernel/mod.zig").KernelContext = null;
                fn eval(fn_name: []const u8, arg: dataflow.ReflectedValue, param: []const u8) ?bool {
                    if (kernel_ptr) |kp| {
                        return kp.dsl.evaluatePredicate(fn_name, arg, param);
                    }
                    return null;
                }
            };
            S.kernel_ptr = k;
            dataflow.predicate.global_custom_predicate_evaluator = &S.eval;
        }

        var eng = engine_mod.PipelineEngine.init(
            self.allocator,
            self.ast,
            &self.registry,
            &self.repos,
        );
        defer eng.deinit();
        eng.withKernel(self.options.kernel);

        return try eng.run(input_payload);
    }
};

fn parseJobSpecFromJson(alloc: Allocator, json_bytes: []const u8) !ast_mod.JobSpec {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
    if (parsed.value != .object) return error.InvalidJobPayload;

    const obj = parsed.value.object;
    const id_str: []const u8 = if (obj.get("id")) |v|
        (if (v == .string) try alloc.dupe(u8, v.string) else "http_job")
    else if (obj.get("series_id")) |v|
        (if (v == .string) try alloc.dupe(u8, v.string) else "http_job")
    else
        "http_job";

    const ds_str: ?[]const u8 = if (obj.get("datasource")) |v|
        (if (v == .string) try alloc.dupe(u8, v.string) else null)
    else
        null;

    const enabled: bool = if (obj.get("enabled")) |v|
        (if (v == .bool) v.bool else true)
    else
        true;

    var params: std.ArrayListUnmanaged(ast_mod.KeyValueParam) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        const val_str: ?[]const u8 = switch (entry.value_ptr.*) {
            .string => |s| try alloc.dupe(u8, s),
            .bool => |b| if (b) "true" else "false",
            .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
            .array => |arr| blk: {
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                for (arr.items, 0..) |elem, idx| {
                    if (elem == .string) {
                        if (buf.items.len > 0 and idx > 0) try buf.append(alloc, ',');
                        try buf.appendSlice(alloc, elem.string);
                    }
                }
                break :blk if (buf.items.len > 0) buf.items else null;
            },
            else => null,
        };
        if (val_str) |vs| {
            try params.append(alloc, .{ .key = key, .value = vs });
        }
    }

    return .{
        .id = id_str,
        .datasource = ds_str,
        .enabled = enabled,
        .params = try params.toOwnedSlice(alloc),
    };
}

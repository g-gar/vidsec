const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("../abi/mod.zig");
const yaml_core = @import("../yaml/mod.zig");
const artifact_mod = @import("artifact.zig");
const engine_mod = @import("engine.zig");
const ast_mod = @import("../ast/ast.zig");
const repository_mod = @import("../repository/mod.zig");
const dataflow = @import("../dataflow/mod.zig");

const c_stdio = @cImport({
    @cInclude("stdio.h");
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

/// Writes `data` to `path` on disk using `libc` (`fopen`/`fwrite`).
pub fn writeFileBytes(allocator: Allocator, path: []const u8, data: []const u8) RunnerError!void {
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
};

/// High-level coordinator that loads `.env` and `pipeline.yaml`,
/// resolves datasources via RepositoryRegistry, and runs the pipeline on media files.
pub const PipelineRunner = struct {
    allocator: Allocator,
    options: RunnerOptions,
    config_arena: std.heap.ArenaAllocator,
    env_interp: yaml_core.EnvInterpolator,
    ast: ast_mod.PipelineAST,
    registry: @import("../modules/mod.zig").ModuleRegistry,
    repos: repository_mod.RepositoryRegistry,

    pub fn initFromFiles(allocator: Allocator, options: RunnerOptions) anyerror!PipelineRunner {
        var config_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer config_arena.deinit();
        const arena = config_arena.allocator();

        var env_interp = yaml_core.EnvInterpolator.init(true);
        if (options.dotenv_path) |env_path| {
            const env_bytes = try readFileBytes(arena, env_path);
            try env_interp.parseDotEnv(arena, env_bytes);
        }

        const pipeline_yaml_bytes = try readFileBytes(arena, options.pipeline_yaml_path);
        const pipeline_ast = try yaml_core.loadPipelineAstFromYaml(arena, pipeline_yaml_bytes, .{
            .env_interpolator = &env_interp,
        });

        var registry = @import("../modules/mod.zig").ModuleRegistry.init(allocator);
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

        // 1. Validate main pipeline exists
        if (self.ast.getPipeline("main") == null) {
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

        if (schemas_path) |s_path| {
            const arena = self.config_arena.allocator();
            const schema_yaml_bytes = try readFileBytes(arena, s_path);
            const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schema_yaml_bytes, &self.env_interp);
            try catalog.yamlValidate(arena);
        }

        // 3. Validate modules and step task bindings
        for (self.ast.pipelines) |pipe| {
            for (pipe.steps) |step| {
                switch (step) {
                    .task => |t| {
                        if (load_shared and self.options.load_shared_modules) {
                            _ = try self.registry.resolveTask(t.module, t.task);
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

        var eng = engine_mod.PipelineEngine.init(
            self.allocator,
            self.ast,
            &self.registry,
            &self.repos,
        );

        const input_payload = dataflow.PayloadHandle.fromSlice(u8, file_bytes);
        return try eng.run(input_payload);
    }
};

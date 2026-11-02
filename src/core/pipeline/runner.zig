const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("vidsec_abi");
const yaml_core = @import("../yaml/mod.zig");
const sqlite_core = @import("../sqlite/mod.zig");
const artifact_mod = @import("artifact.zig");
const engine_mod = @import("engine.zig");

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

pub const RunnerOptions = struct {
    pipeline_yaml_path: []const u8,
    schemas_yaml_path: ?[]const u8 = null,
    dotenv_path: ?[]const u8 = null,
    wal_db_path: ?[]const u8 = null,
    trace_out_path: ?[]const u8 = null,
    entry_pipeline: ?[]const u8 = null,
    artifact_exports: []const ArtifactExportSpec = &.{},
    load_shared_modules: bool = true,
};

/// High-level coordinator that loads `.env`, `pipeline.yaml`, `schemas.yaml`, and `.so` plugins from disk,
/// executes pre-flight validation, and runs the pipeline on media files.
pub const PipelineRunner = struct {
    allocator: Allocator,
    config_arena: std.heap.ArenaAllocator,
    env_interp: yaml_core.EnvInterpolator,
    config: yaml_core.PipelineConfig,
    catalog: yaml_core.SchemaCatalog,
    registry: abi.ModuleRegistry,
    db_runtime: sqlite_core.SqliteRuntime,

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
        const config = try yaml_core.PipelineConfig.parse(arena, pipeline_yaml_bytes, &env_interp);

        const schemas_path = options.schemas_yaml_path orelse config.engine.schemas_path;
        const schemas_yaml_bytes = try readFileBytes(arena, schemas_path);
        const catalog = try yaml_core.SchemaCatalog.parseYaml(arena, schemas_yaml_bytes, &env_interp);

        var registry = abi.ModuleRegistry.init(allocator);
        errdefer registry.deinit();

        return PipelineRunner{
            .allocator = allocator,
            .config_arena = config_arena,
            .env_interp = env_interp,
            .config = config,
            .catalog = catalog,
            .registry = registry,
            .db_runtime = undefined,
        };
    }

    pub fn deinit(self: *PipelineRunner) void {
        self.registry.deinit();
        self.config_arena.deinit();
    }

    /// Initializes the SQLite database runtime, optionally loads `.so` shared libraries from `config.modules`,
    /// and executes full pre-flight validation.
    pub fn validatePreFlight(
        self: *PipelineRunner,
        wal_db_path: ?[]const u8,
        load_shared: bool,
    ) anyerror!void {
        var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
            self.allocator,
            self.config.engine,
            wal_db_path,
            &self.catalog,
        );
        defer db_runtime.deinit();

        var eng = engine_mod.PipelineEngine.init(
            self.allocator,
            &self.config,
            &self.catalog,
            &self.registry,
            &db_runtime,
        );
        defer eng.deinit();

        if (load_shared) {
            try eng.loadConfiguredModules();
        }
        try eng.preflightValidate();
    }

    /// Runs the validated pipeline on `input_file_path`, writing trace JSONL and any requested output artifacts.
    pub fn runFile(
        self: *PipelineRunner,
        input_file_path: []const u8,
        options: RunnerOptions,
    ) anyerror!engine_mod.ExecutionSummary {
        var db_runtime = try sqlite_core.SqliteRuntime.initWithSettings(
            self.allocator,
            self.config.engine,
            options.wal_db_path,
            &self.catalog,
        );
        defer db_runtime.deinit();

        var eng = engine_mod.PipelineEngine.init(
            self.allocator,
            &self.config,
            &self.catalog,
            &self.registry,
            &db_runtime,
        );
        defer eng.deinit();

        if (options.load_shared_modules) {
            try eng.loadConfiguredModules();
        }
        try eng.preflightValidate();

        var artifacts = try artifact_mod.ArtifactStore.initFromFile(self.allocator, input_file_path);
        defer artifacts.deinit();

        const start_p = options.entry_pipeline orelse "main";
        const summary = try eng.runFrom(&artifacts, start_p);

        // Write JSONL trace if requested via CLI or configured in `engine.trace_file`
        if (options.trace_out_path orelse self.config.engine.trace_file) |trace_path| {
            const jsonl = try eng.tracer.toJsonLines(self.allocator);
            defer self.allocator.free(jsonl);
            try writeFileBytes(self.allocator, trace_path, jsonl);
        }

        // Write requested output artifacts to disk
        for (options.artifact_exports) |exp| {
            const art_buf = try artifacts.getBuffer(exp.artifact_id);
            try writeFileBytes(self.allocator, exp.output_path, art_buf.slice());
        }

        return summary;
    }
};

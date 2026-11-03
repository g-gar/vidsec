const std = @import("std");
const Allocator = std.mem.Allocator;

pub const yaml_lib = @import("../../lib/yaml/mod.zig");
pub const env = @import("env.zig");
pub const schema_loader = @import("loaders/schema_loader.zig");
pub const engine_loader = @import("loaders/engine_loader.zig");
pub const module_loader_spec = @import("loaders/module_loader_spec.zig");
pub const input_spec = @import("loaders/input_spec.zig");
pub const output_spec = @import("loaders/output_spec.zig");
pub const router_spec = @import("loaders/router_spec.zig");
pub const step_loader = @import("loaders/step_loader.zig");

pub const EnvInterpolator = env.EnvInterpolator;
pub const YamlNode = yaml_lib.Node;
pub const SchemaCatalog = schema_loader.SchemaCatalog;
pub const DomainSchema = schema_loader.DomainSchema;
pub const TableSchema = schema_loader.TableSchema;
pub const ColumnSpec = schema_loader.ColumnSpec;
pub const ColumnType = schema_loader.ColumnType;
pub const EngineSettings = engine_loader.EngineSettings;
pub const DbMode = engine_loader.DbMode;
pub const ModuleDecl = module_loader_spec.ModuleDecl;
pub const ModuleDeclMap = module_loader_spec.ModuleDeclMap;
pub const InputSpec = input_spec.InputSpec;
pub const InputChannelSpec = input_spec.InputChannelSpec;
pub const OutputSpec = output_spec.OutputSpec;
pub const RouterStep = router_spec.RouterStep;
pub const TaskStep = step_loader.TaskStep;
pub const TaskTarget = step_loader.TaskTarget;
pub const Step = step_loader.Step;
pub const SubPipeline = step_loader.SubPipeline;
pub const SubPipelineMap = step_loader.SubPipelineMap;

pub const PipelineLoadError = error{
    UnsupportedPipelineVersion,
    UnknownModuleReference,
    UnknownSchemaDomainReference,
    UnknownTableReference,
    UnknownOutputColumnReference,
    OutOfMemory,
} || yaml_lib.YamlAstError ||
    yaml_lib.DecodeError ||
    env.EnvError ||
    engine_loader.EngineLoadError ||
    module_loader_spec.ModuleSpecError ||
    step_loader.StepLoadError;

pub const StorageTargetDecl = struct {
    type: []const u8 = "sqlite",
    schema: ?[]const u8 = null,
    path: ?[]const u8 = null,
    directory: ?[]const u8 = null,
};

pub const StorageConfigMap = yaml_lib.Map(StorageTargetDecl);

/// Complete decoded and validated representation of `pipeline.yaml`.
pub const PipelineConfig = struct {
    version: u32,
    engine: EngineSettings,
    storages: ?StorageConfigMap = null,
    modules: ModuleDeclMap,
    pipelines: SubPipelineMap,

    pub fn yamlParse(
        arena: Allocator,
        node: yaml_lib.Node,
        options: yaml_lib.ParseOptions,
    ) anyerror!PipelineConfig {
        _ = node.asMap() orelse return error.TypeMismatch;

        const version_node = node.get("version") orelse return error.UnsupportedPipelineVersion;
        const version_val = if (version_node.asScalar()) |s|
            std.fmt.parseInt(u32, s, 10) catch return error.UnsupportedPipelineVersion
        else
            return error.UnsupportedPipelineVersion;

        var storages: ?StorageConfigMap = null;
        if (node.get("storages")) |st_node| {
            storages = try yaml_lib.parseFromNode(StorageConfigMap, arena, st_node, options);
        }

        var engine: EngineSettings = undefined;
        if (node.get("engine")) |eng_node| {
            engine = try yaml_lib.parseFromNode(EngineSettings, arena, eng_node, options);
        } else if (storages) |st| {
            var schemas_path: []const u8 = "./configs/schemas.yaml";
            var db_path: ?[]const u8 = null;
            var db_mode: DbMode = .memory;

            if (st.get("db")) |db_entry| {
                if (db_entry.schema) |s| schemas_path = s;
                if (db_entry.path) |p| {
                    db_path = p;
                    db_mode = .wal_file;
                }
            }
            engine = EngineSettings{
                .schemas_path = schemas_path,
                .db_path = db_path,
                .db_mode = db_mode,
            };
        } else {
            return error.MissingSchemasPath;
        }

        const mod_node = node.get("modules") orelse return error.TypeMismatch;
        const modules = try yaml_lib.parseFromNode(ModuleDeclMap, arena, mod_node, options);

        const pip_node = node.get("pipelines") orelse return error.TypeMismatch;
        const pipelines = try yaml_lib.parseFromNode(SubPipelineMap, arena, pip_node, options);

        const config = PipelineConfig{
            .version = version_val,
            .engine = engine,
            .storages = storages,
            .modules = modules,
            .pipelines = pipelines,
        };
        try config.yamlValidate(arena);
        return config;
    }

    /// Parses a `pipeline.yaml` string (expanding `.env` variables via `ScalarHook` when `env_interp` is provided)
    /// and validates module references and the router transition DAG.
    pub fn parse(
        arena: Allocator,
        yaml_src: []const u8,
        env_interp: ?*const EnvInterpolator,
    ) anyerror!PipelineConfig {
        const opts = yaml_lib.ParseOptions{
            .scalar_hook = if (env_interp) |e| e.scalarHook() else null,
        };
        return yaml_lib.parse(PipelineConfig, arena, yaml_src, opts);
    }

    /// Post-decode hook invoked automatically by `src/lib/yaml/decode.zig`.
    pub fn yamlValidate(self: *const PipelineConfig, arena: Allocator) PipelineLoadError!void {
        if (self.version != 2) return error.UnsupportedPipelineVersion;

        try step_loader.validateRouterAcyclicGraph(arena, &self.pipelines);

        for (self.pipelines.entries) |sub_entry| {
            for (sub_entry.value.steps) |step| {
                switch (step) {
                    .router => {},
                    .task => |t| {
                        if (t.target.moduleName()) |mod_name| {
                            if (!self.modules.contains(mod_name)) {
                                return error.UnknownModuleReference;
                            }
                        }
                    },
                }
            }
        }
    }

    /// Pre-flight cross-validation of `pipeline.yaml` against `schemas.yaml` (`SchemaCatalog`).
    /// Verifies that all referenced input tables, output schemas, output tables, and mapped target columns exist.
    pub fn validateAgainstCatalog(
        self: *const PipelineConfig,
        catalog: *const SchemaCatalog,
    ) PipelineLoadError!void {
        for (self.pipelines.entries) |sub_entry| {
            for (sub_entry.value.steps) |step| {
                switch (step) {
                    .router => {},
                    .task => |task_step| {
                        if (task_step.input) |in_spec| {
                            for (in_spec.entries) |ch_entry| {
                                if (ch_entry.value.table) |tbl_name| {
                                    if (catalog.getTable(tbl_name) == null) {
                                        return error.UnknownTableReference;
                                    }
                                }
                            }
                        }

                        if (task_step.output) |out_spec| {
                            if (out_spec.target()) |target| {
                                switch (target) {
                                    .schema_domain => |dom_name| {
                                        if (catalog.getDomain(dom_name) == null) {
                                            return error.UnknownSchemaDomainReference;
                                        }
                                    },
                                    .into_table => |into_tbl| {
                                        const tbl_schema = catalog.getTable(into_tbl.table) orelse
                                            return error.UnknownTableReference;

                                        if (into_tbl.key_column) |key_col| {
                                            if (tbl_schema.findColumn(key_col) == null) {
                                                return error.UnknownOutputColumnReference;
                                            }
                                        }

                                        if (into_tbl.map) |mappings| {
                                            for (mappings.entries) |m| {
                                                if (tbl_schema.findColumn(m.key) == null) {
                                                    return error.UnknownOutputColumnReference;
                                                }
                                            }
                                        }
                                    },
                                }
                            }
                        }
                    },
                }
            }
        }
    }
};


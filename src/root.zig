const std = @import("std");

/// Generic, specification-agnostic YAML library (`src/lib/yaml/`).
pub const yaml_lib = @import("lib/yaml/mod.zig");

/// Generic, idiomatic SQLite3 SDK & full-fledged DDL/Query Builder (`src/lib/sqlite/`).
pub const sqlite_lib = @import("lib/sqlite/mod.zig");

/// C-ABI Plugin Contract (`VIDSEC_ABI_VERSION = 2`), Zig Plugin SDK, and Dynamic Module Loader (`src/lib/abi/`).
pub const abi_lib = @import("vidsec_abi");

/// Zero-allocation binary signature (`magic bytes`), MIME type, and container family detection library (`src/lib/magic/`).
pub const magic_lib = @import("vidsec_magic");

/// Pure numerical, statistical, Shannon entropy, interval algebra, and matrix library (`src/lib/math/`).
pub const math_lib = @import("vidsec_math");

/// Pure ISOBMFF parsing, box hierarchy expansion, and structural triage library (`src/lib/formats/isobmff/`).
pub const isobmff_lib = @import("vidsec_isobmff");

/// Pure MP4 inspection, brand validation, track decoding, and sample table analysis (`src/lib/formats/mp4/`).
pub const mp4_lib = @import("vidsec_mp4");

/// Pure EBML parsing, element hierarchy expansion, and structural grammar analysis (`src/lib/formats/ebml/`).
pub const ebml_lib = @import("vidsec_ebml");

/// Pure Matroska (MKV) inspection, track decoding, codec parameters, and cluster analysis (`src/lib/formats/mkv/`).
pub const mkv_lib = @import("vidsec_mkv");

/// Pure RIFF container and chunk hierarchy parsing library (`src/lib/formats/riff/`).
pub const riff_lib = @import("vidsec_riff");

/// `vidsec v2` domain configuration loaders (`schemas.yaml` and `pipeline.yaml`) built on top of `yaml_lib`.
pub const yaml = @import("core/yaml/mod.zig");

/// `vidsec v2` SQLite runtime, schema DDL compiler, declarative query compiler, `sql_rule`, and `router` engine.
pub const sqlite = @import("core/sqlite/mod.zig");

/// `vidsec v2` Pipeline Execution Engine, Host VTable Context, Managed Artifact Store, and JSONL Tracer (`src/core/pipeline/`).
pub const pipeline = @import("core/pipeline/mod.zig");

/// Official `vidsec v2` Plugin Modules (`src/plugin/`), compilable both as `.so` shared libraries and static modules.
pub const plugin = @import("plugin/mod.zig");

pub const EnvInterpolator = yaml.EnvInterpolator;
pub const YamlNode = yaml.YamlNode;
pub const SchemaCatalog = yaml.SchemaCatalog;
pub const PipelineConfig = yaml.PipelineConfig;
pub const CatalogCompiler = sqlite.CatalogCompiler;
pub const SqliteRuntime = sqlite.SqliteRuntime;
pub const ModuleRegistry = pipeline.ModuleRegistry;
pub const ArtifactStore = pipeline.ArtifactStore;
pub const ExecutionTracer = pipeline.ExecutionTracer;
pub const PipelineEngine = pipeline.PipelineEngine;

pub const build_options = @import("build_options");
pub const version = build_options.version;
pub const version_string = build_options.version_string;

test {
    std.testing.refAllDecls(@This());
}

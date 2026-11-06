const std = @import("std");

/// Flowdata: Zero-Copy Black Box Native Zig Dataflow & Pipeline Engine (`packages/flowdata/`).
pub const flowdata = @import("flowdata");

/// C-ABI Plugin Contract (`VIDSEC_ABI_VERSION = 2`), Zig Plugin SDK, and Dynamic Module Loader.
pub const abi_lib = flowdata.abi;

/// Zero-allocation binary signature (`magic bytes`), MIME type, and container family detection library (`src/plugin/magic/`).
pub const magic_lib = @import("vidsec_magic");

/// Pure numerical, statistical, Shannon entropy, interval algebra, and matrix library (`src/plugin/math/`).
pub const math_lib = @import("vidsec_math");

/// Pure ISOBMFF parsing, box hierarchy expansion, and structural triage library (`src/plugin/formats/isobmff/`).
pub const isobmff_lib = @import("vidsec_isobmff");

/// Pure MP4 inspection, brand validation, track decoding, and sample table analysis (`src/plugin/formats/mp4/`).
pub const mp4_lib = @import("vidsec_mp4");

/// Pure EBML parsing, element hierarchy expansion, and structural grammar analysis (`src/plugin/formats/ebml/`).
pub const ebml_lib = @import("vidsec_ebml");

/// Pure Matroska (MKV) inspection, track decoding, codec parameters, and cluster analysis (`src/plugin/formats/mkv/`).
pub const mkv_lib = @import("vidsec_mkv");

/// Pure RIFF container and chunk hierarchy parsing library (`src/plugin/formats/riff/`).
pub const riff_lib = @import("vidsec_riff");

/// Intermediate Representation (IR) schemas and structures (`src/plugin/ir/`).
pub const ir = @import("vidsec_ir");

/// Universal digital forensics primitives and finding models (`src/plugin/forensics/`).
pub const forensics = @import("vidsec_forensics");

/// Flowdata domain configuration loaders (`schemas.yaml` and `pipeline.yaml`).
pub const yaml = flowdata.yaml;

/// Flowdata Pipeline Execution Engine, Managed Artifact Store, and JSONL Tracer.
pub const pipeline = flowdata;
pub const pipeline_ast = flowdata.ast;
pub const PipelineAST = flowdata.PipelineAST;
pub const PipelineEngine = flowdata.PipelineEngine;

/// Flowdata Pure Dataflow Algebra, Automatic Lifting, Stream Transformation, and Multi-Core Execution.
pub const dataflow = flowdata.dataflow;

/// Official `vidsec v2` Plugin Modules (`src/plugin/`), compilable both as `.so` shared libraries and static modules.
pub const plugin = @import("plugin/mod.zig");

/// Vidsec Flowdata Extensions (Datasources: memory, file_store, sqlite)
pub const extensions = @import("vidsec_extensions");

pub const EnvInterpolator = yaml.EnvInterpolator;
pub const YamlNode = yaml.YamlNode;

test {
    std.testing.refAllDecls(@This());
}

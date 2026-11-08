const std = @import("std");

/// Flowdata: Zero-Copy Black Box Native Zig Dataflow & Pipeline Engine (`packages/flowdata/`).
pub const flowdata = @import("flowdata");

/// Flowdata C-ABI Plugin Contract (`FLOWDATA_ABI_VERSION = 2`), Zig Plugin SDK, and Dynamic Module Loader.
pub const abi_lib = @import("flowdata_abi");

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
pub const extensions = @import("vidsec_extensions");
pub const artifact = extensions.artifact;
pub const tracer = extensions.trace_jsonl;
pub const ManagedBuffer = artifact.ManagedBuffer;
pub const ArtifactStore = artifact.ArtifactStore;

pub const pipeline = struct {
    pub const ManagedBuffer = extensions.artifact.ManagedBuffer;
    pub const ArtifactStore = extensions.artifact.ArtifactStore;
    pub const artifact = extensions.artifact;

    pub const PipelineAST = flowdata.PipelineAST;
    pub const PipelineBuilder = flowdata.PipelineBuilder;
    pub const PipelineEngine = flowdata.PipelineEngine;
    pub const ModuleRegistry = flowdata.ModuleRegistry;
    pub const PluginRegistry = flowdata.PluginRegistry;
    pub const RepositoryRegistry = flowdata.RepositoryRegistry;
    pub const validateManifest = flowdata.validateManifest;
    pub const verifySafeModulePermissions = flowdata.verifySafeModulePermissions;
    pub const PayloadHandle = flowdata.PayloadHandle;
    pub const readFileBytes = flowdata.readFileBytes;
    pub const writeFileBytes = flowdata.writeFileBytes;
    pub const NetworkEvent = flowdata.NetworkEvent;
    pub const ExecutionSummary = flowdata.ExecutionSummary;
    pub const EngineNetworkController = flowdata.EngineNetworkController;
    pub const NetworkAdapter = flowdata.NetworkAdapter;
    pub const NetworkRegistry = flowdata.NetworkRegistry;
    pub const repository = flowdata.repository;
    pub const ast = flowdata.ast;
    pub const dataflow = flowdata.dataflow;
    pub const yaml = flowdata.yaml;
    pub const host = @This().host;
    pub const network = flowdata.network;
};
pub const pipeline_ast = flowdata.ast;
pub const PipelineAST = flowdata.PipelineAST;
pub const PipelineEngine = flowdata.PipelineEngine;
pub const host = struct {
    pub const HostTransport = flowdata.host.HostTransport;
    pub const InboundTransport = flowdata.host.InboundTransport;
    pub const HostDispatcher = flowdata.host.HostDispatcher;
    pub const InboundDispatcher = flowdata.host.InboundDispatcher;
    pub const HostApp = flowdata.host.HostApp;
    pub const TransportApp = flowdata.host.TransportApp;
    pub const AppConfig = flowdata.host.AppConfig;
    pub const AppInfo = flowdata.host.AppInfo;
    pub const InboundRegistry = flowdata.host.InboundRegistry;
    pub const InboundTransportConfig = flowdata.host.InboundTransportConfig;
    pub const InvocationRequest = flowdata.host.InvocationRequest;
    pub const InvocationResponse = flowdata.host.InvocationResponse;
    pub const InvocationStatus = flowdata.host.InvocationStatus;
    pub const InvocationCommand = flowdata.host.InvocationCommand;
    pub const InputSource = flowdata.host.InputSource;
    pub const OutputFormat = flowdata.host.OutputFormat;
    pub const DispatcherPtr = flowdata.host.DispatcherPtr;
    pub const DispatchFn = flowdata.host.DispatchFn;

    pub const CliTransport = extensions.inbound_cli.CliTransport;
    pub const HttpServerTransport = extensions.inbound_http.HttpServerTransport;
    pub const HttpTransport = HttpServerTransport;
    pub const GrpcTransport = extensions.inbound_grpc.GrpcTransport;
};

/// Flowdata Pure Dataflow Algebra, Automatic Lifting, Stream Transformation, and Multi-Core Execution.
pub const dataflow = flowdata.dataflow;

/// Official `vidsec v2` Analytical & Remediation Modules.
pub const analysis = @import("analysis/mod.zig");
pub const remediation = @import("remediation/mod.zig");

/// Compatibility namespace for plugins and existing tests
pub const plugin = struct {
    pub const analysis = @import("analysis/mod.zig");
    pub const remediation = @import("remediation/mod.zig");
    pub const analyzer = @import("analysis/mod.zig");
    pub const triage = @import("analysis/mod.zig");
    pub const lib = struct {
        pub const formats = @import("vidsec_formats_common");
        pub const isobmff = @import("vidsec_isobmff");
        pub const mp4 = @import("vidsec_mp4");
        pub const ebml = @import("vidsec_ebml");
        pub const mkv = @import("vidsec_mkv");
        pub const riff = @import("vidsec_riff");
        pub const ir = @import("vidsec_ir");
        pub const forensics = @import("vidsec_forensics");
        pub const magic = @import("vidsec_magic");
        pub const math = @import("vidsec_math");
    };
};

/// Vidsec Flowdata Extensions (Datasources: memory, file_store, sqlite)
pub const EnvInterpolator = yaml.EnvInterpolator;
pub const YamlNode = yaml.YamlNode;

test {
    std.testing.refAllDecls(@This());
}

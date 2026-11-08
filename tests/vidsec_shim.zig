const flowdata = @import("flowdata");
const ext_mod = @import("flowdata_extensions");

pub const extensions = ext_mod;
pub const artifact = ext_mod.artifact;
pub const tracer = ext_mod.trace_jsonl;
pub const ManagedBuffer = artifact.ManagedBuffer;
pub const ArtifactStore = artifact.ArtifactStore;

pub const pipeline = struct {
    pub const ManagedBuffer = ext_mod.artifact.ManagedBuffer;
    pub const ArtifactStore = ext_mod.artifact.ArtifactStore;
    pub const artifact = ext_mod.artifact;

    pub const PipelineEngine = flowdata.PipelineEngine;
    pub const PipelineAST = flowdata.PipelineAST;
    pub const PipelineBuilder = flowdata.PipelineBuilder;
    pub const RepositoryRegistry = flowdata.RepositoryRegistry;
    pub const repository = flowdata.repository;
    pub const ModuleRegistry = flowdata.ModuleRegistry;
    pub const PluginRegistry = flowdata.PluginRegistry;
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
};

pub const pipeline_ast = flowdata.ast;
pub const dataflow = flowdata.dataflow;
pub const yaml = flowdata.yaml;
pub const network = flowdata.network;
pub const abi = flowdata.abi;
pub const host = flowdata.host;

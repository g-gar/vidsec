const std = @import("std");

pub const ast = @import("ast/ast.zig");
pub const dataflow = @import("flowdata_dataflow");
pub const yaml = @import("yaml/mod.zig");
pub const repository = @import("repository/mod.zig");
pub const network = @import("network/mod.zig");
pub const engine = @import("engine/engine.zig");
pub const engine_network = @import("engine/network.zig");
pub const runner = @import("engine/runner.zig");
pub const host = @import("host/mod.zig");
pub const plugin = @import("plugin/mod.zig");
pub const modules = plugin;
pub const loader = plugin;
pub const abi = plugin.abi;
pub const tracer = @import("engine/tracer.zig");
pub const artifact = @import("engine/artifact.zig");
pub const pipeline = @This();
pub const pipeline_ast = ast;

// Primary Engine Exports
pub const PipelineAST = ast.PipelineAST;
pub const PipelineBuilder = ast.PipelineBuilder;
pub const PipelineEngine = engine.PipelineEngine;
pub const EngineNetworkController = engine_network.EngineNetworkController;
pub const PipelineRunner = runner.PipelineRunner;
pub const RunnerOptions = runner.RunnerOptions;
pub const HostApp = host.HostApp;
pub const HostDispatcher = host.HostDispatcher;
pub const HostTransport = host.HostTransport;
pub const AppConfig = host.AppConfig;
pub const ModuleRegistry = plugin.ModuleRegistry;
pub const PluginRegistry = plugin.PluginRegistry;
pub const validateManifest = plugin.validateManifest;
pub const verifySafeModulePermissions = plugin.verifySafeModulePermissions;
pub const LoaderError = plugin.LoaderError;
pub const ExecutionSummary = engine.ExecutionSummary;
pub const StorageRepository = repository.StorageRepository;
pub const RepositoryRegistry = repository.RepositoryRegistry;
pub const NetworkAdapter = network.NetworkAdapter;
pub const NetworkRegistry = network.NetworkRegistry;
pub const CapturedExchangeRecord = network.CapturedExchangeRecord;
pub const NetworkEvent = engine_network.NetworkEvent;
pub const PayloadHandle = dataflow.PayloadHandle;

// Artifact exports
pub const ArtifactStore = artifact.ArtifactStore;
pub const ManagedBuffer = artifact.ManagedBuffer;
pub const readFileBytes = runner.readFileBytes;
pub const ArtifactExportSpec = runner.ArtifactExportSpec;

test {
    std.testing.refAllDecls(@This());
}

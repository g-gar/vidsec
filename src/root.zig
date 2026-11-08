const std = @import("std");

pub const abi = @import("abi/mod.zig");
pub const ast = @import("ast/ast.zig");
pub const dataflow = @import("dataflow/mod.zig");
pub const yaml = @import("yaml/mod.zig");
pub const repository = @import("repository/mod.zig");
pub const network = @import("network/mod.zig");
pub const engine = @import("engine/engine.zig");
pub const engine_network = @import("engine/network.zig");
pub const runner = @import("engine/runner.zig");
pub const host = @import("host/mod.zig");
pub const modules = @import("modules/mod.zig");
pub const loader = modules;
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
pub const ModuleRegistry = modules.ModuleRegistry;
pub const validateManifest = modules.validateManifest;
pub const verifySafeModulePermissions = modules.verifySafeModulePermissions;
pub const LoaderError = modules.LoaderError;
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

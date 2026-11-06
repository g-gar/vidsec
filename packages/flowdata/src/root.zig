const std = @import("std");

pub const abi = @import("abi/mod.zig");
pub const ast = @import("ast/ast.zig");
pub const dataflow = @import("dataflow/mod.zig");
pub const yaml = @import("yaml/mod.zig");
pub const repository = @import("repository/mod.zig");
pub const engine = @import("engine/engine.zig");
pub const runner = @import("engine/runner.zig");
pub const loader = @import("engine/loader/mod.zig");
pub const tracer = @import("engine/tracer.zig");
pub const artifact = @import("engine/artifact.zig");
pub const extensions = @import("extensions/mod.zig");

// Primary Engine Exports
pub const PipelineAST = ast.PipelineAST;
pub const PipelineBuilder = ast.PipelineBuilder;
pub const PipelineEngine = engine.PipelineEngine;
pub const PipelineRunner = runner.PipelineRunner;
pub const RunnerOptions = runner.RunnerOptions;
pub const ModuleRegistry = loader.ModuleRegistry;
pub const validateManifest = loader.validateManifest;
pub const verifySafeModulePermissions = loader.verifySafeModulePermissions;
pub const ExecutionSummary = engine.ExecutionSummary;
pub const StorageRepository = repository.StorageRepository;
pub const RepositoryRegistry = repository.RepositoryRegistry;
pub const PayloadHandle = dataflow.PayloadHandle;

// Artifact exports
pub const ArtifactStore = artifact.ArtifactStore;
pub const ManagedBuffer = artifact.ManagedBuffer;
pub const readFileBytes = runner.readFileBytes;
pub const ArtifactExportSpec = runner.ArtifactExportSpec;

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");

pub const abi_lib = @import("vidsec_abi");
pub const ast = @import("ast.zig");
pub const artifact = @import("artifact.zig");
pub const tracer = @import("tracer.zig");
pub const engine = @import("engine.zig");
pub const runner = @import("runner.zig");
pub const repository = @import("repository/mod.zig");
pub const loader = @import("loader/mod.zig");

// Artifact Store & Managed Buffers
pub const ArtifactError = artifact.ArtifactError;
pub const CarvedItem = artifact.CarvedItem;
pub const ManagedBuffer = artifact.ManagedBuffer;
pub const ArtifactStore = artifact.ArtifactStore;

// Execution Tracer & Telemetry
pub const TraceEvent = tracer.TraceEvent;
pub const DebugAction = tracer.DebugAction;
pub const DebugController = tracer.DebugController;
pub const ExecutionTracer = tracer.ExecutionTracer;

// Engine & Execution Summary
pub const EngineError = engine.EngineError;
pub const ExecutionSummary = engine.ExecutionSummary;
pub const PipelineEngine = engine.PipelineEngine;

// Canonical In-Memory AST & Builder
pub const PipelineAST = ast.PipelineAST;
pub const PipelineBuilder = ast.PipelineBuilder;
pub const StepNode = ast.StepNode;
pub const TaskStepSpec = ast.TaskStepSpec;
pub const RouterStepSpec = ast.RouterStepSpec;
pub const DatasourceSpec = ast.DatasourceSpec;

// Dynamic Module Loader
pub const LoaderError = loader.LoaderError;
pub const LoadedModule = loader.LoadedModule;
pub const ModuleRegistry = loader.ModuleRegistry;
pub const validateManifest = loader.validateManifest;
pub const verifySafeModulePermissions = loader.verifySafeModulePermissions;

// High-level File Runner Utilities
pub const RunnerError = runner.RunnerError;
pub const readFileBytes = runner.readFileBytes;
pub const writeFileBytes = runner.writeFileBytes;

test {
    std.testing.refAllDecls(@This());
}

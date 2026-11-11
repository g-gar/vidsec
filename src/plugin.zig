//! Flowdata Plugin C-ABI & Guest SDK Library (`flowdata_plugin`).
//!
//! Standalone, zero-dependency library defining the C-ABI boundary (`FLOWDATA_ABI_VERSION`),
//! memory-safe streaming readers (`BoundedStreamReader`, `WindowReader`), and compile-time
//! task/manifest builders (`defineTask`, `defineBoundTask`, `definePureTask`, `defineBlackBoxTask`, `defineManifest`).

const std = @import("std");

pub const types = @import("plugin/types/mod.zig");
pub const sdk = @import("plugin/sdk/mod.zig");
pub const reader = @import("plugin/reader/mod.zig");

// Version & Manifest Contract
pub const FLOWDATA_ABI_VERSION = types.FLOWDATA_ABI_VERSION;
pub const ABI_VERSION = types.ABI_VERSION;
pub const MANIFEST_SYMBOL_NAME = types.MANIFEST_SYMBOL_NAME;

// C-ABI Types
pub const SemVer_ABI = types.SemVer_ABI;
pub const ValueTag_ABI = types.ValueTag_ABI;
pub const Slice_ABI = types.Slice_ABI;
pub const ValuePayload_ABI = types.ValuePayload_ABI;
pub const Value_ABI = types.Value_ABI;
pub const NamedField_ABI = types.NamedField_ABI;
pub const WindowView_ABI = types.WindowView_ABI;
pub const RowView_ABI = types.RowView_ABI;
pub const LogLevel_ABI = types.LogLevel_ABI;
pub const HostError_ABI = types.HostError_ABI;
pub const TaskStatus_ABI = types.TaskStatus_ABI;
pub const HostApiVTable_ABI = types.HostApiVTable_ABI;
pub const TaskContext_ABI = types.TaskContext_ABI;
pub const TaskExecuteFn_ABI = types.TaskExecuteFn_ABI;
pub const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
pub const ModuleManifest_ABI = types.ModuleManifest_ABI;
pub const ItemError = types.ItemError;

// Black Box C-ABI Types & Networking ABI
pub const MemContext_ABI = types.MemContext_ABI;
pub const PayloadHandle_ABI = types.PayloadHandle_ABI;
pub const PayloadRepr_ABI = types.PayloadRepr_ABI;
pub const Lowered = types.Lowered;
pub const lowerValue = types.lowerValue;
pub const liftValue = types.liftValue;
pub const schemaId = types.schemaId;
pub const ReflectedTag_ABI = types.ReflectedTag_ABI;
pub const ReflectedValue_ABI = types.ReflectedValue_ABI;
pub const ReflectFn_ABI = types.ReflectFn_ABI;
pub const LogFn_ABI = types.LogFn_ABI;
pub const ExecutionOptions_ABI = types.ExecutionOptions_ABI;
pub const TaskResult_ABI = types.TaskResult_ABI;
pub const TaskFn_ABI = types.TaskFn_ABI;
pub const NetRequest_ABI = types.NetRequest_ABI;
pub const NetResponse_ABI = types.NetResponse_ABI;
pub const NetStreamHandle_ABI = types.NetStreamHandle_ABI;
pub const NetRequestFn_ABI = types.NetRequestFn_ABI;

// Plugin SDK
pub const SdkError = sdk.SdkError;
pub const mapHostError = sdk.mapHostError;
pub const TaskContext = sdk.TaskContext;
pub const ZigTaskSpec = sdk.ZigTaskSpec;
pub const defineTask = sdk.defineTask;
pub const defineManifest = sdk.defineManifest;
pub const injectInputs = sdk.injectInputs;
pub const computeRequiredParams = sdk.computeRequiredParams;
pub const InputInjectorError = sdk.InputInjectorError;
pub const BoundTaskSpec = sdk.BoundTaskSpec;
pub const defineBoundTask = sdk.defineBoundTask;
pub const Logger = sdk.Logger;
pub const PureTaskSpec = sdk.PureTaskSpec;
pub const computeOutputFields = sdk.computeOutputFields;
pub const definePureTask = sdk.definePureTask;
pub const AbiLogger = sdk.AbiLogger;
pub const defineBlackBoxTask = sdk.defineBlackBoxTask;
pub const di = sdk.di;
pub const DiContainer = sdk.DiContainer;
pub const DefaultDiContainer = sdk.DefaultDiContainer;
pub const defineTaskService = sdk.defineTaskService;
pub const EmptyContext = sdk.EmptyContext;
pub const Channels = sdk.Channels;
pub const channels = sdk.channels;
pub const Rows = sdk.Rows;

// Streaming Readers
pub const BoundedStreamReader = reader.BoundedStreamReader;
pub const WindowReader = reader.WindowReader;
pub const ClampedSubRegion = reader.ClampedSubRegion;

test {
    std.testing.refAllDecls(@This());
}

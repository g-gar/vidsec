const std = @import("std");

pub const types = @import("types.zig");
pub const sdk = @import("sdk.zig");
pub const reader = @import("reader.zig");

// Pure C-ABI Type Definitions & Constants
pub const VIDSEC_ABI_VERSION = types.VIDSEC_ABI_VERSION;
pub const MANIFEST_SYMBOL_NAME = types.MANIFEST_SYMBOL_NAME;
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

// Black Box C-ABI Types
pub const MemContext_ABI = types.MemContext_ABI;
pub const PayloadHandle_ABI = types.PayloadHandle_ABI;
pub const ReflectedTag_ABI = types.ReflectedTag_ABI;
pub const ReflectedValue_ABI = types.ReflectedValue_ABI;
pub const ReflectFn_ABI = types.ReflectFn_ABI;
pub const LogFn_ABI = types.LogFn_ABI;
pub const ExecutionOptions_ABI = types.ExecutionOptions_ABI;
pub const TaskResult_ABI = types.TaskResult_ABI;
pub const TaskFn_ABI = types.TaskFn_ABI;

// Pure Plugin SDK & Stream/Window Readers
pub const BoundedStreamReader = reader.BoundedStreamReader;
pub const WindowReader = reader.WindowReader;
pub const ClampedSubRegion = reader.ClampedSubRegion;
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
pub const SdkError = sdk.SdkError;
pub const mapHostError = sdk.mapHostError;

// Modern Black Box Plugin SDK
pub const AbiLogger = sdk.AbiLogger;
pub const defineBlackBoxTask = sdk.defineBlackBoxTask;

test {
    std.testing.refAllDecls(@This());
}

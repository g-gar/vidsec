const sdk_mod = @import("sdk/mod.zig");
const types = @import("types.zig");
pub const reader = @import("reader.zig");

pub const BoundedStreamReader = reader.BoundedStreamReader;
pub const WindowReader = reader.WindowReader;
pub const ClampedSubRegion = reader.ClampedSubRegion;

pub const VIDSEC_ABI_VERSION = types.VIDSEC_ABI_VERSION;
pub const SemVer_ABI = types.SemVer_ABI;
pub const ValueTag_ABI = types.ValueTag_ABI;
pub const Value_ABI = types.Value_ABI;
pub const NamedField_ABI = types.NamedField_ABI;
pub const WindowView_ABI = types.WindowView_ABI;
pub const RowView_ABI = types.RowView_ABI;
pub const LogLevel_ABI = types.LogLevel_ABI;
pub const HostError_ABI = types.HostError_ABI;
pub const TaskStatus_ABI = types.TaskStatus_ABI;
pub const TaskContext_ABI = types.TaskContext_ABI;
pub const TaskDescriptor_ABI = types.TaskDescriptor_ABI;
pub const ModuleManifest_ABI = types.ModuleManifest_ABI;

pub const SdkError = sdk_mod.SdkError;
pub const mapHostError = sdk_mod.mapHostError;
pub const TaskContext = sdk_mod.TaskContext;
pub const ZigTaskSpec = sdk_mod.ZigTaskSpec;
pub const defineTask = sdk_mod.defineTask;
pub const defineManifest = sdk_mod.defineManifest;
pub const input_injector = sdk_mod.input_injector;
pub const injectInputs = sdk_mod.injectInputs;
pub const computeRequiredParams = sdk_mod.computeRequiredParams;
pub const InputInjectorError = sdk_mod.InputInjectorError;
pub const BoundTaskSpec = sdk_mod.BoundTaskSpec;
pub const defineBoundTask = sdk_mod.defineBoundTask;

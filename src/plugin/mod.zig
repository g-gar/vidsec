//! Unified Flowdata Plugin System (`src/plugin/mod.zig`).
//! Combines the Guest C-ABI & SDK (`flowdata_plugin`) with the Host dynamic `.so` loader and C-ABI executor (`loader/`).

pub const abi = @import("flowdata_plugin");
pub const types = abi.types;
pub const sdk = abi.sdk;
pub const reader = abi.reader;

pub const loader_error = @import("loader/loader_error.zig");
pub const validate_manifest = @import("loader/validate_manifest.zig");
pub const verify_safe_module_permissions = @import("loader/verify_safe_module_permissions.zig");
pub const loaded_module = @import("loader/loaded_module.zig");
pub const module_registry = @import("loader/module_registry.zig");
pub const task_executor = @import("loader/task_executor.zig");

// Host Loader & Executor Exports
pub const LoaderError = loader_error.LoaderError;
pub const validateManifest = validate_manifest.validateManifest;
pub const verifySafeModulePermissions = verify_safe_module_permissions.verifySafeModulePermissions;
pub const LoadedModule = loaded_module.LoadedModule;
pub const LoadedPlugin = loaded_module.LoadedModule;
pub const ModuleRegistry = module_registry.ModuleRegistry;
pub const PluginRegistry = module_registry.ModuleRegistry;

pub const TaskOutcomeStatus = task_executor.TaskOutcomeStatus;
pub const TaskExecutionOutcome = task_executor.TaskExecutionOutcome;
pub const NetworkBridge = task_executor.NetworkBridge;
pub const TaskExecutionRequest = task_executor.TaskExecutionRequest;
pub const executeTask = task_executor.executeTask;
pub const fromAbiPayload = task_executor.fromAbiPayload;
pub const toAbiPayload = task_executor.toAbiPayload;
pub const reflectAbiBridge = task_executor.reflectAbiBridge;

// Guest C-ABI & SDK Re-exports
pub const FLOWDATA_ABI_VERSION = abi.FLOWDATA_ABI_VERSION;
pub const ABI_VERSION = abi.ABI_VERSION;
pub const MANIFEST_SYMBOL_NAME = abi.MANIFEST_SYMBOL_NAME;
pub const SemVer_ABI = abi.SemVer_ABI;
pub const ValueTag_ABI = abi.ValueTag_ABI;
pub const Slice_ABI = abi.Slice_ABI;
pub const ValuePayload_ABI = abi.ValuePayload_ABI;
pub const Value_ABI = abi.Value_ABI;
pub const NamedField_ABI = abi.NamedField_ABI;
pub const WindowView_ABI = abi.WindowView_ABI;
pub const RowView_ABI = abi.RowView_ABI;
pub const LogLevel_ABI = abi.LogLevel_ABI;
pub const HostError_ABI = abi.HostError_ABI;
pub const TaskStatus_ABI = abi.TaskStatus_ABI;
pub const HostApiVTable_ABI = abi.HostApiVTable_ABI;
pub const TaskContext_ABI = abi.TaskContext_ABI;
pub const TaskExecuteFn_ABI = abi.TaskExecuteFn_ABI;
pub const TaskDescriptor_ABI = abi.TaskDescriptor_ABI;
pub const ModuleManifest_ABI = abi.ModuleManifest_ABI;
pub const MemContext_ABI = abi.MemContext_ABI;
pub const PayloadHandle_ABI = abi.PayloadHandle_ABI;
pub const ReflectedTag_ABI = abi.ReflectedTag_ABI;
pub const ReflectedValue_ABI = abi.ReflectedValue_ABI;
pub const ReflectFn_ABI = abi.ReflectFn_ABI;
pub const LogFn_ABI = abi.LogFn_ABI;
pub const ExecutionOptions_ABI = abi.ExecutionOptions_ABI;
pub const TaskResult_ABI = abi.TaskResult_ABI;
pub const TaskFn_ABI = abi.TaskFn_ABI;
pub const NetRequest_ABI = abi.NetRequest_ABI;
pub const NetResponse_ABI = abi.NetResponse_ABI;
pub const NetStreamHandle_ABI = abi.NetStreamHandle_ABI;
pub const NetRequestFn_ABI = abi.NetRequestFn_ABI;
pub const SdkError = abi.SdkError;
pub const mapHostError = abi.mapHostError;
pub const TaskContext = abi.TaskContext;
pub const ZigTaskSpec = abi.ZigTaskSpec;
pub const defineTask = abi.defineTask;
pub const defineManifest = abi.defineManifest;
pub const injectInputs = abi.injectInputs;
pub const computeRequiredParams = abi.computeRequiredParams;
pub const InputInjectorError = abi.InputInjectorError;
pub const BoundTaskSpec = abi.BoundTaskSpec;
pub const defineBoundTask = abi.defineBoundTask;
pub const Logger = abi.Logger;
pub const PureTaskSpec = abi.PureTaskSpec;
pub const computeOutputFields = abi.computeOutputFields;
pub const definePureTask = abi.definePureTask;
pub const AbiLogger = abi.AbiLogger;
pub const defineBlackBoxTask = abi.defineBlackBoxTask;
pub const di = abi.di;
pub const DiContainer = abi.DiContainer;
pub const DefaultDiContainer = abi.DefaultDiContainer;
pub const defineTaskService = abi.defineTaskService;
pub const EmptyContext = abi.EmptyContext;
pub const BoundedStreamReader = abi.BoundedStreamReader;
pub const WindowReader = abi.WindowReader;
pub const ClampedSubRegion = abi.ClampedSubRegion;

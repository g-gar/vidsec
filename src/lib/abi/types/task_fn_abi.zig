const MemContext_ABI = @import("mem_context_abi.zig").MemContext_ABI;
const PayloadHandle_ABI = @import("payload_handle_abi.zig").PayloadHandle_ABI;
const ExecutionOptions_ABI = @import("execution_options_abi.zig").ExecutionOptions_ABI;
const TaskResult_ABI = @import("task_result_abi.zig").TaskResult_ABI;

/// Entrypoint function signature for a pure Black Box task implementation inside a plugin.
/// Takes input memory context, input payload handle, and execution options, returning a TaskResult_ABI.
pub const TaskFn_ABI = *const fn (
    mem: *const MemContext_ABI,
    in_payload: PayloadHandle_ABI,
    options: ExecutionOptions_ABI,
) callconv(.c) TaskResult_ABI;

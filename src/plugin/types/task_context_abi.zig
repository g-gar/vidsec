const FLOWDATA_ABI_VERSION = @import("abi_version.zig").FLOWDATA_ABI_VERSION;
const HostApiVTable_ABI = @import("host_api_vtable_abi.zig").HostApiVTable_ABI;

/// Opaque execution context passed to every plugin task invocation.
pub const TaskContext_ABI = extern struct {
    abi_version: u32 = FLOWDATA_ABI_VERSION,
    opaque_host_state: *anyopaque,
    host: *const HostApiVTable_ABI,
};

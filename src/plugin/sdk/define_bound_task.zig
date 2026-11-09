const std = @import("std");
const types = @import("../types/mod.zig");
const define_task = @import("define_task.zig");

const TaskDescriptor_ABI = types.TaskDescriptor_ABI;

/// Backwards compatible wrapper for `defineTask`.
/// If called with `(Inputs, spec)`, `Inputs` is ignored and deduced automatically from `spec.run`.
pub fn defineBoundTask(comptime Inputs: type, comptime spec: anytype) TaskDescriptor_ABI {
    _ = Inputs;
    return define_task.defineTask(spec);
}

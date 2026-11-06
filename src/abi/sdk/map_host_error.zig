const types = @import("../types/mod.zig");
const SdkError = @import("sdk_error.zig").SdkError;

pub fn mapHostError(err: types.HostError_ABI) SdkError!void {
    return switch (err) {
        .ok => {},
        .end_of_stream => error.UnexpectedHostError,
        .out_of_bounds => error.OutOfBounds,
        .invalid_argument => error.InvalidArgument,
        .not_found => error.NotFound,
        .io_error => error.IoError,
        .db_constraint_error => error.DbConstraintError,
        .permission_denied => error.PermissionDenied,
        .out_of_memory => error.OutOfMemory,
    };
}

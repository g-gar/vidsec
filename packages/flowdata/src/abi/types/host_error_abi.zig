/// Status / error codes returned by Host VTable callbacks.
pub const HostError_ABI = enum(u32) {
    ok = 0,
    end_of_stream = 1,
    out_of_bounds = 2,
    invalid_argument = 3,
    not_found = 4,
    io_error = 5,
    db_constraint_error = 6,
    permission_denied = 7,
    out_of_memory = 8,
};

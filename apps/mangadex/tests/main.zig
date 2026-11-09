const std = @import("std");

test {
    _ = @import("env_config_test.zig");
    _ = @import("auth_test.zig");
    _ = @import("adapter_integration_test.zig");
    _ = @import("query_and_types_test.zig");
    _ = @import("client_endpoints_test.zig");
    _ = @import("source_adaptation_test.zig");
}

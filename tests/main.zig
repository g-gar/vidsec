const std = @import("std");

test {
    _ = @import("core/abi_test.zig");
    _ = @import("core/loader_test.zig");
    _ = @import("core/pipeline_test.zig");
    _ = @import("core/artifact_test.zig");
    _ = @import("core/dataflow_test.zig");
    _ = @import("core/pipeline_yaml_ast_test.zig");
    _ = @import("core/network_test.zig");
    _ = @import("core/host_transport_test.zig");
}

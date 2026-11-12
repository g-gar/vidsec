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
    _ = @import("core/kernel_extension_test.zig");
    _ = @import("core/otel_extension_test.zig");
    _ = @import("core/dag_viz_extension_test.zig");
    _ = @import("core/bifurcation_multichannel_test.zig");
    _ = @import("core/concurrency_contract_test.zig");
    _ = @import("core/execution_plan_test.zig");
    _ = @import("core/dag_scheduler_test.zig");
    _ = @import("core/reactive_dispatch_test.zig");
}

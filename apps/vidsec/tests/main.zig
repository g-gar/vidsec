const std = @import("std");

test {
    _ = @import("triage/triage_tasks_test.zig");
    _ = @import("remediation/remediation_tasks_test.zig");
    _ = @import("containers/container_tasks_test.zig");
}

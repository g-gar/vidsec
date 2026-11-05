const std = @import("std");

test {
    // End-to-end integration tests (will be migrated to Black Box in Phase 5)
    // _ = @import("pipeline_e2e_test.zig");

    // Format parser tests
    _ = @import("formats/formats_common_test.zig");
    _ = @import("formats/isobmff_test.zig");
    _ = @import("formats/mp4_test.zig");
    _ = @import("formats/ebml_test.zig");
    _ = @import("formats/mkv_test.zig");
    _ = @import("formats/riff_test.zig");

    // Core library tests
    _ = @import("lib/abi_test.zig");
    _ = @import("lib/magic_test.zig");
    _ = @import("lib/math_test.zig");
    _ = @import("lib/ir_domain_test.zig");
    _ = @import("lib/forensics_domain_test.zig");
    // Core pipeline & artifact tests
    _ = @import("core/loader_test.zig");
    _ = @import("core/pipeline_test.zig");
    _ = @import("core/artifact_test.zig");
    _ = @import("core/dataflow_test.zig");
    _ = @import("core/pipeline_yaml_ast_test.zig");

    // Plugin domain tests
    _ = @import("plugins/analyzer_test.zig");
}

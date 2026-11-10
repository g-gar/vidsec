const std = @import("std");

test {
    _ = @import("env_config_test.zig");
    _ = @import("auth_test.zig");
    _ = @import("adapter_integration_test.zig");
    _ = @import("query_and_types_test.zig");
    _ = @import("client_endpoints_test.zig");
    _ = @import("source_adaptation_test.zig");
    _ = @import("catalog_plugin_test.zig");
    _ = @import("pipeline_config_test.zig");
    _ = @import("komga_test.zig");
    _ = @import("zip_archive_test.zig");
    _ = @import("comicinfo_test.zig");
    _ = @import("sources");
}

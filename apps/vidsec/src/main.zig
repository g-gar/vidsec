const std = @import("std");
const vidsec = @import("vidsec");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !u8 {
    return vidsec.host.HostApp.runCliEntry(init, .{
        .app_name = "vidsec",
        .description = "Declarative Multimedia Security & Transformation Engine",
        .version = build_options.version_string,
        .driver_initializer = &vidsec.extensions.datasources.registerDefaultDrivers,
        .extensions = &.{
            vidsec.extensions.inbound_cli.extension,
            vidsec.extensions.inbound_http.extension,
            vidsec.extensions.inbound_grpc.extension,
        },
    });
}

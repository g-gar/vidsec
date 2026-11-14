const flowdata = @import("flowdata");
const app = @import("mangadex_app");

pub const manifest = app.manifest;

comptime {
    @export(&manifest, .{ .name = flowdata.plugin.MANIFEST_SYMBOL_NAME, .linkage = .strong });
}


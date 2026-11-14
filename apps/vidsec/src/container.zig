const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("flowdata_abi");

pub const VidsecContext = struct {
    logger: abi.Logger,

    pub fn init(self: *VidsecContext, alloc: Allocator, ctx: abi.TaskContext) !void {
        _ = alloc;
        self.* = .{
            .logger = abi.Logger.init(ctx.raw),
        };
    }

    pub fn deinit(self: *VidsecContext) void {
        _ = self;
    }
};

pub const VidsecPluginContainer = abi.DiContainer(VidsecContext);

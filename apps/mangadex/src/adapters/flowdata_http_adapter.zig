const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const OutboundAdapter = flowdata.transport.outbound.OutboundAdapter;
const sdk = @import("mangadex_sdk");

pub const FlowdataHttpAdapter = struct {
    adapter: OutboundAdapter,

    comptime {
        sdk.HttpTransport.assertImplements(@This());
    }

    pub fn init(adapter: OutboundAdapter) FlowdataHttpAdapter {
        return .{ .adapter = adapter };
    }

    pub fn httpTransport(self: *FlowdataHttpAdapter) sdk.HttpTransport {
        return .{
            .ptr = self,
            .vtable = &.{ .execute = executeBridge },
        };
    }

    fn executeBridge(
        ctx: *anyopaque,
        allocator: Allocator,
        method: sdk.HttpMethod,
        url: []const u8,
        headers: []const sdk.HttpHeader,
        body: []const u8,
    ) sdk.HttpTransportError!sdk.HttpResponse {
        const self: *FlowdataHttpAdapter = @ptrCast(@alignCast(ctx));

        var flow_headers = std.ArrayListUnmanaged(flowdata.transport.outbound.HttpHeader).empty;
        defer flow_headers.deinit(allocator);
        for (headers) |h| {
            flow_headers.append(allocator, .{
                .name = h.name,
                .value = h.value,
            }) catch return error.OutOfMemory;
        }

        const res = self.adapter.execute(
            url,
            method.asText(),
            flow_headers.items,
            body,
            "mangadex.request",
        ) catch |err| return switch (err) {
            error.NetworkRateLimited => error.RateLimited,
            error.NetworkAcquireTimeout => error.Timeout,
            error.InvalidUri => error.InvalidUrl,
            error.OutOfMemory => error.OutOfMemory,
            else => error.NetworkFailure,
        };

        return .{
            .status_code = res.status_code,
            .body = res.body,
            .retry_after_ms = res.retry_after_ms,
        };
    }
};

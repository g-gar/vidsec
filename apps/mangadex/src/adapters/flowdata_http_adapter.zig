const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const OutboundAdapter = flowdata.transport.outbound.OutboundAdapter;
const sdk = @import("mangadex_sdk");

pub const FlowdataHttpAdapter = struct {
    backend: Backend,

    pub const Backend = union(enum) {
        adapter: OutboundAdapter,
        task_ctx: flowdata.plugin.TaskContext,
    };

    comptime {
        sdk.HttpTransport.assertImplements(@This());
    }

    pub fn init(adapter: OutboundAdapter) FlowdataHttpAdapter {
        return .{ .backend = .{ .adapter = adapter } };
    }

    pub fn fromTaskContext(ctx: flowdata.plugin.TaskContext) FlowdataHttpAdapter {
        return .{ .backend = .{ .task_ctx = ctx } };
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

        switch (self.backend) {
            .adapter => |adapter| {
                var flow_headers = std.ArrayListUnmanaged(flowdata.transport.outbound.HttpHeader).empty;
                defer flow_headers.deinit(allocator);
                for (headers) |h| {
                    flow_headers.append(allocator, .{
                        .name = h.name,
                        .value = h.value,
                    }) catch return error.OutOfMemory;
                }

                const res = adapter.execute(
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
            },
            .task_ctx => |task_ctx| {
                var fields = std.ArrayListUnmanaged(flowdata.plugin.NamedField_ABI).empty;
                defer {
                    for (fields.items) |f| allocator.free(std.mem.span(f.name_ptr));
                    fields.deinit(allocator);
                }
                for (headers) |h| {
                    const name_z = allocator.dupeZ(u8, h.name) catch return error.OutOfMemory;
                    fields.append(allocator, flowdata.plugin.NamedField_ABI.init(
                        name_z,
                        flowdata.plugin.Value_ABI.fromText(h.value),
                    )) catch {
                        allocator.free(name_z);
                        return error.OutOfMemory;
                    };
                }

                const res = task_ctx.netRequest(.{
                    .url = flowdata.plugin.Slice_ABI.fromSlice(url),
                    .operation = flowdata.plugin.Slice_ABI.fromSlice(method.asText()),
                    .headers_ptr = if (fields.items.len > 0) fields.items.ptr else null,
                    .headers_len = fields.items.len,
                    .body = flowdata.plugin.Slice_ABI.fromSlice(body),
                }) catch |err| {
                    task_ctx.logErrorFmt("netRequest failed for {s} '{s}': {s}", .{ method.asText(), url, @errorName(err) });
                    return switch (err) {
                        error.NetworkRateLimited => error.RateLimited,
                        error.NetworkAcquireTimeout => error.Timeout,
                        error.InvalidArgument => error.InvalidUrl,
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.NetworkFailure,
                    };
                };

                task_ctx.logInfoFmt("HTTP {s} {s} => status={d} len={d}", .{ method.asText(), url, res.status_code, res.body.toSlice().len });
                if (res.status_code >= 400) {
                    task_ctx.logWarnFmt("HTTP error body: {s}", .{ res.body.toSlice() });
                }

                return .{
                    .status_code = res.status_code,
                    .body = res.body.toSlice(),
                    .retry_after_ms = 0,
                };
            },
        }
    }
};

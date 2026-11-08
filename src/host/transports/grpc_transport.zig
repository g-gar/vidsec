const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");

pub const HostTransport = contracts.HostTransport;
pub const InvocationRequest = contracts.InvocationRequest;
pub const InvocationResponse = contracts.InvocationResponse;
pub const InvocationCommand = contracts.InvocationCommand;
pub const OutputFormat = contracts.OutputFormat;

/// gRPC Wire Transport implementation for Flowdata pipelines.
/// Implements standard gRPC 5-byte framing (`[compressed: 1B][length: 4B BE]`) and dispatches
/// RPCs against the `flowdata.v2.PipelineService` contract.
pub const GrpcTransport = struct {
    comptime {
        HostTransport.assertImplements(@This());
    }

    allocator: Allocator,
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 50051,
    default_pipeline_path: []const u8 = "",

    pub fn init(
        allocator: Allocator,
        listen_host: []const u8,
        listen_port: u16,
        default_pipeline_path: []const u8,
    ) GrpcTransport {
        return .{
            .allocator = allocator,
            .listen_host = listen_host,
            .listen_port = listen_port,
            .default_pipeline_path = default_pipeline_path,
        };
    }

    pub fn hostTransport(self: *GrpcTransport) HostTransport {
        const Trampoline = struct {
            fn doName(_: *const anyopaque) []const u8 {
                return "grpc";
            }

            fn doServe(
                _: *anyopaque,
                _: contracts.HostDispatcherPtr,
                _: contracts.DispatchFn,
            ) anyerror!u8 {
                return 0;
            }

            fn doDeinit(ctx: *anyopaque, allocator: Allocator) void {
                const s: *GrpcTransport = @ptrCast(@alignCast(ctx));
                allocator.destroy(s);
            }

            const vtable = HostTransport.VTable{
                .name = &doName,
                .serve = &doServe,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }

    /// Encodes a payload into a standard gRPC 5-byte prefixed binary frame.
    pub fn encodeGrpcFrame(allocator: Allocator, payload: []const u8) ![]u8 {
        const buf = try allocator.alloc(u8, 5 + payload.len);
        buf[0] = 0x00; // Not compressed
        std.mem.writeInt(u32, buf[1..5], @intCast(payload.len), .big);
        @memcpy(buf[5..], payload);
        return buf;
    }

    /// Decodes a standard gRPC 5-byte prefixed binary frame into its payload slice.
    pub fn decodeGrpcFrame(frame_bytes: []const u8) ![]const u8 {
        if (frame_bytes.len < 5) return error.MalformedGrpcFrame;
        const msg_len = std.mem.readInt(u32, frame_bytes[1..5], .big);
        if (frame_bytes.len < 5 + msg_len) return error.MalformedGrpcFrame;
        return frame_bytes[5 .. 5 + msg_len];
    }

    /// Processes an incoming gRPC service call (`/flowdata.v2.PipelineService/Run`, etc.),
    /// decodes the message frame, delegates to `HostDispatcher`, and returns an encoded gRPC response frame.
    pub fn handleGrpcCall(
        self: *GrpcTransport,
        allocator: Allocator,
        method_path: []const u8,
        raw_frame: []const u8,
        dispatcher_ctx: contracts.HostDispatcherPtr,
        dispatch_fn: contracts.DispatchFn,
    ) anyerror![]u8 {
        const payload = try decodeGrpcFrame(raw_frame);

        if (std.mem.endsWith(u8, method_path, "/Health")) {
            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .health,
                .format = .json,
                .options = .{ .pipeline_yaml_path = self.default_pipeline_path },
            });
            return try encodeGrpcFrame(allocator, resp.output_bytes);
        }

        if (std.mem.endsWith(u8, method_path, "/Validate")) {
            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .validate,
                .format = .json,
                .options = .{ .pipeline_yaml_path = self.default_pipeline_path },
            });
            return try encodeGrpcFrame(allocator, resp.output_bytes);
        }

        if (std.mem.endsWith(u8, method_path, "/Run")) {
            const input_source: contracts.InputSource = if (payload.len > 0)
                .{ .memory_bytes = payload }
            else
                .none;

            const resp = try dispatch_fn(dispatcher_ctx, .{
                .command = .run,
                .format = .json,
                .options = .{ .pipeline_yaml_path = self.default_pipeline_path },
                .input = input_source,
            });
            return try encodeGrpcFrame(allocator, resp.output_bytes);
        }

        return error.UnknownGrpcMethod;
    }
};

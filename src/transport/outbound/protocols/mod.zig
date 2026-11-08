const contracts = @import("../contracts/mod.zig");
pub const posix_socket = @import("../../common/posix_socket.zig");
pub const http_transport = @import("http_transport.zig");
pub const stream_transport = @import("stream_transport.zig");
pub const mock_sinkhole_transport = @import("mock_sinkhole_transport.zig");

pub const PosixSocket = posix_socket.PosixSocket;
pub const HttpTransport = http_transport.HttpTransport;
pub const HttpParsedResponse = http_transport.HttpParsedResponse;
pub const StreamTransport = stream_transport.StreamTransport;
pub const StreamSession = stream_transport.StreamSession;
pub const StreamSessionTable = stream_transport.StreamSessionTable;
pub const MockSinkholeTransport = mock_sinkhole_transport.MockSinkholeTransport;

pub fn registerDefaultTransports(reg: *contracts.TransportRegistry) !void {
    try reg.registerTransport(try HttpTransport.createHeap(reg.allocator));
    try reg.registerTransport(try StreamTransport.createHeap(reg.allocator));
}

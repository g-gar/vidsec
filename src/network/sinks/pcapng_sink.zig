const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts/mod.zig");
const PacketSink = contracts.PacketSink;
const NetExchange = contracts.NetExchange;
const NetResult = contracts.NetResult;

/// Wireshark-compatible IETF PCAPNG binary packet sink (`SHB`, `IDB`, `DSB` TLS secrets, and `EPB` frames).
/// Implements the polymorphic `PacketSink` VTable.
pub const PcapngSink = struct {
    comptime {
        PacketSink.assertImplements(@This());
    }

    pub const BLOCK_TYPE_SHB: u32 = 0x0A0D0D0A;
    pub const BLOCK_TYPE_IDB: u32 = 0x00000001;
    pub const BLOCK_TYPE_EPB: u32 = 0x00000006;
    pub const BLOCK_TYPE_DSB: u32 = 0x0000000A;

    pub const BYTE_ORDER_MAGIC: u32 = 0x1A2B3C4D;
    pub const LINKTYPE_RAW: u16 = 101;
    pub const TLS_KEY_LOG_MAGIC: u32 = 0x544c534b; // "TLSK"

    pub const OPT_ENDOFOPT: u16 = 0;
    pub const OPT_COMMENT: u16 = 1;
    pub const IDB_OPT_IF_NAME: u16 = 2;

    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    snaplen: u32 = 65535,
    interface_id: u32 = 0,
    packets_written: usize = 0,

    pub fn init(allocator: Allocator, adapter_name: []const u8, snaplen: u32, include_tls_keys: bool) !PcapngSink {
        var self = PcapngSink{
            .allocator = allocator,
            .snaplen = if (snaplen == 0) 65535 else snaplen,
        };
        errdefer self.deinitInternal();
        try self.writeSectionHeaderBlock();
        self.interface_id = try self.registerInterface(adapter_name);
        if (include_tls_keys) {
            try self.writeDecryptionSecretsBlock("CLIENT_RANDOM 0001020304050607 08090a0b0c0d0e0f\n");
        }
        return self;
    }

    pub fn deinitInternal(self: *PcapngSink) void {
        self.buf.deinit(self.allocator);
    }

    pub fn bytes(self: *const PcapngSink) []const u8 {
        return self.buf.items;
    }

    pub fn writeSectionHeaderBlock(self: *PcapngSink) !void {
        const block_total_len: u32 = 28;
        try self.appendU32(BLOCK_TYPE_SHB);
        try self.appendU32(block_total_len);
        try self.appendU32(BYTE_ORDER_MAGIC);
        try self.appendU16(1);
        try self.appendU16(0);
        try self.appendU64(0xFFFFFFFFFFFFFFFF);
        try self.appendU32(block_total_len);
    }

    pub fn registerInterface(self: *PcapngSink, adapter_name: []const u8) !u32 {
        const name_padded_len = align4(adapter_name.len);
        const options_len: u32 = if (adapter_name.len > 0)
            @intCast(4 + name_padded_len + 4)
        else
            0;

        const block_total_len: u32 = 20 + options_len;
        try self.appendU32(BLOCK_TYPE_IDB);
        try self.appendU32(block_total_len);
        try self.appendU16(LINKTYPE_RAW);
        try self.appendU16(0);
        try self.appendU32(self.snaplen);

        if (adapter_name.len > 0) {
            try self.writeOption(IDB_OPT_IF_NAME, adapter_name);
            try self.writeEndOfOptions();
        }

        try self.appendU32(block_total_len);
        return 0;
    }

    pub fn writeDecryptionSecretsBlock(self: *PcapngSink, keylog_line: []const u8) !void {
        const secrets_padded_len = align4(keylog_line.len);
        const block_total_len: u32 = @intCast(20 + secrets_padded_len);

        try self.appendU32(BLOCK_TYPE_DSB);
        try self.appendU32(block_total_len);
        try self.appendU32(TLS_KEY_LOG_MAGIC);
        try self.appendU32(@intCast(keylog_line.len));
        try self.buf.appendSlice(self.allocator, keylog_line);
        try self.writeZeroPad(secrets_padded_len - keylog_line.len);
        try self.appendU32(block_total_len);
    }

    pub fn onExchange(self: *PcapngSink, exchange: *const NetExchange, result: *const NetResult) !void {
        var comment_buf: [256]u8 = undefined;
        const comment = if (exchange.trace_tag.len > 0)
            (std.fmt.bufPrint(
                &comment_buf,
                "{s} proxy={s} verdict={s}",
                .{
                    exchange.trace_tag,
                    if (result.proxy_used.len > 0) result.proxy_used else "direct",
                    result.verdict.asText(),
                },
            ) catch "flowdata_pkt")
        else
            (std.fmt.bufPrint(
                &comment_buf,
                "adapter={s} proxy={s} verdict={s}",
                .{
                    exchange.adapter_id,
                    if (result.proxy_used.len > 0) result.proxy_used else "direct",
                    result.verdict.asText(),
                },
            ) catch "flowdata_pkt");

        var pkt_buf: [512]u8 = undefined;
        const l7_payload = if (result.wire_response.len > 0)
            result.wire_response
        else if (result.body.len > 0)
            result.body
        else if (result.wire_request.len > 0)
            result.wire_request
        else if (exchange.req_body.len > 0)
            exchange.req_body
        else
            (std.fmt.bufPrint(
                &pkt_buf,
                "{s} {s} ({s})\r\nHost: {s}\r\n\r\n",
                .{ exchange.operation, exchange.uri.resource, exchange.uri.scheme, exchange.uri.host },
            ) catch "");

        try self.writeCapturedPacket(
            self.interface_id,
            exchange.now_ms,
            .{ 10, 254, 0, 2 },
            .{ 104, 18, 40, 10 },
            50000 + @as(u16, @truncate(self.packets_written % 10000)),
            exchange.uri.port,
            l7_payload,
            comment,
        );
        exchange.metrics.packets_captured = self.packets_written;
    }

    pub fn writeCapturedPacket(
        self: *PcapngSink,
        interface_id: u32,
        timestamp_ms: u64,
        src_ip: [4]u8,
        dst_ip: [4]u8,
        src_port: u16,
        dst_port: u16,
        l7_payload: []const u8,
        comment: []const u8,
    ) !void {
        const ip_tcp_hdr_len: usize = 40;
        const orig_pkt_len: u32 = @intCast(ip_tcp_hdr_len + l7_payload.len);
        const captured_pkt_len: u32 = @min(orig_pkt_len, self.snaplen);
        const captured_l7_len: usize = if (captured_pkt_len > ip_tcp_hdr_len)
            captured_pkt_len - ip_tcp_hdr_len
        else
            0;

        const pkt_padded_len = align4(captured_pkt_len);
        const comment_padded_len = align4(comment.len);
        const options_len: u32 = if (comment.len > 0)
            @intCast(4 + comment_padded_len + 4)
        else
            0;

        const block_total_len: u32 = @intCast(32 + pkt_padded_len + options_len);
        const ts_us: u64 = timestamp_ms * 1000;
        const ts_high: u32 = @truncate(ts_us >> 32);
        const ts_low: u32 = @truncate(ts_us);

        try self.appendU32(BLOCK_TYPE_EPB);
        try self.appendU32(block_total_len);
        try self.appendU32(interface_id);
        try self.appendU32(ts_high);
        try self.appendU32(ts_low);
        try self.appendU32(captured_pkt_len);
        try self.appendU32(orig_pkt_len);

        var hdr: [40]u8 = @splat(0);
        hdr[0] = 0x45;
        std.mem.writeInt(u16, hdr[2..4], @truncate(orig_pkt_len), .big);
        hdr[8] = 64;
        hdr[9] = 6;
        @memcpy(hdr[12..16], &src_ip);
        @memcpy(hdr[16..20], &dst_ip);

        std.mem.writeInt(u16, hdr[20..22], src_port, .big);
        std.mem.writeInt(u16, hdr[22..24], dst_port, .big);
        std.mem.writeInt(u32, hdr[24..28], 1, .big);
        std.mem.writeInt(u32, hdr[28..32], 1, .big);
        hdr[32] = 0x50;
        hdr[33] = 0x18;
        std.mem.writeInt(u16, hdr[34..36], 65535, .big);

        const hdr_bytes_to_write = @min(ip_tcp_hdr_len, captured_pkt_len);
        try self.buf.appendSlice(self.allocator, hdr[0..hdr_bytes_to_write]);
        if (captured_l7_len > 0) {
            try self.buf.appendSlice(self.allocator, l7_payload[0..captured_l7_len]);
        }
        try self.writeZeroPad(pkt_padded_len - captured_pkt_len);

        if (comment.len > 0) {
            try self.writeOption(OPT_COMMENT, comment);
            try self.writeEndOfOptions();
        }

        try self.appendU32(block_total_len);
        self.packets_written += 1;
    }

    pub fn packetSink(self: *PcapngSink) PacketSink {
        const Trampoline = struct {
            fn doOnExchange(ctx: *anyopaque, exchange: *const NetExchange, result: *const NetResult) anyerror!void {
                const s: *PcapngSink = @ptrCast(@alignCast(ctx));
                try s.onExchange(exchange, result);
            }

            fn doOnTlsSecret(ctx: *anyopaque, keylog_line: []const u8) anyerror!void {
                const s: *PcapngSink = @ptrCast(@alignCast(ctx));
                try s.writeDecryptionSecretsBlock(keylog_line);
            }

            fn doDeinit(ctx: *anyopaque, _: Allocator) void {
                const s: *PcapngSink = @ptrCast(@alignCast(ctx));
                s.deinitInternal();
            }

            const vtable = PacketSink.VTable{
                .onExchange = &doOnExchange,
                .onTlsSecret = &doOnTlsSecret,
                .deinit = &doDeinit,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }

    fn writeOption(self: *PcapngSink, code: u16, value: []const u8) !void {
        const padded = align4(value.len);
        try self.appendU16(code);
        try self.appendU16(@intCast(value.len));
        try self.buf.appendSlice(self.allocator, value);
        try self.writeZeroPad(padded - value.len);
    }

    fn writeEndOfOptions(self: *PcapngSink) !void {
        try self.appendU16(OPT_ENDOFOPT);
        try self.appendU16(0);
    }

    fn writeZeroPad(self: *PcapngSink, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.buf.append(self.allocator, 0);
        }
    }

    fn appendU16(self: *PcapngSink, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    fn appendU32(self: *PcapngSink, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    fn appendU64(self: *PcapngSink, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    fn align4(len: usize) usize {
        return (len + 3) & ~@as(usize, 3);
    }
};

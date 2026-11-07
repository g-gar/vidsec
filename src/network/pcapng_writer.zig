const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PCAPNG_BLOCK_SHB: u32 = 0x0A0D0D0A;
pub const PCAPNG_BLOCK_IDB: u32 = 0x00000001;
pub const PCAPNG_BLOCK_EPB: u32 = 0x00000006;
pub const PCAPNG_BLOCK_DSB: u32 = 0x0000000A;

pub const PCAPNG_BYTE_ORDER_MAGIC: u32 = 0x1A2B3C4D;
pub const LINKTYPE_RAW: u16 = 101; // Raw IPv4/IPv6 packet (dissected directly by Wireshark)
pub const TLS_KEY_LOG_SECRETS_TYPE: u32 = 0x544C534B; // "TLSK"

pub const OPT_ENDOFOPT: u16 = 0;
pub const OPT_COMMENT: u16 = 1;
pub const OPT_IF_NAME: u16 = 2;

/// Zero-Privilege IETF PCAPNG Serializer for Wireshark Forensic Inspection.
/// Supports multi-interface `IDB` blocks (one per Virtual Network Adapter),
/// `EPB` blocks with pipeline `step_id` comments, and embedded `DSB` TLS key logs.
pub const PcapngWriter = struct {
    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    snaplen: u32 = 65535,
    interfaces_count: u32 = 0,
    packets_written: usize = 0,

    pub fn init(allocator: Allocator, snaplen: u32) !PcapngWriter {
        var self = PcapngWriter{
            .allocator = allocator,
            .snaplen = if (snaplen == 0) 65535 else snaplen,
        };
        try self.writeSectionHeaderBlock();
        return self;
    }

    pub fn deinit(self: *PcapngWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn bytes(self: *const PcapngWriter) []const u8 {
        return self.buf.items;
    }

    /// Writes the Section Header Block (`SHB` - `0x0A0D0D0A`).
    fn writeSectionHeaderBlock(self: *PcapngWriter) !void {
        const total_len: u32 = 28;
        try self.appendU32Le(PCAPNG_BLOCK_SHB);
        try self.appendU32Le(total_len);
        try self.appendU32Le(PCAPNG_BYTE_ORDER_MAGIC);
        try self.appendU16Le(1); // Major version 1
        try self.appendU16Le(0); // Minor version 0
        try self.appendU64Le(0xFFFFFFFFFFFFFFFF); // Unspecified section length
        try self.appendU32Le(total_len);
    }

    /// Registers a Virtual Network Adapter as a named PCAPNG Interface (`IDB` - `0x00000001`).
    /// Returns the assigned `interface_id` (filterable in Wireshark via `frame.interface_name`).
    pub fn registerInterface(self: *PcapngWriter, adapter_name: []const u8) !u32 {
        const opt_bytes = optionWireSize(adapter_name.len) + 4; // opt_if_name + opt_endofopt
        const total_len: u32 = @intCast(20 + opt_bytes);

        try self.appendU32Le(PCAPNG_BLOCK_IDB);
        try self.appendU32Le(total_len);
        try self.appendU16Le(LINKTYPE_RAW);
        try self.appendU16Le(0); // Reserved
        try self.appendU32Le(self.snaplen);

        try self.writeOption(OPT_IF_NAME, adapter_name);
        try self.writeEndOfOptions();

        try self.appendU32Le(total_len);

        const id = self.interfaces_count;
        self.interfaces_count += 1;
        return id;
    }

    /// Embeds a TLS 1.2 / 1.3 Key Log line (`CLIENT_RANDOM ...`) inside a Decryption Secrets Block (`DSB` - `0x0000000A`)
    /// so Wireshark automatically decrypts HTTPS/HTTP2 streams without external `SSLKEYLOGFILE`.
    pub fn writeDecryptionSecretsBlock(self: *PcapngWriter, keylog_data: []const u8) !void {
        const padded_secrets_len = align4(keylog_data.len);
        const total_len: u32 = @intCast(20 + padded_secrets_len);

        try self.appendU32Le(PCAPNG_BLOCK_DSB);
        try self.appendU32Le(total_len);
        try self.appendU32Le(TLS_KEY_LOG_SECRETS_TYPE);
        try self.appendU32Le(@intCast(keylog_data.len));
        try self.buf.appendSlice(self.allocator, keylog_data);
        try self.appendPadding(keylog_data.len);
        try self.appendU32Le(total_len);
    }

    /// Synthesizes an IPv4 + TCP packet around `l7_payload`, truncates to `snaplen`,
    /// and writes an Enhanced Packet Block (`EPB` - `0x00000006`) stamped with `comment`.
    pub fn writeCapturedPacket(
        self: *PcapngWriter,
        interface_id: u32,
        timestamp_ms: u64,
        src_ip: [4]u8,
        dst_ip: [4]u8,
        src_port: u16,
        dst_port: u16,
        l7_payload: []const u8,
        comment: []const u8,
    ) !void {
        const ipv4_tcp_hdr_len: usize = 40; // 20B IPv4 + 20B TCP
        const orig_pkt_len: u32 = @intCast(ipv4_tcp_hdr_len + l7_payload.len);
        const captured_pkt_len: u32 = @min(orig_pkt_len, self.snaplen);
        const captured_l7_len: usize = if (captured_pkt_len > ipv4_tcp_hdr_len)
            captured_pkt_len - ipv4_tcp_hdr_len
        else
            0;

        const padded_pkt_len = align4(captured_pkt_len);
        const opt_bytes: usize = if (comment.len > 0) optionWireSize(comment.len) + 4 else 0;
        const total_len: u32 = @intCast(32 + padded_pkt_len + opt_bytes);

        const ts_us: u64 = timestamp_ms * 1000;
        const ts_high: u32 = @intCast(ts_us >> 32);
        const ts_low: u32 = @truncate(ts_us);

        try self.appendU32Le(PCAPNG_BLOCK_EPB);
        try self.appendU32Le(total_len);
        try self.appendU32Le(interface_id);
        try self.appendU32Le(ts_high);
        try self.appendU32Le(ts_low);
        try self.appendU32Le(captured_pkt_len);
        try self.appendU32Le(orig_pkt_len);

        // Synthesize minimal IPv4 (20B) + TCP (20B) header in network byte order (big-endian)
        var hdr: [40]u8 = @splat(0);
        hdr[0] = 0x45; // Version 4, IHL 5 (20 bytes)
        std.mem.writeInt(u16, hdr[2..4], @truncate(orig_pkt_len), .big);
        hdr[8] = 64; // TTL
        hdr[9] = 6; // Protocol = TCP (6)
        @memcpy(hdr[12..16], &src_ip);
        @memcpy(hdr[16..20], &dst_ip);

        // TCP header
        std.mem.writeInt(u16, hdr[20..22], src_port, .big);
        std.mem.writeInt(u16, hdr[22..24], dst_port, .big);
        std.mem.writeInt(u32, hdr[24..28], @truncate(self.packets_written + 1), .big); // Seq
        hdr[32] = 0x50; // Data offset = 5 (20 bytes)
        hdr[33] = 0x18; // Flags: PSH | ACK
        std.mem.writeInt(u16, hdr[34..36], 65535, .big); // Window size

        const hdr_to_write = @min(ipv4_tcp_hdr_len, captured_pkt_len);
        try self.buf.appendSlice(self.allocator, hdr[0..hdr_to_write]);
        if (captured_l7_len > 0) {
            try self.buf.appendSlice(self.allocator, l7_payload[0..captured_l7_len]);
        }
        try self.appendPadding(captured_pkt_len);

        if (comment.len > 0) {
            try self.writeOption(OPT_COMMENT, comment);
            try self.writeEndOfOptions();
        }

        try self.appendU32Le(total_len);
        self.packets_written += 1;
    }

    fn writeOption(self: *PcapngWriter, code: u16, value: []const u8) !void {
        try self.appendU16Le(code);
        try self.appendU16Le(@intCast(value.len));
        try self.buf.appendSlice(self.allocator, value);
        try self.appendPadding(value.len);
    }

    fn writeEndOfOptions(self: *PcapngWriter) !void {
        try self.appendU16Le(OPT_ENDOFOPT);
        try self.appendU16Le(0);
    }

    fn optionWireSize(val_len: usize) usize {
        return 4 + align4(val_len);
    }

    fn align4(len: usize) usize {
        return (len + 3) & ~@as(usize, 3);
    }

    fn appendPadding(self: *PcapngWriter, unaligned_len: usize) !void {
        const pad = align4(unaligned_len) - unaligned_len;
        var i: usize = 0;
        while (i < pad) : (i += 1) {
            try self.buf.append(self.allocator, 0);
        }
    }

    fn appendU16Le(self: *PcapngWriter, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    fn appendU32Le(self: *PcapngWriter, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    fn appendU64Le(self: *PcapngWriter, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }
};

test "pcapng_writer: generates valid SHB, IDB, DSB TLS secrets, and EPB packets with snaplen and step comments" {
    const testing = std.testing;

    var writer = try PcapngWriter.init(testing.allocator, 64);
    defer writer.deinit();

    // 1. Register interface "api_egress"
    const if_id = try writer.registerInterface("api_egress");
    try testing.expectEqual(@as(u32, 0), if_id);

    // 2. Write TLS 1.3 Decryption Secrets Block (DSB)
    const keylog = "CLIENT_RANDOM 01020304 0a0b0c0d\n";
    try writer.writeDecryptionSecretsBlock(keylog);

    // 3. Write Enhanced Packet Block (EPB) with 100-byte payload (truncated to snaplen=64)
    const payload = "GET /manga/a96676e5/feed HTTP/1.1\r\nHost: api.mangadex.org\r\nUser-Agent: flowdata/2.0\r\n\r\nEXTRA_PAYLOAD_BYTES";
    try writer.writeCapturedPacket(
        if_id,
        1700000000000,
        .{ 10, 254, 0, 2 },
        .{ 104, 18, 40, 10 },
        51234,
        443,
        payload,
        "step_id=fetch_chapters task=mangadex/fetch_feed verdict=ALLOWED",
    );

    try testing.expectEqual(@as(usize, 1), writer.packets_written);

    const raw = writer.bytes();
    // Verify SHB magic at offset 0
    try testing.expectEqual(PCAPNG_BLOCK_SHB, std.mem.readInt(u32, raw[0..4], .little));
    try testing.expectEqual(PCAPNG_BYTE_ORDER_MAGIC, std.mem.readInt(u32, raw[8..12], .little));
    // Verify comment string is embedded inside the PCAPNG stream
    try testing.expect(std.mem.indexOf(u8, raw, "step_id=fetch_chapters") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "CLIENT_RANDOM") != null);
}

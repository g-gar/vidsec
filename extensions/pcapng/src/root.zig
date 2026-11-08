const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const kernel = flowdata.kernel;
const KernelContext = kernel.KernelContext;
const Extension = kernel.Extension;
const TelemetryEvent = kernel.TelemetryEvent;
const TelemetrySubscriber = kernel.TelemetrySubscriber;
const OutboundRegistry = flowdata.transport.outbound.OutboundRegistry;
const AdapterConfig = flowdata.transport.outbound.contracts.AdapterConfig;
const CaptureSpec = flowdata.transport.outbound.contracts.CaptureSpec;
const PacketSink = flowdata.transport.outbound.contracts.PacketSink;
const NetworkSpec = flowdata.transport.outbound.contracts.NetworkSpec;
const RepositoryRegistry = flowdata.RepositoryRegistry;
const PayloadHandle = flowdata.dataflow.PayloadHandle;

pub const pcapng_writer = @import("pcapng_writer.zig");
pub const PcapngWriter = pcapng_writer.PcapngWriter;
pub const PcapngSink = PcapngWriter;

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

pub fn writeFileBytes(allocator: Allocator, path: []const u8, data: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fp = c_stdio.fopen(path_z.ptr, "wb") orelse return error.FileOpenFailed;
    defer _ = c_stdio.fclose(fp);

    if (data.len > 0) {
        const written = c_stdio.fwrite(data.ptr, 1, data.len, fp);
        if (written != data.len) return error.FileWriteFailed;
    }
}

pub fn writePcapWithRotation(
    allocator: Allocator,
    base_path: []const u8,
    pcap_bytes: []const u8,
    max_file_size_mb: usize,
    max_files: usize,
) !void {
    const max_bytes: usize = if (max_file_size_mb > 0)
        max_file_size_mb * 1024 * 1024
    else
        pcap_bytes.len;

    if (max_bytes == 0 or pcap_bytes.len <= max_bytes or max_files <= 1) {
        try writeFileBytes(allocator, base_path, pcap_bytes);
        return;
    }

    // Ring-buffer rotation across `<base_path>.0`, `<base_path>.1`, ... up to `max_files`
    var offset: usize = 0;
    var part_idx: usize = 0;
    while (offset < pcap_bytes.len) : (part_idx += 1) {
        const chunk_len = @min(max_bytes, pcap_bytes.len - offset);
        const slot = part_idx % max_files;
        const rotated_path = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_path, slot });
        defer allocator.free(rotated_path);

        try writeFileBytes(allocator, rotated_path, pcap_bytes[offset .. offset + chunk_len]);
        offset += chunk_len;
    }

    // Also write the primary file so tools inspecting `base_path` directly find valid PCAPNG data
    try writeFileBytes(allocator, base_path, pcap_bytes);
}

pub const PcapngExtension = struct {
    allocator: Allocator,
    writers: std.StringHashMapUnmanaged(*PcapngWriter) = .empty,
    specs: std.StringHashMapUnmanaged(CaptureSpec) = .empty,

    pub fn init(allocator: Allocator) PcapngExtension {
        return .{
            .allocator = allocator,
            .writers = .empty,
            .specs = .empty,
        };
    }

    pub fn deinit(self: *PcapngExtension) void {
        var wit = self.writers.iterator();
        while (wit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinitInternal();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.writers.deinit(self.allocator);

        var sit = self.specs.keyIterator();
        while (sit.next()) |key| {
            self.allocator.free(key.*);
        }
        self.specs.deinit(self.allocator);
    }

    pub fn createTapSink(self: *PcapngExtension, allocator: Allocator, config: AdapterConfig) !?PacketSink {
        if (!config.capture.enabled) return null;

        const writer = try allocator.create(PcapngWriter);
        errdefer allocator.destroy(writer);

        writer.* = try PcapngWriter.init(
            allocator,
            config.id,
            config.capture.snaplen,
            config.capture.include_tls_keys,
        );

        const owned_id1 = try self.allocator.dupe(u8, config.id);
        errdefer self.allocator.free(owned_id1);

        const owned_id2 = try self.allocator.dupe(u8, config.id);
        errdefer self.allocator.free(owned_id2);

        try self.writers.put(self.allocator, owned_id1, writer);
        try self.specs.put(self.allocator, owned_id2, config.capture);

        return writer.packetSink();
    }

    pub fn flush(self: *PcapngExtension, repos: *RepositoryRegistry) anyerror!void {
        var it = self.writers.iterator();
        while (it.next()) |entry| {
            const adapter_id = entry.key_ptr.*;
            const writer = entry.value_ptr.*;
            const pcap_bytes = writer.bytes();
            if (pcap_bytes.len == 0) continue;

            const spec = self.specs.get(adapter_id) orelse continue;
            if (!spec.enabled) continue;

            // 1. Persist to configured Datasource Repository (`capture.datasource`)
            if (spec.datasource) |ds_name| {
                if (repos.get(ds_name)) |repo| {
                    const ch_name = if (spec.channel.len > 0)
                        spec.channel
                    else
                        "pcap_packets";
                    const handle = PayloadHandle.fromSlice(u8, pcap_bytes);
                    try repo.writePayload(ch_name, handle);
                }
            }

            // 2. Persist to configured File Path (`capture.path`) with ring-buffer rotation
            if (spec.path) |file_path| {
                if (file_path.len > 0) {
                    try writePcapWithRotation(
                        self.allocator,
                        file_path,
                        pcap_bytes,
                        spec.max_file_size_mb,
                        spec.max_files,
                    );
                }
            }
        }
    }

    pub fn getBytes(self: *const PcapngExtension, adapter_id: []const u8) ?[]const u8 {
        if (self.writers.get(adapter_id)) |writer| {
            return writer.bytes();
        }
        return null;
    }

    pub fn subscriber(self: *PcapngExtension) TelemetrySubscriber {
        const Trampoline = struct {
            fn doOnEvent(_: *anyopaque, _: *const TelemetryEvent) void {}

            fn doFlush(ctx: *anyopaque, repos: *RepositoryRegistry) anyerror!void {
                const s: *PcapngExtension = @ptrCast(@alignCast(ctx));
                try s.flush(repos);
            }

            const vtable = TelemetrySubscriber.VTable{
                .onEvent = &doOnEvent,
                .flush = &doFlush,
                .deinit = null,
            };
        };
        return .{ .ptr = self, .vtable = &Trampoline.vtable };
    }
};

var global_extension_instance: ?PcapngExtension = null;

pub fn getGlobalExtension(allocator: Allocator) *PcapngExtension {
    if (global_extension_instance == null) {
        global_extension_instance = PcapngExtension.init(allocator);
    }
    return &global_extension_instance.?;
}

pub fn globalSinkFactory(allocator: Allocator, config: AdapterConfig) anyerror!?PacketSink {
    const ext = getGlobalExtension(allocator);
    return ext.createTapSink(allocator, config);
}

pub fn registerOutboundSink(reg: *OutboundRegistry) !void {
    try reg.registerSinkFactory(&globalSinkFactory);
}

pub const extension = Extension.fromStateless("flowdata.pcapng", struct {
    fn reg(k: *KernelContext) anyerror!void {
        const ext = getGlobalExtension(k.allocator);
        try k.outbound.registerSinkFactory(&globalSinkFactory);
        try k.telemetry.subscribe(ext.subscriber());
    }
}.reg);

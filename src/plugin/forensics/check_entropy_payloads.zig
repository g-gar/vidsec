const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("vidsec_ir");
const math = @import("vidsec_math");
const FindingList = @import("finding_list.zig").FindingList;

pub const EntropyForensicsOptions = struct {
    threshold: f64 = 7.2,
    min_length: u64 = 64,
};

/// Detects hidden high-entropy payloads (encrypted/compressed) in unreferenced overlays and padding.
pub fn checkEntropyPayloads(
    allocator: Allocator,
    container: *const ir.ContainerIR,
    stream: ir.ByteStream,
    options: EntropyForensicsOptions,
    findings: *FindingList,
) !void {
    const file_size = stream.size();
    if (file_size < options.min_length) return;

    var chunk_buf: [4096]u8 = undefined;

    // 1. Inspect Trailing Overlay if present
    const highest_root_end = container.highestRootEnd();
    if (highest_root_end > 0 and highest_root_end < file_size) {
        const overlay_len = file_size - highest_root_end;
        if (overlay_len >= options.min_length) {
            const read_len = @min(overlay_len, chunk_buf.len);
            const bytes_read = stream.readAt(highest_root_end, chunk_buf[0..read_len]) catch 0;
            if (bytes_read >= options.min_length) {
                const ent = math.shannonEntropy(chunk_buf[0..bytes_read]);
                if (ent >= options.threshold) {
                    const msg = try std.fmt.allocPrint(
                        allocator,
                        "High entropy ({d:.2} bits/byte >= {d:.2}) in trailing overlay ({d} bytes at offset {d})",
                        .{ ent, options.threshold, overlay_len, highest_root_end },
                    );
                    try findings.append(allocator, .{
                        .vulnerability = .high_entropy_payload,
                        .severity = .critical,
                        .offset = highest_root_end,
                        .length = overlay_len,
                        .region_tag = "overlay_entropy",
                        .message = msg,
                    });
                }
            }
        }
    }

    // 2. Inspect Padding regions ('free', 'skip', 'Void', 'JUNK')
    for (container.regions.items) |region| {
        if (region.role == .padding and region.size >= options.min_length) {
            const read_len = @min(region.payloadSize(), chunk_buf.len);
            if (read_len >= options.min_length) {
                const bytes_read = stream.readAt(region.payload_offset, chunk_buf[0..read_len]) catch 0;
                if (bytes_read >= options.min_length) {
                    const ent = math.shannonEntropy(chunk_buf[0..bytes_read]);
                    if (ent >= options.threshold) {
                        const msg = try std.fmt.allocPrint(
                            allocator,
                            "High entropy ({d:.2} bits/byte) hidden in padding region {s} ({d} bytes at offset {d})",
                            .{ ent, region.tagSlice(), region.size, region.header_offset },
                        );
                        try findings.append(allocator, .{
                            .vulnerability = .high_entropy_payload,
                            .severity = .critical,
                            .offset = region.header_offset,
                            .length = region.size,
                            .region_tag = region.tagSlice(),
                            .message = msg,
                        });
                    }
                }
            }
        }
    }
}

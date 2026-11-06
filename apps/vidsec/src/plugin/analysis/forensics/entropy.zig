const std = @import("std");
const math = @import("vidsec_math");
const ir = @import("vidsec_ir");
const forensics = @import("vidsec_forensics");

pub const ScanEntropyOptions = struct {
    min_entropy: f64 = 7.2,
};

/// Pure Black Box forensics task:
/// Inspects unreferenced slack and gap regions in `ir_unreferenced_slack`
/// using Shannon entropy to detect encrypted payloads, compressed archives, or shellcode.
pub fn scanEntropy(
    allocator: std.mem.Allocator,
    file_bytes: []const u8,
    slacks: []const ir.IrUnreferencedSlackRow,
    opts: ScanEntropyOptions,
) ![]forensics.AuditFinding {
    var findings = std.ArrayList(forensics.AuditFinding).empty;
    errdefer findings.deinit(allocator);

    for (slacks) |slack| {
        if (slack.byte_length == 0) continue;
        if (slack.file_offset >= file_bytes.len) continue;

        const avail = file_bytes.len - slack.file_offset;
        const sample_len = @min(slack.byte_length, @min(avail, 65536));
        const slice = file_bytes[slack.file_offset .. slack.file_offset + sample_len];

        // Harmless zero-padding
        if (math.isAllZero(slice)) continue;

        const h = math.shannonEntropy(slice);
        if (h >= opts.min_entropy) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "High entropy payload in {s} (H={d:.2} >= {d:.2}): potential encrypted/compressed data",
                .{ slack.region_tag, h, opts.min_entropy },
            );

            try findings.append(allocator, .{
                .rule_id = "R07_HIGH_ENTROPY_PAYLOAD",
                .severity = 2,
                .file_offset = @intCast(slack.file_offset),
                .byte_length = @intCast(slack.byte_length),
                .end_offset = @intCast(slack.file_offset + slack.byte_length),
                .region_tag = slack.region_tag,
                .measured_value = h,
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }
    }

    return try findings.toOwnedSlice(allocator);
}

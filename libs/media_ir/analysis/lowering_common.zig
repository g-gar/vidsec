const std = @import("std");
const ContainerFormat = @import("../entities/container_format.zig").ContainerFormat;
const rows = @import("../rows/mod.zig");
const AuditFindingRow = @import("../findings/audit_finding_row.zig").AuditFindingRow;
const RuleId = @import("../findings/vulnerability_type.zig").RuleId;
const types = @import("lowering_types.zig");
const RegionInput = types.RegionInput;
const LowerContainerOutput = types.LowerContainerOutput;

pub fn lowerRegions(
    allocator: std.mem.Allocator,
    file_size: i64,
    format: ContainerFormat,
    true_magic_kind: i64,
    true_magic_name: []const u8,
    inputs: []const RegionInput,
) !LowerContainerOutput {
    var regions = std.ArrayList(rows.IrRegionRow).empty;
    errdefer regions.deinit(allocator);

    var findings = std.ArrayList(AuditFindingRow).empty;
    errdefer findings.deinit(allocator);

    var highest_root_end: i64 = 0;

    for (inputs) |in| {
        const effective_end_offset = in.header_offset + in.size;
        const is_truncated_or_overflow = (effective_end_offset > file_size);

        if (in.parent_id == null) {
            highest_root_end = @max(highest_root_end, effective_end_offset);
        }

        if (is_truncated_or_overflow) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Region {s} overflows file bounds: offset={d} end={d} > file_size={d}",
                .{ in.tag, in.header_offset, effective_end_offset, file_size },
            );

            try findings.append(allocator, .{
                .rule_id = RuleId.region_overflow.asText(),
                .severity = 2,
                .file_offset = in.header_offset,
                .byte_length = effective_end_offset - in.header_offset,
                .end_offset = effective_end_offset,
                .region_tag = in.tag,
                .measured_value = @floatFromInt(effective_end_offset),
                .message = msg,
                .is_remediated = false,
                .remediation_action = "UNRESOLVED",
            });
        }

        try regions.append(allocator, .{
            .region_id = in.id,
            .parent_region_id = in.parent_id,
            .tag_name = in.tag,
            .role = in.role,
            .header_offset = @intCast(@max(0, in.header_offset)),
            .payload_offset = @intCast(@max(0, in.payload_offset)),
            .effective_end_offset = @intCast(@max(0, effective_end_offset)),
            .is_truncated_or_overflow = is_truncated_or_overflow,
        });
    }

    const metadata = rows.ContainerMetadataRow{
        .file_size = @intCast(@max(0, file_size)),
        .detected_format = format.toInt(),
        .true_magic = true_magic_kind,
        .true_magic_name = true_magic_name,
        .highest_root_end = @intCast(@max(0, highest_root_end)),
    };

    return .{
        .regions = try regions.toOwnedSlice(allocator),
        .metadata = metadata,
        .overflow_findings = try findings.toOwnedSlice(allocator),
    };
}

const std = @import("std");
const abi = @import("vidsec_abi");
const types = @import("types.zig");

fn tryNextRow(
    ctx: abi.TaskContext,
    primary: [:0]const u8,
    alt: [:0]const u8,
) abi.SdkError!?abi.RowView_ABI {
    if (ctx.nextRow(primary)) |maybe_row| {
        return maybe_row;
    } else |err| {
        if (err == error.NotFound) {
            if (ctx.nextRow(alt)) |maybe_alt_row| {
                return maybe_alt_row;
            } else |alt_err| {
                if (alt_err == error.NotFound) {
                    return null;
                }
                return alt_err;
            }
        }
        return err;
    }
}

/// Task `ir/lower_container`:
/// Normalizes format-specific container tables (`isobmff_boxes`, `ebml_elements`, `riff_chunks`)
/// into the unified `ir_regions` hierarchy and populates `container_metadata`.
pub fn runLowerContainer(ctx: abi.TaskContext) abi.SdkError!abi.TaskStatus_ABI {
    var file_size: i64 = @intCast(ctx.streamSize());
    var true_magic_kind: i64 = 0;
    var true_magic_name: []const u8 = "unknown";
    var detected_family: []const u8 = "unknown";

    // 1. Read metadata from `triage` or `file_triage` cursor
    if (try tryNextRow(ctx, "triage", "file_triage")) |triage_row| {
        if (triage_row.getField("file_size")) |v| {
            if (v.asInt()) |sz| file_size = sz;
        }
        if (triage_row.getField("true_magic_kind")) |v| {
            if (v.asInt()) |k| true_magic_kind = k;
        }
        if (triage_row.getField("true_magic_name")) |v| {
            if (v.asText()) |n| true_magic_name = n;
        }
        if (triage_row.getField("detected_family")) |v| {
            if (v.asText()) |f| detected_family = f;
        }
    }

    var highest_root_end: i64 = 0;
    var lowered_count: usize = 0;
    var detected_format: abi.ir.ContainerFormat = .unknown;

    // 2. Check and lower ISOBMFF boxes
    var has_boxes = false;
    while (try tryNextRow(ctx, "boxes", "isobmff_boxes")) |box_row| {
        has_boxes = true;
        detected_format = .isobmff;
        const box_id = if (box_row.getField("box_id")) |v| v.asInt() orelse 0 else 0;
        const maybe_parent = if (box_row.getField("parent_box_id")) |v| v.asInt() else null;
        const fourcc = if (box_row.getField("fourcc")) |v| v.asText() orelse "????" else "????";
        const role = if (box_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
        const header_offset = if (box_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
        const payload_offset = if (box_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
        const box_size = if (box_row.getField("box_size")) |v| v.asInt() orelse 0 else 0;

        const effective_end_offset = header_offset + box_size;
        const is_truncated_or_overflow = (effective_end_offset > file_size);

        if (maybe_parent == null) {
            highest_root_end = @max(highest_root_end, effective_end_offset);
        }

        const fields = [_]abi.NamedField_ABI{
            abi.NamedField_ABI.init("region_id", abi.Value_ABI.fromInt(box_id)),
            abi.NamedField_ABI.init("parent_region_id", if (maybe_parent) |p| abi.Value_ABI.fromInt(p) else abi.Value_ABI.nullVal()),
            abi.NamedField_ABI.init("tag_name", abi.Value_ABI.fromText(fourcc)),
            abi.NamedField_ABI.init("role", abi.Value_ABI.fromText(role)),
            abi.NamedField_ABI.init("header_offset", abi.Value_ABI.fromInt(header_offset)),
            abi.NamedField_ABI.init("payload_offset", abi.Value_ABI.fromInt(payload_offset)),
            abi.NamedField_ABI.init("effective_end_offset", abi.Value_ABI.fromInt(effective_end_offset)),
            abi.NamedField_ABI.init("is_truncated_or_overflow", abi.Value_ABI.fromBool(is_truncated_or_overflow)),
        };

        try ctx.emitRow("ir_regions", &fields);
        lowered_count += 1;
    }

    // 3. Check and lower EBML elements if no boxes lowered
    if (!has_boxes) {
        var has_elements = false;
        while (try tryNextRow(ctx, "elements", "ebml_elements")) |elem_row| {
            has_elements = true;
            detected_format = .ebml;
            const element_id = if (elem_row.getField("element_id")) |v| v.asInt() orelse 0 else 0;
            const maybe_parent = if (elem_row.getField("parent_element_id")) |v| v.asInt() else null;
            const ebml_id_hex = if (elem_row.getField("ebml_id_hex")) |v| v.asText() orelse "0x00" else "0x00";
            const role = if (elem_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
            const header_offset = if (elem_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
            const payload_offset = if (elem_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
            const total_size = if (elem_row.getField("total_size")) |v| v.asInt() orelse 0 else 0;

            const effective_end_offset = header_offset + total_size;
            const is_truncated_or_overflow = (effective_end_offset > file_size);

            if (maybe_parent == null) {
                highest_root_end = @max(highest_root_end, effective_end_offset);
            }

            const fields = [_]abi.NamedField_ABI{
                abi.NamedField_ABI.init("region_id", abi.Value_ABI.fromInt(element_id)),
                abi.NamedField_ABI.init("parent_region_id", if (maybe_parent) |p| abi.Value_ABI.fromInt(p) else abi.Value_ABI.nullVal()),
                abi.NamedField_ABI.init("tag_name", abi.Value_ABI.fromText(ebml_id_hex)),
                abi.NamedField_ABI.init("role", abi.Value_ABI.fromText(role)),
                abi.NamedField_ABI.init("header_offset", abi.Value_ABI.fromInt(header_offset)),
                abi.NamedField_ABI.init("payload_offset", abi.Value_ABI.fromInt(payload_offset)),
                abi.NamedField_ABI.init("effective_end_offset", abi.Value_ABI.fromInt(effective_end_offset)),
                abi.NamedField_ABI.init("is_truncated_or_overflow", abi.Value_ABI.fromBool(is_truncated_or_overflow)),
            };

            try ctx.emitRow("ir_regions", &fields);
            lowered_count += 1;
        }

        // 4. Check and lower RIFF chunks if neither boxes nor elements lowered
        if (!has_elements) {
            while (try tryNextRow(ctx, "chunks", "riff_chunks")) |chunk_row| {
                detected_format = .riff;
                const chunk_id = if (chunk_row.getField("chunk_id")) |v| v.asInt() orelse 0 else 0;
                const maybe_parent = if (chunk_row.getField("parent_chunk_id")) |v| v.asInt() else null;
                const fourcc = if (chunk_row.getField("fourcc")) |v| v.asText() orelse "????" else "????";
                const role = if (chunk_row.getField("role")) |v| v.asText() orelse "unknown" else "unknown";
                const header_offset = if (chunk_row.getField("header_offset")) |v| v.asInt() orelse 0 else 0;
                const payload_offset = if (chunk_row.getField("payload_offset")) |v| v.asInt() orelse 0 else 0;
                const total_size = if (chunk_row.getField("total_size")) |v| v.asInt() orelse 0 else 0;

                const effective_end_offset = header_offset + total_size;
                const is_truncated_or_overflow = (effective_end_offset > file_size);

                if (maybe_parent == null) {
                    highest_root_end = @max(highest_root_end, effective_end_offset);
                }

                const fields = [_]abi.NamedField_ABI{
                    abi.NamedField_ABI.init("region_id", abi.Value_ABI.fromInt(chunk_id)),
                    abi.NamedField_ABI.init("parent_region_id", if (maybe_parent) |p| abi.Value_ABI.fromInt(p) else abi.Value_ABI.nullVal()),
                    abi.NamedField_ABI.init("tag_name", abi.Value_ABI.fromText(fourcc)),
                    abi.NamedField_ABI.init("role", abi.Value_ABI.fromText(role)),
                    abi.NamedField_ABI.init("header_offset", abi.Value_ABI.fromInt(header_offset)),
                    abi.NamedField_ABI.init("payload_offset", abi.Value_ABI.fromInt(payload_offset)),
                    abi.NamedField_ABI.init("effective_end_offset", abi.Value_ABI.fromInt(effective_end_offset)),
                    abi.NamedField_ABI.init("is_truncated_or_overflow", abi.Value_ABI.fromBool(is_truncated_or_overflow)),
                };

                try ctx.emitRow("ir_regions", &fields);
                lowered_count += 1;
            }
        }
    }

    // 5. Populate container_metadata
    if (detected_format == .unknown) {
        if (std.mem.eql(u8, detected_family, "isobmff")) {
            detected_format = .isobmff;
        } else if (std.mem.eql(u8, detected_family, "ebml")) {
            detected_format = .ebml;
        } else if (std.mem.eql(u8, detected_family, "riff")) {
            detected_format = .riff;
        }
    }

    const meta_fields = [_]abi.NamedField_ABI{
        abi.NamedField_ABI.init("file_size", abi.Value_ABI.fromInt(file_size)),
        abi.NamedField_ABI.init("detected_format", abi.Value_ABI.fromInt(detected_format.toInt())),
        abi.NamedField_ABI.init("true_magic", abi.Value_ABI.fromInt(true_magic_kind)),
        abi.NamedField_ABI.init("true_magic_name", abi.Value_ABI.fromText(true_magic_name)),
        abi.NamedField_ABI.init("highest_root_end", abi.Value_ABI.fromInt(highest_root_end)),
    };

    try ctx.emitRow("container_metadata", &meta_fields);

    return .ok;
}

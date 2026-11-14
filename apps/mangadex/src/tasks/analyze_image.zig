const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const PageWithContentType = @import("detect_content_type.zig").PageWithContentType;

pub const AnalyzeImageInputs = struct {
    item: PageWithContentType,
    default_width: u32 = 0,
    default_height: u32 = 0,
    spread_threshold: f32 = 1.3,
};

pub const AnalyzedPageItem = struct {
    source_chapter_id: []const u8,
    page_number: u32,
    url: []const u8,
    image_data: []const u8,
    content_type: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    aspect_ratio: f32 = 0.0,
    is_double_page: bool = false,
};

/// Service that simulates static image analysis (dimensions, aspect ratio, spread detection)
/// using configurable parameters from pipeline.yaml rather than hardcoded dimensions.
pub const AnalyzeImageService = struct {
    logger: Logger,

    pub fn execute(self: *AnalyzeImageService, alloc: Allocator, inputs: AnalyzeImageInputs) !AnalyzedPageItem {
        const item = inputs.item;
        if (item.image_data.len == 0) {
            self.logger.err("Cannot analyze empty image payload for page {d}", .{item.page_number});
            return error.EmptyImagePayload;
        }

        self.logger.info("Simulating static image analysis for page {d} ({s}, {d} bytes, params: {d}x{d})", .{
            item.page_number,
            item.content_type,
            item.image_data.len,
            inputs.default_width,
            inputs.default_height,
        });

        const width = inputs.default_width;
        const height = inputs.default_height;
        const ratio: f32 = if (width > 0 and height > 0)
            @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height))
        else
            0.0;
        const is_double = if (inputs.spread_threshold > 0.0) ratio > inputs.spread_threshold else false;

        return AnalyzedPageItem{
            .source_chapter_id = try alloc.dupe(u8, item.source_chapter_id),
            .page_number = item.page_number,
            .url = try alloc.dupe(u8, item.url),
            .image_data = item.image_data,
            .content_type = try alloc.dupe(u8, item.content_type),
            .width = width,
            .height = height,
            .aspect_ratio = ratio,
            .is_double_page = is_double,
        };
    }
};

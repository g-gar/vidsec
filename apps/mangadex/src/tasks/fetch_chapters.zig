const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const MangaSource = @import("../sources/mod.zig").MangaSource;

pub const FetchChaptersInputs = struct {
    series_id: []const u8,
    languages: []const u8 = "en",
    datasource: ?[]const u8 = null,
    target_chapters: []const u8 = "all",
};

pub const ChapterItem = struct {
    source_chapter_id: []const u8,
    series_id: []const u8,
    chapter_number: []const u8,
    volume_number: ?[]const u8 = null,
    title: ?[]const u8 = null,
    language: []const u8,
    scanlation_group: ?[]const u8 = null,
    page_count: u32 = 0,
};

fn matchesSingleFilter(ch_num: []const u8, item: []const u8) bool {
    const target = std.mem.trim(u8, item, " \t\r\n");
    if (target.len == 0) return false;
    if (std.mem.eql(u8, target, "all") or std.mem.eql(u8, target, "*")) return true;
    if (std.mem.eql(u8, ch_num, target)) return true;

    // Suffix '+' notation: e.g. "2+" (chapter 2 onwards inclusive)
    if (std.mem.endsWith(u8, target, "+")) {
        const s_clean = std.mem.trim(u8, target[0 .. target.len - 1], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
        return ch_val >= s_val;
    }

    // Comparison operators: ">=2", ">2", "<=5", "<5"
    if (std.mem.startsWith(u8, target, ">=")) {
        const s_clean = std.mem.trim(u8, target[2..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
        return ch_val >= s_val;
    } else if (std.mem.startsWith(u8, target, ">")) {
        const s_clean = std.mem.trim(u8, target[1..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
        return ch_val > s_val;
    } else if (std.mem.startsWith(u8, target, "<=")) {
        const e_clean = std.mem.trim(u8, target[2..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const e_val = std.fmt.parseFloat(f64, e_clean) catch return false;
        return ch_val <= e_val;
    } else if (std.mem.startsWith(u8, target, "<")) {
        const e_clean = std.mem.trim(u8, target[1..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const e_val = std.fmt.parseFloat(f64, e_clean) catch return false;
        return ch_val < e_val;
    }

    // Detect range separators: "...", "..", ":", or "-"
    var start_str: ?[]const u8 = null;
    var end_str: ?[]const u8 = null;

    if (std.mem.indexOf(u8, target, "...")) |dot3_idx| {
        start_str = target[0..dot3_idx];
        end_str = target[dot3_idx + 3 ..];
    } else if (std.mem.indexOf(u8, target, "..")) |dot_idx| {
        start_str = target[0..dot_idx];
        end_str = target[dot_idx + 2 ..];
    } else if (std.mem.indexOfScalar(u8, target, ':')) |colon_idx| {
        start_str = target[0..colon_idx];
        end_str = target[colon_idx + 1 ..];
    } else if (std.mem.indexOfScalar(u8, target, '-')) |dash_idx| {
        start_str = target[0..dash_idx];
        end_str = target[dash_idx + 1 ..];
    }

    if (start_str) |s_raw| {
        const e_raw = end_str.?;
        const s_clean = std.mem.trim(u8, s_raw, " \t");
        const e_clean = std.mem.trim(u8, e_raw, " \t");

        // Must have at least start or end defined
        if (s_clean.len == 0 and e_clean.len == 0) return true;

        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;

        // Both bounds are inclusive: [s_val, e_val]
        if (s_clean.len > 0) {
            const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
            if (ch_val < s_val) return false;
        }

        if (e_clean.len > 0) {
            const e_val = std.fmt.parseFloat(f64, e_clean) catch return false;
            if (ch_val > e_val) return false;
        }

        return true;
    }

    return false;
}

pub fn matchesChapterFilter(ch_num: []const u8, filter: []const u8) bool {
    const trimmed = std.mem.trim(u8, filter, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "all") or std.mem.eql(u8, trimmed, "*")) {
        return true;
    }
    var it = std.mem.tokenizeScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        if (matchesSingleFilter(ch_num, item)) return true;
    }
    return false;
}

pub const FetchChaptersService = struct {
    source: MangaSource,
    logger: Logger,

    /// Only accepts `SeriesDetails`-like payloads (must carry `series_id` and `source_id` or `status`),
    /// preventing premature activation on raw `JobSpec` records before `fetch_series_details`.
    pub fn canHandle(payload: *const @import("flowdata").plugin.PayloadHandle_ABI) bool {
        return payload.getReflected("series_id") != null and
            (payload.getReflected("source_id") != null or payload.getReflected("status") != null);
    }

    pub fn execute(self: *FetchChaptersService, alloc: Allocator, inputs: FetchChaptersInputs) ![]ChapterItem {
        var chapters_list: std.ArrayListUnmanaged(ChapterItem) = .empty;

        var lang_iter = std.mem.tokenizeScalar(u8, inputs.languages, ',');
        while (lang_iter.next()) |raw_lang| {
            const lang = std.mem.trim(u8, raw_lang, " \t\r\n");
            if (lang.len == 0) continue;

            self.logger.info("Fetching chapters for series '{s}' in language '{s}' (filter: '{s}') via source '{s}'", .{
                inputs.series_id,
                lang,
                inputs.target_chapters,
                self.source.getSourceId(),
            });
            const chapters = try self.source.getChapters(alloc, inputs.series_id, lang);
            for (chapters) |ch| {
                if (!matchesChapterFilter(ch.chapter_number, inputs.target_chapters)) {
                    continue;
                }

                // Avoid duplicate chapter numbers in the same language run
                var already_exists = false;
                for (chapters_list.items) |existing| {
                    if (std.mem.eql(u8, existing.chapter_number, ch.chapter_number)) {
                        already_exists = true;
                        break;
                    }
                }
                if (already_exists) continue;

                try chapters_list.append(alloc, .{
                    .source_chapter_id = ch.source_chapter_id,
                    .series_id = inputs.series_id,
                    .chapter_number = ch.chapter_number,
                    .volume_number = ch.volume_number,
                    .title = ch.title,
                    .language = ch.language_iso,
                    .scanlation_group = ch.scanlation_group,
                    .page_count = ch.page_count,
                });
            }
        }

        self.logger.info("Total chapters discovered for series '{s}': {d}", .{
            inputs.series_id,
            chapters_list.items.len,
        });
        return chapters_list.toOwnedSlice(alloc);
    }
};

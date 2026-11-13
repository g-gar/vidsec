const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("flowdata").plugin.Logger;
const komga_sdk = @import("komga_sdk");
const KomgaClient = komga_sdk.KomgaClient;
const CbzArchiveOutput = @import("build_cbz_archive.zig").CbzArchiveOutput;

pub const UploadCbzInputs = struct {
    cbz_archive: []const CbzArchiveOutput,
    series_title: ?[]const u8 = null,
    title: ?[]const u8 = null,
    library: ?[]const u8 = null,
    default_library: ?[]const u8 = null,
    /// Library scan strategy: "none", "normal" (default), or "deep"
    scan_mode: []const u8 = "normal",
    analyze_series: bool = true,
};

pub const EgressDeliveryRecord = struct {
    id: []const u8,
    source_chapter_id: []const u8,
    target: []const u8,
    external_book_id: ?[]const u8 = null,
    delivered_at: i64,
    status: []const u8,
    details: ?[]const u8 = null,
};

fn findLibraryId(libs: []const komga_sdk.LibraryDto, target: ?[]const u8) ?[]const u8 {
    if (libs.len == 0) return null;
    if (target) |t| {
        if (t.len > 0) {
            for (libs) |lib| {
                if (std.mem.eql(u8, lib.id, t) or std.ascii.eqlIgnoreCase(lib.name, t)) {
                    return lib.id;
                }
            }
        }
    }
    return libs[0].id;
}

/// Service that synchronizes uploaded CBZ archives with a remote Komga server over HTTP
/// (library resolution, library scan, series analysis, and egress_history audit output).
pub const UploadCbzService = struct {
    komga: *KomgaClient,
    logger: Logger,
    default_library_id: ?[]const u8 = null,

    pub fn execute(self: *UploadCbzService, alloc: Allocator, inputs: UploadCbzInputs) ![]EgressDeliveryRecord {
        if (inputs.cbz_archive.len == 0) {
            self.logger.warn("No CBZ archives to synchronize with Komga", .{});
            return &.{};
        }

        const first = inputs.cbz_archive[0];
        const series_name = blk: {
            if (inputs.series_title) |st| {
                if (st.len > 0) break :blk st;
            }
            if (inputs.title) |t| {
                if (t.len > 0) break :blk t;
            }
            if (first.series.len > 0) break :blk first.series;
            break :blk first.series_id;
        };

        const requested_lib: ?[]const u8 = blk: {
            if (inputs.library) |l| {
                if (l.len > 0) break :blk l;
            }
            if (first.library.len > 0) break :blk first.library;
            if (inputs.default_library) |dl| {
                if (dl.len > 0) break :blk dl;
            }
            break :blk self.default_library_id;
        };

        // 1. Resolve target Komga library ID
        var libs_parsed = try self.komga.listLibraries();
        defer libs_parsed.deinit();

        const library_id = findLibraryId(libs_parsed.value, requested_lib) orelse return error.KomgaLibraryNotFound;

        const is_none = std.ascii.eqlIgnoreCase(inputs.scan_mode, "none");
        const is_deep = std.ascii.eqlIgnoreCase(inputs.scan_mode, "deep");
        const is_normal = std.ascii.eqlIgnoreCase(inputs.scan_mode, "normal");
        if (!is_none and !is_deep and !is_normal) {
            self.logger.err("Invalid scan_mode '{s}'; expected 'none', 'normal', or 'deep'", .{inputs.scan_mode});
            return error.InvalidScanMode;
        }

        // 2. Scan library so Komga discovers newly uploaded CBZ files (unless scan_mode == "none")
        if (!is_none) {
            self.logger.info("Triggering Komga library scan (library_id={s}, scan_mode={s}) for series '{s}'", .{
                library_id,
                inputs.scan_mode,
                series_name,
            });
            try self.komga.scanLibrary(library_id, is_deep);
        } else {
            self.logger.info("Skipping Komga library scan (scan_mode=none) for series '{s}'", .{series_name});
        }

        // 3. Optionally locate the series and trigger analysis
        var komga_series_id: ?[]const u8 = null;
        if (series_name.len > 0) {
            if (self.komga.searchSeries(series_name, library_id)) |*search_res_const| {
                var search_res = search_res_const.*;
                defer search_res.deinit();
                if (search_res.value.content.len > 0) {
                    komga_series_id = try alloc.dupe(u8, search_res.value.content[0].id);
                    if (inputs.analyze_series) {
                        self.komga.analyzeSeries(komga_series_id.?) catch |err| {
                            self.logger.warn("Komga analyzeSeries failed for '{s}': {s}", .{
                                komga_series_id.?,
                                @errorName(err),
                            });
                        };
                    }
                }
            } else |err| {
                self.logger.warn("Komga searchSeries failed for '{s}': {s}", .{
                    series_name,
                    @errorName(err),
                });
            }
        }

        // 4. Emit egress_history audit records
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const now_sec: i64 = @intCast(tv.sec);

        const records = try alloc.alloc(EgressDeliveryRecord, inputs.cbz_archive.len);
        for (inputs.cbz_archive, 0..) |cbz, idx| {
            const chapter_ref = try std.fmt.allocPrint(alloc, "{s}:ch:{s}", .{
                if (cbz.series_id.len > 0) cbz.series_id else series_name,
                cbz.chapter_number,
            });
            const rec_id = try std.fmt.allocPrint(alloc, "komga:{s}:{d}", .{ chapter_ref, now_sec });
            const details = try std.fmt.allocPrint(alloc, "library={s} file={s} bytes={d}", .{
                library_id,
                cbz.filename,
                cbz.file_size_bytes,
            });

            records[idx] = .{
                .id = rec_id,
                .source_chapter_id = chapter_ref,
                .target = "komga",
                .external_book_id = komga_series_id,
                .delivered_at = now_sec,
                .status = "success",
                .details = details,
            };
        }

        return records;
    }
};


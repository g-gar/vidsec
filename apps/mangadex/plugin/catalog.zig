const std = @import("std");
const Allocator = std.mem.Allocator;
const flowdata = @import("flowdata");
const abi = flowdata.plugin;
const TaskContext = abi.TaskContext;

const container = @import("container.zig");
pub const MangaContext = container.MangaContext;
pub const MangaPluginContainer = container.MangaPluginContainer;

pub const task_details = @import("tasks/fetch_series_details.zig");
pub const task_chapters = @import("tasks/fetch_chapters.zig");
pub const task_pages = @import("tasks/fetch_chapter_pages.zig");
pub const task_download = @import("tasks/download_chapter_page.zig");
pub const task_detect = @import("tasks/detect_content_type.zig");
pub const task_analyze = @import("tasks/analyze_image.zig");
pub const task_comicinfo = @import("tasks/generate_comicinfo.zig");
pub const task_cbz = @import("tasks/build_cbz_archive.zig");
pub const task_upload_cbz = @import("tasks/upload_cbz.zig");

// DTOs & Services
pub const MangaJob = task_details.MangaJob;
pub const SeriesDetails = task_details.SeriesDetails;
pub const FetchSeriesDetailsService = task_details.FetchSeriesDetailsService;

pub const FetchChaptersInputs = task_chapters.FetchChaptersInputs;
pub const ChapterItem = task_chapters.ChapterItem;
pub const FetchChaptersService = task_chapters.FetchChaptersService;

pub const FetchChapterPagesInputs = task_pages.FetchChapterPagesInputs;
pub const ChapterPageItem = task_pages.ChapterPageItem;
pub const FetchChapterPagesService = task_pages.FetchChapterPagesService;

pub const DownloadedPageItem = task_download.DownloadedPageItem;
pub const DownloadChapterPageService = task_download.DownloadChapterPageService;

pub const PageWithContentType = task_detect.PageWithContentType;
pub const DetectContentTypeService = task_detect.DetectContentTypeService;

pub const AnalyzeImageInputs = task_analyze.AnalyzeImageInputs;
pub const AnalyzedPageItem = task_analyze.AnalyzedPageItem;
pub const AnalyzeImageService = task_analyze.AnalyzeImageService;

pub const GenerateComicInfoInputs = task_comicinfo.GenerateComicInfoInputs;
pub const ComicInfoOutput = task_comicinfo.ComicInfoOutput;
pub const GenerateComicInfoService = task_comicinfo.GenerateComicInfoService;

pub const BuildCbzArchiveInputs = task_cbz.BuildCbzArchiveInputs;
pub const CbzArchiveOutput = task_cbz.CbzArchiveOutput;
pub const BuildCbzArchiveService = task_cbz.BuildCbzArchiveService;

pub const UploadCbzInputs = task_upload_cbz.UploadCbzInputs;
pub const EgressDeliveryRecord = task_upload_cbz.EgressDeliveryRecord;
pub const UploadCbzService = task_upload_cbz.UploadCbzService;

// Backward-compatible runner functions
pub fn runFetchSeriesDetails(alloc: Allocator, ctx: TaskContext, job: MangaJob) !SeriesDetails {
    return MangaPluginContainer.runWithContext(FetchSeriesDetailsService, alloc, ctx, job);
}

pub fn runFetchChapters(alloc: Allocator, ctx: TaskContext, inputs: FetchChaptersInputs) ![]ChapterItem {
    return MangaPluginContainer.runWithContext(FetchChaptersService, alloc, ctx, inputs);
}

pub fn runFetchChapterPages(alloc: Allocator, ctx: TaskContext, inputs: FetchChapterPagesInputs) ![]ChapterPageItem {
    return MangaPluginContainer.runWithContext(FetchChapterPagesService, alloc, ctx, inputs);
}

// C-ABI Task Descriptors and Manifest assembled via MangaPluginContainer
pub const tasks = [_]abi.TaskDescriptor_ABI{
    MangaPluginContainer.defineTaskService(FetchSeriesDetailsService, .{
        .name = "fetch_series_details",
        .description = "Retrieves series metadata (title, author, artist, cover URL, available languages) from configured MangaSource",
    }),
    MangaPluginContainer.defineTaskService(FetchChaptersService, .{
        .name = "fetch_chapters",
        .description = "Retrieves chapters list for series in the specified language(s) from configured MangaSource",
    }),
    MangaPluginContainer.defineTaskService(FetchChapterPagesService, .{
        .name = "fetch_chapter_pages",
        .description = "Retrieves page URLs and metadata for a specific chapter from configured MangaSource",
        .lift = .elemental,
    }),
    MangaPluginContainer.defineTaskService(DownloadChapterPageService, .{
        .name = "download_chapter_page",
        .description = "Downloads a comic page image over HTTP with error recovery",
        .lift = .elemental,
    }),
    MangaPluginContainer.defineTaskService(DetectContentTypeService, .{
        .name = "detect_content_type",
        .description = "Inspects magic bytes to detect standard image formats (PNG, JPEG, WebP, GIF)",
        .lift = .elemental,
    }),
    MangaPluginContainer.defineTaskService(AnalyzeImageService, .{
        .name = "analyze_image",
        .description = "Simulates static image analysis and spread detection using configurable parameters",
        .lift = .elemental,
    }),
    MangaPluginContainer.defineTaskService(GenerateComicInfoService, .{
        .name = "generate_comicinfo",
        .description = "Generates standard Anansi ComicInfo XML metadata buffer for a chapter",
    }),
    MangaPluginContainer.defineTaskService(BuildCbzArchiveService, .{
        .name = "build_cbz_archive",
        .description = "Bundles page images and ComicInfo.xml into a standard .cbz archive using STORE compression",
    }),
    MangaPluginContainer.defineTaskService(UploadCbzService, .{
        .name = "upload_cbz",
        .description = "Synchronizes uploaded CBZ archives with a remote Komga server (library scan and series analysis)",
    }),
};

pub const manifest: abi.ModuleManifest_ABI = abi.defineManifest(
    "manga_catalog",
    .{ .major = 1, .minor = 0, .patch = 0 },
    &tasks,
);

comptime {
    if (@import("root") == @This()) {
        @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
    }
}

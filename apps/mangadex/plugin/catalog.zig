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

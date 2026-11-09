const std = @import("std");
const Allocator = std.mem.Allocator;

pub const YesNo = enum {
    Unknown,
    No,
    Yes,
};

pub const MangaType = enum {
    Unknown,
    No,
    Yes,
    YesAndRightToLeft,
};

pub const AgeRating = enum {
    Unknown,
    AdultsOnly,
    EarlyChildhood,
    Everyone,
    Everyone10Plus,
    G,
    KidsToAdults,
    Mature17Plus,
    PG,
    R18Plus,
    RatingPending,
    Teen,
};

pub const PageType = enum {
    FrontCover,
    InnerCover,
    Roundup,
    Story,
    Advertisement,
    Editorial,
    Letters,
    Preview,
    BackCover,
    Other,
    Deleted,
};

pub const ComicPageInfo = struct {
    image_index: u32,
    page_type: PageType = .Story,
    double_page: bool = false,
    image_size_bytes: ?u64 = null,
    key: ?[]const u8 = null,
};

pub const ComicInfo = struct {
    // Core Identification
    title: ?[]const u8 = null,
    series: []const u8,
    number: ?[]const u8 = null, // Chapter / Issue number
    count: ?u32 = null, // Total issues in series
    volume: ?[]const u8 = null,
    alternate_series: ?[]const u8 = null,

    // Narrative Metadata
    summary: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    year: ?u16 = null,
    month: ?u8 = null,
    day: ?u8 = null,

    // Credits
    writer: ?[]const u8 = null,
    penciller: ?[]const u8 = null,
    inker: ?[]const u8 = null,
    colorist: ?[]const u8 = null,
    letterer: ?[]const u8 = null,
    cover_artist: ?[]const u8 = null,
    editor: ?[]const u8 = null,
    translator: ?[]const u8 = null,

    // Classification & Taxonomy
    publisher: ?[]const u8 = null,
    imprint: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    web: ?[]const u8 = null,
    page_count: u32 = 0,
    language_iso: []const u8 = "en",

    // Structural Flags
    format: ?[]const u8 = null,
    black_and_white: YesNo = .Unknown,
    manga: MangaType = .YesAndRightToLeft,
    age_rating: AgeRating = .Unknown,

    // Detailed Page Layout (Optional)
    pages: []const ComicPageInfo = &.{},

    /// Frees memory allocated dynamically by reader.parse()
    pub fn deinit(self: *ComicInfo, allocator: Allocator) void {
        if (self.title) |v| allocator.free(v);
        allocator.free(self.series);
        if (self.number) |v| allocator.free(v);
        if (self.volume) |v| allocator.free(v);
        if (self.alternate_series) |v| allocator.free(v);
        if (self.summary) |v| allocator.free(v);
        if (self.notes) |v| allocator.free(v);
        if (self.writer) |v| allocator.free(v);
        if (self.penciller) |v| allocator.free(v);
        if (self.inker) |v| allocator.free(v);
        if (self.colorist) |v| allocator.free(v);
        if (self.letterer) |v| allocator.free(v);
        if (self.cover_artist) |v| allocator.free(v);
        if (self.editor) |v| allocator.free(v);
        if (self.translator) |v| allocator.free(v);
        if (self.publisher) |v| allocator.free(v);
        if (self.imprint) |v| allocator.free(v);
        if (self.genre) |v| allocator.free(v);
        if (self.tags) |v| allocator.free(v);
        if (self.web) |v| allocator.free(v);
        if (self.format) |v| allocator.free(v);
        if (self.language_iso.len > 0 and !std.mem.eql(u8, self.language_iso, "en")) {
            allocator.free(self.language_iso);
        }
        for (self.pages) |page| {
            if (page.key) |k| allocator.free(k);
        }
        if (self.pages.len > 0) {
            allocator.free(self.pages);
        }
    }
};

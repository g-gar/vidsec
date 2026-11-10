# 008 — ComicInfo Metadata Library (`comicinfo`)

| Metadata | Value |
| :--- | :--- |
| **ID** | `ARCH-008` |
| **Depends On** | [`ARCH-007`](./007-zip-archive-and-cbz-engine.md) |
| **Reference** | [Anansi Project ComicInfo Schema](https://github.com/anansi-project/comicinfo) (v2.0 / v2.1) |
| **Target Module** | `apps/mangadex/lib/comicinfo/` |
| **Status** | `COMPLETED` |

---

## 1. Purpose and Scope

`comicinfo` is a standalone Zig library dedicated to parsing, validating, and generating standard **`ComicInfo.xml`** metadata files for digital comic archives (`.cbz`).

* **Zero dependencies**: Pure Zig library with zero imports of `flowdata`, `mangadex_sdk`, or `komga_sdk`.
* **Standard Compliant**: Follows the [Anansi Project ComicInfo specification](https://github.com/anansi-project/comicinfo) used by Komga, Kavita, Tachiyomi/Mihon, and ComicRack.
* **Bi-directional**: Supports both **serialization** (creating XML to inject into new CBZ archives) and **deserialization** (reading existing metadata from inspected archives).

---

## 2. Core Data Model (`schema.zig`)

```zig
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
    number: ?[]const u8 = null,          // Chapter / Issue number
    count: ?u32 = null,                  // Total issues in series
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
};
```

---

## 3. Serialization Interface (`writer.zig`)

The serializer converts a `ComicInfo` struct into well-formed XML with standard entity escaping (`&`, `<`, `>`, `"`, `'`):

```zig
pub const ComicInfoWriter = struct {
    /// Serializes `ComicInfo` into an XML string.
    pub fn serialize(allocator: std.mem.Allocator, info: *const ComicInfo) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        var writer = buf.writer(allocator);
        try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
        try writer.writeAll("<ComicInfo xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n");

        try writeTag(writer, "Title", info.title);
        try writeTag(writer, "Series", info.series);
        try writeTag(writer, "Number", info.number);
        try writeTag(writer, "Volume", info.volume);
        try writeTag(writer, "Summary", info.summary);
        try writeTag(writer, "Writer", info.writer);
        try writeTag(writer, "Penciller", info.penciller);
        try writeTag(writer, "Translator", info.translator);
        try writeTag(writer, "Genre", info.genre);
        try writeTag(writer, "Tags", info.tags);
        try writeTag(writer, "Web", info.web);
        try writeTag(writer, "LanguageISO", info.language_iso);

        if (info.page_count > 0) {
            try writer.print("  <PageCount>{d}</PageCount>\n", .{info.page_count});
        }
        if (info.manga != .Unknown) {
            try writer.print("  <Manga>{s}</Manga>\n", .{@tagName(info.manga)});
        }

        try writer.writeAll("</ComicInfo>\n");
        return buf.toOwnedSlice(allocator);
    }
};
```

---

## 4. Module Directory Layout

Consistent with all other internal libraries in `apps/mangadex/lib/`, the module exposes `mod.zig` directly at its root and is registered centrally in `apps/mangadex/build.zig`:

```text
apps/mangadex/lib/comicinfo/
├── mod.zig                       # Root exports (ComicInfo, ComicInfoWriter, parse)
├── schema.zig                    # Structs and Enums following Anansi v2.1
├── writer.zig                    # XML builder with attribute/text escaping
└── reader.zig                    # XML parser populating ComicInfo struct
```

All test cases are centralized alongside the application suite in:
* `apps/mangadex/tests/comicinfo_test.zig` (run with `zig build test` from `apps/mangadex/`)

---

## 5. Next Steps for Implementation

When implementing `comicinfo`:
1. Use standard XML escaping for text nodes (`std.xml` or custom string buffer escaping).
2. Wire `comicinfo.serialize()` directly into `apps/mangadex/lib/zip_archive/` so `ZipArchiveWriter.addFileFromMemory("ComicInfo.xml", ...)` takes the generated buffer cleanly.

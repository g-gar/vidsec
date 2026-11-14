const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Uuid = []const u8;

pub const LocalizedString = struct {
    raw: std.json.Value,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !LocalizedString {
        const val = try std.json.Value.jsonParse(allocator, source, options);
        return .{ .raw = val };
    }

    pub fn get(self: LocalizedString, lang: []const u8) ?[]const u8 {
        if (self.raw != .object) return null;
        if (self.raw.object.get(lang)) |v| {
            if (v == .string) return v.string;
        }
        return null;
    }

    /// Returns the primary/canonical string present in the localization map.
    pub fn getPrimary(self: LocalizedString) ?[]const u8 {
        if (self.raw != .object) return null;
        var it = self.raw.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                return entry.value_ptr.*.string;
            }
        }
        return null;
    }

    pub fn getPreferred(self: LocalizedString, preferred_lang: []const u8) ?[]const u8 {
        if (self.raw != .object) return null;

        // 1. Exact match (e.g. "es-la" or "es")
        if (self.get(preferred_lang)) |s| return s;

        // 2. Base language or dialect fallback
        if (std.mem.indexOfScalar(u8, preferred_lang, '-')) |dash_idx| {
            // e.g. if preferred is "es-la", try base "es"
            if (self.get(preferred_lang[0..dash_idx])) |s| return s;
        } else {
            // e.g. if preferred is "es", try any "es-*" dialect such as "es-la"
            var it = self.raw.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, preferred_lang) and entry.value_ptr.* == .string) {
                    return entry.value_ptr.*.string;
                }
            }
        }

        // 3. Fallback to English
        if (!std.mem.eql(u8, preferred_lang, "en")) {
            if (self.get("en")) |s| return s;
        }

        // 4. Fallback to first available string in map
        var it = self.raw.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                return entry.value_ptr.*.string;
            }
        }
        return null;
    }
};

pub const RelationshipType = enum {
    manga,
    chapter,
    cover_art,
    author,
    artist,
    scanlation_group,
    tag,
    user,
    custom_list,
    creator,

    pub fn fromStr(s: []const u8) ?RelationshipType {
        return std.meta.stringToEnum(RelationshipType, s);
    }

    pub fn asStr(self: RelationshipType) []const u8 {
        return @tagName(self);
    }
};

pub const RelationshipAttr = enum {
    name,
    fileName,

    pub fn asStr(self: RelationshipAttr) []const u8 {
        return @tagName(self);
    }
};

pub const SortOrder = enum {
    asc,
    desc,

    pub fn asStr(self: SortOrder) []const u8 {
        return @tagName(self);
    }
};

pub const Relationship = struct {
    id: []const u8,
    type: []const u8,
    related: ?[]const u8 = null,
    attributes: ?std.json.Value = null,

    pub fn kind(self: Relationship) ?RelationshipType {
        return RelationshipType.fromStr(self.type);
    }

    pub fn attrString(self: Relationship, attr: RelationshipAttr) ?[]const u8 {
        const attrs = self.attributes orelse return null;
        if (attrs != .object) return null;
        const val = attrs.object.get(attr.asStr()) orelse return null;
        if (val != .string) return null;
        return val.string;
    }
};

pub const ApiError = struct {
    id: ?[]const u8 = null,
    status: ?i32 = null,
    title: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const ErrorResponse = struct {
    result: []const u8 = "error",
    errors: []const ApiError = &.{},
};

pub fn PagedResponse(comptime T: type) type {
    return struct {
        result: []const u8 = "ok",
        response: []const u8 = "collection",
        data: []const T = &.{},
        limit: u32 = 0,
        offset: u32 = 0,
        total: u32 = 0,
    };
}

pub fn EntityResponse(comptime T: type) type {
    return struct {
        result: []const u8 = "ok",
        response: []const u8 = "entity",
        data: T,
    };
}

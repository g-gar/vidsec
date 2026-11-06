const std = @import("std");
const Allocator = std.mem.Allocator;

const ContainerFormat = @import("container_format.zig").ContainerFormat;
const Region = @import("region.zig").Region;
const Track = @import("track.zig").Track;
const SampleExtent = @import("sample_extent.zig").SampleExtent;

/// Central Domain Intermediate Representation of a multimedia container.
pub const ContainerIR = struct {
    file_size: u64,
    format: ContainerFormat = .unknown,
    regions: std.ArrayListUnmanaged(Region) = .empty,
    tracks: std.ArrayListUnmanaged(Track) = .empty,
    samples: std.ArrayListUnmanaged(SampleExtent) = .empty,

    pub fn init(file_size: u64, format: ContainerFormat) ContainerIR {
        return .{
            .file_size = file_size,
            .format = format,
        };
    }

    pub fn deinit(self: *ContainerIR, allocator: Allocator) void {
        self.regions.deinit(allocator);
        self.tracks.deinit(allocator);
        self.samples.deinit(allocator);
    }

    pub fn addRegion(self: *ContainerIR, allocator: Allocator, region: Region) !u32 {
        try self.regions.append(allocator, region);
        return @intCast(self.regions.items.len - 1);
    }

    pub fn addTrack(self: *ContainerIR, allocator: Allocator, track: Track) !u32 {
        try self.tracks.append(allocator, track);
        return @intCast(self.tracks.items.len - 1);
    }

    pub fn addSample(self: *ContainerIR, allocator: Allocator, sample: SampleExtent) !u32 {
        try self.samples.append(allocator, sample);
        return @intCast(self.samples.items.len - 1);
    }

    // -------------------------------------------------------------------------
    // 1. Árbol de Regiones y Navegación
    // -------------------------------------------------------------------------

    /// Finds a region by its unique identifier.
    pub fn findRegionById(self: ContainerIR, id: u32) ?Region {
        for (self.regions.items) |r| {
            if (r.id == id) return r;
        }
        return null;
    }

    /// Finds the first region matching a given 4-byte FourCC / tag.
    pub fn findFirstByTag(self: ContainerIR, tag: [4]u8) ?Region {
        for (self.regions.items) |r| {
            if (std.mem.eql(u8, &r.tag, &tag)) return r;
        }
        return null;
    }

    /// Collects an allocated slice of all root regions (parent_id == null).
    pub fn getRootRegions(self: ContainerIR, allocator: Allocator) ![]Region {
        var list: std.ArrayListUnmanaged(Region) = .empty;
        errdefer list.deinit(allocator);
        for (self.regions.items) |r| {
            if (r.parent_id == null) {
                try list.append(allocator, r);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    /// Collects an allocated slice of direct children belonging to parent_id.
    pub fn getChildren(self: ContainerIR, parent_id: u32, allocator: Allocator) ![]Region {
        var list: std.ArrayListUnmanaged(Region) = .empty;
        errdefer list.deinit(allocator);
        for (self.regions.items) |r| {
            if (r.parent_id) |p| {
                if (p == parent_id) {
                    try list.append(allocator, r);
                }
            }
        }
        return list.toOwnedSlice(allocator);
    }

    /// Removes a region by its identifier. Returns true if found and removed.
    pub fn removeRegion(self: *ContainerIR, region_id: u32) bool {
        for (self.regions.items, 0..) |r, i| {
            if (r.id == region_id) {
                _ = self.regions.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // 2. Geometría y Contabilidad de Espacio
    // -------------------------------------------------------------------------

    /// Computes the highest end offset among all root regions (parent_id == null).
    pub fn highestRootEnd(self: ContainerIR) u64 {
        var highest: u64 = 0;
        for (self.regions.items) |r| {
            if (r.parent_id == null) {
                highest = @max(highest, r.effectiveEnd());
            }
        }
        return highest;
    }

    /// Returns unreferenced trailing slack bytes past the highest root region.
    pub fn calculateSlackBytes(self: ContainerIR) u64 {
        const root_end = self.highestRootEnd();
        if (self.file_size > root_end) {
            return self.file_size - root_end;
        }
        return 0;
    }

    /// Computes total payload bytes across all declared regions.
    pub fn totalPayloadBytes(self: ContainerIR) u64 {
        var total: u64 = 0;
        for (self.regions.items) |r| {
            total += r.payloadSize();
        }
        return total;
    }

    // -------------------------------------------------------------------------
    // 3. Pistas y Muestras para Procesamiento de Vídeo
    // -------------------------------------------------------------------------

    /// Finds a track by its identifier.
    pub fn findTrackById(self: ContainerIR, track_id: u32) ?Track {
        for (self.tracks.items) |t| {
            if (t.id == track_id) return t;
        }
        return null;
    }

    /// Finds the primary (first) video track in the container.
    pub fn findPrimaryVideoTrack(self: ContainerIR) ?Track {
        for (self.tracks.items) |t| {
            if (t.kind == .video) return t;
        }
        return null;
    }

    /// Computes duration in seconds for a given track.
    pub fn getTrackDurationSeconds(self: ContainerIR, track_id: u32) ?f64 {
        if (self.findTrackById(track_id)) |t| {
            return t.durationSeconds();
        }
        return null;
    }

    /// Collects an allocated slice of all sample extents belonging to a given track.
    pub fn getSamplesForTrack(self: ContainerIR, track_id: u32, allocator: Allocator) ![]SampleExtent {
        var list: std.ArrayListUnmanaged(SampleExtent) = .empty;
        errdefer list.deinit(allocator);
        for (self.samples.items) |s| {
            if (s.track_id == track_id) {
                try list.append(allocator, s);
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

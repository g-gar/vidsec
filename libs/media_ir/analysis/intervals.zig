const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents a half-open byte interval `[start, end)` with an optional label `tag`.
pub const Interval = struct {
    start: u64,
    end: u64,
    tag: []const u8 = "",

    pub inline fn len(self: Interval) u64 {
        return if (self.end > self.start) self.end - self.start else 0;
    }

    pub inline fn isEmpty(self: Interval) bool {
        return self.end <= self.start;
    }

    /// Returns `true` if `self` and `other` share at least one interior byte (`max(a.start, b.start) < min(a.end, b.end)`).
    pub inline fn overlaps(self: Interval, other: Interval) bool {
        if (self.isEmpty() or other.isEmpty()) return false;
        return self.start < other.end and other.start < self.end;
    }

    /// Returns `true` if `other` is completely contained within `self` (`self.start <= other.start and other.end <= self.end`).
    pub inline fn contains(self: Interval, other: Interval) bool {
        return self.start <= other.start and other.end <= self.end;
    }

    pub fn lessThan(_: void, a: Interval, b: Interval) bool {
        if (a.start != b.start) return a.start < b.start;
        return a.end < b.end;
    }
};

/// Returns `true` if any pair of intervals in an already start-sorted slice overlaps (`zero-allocation`, $O(N)$).
/// Used for sample-overlap decompression bomb detection.
pub fn hasOverlapInSorted(sorted_intervals: []const Interval) bool {
    var max_end: u64 = 0;
    var has_prev = false;
    for (sorted_intervals) |iv| {
        if (iv.isEmpty()) continue;
        if (has_prev and iv.start < max_end) {
            return true;
        }
        if (!has_prev or iv.end > max_end) {
            max_end = iv.end;
            has_prev = true;
        }
    }
    return false;
}

/// Sorts `intervals` in-place by `.start` ascending and returns `true` if any two intervals overlap (`zero-allocation`).
pub fn sortAndCheckOverlap(intervals: []Interval) bool {
    std.mem.sort(Interval, intervals, {}, Interval.lessThan);
    return hasOverlapInSorted(intervals);
}

/// Computes the set difference $\mathcal{G}(M) = M \setminus \bigcup_{j} I_j$ between each parent container
/// interval $M \in \text{containers}$ (e.g. `mdat` or `LIST:movi`) and the union of covered intervals $I_j \in \text{covered}$
/// (e.g. sample extents from `stbl`/`Cues`/`idx1`).
/// Returns an owned slice of disjoint unreferenced gap intervals (`unreferenced_media_slack`).
pub fn computeComplementGaps(
    allocator: Allocator,
    containers: []const Interval,
    covered: []const Interval,
) Allocator.Error![]Interval {
    var gaps: std.ArrayListUnmanaged(Interval) = .empty;
    errdefer gaps.deinit(allocator);

    if (containers.len == 0) {
        return gaps.toOwnedSlice(allocator);
    }

    const sorted = try allocator.dupe(Interval, covered);
    defer allocator.free(sorted);
    std.mem.sort(Interval, sorted, {}, Interval.lessThan);

    for (containers) |m| {
        if (m.isEmpty()) continue;
        var cursor: u64 = m.start;

        for (sorted) |s| {
            if (s.end <= cursor) continue;
            if (s.start >= m.end) break;

            const clamped_start = @max(s.start, m.start);
            const clamped_end = @min(s.end, m.end);

            if (clamped_start > cursor) {
                try gaps.append(allocator, .{
                    .start = cursor,
                    .end = clamped_start,
                    .tag = m.tag,
                });
            }
            if (clamped_end > cursor) {
                cursor = clamped_end;
            }
        }

        if (cursor < m.end) {
            try gaps.append(allocator, .{
                .start = cursor,
                .end = m.end,
                .tag = m.tag,
            });
        }
    }

    return gaps.toOwnedSlice(allocator);
}

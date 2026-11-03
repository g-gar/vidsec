const std = @import("std");
const Allocator = std.mem.Allocator;
const Severity = @import("severity.zig").Severity;
const Finding = @import("finding.zig").Finding;
const VulnerabilityType = @import("vulnerability_type.zig").VulnerabilityType;

/// Container for forensics findings.
pub const FindingList = struct {
    items: std.ArrayListUnmanaged(Finding) = .empty,

    pub fn init() FindingList {
        return .{};
    }

    pub fn deinit(self: *FindingList, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn append(self: *FindingList, allocator: Allocator, finding: Finding) !void {
        try self.items.append(allocator, finding);
    }

    pub fn hasVulnerability(self: FindingList, vuln: VulnerabilityType) bool {
        for (self.items.items) |f| {
            if (f.vulnerability == vuln) return true;
        }
        return false;
    }

    pub fn countBySeverity(self: FindingList, severity: Severity) usize {
        var count: usize = 0;
        for (self.items.items) |f| {
            if (f.severity == severity) count += 1;
        }
        return count;
    }
};

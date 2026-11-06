const std = @import("std");
const Allocator = std.mem.Allocator;
const Severity = @import("severity.zig").Severity;
const DiagnosticFinding = @import("diagnostic_finding.zig").DiagnosticFinding;

/// Managed list of format diagnostic findings.
pub const DiagnosticList = struct {
    items: std.ArrayListUnmanaged(DiagnosticFinding) = .empty,

    pub fn init() DiagnosticList {
        return .{};
    }

    pub fn deinit(self: *DiagnosticList, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn append(self: *DiagnosticList, allocator: Allocator, finding: DiagnosticFinding) !void {
        try self.items.append(allocator, finding);
    }

    pub fn countBySeverity(self: DiagnosticList, severity: Severity) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == severity) count += 1;
        }
        return count;
    }

    pub fn hasRuleId(self: DiagnosticList, rule_id: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.rule_id, rule_id)) return true;
        }
        return false;
    }
};

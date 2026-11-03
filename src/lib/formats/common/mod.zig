const std = @import("std");

pub const entities = @import("entities/mod.zig");
pub const services = @import("services/mod.zig");

// Re-export Entities
pub const ir = entities.ir;
pub const Region = entities.Region;
pub const RegionRole = entities.RegionRole;
pub const ContainerIR = entities.ContainerIR;
pub const ByteSource = entities.ByteSource;
pub const ElementRole = entities.ElementRole;
pub const ElementSpan = entities.ElementSpan;
pub const ElementContext = entities.ElementContext;
pub const Severity = entities.Severity;
pub const DiagnosticFinding = entities.DiagnosticFinding;
pub const DiagnosticList = entities.DiagnosticList;

// Re-export Services
pub const InLineCheckFn = services.InLineCheckFn;
pub const InLineCheck = services.InLineCheck;
pub const checkGaps = services.checkGaps;
pub const checkOverlaps = services.checkOverlaps;
pub const checkTrailingOverlay = services.checkTrailingOverlay;
pub const StructuralAuditor = services.StructuralAuditor;

test {
    std.testing.refAllDecls(@This());
}

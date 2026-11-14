const isobmff = @import("../box/mod.zig");
const FourCC = isobmff.FourCC;

/// Decoded parameters of the `ftyp` (File Type Box).
pub const FtypInfo = struct {
    major_brand: FourCC,
    minor_version: u32,
    compatible_brands: []const FourCC,

    pub fn hasBrand(self: FtypInfo, brand: FourCC) bool {
        if (self.major_brand.equals(brand)) return true;
        for (self.compatible_brands) |cb| {
            if (cb.equals(brand)) return true;
        }
        return false;
    }
};

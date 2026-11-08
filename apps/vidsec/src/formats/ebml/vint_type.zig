const std = @import("std");

/// Decoded Variable Size Integer (VINT) per RFC 8794 Section 4.
pub const Vint = struct {
    /// Raw integer representation of the octet sequence (big-endian)
    raw_value: u64,
    /// Length of the VINT octet sequence (1 to 8 octets)
    length: u8,
    /// Numerical value with the leading length-marker bit cleared
    data_value: u64,
    /// True if all data bits are set to 1 (indicating unknown or undefined data size)
    is_all_ones: bool,
};

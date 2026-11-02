const std = @import("std");

/// 4-character code (FourCC) identifying an ISOBMFF box/atom.
pub const FourCC = struct {
    bytes: [4]u8,

    pub fn init(str: *const [4]u8) FourCC {
        return .{ .bytes = str.* };
    }

    pub fn fromSlice(slice: []const u8) ?FourCC {
        if (slice.len < 4) return null;
        return .{ .bytes = slice[0..4].* };
    }

    pub fn fromInt(val: u32) FourCC {
        return .{ .bytes = std.mem.nativeToBig(u32, val) };
    }

    pub fn toBigEndianInt(self: FourCC) u32 {
        return std.mem.readInt(u32, &self.bytes, .big);
    }

    pub fn equals(self: FourCC, other: FourCC) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn isPrintable(self: FourCC) bool {
        for (self.bytes) |b| {
            if (b < 32 or b > 126) return false;
        }
        return true;
    }

    pub fn format(
        self: FourCC,
        writer: anytype,
    ) !void {
        if (self.isPrintable()) {
            try writer.print("{s}", .{self.bytes});
        } else {
            try writer.print("0x{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
                self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            });
        }
    }
};

// ============================================================================
// Standard ISOBMFF Box Types (ISO/IEC 14496-12)
// ============================================================================

pub const BOX_FTYP = FourCC.init("ftyp");
pub const BOX_MOOV = FourCC.init("moov");
pub const BOX_MVHD = FourCC.init("mvhd");
pub const BOX_TRAK = FourCC.init("trak");
pub const BOX_TKHD = FourCC.init("tkhd");
pub const BOX_EDTS = FourCC.init("edts");
pub const BOX_ELST = FourCC.init("elst");
pub const BOX_MDIA = FourCC.init("mdia");
pub const BOX_MDHD = FourCC.init("mdhd");
pub const BOX_HDLR = FourCC.init("hdlr");
pub const BOX_MINF = FourCC.init("minf");
pub const BOX_VMHD = FourCC.init("vmhd");
pub const BOX_SMHD = FourCC.init("smhd");
pub const BOX_HMHD = FourCC.init("hmhd");
pub const BOX_NMHD = FourCC.init("nmhd");
pub const BOX_DINF = FourCC.init("dinf");
pub const BOX_DREF = FourCC.init("dref");
pub const BOX_STBL = FourCC.init("stbl");
pub const BOX_STSD = FourCC.init("stsd");
pub const BOX_STTS = FourCC.init("stts");
pub const BOX_CTTS = FourCC.init("ctts");
pub const BOX_CSLG = FourCC.init("cslg");
pub const BOX_STSC = FourCC.init("stsc");
pub const BOX_STSZ = FourCC.init("stsz");
pub const BOX_STZ2 = FourCC.init("stz2");
pub const BOX_STCO = FourCC.init("stco");
pub const BOX_CO64 = FourCC.init("co64");
pub const BOX_STSS = FourCC.init("stss");
pub const BOX_STSH = FourCC.init("stsh");
pub const BOX_PADB = FourCC.init("padb");
pub const BOX_SDTP = FourCC.init("sdtp");
pub const BOX_SBGP = FourCC.init("sbgp");
pub const BOX_SGPD = FourCC.init("sgpd");
pub const BOX_SUBS = FourCC.init("subs");
pub const BOX_SAIZ = FourCC.init("saiz");
pub const BOX_SAIO = FourCC.init("saio");

// Media data & padding
pub const BOX_MDAT = FourCC.init("mdat");
pub const BOX_FREE = FourCC.init("free");
pub const BOX_SKIP = FourCC.init("skip");
pub const BOX_WIDE = FourCC.init("wide"); // QuickTime legacy padding atom

// User data & Metadata
pub const BOX_UDTA = FourCC.init("udta");
pub const BOX_META = FourCC.init("meta");
pub const BOX_ILST = FourCC.init("ilst");
pub const BOX_ILOC = FourCC.init("iloc");
pub const BOX_IPRO = FourCC.init("ipro");
pub const BOX_IINF = FourCC.init("iinf");
pub const BOX_XML  = FourCC.init("xml ");
pub const BOX_BXML = FourCC.init("bxml");
pub const BOX_PITM = FourCC.init("pitm");

// Fragmented MP4 (fMP4)
pub const BOX_MOOF = FourCC.init("moof");
pub const BOX_MFHD = FourCC.init("mfhd");
pub const BOX_TRAF = FourCC.init("traf");
pub const BOX_TFHD = FourCC.init("tfhd");
pub const BOX_TRUN = FourCC.init("trun");
pub const BOX_MFRA = FourCC.init("mfra");
pub const BOX_TFRA = FourCC.init("tfra");
pub const BOX_MFRO = FourCC.init("mfro");
pub const BOX_MVEX = FourCC.init("mvex");
pub const BOX_TREX = FourCC.init("trex");
pub const BOX_MEHD = FourCC.init("mehd");
pub const BOX_SIDX = FourCC.init("sidx");
pub const BOX_SSIX = FourCC.init("ssix");
pub const BOX_PRFT = FourCC.init("prft");

// Protection & Encryption
pub const BOX_SINF = FourCC.init("sinf");
pub const BOX_SCHI = FourCC.init("schi");
pub const BOX_SCHM = FourCC.init("schm");
pub const BOX_FRMA = FourCC.init("frma");
pub const BOX_ENCA = FourCC.init("enca");
pub const BOX_ENCV = FourCC.init("encv");

// Progressive download / Chapters / UUID
pub const BOX_PDIN = FourCC.init("pdin");
pub const BOX_CHPL = FourCC.init("chpl");
pub const BOX_UUID = FourCC.init("uuid");

/// Known ISOBMFF container boxes whose payload is composed entirely of sub-boxes.
pub const CONTAINER_BOXES = [_]FourCC{
    BOX_MOOV,
    BOX_TRAK,
    BOX_EDTS,
    BOX_MDIA,
    BOX_MINF,
    BOX_DINF,
    BOX_STBL,
    BOX_MVEX,
    BOX_MOOF,
    BOX_TRAF,
    BOX_MFRA,
    BOX_UDTA,
    BOX_SINF,
    BOX_SCHI,
    BOX_ILST,
};

/// Returns true if the box is a pure container box that holds nested child boxes.
pub fn isContainerBox(fourcc: FourCC) bool {
    for (CONTAINER_BOXES) |cb| {
        if (fourcc.equals(cb)) return true;
    }
    return false;
}

/// Returns true if the box is commonly used for padding, alignment or dead slack space.
pub fn isPaddingBox(fourcc: FourCC) bool {
    return fourcc.equals(BOX_FREE) or
        fourcc.equals(BOX_SKIP) or
        fourcc.equals(BOX_WIDE);
}

/// Role classification for the Intermediate Representation (IR).
pub const BoxRole = enum {
    header,
    metadata,
    media_data,
    index,
    padding,
    unknown,

    pub fn asText(self: BoxRole) []const u8 {
        return switch (self) {
            .header => "header",
            .metadata => "metadata",
            .media_data => "media_data",
            .index => "index",
            .padding => "padding",
            .unknown => "unknown",
        };
    }

    /// Maps a standard ISOBMFF FourCC to its default IR role.
    pub fn fromFourCC(fourcc: FourCC) BoxRole {
        if (fourcc.equals(BOX_FTYP) or fourcc.equals(BOX_PDIN)) return .header;
        if (fourcc.equals(BOX_MDAT)) return .media_data;
        if (isPaddingBox(fourcc)) return .padding;
        if (fourcc.equals(BOX_STCO) or
            fourcc.equals(BOX_CO64) or
            fourcc.equals(BOX_STSC) or
            fourcc.equals(BOX_STSZ) or
            fourcc.equals(BOX_STZ2) or
            fourcc.equals(BOX_STTS) or
            fourcc.equals(BOX_CTTS) or
            fourcc.equals(BOX_STSS) or
            fourcc.equals(BOX_SIDX)) return .index;
        if (isContainerBox(fourcc) or
            fourcc.equals(BOX_MVHD) or
            fourcc.equals(BOX_TKHD) or
            fourcc.equals(BOX_MDHD) or
            fourcc.equals(BOX_HDLR) or
            fourcc.equals(BOX_VMHD) or
            fourcc.equals(BOX_SMHD) or
            fourcc.equals(BOX_STSD) or
            fourcc.equals(BOX_META) or
            fourcc.equals(BOX_XML) or
            fourcc.equals(BOX_BXML) or
            fourcc.equals(BOX_CHPL) or
            fourcc.equals(BOX_UUID)) return .metadata;

        return .unknown;
    }
};

/// High-level header representation of an ISOBMFF Box.
pub const BoxHeader = struct {
    fourcc: FourCC,
    offset: u64,
    size: u64,
    header_size: u8,
    is_extended_size: bool,
    is_eof_size: bool,

    pub fn payloadOffset(self: BoxHeader) u64 {
        return self.offset + self.header_size;
    }

    pub fn payloadSize(self: BoxHeader) u64 {
        if (self.is_eof_size) return 0;
        return self.size -| self.header_size;
    }

    pub fn endOffset(self: BoxHeader) u64 {
        if (self.is_eof_size) return std.math.maxInt(u64);
        return self.offset + self.size;
    }
};

/// FullBox header extending a standard Box with 1-byte version and 3-byte (24-bit) flags.
pub const FullBoxHeader = struct {
    box: BoxHeader,
    version: u8,
    flags: u24,

    pub fn payloadOffset(self: FullBoxHeader) u64 {
        return self.box.payloadOffset() + 4;
    }

    pub fn payloadSize(self: FullBoxHeader) u64 {
        const p_size = self.box.payloadSize();
        return p_size -| 4;
    }
};

/// Flattened representation of a parsed Box within the container tree.
pub const ParsedBox = struct {
    id: u32,
    parent_id: ?u32,
    depth: u16,
    header: BoxHeader,
    is_full_box: bool = false,
    version: u8 = 0,
    flags: u24 = 0,
    role: BoxRole = .unknown,
    child_count: u32 = 0,
};

/// Structural syntax anomalies and integrity issues detected during ISOBMFF parsing.
pub const ParserIssueCode = enum(u8) {
    box_size_invalid = 0,
    box_size_overflow = 1,
    large_size_invalid = 2,
    eof_box_not_at_end = 3,
    non_printable_fourcc = 4,
    unknown_fourcc = 5,
    truncated_header = 6,
    container_cycle_or_overlap = 7,
    excessive_nesting_depth = 8,
    missing_ftyp = 9,
    ftyp_not_first_box = 10,
    multiple_ftyp = 11,
    missing_moov = 12,
    multiple_moov = 13,
    orphaned_trailing_data = 14,
    unindexed_slack_in_mdat = 15,

    pub fn asText(self: ParserIssueCode) []const u8 {
        return switch (self) {
            .box_size_invalid => "ISOBMFF_BOX_SIZE_INVALID",
            .box_size_overflow => "ISOBMFF_BOX_SIZE_OVERFLOW",
            .large_size_invalid => "ISOBMFF_LARGE_SIZE_INVALID",
            .eof_box_not_at_end => "ISOBMFF_EOF_BOX_NOT_AT_END",
            .non_printable_fourcc => "ISOBMFF_NON_PRINTABLE_FOURCC",
            .unknown_fourcc => "ISOBMFF_UNKNOWN_FOURCC",
            .truncated_header => "ISOBMFF_TRUNCATED_HEADER",
            .container_cycle_or_overlap => "ISOBMFF_CONTAINER_CYCLE_OR_OVERLAP",
            .excessive_nesting_depth => "ISOBMFF_EXCESSIVE_NESTING_DEPTH",
            .missing_ftyp => "ISOBMFF_MISSING_FTYP",
            .ftyp_not_first_box => "ISOBMFF_FTYP_NOT_FIRST_BOX",
            .multiple_ftyp => "ISOBMFF_MULTIPLE_FTYP",
            .missing_moov => "ISOBMFF_MISSING_MOOV",
            .multiple_moov => "ISOBMFF_MULTIPLE_MOOV",
            .orphaned_trailing_data => "ISOBMFF_ORPHANED_TRAILING_DATA",
            .unindexed_slack_in_mdat => "ISOBMFF_UNINDEXED_SLACK_IN_MDAT",
        };
    }
};

/// Structural fact/issue emitted by the pure ISOBMFF parser (without triage/security policy).
pub const ParserIssue = struct {
    code: ParserIssueCode,
    offset: u64,
    fourcc: ?FourCC = null,
    details: []const u8 = "",
};

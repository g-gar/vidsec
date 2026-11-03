const std = @import("std");
const FourCC = @import("fourcc.zig").FourCC;

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
pub const BOX_WIDE = FourCC.init("wide");

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

const std = @import("std");

// EBML Header (RFC 8794)
pub const ID_EBML_HEADER           = 0x1A45DFA3; // Master
pub const ID_EBML_VERSION          = 0x4286;     // uint
pub const ID_EBML_READ_VERSION     = 0x42F7;     // uint
pub const ID_EBML_MAX_ID_LENGTH    = 0x42F2;     // uint
pub const ID_EBML_MAX_SIZE_LENGTH  = 0x42F3;     // uint
pub const ID_DOC_TYPE              = 0x4282;     // string
pub const ID_DOC_TYPE_VERSION      = 0x4287;     // uint
pub const ID_DOC_TYPE_READ_VERSION = 0x4285;     // uint
pub const ID_CRC32                 = 0xBF;       // binary (4 bytes)
pub const ID_VOID                  = 0xEC;       // binary (padding)

// Matroska Segment & Top-Level Elements
pub const ID_SEGMENT               = 0x18538067; // Master
pub const ID_SEEK_HEAD             = 0x114D9B74; // Master
pub const ID_SEEK_ENTRY            = 0x4DBB;     // Master
pub const ID_SEEK_ID               = 0x53AB;     // binary
pub const ID_SEEK_POSITION         = 0x53AC;     // uint

pub const ID_INFO                  = 0x1549A966; // Master
pub const ID_TIMECODE_SCALE        = 0x2AD7B1;   // uint
pub const ID_DURATION              = 0x4489;     // float
pub const ID_MUXING_APP            = 0x4D80;     // utf-8
pub const ID_WRITING_APP           = 0x5741;     // utf-8
pub const ID_DATE_UTC              = 0x4461;     // date

pub const ID_TRACKS                = 0x1654AE6B; // Master
pub const ID_TRACK_ENTRY           = 0xAE;       // Master
pub const ID_TRACK_NUMBER          = 0xD7;       // uint
pub const ID_TRACK_UID             = 0x73C5;     // uint
pub const ID_TRACK_TYPE            = 0x83;       // uint (1=video, 2=audio, 3=complex, 0x11=sub)
pub const ID_CODEC_ID              = 0x86;       // string
pub const ID_CODEC_PRIVATE         = 0x63A2;     // binary
pub const ID_CODEC_NAME            = 0x258688;   // utf-8
pub const ID_DEFAULT_DURATION      = 0x23E383;   // uint (ns per frame)

// Video & Audio sub-masters
pub const ID_VIDEO                 = 0xE0;       // Master
pub const ID_PIXEL_WIDTH           = 0xB0;       // uint
pub const ID_PIXEL_HEIGHT          = 0xBA;       // uint
pub const ID_DISPLAY_WIDTH         = 0x54B0;     // uint
pub const ID_DISPLAY_HEIGHT        = 0x54BA;     // uint

pub const ID_AUDIO                 = 0xE1;       // Master
pub const ID_SAMPLING_FREQUENCY    = 0xB5;       // float
pub const ID_CHANNELS              = 0x9F;       // uint
pub const ID_BIT_DEPTH             = 0x6264;     // uint

// Clusters & Media Blocks
pub const ID_CLUSTER               = 0x1F43B675; // Master
pub const ID_CLUSTER_TIMECODE      = 0xE7;       // uint
pub const ID_SIMPLE_BLOCK          = 0xA3;       // binary
pub const ID_BLOCK_GROUP           = 0xA0;       // Master
pub const ID_BLOCK                 = 0xA1;       // binary
pub const ID_BLOCK_DURATION        = 0x9B;       // uint

// Cues, Attachments, Chapters, Tags
pub const ID_CUES                  = 0x1C53BB6B; // Master
pub const ID_CUE_POINT             = 0xBB;       // Master
pub const ID_ATTACHMENTS           = 0x1941A469; // Master
pub const ID_ATTACHED_FILE         = 0x61A7;     // Master
pub const ID_FILE_NAME             = 0x466E;     // utf-8
pub const ID_FILE_MIME_TYPE        = 0x4660;     // string
pub const ID_FILE_DATA             = 0x465C;     // binary
pub const ID_CHAPTERS              = 0x1043A770; // Master
pub const ID_TAGS                  = 0x1254C367; // Master

/// Master Elements whose payload is formed entirely of nested sub-elements.
pub fn isMasterElement(id: u32) bool {
    return switch (id) {
        ID_EBML_HEADER,
        ID_SEGMENT,
        ID_SEEK_HEAD,
        ID_SEEK_ENTRY,
        ID_INFO,
        ID_TRACKS,
        ID_TRACK_ENTRY,
        ID_VIDEO,
        ID_AUDIO,
        ID_CLUSTER,
        ID_BLOCK_GROUP,
        ID_CUES,
        ID_CUE_POINT,
        ID_ATTACHMENTS,
        ID_ATTACHED_FILE,
        ID_CHAPTERS,
        ID_TAGS,
        => true,
        else => false,
    };
}

const std = @import("std");
const vidsec = @import("vidsec");
const analyzer = vidsec.plugin.analyzer;

const Verdict = analyzer.Verdict;
const analyzeSlice = analyzer.analyzeSlice;

fn fillHighEntropyPayload(buf: []u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.fill(buf);
}

test "Triage Scenario 1: Valid sample video files (MP4, MKV, AVI, TS 188B & 204B) pass with zero flags" {
    var file_buf: [16384]u8 = undefined;

    // 1. Valid MP4 (.mp4) with high-entropy mdat payload
    fillHighEntropyPayload(&file_buf, 0xCAFE1234);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(file_buf[0..mp4_hdr.len], mp4_hdr);

    const mp4_res = analyzeSlice(&file_buf, .{ .file_path = "/samples/clean_video.mp4" });
    try std.testing.expectEqual(Verdict.pass, mp4_res.verdict);
    try std.testing.expectEqualStrings("mp4", mp4_res.identified_format);
    try std.testing.expectEqualStrings("isobmff", mp4_res.detected_family);
    try std.testing.expect(mp4_res.extension_match);
    try std.testing.expect(!mp4_res.hasAnyFlags());
    try std.testing.expect(mp4_res.mid_entropy >= 7.3);

    // 2. Valid MKV (.mkv)
    fillHighEntropyPayload(&file_buf, 0xBEEF5678);
    const mkv_hdr = "\x1A\x45\xDF\xA3\x9F\x42\x86\x81\x01\x42\xF7\x81\x01\x42\x82\x88matroska\x42\x87\x81\x04";
    @memcpy(file_buf[0..mkv_hdr.len], mkv_hdr);

    const mkv_res = analyzeSlice(&file_buf, .{ .file_path = "/samples/movie.mkv" });
    try std.testing.expectEqual(Verdict.pass, mkv_res.verdict);
    try std.testing.expectEqualStrings("mkv", mkv_res.identified_format);
    try std.testing.expectEqualStrings("ebml", mkv_res.detected_family);
    try std.testing.expect(mkv_res.extension_match);
    try std.testing.expect(!mkv_res.hasAnyFlags());

    // 3. Valid AVI (.avi) with matching RIFF size (file_size - 8)
    fillHighEntropyPayload(&file_buf, 0xABCD9999);
    @memcpy(file_buf[0..4], "RIFF");
    std.mem.writeInt(u32, file_buf[4..8], @intCast(file_buf.len - 8), .little);
    @memcpy(file_buf[8..12], "AVI ");

    const avi_res = analyzeSlice(&file_buf, .{ .file_path = "/samples/clip.avi" });
    try std.testing.expectEqual(Verdict.pass, avi_res.verdict);
    try std.testing.expectEqualStrings("avi", avi_res.identified_format);
    try std.testing.expectEqualStrings("riff", avi_res.detected_family);
    try std.testing.expect(!avi_res.hasAnyFlags());

    // 4. Valid MPEG-TS (.ts) with 188-byte and 204-byte strides
    fillHighEntropyPayload(&file_buf, 0x13572468);
    file_buf[0] = 0x47;
    file_buf[188] = 0x47;
    file_buf[376] = 0x47;
    file_buf[564] = 0x47;
    const ts188_res = analyzeSlice(&file_buf, .{ .file_path = "/samples/broadcast.ts" });
    try std.testing.expectEqual(Verdict.pass, ts188_res.verdict);
    try std.testing.expectEqualStrings("ts", ts188_res.identified_format);

    fillHighEntropyPayload(&file_buf, 0x97531864);
    file_buf[0] = 0x47;
    file_buf[204] = 0x47;
    file_buf[408] = 0x47;
    file_buf[612] = 0x47;
    const ts204_res = analyzeSlice(&file_buf, .{ .file_path = "/samples/dvbt_stream.mts" });
    try std.testing.expectEqual(Verdict.pass, ts204_res.verdict);
    try std.testing.expectEqualStrings("ts", ts204_res.identified_format);
}

test "Triage Scenario 2: Video file concatenated with a ZIP at the end (polyglot.mp4) and JSON report contract" {
    var polyglot_buf: [16384]u8 = undefined;
    fillHighEntropyPayload(&polyglot_buf, 0x42424242);

    // Valid MP4 header at offset 0
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(polyglot_buf[0..mp4_hdr.len], mp4_hdr);

    // Inject a suspicious PowerShell string in Head Buffer (offset 256)
    const ps_cmd = "powershell -enc JABzAD0ATgBlAHcALQBPAGIAagBlAGMAdAA=";
    @memcpy(polyglot_buf[256 .. 256 + ps_cmd.len], ps_cmd);

    // Append a ZIP End of Central Directory (PK\x05\x06) 22 bytes before EOF
    const eocd_offset: usize = polyglot_buf.len - 22;
    @memcpy(polyglot_buf[eocd_offset .. eocd_offset + 4], "PK\x05\x06");

    const res = analyzeSlice(&polyglot_buf, .{ .file_path = "/path/to/sample.mp4" });
    try std.testing.expectEqual(Verdict.flagged, res.verdict);
    try std.testing.expect(res.hasFlag(.secondary_signature_zip_eocd_found));
    try std.testing.expect(res.hasFlag(.suspicious_string_detected));
    try std.testing.expectEqual(@as(?u64, eocd_offset), res.zip_eocd_offset);

    var json_buf: [1024]u8 = undefined;
    const json = res.formatJson(&json_buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"verdict\":\"FLAGGED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SECONDARY_SIGNATURE_ZIP_EOCD_FOUND\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SUSPICIOUS_STRING_DETECTED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"powershell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"zip_eocd_offset\":16362") != null);
}

test "Triage Scenario 3: Text file renamed to .mp4 (DROP) and Low-Entropy Video Mock (FLAGGED)" {
    // 1. Plain ASCII text file renamed to .mp4 -> DROP (PRIMARY_MAGIC_NOT_VIDEO + EXTENSION_MAGIC_MISMATCH + SUSPICIOUS_LOW_ENTROPY)
    var text_buf: [4096]u8 = @splat('A');
    @memcpy(text_buf[0..28], "This is just a plain text!! ");
    const txt_res = analyzeSlice(&text_buf, .{ .file_path = "fake_video.mp4" });
    try std.testing.expectEqual(Verdict.drop, txt_res.verdict);
    try std.testing.expect(!txt_res.extension_match);
    try std.testing.expect(txt_res.hasFlag(.primary_magic_not_video));
    try std.testing.expect(txt_res.hasFlag(.extension_magic_mismatch));
    try std.testing.expect(txt_res.hasFlag(.suspicious_low_entropy));

    // 2. Valid MP4 header at 0x00, but zero-filled body (H = 0.0 < 5.5) -> FLAGGED (SUSPICIOUS_LOW_ENTROPY)
    var low_ent_mp4: [8192]u8 = @splat(0x00);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(low_ent_mp4[0..mp4_hdr.len], mp4_hdr);
    const low_res = analyzeSlice(&low_ent_mp4, .{ .file_path = "zero_padded.mp4" });
    try std.testing.expectEqual(Verdict.flagged, low_res.verdict);
    try std.testing.expect(low_res.hasFlag(.suspicious_low_entropy));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), low_res.mid_entropy, 0.001);
}

test "Triage Scenario 4: Sample with MZ stub or /bin/sh inserted in the first 4 KB" {
    var buf: [16384]u8 = undefined;
    fillHighEntropyPayload(&buf, 0x77778888);

    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(buf[0..mp4_hdr.len], mp4_hdr);

    // Insert DOS MZ stub ("MZ\x90\x00") at offset 512 and "!/bin/sh" at offset 1024 inside the first 4 KB
    @memcpy(buf[512..516], "MZ\x90\x00");
    @memcpy(buf[1024..1033], "#!/bin/sh");

    const res = analyzeSlice(&buf, .{ .file_path = "injected.mp4" });
    try std.testing.expectEqual(Verdict.flagged, res.verdict);
    try std.testing.expect(res.hasFlag(.secondary_executable_in_head));
    try std.testing.expect(res.hasFlag(.suspicious_string_detected));
    try std.testing.expectEqual(@as(?u64, 512), res.secondary_exec_offset);
}

test "Black Box Tasks: Native typed execution under std.testing.allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1. probeFileTask on mock MP4
    var mp4_buf: [4096]u8 = undefined;
    fillHighEntropyPayload(&mp4_buf, 0x11223344);
    const mp4_hdr = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2mp41";
    @memcpy(mp4_buf[0..mp4_hdr.len], mp4_hdr);

    const probe_out = try analyzer.probeFileTask(alloc, &mp4_buf);
    try std.testing.expectEqualStrings("mp4", probe_out.identified_format);
    try std.testing.expectEqualStrings("isobmff", probe_out.detected_family);
    try std.testing.expect(probe_out.file_size == 4096);

    // 2. probeIsobmffTask
    const isobmff_out = try analyzer.probeIsobmffTask(alloc, &mp4_buf);
    try std.testing.expect(isobmff_out.has_ftyp);

    // 3. probeMp4Task
    const mp4_out = try analyzer.probeMp4Task(alloc, &mp4_buf);
    try std.testing.expectEqualStrings("isom", mp4_out.major_brand);

    // 4. probeEbmlTask & probeMkvTask on mock MKV
    var mkv_buf: [4096]u8 = undefined;
    fillHighEntropyPayload(&mkv_buf, 0x55667788);
    const mkv_hdr = "\x1A\x45\xDF\xA3\x9F\x42\x86\x81\x01\x42\xF7\x81\x01\x42\x82\x88matroska\x42\x87\x81\x04";
    @memcpy(mkv_buf[0..mkv_hdr.len], mkv_hdr);

    const ebml_out = try analyzer.probeEbmlTask(alloc, &mkv_buf);
    try std.testing.expectEqualStrings("matroska", ebml_out.doc_type);
    try std.testing.expect(ebml_out.element_count > 0);

    const mkv_out = try analyzer.probeMkvTask(alloc, &mkv_buf);
    try std.testing.expect(mkv_out.track_count >= 0);

    // 5. probeRiffTask on mock AVI
    var riff_buf: [4096]u8 = undefined;
    fillHighEntropyPayload(&riff_buf, 0x99AABBCC);
    @memcpy(riff_buf[0..4], "RIFF");
    std.mem.writeInt(u32, riff_buf[4..8], @intCast(riff_buf.len - 8), .little);
    @memcpy(riff_buf[8..12], "AVI ");

    const riff_out = try analyzer.probeRiffTask(alloc, &riff_buf);
    try std.testing.expectEqualStrings("AVI ", riff_out.form_type);

    // 6. Test decoupled modular namespaces (triage, audit, forensics)
    const triage_out = try analyzer.triage.probeFile(alloc, &mp4_buf);
    try std.testing.expectEqualStrings("mp4", triage_out.identified_format);

    const audit_mp4_out = try analyzer.audit.mp4.auditMp4(alloc, &mp4_buf);
    try std.testing.expectEqualStrings("isom", audit_mp4_out.major_brand);

    const slacks = [_]vidsec.ir.IrUnreferencedSlackRow{
        .{
            .slack_id = 1,
            .region_tag = "trailing_slack",
            .file_offset = 100,
            .byte_length = 500,
        },
    };
    const findings = try analyzer.forensics_analysis.entropy.scanEntropy(alloc, &mp4_buf, &slacks, .{ .min_entropy = 5.0 });
    try std.testing.expect(findings.len > 0);

    // 7. Verify plugin library organization and analysis alias
    try std.testing.expect(vidsec.plugin.analysis == vidsec.plugin.analyzer);
    try std.testing.expect(@hasDecl(vidsec.plugin.lib, "isobmff"));
    try std.testing.expect(@hasDecl(vidsec.plugin.lib, "ebml"));
    try std.testing.expect(@hasDecl(vidsec.plugin.lib, "mp4"));
    try std.testing.expect(@hasDecl(vidsec.plugin.lib, "mkv"));
    try std.testing.expect(@hasDecl(vidsec.plugin.lib, "riff"));
    try std.testing.expect(@hasDecl(vidsec.plugin.lib, "ir"));

    // 8. Verify pure media lowering functions (zero ABI, zero ctx)
    const media = analyzer.lowering.media;
    const test_tracks = [_]media.TrackInput{
        .{ .track_id = 1, .codec_tag = "avc1", .width = 1920, .height = 1080 },
        .{ .track_id = 2, .codec_tag = "mp4a", .width = 0, .height = 0 },
    };
    var cfg_counter: i64 = 1;
    const lowered_mp4_configs = try media.lowerMp4Tracks(alloc, &test_tracks, &cfg_counter);
    defer alloc.free(lowered_mp4_configs);
    try std.testing.expectEqual(@as(usize, 2), lowered_mp4_configs.len);
    try std.testing.expectEqual(@as(i64, 1), lowered_mp4_configs[0].config_id);
    try std.testing.expectEqualStrings("avc1", lowered_mp4_configs[0].codec_tag);
    try std.testing.expectEqual(@as(i64, 1920), lowered_mp4_configs[0].container_width);

    const test_samples = [_]media.SampleInput{
        .{ .track_id = 1, .sample_index = 1, .source_tag = "mdat", .target_offset = 1000, .byte_size = 500 },
    };
    var ext_counter: i64 = 1;
    const lowered_samples = try media.lowerSampleExtents(alloc, &test_samples, &ext_counter);
    defer alloc.free(lowered_samples);
    try std.testing.expectEqual(@as(usize, 1), lowered_samples.len);
    try std.testing.expectEqual(@as(u64, 1500), lowered_samples[0].end_offset);

    // 9. Verify pure container lowering functions (zero ABI, zero ctx)
    const container = analyzer.lowering.container;
    const test_boxes = [_]container.RegionInput{
        .{ .id = 1, .parent_id = null, .tag = "ftyp", .role = "header", .header_offset = 0, .payload_offset = 8, .size = 32 },
        .{ .id = 2, .parent_id = null, .tag = "moov", .role = "index", .header_offset = 32, .payload_offset = 40, .size = 100 },
    };
    const lowered_container = try container.lowerIsobmffContainer(alloc, 132, 1, "mp4", &test_boxes);
    defer alloc.free(lowered_container.regions);
    defer alloc.free(lowered_container.overflow_findings);
    try std.testing.expectEqual(@as(usize, 2), lowered_container.regions.len);
    try std.testing.expectEqual(@as(u64, 132), lowered_container.metadata.highest_root_end);
    try std.testing.expectEqual(@as(usize, 0), lowered_container.overflow_findings.len);
}

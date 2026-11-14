const std = @import("std");
pub const repository = @import("yaml_file_repository.zig");
pub const YamlFileRepository = repository.YamlFileRepository;

test "YamlFileRepository parses jobs from yaml file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sample_yaml =
        \\- series_id: "a1c7c817-4e59-42b5-bd33-02047732da38"
        \\  title: "Frieren: Beyond Journey's End"
        \\  languages: ["es", "en"]
        \\  chapters: "all"
        \\- series_id: "a7774250-3785-4bda-ac68-6d4fb245ab5f"
        \\  title: "Chainsaw Man"
        \\  languages: ["es"]
        \\  chapters: "latest:5"
    ;

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "jobs.yaml", .data = sample_yaml });

    const real_path = try tmp.dir.realPathFileAlloc(std.testing.io, "jobs.yaml", allocator);
    defer allocator.free(real_path);

    var repo = try YamlFileRepository.init(allocator, real_path);
    defer repo.deinit();

    try std.testing.expectEqual(@as(usize, 2), repo.recordCount("jobs"));

    const payload = repo.readPayload("jobs");
    try std.testing.expect(payload != null);
    try std.testing.expectEqual(@as(usize, 2), payload.?.len);

    // Verify first job
    const job0 = repo.jobs[0];
    try std.testing.expectEqualStrings("a1c7c817-4e59-42b5-bd33-02047732da38", job0.getParam("series_id").?);
    try std.testing.expectEqualStrings("Frieren: Beyond Journey's End", job0.getParam("title").?);
    try std.testing.expectEqualStrings("es,en", job0.getParam("languages").?);
    try std.testing.expectEqualStrings("all", job0.getParam("chapters").?);

    // Verify second job
    const job1 = repo.jobs[1];
    try std.testing.expectEqualStrings("a7774250-3785-4bda-ac68-6d4fb245ab5f", job1.getParam("series_id").?);
    try std.testing.expectEqualStrings("Chainsaw Man", job1.getParam("title").?);
    try std.testing.expectEqualStrings("es", job1.getParam("languages").?);
    try std.testing.expectEqualStrings("latest:5", job1.getParam("chapters").?);
}

test "YamlFileRepository via factory createHeap" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sample_yaml =
        \\jobs:
        \\  - id: custom_id
        \\    series_id: "test-uuid"
        \\    enabled: true
    ;

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "jobs.yaml", .data = sample_yaml });

    const real_path = try tmp.dir.realPathFileAlloc(std.testing.io, "jobs.yaml", allocator);
    defer allocator.free(real_path);

    var storage_repo = try YamlFileRepository.createHeap(allocator, &.{
        .{ .key = "path", .value = real_path },
    });
    defer storage_repo.deinit();

    try std.testing.expectEqual(@as(usize, 1), storage_repo.recordCount("jobs"));
    const handle = storage_repo.readPayload("jobs");
    try std.testing.expect(handle != null);
}

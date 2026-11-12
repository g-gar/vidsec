//! Flowdata Reactive Router & Service Catalog Tests (ARCH-018).
//!
//! Comprehensive verification suite:
//! 1. Schema compatibility / Auto `canHandle` via comptime reflection.
//! 2. Custom domain predicate (`canHandle` explicit override).
//! 3. Innate engine merge with ambient context (`system.timestamp`, `system.hour`, `system.cpu_load`).
//! 4. Unary `where:` predicate filtering with short-circuit rejection.
//! 5. Intermediate sub-DAG re-entry (dynamic entry at middle or leaf step).
//! 6. Outbound re-routing loop (Vidsec Triage -> CDR -> IR cycle).

const std = @import("std");
const testing = std.testing;
const flowdata = @import("flowdata");
const plugin = @import("flowdata_plugin");
const datasource_ext = @import("flowdata_extensions").datasource;
const MemoryRepository = datasource_ext.MemoryRepository;

// -------------------------------------------------------------------------
// Sample Schemas
// -------------------------------------------------------------------------

pub const MangaTarget = struct {
    series_id: []const u8,
};

pub const MangaDetails = struct {
    series_id: []const u8,
    title: []const u8,
};

pub const MangaChapter = struct {
    chapter_id: []const u8,
    number: u32,
};

pub const VideoItem = struct {
    video_id: []const u8,
    codec: []const u8 = "h264",
};

pub const ProblemMedia = struct {
    video_id: []const u8,
    is_problematic: bool,
    anomaly_score: f64 = 0.95,
};

pub const CleanMedia = struct {
    video_id: []const u8,
    is_clean: bool,
    sanitized_bytes: usize = 1024,
};

pub const AuditReport = struct {
    video_id: []const u8,
    status: []const u8,
};

pub const ScheduledJobInput = struct {
    task_id: []const u8,
    cpu_usage: f64 = 0.0,
    timestamp: i64 = 0,
    hour: u8 = 0,
};

// -------------------------------------------------------------------------
// Task Services
// -------------------------------------------------------------------------

pub const AutoMatchMangaService = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *AutoMatchMangaService, alloc: std.mem.Allocator, in: MangaTarget) !MangaDetails {
        _ = alloc;
        return .{
            .series_id = in.series_id,
            .title = "Auto Matched Manga",
        };
    }
};

pub const AutoMatchChapterService = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *AutoMatchChapterService, alloc: std.mem.Allocator, in: MangaChapter) !MangaChapter {
        _ = alloc;
        return .{
            .chapter_id = in.chapter_id,
            .number = in.number + 10,
        };
    }
};

pub const CustomCdrSanitizerService = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn canHandle(_: *CustomCdrSanitizerService, payload: plugin.PayloadHandle_ABI) bool {
        if (payload.getReflected("is_problematic")) |val| {
            return val.asBool() orelse false;
        }
        return false;
    }

    pub fn execute(_: *CustomCdrSanitizerService, alloc: std.mem.Allocator, in: ProblemMedia) !CleanMedia {
        _ = alloc;
        return .{
            .video_id = in.video_id,
            .is_clean = true,
            .sanitized_bytes = 2048,
        };
    }
};

pub const CustomIrAnalysisService = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn canHandle(_: *CustomIrAnalysisService, payload: plugin.PayloadHandle_ABI) bool {
        if (payload.getReflected("is_clean")) |val| {
            return val.asBool() orelse false;
        }
        return false;
    }

    pub fn execute(_: *CustomIrAnalysisService, alloc: std.mem.Allocator, in: CleanMedia) !AuditReport {
        _ = alloc;
        return .{
            .video_id = in.video_id,
            .status = "IR_VERIFIED_CLEAN",
        };
    }
};

pub const TriageAuditorService = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *TriageAuditorService, alloc: std.mem.Allocator, in: VideoItem) !ProblemMedia {
        _ = alloc;
        return .{
            .video_id = in.video_id,
            .is_problematic = true,
            .anomaly_score = 0.99,
        };
    }
};

pub const AmbientScheduledService = struct {
    pub const Context = struct {
        pub const concurrency_safe = true;
    };

    pub fn execute(_: *AmbientScheduledService, alloc: std.mem.Allocator, in: ScheduledJobInput) !ScheduledJobInput {
        _ = alloc;
        return in;
    }
};

// -------------------------------------------------------------------------
// Test Cases
// -------------------------------------------------------------------------

test "ARCH-018: Automatic structural compatibility canHandle selects matching task" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const desc_manga = plugin.defineTaskService(AutoMatchMangaService, .{ .name = "match_manga" });
    const desc_chapter = plugin.defineTaskService(AutoMatchChapterService, .{ .name = "match_chapter" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ desc_manga, desc_chapter };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "router_auto_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("router_auto_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_manga
        \\        uses: router_auto_test/match_manga
        \\
        \\      - id: step_chapter
        \\        uses: router_auto_test/match_chapter
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var router = try engine.createRouter("main");
    defer router.deinit();

    // 1. Emit MangaChapter record: matches step_chapter (Node 1)
    const ch_item = MangaChapter{ .chapter_id = "chap-99", .number = 1 };
    const ch_payload = flowdata.PayloadHandle.fromScalar(MangaChapter, &ch_item);

    const matches_ch = try router.findMatchingNodes(ch_payload);
    defer alloc.free(matches_ch);

    try testing.expectEqual(@as(usize, 1), matches_ch.len);
    try testing.expectEqual(@as(usize, 1), matches_ch[0]); // step_chapter is node 1

    // 2. Emit MangaTarget record: matches step_manga (Node 0)
    const tg_item = MangaTarget{ .series_id = "manga-01" };
    const tg_payload = flowdata.PayloadHandle.fromScalar(MangaTarget, &tg_item);

    const matches_tg = try router.findMatchingNodes(tg_payload);
    defer alloc.free(matches_tg);

    try testing.expectEqual(@as(usize, 1), matches_tg.len);
    try testing.expectEqual(@as(usize, 0), matches_tg[0]); // step_manga is node 0
}

test "ARCH-018: Custom domain predicate canHandle override filters by payload content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const desc_cdr = plugin.defineTaskService(CustomCdrSanitizerService, .{ .name = "cdr_sanitizer" });
    var tasks = [_]plugin.TaskDescriptor_ABI{desc_cdr};
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "router_custom_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("router_custom_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: cdr_step
        \\        uses: router_custom_test/cdr_sanitizer
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var router = try engine.createRouter("main");
    defer router.deinit();

    // 1. Non-problematic item: canHandle returns false -> 0 matches
    const clean_item = ProblemMedia{
        .video_id = "v-clean",
        .is_problematic = false,
    };
    const clean_p = flowdata.PayloadHandle.fromScalar(ProblemMedia, &clean_item);
    const matches_clean = try router.findMatchingNodes(clean_p);
    defer alloc.free(matches_clean);
    try testing.expectEqual(@as(usize, 0), matches_clean.len);

    // 2. Problematic item: canHandle returns true -> 1 match
    const bad_item = ProblemMedia{
        .video_id = "v-infected",
        .is_problematic = true,
    };
    const bad_p = flowdata.PayloadHandle.fromScalar(ProblemMedia, &bad_item);
    const matches_bad = try router.findMatchingNodes(bad_p);
    defer alloc.free(matches_bad);
    try testing.expectEqual(@as(usize, 1), matches_bad.len);

    // 3. Route execution
    const summary = try router.route(bad_p, .{ .enable_outbound_loop = false });
    try testing.expectEqual(@as(usize, 1), summary.steps_executed);
}

test "ARCH-018: Innate engine merge binds ambient context (timestamp, hour, cpu_load)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const desc_ambient = plugin.defineTaskService(AmbientScheduledService, .{ .name = "scheduled_task" });
    var tasks = [_]plugin.TaskDescriptor_ABI{desc_ambient};
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "router_ambient_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("router_ambient_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: run_job
        \\        uses: router_ambient_test/scheduled_task
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    // Set custom ambient context values
    const custom_ambient = flowdata.AmbientContext.withValues(alloc, 1700000000_000000000, 14, 42.5);
    engine.withAmbient(custom_ambient);

    var router = try engine.createRouter("main");
    defer router.deinit();

    const job = ScheduledJobInput{ .task_id = "job-42" };
    const summary = try router.route(flowdata.PayloadHandle.fromScalar(ScheduledJobInput, &job), .{
        .enable_outbound_loop = false,
    });

    try testing.expectEqual(@as(usize, 1), summary.steps_executed);
}

test "ARCH-018: Unary where: predicate filtering with short-circuit rejection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const desc_ambient = plugin.defineTaskService(AmbientScheduledService, .{ .name = "scheduled_task" });
    var tasks = [_]plugin.TaskDescriptor_ABI{desc_ambient};
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "router_unary_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("router_unary_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: throttled_job
        \\        uses: router_unary_test/scheduled_task
        \\        inputs:
        \\          cpu_usage:
        \\            from: system.cpu_load
        \\            where: "< 80"
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    const job = ScheduledJobInput{ .task_id = "job-throttled" };

    // 1. High CPU load (95.0) -> unary where: "< 80" fails -> 0 matches, 0 steps executed
    engine.withAmbient(flowdata.AmbientContext.withValues(alloc, 1000, 10, 95.0));
    var router_high = try engine.createRouter("main");
    defer router_high.deinit();

    const high_matches = try router_high.findMatchingNodes(flowdata.PayloadHandle.fromScalar(ScheduledJobInput, &job));
    defer alloc.free(high_matches);
    try testing.expectEqual(@as(usize, 0), high_matches.len);

    const high_summary = try router_high.route(flowdata.PayloadHandle.fromScalar(ScheduledJobInput, &job), .{});
    try testing.expectEqual(@as(usize, 0), high_summary.steps_executed);

    // 2. Low CPU load (50.0) -> unary where: "< 80" passes -> 1 match, 1 step executed
    engine.withAmbient(flowdata.AmbientContext.withValues(alloc, 1000, 10, 50.0));
    var router_low = try engine.createRouter("main");
    defer router_low.deinit();

    const low_matches = try router_low.findMatchingNodes(flowdata.PayloadHandle.fromScalar(ScheduledJobInput, &job));
    defer alloc.free(low_matches);
    try testing.expectEqual(@as(usize, 1), low_matches.len);

    const low_summary = try router_low.route(flowdata.PayloadHandle.fromScalar(ScheduledJobInput, &job), .{});
    try testing.expectEqual(@as(usize, 1), low_summary.steps_executed);
}

test "ARCH-018: Intermediate sub-DAG re-entry skips upstream steps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const desc_manga = plugin.defineTaskService(AutoMatchMangaService, .{ .name = "fetch_details" });
    const desc_chapter = plugin.defineTaskService(AutoMatchChapterService, .{ .name = "download_chapter" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ desc_manga, desc_chapter };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "router_subdag_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("router_subdag_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: step_root
        \\        uses: router_subdag_test/fetch_details
        \\
        \\      - id: step_leaf
        \\        uses: router_subdag_test/download_chapter
        \\        after: [step_root]
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var router = try engine.createRouter("main");
    defer router.deinit();

    // Emitting a MangaChapter matches only step_leaf (Node 1).
    // The sub-DAG entry activates only Node 1. Node 0 is skipped!
    const chapter = MangaChapter{ .chapter_id = "c-intermediate", .number = 42 };
    const summary = try router.route(flowdata.PayloadHandle.fromScalar(MangaChapter, &chapter), .{
        .enable_outbound_loop = false,
    });

    try testing.expectEqual(@as(usize, 1), summary.steps_executed);
}

test "ARCH-018: Outbound re-routing loop executes Vidsec Triage -> CDR -> IR cycle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const desc_triage = plugin.defineTaskService(TriageAuditorService, .{ .name = "triage_task" });
    const desc_cdr = plugin.defineTaskService(CustomCdrSanitizerService, .{ .name = "cdr_task" });
    const desc_ir = plugin.defineTaskService(CustomIrAnalysisService, .{ .name = "ir_task" });

    var tasks = [_]plugin.TaskDescriptor_ABI{ desc_triage, desc_cdr, desc_ir };
    const manifest = plugin.ModuleManifest_ABI{
        .module_name = "router_loop_test",
        .module_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .tasks_ptr = &tasks,
        .tasks_len = tasks.len,
    };

    var mod_reg = flowdata.plugin.ModuleRegistry.init(alloc);
    defer mod_reg.deinit();
    try mod_reg.registerStaticModule("router_loop_test", &manifest);

    var repo_reg = flowdata.repository.RepositoryRegistry.init(alloc);
    defer repo_reg.deinit();
    try datasource_ext.registerDefaultDrivers(&repo_reg);

    const pipeline_yaml =
        \\version: 2
        \\pipelines:
        \\  main:
        \\    steps:
        \\      - id: triage
        \\        uses: router_loop_test/triage_task
        \\        outputs:
        \\          problem_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: cdr
        \\        uses: router_loop_test/cdr_task
        \\        outputs:
        \\          clean_out:
        \\            datasource: pipeline_memory
        \\
        \\      - id: ir
        \\        uses: router_loop_test/ir_task
        \\        outputs:
        \\          report_out:
        \\            datasource: pipeline_memory
    ;

    var env_interp = flowdata.yaml.EnvInterpolator.init(false);
    const ast = try flowdata.yaml.loadPipelineAstFromYaml(alloc, pipeline_yaml, .{
        .env_interpolator = &env_interp,
    });

    var engine = flowdata.PipelineEngine.init(alloc, ast, &mod_reg, &repo_reg);
    defer engine.deinit();

    var router = try engine.createRouter("main");
    defer router.deinit();

    // Ingress video item:
    // 1. triage_task executes and outputs ProblemMedia { is_problematic = true }
    // 2. Router re-routes ProblemMedia to cdr_task (canHandle is true)
    // 3. cdr_task executes and outputs CleanMedia { is_clean = true }
    // 4. Router re-routes CleanMedia to ir_task (canHandle is true)
    // 5. ir_task executes and outputs AuditReport
    // Total steps executed across the recursive re-routing loop: 3 steps!
    const video = VideoItem{ .video_id = "sample_raw.mp4" };
    const summary = try router.route(flowdata.PayloadHandle.fromScalar(VideoItem, &video), .{
        .enable_outbound_loop = true,
    });

    try testing.expectEqual(@as(usize, 3), summary.steps_executed);
    try testing.expectEqual(@as(usize, 2), router.total_re_routed);
}

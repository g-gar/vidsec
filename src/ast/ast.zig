const std = @import("std");
const Allocator = std.mem.Allocator;
const repository = @import("../repository/mod.zig");
const network = @import("../transport/outbound/mod.zig");

// =============================================================================
// RUNTIME, NETWORK, AND DATASOURCE SPECIFICATIONS
// =============================================================================

pub const SchedulerMode = enum {
    sequential,
    dag,
};

pub const RoutingMode = enum {
    directed,
    type_driven,
    hybrid,
};

pub const RuntimeConfig = struct {
    /// Worker thread quota for multi-core data parallelism.
    /// Default is 1 (deterministic single-threaded).
    workers: usize = 1,
    /// Default virtual network adapter assigned to steps that omit `network:`.
    default_network: []const u8 = "isolated",
    /// Scheduler mode: sequential (default) or dag (ARCH-017).
    scheduler: SchedulerMode = .sequential,
    /// Routing strategy: directed (default), type_driven, or hybrid (ARCH-023).
    routing: RoutingMode = .directed,
    /// Maximum live in-flight memory allowed across unconsumed channels (ARCH-017 §3.5).
    max_inflight_bytes: ?usize = null,
    /// When true, prevents freeing intermediate channels until pipeline completion.
    retain_all: bool = false,
};

pub const ConfigParam = repository.ConfigParam;
pub const KeyValueParam = ConfigParam;

// Canonical Network Specifications imported directly from `src/network/contracts/`
pub const NetworkDriver = network.contracts.NetworkDriver;
pub const ProxyStrategy = network.contracts.ProxyStrategy;
pub const PolicyDefaultAction = network.contracts.PolicyDefaultAction;
pub const PortRangeSpec = network.contracts.PortRangeSpec;
pub const AllowRuleSpec = network.contracts.AllowRuleSpec;
pub const NetworkPolicySpec = network.contracts.NetworkPolicySpec;
pub const PoolSpec = network.contracts.PoolSpec;
pub const TimeoutsSpec = network.contracts.TimeoutsSpec;
pub const BackpressureSpec = network.contracts.BackpressureSpec;
pub const RateLimitSpec = network.contracts.RateLimitSpec;
pub const CircuitBreakerSpec = network.contracts.CircuitBreakerSpec;
pub const ProxyEndpointSpec = network.contracts.ProxyEndpointSpec;
pub const ProxyPoolSpec = network.contracts.ProxyPoolSpec;
pub const DnsSpec = network.contracts.DnsSpec;
pub const TlsSpec = network.contracts.TlsSpec;
pub const RedirectRuleSpec = network.contracts.RedirectRuleSpec;
pub const RouteRuleSpec = network.contracts.RouteRuleSpec;
pub const CaptureSpec = network.contracts.CaptureSpec;
pub const NetworkSpec = network.contracts.NetworkSpec;

// =============================================================================
// RECONCILIATION / RECON WORKLOAD JOBS SPECIFICATION (CORE AST)
// =============================================================================

pub const JobSpec = struct {
    id: []const u8,
    datasource: ?[]const u8 = null,
    enabled: bool = true,
    params: []const KeyValueParam = &.{},

    pub fn getParam(self: JobSpec, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "id")) return self.id;
        if (self.datasource) |ds| {
            if (std.mem.eql(u8, key, "datasource")) return ds;
        }
        if (std.mem.eql(u8, key, "enabled")) {
            return if (self.enabled) "true" else "false";
        }
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }
};

/// Specification for an open-ended storage datasource (memory, sqlite, elasticsearch, kafka, s3, etc.).
/// Driver resolution is handled dynamically via registry without requiring core recompilation.
pub const DatasourceRole = enum {
    source,
    sink,
    duplex,
};

pub const DatasourceSpec = struct {
    id: []const u8,
    /// Open-ended driver / storage backend identifier (e.g. "memory", "sqlite", "file_store", "elasticsearch", "s3", etc.)
    driver: []const u8,
    role: DatasourceRole = .duplex,
    params: []const KeyValueParam = &.{},

    pub fn getParam(self: DatasourceSpec, key: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    /// Alias for driver identifier
    pub fn kind(self: DatasourceSpec) []const u8 {
        return self.driver;
    }
};

// =============================================================================
// STREAM ALGEBRA & INBOUND BINDINGS
// =============================================================================

pub const AlgebraOp = enum {
    none,
    merge,
    zip,
    join,
    slice,
};

pub const InboundStreamExpr = struct {
    op: AlgebraOp = .none,
    /// Reference to a step channel, e.g., "lower_mp4.regions" or "file"
    stream_ref: ?[]const u8 = null,
    /// Nested streams for multi-stream algebra (merge, zip, join)
    sub_streams: []const InboundStreamExpr = &.{},
    /// Equi-join key parameter for join(a, b, on: "key")
    join_key: ?[]const u8 = null,
    /// Offset for slice(s, offset, count)
    slice_offset: usize = 0,
    /// Count for slice(s, offset, count)
    slice_count: usize = 0,

    pub fn direct(stream_ref: []const u8) InboundStreamExpr {
        return .{
            .op = .none,
            .stream_ref = stream_ref,
        };
    }

    pub fn merge(streams: []const InboundStreamExpr) InboundStreamExpr {
        return .{
            .op = .merge,
            .sub_streams = streams,
        };
    }

    pub fn zip(a: InboundStreamExpr, b: InboundStreamExpr, alloc: Allocator) Allocator.Error!InboundStreamExpr {
        const sub = try alloc.alloc(InboundStreamExpr, 2);
        sub[0] = a;
        sub[1] = b;
        return .{
            .op = .zip,
            .sub_streams = sub,
        };
    }

    pub fn join(a: InboundStreamExpr, b: InboundStreamExpr, key: []const u8, alloc: Allocator) Allocator.Error!InboundStreamExpr {
        const sub = try alloc.alloc(InboundStreamExpr, 2);
        sub[0] = a;
        sub[1] = b;
        return .{
            .op = .join,
            .sub_streams = sub,
            .join_key = key,
        };
    }
};

pub const InputBindingSpec = struct {
    param_name: []const u8,
    expr: InboundStreamExpr,
    where_filter: ?[]const u8 = null,
};

pub const ChannelOutputSpec = struct {
    name: []const u8,
    from_field: ?[]const u8 = null,
    schema_ref: ?[]const u8 = null,
    datasource: []const u8 = "default",
    filter: ?[]const u8 = null,
    retain: bool = false,
};

// =============================================================================
// STEP AND ROUTER SPECIFICATIONS
// =============================================================================

pub const TaskStepSpec = struct {
    id: []const u8,
    module: []const u8,
    task: []const u8,
    /// Virtual network adapter bindings (single or multi-homed). Empty inherits `runtime.default_network`.
    networks: []const []const u8 = &.{},
    inputs: []const InputBindingSpec = &.{},
    where_filter: ?[]const u8 = null,
    /// Concurrency override for this task (null = inherit runtime.workers)
    concurrency: ?usize = null,
    static_params: []const KeyValueParam = &.{},
    outputs: []const ChannelOutputSpec = &.{},
    /// Explicit step ordering dependencies (ARCH-017 §3.1).
    after: []const []const u8 = &.{},

    pub fn getInput(self: TaskStepSpec, param_name: []const u8) ?InboundStreamExpr {
        for (self.inputs) |in| {
            if (std.mem.eql(u8, in.param_name, param_name)) return in.expr;
        }
        return null;
    }

    pub fn primaryNetwork(self: TaskStepSpec, default_network: []const u8) []const u8 {
        if (self.networks.len > 0) return self.networks[0];
        return default_network;
    }
};

pub const RouterCaseSpec = struct {
    when_predicate: []const u8,
    goto_pipeline: []const u8,
};

pub const RouterStepSpec = struct {
    id: []const u8,
    cases: []const RouterCaseSpec = &.{},
    default_pipeline: ?[]const u8 = null,
};

pub const StepNode = union(enum) {
    task: TaskStepSpec,
    router: RouterStepSpec,

    pub fn id(self: StepNode) []const u8 {
        return switch (self) {
            .task => |t| t.id,
            .router => |r| r.id,
        };
    }
};

pub const PipelineDecl = struct {
    name: []const u8,
    routing: ?RoutingMode = null,
    steps: []const StepNode = &.{},

    /// Returns the pipeline's explicit routing mode, or falls back to `default_routing`.
    pub fn effectiveRouting(self: PipelineDecl, default_routing: RoutingMode) RoutingMode {
        return self.routing orelse default_routing;
    }
};

/// Specification for an external plugin module (.so).
pub const ModuleSpec = struct {
    name: []const u8,
    path: []const u8,
};

// =============================================================================
// UNIFIED PIPELINE AST (CANONICAL IN-MEMORY EXECUTION PLAN)
// =============================================================================

pub const PipelineAST = struct {
    runtime: RuntimeConfig = .{},
    modules: []const ModuleSpec = &.{},
    networks: []const NetworkSpec = &.{},
    datasources: []const DatasourceSpec = &.{},
    jobs: []const JobSpec = &.{},
    pipelines: []const PipelineDecl = &.{},
    entrypoint: ?[]const u8 = null,

    pub fn getEntrypoint(self: PipelineAST) ?[]const u8 {
        if (self.entrypoint) |ep| return ep;
        if (self.getPipeline("main")) |_| return "main";
        if (self.pipelines.len > 0) return self.pipelines[0].name;
        return null;
    }

    pub fn getModule(self: PipelineAST, name: []const u8) ?ModuleSpec {
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    pub fn getNetwork(self: PipelineAST, id: []const u8) ?NetworkSpec {
        for (self.networks) |n| {
            if (std.mem.eql(u8, n.id, id)) return n;
        }
        return null;
    }

    pub fn getPipeline(self: PipelineAST, name: []const u8) ?PipelineDecl {
        for (self.pipelines) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn getDatasource(self: PipelineAST, id: []const u8) ?DatasourceSpec {
        for (self.datasources) |d| {
            if (std.mem.eql(u8, d.id, id)) return d;
        }
        return null;
    }

    pub fn getJob(self: PipelineAST, id: []const u8) ?JobSpec {
        for (self.jobs) |j| {
            if (std.mem.eql(u8, j.id, id)) return j;
        }
        return null;
    }
};

// =============================================================================
// PIPELINE BUILDER & SEMANTIC VALIDATOR
// =============================================================================

pub const ValidationError = error{
    OutOfMemory,
    DuplicateModuleName,
    DuplicateNetworkId,
    DuplicateDatasourceId,
    DuplicatePipelineName,
    DuplicateStepId,
    UnknownNetworkAdapter,
    UnknownTargetSubPipeline,
    CircularRouterReference,
    EmptyPipeline,
    MissingMainPipeline,
};

pub const PipelineBuilder = struct {
    arena: std.heap.ArenaAllocator,
    runtime: RuntimeConfig = .{},
    modules: std.ArrayListUnmanaged(ModuleSpec) = .empty,
    networks: std.ArrayListUnmanaged(NetworkSpec) = .empty,
    datasources: std.ArrayListUnmanaged(DatasourceSpec) = .empty,
    jobs: std.ArrayListUnmanaged(JobSpec) = .empty,
    pipelines: std.ArrayListUnmanaged(PipelineDecl) = .empty,

    pub fn init(backing_allocator: Allocator) PipelineBuilder {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *PipelineBuilder) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *PipelineBuilder) Allocator {
        return self.arena.allocator();
    }

    pub fn setWorkers(self: *PipelineBuilder, workers: usize) void {
        self.runtime.workers = workers;
    }

    pub fn setDefaultNetwork(self: *PipelineBuilder, net_id: []const u8) void {
        self.runtime.default_network = net_id;
    }

    pub fn setScheduler(self: *PipelineBuilder, scheduler: SchedulerMode) void {
        self.runtime.scheduler = scheduler;
    }

    pub fn setRouting(self: *PipelineBuilder, routing: RoutingMode) void {
        self.runtime.routing = routing;
    }

    pub fn setMaxInflightBytes(self: *PipelineBuilder, bytes: ?usize) void {
        self.runtime.max_inflight_bytes = bytes;
    }

    pub fn setRetainAll(self: *PipelineBuilder, retain_all: bool) void {
        self.runtime.retain_all = retain_all;
    }

    pub fn addModule(self: *PipelineBuilder, spec: ModuleSpec) ValidationError!void {
        const alloc = self.allocator();
        for (self.modules.items) |m| {
            if (std.mem.eql(u8, m.name, spec.name)) {
                return error.DuplicateModuleName;
            }
        }
        try self.modules.append(alloc, spec);
    }

    pub fn addNetwork(self: *PipelineBuilder, spec: NetworkSpec) ValidationError!void {
        const alloc = self.allocator();
        for (self.networks.items) |n| {
            if (std.mem.eql(u8, n.id, spec.id)) {
                return error.DuplicateNetworkId;
            }
        }
        try self.networks.append(alloc, spec);
    }

    pub fn addDatasource(self: *PipelineBuilder, spec: DatasourceSpec) ValidationError!void {
        const alloc = self.allocator();
        for (self.datasources.items) |d| {
            if (std.mem.eql(u8, d.id, spec.id)) {
                return error.DuplicateDatasourceId;
            }
        }
        try self.datasources.append(alloc, spec);
    }

    pub fn addJob(self: *PipelineBuilder, job: JobSpec) !void {
        const alloc = self.allocator();
        try self.jobs.append(alloc, job);
    }

    pub fn addPipeline(self: *PipelineBuilder, decl: PipelineDecl) ValidationError!void {
        const alloc = self.allocator();
        for (self.pipelines.items) |p| {
            if (std.mem.eql(u8, p.name, decl.name)) {
                return error.DuplicatePipelineName;
            }
        }

        // Validate step IDs are unique within the pipeline
        for (decl.steps, 0..) |s, i| {
            for (decl.steps[i + 1 ..]) |other| {
                if (std.mem.eql(u8, s.id(), other.id())) {
                    return error.DuplicateStepId;
                }
            }
        }

        try self.pipelines.append(alloc, decl);
    }

    /// Performs holistic semantic validation and freezes the AST.
    /// Checks:
    /// 1. At least one pipeline is defined (defaults to "main" if present, or first declared).
    /// 2. Router destinations and step network references exist.
    /// 3. Absence of recursive router cycles (DFS graph color marking).
    pub fn finish(self: *PipelineBuilder) ValidationError!PipelineAST {
        const alloc = self.allocator();

        // 1. Verify at least one pipeline exists
        if (self.pipelines.items.len == 0) return error.MissingMainPipeline;

        var entrypoint_name: []const u8 = self.pipelines.items[0].name;
        for (self.pipelines.items) |p| {
            if (std.mem.eql(u8, p.name, "main")) {
                entrypoint_name = "main";
                break;
            }
        }

        // 2. Verify router destination pipelines and step network bindings exist
        for (self.pipelines.items) |p| {
            for (p.steps) |step| {
                switch (step) {
                    .router => |r| {
                        for (r.cases) |c| {
                            if (!std.mem.eql(u8, c.goto_pipeline, "continue") and !self.hasPipeline(c.goto_pipeline)) {
                                return error.UnknownTargetSubPipeline;
                            }
                        }
                        if (r.default_pipeline) |def_pipe| {
                            if (!std.mem.eql(u8, def_pipe, "continue") and !self.hasPipeline(def_pipe)) {
                                return error.UnknownTargetSubPipeline;
                            }
                        }
                    },
                    .task => |t| {
                        for (t.networks) |net_id| {
                            if (!self.hasNetworkOrBuiltin(net_id)) {
                                return error.UnknownNetworkAdapter;
                            }
                        }
                    },
                }
            }
        }

        // 3. Cycle detection using Depth-First Search
        try self.validateAcyclicRouters();

        return .{
            .runtime = self.runtime,
            .modules = try self.modules.toOwnedSlice(alloc),
            .networks = try self.networks.toOwnedSlice(alloc),
            .datasources = try self.datasources.toOwnedSlice(alloc),
            .jobs = try self.jobs.toOwnedSlice(alloc),
            .pipelines = try self.pipelines.toOwnedSlice(alloc),
            .entrypoint = entrypoint_name,
        };
    }

    fn hasNetworkOrBuiltin(self: *PipelineBuilder, id: []const u8) bool {
        if (std.mem.eql(u8, id, "isolated") or std.mem.eql(u8, id, "none")) return true;
        for (self.networks.items) |n| {
            if (std.mem.eql(u8, n.id, id)) return true;
        }
        return false;
    }

    fn hasPipeline(self: *PipelineBuilder, name: []const u8) bool {
        for (self.pipelines.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        return false;
    }

    const NodeColor = enum { white, gray, black };

    fn validateAcyclicRouters(self: *PipelineBuilder) ValidationError!void {
        const alloc = self.allocator();
        var colors: std.StringHashMapUnmanaged(NodeColor) = .empty;
        defer colors.deinit(alloc);

        for (self.pipelines.items) |p| {
            try colors.put(alloc, p.name, .white);
        }

        for (self.pipelines.items) |p| {
            if (colors.get(p.name) == .white) {
                try self.dfsVisit(p.name, &colors);
            }
        }
    }

    fn dfsVisit(self: *PipelineBuilder, name: []const u8, colors: *std.StringHashMapUnmanaged(NodeColor)) ValidationError!void {
        const alloc = self.allocator();
        try colors.put(alloc, name, .gray);

        for (self.pipelines.items) |p| {
            if (!std.mem.eql(u8, p.name, name)) continue;

            for (p.steps) |step| {
                switch (step) {
                    .router => |r| {
                        for (r.cases) |c| {
                            const neighbor = c.goto_pipeline;
                            if (colors.get(neighbor)) |col| {
                                if (col == .gray) return error.CircularRouterReference;
                                if (col == .white) try self.dfsVisit(neighbor, colors);
                            }
                        }
                        if (r.default_pipeline) |def_pipe| {
                            if (colors.get(def_pipe)) |col| {
                                if (col == .gray) return error.CircularRouterReference;
                                if (col == .white) try self.dfsVisit(def_pipe, colors);
                            }
                        }
                    },
                    .task => {},
                }
            }
        }

        try colors.put(alloc, name, .black);
    }
};

// =============================================================================
// UNIT TESTS
// =============================================================================

test "ast: PipelineBuilder valid construction and semantic validation" {
    const testing = std.testing;
    var builder = PipelineBuilder.init(testing.allocator);
    defer builder.deinit();

    builder.setWorkers(4);

    try builder.addDatasource(.{
        .id = "pipeline_memory",
        .driver = "memory",
    });

    try builder.addDatasource(.{
        .id = "audit_db",
        .driver = "sqlite",
        .params = &.{.{ .key = "path", .value = ":memory:" }},
    });

    try builder.addDatasource(.{
        .id = "custom_search",
        .driver = "elasticsearch",
        .params = &.{.{ .key = "endpoint", .value = "http://localhost:9200" }},
    });

    // Sub-pipeline: quarantine
    try builder.addPipeline(.{
        .name = "quarantine_flow",
        .steps = &.{
            .{ .task = .{
                .id = "quarantine_step",
                .module = "cdr",
                .task = "quarantine_file",
            } },
        },
    });

    // Sub-pipeline: main
    try builder.addPipeline(.{
        .name = "main",
        .steps = &.{
            .{ .task = .{
                .id = "probe",
                .module = "analyzer",
                .task = "probe_file",
                .inputs = &.{.{
                    .param_name = "stream",
                    .expr = InboundStreamExpr.direct("file"),
                }},
                .outputs = &.{.{
                    .name = "coordination",
                    .datasource = "pipeline_memory",
                }},
            } },
            .{ .router = .{
                .id = "triage_router",
                .cases = &.{.{
                    .when_predicate = "probe.coordination.should_quarantine",
                    .goto_pipeline = "quarantine_flow",
                }},
                .default_pipeline = null,
            } },
        },
    });

    const ast = try builder.finish();

    try testing.expectEqual(ast.runtime.workers, 4);
    try testing.expectEqual(@as(usize, 3), ast.datasources.len);
    try testing.expectEqualStrings("elasticsearch", ast.datasources[2].driver);
    try testing.expectEqual(ast.pipelines.len, 2);

    const main_pipe = ast.getPipeline("main");
    try testing.expect(main_pipe != null);
    try testing.expectEqual(main_pipe.?.steps.len, 2);
}

test "ast: PipelineBuilder detects circular router cycle" {
    const testing = std.testing;
    var builder = PipelineBuilder.init(testing.allocator);
    defer builder.deinit();

    // Pipe A -> Pipe B -> Pipe A (Cycle!)
    try builder.addPipeline(.{
        .name = "main",
        .steps = &.{
            .{ .router = .{
                .id = "r_a",
                .cases = &.{.{ .when_predicate = "true", .goto_pipeline = "pipe_b" }},
            } },
        },
    });

    try builder.addPipeline(.{
        .name = "pipe_b",
        .steps = &.{
            .{ .router = .{
                .id = "r_b",
                .cases = &.{.{ .when_predicate = "true", .goto_pipeline = "main" }},
            } },
        },
    });

    const res = builder.finish();
    try testing.expectError(error.CircularRouterReference, res);
}

test "ast: PipelineBuilder adopts custom entrypoint or detects empty pipelines" {
    const testing = std.testing;
    var builder = PipelineBuilder.init(testing.allocator);
    defer builder.deinit();

    // 1. Zero pipelines -> error.MissingMainPipeline
    try testing.expectError(error.MissingMainPipeline, builder.finish());

    // 2. Custom pipeline without "main" adopts custom pipeline as entrypoint
    try builder.addPipeline(.{
        .name = "custom_pipeline",
        .steps = &.{},
    });

    const ast = try builder.finish();
    try testing.expectEqualStrings("custom_pipeline", ast.getEntrypoint().?);
}

test "ast: RoutingMode defaults to directed and supports per-pipeline override" {
    const testing = std.testing;
    var builder = PipelineBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.addPipeline(.{ .name = "etl_pipe", .steps = &.{} });
    try builder.addPipeline(.{ .name = "mesh_pipe", .routing = .type_driven, .steps = &.{} });

    const ast = try builder.finish();
    try testing.expectEqual(RoutingMode.directed, ast.runtime.routing);
    try testing.expectEqual(RoutingMode.directed, ast.getPipeline("etl_pipe").?.effectiveRouting(ast.runtime.routing));
    try testing.expectEqual(RoutingMode.type_driven, ast.getPipeline("mesh_pipe").?.effectiveRouting(ast.runtime.routing));

    builder.setRouting(.hybrid);
    try testing.expectEqual(RoutingMode.hybrid, builder.runtime.routing);
    try testing.expectEqual(RoutingMode.hybrid, ast.getPipeline("etl_pipe").?.effectiveRouting(builder.runtime.routing));
    try testing.expectEqual(RoutingMode.type_driven, ast.getPipeline("mesh_pipe").?.effectiveRouting(builder.runtime.routing));
}

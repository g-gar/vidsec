//! Pluggable Routing Strategy Contract (ARCH-023).
//!
//! Decouples *routing decisions* (which tasks activate next and with what inputs)
//! from *execution mechanics* (WorkerPool, StepArena, NetworkController, Telemetry).
//! Implementations must remain independent of WorkerPool and Coordinator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast/ast.zig");
const dataflow = @import("flowdata_dataflow");
const PayloadHandle = dataflow.PayloadHandle;
const modules_mod = @import("../../plugin/mod.zig");
const repository = @import("../../repository/mod.zig");
const AmbientContext = @import("../ambient_context.zig").AmbientContext;
const plan_mod = @import("../plan.zig");

pub const NodeId = plan_mod.NodeId;
pub const ChannelId = plan_mod.ChannelId;
pub const BoundInput = modules_mod.BoundInput;
pub const TaskStatus = modules_mod.TaskStatus_ABI;

pub const NamedPayload = struct {
    name: []const u8,
    payload: PayloadHandle,
};

/// A single task dispatch instruction produced by a RoutingStrategy.
pub const TaskActivation = struct {
    node_id: NodeId,
    step_input: PayloadHandle,
    bound_inputs: []const BoundInput = &.{},
    /// Channels consumed by this activation (used by directed mode for refcounting).
    consumed_channels: []const ChannelId = &.{},
};

/// Notification delivered back to a RoutingStrategy when a task finishes.
pub const StepOutcomeEvent = struct {
    node_id: NodeId,
    status: TaskStatus,
    output: PayloadHandle,
    channel_outputs: []const NamedPayload = &.{},
};

/// Read-only context passed to router factories when instantiating a strategy.
/// Intentionally excludes WorkerPool, Coordinator, and NetworkController.
pub const RoutingContext = struct {
    allocator: Allocator,
    ast: ast.PipelineAST,
    pipeline: ast.PipelineDecl,
    modules: *const modules_mod.ModuleRegistry,
    ambient: *const AmbientContext,
    repos: ?*const repository.RepositoryRegistry = null,
    active_mask: ?[]const bool = null,
    external_outputs: ?*const std.StringHashMapUnmanaged(PayloadHandle) = null,
};

/// Type-erased RoutingStrategy interface following the Flowdata ptr + vtable contract.
pub const RoutingStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onPipelineStart: *const fn (
            ptr: *anyopaque,
            alloc: Allocator,
            initial_input: PayloadHandle,
        ) anyerror![]TaskActivation,

        onStepComplete: *const fn (
            ptr: *anyopaque,
            alloc: Allocator,
            event: StepOutcomeEvent,
        ) anyerror![]TaskActivation,

        hasPendingWork: *const fn (ptr: *const anyopaque) bool,

        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Compile-time structural check ensuring `T` implements the RoutingStrategy contract.
    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "onPipelineStart") or
                !@hasDecl(T, "onStepComplete") or
                !@hasDecl(T, "hasPendingWork") or
                !@hasDecl(T, "deinit"))
            {
                @compileError(@typeName(T) ++ " must implement onPipelineStart, onStepComplete, hasPendingWork, and deinit");
            }
        }
    }

    /// Wraps a concrete strategy pointer into a `RoutingStrategy` handle.
    pub fn fromImpl(comptime T: type, impl: *T) RoutingStrategy {
        assertImplements(T);
        const Gen = struct {
            fn onPipelineStartFn(ptr: *anyopaque, alloc: Allocator, initial_input: PayloadHandle) anyerror![]TaskActivation {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.onPipelineStart(alloc, initial_input);
            }

            fn onStepCompleteFn(ptr: *anyopaque, alloc: Allocator, event: StepOutcomeEvent) anyerror![]TaskActivation {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.onStepComplete(alloc, event);
            }

            fn hasPendingWorkFn(ptr: *const anyopaque) bool {
                const self: *const T = @ptrCast(@alignCast(ptr));
                return self.hasPendingWork();
            }

            fn deinitFn(ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.deinit();
            }

            const vtable_inst = VTable{
                .onPipelineStart = &onPipelineStartFn,
                .onStepComplete = &onStepCompleteFn,
                .hasPendingWork = &hasPendingWorkFn,
                .deinit = &deinitFn,
            };
        };

        return .{
            .ptr = impl,
            .vtable = &Gen.vtable_inst,
        };
    }

    pub fn onPipelineStart(self: RoutingStrategy, alloc: Allocator, initial_input: PayloadHandle) anyerror![]TaskActivation {
        return self.vtable.onPipelineStart(self.ptr, alloc, initial_input);
    }

    pub fn onStepComplete(self: RoutingStrategy, alloc: Allocator, event: StepOutcomeEvent) anyerror![]TaskActivation {
        return self.vtable.onStepComplete(self.ptr, alloc, event);
    }

    pub fn hasPendingWork(self: RoutingStrategy) bool {
        return self.vtable.hasPendingWork(self.ptr);
    }

    pub fn deinit(self: RoutingStrategy) void {
        self.vtable.deinit(self.ptr);
    }
};

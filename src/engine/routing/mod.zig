//! Pluggable Routing Layer (ARCH-023).

pub const strategy = @import("strategy.zig");
pub const registry = @import("registry.zig");
pub const directed = @import("directed.zig");

pub const NodeId = strategy.NodeId;
pub const ChannelId = strategy.ChannelId;
pub const BoundInput = strategy.BoundInput;
pub const TaskStatus = strategy.TaskStatus;
pub const NamedPayload = strategy.NamedPayload;
pub const TaskActivation = strategy.TaskActivation;
pub const StepOutcomeEvent = strategy.StepOutcomeEvent;
pub const RoutingContext = strategy.RoutingContext;
pub const RoutingStrategy = strategy.RoutingStrategy;

pub const RouterFactoryFn = registry.RouterFactoryFn;
pub const RouterRegistryError = registry.RouterRegistryError;
pub const RouterRegistry = registry.RouterRegistry;
pub const DirectedRouter = directed.DirectedRouter;

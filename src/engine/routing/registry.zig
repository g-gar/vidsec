//! Extensible Registry for RoutingStrategy Factories (ARCH-023).
//!
//! Mirrors `RepositoryRegistry` so built-in modes (`directed`, `type_driven`, `hybrid`)
//! and custom user/extension routing strategies can be registered and resolved by name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../../ast/ast.zig");
const strategy_mod = @import("strategy.zig");

pub const RoutingStrategy = strategy_mod.RoutingStrategy;
pub const RoutingContext = strategy_mod.RoutingContext;

pub const RouterFactoryFn = *const fn (ctx: RoutingContext) anyerror!RoutingStrategy;

pub const RouterRegistryError = error{
    UnknownRoutingStrategy,
} || Allocator.Error;

/// IoC registry mapping routing strategy names to factory functions.
pub const RouterRegistry = struct {
    allocator: Allocator,
    factories: std.StringHashMapUnmanaged(RouterFactoryFn) = .empty,

    pub fn init(allocator: Allocator) RouterRegistry {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RouterRegistry) void {
        var iter = self.factories.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.factories.deinit(self.allocator);
    }

    /// Registers (or replaces) a routing strategy factory under `name`.
    pub fn register(self: *RouterRegistry, name: []const u8, factory: RouterFactoryFn) !void {
        if (self.factories.getPtr(name)) |existing| {
            existing.* = factory;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.factories.put(self.allocator, owned_name, factory);
    }

    /// Returns true if a factory is registered for `name`.
    pub fn has(self: *const RouterRegistry, name: []const u8) bool {
        return self.factories.contains(name);
    }

    /// Instantiates a registered routing strategy by name.
    pub fn create(self: *const RouterRegistry, name: []const u8, ctx: RoutingContext) anyerror!RoutingStrategy {
        const factory = self.factories.get(name) orelse return error.UnknownRoutingStrategy;
        return factory(ctx);
    }

    /// Instantiates a routing strategy matching an AST `RoutingMode`.
    pub fn createForMode(self: *const RouterRegistry, mode: ast.RoutingMode, ctx: RoutingContext) anyerror!RoutingStrategy {
        return self.create(modeName(mode), ctx);
    }

    /// Canonical string name for an AST `RoutingMode`.
    pub fn modeName(mode: ast.RoutingMode) []const u8 {
        return switch (mode) {
            .directed => "directed",
            .type_driven => "type_driven",
            .hybrid => "hybrid",
        };
    }
};

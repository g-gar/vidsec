const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");

pub const ReflectedValue = dataflow.ReflectedValue;

pub const CustomPredicateFn = *const fn (arg: ReflectedValue, param_literal: []const u8) bool;
pub const EnvSchemeResolverFn = *const fn (allocator: Allocator, key: []const u8) ?[]const u8;

/// Open DSL registry allowing extensions to inject custom functions into the Dataflow algebra (`where:`)
/// and custom secret/vault resolvers into the YAML env interpolator (`${vault:...}`).
pub const DslRegistry = struct {
    allocator: Allocator,
    predicates: std.StringHashMapUnmanaged(CustomPredicateFn) = .empty,
    env_schemes: std.StringHashMapUnmanaged(EnvSchemeResolverFn) = .empty,

    pub fn init(allocator: Allocator) DslRegistry {
        return .{
            .allocator = allocator,
            .predicates = .empty,
            .env_schemes = .empty,
        };
    }

    pub fn deinit(self: *DslRegistry) void {
        var pit = self.predicates.keyIterator();
        while (pit.next()) |k| {
            self.allocator.free(k.*);
        }
        self.predicates.deinit(self.allocator);

        var sit = self.env_schemes.keyIterator();
        while (sit.next()) |k| {
            self.allocator.free(k.*);
        }
        self.env_schemes.deinit(self.allocator);
    }

    pub fn registerPredicateFn(self: *DslRegistry, name: []const u8, fn_ptr: CustomPredicateFn) !void {
        if (!self.predicates.contains(name)) {
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.predicates.put(self.allocator, owned, fn_ptr);
        } else {
            try self.predicates.put(self.allocator, name, fn_ptr);
        }
    }

    pub fn registerEnvScheme(self: *DslRegistry, scheme: []const u8, fn_ptr: EnvSchemeResolverFn) !void {
        if (!self.env_schemes.contains(scheme)) {
            const owned = try self.allocator.dupe(u8, scheme);
            errdefer self.allocator.free(owned);
            try self.env_schemes.put(self.allocator, owned, fn_ptr);
        } else {
            try self.env_schemes.put(self.allocator, scheme, fn_ptr);
        }
    }

    pub fn resolveEnvScheme(self: *const DslRegistry, allocator: Allocator, scheme: []const u8, key: []const u8) ?[]const u8 {
        const resolver = self.env_schemes.get(scheme) orelse return null;
        return resolver(allocator, key);
    }

    pub fn evaluatePredicate(self: *const DslRegistry, name: []const u8, arg: ReflectedValue, param: []const u8) ?bool {
        const p_fn = self.predicates.get(name) orelse return null;
        return p_fn(arg, param);
    }
};

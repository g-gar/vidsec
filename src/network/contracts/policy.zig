const std = @import("std");
const Allocator = std.mem.Allocator;
const exchange_mod = @import("exchange.zig");
const NetExchange = exchange_mod.NetExchange;

pub const PolicyVerdict = enum {
    allowed,
    denied_ssrf_private_ip,
    denied_ssrf_loopback,
    denied_ssrf_link_local,
    denied_acl_mismatch,
    denied_tls_policy,
};

/// Polymorphic VTable interface for L4/L7 Network Security Policies
/// (`AntiSsrfPolicy`, `AllowListAclPolicy`, `TlsSecurityPolicy`, `CompositePolicy`).
pub const NetworkPolicyRule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        evaluate: *const fn (ctx: *const anyopaque, exchange: *const NetExchange) PolicyVerdict,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub fn evaluate(self: NetworkPolicyRule, exchange: *const NetExchange) PolicyVerdict {
        return self.vtable.evaluate(self.ptr, exchange);
    }

    pub fn deinit(self: NetworkPolicyRule, allocator: Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "networkPolicyRule")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must declare 'pub fn networkPolicyRule(*" ++ @typeName(T) ++ ") NetworkPolicyRule'");
            }
        }
    }
};

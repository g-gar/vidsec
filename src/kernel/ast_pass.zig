const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_mod = @import("../ast/ast.zig");

pub const PipelineAST = ast_mod.PipelineAST;

pub const AstPassFn = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    ast: *PipelineAST,
) anyerror!void;

pub const AstPass = struct {
    name: []const u8,
    ctx: ?*anyopaque = null,
    run: AstPassFn,
};

/// Registry for AST analysis, linting, and mutating passes executed immediately after YAML compilation.
pub const AstPassRegistry = struct {
    allocator: Allocator,
    passes: std.ArrayListUnmanaged(AstPass) = .empty,

    pub fn init(allocator: Allocator) AstPassRegistry {
        return .{
            .allocator = allocator,
            .passes = .empty,
        };
    }

    pub fn deinit(self: *AstPassRegistry) void {
        self.passes.deinit(self.allocator);
    }

    pub fn register(self: *AstPassRegistry, pass: AstPass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn registerFn(
        self: *AstPassRegistry,
        name: []const u8,
        comptime run_fn: *const fn (allocator: Allocator, ast: *PipelineAST) anyerror!void,
    ) !void {
        const S = struct {
            fn wrapper(_: ?*anyopaque, a: Allocator, ast: *PipelineAST) anyerror!void {
                return run_fn(a, ast);
            }
        };
        try self.register(.{
            .name = name,
            .ctx = null,
            .run = &S.wrapper,
        });
    }

    pub fn runAll(self: *const AstPassRegistry, ast: *PipelineAST) anyerror!void {
        for (self.passes.items) |pass| {
            try pass.run(pass.ctx, self.allocator, ast);
        }
    }
};

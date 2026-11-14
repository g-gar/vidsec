const std = @import("std");
const Allocator = std.mem.Allocator;

pub const yaml_lib = @import("lib/mod.zig");
pub const env = @import("env.zig");
pub const schema_loader = @import("loaders/schema_loader.zig");
pub const network_loader = @import("loaders/network_loader.zig");
pub const ast_loader = @import("ast_loader.zig");

pub const EnvInterpolator = env.EnvInterpolator;
pub const YamlNode = yaml_lib.Node;

// Declarative Schema Catalog (schemas.yaml)
pub const SchemaCatalog = schema_loader.SchemaCatalog;
pub const parseSchemaCatalog = schema_loader.parseYaml;
pub const DomainSchema = schema_loader.DomainSchema;
pub const TableSchema = schema_loader.TableSchema;
pub const ColumnSpec = schema_loader.ColumnSpec;
pub const ColumnType = schema_loader.ColumnType;
pub const SeedRow = schema_loader.SeedRow;

// Declarative Pipeline AST Loader (pipeline.yaml)
pub const loadPipelineAstFromYaml = ast_loader.loadPipelineAstFromYaml;
pub const AstLoadOptions = ast_loader.AstLoadOptions;
pub const YamlAstLoaderError = ast_loader.YamlAstLoaderError;
pub const RoutingMode = ast_loader.RoutingMode;
pub const parseInboundStreamExpr = ast_loader.parseInboundStreamExpr;
pub const parseJobEntry = ast_loader.parseJobEntry;

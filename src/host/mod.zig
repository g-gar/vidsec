pub const contracts = @import("contracts/mod.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const transports = @import("transports/mod.zig");
pub const app = @import("app.zig");

// Contract re-exports
pub const InvocationCommand = contracts.InvocationCommand;
pub const InputSource = contracts.InputSource;
pub const OutputFormat = contracts.OutputFormat;
pub const InvocationRequest = contracts.InvocationRequest;
pub const InvocationStatus = contracts.InvocationStatus;
pub const InvocationResponse = contracts.InvocationResponse;
pub const HostTransport = contracts.HostTransport;

// Dispatcher & App
pub const HostDispatcher = dispatcher.HostDispatcher;
pub const AppInfo = dispatcher.AppInfo;
pub const AppConfig = app.AppConfig;
pub const HostApp = app.HostApp;

// Transports
pub const CliTransport = transports.CliTransport;
pub const HttpServerTransport = transports.HttpServerTransport;
pub const GrpcTransport = transports.GrpcTransport;

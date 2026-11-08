pub const contracts = @import("contracts/mod.zig");
pub const drivers = @import("drivers/mod.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const registry = @import("registry.zig");
pub const app = @import("app.zig");

// Inbound Contracts
pub const InvocationCommand = contracts.InvocationCommand;
pub const ServeConfig = contracts.ServeConfig;
pub const InputSource = contracts.InputSource;
pub const OutputFormat = contracts.OutputFormat;
pub const InvocationRequest = contracts.InvocationRequest;
pub const InvocationStatus = contracts.InvocationStatus;
pub const InvocationResponse = contracts.InvocationResponse;
pub const InboundTransport = contracts.InboundTransport;
pub const DispatcherPtr = contracts.DispatcherPtr;
pub const DispatchFn = contracts.DispatchFn;

// Inbound Registry & Dispatcher & App
pub const InboundRegistry = registry.InboundRegistry;
pub const InboundTransportConfig = registry.InboundTransportConfig;
pub const InboundFactoryFn = registry.InboundFactoryFn;
pub const InboundDispatcher = dispatcher.InboundDispatcher;
pub const CustomCommandHandler = dispatcher.CustomCommandHandler;
pub const AppInfo = dispatcher.AppInfo;
pub const AppConfig = dispatcher.AppInfo;
pub const TransportApp = app.TransportApp;

// Drivers
pub const CliTransport = drivers.CliTransport;
pub const HttpServerTransport = drivers.HttpServerTransport;
pub const HttpTransport = drivers.HttpTransport;
pub const GrpcTransport = drivers.GrpcTransport;

// Backward Compatibility Aliases (Host*)
pub const HostTransport = contracts.HostTransport;
pub const HostDispatcher = dispatcher.HostDispatcher;
pub const HostApp = app.HostApp;
pub const HostDispatcherPtr = contracts.HostDispatcherPtr;

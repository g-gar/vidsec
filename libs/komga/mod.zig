pub const http = @import("http.zig");
pub const auth = @import("auth.zig");
pub const types = @import("types.zig");
pub const client = @import("client.zig");

pub const HttpTransport = http.HttpTransport;
pub const HttpMethod = http.HttpMethod;
pub const HttpHeader = http.HttpHeader;
pub const HttpResponse = http.HttpResponse;
pub const HttpTransportError = http.HttpTransportError;

pub const KomgaAuth = auth.KomgaAuth;
pub const KomgaClient = client.KomgaClient;
pub const ClientConfig = client.ClientConfig;
pub const KomgaClientError = client.KomgaClientError;

pub const UserDto = types.UserDto;
pub const LibraryDto = types.LibraryDto;
pub const SeriesDto = types.SeriesDto;
pub const BookDto = types.BookDto;
pub const BookMediaDto = types.BookMediaDto;
pub const BookImportDto = types.BookImportDto;
pub const BookImportBatchDto = types.BookImportBatchDto;
pub const CopyMode = types.CopyMode;
pub const PageDto = types.PageDto;

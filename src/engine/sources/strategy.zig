const std = @import("std");
const Allocator = std.mem.Allocator;
const dataflow = @import("flowdata_dataflow");
pub const PayloadHandle = dataflow.PayloadHandle;

/// Agnostic event emission interface for pushing items into the Flowdata engine.
/// Allows external collectors (ARCH-019), webhooks, test harnesses, or batch sources
/// to inject payloads without coupling to the pipeline topology.
pub const RecordEmitter = struct {
    ptr: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, source_id: []const u8, record: PayloadHandle) anyerror!void,

    pub fn emit(self: RecordEmitter, source_id: []const u8, record: PayloadHandle) !void {
        return self.emit_fn(self.ptr, source_id, record);
    }

    pub fn emitRecord(self: RecordEmitter, source_id: []const u8, record: anytype) !void {
        const T = @TypeOf(record);
        if (T == PayloadHandle) {
            return self.emit(source_id, record);
        } else if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice) {
            return self.emit(source_id, PayloadHandle.fromSlice(@typeInfo(T).pointer.child, record));
        } else {
            return self.emit(source_id, PayloadHandle.fromScalar(T, &record));
        }
    }
};

/// Decoupled batch/stream source contract (ARCH-025).
/// Implementations emit items into `RecordEmitter` without importing `PipelineEngine`,
/// `Coordinator`, `WorkerPool`, or `CliTransport`.
pub const BatchSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        emitAll: *const fn (
            ptr: *anyopaque,
            alloc: Allocator,
            emitter: RecordEmitter,
        ) anyerror!usize,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn emitAll(self: BatchSource, alloc: Allocator, emitter: RecordEmitter) anyerror!usize {
        return self.vtable.emitAll(self.ptr, alloc, emitter);
    }

    pub fn deinit(self: BatchSource) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn assertImplements(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "batchSource") and !@hasDecl(T, "emitAll")) {
                @compileError("Type '" ++ @typeName(T) ++ "' must implement BatchSource contract");
            }
        }
    }

    pub fn fromImpl(comptime T: type, impl: *T) BatchSource {
        const Trampoline = struct {
            fn doEmitAll(ptr: *anyopaque, alloc: Allocator, emitter: RecordEmitter) anyerror!usize {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.emitAll(alloc, emitter);
            }

            fn doDeinit(ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.deinit();
            }

            const vtable = VTable{
                .emitAll = &doEmitAll,
                .deinit = &doDeinit,
            };
        };

        return .{
            .ptr = impl,
            .vtable = &Trampoline.vtable,
        };
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

pub const CompressionLevel = enum(u32) {
    store = 0, // No compression (fastest, ideal for JPG/PNG/WebP)
    fast = 1,
    default = 6, // Ideal for ComicInfo.xml
    best = 9,
};

pub const ZipError = error{
    FileCreateFailed,
    ArchiveInitFailed,
    EntryAddFailed,
    FinalizationFailed,
    OutOfMemory,
    FileNotFound,
    ReadFailed,
    InvalidPath,
};

pub const ZipArchiveWriter = struct {
    allocator: Allocator,
    archive: *c.mz_zip_archive,
    output_path: ?[:0]const u8,
    is_open: bool,
    is_memory: bool = false,

    pub fn create(allocator: Allocator, output_file_path: []const u8) ZipError!ZipArchiveWriter {
        const path_z = allocator.dupeZ(u8, output_file_path) catch return error.OutOfMemory;
        errdefer allocator.free(path_z);

        const archive = allocator.create(c.mz_zip_archive) catch return error.OutOfMemory;
        errdefer allocator.destroy(archive);

        c.mz_zip_zero_struct(archive);

        if (c.mz_zip_writer_init_file(archive, path_z.ptr, 0) == 0) {
            return error.ArchiveInitFailed;
        }

        return .{
            .allocator = allocator,
            .archive = archive,
            .output_path = path_z,
            .is_open = true,
            .is_memory = false,
        };
    }

    pub fn createInMemory(allocator: Allocator) ZipError!ZipArchiveWriter {
        const archive = allocator.create(c.mz_zip_archive) catch return error.OutOfMemory;
        errdefer allocator.destroy(archive);

        c.mz_zip_zero_struct(archive);

        if (c.mz_zip_writer_init_heap(archive, 0, 0) == 0) {
            return error.ArchiveInitFailed;
        }

        return .{
            .allocator = allocator,
            .archive = archive,
            .output_path = null,
            .is_open = true,
            .is_memory = true,
        };
    }

    /// Appends an in-memory buffer as a file entry inside the ZIP archive.
    pub fn addFileFromMemory(
        self: *ZipArchiveWriter,
        entry_name: []const u8,
        data: []const u8,
        level: CompressionLevel,
    ) ZipError!void {
        if (!self.is_open) return error.ArchiveInitFailed;

        const name_z = self.allocator.dupeZ(u8, entry_name) catch return error.OutOfMemory;
        defer self.allocator.free(name_z);

        const flags: c.mz_uint = @intFromEnum(level);
        const ptr: ?*const anyopaque = if (data.len > 0) data.ptr else "";

        if (c.mz_zip_writer_add_mem(self.archive, name_z.ptr, ptr, data.len, flags) == 0) {
            return error.EntryAddFailed;
        }
    }

    /// Appends a file from the host filesystem into the ZIP archive.
    pub fn addFileFromDisk(
        self: *ZipArchiveWriter,
        entry_name: []const u8,
        disk_path: []const u8,
        level: CompressionLevel,
    ) ZipError!void {
        if (!self.is_open) return error.ArchiveInitFailed;

        const name_z = self.allocator.dupeZ(u8, entry_name) catch return error.OutOfMemory;
        defer self.allocator.free(name_z);

        const disk_z = self.allocator.dupeZ(u8, disk_path) catch return error.OutOfMemory;
        defer self.allocator.free(disk_z);

        const flags: c.mz_uint = @intFromEnum(level);

        if (c.mz_zip_writer_add_file(self.archive, name_z.ptr, disk_z.ptr, null, 0, flags) == 0) {
            return error.EntryAddFailed;
        }
    }

    /// Finalizes the central directory and closes the file descriptor.
    pub fn finish(self: *ZipArchiveWriter) ZipError!void {
        if (!self.is_open) return;

        if (c.mz_zip_writer_finalize_archive(self.archive) == 0) {
            _ = c.mz_zip_writer_end(self.archive);
            self.is_open = false;
            return error.FinalizationFailed;
        }

        if (c.mz_zip_writer_end(self.archive) == 0) {
            self.is_open = false;
            return error.FinalizationFailed;
        }

        self.is_open = false;
    }

    /// Finalizes an in-memory ZIP archive and returns an owned slice of its bytes.
    pub fn finishInMemory(self: *ZipArchiveWriter) ZipError![]u8 {
        if (!self.is_open or !self.is_memory) return error.ArchiveInitFailed;

        var buf_ptr: ?*anyopaque = null;
        var buf_len: usize = 0;
        if (c.mz_zip_writer_finalize_heap_archive(self.archive, &buf_ptr, &buf_len) == 0) {
            _ = c.mz_zip_writer_end(self.archive);
            self.is_open = false;
            return error.FinalizationFailed;
        }

        const owned = self.allocator.alloc(u8, buf_len) catch {
            if (buf_ptr) |p| c.mz_free(p);
            _ = c.mz_zip_writer_end(self.archive);
            self.is_open = false;
            return error.OutOfMemory;
        };

        if (buf_ptr) |p| {
            const src: [*]const u8 = @ptrCast(p);
            @memcpy(owned, src[0..buf_len]);
            c.mz_free(p);
        }

        _ = c.mz_zip_writer_end(self.archive);
        self.is_open = false;
        return owned;
    }

    pub fn deinit(self: *ZipArchiveWriter) void {
        if (self.is_open) {
            _ = c.mz_zip_writer_end(self.archive);
            self.is_open = false;
        }
        self.allocator.destroy(self.archive);
        if (self.output_path) |p| {
            self.allocator.free(p);
        }
    }
};

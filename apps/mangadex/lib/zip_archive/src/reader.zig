const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const ZipError = @import("writer.zig").ZipError;

pub const ZipArchiveReader = struct {
    allocator: Allocator,
    archive: *c.mz_zip_archive,
    is_open: bool,

    pub fn openFile(allocator: Allocator, path: []const u8) ZipError!ZipArchiveReader {
        const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer allocator.free(path_z);

        const archive = allocator.create(c.mz_zip_archive) catch return error.OutOfMemory;
        errdefer allocator.destroy(archive);

        c.mz_zip_zero_struct(archive);

        if (c.mz_zip_reader_init_file(archive, path_z.ptr, 0) == 0) {
            return error.ArchiveInitFailed;
        }

        return .{
            .allocator = allocator,
            .archive = archive,
            .is_open = true,
        };
    }

    pub fn openMemory(allocator: Allocator, bytes: []const u8) ZipError!ZipArchiveReader {
        const archive = allocator.create(c.mz_zip_archive) catch return error.OutOfMemory;
        errdefer allocator.destroy(archive);

        c.mz_zip_zero_struct(archive);

        if (c.mz_zip_reader_init_mem(archive, bytes.ptr, bytes.len, 0) == 0) {
            return error.ArchiveInitFailed;
        }

        return .{
            .allocator = allocator,
            .archive = archive,
            .is_open = true,
        };
    }

    pub fn getNumFiles(self: *ZipArchiveReader) usize {
        if (!self.is_open) return 0;
        return @intCast(c.mz_zip_reader_get_num_files(self.archive));
    }

    pub fn getFileName(self: *ZipArchiveReader, index: usize, buf: []u8) ZipError!?[]const u8 {
        if (!self.is_open) return error.ArchiveInitFailed;
        if (index >= self.getNumFiles()) return null;

        const len = c.mz_zip_reader_get_filename(self.archive, @intCast(index), buf.ptr, @intCast(buf.len));
        if (len == 0) return null;

        // mz_zip_reader_get_filename includes null terminator in count or does not?
        // miniz doc: returns number of bytes written to pFilename (including trailing NULL) or 0 on error
        const actual_len: usize = if (len > 0 and buf[len - 1] == 0) len - 1 else len;
        return buf[0..actual_len];
    }

    pub fn locateFile(self: *ZipArchiveReader, filename: []const u8) ?usize {
        if (!self.is_open) return null;
        const name_z = self.allocator.dupeZ(u8, filename) catch return null;
        defer self.allocator.free(name_z);

        const idx = c.mz_zip_reader_locate_file(self.archive, name_z.ptr, null, 0);
        if (idx < 0) return null;
        return @intCast(idx);
    }

    pub fn readFileToMemory(self: *ZipArchiveReader, allocator: Allocator, index: usize) ZipError![]u8 {
        if (!self.is_open) return error.ArchiveInitFailed;
        var uncomp_size: usize = 0;
        const c_buf = c.mz_zip_reader_extract_to_heap(self.archive, @intCast(index), &uncomp_size, 0);
        if (c_buf == null) return error.ReadFailed;
        defer c.mz_free(c_buf);

        const slice: [*]const u8 = @ptrCast(c_buf);
        return allocator.dupe(u8, slice[0..uncomp_size]) catch return error.OutOfMemory;
    }

    pub fn readFileByNameToMemory(self: *ZipArchiveReader, allocator: Allocator, filename: []const u8) ZipError![]u8 {
        const idx = self.locateFile(filename) orelse return error.FileNotFound;
        return self.readFileToMemory(allocator, idx);
    }

    pub fn deinit(self: *ZipArchiveReader) void {
        if (self.is_open) {
            _ = c.mz_zip_reader_end(self.archive);
            self.is_open = false;
        }
        self.allocator.destroy(self.archive);
    }
};

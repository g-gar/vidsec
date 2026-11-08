const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const c_posix = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub const ArtifactError = error{
    StreamNotFound,
    OutOfBounds,
    NoOutputArtifactConfigured,
    QuarantineFailed,
    IoError,
    OutOfMemory,
};

/// Storage backing for a `ManagedBuffer`: either in-memory heap or a memory-mapped file.
pub const BufferKind = enum {
    memory,
    mapped_file,
};

/// Record of a byte region carved into quarantine via `carve_to_quarantine`.
pub const CarvedItem = struct {
    reason_tag: []const u8,
    offset: u64,
    length: u64,
    sha256_hex: [64]u8,
    data: []u8,

    pub fn deinit(self: *CarvedItem, allocator: Allocator) void {
        allocator.free(self.reason_tag);
        allocator.free(self.data);
    }
};

/// Safe, bounds-checked byte buffer representing the input media stream (`"file"`)
/// or a named intermediate/final artifact (`"sanitized_video"`, `"final_video"`, etc.).
/// Supports memory-mapped file backing (zero physical RAM allocation for multi-gigabyte video files)
/// with seamless Copy-on-Write (CoW) promotion to heap memory on mutation.
pub const ManagedBuffer = struct {
    kind: BufferKind = .memory,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    mmap_slice: []const u8 = &.{},
    fd: c_int = -1,

    pub fn initCopy(allocator: Allocator, initial: []const u8) !ManagedBuffer {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        try list.appendSlice(allocator, initial);
        return .{
            .kind = .memory,
            .bytes = list,
            .mmap_slice = &.{},
            .fd = -1,
        };
    }

    /// Maps a file into virtual memory via POSIX `mmap()` with read-only permissions (`PROT_READ`, `MAP_SHARED`).
    /// Zero heap memory is allocated for the file contents, allowing multi-gigabyte files (e.g. 20+ GB)
    /// to be inspected with near-zero physical RAM overhead.
    pub fn initMmap(allocator: Allocator, path: []const u8) ArtifactError!ManagedBuffer {
        const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer allocator.free(path_z);

        const fd = c_posix.open(path_z.ptr, c_posix.O_RDONLY);
        if (fd < 0) return error.StreamNotFound;
        errdefer _ = c_posix.close(fd);

        var st: c_posix.struct_stat = undefined;
        if (c_posix.fstat(fd, &st) != 0) return error.IoError;
        if (st.st_size < 0) return error.IoError;

        const file_size: usize = std.math.cast(usize, st.st_size) orelse return error.OutOfBounds;
        if (file_size == 0) {
            return ManagedBuffer{
                .kind = .mapped_file,
                .bytes = .empty,
                .mmap_slice = &.{},
                .fd = fd,
            };
        }

        const raw_ptr = c_posix.mmap(null, file_size, c_posix.PROT_READ, c_posix.MAP_SHARED, fd, 0);
        if (raw_ptr == c_posix.MAP_FAILED) return error.IoError;

        const ptr: [*]const u8 = @ptrCast(raw_ptr);
        return ManagedBuffer{
            .kind = .mapped_file,
            .bytes = .empty,
            .mmap_slice = ptr[0..file_size],
            .fd = fd,
        };
    }

    pub fn deinit(self: *ManagedBuffer, allocator: Allocator) void {
        switch (self.kind) {
            .memory => {
                self.bytes.deinit(allocator);
            },
            .mapped_file => {
                if (self.mmap_slice.len > 0) {
                    _ = c_posix.munmap(@constCast(@ptrCast(self.mmap_slice.ptr)), self.mmap_slice.len);
                    self.mmap_slice = &.{};
                }
                if (self.fd >= 0) {
                    _ = c_posix.close(self.fd);
                    self.fd = -1;
                }
            },
        }
    }

    /// Automatically promotes a `.mapped_file` buffer to an owned heap `.memory` buffer via Copy-on-Write (CoW).
    pub fn promoteToMemory(self: *ManagedBuffer, allocator: Allocator) ArtifactError!void {
        if (self.kind == .memory) return;

        var list: std.ArrayListUnmanaged(u8) = .empty;
        list.appendSlice(allocator, self.mmap_slice) catch return error.OutOfMemory;

        if (self.mmap_slice.len > 0) {
            _ = c_posix.munmap(@constCast(@ptrCast(self.mmap_slice.ptr)), self.mmap_slice.len);
            self.mmap_slice = &.{};
        }
        if (self.fd >= 0) {
            _ = c_posix.close(self.fd);
            self.fd = -1;
        }

        self.bytes = list;
        self.kind = .memory;
    }

    pub fn size(self: *const ManagedBuffer) u64 {
        return switch (self.kind) {
            .memory => self.bytes.items.len,
            .mapped_file => self.mmap_slice.len,
        };
    }

    pub fn slice(self: *const ManagedBuffer) []const u8 {
        return switch (self.kind) {
            .memory => self.bytes.items,
            .mapped_file => self.mmap_slice,
        };
    }

    /// Reads `dest.len` bytes at `offset`, checking for 64-bit overflow and `offset + dest.len <= size`.
    pub fn readAt(self: *const ManagedBuffer, offset: u64, dest: []u8) ArtifactError!void {
        if (dest.len == 0) return;
        const current_size = self.size();
        const end = std.math.add(u64, offset, dest.len) catch return error.OutOfBounds;
        if (end > current_size) return error.OutOfBounds;
        const start_usize: usize = @intCast(offset);
        const s = self.slice();
        @memcpy(dest, s[start_usize .. start_usize + dest.len]);
    }

    /// Reads `dest.len` bytes from a bounded window `[win_offset, win_offset + win_len)` at `rel_offset`.
    /// Enforces both `rel_offset + dest.len <= win_len` and `win_offset + win_len <= size`.
    pub fn readWindowAt(
        self: *const ManagedBuffer,
        win_offset: u64,
        win_len: u64,
        rel_offset: u64,
        dest: []u8,
    ) ArtifactError!void {
        const rel_end = std.math.add(u64, rel_offset, dest.len) catch return error.OutOfBounds;
        if (rel_end > win_len) return error.OutOfBounds;
        const current_size = self.size();
        const win_end = std.math.add(u64, win_offset, win_len) catch return error.OutOfBounds;
        if (win_end > current_size) return error.OutOfBounds;
        const abs_offset = std.math.add(u64, win_offset, rel_offset) catch return error.OutOfBounds;
        return self.readAt(abs_offset, dest);
    }

    /// Writes `src` at `offset`, automatically zero-extending the buffer if `offset + src.len > size`.
    /// Promotes from `.mapped_file` to heap `.memory` via Copy-on-Write.
    pub fn writeAt(self: *ManagedBuffer, allocator: Allocator, offset: u64, src: []const u8) ArtifactError!void {
        try self.promoteToMemory(allocator);
        if (src.len == 0) return;
        const end_u64 = std.math.add(u64, offset, src.len) catch return error.OutOfBounds;
        const end_usize = std.math.cast(usize, end_u64) orelse return error.OutOfBounds;
        const start_usize = std.math.cast(usize, offset) orelse return error.OutOfBounds;

        if (end_usize > self.bytes.items.len) {
            const old_len = self.bytes.items.len;
            try self.bytes.resize(allocator, end_usize);
            if (start_usize > old_len) {
                @memset(self.bytes.items[old_len..start_usize], 0);
            }
        }
        @memcpy(self.bytes.items[start_usize..end_usize], src);
    }

    /// Overwrites `[offset, offset + length)` with `0x00`. Fails with `OutOfBounds` if outside current size.
    /// Promotes from `.mapped_file` to heap `.memory` via Copy-on-Write.
    pub fn zeroRange(self: *ManagedBuffer, allocator: Allocator, offset: u64, length: u64) ArtifactError!void {
        try self.promoteToMemory(allocator);
        if (length == 0) return;
        const end_u64 = std.math.add(u64, offset, length) catch return error.OutOfBounds;
        if (end_u64 > self.bytes.items.len) return error.OutOfBounds;
        const start_usize: usize = @intCast(offset);
        const end_usize: usize = @intCast(end_u64);
        @memset(self.bytes.items[start_usize..end_usize], 0);
    }

    /// Truncates or zero-extends the buffer to `new_size`.
    /// Promotes from `.mapped_file` to heap `.memory` via Copy-on-Write.
    pub fn truncate(self: *ManagedBuffer, allocator: Allocator, new_size: u64) ArtifactError!void {
        try self.promoteToMemory(allocator);
        const new_len = std.math.cast(usize, new_size) orelse return error.OutOfBounds;
        const old_len = self.bytes.items.len;
        if (new_len <= old_len) {
            self.bytes.shrinkRetainingCapacity(new_len);
        } else {
            try self.bytes.resize(allocator, new_len);
            @memset(self.bytes.items[old_len..new_len], 0);
        }
    }
};

/// Manages the primary input stream (`"file"`), named pipeline artifacts (`output.artifact`),
/// transactional staging per task step, and carved quarantine evidence.
pub const ArtifactStore = struct {
    allocator: Allocator,
    root_file: ManagedBuffer = .{},
    artifacts: std.StringHashMapUnmanaged(ManagedBuffer) = .{},
    carved_items: std.ArrayListUnmanaged(CarvedItem) = .empty,

    pub fn init(allocator: Allocator, initial_file_bytes: []const u8) !ArtifactStore {
        return .{
            .allocator = allocator,
            .root_file = try ManagedBuffer.initCopy(allocator, initial_file_bytes),
        };
    }

    /// Creates an `ArtifactStore` by mapping a media file on disk via POSIX `mmap()` (virtual memory).
    /// Eliminates loading entire files into physical RAM.
    pub fn initFromFile(allocator: Allocator, path: []const u8) !ArtifactStore {
        return .{
            .allocator = allocator,
            .root_file = try ManagedBuffer.initMmap(allocator, path),
        };
    }

    pub fn deinit(self: *ArtifactStore) void {
        self.root_file.deinit(self.allocator);
        var it = self.artifacts.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.artifacts.deinit(self.allocator);

        for (self.carved_items.items) |*item| {
            item.deinit(self.allocator);
        }
        self.carved_items.deinit(self.allocator);
    }

    /// Resolves a read-only `ManagedBuffer` by source name (`null` or `"file"` returns the root input file;
    /// otherwise looks up a previously committed artifact by ID).
    pub fn getBuffer(self: *const ArtifactStore, source_name: ?[]const u8) ArtifactError!*const ManagedBuffer {
        const name = source_name orelse return &self.root_file;
        if (std.mem.eql(u8, name, "file")) return &self.root_file;
        return self.artifacts.getPtr(name) orelse error.StreamNotFound;
    }

    /// Publishes or replaces a named artifact buffer upon successful completion of a task step.
    pub fn putArtifact(self: *ArtifactStore, artifact_id: []const u8, buf: ManagedBuffer) !void {
        if (self.artifacts.getEntry(artifact_id)) |existing| {
            existing.value_ptr.deinit(self.allocator);
            existing.value_ptr.* = buf;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, artifact_id);
        errdefer self.allocator.free(owned_key);
        try self.artifacts.put(self.allocator, owned_key, buf);
    }

    /// Carves `[offset, offset + length)` from `source_name`, computes its lowercase SHA-256 hex digest,
    /// stores the carved evidence in `carved_items`, and returns the 64-byte hex digest.
    pub fn carveToQuarantine(
        self: *ArtifactStore,
        source_name: ?[]const u8,
        offset: u64,
        length: u64,
        reason_tag: []const u8,
    ) ArtifactError![64]u8 {
        const src_buf = try self.getBuffer(source_name);
        const len_usize = std.math.cast(usize, length) orelse return error.OutOfBounds;

        const carved_bytes = try self.allocator.alloc(u8, len_usize);
        errdefer self.allocator.free(carved_bytes);

        try src_buf.readAt(offset, carved_bytes);

        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(carved_bytes, &digest, .{});
        const hex_digest = std.fmt.bytesToHex(digest, .lower);

        const owned_reason = try self.allocator.dupe(u8, reason_tag);
        errdefer self.allocator.free(owned_reason);

        try self.carved_items.append(self.allocator, .{
            .reason_tag = owned_reason,
            .offset = offset,
            .length = length,
            .sha256_hex = hex_digest,
            .data = carved_bytes,
        });

        return hex_digest;
    }
};

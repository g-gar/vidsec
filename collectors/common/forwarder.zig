const std = @import("std");
const Allocator = std.mem.Allocator;
const JobEnvelope = @import("envelope.zig").JobEnvelope;
const SpoolQueue = @import("spool.zig").SpoolQueue;
const EngineClient = @import("engine_client.zig").EngineClient;

/// Orchestrates live delivery to Flowdata with automatic Store-and-Forward
/// fallback to a local persistent disk spool when the engine is unreachable.
pub const SpoolForwarder = struct {
    allocator: Allocator,
    client: EngineClient,
    spool: SpoolQueue,
    collector_name: []const u8,

    pub fn init(
        allocator: Allocator,
        collector_name: []const u8,
        engine_url: []const u8,
        spool_dir: []const u8,
    ) !SpoolForwarder {
        const client = try EngineClient.init(allocator, engine_url);
        const spool = try SpoolQueue.init(allocator, spool_dir);
        const owned_name = try allocator.dupe(u8, collector_name);

        return .{
            .allocator = allocator,
            .collector_name = owned_name,
            .client = client,
            .spool = spool,
        };
    }

    pub fn deinit(self: *SpoolForwarder) void {
        self.allocator.free(self.collector_name);
        self.client.deinit();
        self.spool.deinit();
        self.* = undefined;
    }

    pub const SendResult = struct {
        delivered: bool,
        spooled: bool,
    };

    pub fn send(self: *SpoolForwarder, job: JobEnvelope) !SendResult {
        const delivered = try self.dispatch(job);
        return .{
            .delivered = delivered,
            .spooled = !delivered,
        };
    }

    /// Dispatches a job: attempts live HTTP delivery if no prior queue exists;
    /// otherwise spools to disk to strictly preserve chronological FIFO order.
    /// Returns `true` if delivered immediately, `false` if persisted to spool.
    pub fn dispatch(self: *SpoolForwarder, job: JobEnvelope) !bool {
        // If there are prior spooled jobs, we must spool to preserve FIFO
        if (self.spool.count() == 0) {
            const delivered = self.client.sendJob(job);
            if (delivered) {
                std.debug.print("[{s}] [DIRECT] Delivered job '{s}' to {s}\n", .{
                    self.collector_name, job.id, self.client.engine_url,
                });
                return true;
            }
        }

        // Engine is down or prior queue exists: spool to disk
        try self.spool.push(job);
        std.debug.print("[{s}] [SPOOL] Engine offline. Persisted job '{s}' to spool ({s})\n", .{
            self.collector_name, job.id, self.spool.spool_dir,
        });

        // Try an opportunistic flush in case engine just came back up
        _ = self.flush() catch {};
        return false;
    }

    /// Drains the persistent disk spool in FIFO order while Flowdata is reachable.
    /// Returns the number of jobs successfully flushed.
    pub fn flush(self: *SpoolForwarder) !usize {
        var flushed: usize = 0;

        while (true) {
            var job = (try self.spool.peek()) orelse break;
            defer job.deinit(self.allocator);

            const delivered = self.client.sendJob(job);
            if (!delivered) {
                // Engine is still down: stop draining and preserve remaining queue
                break;
            }

            // Confirmed delivered: pop and remove from disk
            var popped = (try self.spool.pop()) orelse break;
            popped.deinit(self.allocator);

            flushed += 1;
            std.debug.print("[{s}] [FLUSH] Flushed spooled job '{s}' to {s} (remaining in spool: {d})\n", .{
                self.collector_name, job.id, self.client.engine_url, self.spool.count(),
            });
        }

        return flushed;
    }
};

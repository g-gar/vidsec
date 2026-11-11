const std = @import("std");

/// Clean POSIX Mutex wrapping `pthread_mutex_t`.
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn init() Mutex {
        return .{};
    }

    pub fn lock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_lock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn tryLock(self: *Mutex) bool {
        return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }

    pub fn unlock(self: *Mutex) void {
        const rc = std.c.pthread_mutex_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn deinit(self: *Mutex) void {
        _ = std.c.pthread_mutex_destroy(&self.inner);
    }
};

/// Clean POSIX Condition Variable wrapping `pthread_cond_t`.
pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn init() Condition {
        return .{};
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const rc = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) bool {
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.posix.CLOCK.REALTIME, &now);

        const sec_to_add: i64 = @intCast(timeout_ns / std.time.ns_per_s);
        const nsec_to_add: i64 = @intCast(timeout_ns % std.time.ns_per_s);

        var ts: std.c.timespec = .{
            .sec = now.sec + sec_to_add,
            .nsec = now.nsec + nsec_to_add,
        };
        if (ts.nsec >= std.time.ns_per_s) {
            ts.sec += 1;
            ts.nsec -= std.time.ns_per_s;
        }

        const rc = std.c.pthread_cond_timedwait(&self.inner, &mutex.inner, &ts);
        return rc == .SUCCESS;
    }

    pub fn signal(self: *Condition) void {
        const rc = std.c.pthread_cond_signal(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn broadcast(self: *Condition) void {
        const rc = std.c.pthread_cond_broadcast(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn deinit(self: *Condition) void {
        _ = std.c.pthread_cond_destroy(&self.inner);
    }
};

/// Clean POSIX Read-Write Lock wrapping `pthread_rwlock_t`.
pub const RwLock = struct {
    inner: std.c.pthread_rwlock_t = .{},

    pub fn init() RwLock {
        return .{};
    }

    pub fn lockRead(self: *RwLock) void {
        const rc = std.c.pthread_rwlock_rdlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn lockWrite(self: *RwLock) void {
        const rc = std.c.pthread_rwlock_wrlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(self: *RwLock) void {
        const rc = std.c.pthread_rwlock_unlock(&self.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn deinit(self: *RwLock) void {
        _ = std.c.pthread_rwlock_destroy(&self.inner);
    }
};

/// WaitGroup coordinating batch completion across multiple worker threads.
pub const WaitGroup = struct {
    remaining: std.atomic.Value(usize),
    mutex: Mutex = .{},
    cond: Condition = .{},

    pub fn init(count: usize) WaitGroup {
        return .{
            .remaining = std.atomic.Value(usize).init(count),
        };
    }

    pub fn add(self: *WaitGroup, count: usize) void {
        _ = self.remaining.fetchAdd(count, .release);
    }

    pub fn done(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const prev = self.remaining.fetchSub(1, .release);
        if (prev <= 1) {
            self.cond.broadcast();
        }
    }

    pub fn isDone(self: *const WaitGroup) bool {
        const mutable: *WaitGroup = @constCast(self);
        return mutable.remaining.load(.acquire) == 0;
    }

    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.remaining.load(.acquire) > 0) {
            self.cond.wait(&self.mutex);
        }
    }
};

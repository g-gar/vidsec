const std = @import("std");

/// Lazy record iterator over a contiguous slice or streaming cursor (ARCH-016 §6.4).
pub fn Rows(comptime T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,

        pub const ElementType = T;
        pub const is_flowdata_rows = true;

        pub fn init(items: []const T) @This() {
            return .{
                .items = items,
                .index = 0,
            };
        }

        pub fn next(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            const item = self.items[self.index];
            self.index += 1;
            return item;
        }

        pub fn len(self: @This()) usize {
            return self.items.len;
        }

        pub fn reset(self: *@This()) void {
            self.index = 0;
        }
    };
}

const std = @import("std");

/// A thread-safe, blocking, generic mailbox with timeout and cancellation.
pub fn Mailbox(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        queue: std.ArrayList(T),
        closed: bool = false,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .queue = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.deinit(self.allocator);
        }

        /// Push a message and wake up receiver
        pub fn send(self: *Self, msg: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.MailboxClosed;

            try self.queue.append(self.allocator, msg);
            self.cond.signal(); // Wake up one waiting thread
        }

        /// Wait for a message with a timeout (in nanoseconds)
        /// Returns: T (success), error.Empty (timeout), or error.MailboxClosed
        pub fn receive(self: *Self, timeout_ns: u64) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait while empty and not closed
            if (self.queue.items.len == 0 and !self.closed) {
                // timedWait returns error.TimedOut if time expires
                self.cond.timedWait(&self.mutex, timeout_ns) catch {};
            }

            if (self.closed) return error.MailboxClosed;
            if (self.queue.items.len == 0) return error.Timeout;

            return self.queue.orderedRemove(0);
        }

        /// Wake up all threads and prevent new messages
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
        }

        /// Check if empty (non-blocking)
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.queue.items.len == 0;
        }
    };
}

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const EventLoop = @import("event_loop.zig").EventLoop;
const Mailbox = z.Mailbox;

pub const WorkerMessage = struct {
    tag: enum { Script, PostMessage, Terminate },
    data: []u8, // Heap-allocated string/bytes
};

pub const WorkerActor = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    mailbox: Mailbox(WorkerMessage),

    pub fn init(allocator: std.mem.Allocator) !*WorkerActor {
        const self = try allocator.create(WorkerActor);
        self.* = .{
            .allocator = allocator,
            .mailbox = Mailbox(WorkerMessage).init(allocator),
            .thread = undefined, // Set after spawn
        };

        // Spawn thread - must be done after self is fully initialized
        self.thread = try std.Thread.spawn(.{}, workerEntry, .{self});
        return self;
    }

    pub fn deinit(self: *WorkerActor) void {
        self.mailbox.close();
        self.thread.join();
        self.mailbox.deinit();
        self.allocator.destroy(self);
    }

    fn workerEntry(self: *WorkerActor) void {
        // 1. Setup Isolated Environment
        const rt = zqjs.Runtime.init(self.allocator) catch return;
        defer rt.deinit();

        const ctx = zqjs.Context.init(&rt);
        defer ctx.deinit();

        var loop = EventLoop.create(self.allocator, &rt) catch return;
        defer loop.destroy();
        loop.install(ctx) catch return; // Install bindings

        var running = true;

        // 2. The Event Loop
        while (running) {
            // A. Execute any ready JS tasks (Microtasks/Promises)
            _ = rt.executePendingJob();

            // B. Process async task results (if any completed)
            loop.processAsyncTasks() catch {};

            // C. Check Timers (returns time to next timer in ms, or null if none)
            const next_timer_ms = loop.processTimers() catch null;

            // D. Calculate wait time
            // - If we have timers, wait until next timer
            // - Otherwise, wait a default interval (e.g., 100ms for responsiveness)
            const wait_ms: i64 = next_timer_ms orelse 100;
            const timeout_ns = @as(u64, @intCast(@max(wait_ms, 0))) * std.time.ns_per_ms;

            // E. Wait for Mailbox OR Timeout
            if (self.mailbox.receive(timeout_ns)) |msg| {
                // === We got a message! ===
                defer self.allocator.free(msg.data); // Clean up payload

                switch (msg.tag) {
                    .Script => {
                        // Execute script in worker context
                        const result = ctx.eval(msg.data, "<worker>", .{}) catch z.jsException;
                        ctx.freeValue(result);
                    },
                    .PostMessage => {
                        // TODO: Fire 'onmessage' event
                        // For now, just log it
                        std.debug.print("[Worker] Received message: {s}\n", .{msg.data});
                    },
                    .Terminate => {
                        running = false;
                    },
                }
            } else |err| {
                switch (err) {
                    error.Timeout => {
                        // Timeout reached: loop back to top to process timers/tasks
                    },
                    error.MailboxClosed => {
                        running = false;
                    },
                    else => {},
                }
            }
        }
    }

    // Public API for Main Thread
    pub fn postMessage(self: *WorkerActor, data: []const u8) !void {
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        try self.mailbox.send(.{ .tag = .PostMessage, .data = copy });
    }

    pub fn executeScript(self: *WorkerActor, script: []const u8) !void {
        const copy = try self.allocator.dupe(u8, script);
        errdefer self.allocator.free(copy);
        try self.mailbox.send(.{ .tag = .Script, .data = copy });
    }

    pub fn terminate(self: *WorkerActor) !void {
        const empty = try self.allocator.alloc(u8, 0);
        try self.mailbox.send(.{ .tag = .Terminate, .data = empty });
    }
};

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;

const http_ex = @import("main.zig").zexplore_example_com;

// Worker task context for HTTP fetch
pub const WorkerTask = struct {
    loop: *EventLoop,
    url: []const u8,
    resolve: zqjs.Value,
    reject: zqjs.Value,
    ctx: zqjs.Context,
};

// Worker function that runs on thread pool
pub fn workerFetchHTTP(task: WorkerTask) void {
    // Free the URL copy when done (was allocated in js_fetch)
    defer task.loop.allocator.free(task.url);

    // Perform HTTP fetch (blocking, but on worker thread)
    const css = http_ex(task.loop.allocator, task.url) catch |err| {
        // On error, send rejection
        const err_msg = std.fmt.allocPrint(
            task.loop.allocator,
            "HTTP fetch failed: {s}",
            .{@errorName(err)},
        ) catch {
            // If we can't even allocate error message, send generic error
            const fallback = task.loop.allocator.dupe(u8, "HTTP fetch failed (OOM)") catch return;
            task.loop.enqueueTask(.{
                .ctx = task.ctx,
                .resolve = task.resolve,
                .reject = task.reject,
                .result = .{ .failure = fallback },
            });
            return;
        };

        task.loop.enqueueTask(.{
            .ctx = task.ctx,
            .resolve = task.resolve,
            .reject = task.reject,
            .result = .{ .failure = err_msg },
        });
        return;
    };

    // Success: send CSS content back
    task.loop.enqueueTask(.{
        .ctx = task.ctx,
        .resolve = task.resolve,
        .reject = task.reject,
        .result = .{ .success = css },
    });
}

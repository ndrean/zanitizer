const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;

// ============================================================================
// Payload Types (for async_bridge.zig)
// ============================================================================

/// Payload for HTTP fetch operation
pub const FetchPayload = struct {
    url: []const u8, // Owned, will be freed by worker
};

/// Payload for simulated work operation
pub const SimulateWorkPayload = struct {
    delay_ms: u64,
};

/// Payload for file reading operation
pub const ReadFilePayload = struct {
    path: []const u8, // Owned, will be freed by worker
};

// ============================================================================
// Legacy WorkerTask (for manual bindings in utils.zig)
// TODO: Remove once we migrate to async_bridge generated bindings
// ============================================================================

pub const WorkerTask = struct {
    loop: *EventLoop,
    url: []const u8,
    resolve: zqjs.Value,
    reject: zqjs.Value,
    ctx: zqjs.Context,
};

pub fn workerSimulate(task: WorkerTask) void {
    // We reuse the 'url' field as the payload containing the delay string
    defer task.loop.allocator.free(task.url);

    // Parse "1000" -> 1000u64
    const delay_ms = std.fmt.parseInt(u64, task.url, 10) catch 500;

    // BLOCKING CALL (Runs on background thread, does not block JS loop)
    std.Thread.sleep(delay_ms * 1_000_000);

    // Create result message
    const msg = std.fmt.allocPrint(task.loop.allocator, "✅ Work finished after {d}ms", .{delay_ms}) catch return;

    // Send back to Main Thread
    task.loop.enqueueTask(.{
        .ctx = task.ctx,
        .resolve = task.resolve,
        .reject = task.reject,
        .result = .{ .success = msg },
    });
}

// Worker function that runs on thread pool
pub fn workerFetchHTTP(task: WorkerTask) void {
    // Free the URL copy when done (was allocated in js_fetch)
    defer task.loop.allocator.free(task.url);

    // Perform HTTP fetch (blocking, but on worker thread)
    const css = zexplore_example_com(task.loop.allocator, task.url) catch |err| {
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

pub fn zexplore_example_com(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    z.print("\n=== Demo visiting the page {s} --------------\n\n", .{url});
    const page = try z.get(allocator, url);
    defer allocator.free(page);
    const doc = try z.createDocFromString(page);
    defer z.destroyDocument(doc);
    const html = z.documentRoot(doc).?;
    try z.prettyPrint(allocator, html);

    var css_engine = try z.createCssEngine(allocator);
    defer css_engine.deinit();

    const a_link = try css_engine.querySelector(html, "a[href]");

    const href_value = z.getAttribute_zc(z.nodeToElement(a_link.?).?, "href").?;
    z.print("{s}\n", .{href_value});

    const style_by_walker = z.getElementByTag(html, .style);
    var css_content: []u8 = undefined;
    if (style_by_walker) |style| {
        // Use allocating version - caller (Worker) will free
        css_content = try z.textContent(allocator, z.elementToNode(style));
        z.print("{s}\n", .{css_content});
    }

    const style_by_css = try css_engine.querySelector(html, "style");

    if (style_by_css) |style| {
        const css_content_2 = z.textContent_zc(style);
        // z.print("{s}\n", .{css_content_2});
        std.debug.assert(std.mem.eql(u8, css_content, css_content_2));
    }
    return css_content;
}

// ============================================================================
// Worker Functions (for async_bridge.zig)
// Signature: fn(allocator: std.mem.Allocator, payload: PayloadType) ![]u8
// ============================================================================

/// Worker for HTTP fetch - async_bridge compatible
pub fn workerFetch(allocator: std.mem.Allocator, payload: FetchPayload) ![]u8 {
    defer allocator.free(payload.url);
    return try zexplore_example_com(allocator, payload.url);
}

/// Worker for simulated work - async_bridge compatible
pub fn workerSimulateAsync(allocator: std.mem.Allocator, payload: SimulateWorkPayload) ![]u8 {
    // BLOCKING CALL (Runs on background thread, does not block JS loop)
    std.Thread.sleep(payload.delay_ms * 1_000_000);

    // Create result message
    return try std.fmt.allocPrint(allocator, "✅ Work finished after {d}ms", .{payload.delay_ms});
}

/// Worker for file reading - async_bridge compatible
pub fn workerReadFile(allocator: std.mem.Allocator, payload: ReadFilePayload) ![]u8 {
    // CRITICAL: Free the path when done - it was allocated by the parser
    defer allocator.free(payload.path);

    // BLOCKING I/O (runs on worker thread)
    const file = try std.fs.cwd().openFile(payload.path, .{});
    defer file.close();

    // Read entire file into memory
    const max_size = 10 * 1024 * 1024; // 10MB limit
    const content = try file.readToEndAlloc(allocator, max_size);

    // Return owned string - async_bridge will pass it to Promise.resolve()
    return content;
}

//! Example showing how to use async_bridge.zig to create async bindings
//! This eliminates all the boilerplate from utils.zig

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const async_bridge = @import("async_bridge.zig");
const Worker = @import("Worker.zig");

// ============================================================================
// Parse Functions (run on main thread, extract args from JS)
// ============================================================================

/// Parse arguments for fetch(url)
fn parseFetch(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Worker.FetchPayload {
    if (args.len < 1) return error.InvalidArgCount;

    // Extract URL string from JS
    const url_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(url_str);

    // DIRECT ACCESS to the heap-persisted EventLoop allocator
    // This allocator was created by EventLoop.create() and lives on the heap
    const url_copy = try loop.allocator.dupe(u8, std.mem.span(url_str));

    return .{ .url = url_copy };
}

/// Parse arguments for simulateWork(delay_ms)
fn parseSimulateWork(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Worker.SimulateWorkPayload {
    _ = loop; // Not needed for this simple case (no string allocation)
    if (args.len < 1) return error.InvalidArgCount;

    // Extract delay as integer
    const delay_i32 = try ctx.toInt32(args[0]);
    if (delay_i32 < 0) return error.InvalidDelay;

    return .{ .delay_ms = @intCast(delay_i32) };
}

/// Parse arguments for readFile(path)
fn parseReadFile(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Worker.ReadFilePayload {
    if (args.len < 1) {
        _ = ctx.throwTypeError("readFile requires 1 argument (path)");
        return error.InvalidArgCount;
    }

    // Extract path string from JS
    const path_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(path_str);

    // DIRECT ACCESS to the correct allocator. No lookups.
    // This is CRITICAL: We use the heap-persisted EventLoop allocator
    const owned_path = try loop.allocator.dupe(u8, std.mem.span(path_str));

    return .{ .path = owned_path };
}

// ============================================================================
// Bindings - One-liners using async_bridge.bindAsync()
// ============================================================================

/// fetch(url) -> Promise<string>
/// Fetches an HTTP URL and returns the CSS content
pub const js_fetch = async_bridge.bindAsync(
    Worker.FetchPayload,
    parseFetch,
    Worker.workerFetch,
);

/// simulateWork(delay_ms) -> Promise<string>
/// Simulates work by sleeping for delay_ms milliseconds
pub const js_simulateWork = async_bridge.bindAsync(
    Worker.SimulateWorkPayload,
    parseSimulateWork,
    Worker.workerSimulateAsync,
);

/// readFile(path) -> Promise<string>
/// Reads a file asynchronously and returns its contents
pub const js_readFile = async_bridge.bindAsync(
    Worker.ReadFilePayload,
    parseReadFile,
    Worker.workerReadFile,
);

// ============================================================================
// Compare: Manual vs async_bridge approach
// ============================================================================

// BEFORE (manual boilerplate in utils.zig): ~74 lines for js_fetch
// - Get EventLoop
// - Parse URL
// - Duplicate URL
// - Create Promise with JS_NewPromiseCapability
// - Create WorkerTask struct
// - Handle all error cases (6 different error returns)
// - Spawn worker
// - Return promise

// AFTER (using async_bridge):
// - Parse function: ~15 lines
// - Binding declaration: 1 line
// Total: ~16 lines

// That's a 78% reduction in boilerplate!

// ============================================================================
// How to install these bindings
// ============================================================================

pub fn installAsyncBindings(ctx: zqjs.Context, global: zqjs.Object) !void {
    _ = ctx; // Not used, but required for consistency with other install functions
    try global.setFunction("fetch", js_fetch, 1);
    try global.setFunction("simulateWork", js_simulateWork, 1);
    try global.setFunction("readFile", js_readFile, 1);
}

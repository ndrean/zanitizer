//! Example: Automatic async binding generation using auto_bridge.zig
//! Zero boilerplate - just define struct and worker function!

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const AutoBridge = @import("auto_bridge.zig");
const Worker = @import("Worker.zig");

// ============================================================================
// Example 1: File Reading (String argument)
// ============================================================================

// Step 1: Define payload struct
// IMPORTANT: Field order MUST match JavaScript argument order!
const ReadFilePayload = struct {
    path: []const u8, // JS arg[0]
};

// Step 2: Define worker function
// IMPORTANT: Must free owned string fields!
fn doReadFile(allocator: std.mem.Allocator, task: ReadFilePayload) ![]u8 {
    // CRITICAL: Free the string that was allocated by auto_bridge
    defer allocator.free(task.path);

    const file = try std.fs.cwd().openFile(task.path, .{});
    defer file.close();

    const max_size = 10 * 1024 * 1024; // 10MB
    const content = try file.readToEndAlloc(allocator, max_size);

    return content;
}

// Step 3: Generate binding (ONE LINE!)
pub const js_readFile = AutoBridge.bindAsyncAuto(ReadFilePayload, doReadFile);

// ============================================================================
// Example 2: Simulated Work (Integer argument)
// ============================================================================

const SimulateWorkPayload = struct {
    delay_ms: u64, // JS arg[0]
};

fn doSimulateWork(allocator: std.mem.Allocator, task: SimulateWorkPayload) ![]u8 {
    std.Thread.sleep(task.delay_ms * 1_000_000);
    return try std.fmt.allocPrint(allocator, "✅ Completed after {d}ms", .{task.delay_ms});
}

pub const js_simulateWork = AutoBridge.bindAsyncAuto(SimulateWorkPayload, doSimulateWork);

// ============================================================================
// Example 3: HTTP Fetch (String argument, delegates to existing worker)
// ============================================================================

const FetchPayload = struct {
    url: []const u8, // JS arg[0]
};

fn doFetch(allocator: std.mem.Allocator, task: FetchPayload) ![]u8 {
    defer allocator.free(task.url);
    return try Worker.zexplore_example_com(allocator, task.url);
}

pub const js_fetch = AutoBridge.bindAsyncAuto(FetchPayload, doFetch);

// ============================================================================
// Example 4: Write File (Multiple arguments)
// ============================================================================

const WriteFilePayload = struct {
    path: []const u8, // JS arg[0]
    content: []const u8, // JS arg[1]
};

fn doWriteFile(allocator: std.mem.Allocator, task: WriteFilePayload) ![]u8 {
    // CRITICAL: Free BOTH strings
    defer allocator.free(task.path);
    defer allocator.free(task.content);

    const file = try std.fs.cwd().createFile(task.path, .{});
    defer file.close();

    try file.writeAll(task.content);

    return try std.fmt.allocPrint(
        allocator,
        "Wrote {d} bytes to {s}",
        .{ task.content.len, task.path },
    );
}

pub const js_writeFile = AutoBridge.bindAsyncAuto(WriteFilePayload, doWriteFile);

// ============================================================================
// Example 5: Math Operation (Multiple numeric arguments)
// ============================================================================

const AddPayload = struct {
    a: i32, // JS arg[0]
    b: i32, // JS arg[1]
};

fn doAdd(allocator: std.mem.Allocator, task: AddPayload) ![]u8 {
    const result = task.a + task.b;
    return try std.fmt.allocPrint(allocator, "{d} + {d} = {d}", .{ task.a, task.b, result });
}

pub const js_addAsync = AutoBridge.bindAsyncAuto(AddPayload, doAdd);

// ============================================================================
// Example 6: Sleep with callback message (String + Integer)
// ============================================================================

const SleepWithMessagePayload = struct {
    message: []const u8, // JS arg[0]
    delay_ms: u32, // JS arg[1]
};

fn doSleepWithMessage(allocator: std.mem.Allocator, task: SleepWithMessagePayload) ![]u8 {
    defer allocator.free(task.message);

    std.Thread.sleep(task.delay_ms * 1_000_000);

    return try std.fmt.allocPrint(
        allocator,
        "After {d}ms: {s}",
        .{ task.delay_ms, task.message },
    );
}

pub const js_sleepWithMessage = AutoBridge.bindAsyncAuto(SleepWithMessagePayload, doSleepWithMessage);

// ============================================================================
// Installation
// ============================================================================

pub fn installAutoBindings(ctx: zqjs.Context, global: zqjs.Object) !void {
    _ = ctx;
    try global.setFunction("readFile", js_readFile, 1);
    try global.setFunction("writeFile", js_writeFile, 2);
    try global.setFunction("simulateWork", js_simulateWork, 1);
    try global.setFunction("fetch", js_fetch, 1);
    try global.setFunction("addAsync", js_addAsync, 2);
    try global.setFunction("sleepWithMessage", js_sleepWithMessage, 2);
}

// ============================================================================
// Code Comparison
// ============================================================================

// BEFORE (Manual parser in async_bindings_example.zig):
// ~15 lines per binding
//
// fn parseReadFile(loop: *EventLoop, ctx: Context, args: []const Value) !Payload {
//     if (args.len < 1) return error.InvalidArgCount;
//     const path_str = try ctx.toCString(args[0]);
//     defer ctx.freeCString(path_str);
//     const owned_path = try loop.allocator.dupe(u8, std.mem.span(path_str));
//     return .{ .path = owned_path };
// }
// pub const js_readFile = async_bridge.bindAsync(Payload, parseReadFile, workerReadFile);
//
// AFTER (Auto-generated):
// ~3 lines per binding
//
// const ReadFilePayload = struct { path: []const u8 };
// fn doReadFile(allocator: Allocator, task: ReadFilePayload) ![]u8 { ... }
// pub const js_readFile = AutoBridge.bindAsyncAuto(ReadFilePayload, doReadFile);
//
// That's an 80% reduction in binding code!

//! workers Functions (for async_bridge.zig)

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper; // Zig QuickJS wrapper
const qjs = z.qjs; // C-bindings
const EventLoop = z.EventLoop;
const RuntimeContext = z.RuntimeContext;
const curl = @import("curl");

// ============================================================================
// Payload Types (for async_bridge.zig)
// ============================================================================

pub const FetchContext = struct {
    // Input
    URL: []const u8,
    // Output
    status: i64 = 0,
    body: ?[]u8 = null, // Owned by heap
    err_msg: ?[]u8 = null,

    pub fn deinit(self: *FetchContext, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.body) |b| allocator.free(b);
        if (self.err_msg) |e| allocator.free(e);
        allocator.destroy(self);
    }

    fn fail(self: *FetchContext, allocator: std.mem.Allocator, err: anytype) void {
        self.err_msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch null;
        return;
    }
};

// helper struct to hold Promise resolvers and context for the EventLoop
pub const FetchTask = struct {
    loop: *EventLoop,
    ctx: zqjs.Context,
    resolve: zqjs.Value,
    reject: zqjs.Value,
    data: *FetchContext,
};

// This runs on the WORKER THREAD - can't return errors. To be tested.
pub fn workerFetch(allocator: std.mem.Allocator, ctx: *FetchContext) void {
    const ca_bundle = curl.allocCABundle(allocator) catch |err| {
        ctx.fail(allocator, @errorName(err));
        return;
    };
    defer ca_bundle.deinit();

    const easy = curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    }) catch |err| {
        ctx.fail(allocator, @errorName(err));
        return;
    };
    defer easy.deinit();

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    // 2. Create null-terminated URL
    const zURL = allocator.dupeZ(u8, ctx.URL) catch |err| {
        ctx.fail(allocator, @errorName(err));
        return;
    };
    defer allocator.free(zURL);

    const response = easy.fetch(
        zURL,
        .{ .writer = &writer },
    ) catch |err| {
        ctx.fail(allocator, @errorName(err));
        return;
    };

    ctx.status = response.status_code;
    ctx.body = writer.toOwnedSlice() catch |err| {
        ctx.fail(allocator, @errorName(err));
        return;
    };
}

pub fn js_fetch(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("URL required");

    const url_str = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(url_str);

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    // 1. Alloc Task Data
    const data = loop.allocator.create(FetchContext) catch return ctx.throwOutOfMemory();
    data.* = .{ .URL = loop.allocator.dupe(u8, std.mem.span(url_str)) catch return ctx.throwOutOfMemory() };

    // 2. Create Promise
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);

    // 3. Alloc Task Wrapper (to hold promise refs)
    const task = loop.allocator.create(FetchTask) catch return ctx.throwOutOfMemory();
    task.* = .{
        .loop = loop,
        .ctx = ctx,
        .resolve = resolvers[0],
        .reject = resolvers[1],
        .data = data,
    };

    // 4. Spawn
    // Note: You might need to adjust 'spawnWorker' signature to accept *anyopaque if not using generic
    // Or just use the existing AsyncBridge but bypass the JSON part.
    // For now, assuming you can spawn a generic function:
    loop.spawnWorker(workerFetch, task) catch {
        loop.allocator.destroy(task);
        loop.allocator.destroy(data);
        return ctx.throwOutOfMemory();
    };

    return promise;
}

// ===========================================================================
// File Reading Worker: TODO
// ===========================================================================

/// Payload for file reading operation
///
/// ❗️ Caller owns the path
pub const ReadFilePayload = struct {
    path: []const u8, // Owned, will be freed by worker
};
/// Worker for file reading - async_bridge compatible
///
/// ❗️ Caller owns the content
/// ⚠️ payload.path is freed by the bindAsyncAuto wrapper, NOT by this function.
pub fn workerReadFile(allocator: std.mem.Allocator, payload: ReadFilePayload) ![]u8 {
    // BLOCKING I/O (runs on worker thread)
    const file = try std.fs.cwd().openFile(
        payload.path,
        .{ .mode = .read_only },
    );
    defer file.close();

    // [TODO] use Zig 0.15.2 semantics
    const max_size = 10 * 1024 * 1024; // 10MB limit
    const content = try file.readToEndAlloc(allocator, max_size);

    // Return owned string - async_bridge will pass it to Promise.resolve()
    return content;
}

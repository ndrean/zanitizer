const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const Worker = @import("Worker.zig");

pub fn js_consoleLog(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const str = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (str != null) {
            defer qjs.JS_FreeCString(ctx, str);
            if (i > 0) z.print(" ", .{});
            z.print("{s}", .{str});
        }
    }
    z.print("\n", .{});
    return zqjs.UNDEFINED;
}

// JavaScript binding: fetch(url) -> Promise
pub fn js_fetch(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    if (argc < 1) return ctx.throwTypeError("fetch requires 1 argument (url)");

    const loop = EventLoop.getFromContext(ctx) orelse {
        return ctx.throwInternalError("EventLoop not found");
    };

    // Get URL string
    const url_str = ctx.toCString(argv[0]) catch {
        return ctx.throwTypeError("URL must be a string");
    };
    defer ctx.freeCString(url_str);

    // Duplicate URL for worker thread (it will free it)
    const url_copy = loop.allocator.dupe(u8, std.mem.span(url_str)) catch {
        return ctx.throwInternalError("Out of memory");
    };
    errdefer loop.allocator.free(url_copy);

    // Create Promise using raw QuickJS API
    var resolving_funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx_ptr, &resolving_funcs);
    if (ctx.isException(promise)) {
        loop.allocator.free(url_copy);
        return promise;
    }

    // resolving_funcs[0] = resolve, resolving_funcs[1] = reject
    const resolve = resolving_funcs[0];
    const reject = resolving_funcs[1];

    // Create worker task
    const worker_task = Worker.WorkerTask{
        .loop = loop,
        .url = url_copy,
        .resolve = resolve,
        .reject = reject,
        .ctx = ctx,
    };

    // Spawn on thread pool
    loop.spawnWorker(Worker.workerFetchHTTP, worker_task) catch {
        qjs.JS_FreeValue(ctx_ptr, resolve);
        qjs.JS_FreeValue(ctx_ptr, reject);
        loop.allocator.free(url_copy);
        qjs.JS_FreeValue(ctx_ptr, promise);
        return ctx.throwInternalError("Failed to spawn worker");
    };

    return promise;
}

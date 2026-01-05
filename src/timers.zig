//! Timer API implementations (setTimeout, setInterval, clearTimeout, clearInterval)

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig");

pub fn js_setTimeout(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return zqjs.EXCEPTION;

    const loop = EventLoop.EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const callback = argv[0];
    if (!ctx.isFunction(callback)) return ctx.throwTypeError("Callback must be a function");

    var interval: i32 = 0;
    if (qjs.JS_ToInt32(ctx.ptr, &interval, argv[1]) != 0) return zqjs.EXCEPTION;
    if (interval < 0) interval = 0;

    const id = loop.addTimer(
        ctx,
        callback,
        interval,
        false,
    ) catch return ctx.throwInternalError("Failed to add timer");
    return ctx.newInt32(id);
}

pub fn js_setInterval(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return zqjs.EXCEPTION;

    const loop = EventLoop.EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const callback = argv[0];
    if (!ctx.isFunction(callback)) return ctx.throwTypeError("Callback must be a function");

    var interval: i32 = 0;
    if (qjs.JS_ToInt32(ctx.ptr, &interval, argv[1]) != 0) return zqjs.EXCEPTION;
    if (interval < 0) interval = 0;

    const id = loop.addTimer(
        ctx,
        callback,
        interval,
        true,
    ) catch return ctx.throwInternalError("Failed to add timer");
    return ctx.newInt32(id);
}

pub fn js_clearTimeout(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return zqjs.UNDEFINED;
    const loop = EventLoop.EventLoop.getFromContext(ctx) orelse return zqjs.UNDEFINED;

    var id: i32 = 0;
    if (qjs.JS_ToInt32(ctx.ptr, &id, argv[0]) == 0) loop.cancelTimer(id);
    return zqjs.UNDEFINED;
}

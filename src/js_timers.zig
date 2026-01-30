const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// Helper to install functions with specific length (argument count)
fn installFn(ctx: zqjs.Context, func: qjs.JSCFunction, obj: zqjs.Value, name: [:0]const u8, prop: [:0]const u8, len: c_int) !void {
    const named_fn = ctx.newCFunction(func, name, len);
    _ = try ctx.setPropertyStr(obj, prop, named_fn);
}

// ----------------------------------------------------------------------------
// C-API Bindings
// ----------------------------------------------------------------------------

fn js_setTimeout(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return ctx.throwTypeError("setTimeout requires 2 arguments");

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    var delay: i64 = 0;
    _ = qjs.JS_ToInt64(ctx_ptr, &delay, argv[1]);

    // addTimer(ctx, callback, delay, is_interval)
    const id = loop.addTimer(ctx, argv[0], delay, false) catch return ctx.throwOutOfMemory();

    return ctx.newInt32(id);
}

fn js_setInterval(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return ctx.throwTypeError("setInterval requires 2 arguments");

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    var delay: i64 = 0;
    _ = qjs.JS_ToInt64(ctx_ptr, &delay, argv[1]);

    const id = loop.addTimer(ctx, argv[0], delay, true) catch return ctx.throwOutOfMemory();

    return ctx.newInt32(id);
}

fn js_clearTimer(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return zqjs.UNDEFINED;

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    var id: i32 = 0;
    _ = qjs.JS_ToInt32(ctx_ptr, &id, argv[0]);

    loop.cancelTimer(id);

    return zqjs.UNDEFINED;
}

// ----------------------------------------------------------------------------
// Installation
// ----------------------------------------------------------------------------

pub fn install(ctx: zqjs.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    try installFn(ctx, js_setTimeout, global, "setTimeout", "setTimeout", 2);
    try installFn(ctx, js_setInterval, global, "setInterval", "setInterval", 2);
    try installFn(ctx, js_clearTimer, global, "clearTimeout", "clearTimeout", 1);
    try installFn(ctx, js_clearTimer, global, "clearInterval", "clearInterval", 1);
}

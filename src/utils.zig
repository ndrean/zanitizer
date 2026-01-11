const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const Worker = @import("workers.zig");

pub fn installFn(ctx: zqjs.Context, func: qjs.JSCFunction, obj: zqjs.Value, name: [:0]const u8, prop: [:0]const u8, len: c_int) !void {
    const named_fn = ctx.newCFunction(func, name, len);
    _ = try ctx.setPropertyStr(obj, prop, named_fn);
}

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
pub fn js_consoleError(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const str = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (str != null) {
            defer qjs.JS_FreeCString(ctx, str);
            if (i > 0) z.print(" ", .{});
            z.print("[ERROR] {s}", .{str});
        }
    }
    z.print("\n", .{});
    return zqjs.UNDEFINED;
}
// pub fn installConsole(ctx: zqjs.Context, global: zqjs.Value) !void {
//     const console_obj = try ctx.newObject();

//     try installFn(ctx, js_consoleLog, console_obj, "log", "log", 3);
//     try installFn(ctx, js_consoleError, console_obj, "error", "error", 5);

//     _ = try ctx.setPropertyStr(global, "console", console_obj);
// }

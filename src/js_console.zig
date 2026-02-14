const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const log = std.log.scoped(.js_console);

// Helper to print a single value with formatting
fn printValue(ctx: w.Context, val: qjs.JSValue, stringify_fn: qjs.JSValue) void {
    // 1. Handle Errors (print stack trace or message)
    if (z.wrapper.Context.isError(val)) {
        // Error.toString() typically gives "ErrorType: message"
        // We could also look for .stack if we wanted more detail
        if (ctx.toCString(val)) |str| {
            log.info("{s}", .{str});
            ctx.freeCString(str);
        } else |_| {
            log.info("[Error]", .{});
        }
        return;
    }

    // 2. Handle Objects (Try JSON.stringify for readability)
    if (ctx.isObject(val) and !ctx.isNull(val)) {
        // args: [value, replacer=null, space=2]
        const space = ctx.newInt32(2);
        var args = [_]qjs.JSValue{ val, w.NULL, space };

        const json_str = ctx.call(stringify_fn, w.UNDEFINED, &args);

        // We are done with 'space' (it was passed by value/copy to args array logic?
        // No, in QJS raw calls, we own our handles. 'args' array holds them.
        // We must free 'space' after call.
        defer ctx.freeValue(space);

        if (!ctx.isException(json_str)) {
            if (ctx.toCString(json_str)) |c_str| {
                log.info("{s}", .{c_str});
                ctx.freeCString(c_str);
            } else |_| {
                log.info("[Object]", .{});
            }
            ctx.freeValue(json_str);
            return;
        } else {
            // If stringify fails (e.g. circular ref), clear exception and fall back to toString
            const err = ctx.getException();
            ctx.freeValue(err);
        }
    }

    // 3. Fallback: Primitives / Default toString
    if (ctx.toCString(val)) |str| {
        log.info("{s}", .{str});
        ctx.freeCString(str);
    } else |_| {
        log.info("[Unknown]", .{});
    }
}

pub fn js_console_print(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };

    // Grab JSON.stringify once for this batch
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const json_obj = ctx.getPropertyStr(global, "JSON");
    defer ctx.freeValue(json_obj);

    const stringify_fn = ctx.getPropertyStr(json_obj, "stringify");
    defer ctx.freeValue(stringify_fn);

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) log.info(" ", .{});
        printValue(ctx, argv[i], stringify_fn);
    }
    log.info("\n", .{});

    return w.UNDEFINED;
}

pub fn install(ctx: w.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const console = ctx.newObject();

    // Attach methods
    // We reuse the same C function for log, error, warn, info
    // (unless you want prefixes like [ERROR])

    const log_fn = ctx.newCFunction(js_console_print, "log", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "log", log_fn);

    const err_fn = ctx.newCFunction(js_console_print, "error", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "error", err_fn);

    const warn_fn = ctx.newCFunction(js_console_print, "warn", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "warn", warn_fn);

    const info_fn = ctx.newCFunction(js_console_print, "info", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "info", info_fn);

    // Attach console to global
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "console", console);
}

const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;

const Stdout = *std.Io.Writer;

// Helper to print a single value
fn printValue(ctx: w.Context, val: qjs.JSValue, stringify_fn: qjs.JSValue, stdout: Stdout) void {
    // 1. Handle Errors (print stack trace or message)
    if (z.wrapper.Context.isError(val)) {
        if (ctx.toCString(val)) |str| {
            stdout.print("{s}", .{str}) catch {};
            ctx.freeCString(str);
        } else |_| {
            stdout.print("[Error]", .{}) catch {};
        }
        return;
    }

    // 2. Handle Objects (Try JSON.stringify for readability)
    if (ctx.isObject(val) and !ctx.isNull(val)) {
        const space = ctx.newInt32(2);
        var args = [_]qjs.JSValue{ val, w.NULL, space };

        const json_str = ctx.call(stringify_fn, w.UNDEFINED, &args);
        defer ctx.freeValue(space);

        if (!ctx.isException(json_str)) {
            if (ctx.toCString(json_str)) |c_str| {
                stdout.print("{s}", .{c_str}) catch {};
                ctx.freeCString(c_str);
            } else |_| {
                stdout.print("[Object]", .{}) catch {};
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
        stdout.print("{s}", .{str}) catch {};
        ctx.freeCString(str);
    } else |_| {
        stdout.print("[Unknown]", .{}) catch {};
    }
}

pub fn js_console_print(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);

    var buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&buf);
    const stdout: Stdout = &sw.interface;

    // Grab JSON.stringify once for this batch
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const json_obj = ctx.getPropertyStr(global, "JSON");
    defer ctx.freeValue(json_obj);

    const stringify_fn = ctx.getPropertyStr(json_obj, "stringify");
    defer ctx.freeValue(stringify_fn);

    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        if (i > 0) stdout.print(" ", .{}) catch {};
        printValue(ctx, argv[i], stringify_fn, stdout);
    }
    stdout.print("\n", .{}) catch {};
    stdout.flush() catch {};

    return w.UNDEFINED;
}

/// Per-request output override for server mode.
/// Set before running a script so that zxp.write() calls go to res.chunk()
/// instead of stdout. Thread-local: safe for httpz worker threads.
threadlocal var tl_chunk_fn: ?*const fn (*anyopaque, []const u8) void = null;
threadlocal var tl_chunk_ctx: ?*anyopaque = null;

pub fn setChunkWriter(fn_ptr: *const fn (*anyopaque, []const u8) void, ctx: *anyopaque) void {
    tl_chunk_fn = fn_ptr;
    tl_chunk_ctx = ctx;
}

pub fn clearChunkWriter() void {
    tl_chunk_fn = null;
    tl_chunk_ctx = null;
}

/// zxp.write(str) — writes a single string with no trailing newline.
/// In CLI mode: goes to stdout (safe for piping raw HTML/binary).
/// In server mode: goes to res.chunk() via the thread-local chunk writer.
pub fn js_stdout_write(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return w.UNDEFINED;
    const ctx = w.Context.from(ctx_ptr);

    if (ctx.toCString(argv[0])) |str| {
        const data = std.mem.span(str);
        if (tl_chunk_fn) |fn_ptr| {
            fn_ptr(tl_chunk_ctx.?, data);
        } else {
            var buf: [4096]u8 = undefined;
            var sw = std.fs.File.stdout().writer(&buf);
            const stdout: Stdout = &sw.interface;
            stdout.print("{s}", .{data}) catch {};
            stdout.flush() catch {};
        }
        ctx.freeCString(str);
    } else |_| {}

    return w.UNDEFINED;
}

pub fn js_console_error(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);

    var buf: [4096]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&buf);
    const stderr: Stdout = &sw.interface;

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const json_obj = ctx.getPropertyStr(global, "JSON");
    defer ctx.freeValue(json_obj);

    const stringify_fn = ctx.getPropertyStr(json_obj, "stringify");
    defer ctx.freeValue(stringify_fn);

    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        if (i > 0) stderr.print(" ", .{}) catch {};
        printValue(ctx, argv[i], stringify_fn, stderr);
    }
    stderr.print("\n", .{}) catch {};
    stderr.flush() catch {};

    return w.UNDEFINED;
}

pub fn js_console_assert(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    // console.assert(condition, ...data) — if condition is falsy, print "Assertion failed: " + data
    if (argc >= 1 and qjs.JS_ToBool(ctx_ptr, argv[0]) != 0) {
        return w.UNDEFINED; // condition is truthy, do nothing
    }

    const ctx = w.Context.from(ctx_ptr);

    var buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&buf);
    const stdout: Stdout = &sw.interface;

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const json_obj = ctx.getPropertyStr(global, "JSON");
    defer ctx.freeValue(json_obj);
    const stringify_fn = ctx.getPropertyStr(json_obj, "stringify");
    defer ctx.freeValue(stringify_fn);

    stdout.print("Assertion failed:", .{}) catch {};

    // Print remaining arguments (skip argv[0] which is the condition)
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        stdout.print(" ", .{}) catch {};
        printValue(ctx, argv[i], stringify_fn, stdout);
    }
    stdout.print("\n", .{}) catch {};
    stdout.flush() catch {};

    return w.UNDEFINED;
}

pub fn install(ctx: w.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const console = ctx.newObject();

    // Attach methods: reuse the same C function for log, error, warn, info

    const log_fn = ctx.newCFunction(js_console_print, "log", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "log", log_fn);

    const err_fn = ctx.newCFunction(js_console_error, "error", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "error", err_fn);

    const warn_fn = ctx.newCFunction(js_console_error, "warn", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "warn", warn_fn);

    const info_fn = ctx.newCFunction(js_console_print, "info", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "info", info_fn);

    const assert_fn = ctx.newCFunction(js_console_assert, "assert", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, console, "assert", assert_fn);

    // Attach console to global
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "console", console);
}

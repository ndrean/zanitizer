const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;

const MAX_STDIN: usize = 64 * 1024 * 1024; // 64 MB cap

/// zxp.stdin.read() → string
/// Returns all of stdin as a UTF-8 string.
/// Returns "" if stdin is a TTY (nothing piped in).
pub fn js_native_stdinRead(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = z.RuntimeContext.get(ctx);

    const stdin = std.fs.File.stdin();
    if (std.posix.isatty(stdin.handle)) return ctx.newString("");

    const data = stdin.readToEndAlloc(rc.allocator, MAX_STDIN) catch return zqjs.EXCEPTION;
    defer rc.allocator.free(data);
    return ctx.newString(data);
}

/// zxp.stdin.readBytes() → ArrayBuffer
/// Returns all of stdin as raw bytes.
/// Returns empty ArrayBuffer if stdin is a TTY.
pub fn js_native_stdinReadBytes(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = z.RuntimeContext.get(ctx);

    const stdin = std.fs.File.stdin();
    if (std.posix.isatty(stdin.handle)) return ctx.newArrayBufferCopy(&.{});

    const data = stdin.readToEndAlloc(rc.allocator, MAX_STDIN) catch return zqjs.EXCEPTION;
    defer rc.allocator.free(data);
    return ctx.newArrayBufferCopy(data);
}

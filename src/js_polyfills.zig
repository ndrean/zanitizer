const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// btoa: Binary to ASCII (Base64 Encode)
pub fn js_btoa(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return w.UNDEFINED;
    const temp_alloc = std.heap.c_allocator;

    const str = ctx.toZString(argv[0]) catch return z.jsException;
    defer ctx.freeZString(str);

    const encoder = std.base64.standard.Encoder;
    const alloc_len = encoder.calcSize(str.len);
    const output = temp_alloc.alloc(u8, alloc_len) catch return z.jsException;
    defer temp_alloc.free(output);

    _ = encoder.encode(output, str);

    return ctx.newString(output);
}

// atob: ASCII to Binary (Base64 Decode)
pub fn js_atob(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = z.wrapper.Context{ .ptr = ctx_ptr };
    if (argc < 1) return z.wrapper.UNDEFINED;
    const temp_alloc = std.heap.c_allocator;

    const str = ctx.toZString(argv[0]) catch return z.jsException;
    defer ctx.freeZString(str);

    const decoder = std.base64.standard.Decoder;
    const alloc_len = decoder.calcSizeForSlice(str) catch return ctx.throwTypeError("Invalid Base64");

    const output = temp_alloc.alloc(u8, alloc_len) catch return z.jsException;
    defer temp_alloc.free(output);

    decoder.decode(output, str) catch return ctx.throwTypeError("Invalid Base64");

    return ctx.newString(output);
}

pub fn install(ctx: w.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const btoa = ctx.newCFunction(js_btoa, "btoa", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "btoa", btoa);

    const atob = ctx.newCFunction(js_atob, "atob", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "atob", atob);
}

const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_fetch_all = @import("js_fetch_all.zig");

// btoa: Binary to ASCII (Base64 Encode)
// Per spec, btoa treats each JS character as a Latin-1 byte (code point 0-255).
// QuickJS returns UTF-8 from JS_ToCStringLen, so we must decode UTF-8 back
// to Latin-1 before base64 encoding. Also uses toCStringLen (not toZString)
// to handle embedded null bytes in binary strings.
pub fn js_btoa(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 1) return w.UNDEFINED;
    const temp_alloc = std.heap.c_allocator;

    const utf8 = ctx.toCStringLen(argv[0]) catch return z.jsException;
    defer ctx.freeCString(utf8.ptr);

    // Decode UTF-8 → Latin-1 bytes (latin1_len <= utf8.len always holds)
    const latin1_buf = temp_alloc.alloc(u8, utf8.len) catch return z.jsException;
    defer temp_alloc.free(latin1_buf);

    var latin1_len: usize = 0;
    var i: usize = 0;
    while (i < utf8.len) {
        const byte = utf8[i];
        if (byte < 0x80) {
            // ASCII: single byte
            latin1_buf[latin1_len] = byte;
            latin1_len += 1;
            i += 1;
        } else if (byte >= 0xC0 and byte < 0xE0) {
            // 2-byte UTF-8 sequence: code points 0x80-0x7FF
            if (i + 1 >= utf8.len) return ctx.throwTypeError("btoa: invalid string");
            const cp: u32 = (@as(u32, byte & 0x1F) << 6) | @as(u32, utf8[i + 1] & 0x3F);
            if (cp > 0xFF) return ctx.throwTypeError("btoa: string contains characters outside Latin-1 range");
            latin1_buf[latin1_len] = @intCast(cp);
            latin1_len += 1;
            i += 2;
        } else {
            // 3+ byte UTF-8: code point > 0x7FF, always outside Latin-1
            return ctx.throwTypeError("btoa: string contains characters outside Latin-1 range");
        }
    }

    const latin1_data = latin1_buf[0..latin1_len];
    const encoder = std.base64.standard.Encoder;
    const alloc_len = encoder.calcSize(latin1_data.len);
    const output = temp_alloc.alloc(u8, alloc_len) catch return z.jsException;
    defer temp_alloc.free(output);

    _ = encoder.encode(output, latin1_data);

    return ctx.newString(output);
}

// __flush(): Drain all pending microtasks (Promises)
// Useful for waiting on React 19's async scheduler to complete
pub fn js_flush(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const rt = qjs.JS_GetRuntime(ctx_ptr);
    drainMicrotasksGCSafe(rt, ctx_ptr);
    return w.UNDEFINED;
}

/// Drain pending microtasks with GC suppressed.
///
/// QuickJS-ng's GC can crash on corrupted `mapped_arguments` objects when
/// triggered mid-render (e.g. during Preact's microtask-scheduled VDOM diff).
/// We suppress GC during the drain and run it explicitly afterwards, when
/// all temporary objects have been properly freed.
pub fn drainMicrotasksGCSafe(rt: ?*qjs.JSRuntime, ctx_ptr: ?*qjs.JSContext) void {
    const rt_nonnull = rt orelse return;
    // Suppress GC during microtask execution
    const saved_threshold = qjs.JS_GetGCThreshold(rt_nonnull);
    qjs.JS_SetGCThreshold(rt_nonnull, std.math.maxInt(usize));

    var ctx_out: ?*qjs.JSContext = ctx_ptr;
    var iterations: u32 = 0;
    const max_iterations: u32 = 10000;

    while (iterations < max_iterations) : (iterations += 1) {
        const ret = qjs.JS_ExecutePendingJob(rt_nonnull, &ctx_out);
        if (ret <= 0) break;
    }

    // Restore threshold and run GC now that we're in a safe state
    qjs.JS_SetGCThreshold(rt_nonnull, saved_threshold);
}

// atob: ASCII to Binary (Base64 Decode)
pub fn js_atob(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = z.wrapper.Context.from(ctx_ptr);
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

// arrayBufferToBase64DataUri(arrayBuffer, contentType)
// Converts raw ArrayBuffer bytes to a base64-encoded data URI string entirely in Zig.
// Returns: "data:{contentType};base64,{encoded}"
pub fn js_arrayBufferToBase64DataUri(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 2) return ctx.throwTypeError("arrayBufferToBase64DataUri requires 2 arguments");
    const temp_alloc = std.heap.c_allocator;

    // Get raw bytes from ArrayBuffer or TypedArray
    var data_len: usize = 0;
    var data_ptr: ?[*]u8 = null;

    // Try ArrayBuffer first
    data_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &data_len, argv[0]);
    if (data_ptr == null) {
        // Try TypedArray (Uint8Array etc.)
        var byte_offset: usize = 0;
        var byte_len: usize = 0;
        var bytes_per_elem: usize = 0;
        const ab = qjs.JS_GetTypedArrayBuffer(ctx.ptr, argv[0], &byte_offset, &byte_len, &bytes_per_elem);
        if (ctx.isException(ab)) {
            return ctx.throwTypeError("First argument must be an ArrayBuffer or TypedArray");
        }
        defer ctx.freeValue(ab);
        var ab_size: usize = 0;
        data_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &ab_size, ab);
        if (data_ptr) |p| {
            data_ptr = p + byte_offset;
            data_len = byte_len;
        }
    }

    if (data_ptr == null) return ctx.throwTypeError("Could not read ArrayBuffer data");
    const data = data_ptr.?[0..data_len];

    // Get content type string
    const content_type = ctx.toCStringLen(argv[1]) catch return ctx.throwTypeError("Second argument must be a string");
    defer ctx.freeCString(content_type.ptr);

    // Base64 encode
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(data.len);

    // Build: "data:" + contentType + ";base64," + encoded
    const prefix_len = 5; // "data:"
    const mid_len = 8; // ";base64,"
    const total_len = prefix_len + content_type.len + mid_len + b64_len;

    const output = temp_alloc.alloc(u8, total_len) catch return z.jsException;
    defer temp_alloc.free(output);

    // Write prefix
    @memcpy(output[0..5], "data:");
    @memcpy(output[5 .. 5 + content_type.len], content_type);
    @memcpy(output[5 + content_type.len .. 5 + content_type.len + 8], ";base64,");

    // Encode directly into the output buffer
    _ = encoder.encode(output[prefix_len + content_type.len + mid_len ..], data);

    return ctx.newString(output);
}

pub fn install(ctx: w.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    // navigator — headless browser identity (must be set before any scripts run)
    {
        const nav_obj = ctx.newObject();
        try ctx.setPropertyStr(nav_obj, "userAgent", ctx.newString(
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Zexplorer/1.0",
        ));
        try ctx.setPropertyStr(nav_obj, "platform", ctx.newString("Linux x86_64"));
        try ctx.setPropertyStr(nav_obj, "language", ctx.newString("en-US"));
        try ctx.setPropertyStr(nav_obj, "maxTouchPoints", ctx.newInt32(0));
        try ctx.setPropertyStr(nav_obj, "cookieEnabled", w.FALSE);
        try ctx.setPropertyStr(nav_obj, "onLine", w.TRUE);
        try ctx.setPropertyStr(global, "navigator", nav_obj);
    }

    const btoa_fn = ctx.newCFunction(js_btoa, "btoa", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "btoa", btoa_fn);

    const atob_fn = ctx.newCFunction(js_atob, "atob", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "atob", atob_fn);

    // __flush: drain pending microtasks (useful for React 19 async scheduler)
    const flush = ctx.newCFunction(js_flush, "__flush", 0);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "__flush", flush);

    // arrayBufferToBase64DataUri: native base64 data URI encoding
    const ab_to_b64 = ctx.newCFunction(js_arrayBufferToBase64DataUri, "arrayBufferToBase64DataUri", 2);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "arrayBufferToBase64DataUri", ab_to_b64);

    // fetchAll: parallel HTTP fetcher using curl_multi
    const fetch_all_fn = ctx.newCFunction(js_fetch_all.js_fetchAll, "fetchAll", 2);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "fetchAll", fetch_all_fn);
    // All JS polyfills (env, rAF, MessageChannel, etc.) now live in polyfills.js
    // and are loaded as bytecode by ScriptEngine after zexplorer.js.
}

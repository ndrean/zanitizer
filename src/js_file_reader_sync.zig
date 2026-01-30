const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_blob = @import("js_blob.zig");
const js_file = @import("js_file.zig");

// Helper to unwrap Blob OR File
fn getBlobData(ctx: w.Context, val: qjs.JSValue) ?*js_blob.BlobObject {
    const rc = RuntimeContext.get(ctx);

    // 1. Try Blob
    if (qjs.JS_GetOpaque(val, rc.classes.blob)) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }
    // 2. Try File
    if (qjs.JS_GetOpaque(val, rc.classes.file)) |ptr| {
        const file: *js_file.FileObject = @ptrCast(@alignCast(ptr));
        return &file.blob;
    }
    return null;
}

fn js_reader_readAsArrayBuffer(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("Argument required");

    const blob = getBlobData(ctx, argv[0]) orelse return ctx.throwTypeError("Argument must be Blob or File");

    // Return ArrayBuffer copy
    return qjs.JS_NewArrayBufferCopy(ctx.ptr, blob.data.ptr, blob.data.len);
}

fn js_reader_readAsText(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("Argument required");

    const blob = getBlobData(ctx, argv[0]) orelse return ctx.throwTypeError("Argument must be Blob or File");

    // We assume UTF-8. The spec allows an 'encoding' arg, but modern usage is almost always UTF-8.
    return qjs.JS_NewStringLen(ctx.ptr, blob.data.ptr, blob.data.len);
}

fn js_reader_readAsDataURL(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return ctx.throwTypeError("Argument required");

    const blob = getBlobData(ctx, argv[0]) orelse return ctx.throwTypeError("Argument must be Blob or File");

    // Format: data:[<mediatype>][;base64],<data>
    const mime = if (blob.mime_type.len > 0) blob.mime_type else "application/octet-stream";

    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(blob.data.len);
    // "data:" + mime + ";base64," + b64_len
    const total_len = 5 + mime.len + 8 + b64_len;

    const output = rc.allocator.alloc(u8, total_len) catch return ctx.throwOutOfMemory();
    defer rc.allocator.free(output);

    // Build string
    var fbs = std.io.fixedBufferStream(output);
    const writer = fbs.writer();

    writer.print("data:{s};base64,", .{mime}) catch return z.jsException;
    _ = encoder.encode(output[fbs.pos..], blob.data);

    return qjs.JS_NewStringLen(ctx.ptr, output.ptr, output.len);
}

// Stateless constructor (no arguments)
fn js_reader_constructor(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    // Create empty object linked to prototype (no opaque data needed for ReaderSync)
    const proto = ctx.getClassProto(rc.classes.reader_sync);
    defer ctx.freeValue(proto);
    return ctx.newObjectProtoClass(proto, rc.classes.reader_sync);
}

pub fn install(ctx: w.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    if (rc.classes.reader_sync == 0) {
        rc.classes.reader_sync = rt.newClassID();
        // No finalizer needed (stateless object)
        try rt.newClass(rc.classes.reader_sync, .{ .class_name = "FileReaderSync" });
    }

    const proto = ctx.newObject();

    try ctx.setPropertyStr(proto, "readAsArrayBuffer", ctx.newCFunction(js_reader_readAsArrayBuffer, "readAsArrayBuffer", 1));
    try ctx.setPropertyStr(proto, "readAsText", ctx.newCFunction(js_reader_readAsText, "readAsText", 1));
    try ctx.setPropertyStr(proto, "readAsDataURL", ctx.newCFunction(js_reader_readAsDataURL, "readAsDataURL", 1));

    const ctor = ctx.newCFunction2(js_reader_constructor, "FileReaderSync", 0, qjs.JS_CFUNC_constructor, 0);
    _ = ctx.setConstructor(ctor, proto);
    _ = qjs.JS_SetClassProto(ctx.ptr, rc.classes.reader_sync, proto);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "FileReaderSync", ctor);
}

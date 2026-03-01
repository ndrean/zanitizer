const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = z.RuntimeContext;
const js_blob = z.js_blob;
const js_file = z.js_File;

// Shared Enum (matching your Async Reader)
const ReadType = enum { ArrayBuffer, Text, DataURL };

// ============================================================================
// SYNC READ LOGIC (Main Thread)
// ============================================================================

fn readSync(ctx: zqjs.Context, blob_val: qjs.JSValue, read_type: ReadType) qjs.JSValue {
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.loop.allocator;

    // 1. Extract Blob/File Data
    var raw_bytes: []u8 = &.{};
    var mime_type: []const u8 = "application/octet-stream";
    var needs_free = false;

    if (qjs.JS_GetOpaque(blob_val, rc.classes.file)) |ptr| {
        const file: *js_file.FileObject = @ptrCast(@alignCast(ptr));
        if (file.path) |path| {
            // Read from Disk (Blocking)
            const f = std.fs.cwd().openFile(path, .{}) catch return ctx.throwTypeError("Could not open file");
            defer f.close();
            // Safety limit: 100MB (Sync reads block the event loop!)
            raw_bytes = f.readToEndAlloc(allocator, 100 * 1024 * 1024) catch return ctx.throwOutOfMemory();
            needs_free = true;
        } else {
            raw_bytes = file.blob.data;
        }
        if (file.blob.mime_type.len > 0) mime_type = file.blob.mime_type;
    } else if (qjs.JS_GetOpaque(blob_val, rc.classes.blob)) |ptr| {
        const blob: *js_blob.BlobObject = @ptrCast(@alignCast(ptr));
        raw_bytes = blob.data;
        if (blob.mime_type.len > 0) mime_type = blob.mime_type;
    } else {
        return ctx.throwTypeError("Argument must be a Blob or File");
    }
    defer if (needs_free) allocator.free(raw_bytes);

    // 2. Process & Return
    switch (read_type) {
        .ArrayBuffer => {
            return ctx.newArrayBufferCopy(raw_bytes);
        },
        .Text => {
            return ctx.newString(raw_bytes);
        },
        .DataURL => {
            // Encode Base64
            const encoder = std.base64.standard.Encoder;
            const b64_len = encoder.calcSize(raw_bytes.len);

            const prefix = "data:";
            const mid = ";base64,";
            const total_len = prefix.len + mime_type.len + mid.len + b64_len;

            const out_buf = allocator.alloc(u8, total_len) catch return ctx.throwOutOfMemory();
            defer allocator.free(out_buf);

            // Assemble Data URL
            @memcpy(out_buf[0..prefix.len], prefix);
            var pos = prefix.len;
            @memcpy(out_buf[pos .. pos + mime_type.len], mime_type);
            pos += mime_type.len;
            @memcpy(out_buf[pos .. pos + mid.len], mid);
            pos += mid.len;
            _ = encoder.encode(out_buf[pos..], raw_bytes);

            return ctx.newString(out_buf);
        },
    }
}

// ============================================================================
// JS BINDINGS
// ============================================================================

fn js_FileReaderSync_readAsArrayBuffer(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    return readSync(ctx, argv[0], .ArrayBuffer);
}

fn js_FileReaderSync_readAsText(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    return readSync(ctx, argv[0], .Text);
}

fn js_FileReaderSync_readAsDataURL(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    return readSync(ctx, argv[0], .DataURL);
}

fn js_FileReaderSync_constructor(ctx_ptr: ?*qjs.JSContext, new_target: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const proto = ctx.getPropertyStr(new_target, "prototype");
    const obj = qjs.JS_NewObjectProto(ctx.ptr, proto);
    ctx.freeValue(proto);
    return obj;
}

pub const FileReaderSyncBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const proto = ctx.newObject();
        defer ctx.freeValue(proto);

        try ctx.setPropertyStr(proto, "readAsArrayBuffer", ctx.newCFunction(js_FileReaderSync_readAsArrayBuffer, "readAsArrayBuffer", 1));
        try ctx.setPropertyStr(proto, "readAsText", ctx.newCFunction(js_FileReaderSync_readAsText, "readAsText", 1));
        try ctx.setPropertyStr(proto, "readAsDataURL", ctx.newCFunction(js_FileReaderSync_readAsDataURL, "readAsDataURL", 1));

        const ctor = ctx.newCFunction2(js_FileReaderSync_constructor, "FileReaderSync", 0, qjs.JS_CFUNC_constructor, 0);
        try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
        try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor));

        try ctx.setPropertyStr(global, "FileReaderSync", ctor);
    }
};

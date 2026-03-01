//! js_file_reader.zig
const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = z.RuntimeContext;
const EventLoop = z.EventLoop;
const js_blob = z.js_blob;
const js_file = z.js_File;

// States
const EMPTY = 0;
const LOADING = 1;
const DONE = 2;

const ReadType = enum { ArrayBuffer, Text, DataURL };

const ReaderTask = struct {
    allocator: std.mem.Allocator,
    loop: *EventLoop,
    blob_data: ?[]u8 = null,
    file_path: ?[]u8 = null,
    mime_type: []u8,
    read_type: ReadType,
    ctx: zqjs.Context,
    reader_obj: qjs.JSValue,
};

const ReaderResult = struct {
    data: []u8,
    read_type: ReadType,
};

const ReaderCallbackCtx = struct {
    reader: qjs.JSValue,
    result: *ReaderResult,
};

// ============================================================================
// WORKER (Background Thread)
// ============================================================================

fn workReadAndCallback(task: ReaderTask) void {
    const allocator = task.loop.allocator;
    var result_data: []u8 = &.{};
    var success = true;

    // 1. Get Raw Data
    var raw_bytes: []u8 = &.{};
    var needs_free = false;

    if (task.file_path) |path| {
        if (std.fs.cwd().openFile(path, .{})) |file| {
            defer file.close();
            if (file.readToEndAlloc(allocator, 100 * 1024 * 1024)) |bytes| {
                raw_bytes = bytes;
                needs_free = true;
            } else |_| {
                success = false;
            }
        } else |_| {
            success = false;
        }
    } else if (task.blob_data) |data| {
        if (allocator.dupe(u8, data)) |bytes| {
            raw_bytes = bytes;
            needs_free = true;
        } else |_| {
            success = false;
        }
    } else {
        success = false;
    }

    // 2. Process Data
    if (success) {
        switch (task.read_type) {
            .ArrayBuffer, .Text => {
                result_data = raw_bytes;
                needs_free = false;
            },
            .DataURL => {
                const encoder = std.base64.standard.Encoder;
                const b64_len = encoder.calcSize(raw_bytes.len);
                const prefix = "data:";
                const mid = ";base64,";
                const mime = if (task.mime_type.len > 0) task.mime_type else "application/octet-stream";
                const total_len = prefix.len + mime.len + mid.len + b64_len;

                if (allocator.alloc(u8, total_len)) |buf| {
                    result_data = buf;
                    @memcpy(buf[0..prefix.len], prefix);
                    var pos = prefix.len;
                    @memcpy(buf[pos .. pos + mime.len], mime);
                    pos += mime.len;
                    @memcpy(buf[pos .. pos + mid.len], mid);
                    pos += mid.len;
                    _ = encoder.encode(buf[pos..], raw_bytes);
                } else |_| {
                    success = false;
                }

                if (needs_free) allocator.free(raw_bytes);
            },
        }
    }

    // Cleanup inputs
    if (task.file_path) |p| allocator.free(p);
    if (task.blob_data) |d| allocator.free(d);
    allocator.free(task.mime_type);

    // 3. Enqueue Callback (pending_background_jobs decremented centrally in enqueueTask)
    if (success) {
        const res = allocator.create(ReaderResult) catch return;
        res.* = .{ .data = result_data, .read_type = task.read_type };

        const cb_ctx = allocator.create(ReaderCallbackCtx) catch return;
        cb_ctx.* = .{ .reader = task.reader_obj, .result = res };

        task.loop.enqueueTask(.{
            .ctx = task.ctx,
            .resolve = zqjs.UNDEFINED,
            .reject = zqjs.UNDEFINED,
            .result = .{
                .custom = .{
                    .data = cb_ctx,
                    .callback = finishReadSuccess_Safe,
                    // We handle destruction manually in the callback, so we pass a no-op here
                    .destroy = noopDestroy,
                },
            },
        });
    } else {
        const cb_ctx = allocator.create(ReaderCallbackCtx) catch return;
        cb_ctx.* = .{ .reader = task.reader_obj, .result = undefined };

        task.loop.enqueueTask(.{
            .ctx = task.ctx,
            .resolve = zqjs.UNDEFINED,
            .reject = zqjs.UNDEFINED,
            .result = .{ .custom = .{
                .data = cb_ctx,
                .callback = finishReadFailure_Safe,
                .destroy = noopDestroy,
            } },
        });
    }
}

// ============================================================================
// MAIN THREAD CALLBACKS
// ============================================================================

fn finishReadSuccess_Safe(ctx: zqjs.Context, ptr: *anyopaque) void {
    const rc = RuntimeContext.get(ctx);
    const wrapper: *ReaderCallbackCtx = @ptrCast(@alignCast(ptr));
    const reader = wrapper.reader;
    const res = wrapper.result;

    // 1. State -> DONE
    ctx.setPropertyStr(reader, "readyState", ctx.newInt32(DONE)) catch {};

    // 2. Set Result
    var result_val: qjs.JSValue = zqjs.UNDEFINED;
    switch (res.read_type) {
        .ArrayBuffer => {
            result_val = ctx.newArrayBufferCopy(res.data);
        },
        .Text, .DataURL => {
            // [FIX] Use newString (wrapper handles slice)
            result_val = ctx.newString(res.data);
        },
    }

    // setPropertyStr takes ownership of result_val
    ctx.setPropertyStr(reader, "result", result_val) catch {};

    // 3. Fire events
    fireEvent(ctx, reader, "onload");
    fireEvent(ctx, reader, "onloadend");

    // 4. CLEANUP (Fixes Memory Leaks)
    ctx.freeValue(reader); // Free the JS Handle duped in main thread
    rc.loop.allocator.free(res.data); // Free the data buffer (Base64 string / bytes)
    rc.loop.allocator.destroy(res); // Free the Result struct
    rc.loop.allocator.destroy(wrapper); // Free the Callback Context wrapper
}

fn finishReadFailure_Safe(ctx: zqjs.Context, ptr: *anyopaque) void {
    const rc = RuntimeContext.get(ctx);
    const wrapper: *ReaderCallbackCtx = @ptrCast(@alignCast(ptr));
    const reader = wrapper.reader;

    ctx.setPropertyStr(reader, "readyState", ctx.newInt32(DONE)) catch {};

    // Create Error Object
    const err = ctx.throwTypeError("Failed to read file");
    ctx.setPropertyStr(reader, "error", err) catch {};

    fireEvent(ctx, reader, "onerror");
    fireEvent(ctx, reader, "onloadend");

    // 4. CLEANUP (Fixes Memory Leaks)
    ctx.freeValue(reader);
    // In failure case, wrapper.result was undefined, so we ONLY destroy the wrapper
    rc.loop.allocator.destroy(wrapper);
}

// [FIX] A valid function pointer that does nothing, to satisfy the EventLoop struct requirements
fn noopDestroy(_: std.mem.Allocator, _: *anyopaque) void {}

fn fireEvent(ctx: zqjs.Context, reader: qjs.JSValue, event_name: [:0]const u8) void {
    const handler = ctx.getPropertyStr(reader, event_name);
    defer ctx.freeValue(handler);
    if (ctx.isFunction(handler)) {
        _ = ctx.call(handler, reader, &.{});
    }
}

// ============================================================================
// JS BINDINGS
// ============================================================================

fn js_FileReader_constructor(ctx_ptr: ?*qjs.JSContext, new_target: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const proto = ctx.getPropertyStr(new_target, "prototype");
    const obj = qjs.JS_NewObjectProto(ctx.ptr, proto);
    ctx.freeValue(proto);

    ctx.setPropertyStr(obj, "readyState", ctx.newInt32(EMPTY)) catch {};
    ctx.setPropertyStr(obj, "result", zqjs.NULL) catch {};

    return obj;
}

fn js_read_common(ctx: zqjs.Context, this: qjs.JSValue, blob_val: qjs.JSValue, read_type: ReadType) qjs.JSValue {
    const rc = RuntimeContext.get(ctx);

    ctx.setPropertyStr(this, "readyState", ctx.newInt32(LOADING)) catch {};
    ctx.setPropertyStr(this, "result", zqjs.NULL) catch {};

    var path_dupe: ?[]u8 = null;
    var data_dupe: ?[]u8 = null;
    var mime_dupe: []u8 = undefined;

    if (qjs.JS_GetOpaque(blob_val, rc.classes.file)) |ptr| {
        const file: *js_file.FileObject = @ptrCast(@alignCast(ptr));
        if (file.path) |p| {
            path_dupe = rc.loop.allocator.dupe(u8, p) catch return ctx.throwOutOfMemory();
        } else {
            data_dupe = rc.loop.allocator.dupe(u8, file.blob.data) catch return ctx.throwOutOfMemory();
        }
        mime_dupe = rc.loop.allocator.dupe(u8, file.blob.mime_type) catch return ctx.throwOutOfMemory();
    } else if (qjs.JS_GetOpaque(blob_val, rc.classes.blob)) |ptr| {
        const blob: *js_blob.BlobObject = @ptrCast(@alignCast(ptr));
        data_dupe = rc.loop.allocator.dupe(u8, blob.data) catch return ctx.throwOutOfMemory();
        mime_dupe = rc.loop.allocator.dupe(u8, blob.mime_type) catch return ctx.throwOutOfMemory();
    } else {
        return ctx.throwTypeError("Argument must be a Blob or File");
    }

    fireEvent(ctx, this, "loadstart");

    const task = ReaderTask{
        .allocator = rc.loop.allocator,
        .loop = rc.loop,
        .blob_data = data_dupe,
        .file_path = path_dupe,
        .mime_type = mime_dupe,
        .read_type = read_type,
        .ctx = ctx,
        .reader_obj = ctx.dupValue(this),
    };

    rc.loop.spawnWorker(workReadAndCallback, task) catch return ctx.throwInternalError("Failed to spawn reader");

    return zqjs.UNDEFINED;
}

fn js_FileReader_readAsText(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    return js_read_common(ctx, this, argv[0], .Text);
}
fn js_FileReader_readAsArrayBuffer(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    return js_read_common(ctx, this, argv[0], .ArrayBuffer);
}
fn js_FileReader_readAsDataURL(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    return js_read_common(ctx, this, argv[0], .DataURL);
}

pub const FileReaderBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const proto = ctx.newObject();
        defer ctx.freeValue(proto);

        // Constants
        try ctx.setPropertyStr(proto, "EMPTY", ctx.newInt32(EMPTY));
        try ctx.setPropertyStr(proto, "LOADING", ctx.newInt32(LOADING));
        try ctx.setPropertyStr(proto, "DONE", ctx.newInt32(DONE));

        // Methods
        try ctx.setPropertyStr(proto, "readAsText", ctx.newCFunction(js_FileReader_readAsText, "readAsText", 1));
        try ctx.setPropertyStr(proto, "readAsArrayBuffer", ctx.newCFunction(js_FileReader_readAsArrayBuffer, "readAsArrayBuffer", 1));
        try ctx.setPropertyStr(proto, "readAsDataURL", ctx.newCFunction(js_FileReader_readAsDataURL, "readAsDataURL", 1));

        const ctor = ctx.newCFunction2(js_FileReader_constructor, "FileReader", 0, qjs.JS_CFUNC_constructor, 0);
        try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
        try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor));

        // Static Constants
        try ctx.setPropertyStr(ctor, "EMPTY", ctx.newInt32(EMPTY));
        try ctx.setPropertyStr(ctor, "LOADING", ctx.newInt32(LOADING));
        try ctx.setPropertyStr(ctor, "DONE", ctx.newInt32(DONE));

        try ctx.setPropertyStr(global, "FileReader", ctor);
    }
};

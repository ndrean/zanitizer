//! ReadableStream Web API implementation
//!
//! Supports in-memory Buffers AND Files (Async/Threaded).
//!
//! Usage:
//!   const reader = response.body.getReader();
//!   while (true) {
//!     const {value, done} = await reader.read();
//!     if (done) break;
//!     // process value (Uint8Array chunk)
//!   }

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const EL = @import("event_loop.zig");
const EventLoop = EL.EventLoop;

// ============================================================================
// STRUCTS
// ============================================================================

pub const StreamType = enum {
    Buffer,
    File,
};

pub const StreamState = enum {
    readable,
    closed,
    errored,
};

pub const ReadableStreamObject = struct {
    allocator: std.mem.Allocator,
    state: StreamState,
    stream_type: StreamType,

    // Buffer Mode
    data: []const u8,

    // File Mode
    file: std.fs.File,
    file_size: u64,

    // Common
    position: u64,
    chunk_size: usize,
    locked: bool,
    error_msg: ?[]const u8,

    pub fn initBuffer(allocator: std.mem.Allocator, data: []const u8) !*ReadableStreamObject {
        const self = try allocator.create(ReadableStreamObject);
        self.* = .{
            .allocator = allocator,
            .state = .readable,
            .stream_type = .Buffer,
            .data = data,
            .file = undefined,
            .file_size = 0,
            .position = 0,
            .chunk_size = 64 * 1024,
            .locked = false,
            .error_msg = null,
        };
        return self;
    }

    pub fn initFile(allocator: std.mem.Allocator, path: []const u8) !*ReadableStreamObject {
        // Open file (Blocking open is usually fine)
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        const stat = try file.stat();

        const self = try allocator.create(ReadableStreamObject);
        self.* = .{
            .allocator = allocator,
            .state = .readable,
            .stream_type = .File,
            .data = &.{},
            .file = file,
            .file_size = stat.size,
            .position = 0,
            .chunk_size = 64 * 1024, // 64KB chunks
            .locked = false,
            .error_msg = null,
        };
        return self;
    }

    pub fn deinit(self: *ReadableStreamObject) void {
        if (self.stream_type == .File) {
            self.file.close();
        }
        self.allocator.destroy(self);
    }
};

pub const ReaderObject = struct {
    allocator: std.mem.Allocator,
    stream: *ReadableStreamObject,

    // Pending Promise Resolvers (for Async File Reads)
    pending_resolve: zqjs.Value = zqjs.UNDEFINED,
    pending_reject: zqjs.Value = zqjs.UNDEFINED,

    pub fn init(allocator: std.mem.Allocator, stream: *ReadableStreamObject) !*ReaderObject {
        const self = try allocator.create(ReaderObject);
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .pending_resolve = zqjs.UNDEFINED,
            .pending_reject = zqjs.UNDEFINED,
        };
        stream.locked = true;
        return self;
    }

    pub fn deinit(self: *ReaderObject) void {
        self.stream.locked = false;
        self.allocator.destroy(self);
    }
};

// ============================================================================
// ASYNC FILE WORKER
// ============================================================================

const FileReadTask = struct {
    loop: *EventLoop,
    file: std.fs.File,
    offset: u64,
    size: usize,
    reader_ptr: *ReaderObject,
    ctx: zqjs.Context,
};

const FileReadResult = struct {
    buffer: []u8,
    reader: *ReaderObject,
    bytes_read: usize,
    is_error: bool,
};

fn workReadFileChunk(task: FileReadTask) void {
    const allocator = task.loop.allocator;

    // 1. Allocate buffer
    const buffer = allocator.alloc(u8, task.size) catch {
        // Enqueue error result
        const res = allocator.create(FileReadResult) catch return;
        res.* = .{ .buffer = &.{}, .reader = task.reader_ptr, .bytes_read = 0, .is_error = true };
        task.loop.enqueueTask(.{
            .ctx = task.ctx,
            .resolve = zqjs.UNDEFINED,
            .reject = zqjs.UNDEFINED,
            .result = .{ .custom = .{
                .data = res,
                .callback = finishFileRead,
                .destroy = destroyFileReadResult,
            } },
        });
        return;
    };

    // 2. Seek and Read
    task.file.seekTo(task.offset) catch {
        allocator.free(buffer);
        const res = allocator.create(FileReadResult) catch return;
        res.* = .{ .buffer = &.{}, .reader = task.reader_ptr, .bytes_read = 0, .is_error = true };
        task.loop.enqueueTask(.{
            .ctx = task.ctx,
            .resolve = zqjs.UNDEFINED,
            .reject = zqjs.UNDEFINED,
            .result = .{ .custom = .{
                .data = res,
                .callback = finishFileRead,
                .destroy = destroyFileReadResult,
            } },
        });
        return;
    };

    const bytes = task.file.read(buffer) catch {
        allocator.free(buffer);
        const res = allocator.create(FileReadResult) catch return;
        res.* = .{ .buffer = &.{}, .reader = task.reader_ptr, .bytes_read = 0, .is_error = true };
        task.loop.enqueueTask(.{
            .ctx = task.ctx,
            .resolve = zqjs.UNDEFINED,
            .reject = zqjs.UNDEFINED,
            .result = .{ .custom = .{
                .data = res,
                .callback = finishFileRead,
                .destroy = destroyFileReadResult,
            } },
        });
        return;
    };

    // 3. Prepare Result
    const res = allocator.create(FileReadResult) catch {
        allocator.free(buffer);
        return;
    };
    res.* = .{
        .buffer = buffer,
        .reader = task.reader_ptr,
        .bytes_read = bytes,
        .is_error = false,
    };

    // 4. Send back to Event Loop
    task.loop.enqueueTask(.{
        .ctx = task.ctx,
        .resolve = zqjs.UNDEFINED,
        .reject = zqjs.UNDEFINED,
        .result = .{ .custom = .{
            .data = res,
            .callback = finishFileRead,
            .destroy = destroyFileReadResult,
        } },
    });
}

fn destroyFileReadResult(allocator: std.mem.Allocator, data: *anyopaque) void {
    const res: *FileReadResult = @ptrCast(@alignCast(data));
    if (res.buffer.len > 0) allocator.free(res.buffer);
    allocator.destroy(res);
}

fn finishFileRead(ctx: zqjs.Context, data: *anyopaque) void {
    const res: *FileReadResult = @ptrCast(@alignCast(data));
    const reader = res.reader;
    const bytes = res.bytes_read;
    const allocator = reader.allocator;

    // Advance position
    reader.stream.position += bytes;

    const result_obj = ctx.newObject();

    if (res.is_error) {
        // Reject the promise
        const err_str = ctx.newString("File read error");
        var args = [1]qjs.JSValue{err_str};
        const ret = qjs.JS_Call(ctx.ptr, reader.pending_reject, zqjs.UNDEFINED, 1, &args);
        ctx.freeValue(ret);
        ctx.freeValue(err_str);
        ctx.freeValue(result_obj);
    } else if (bytes > 0) {
        // Create Uint8Array
        const js_ab = qjs.JS_NewArrayBufferCopy(ctx.ptr, res.buffer.ptr, bytes);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        const uint8_ctor = ctx.getPropertyStr(global, "Uint8Array");
        defer ctx.freeValue(uint8_ctor);

        var ctor_args = [_]qjs.JSValue{js_ab};
        const view = qjs.JS_CallConstructor(ctx.ptr, uint8_ctor, 1, &ctor_args);
        ctx.freeValue(js_ab);

        ctx.setPropertyStr(result_obj, "value", view) catch {};
        ctx.setPropertyStr(result_obj, "done", ctx.newBool(false)) catch {};

        // Resolve Promise
        var args = [1]qjs.JSValue{result_obj};
        const ret = qjs.JS_Call(ctx.ptr, reader.pending_resolve, zqjs.UNDEFINED, 1, &args);
        ctx.freeValue(ret);
    } else {
        // EOF
        reader.stream.state = .closed;
        ctx.setPropertyStr(result_obj, "value", zqjs.UNDEFINED) catch {};
        ctx.setPropertyStr(result_obj, "done", ctx.newBool(true)) catch {};

        // Resolve Promise
        var args = [1]qjs.JSValue{result_obj};
        const ret = qjs.JS_Call(ctx.ptr, reader.pending_resolve, zqjs.UNDEFINED, 1, &args);
        ctx.freeValue(ret);
    }

    ctx.freeValue(result_obj);

    // Cleanup JS Refs
    ctx.freeValue(reader.pending_resolve);
    ctx.freeValue(reader.pending_reject);
    reader.pending_resolve = zqjs.UNDEFINED;
    reader.pending_reject = zqjs.UNDEFINED;

    // Free buffer
    if (res.buffer.len > 0) allocator.free(res.buffer);
    allocator.destroy(res);
}

// =============================================================
// JS Callbacks - ReadableStream

fn js_ReadableStream_finalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    _ = rt;
    const ptr = qjs.JS_GetOpaque(val, getStreamClassId());
    if (ptr) |p| {
        const stream: *ReadableStreamObject = @ptrCast(@alignCast(p));
        stream.deinit();
    }
}

fn js_ReadableStream_getReader(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    // Get stream from this
    const stream = ctx.getOpaqueAs(ReadableStreamObject, this, rc.classes.readable_stream) orelse {
        return ctx.throwTypeError("Invalid ReadableStream");
    };

    if (stream.locked) {
        return ctx.throwTypeError("ReadableStream is locked");
    }

    // Create reader
    const reader = ReaderObject.init(rc.allocator, stream) catch {
        return ctx.throwOutOfMemory();
    };

    // Create JS reader object
    const reader_obj = ctx.newObjectClass(rc.classes.readable_stream_reader);
    ctx.setOpaque(reader_obj, reader) catch {
        reader.deinit();
        return ctx.throwOutOfMemory();
    };

    return reader_obj;
}

fn js_ReadableStream_get_locked(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const stream_ptr = qjs.JS_GetOpaque(this, rc.classes.readable_stream);
    if (stream_ptr == null) return ctx.newBool(false);

    const stream: *ReadableStreamObject = @ptrCast(@alignCast(stream_ptr));
    return ctx.newBool(stream.locked);
}

fn js_ReadableStream_cancel(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const stream_ptr = qjs.JS_GetOpaque(this, rc.classes.readable_stream);
    if (stream_ptr) |p| {
        const stream: *ReadableStreamObject = @ptrCast(@alignCast(p));
        stream.state = .closed;
    }

    // Return resolved promise with undefined
    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

// =============================================================
// JS Callbacks - Reader

fn js_Reader_finalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    _ = rt;
    const ptr = qjs.JS_GetOpaque(val, getReaderClassId());
    if (ptr) |p| {
        const reader: *ReaderObject = @ptrCast(@alignCast(p));
        reader.deinit();
    }
}

fn js_Reader_read(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const reader_ptr = qjs.JS_GetOpaque(this, rc.classes.readable_stream_reader);
    if (reader_ptr == null) {
        return ctx.throwTypeError("Invalid reader");
    }
    const reader: *ReaderObject = @ptrCast(@alignCast(reader_ptr));
    const stream = reader.stream;

    // Already closed?
    if (stream.state == .closed) {
        const res = ctx.newObject();
        ctx.setPropertyStr(res, "value", zqjs.UNDEFINED) catch {};
        ctx.setPropertyStr(res, "done", ctx.newBool(true)) catch {};
        return createResolvedPromise(ctx, res);
    }

    // Create Promise
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return promise;

    // --- CASE 1: BUFFER (SYNC) ---
    if (stream.stream_type == .Buffer) {
        const pos: usize = @intCast(stream.position);
        const end = @min(pos + stream.chunk_size, stream.data.len);
        const chunk = stream.data[pos..end];
        stream.position = end;

        const result_obj = ctx.newObject();
        if (chunk.len > 0) {
            // Create Uint8Array from chunk
            const array_buffer = qjs.JS_NewArrayBufferCopy(ctx.ptr, chunk.ptr, chunk.len);
            if (qjs.JS_IsException(array_buffer)) {
                ctx.freeValue(result_obj);
                ctx.freeValue(resolvers[0]);
                ctx.freeValue(resolvers[1]);
                return zqjs.EXCEPTION;
            }

            const global = ctx.getGlobalObject();
            defer ctx.freeValue(global);
            const uint8_ctor = ctx.getPropertyStr(global, "Uint8Array");
            defer ctx.freeValue(uint8_ctor);

            var args = [_]qjs.JSValue{array_buffer};
            const uint8_array = qjs.JS_CallConstructor(ctx.ptr, uint8_ctor, 1, &args);
            ctx.freeValue(array_buffer);

            if (qjs.JS_IsException(uint8_array)) {
                ctx.freeValue(result_obj);
                ctx.freeValue(resolvers[0]);
                ctx.freeValue(resolvers[1]);
                return zqjs.EXCEPTION;
            }

            ctx.setPropertyStr(result_obj, "value", uint8_array) catch {};
            ctx.setPropertyStr(result_obj, "done", ctx.newBool(false)) catch {};
        } else {
            stream.state = .closed;
            ctx.setPropertyStr(result_obj, "value", zqjs.UNDEFINED) catch {};
            ctx.setPropertyStr(result_obj, "done", ctx.newBool(true)) catch {};
        }

        // Resolve immediately
        var args = [1]qjs.JSValue{result_obj};
        const ret = qjs.JS_Call(ctx.ptr, resolvers[0], zqjs.UNDEFINED, 1, &args);
        ctx.freeValue(ret);
        ctx.freeValue(result_obj);
        ctx.freeValue(resolvers[0]);
        ctx.freeValue(resolvers[1]);
        return promise;
    }

    // --- CASE 2: FILE (ASYNC) ---
    if (stream.stream_type == .File) {
        // Save resolvers for the worker callback
        reader.pending_resolve = resolvers[0];
        reader.pending_reject = resolvers[1];

        const task = FileReadTask{
            .loop = rc.loop,
            .file = stream.file,
            .offset = stream.position,
            .size = stream.chunk_size,
            .reader_ptr = reader,
            .ctx = ctx,
        };

        rc.loop.spawnWorker(workReadFileChunk, task) catch {
            ctx.freeValue(resolvers[0]);
            ctx.freeValue(resolvers[1]);
            ctx.freeValue(promise);
            return ctx.throwInternalError("Failed to spawn read worker");
        };

        return promise;
    }

    return zqjs.UNDEFINED;
}

fn js_Reader_releaseLock(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const reader_ptr = qjs.JS_GetOpaque(this, rc.classes.readable_stream_reader);
    if (reader_ptr) |p| {
        const reader: *ReaderObject = @ptrCast(@alignCast(p));
        reader.stream.locked = false;
    }

    return zqjs.UNDEFINED;
}

fn js_Reader_cancel(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const reader_ptr = qjs.JS_GetOpaque(this, rc.classes.readable_stream_reader);
    if (reader_ptr) |p| {
        const reader: *ReaderObject = @ptrCast(@alignCast(p));
        reader.stream.state = .closed;
        reader.stream.locked = false;
    }

    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

fn js_Reader_get_closed(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const reader_ptr = qjs.JS_GetOpaque(this, rc.classes.readable_stream_reader);
    if (reader_ptr == null) {
        return createRejectedPromise(ctx, "Invalid reader");
    }
    const reader: *ReaderObject = @ptrCast(@alignCast(reader_ptr));

    if (reader.stream.state == .closed) {
        return createResolvedPromise(ctx, zqjs.UNDEFINED);
    } else if (reader.stream.state == .errored) {
        return createRejectedPromise(ctx, reader.stream.error_msg orelse "Stream error");
    }

    // For simplicity, return resolved promise (real impl would track pending)
    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

// =============================================================
// Promise Helpers

fn createResolvedPromise(ctx: zqjs.Context, value: qjs.JSValue) qjs.JSValue {
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return promise;

    var args = [1]qjs.JSValue{value};
    const ret = qjs.JS_Call(ctx.ptr, resolvers[0], zqjs.UNDEFINED, 1, &args);
    ctx.freeValue(ret);
    ctx.freeValue(value);
    ctx.freeValue(resolvers[0]);
    ctx.freeValue(resolvers[1]);

    return promise;
}

fn createRejectedPromise(ctx: zqjs.Context, msg: []const u8) qjs.JSValue {
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return promise;

    const err = ctx.newString(msg);
    var args = [1]qjs.JSValue{err};
    const ret = qjs.JS_Call(ctx.ptr, resolvers[1], zqjs.UNDEFINED, 1, &args);
    ctx.freeValue(ret);
    ctx.freeValue(err);
    ctx.freeValue(resolvers[0]);
    ctx.freeValue(resolvers[1]);

    return promise;
}

// =========================================================
// Class ID helpers for finalizers which don't have RuntimeContext

var g_stream_class_id: qjs.JSClassID = 0;
var g_reader_class_id: qjs.JSClassID = 0;

fn getStreamClassId() qjs.JSClassID {
    return g_stream_class_id;
}

fn getReaderClassId() qjs.JSClassID {
    return g_reader_class_id;
}

// ============================================================================
// Installation
// ============================================================================

pub fn install(ctx: zqjs.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    // ReadableStream class
    if (rc.classes.readable_stream == 0) {
        rc.classes.readable_stream = rt.newClassID();
        g_stream_class_id = rc.classes.readable_stream;
        try rt.newClass(rc.classes.readable_stream, .{
            .class_name = "ReadableStream",
            .finalizer = js_ReadableStream_finalizer,
        });
    }

    const stream_proto = ctx.newObject();
    _ = qjs.JS_SetPropertyStr(ctx.ptr, stream_proto, "getReader", qjs.JS_NewCFunction(ctx.ptr, js_ReadableStream_getReader, "getReader", 0));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, stream_proto, "cancel", qjs.JS_NewCFunction(ctx.ptr, js_ReadableStream_cancel, "cancel", 0));

    // locked getter
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "locked");
        const get = qjs.JS_NewCFunction2(ctx.ptr, js_ReadableStream_get_locked, "get_locked", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, stream_proto, atom, get, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }

    ctx.setClassProto(rc.classes.readable_stream, stream_proto);

    // ReadableStreamDefaultReader class
    if (rc.classes.readable_stream_reader == 0) {
        rc.classes.readable_stream_reader = rt.newClassID();
        g_reader_class_id = rc.classes.readable_stream_reader;
        try rt.newClass(rc.classes.readable_stream_reader, .{
            .class_name = "ReadableStreamDefaultReader",
            .finalizer = js_Reader_finalizer,
        });
    }

    const reader_proto = ctx.newObject();
    _ = qjs.JS_SetPropertyStr(ctx.ptr, reader_proto, "read", qjs.JS_NewCFunction(ctx.ptr, js_Reader_read, "read", 0));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, reader_proto, "releaseLock", qjs.JS_NewCFunction(ctx.ptr, js_Reader_releaseLock, "releaseLock", 0));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, reader_proto, "cancel", qjs.JS_NewCFunction(ctx.ptr, js_Reader_cancel, "cancel", 0));

    // closed getter
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "closed");
        const get = qjs.JS_NewCFunction2(ctx.ptr, js_Reader_get_closed, "get_closed", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, reader_proto, atom, get, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }

    ctx.setClassProto(rc.classes.readable_stream_reader, reader_proto);
}

/// Create a ReadableStream JS object from data buffer
/// The data pointer must remain valid for the lifetime of the stream
pub fn createStreamFromBuffer(ctx: zqjs.Context, data: []const u8) !qjs.JSValue {
    const rc = RuntimeContext.get(ctx);

    const stream = try ReadableStreamObject.initBuffer(rc.allocator, data);
    errdefer stream.deinit();

    const js_stream = ctx.newObjectClass(rc.classes.readable_stream);
    try ctx.setOpaque(js_stream, stream);

    return js_stream;
}

/// Create a ReadableStream JS object from file path (async reads via worker threads)
pub fn createStreamFromFile(ctx: zqjs.Context, path: []const u8) !qjs.JSValue {
    const rc = RuntimeContext.get(ctx);

    const stream = try ReadableStreamObject.initFile(rc.allocator, path);
    errdefer stream.deinit();

    const js_stream = ctx.newObjectClass(rc.classes.readable_stream);
    try ctx.setOpaque(js_stream, stream);

    return js_stream;
}

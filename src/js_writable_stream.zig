//! WritableStream Web API implementation
//!
//! Provides file-backed WritableStream for fs.createWriteStream()
//! Writes are async via worker threads (similar to Node.js libuv thread pool)
//! Supports write queuing with backpressure (highWaterMark like Node.js)
//!
//! Usage:
//!   const stream = fs.createWriteStream("output.txt");
//!   const writer = stream.getWriter();
//!   await writer.write(new TextEncoder().encode("Hello"));
//!   await writer.write(new TextEncoder().encode(" World"));
//!   await writer.close();

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = z.RuntimeContext;
const EventLoop = z.EventLoop;

// ============================================================================
// STRUCTS
// ============================================================================

pub const StreamState = enum {
    writable,
    closing,
    closed,
    errored,
};

/// A pending write in the queue
pub const PendingWrite = struct {
    data: []u8,
    resolve: zqjs.Value,
    reject: zqjs.Value,
    ctx: zqjs.Context,
};

/// Write queue using ArrayListUnmanaged (simpler than intrusive linked list)
const WriteQueue = std.ArrayListUnmanaged(PendingWrite);

pub const WritableStreamObject = struct {
    allocator: std.mem.Allocator,
    state: StreamState,
    file: std.fs.File,
    position: u64,
    locked: bool,
    error_msg: ?[]const u8,
    /// Track if a write is in progress
    write_pending: bool,

    pub fn initFile(allocator: std.mem.Allocator, path: []const u8) !*WritableStreamObject {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        errdefer file.close();

        const self = try allocator.create(WritableStreamObject);
        self.* = .{
            .allocator = allocator,
            .state = .writable,
            .file = file,
            .position = 0,
            .locked = false,
            .error_msg = null,
            .write_pending = false,
        };
        return self;
    }

    pub fn deinit(self: *WritableStreamObject) void {
        if (self.state != .closed) {
            self.file.close();
        }
        self.allocator.destroy(self);
    }
};

pub const WriterObject = struct {
    allocator: std.mem.Allocator,
    stream: *WritableStreamObject,

    // Current write in flight
    pending_resolve: zqjs.Value = zqjs.UNDEFINED,
    pending_reject: zqjs.Value = zqjs.UNDEFINED,

    // Write queue for backpressure
    write_queue: WriteQueue = .{},
    queue_size: usize = 0, // Bytes currently queued
    high_water_mark: usize = 16 * 1024, // 16KB like Node.js

    // For ready promise
    ready_resolve: zqjs.Value = zqjs.UNDEFINED,
    ready_reject: zqjs.Value = zqjs.UNDEFINED,

    pub fn init(allocator: std.mem.Allocator, stream: *WritableStreamObject) !*WriterObject {
        const self = try allocator.create(WriterObject);
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .pending_resolve = zqjs.UNDEFINED,
            .pending_reject = zqjs.UNDEFINED,
            .write_queue = .{},
            .queue_size = 0,
            .high_water_mark = 16 * 1024,
            .ready_resolve = zqjs.UNDEFINED,
            .ready_reject = zqjs.UNDEFINED,
        };
        stream.locked = true;
        return self;
    }

    pub fn deinit(self: *WriterObject) void {
        // Clean up queued writes
        for (self.write_queue.items) |pending| {
            self.allocator.free(pending.data);
            pending.ctx.freeValue(pending.resolve);
            pending.ctx.freeValue(pending.reject);
        }
        self.write_queue.deinit(self.allocator);
        self.stream.locked = false;
        self.allocator.destroy(self);
    }

    pub fn isBackpressured(self: *WriterObject) bool {
        return self.queue_size >= self.high_water_mark;
    }

    /// Enqueue a write (used when a write is already in progress)
    pub fn enqueueWrite(self: *WriterObject, data: []u8, resolve: zqjs.Value, reject: zqjs.Value, ctx: zqjs.Context) !void {
        try self.write_queue.append(self.allocator, .{
            .data = data,
            .resolve = resolve,
            .reject = reject,
            .ctx = ctx,
        });
        self.queue_size += data.len;
    }

    /// Dequeue next write (called after current write completes)
    pub fn dequeueWrite(self: *WriterObject) ?PendingWrite {
        if (self.write_queue.items.len == 0) return null;
        const pending = self.write_queue.orderedRemove(0);
        self.queue_size -= pending.data.len;
        return pending;
    }
};

// ============================================================================
// ASYNC FILE WORKER
// ============================================================================

const FileWriteTask = struct {
    loop: *EventLoop,
    file: std.fs.File,
    offset: u64,
    data: []u8,
    writer_ptr: *WriterObject,
    stream_ptr: *WritableStreamObject,
    ctx: zqjs.Context,
    is_close: bool,
};

const FileWriteResult = struct {
    writer: *WriterObject,
    stream: *WritableStreamObject,
    bytes_written: usize,
    is_error: bool,
    is_close: bool,
    ctx: zqjs.Context,
};

fn workWriteFileChunk(task: FileWriteTask) void {
    const allocator = task.loop.allocator;
    defer allocator.free(task.data);

    // Seek and Write
    task.file.seekTo(task.offset) catch {
        enqueueErrorResult(allocator, task);
        return;
    };

    const bytes = task.file.write(task.data) catch {
        enqueueErrorResult(allocator, task);
        return;
    };

    if (task.is_close) {
        task.file.close();
    }

    const res = allocator.create(FileWriteResult) catch return;
    res.* = .{
        .writer = task.writer_ptr,
        .stream = task.stream_ptr,
        .bytes_written = bytes,
        .is_error = false,
        .is_close = task.is_close,
        .ctx = task.ctx,
    };

    task.loop.enqueueTask(.{
        .ctx = task.ctx,
        .resolve = zqjs.UNDEFINED,
        .reject = zqjs.UNDEFINED,
        .result = .{ .custom = .{
            .data = res,
            .callback = finishFileWrite,
            .destroy = destroyFileWriteResult,
        } },
    });
}

fn enqueueErrorResult(allocator: std.mem.Allocator, task: FileWriteTask) void {
    const res = allocator.create(FileWriteResult) catch return;
    res.* = .{
        .writer = task.writer_ptr,
        .stream = task.stream_ptr,
        .bytes_written = 0,
        .is_error = true,
        .is_close = task.is_close,
        .ctx = task.ctx,
    };
    task.loop.enqueueTask(.{
        .ctx = task.ctx,
        .resolve = zqjs.UNDEFINED,
        .reject = zqjs.UNDEFINED,
        .result = .{ .custom = .{
            .data = res,
            .callback = finishFileWrite,
            .destroy = destroyFileWriteResult,
        } },
    });
}

fn destroyFileWriteResult(allocator: std.mem.Allocator, data: *anyopaque) void {
    const res: *FileWriteResult = @ptrCast(@alignCast(data));
    allocator.destroy(res);
}

fn finishFileWrite(ctx: zqjs.Context, data: *anyopaque) void {
    const res: *FileWriteResult = @ptrCast(@alignCast(data));
    const writer = res.writer;
    const stream = res.stream;
    const rc = RuntimeContext.get(ctx);

    // Update position
    stream.position += res.bytes_written;
    stream.write_pending = false;

    if (res.is_close) {
        stream.state = .closed;
    }

    // Resolve/reject current write
    if (res.is_error) {
        stream.state = .errored;
        const err_str = ctx.newString("File write error");
        var args = [1]qjs.JSValue{err_str};
        const ret = qjs.JS_Call(ctx.ptr, writer.pending_reject, zqjs.UNDEFINED, 1, &args);
        ctx.freeValue(ret);
        ctx.freeValue(err_str);
    } else {
        const bytes_val = ctx.newInt64(@intCast(res.bytes_written));
        var args = [1]qjs.JSValue{bytes_val};
        const ret = qjs.JS_Call(ctx.ptr, writer.pending_resolve, zqjs.UNDEFINED, 1, &args);
        ctx.freeValue(ret);
        ctx.freeValue(bytes_val);
    }

    ctx.freeValue(writer.pending_resolve);
    ctx.freeValue(writer.pending_reject);
    writer.pending_resolve = zqjs.UNDEFINED;
    writer.pending_reject = zqjs.UNDEFINED;

    // Check if queue dropped below high water mark - resolve ready promise
    if (!writer.isBackpressured() and !ctx.isUndefined(writer.ready_resolve)) {
        var args = [1]qjs.JSValue{zqjs.UNDEFINED};
        const ret = qjs.JS_Call(ctx.ptr, writer.ready_resolve, zqjs.UNDEFINED, 1, &args);
        ctx.freeValue(ret);
        ctx.freeValue(writer.ready_resolve);
        ctx.freeValue(writer.ready_reject);
        writer.ready_resolve = zqjs.UNDEFINED;
        writer.ready_reject = zqjs.UNDEFINED;
    }

    // Process next queued write
    if (writer.dequeueWrite()) |pending| {
        stream.write_pending = true;
        writer.pending_resolve = pending.resolve;
        writer.pending_reject = pending.reject;

        const task = FileWriteTask{
            .loop = rc.loop,
            .file = stream.file,
            .offset = stream.position,
            .data = pending.data,
            .writer_ptr = writer,
            .stream_ptr = stream,
            .ctx = pending.ctx,
            .is_close = false,
        };

        rc.loop.spawnWorker(workWriteFileChunk, task) catch {
            // Failed to spawn - reject promise
            const err_str = pending.ctx.newString("Failed to spawn worker");
            var err_args = [1]qjs.JSValue{err_str};
            const err_ret = qjs.JS_Call(pending.ctx.ptr, pending.reject, zqjs.UNDEFINED, 1, &err_args);
            pending.ctx.freeValue(err_ret);
            pending.ctx.freeValue(err_str);
            pending.ctx.freeValue(pending.resolve);
            pending.ctx.freeValue(pending.reject);
            rc.allocator.free(pending.data);
            stream.write_pending = false;
        };
    }

    rc.allocator.destroy(res);
}

// =============================================================
// JS Callbacks - WritableStream

fn js_WritableStream_finalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    _ = rt;
    const ptr = qjs.JS_GetOpaque(val, getStreamClassId());
    if (ptr) |p| {
        const stream: *WritableStreamObject = @ptrCast(@alignCast(p));
        stream.deinit();
    }
}

fn js_WritableStream_getWriter(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const stream = ctx.getOpaqueAs(WritableStreamObject, this, rc.classes.writable_stream) orelse {
        return ctx.throwTypeError("Invalid WritableStream");
    };

    if (stream.locked) {
        return ctx.throwTypeError("WritableStream is locked");
    }

    const writer = WriterObject.init(rc.allocator, stream) catch {
        return ctx.throwOutOfMemory();
    };

    const writer_obj = ctx.newObjectClass(rc.classes.writable_stream_writer);
    ctx.setOpaque(writer_obj, writer) catch {
        writer.deinit();
        return ctx.throwOutOfMemory();
    };

    return writer_obj;
}

fn js_WritableStream_get_locked(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const stream = ctx.getOpaqueAs(WritableStreamObject, this, rc.classes.writable_stream) orelse return ctx.newBool(false);
    return ctx.newBool(stream.locked);
}

fn js_WritableStream_close(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (ctx.getOpaqueAs(WritableStreamObject, this, rc.classes.writable_stream)) |stream| {
        if (stream.state == .writable) {
            stream.file.close();
            stream.state = .closed;
        }
    }

    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

fn js_WritableStream_abort(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (ctx.getOpaqueAs(WritableStreamObject, this, rc.classes.writable_stream)) |stream| {
        if (stream.state != .closed) {
            stream.file.close();
            stream.state = .errored;
            stream.error_msg = "Aborted";
        }
    }

    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

// =============================================================
// JS Callbacks - Writer

fn js_Writer_finalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    _ = rt;
    const ptr = qjs.JS_GetOpaque(val, getWriterClassId());
    if (ptr) |p| {
        const writer: *WriterObject = @ptrCast(@alignCast(p));
        writer.deinit();
    }
}

fn js_Writer_write(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) {
        return ctx.throwTypeError("write() requires a chunk argument");
    }

    const writer = ctx.getOpaqueAs(WriterObject, this, rc.classes.writable_stream_writer) orelse {
        return ctx.throwTypeError("Invalid writer");
    };
    const stream = writer.stream;

    if (stream.state != .writable) {
        return ctx.throwTypeError("Stream is not writable");
    }

    // Extract data from chunk
    const chunk = argv[0];
    var data_slice: []const u8 = &.{};
    var free_cstr: ?[*:0]const u8 = null;

    if (qjs.JS_IsString(chunk)) {
        const c_str = ctx.toCString(chunk) catch return zqjs.EXCEPTION;
        data_slice = std.mem.span(c_str);
        free_cstr = c_str;
    } else {
        var len: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, chunk);
        if (ptr) |p| {
            data_slice = p[0..len];
        } else {
            var buf_size: usize = 0;
            var buf_offset: usize = 0;
            var bytes_per_element: usize = 0;
            const ab = qjs.JS_GetTypedArrayBuffer(ctx.ptr, chunk, &buf_offset, &buf_size, &bytes_per_element);
            if (!qjs.JS_IsException(ab)) {
                var ab_len: usize = 0;
                const ab_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &ab_len, ab);
                ctx.freeValue(ab);
                if (ab_ptr) |p| {
                    data_slice = p[buf_offset .. buf_offset + buf_size];
                }
            }
        }
    }
    defer if (free_cstr) |c| ctx.freeCString(c);

    if (data_slice.len == 0) {
        return createResolvedPromise(ctx, ctx.newInt64(0));
    }

    // Copy data for worker thread
    const data_copy = rc.allocator.dupe(u8, data_slice) catch {
        return ctx.throwOutOfMemory();
    };

    // Create Promise
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) {
        rc.allocator.free(data_copy);
        return promise;
    }

    // If a write is already pending, queue this one
    if (stream.write_pending) {
        writer.enqueueWrite(data_copy, resolvers[0], resolvers[1], ctx) catch {
            rc.allocator.free(data_copy);
            ctx.freeValue(resolvers[0]);
            ctx.freeValue(resolvers[1]);
            ctx.freeValue(promise);
            return ctx.throwOutOfMemory();
        };
        return promise;
    }

    // Start write immediately
    writer.pending_resolve = resolvers[0];
    writer.pending_reject = resolvers[1];
    stream.write_pending = true;

    const task = FileWriteTask{
        .loop = rc.loop,
        .file = stream.file,
        .offset = stream.position,
        .data = data_copy,
        .writer_ptr = writer,
        .stream_ptr = stream,
        .ctx = ctx,
        .is_close = false,
    };

    rc.loop.spawnWorker(workWriteFileChunk, task) catch {
        rc.allocator.free(data_copy);
        ctx.freeValue(resolvers[0]);
        ctx.freeValue(resolvers[1]);
        ctx.freeValue(promise);
        stream.write_pending = false;
        return ctx.throwInternalError("Failed to spawn write worker");
    };

    return promise;
}

fn js_Writer_close(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const writer = ctx.getOpaqueAs(WriterObject, this, rc.classes.writable_stream_writer) orelse {
        return ctx.throwTypeError("Invalid writer");
    };
    const stream = writer.stream;

    if (stream.state == .closed) {
        return createResolvedPromise(ctx, zqjs.UNDEFINED);
    }

    // Wait for queue to drain
    if (stream.write_pending or writer.write_queue.items.len > 0) {
        return ctx.throwTypeError("Cannot close while writes are pending");
    }

    stream.file.close();
    stream.state = .closed;

    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

fn js_Writer_abort(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (ctx.getOpaqueAs(WriterObject, this, rc.classes.writable_stream_writer)) |writer| {
        if (writer.stream.state != .closed) {
            writer.stream.file.close();
            writer.stream.state = .errored;
        }
    }

    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

fn js_Writer_releaseLock(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (ctx.getOpaqueAs(WriterObject, this, rc.classes.writable_stream_writer)) |writer| {
        writer.stream.locked = false;
    }

    return zqjs.UNDEFINED;
}

fn js_Writer_get_closed(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const writer = ctx.getOpaqueAs(WriterObject, this, rc.classes.writable_stream_writer) orelse {
        return createRejectedPromise(ctx, "Invalid writer");
    };

    if (writer.stream.state == .closed) {
        return createResolvedPromise(ctx, zqjs.UNDEFINED);
    } else if (writer.stream.state == .errored) {
        return createRejectedPromise(ctx, writer.stream.error_msg orelse "Stream error");
    }

    return createResolvedPromise(ctx, zqjs.UNDEFINED);
}

fn js_Writer_get_ready(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const writer = ctx.getOpaqueAs(WriterObject, this, rc.classes.writable_stream_writer) orelse {
        return createRejectedPromise(ctx, "Invalid writer");
    };

    // If not backpressured, resolve immediately
    if (!writer.isBackpressured()) {
        return createResolvedPromise(ctx, zqjs.UNDEFINED);
    }

    // Create promise that resolves when queue drains below high water mark
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return promise;

    // Store resolvers - will be called when queue drains
    writer.ready_resolve = resolvers[0];
    writer.ready_reject = resolvers[1];

    return promise;
}

fn js_Writer_get_desiredSize(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const writer = ctx.getOpaqueAs(WriterObject, this, rc.classes.writable_stream_writer) orelse {
        return zqjs.NULL;
    };

    // desiredSize = highWaterMark - queueSize (can be negative)
    const desired: i64 = @as(i64, @intCast(writer.high_water_mark)) - @as(i64, @intCast(writer.queue_size));
    return ctx.newInt64(desired);
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
// Class ID helpers

var g_stream_class_id: qjs.JSClassID = 0;
var g_writer_class_id: qjs.JSClassID = 0;

fn getStreamClassId() qjs.JSClassID {
    return g_stream_class_id;
}

fn getWriterClassId() qjs.JSClassID {
    return g_writer_class_id;
}

// ============================================================================
// Installation
// ============================================================================

pub fn install(ctx: zqjs.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    // WritableStream class
    if (rc.classes.writable_stream == 0) {
        rc.classes.writable_stream = rt.newClassID();
        g_stream_class_id = rc.classes.writable_stream;
        try rt.newClass(rc.classes.writable_stream, .{
            .class_name = "WritableStream",
            .finalizer = js_WritableStream_finalizer,
        });
    }

    const stream_proto = ctx.newObject();
    _ = qjs.JS_SetPropertyStr(ctx.ptr, stream_proto, "getWriter", qjs.JS_NewCFunction(ctx.ptr, js_WritableStream_getWriter, "getWriter", 0));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, stream_proto, "close", qjs.JS_NewCFunction(ctx.ptr, js_WritableStream_close, "close", 0));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, stream_proto, "abort", qjs.JS_NewCFunction(ctx.ptr, js_WritableStream_abort, "abort", 0));

    // locked getter
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "locked");
        const get = qjs.JS_NewCFunction2(ctx.ptr, js_WritableStream_get_locked, "get_locked", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, stream_proto, atom, get, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }

    ctx.setClassProto(rc.classes.writable_stream, stream_proto);

    // WritableStreamDefaultWriter class
    if (rc.classes.writable_stream_writer == 0) {
        rc.classes.writable_stream_writer = rt.newClassID();
        g_writer_class_id = rc.classes.writable_stream_writer;
        try rt.newClass(rc.classes.writable_stream_writer, .{
            .class_name = "WritableStreamDefaultWriter",
            .finalizer = js_Writer_finalizer,
        });
    }

    const writer_proto = ctx.newObject();
    _ = qjs.JS_SetPropertyStr(ctx.ptr, writer_proto, "write", qjs.JS_NewCFunction(ctx.ptr, js_Writer_write, "write", 1));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, writer_proto, "close", qjs.JS_NewCFunction(ctx.ptr, js_Writer_close, "close", 0));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, writer_proto, "abort", qjs.JS_NewCFunction(ctx.ptr, js_Writer_abort, "abort", 0));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, writer_proto, "releaseLock", qjs.JS_NewCFunction(ctx.ptr, js_Writer_releaseLock, "releaseLock", 0));

    // closed getter
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "closed");
        const get = qjs.JS_NewCFunction2(ctx.ptr, js_Writer_get_closed, "get_closed", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, writer_proto, atom, get, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }

    // ready getter
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "ready");
        const get = qjs.JS_NewCFunction2(ctx.ptr, js_Writer_get_ready, "get_ready", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, writer_proto, atom, get, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }

    // desiredSize getter
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "desiredSize");
        const get = qjs.JS_NewCFunction2(ctx.ptr, js_Writer_get_desiredSize, "get_desiredSize", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, writer_proto, atom, get, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }

    ctx.setClassProto(rc.classes.writable_stream_writer, writer_proto);
}

/// Create a WritableStream JS object for writing to a file
pub fn createStreamToFile(ctx: zqjs.Context, path: []const u8) !qjs.JSValue {
    const rc = RuntimeContext.get(ctx);

    const stream = try WritableStreamObject.initFile(rc.allocator, path);
    errdefer stream.deinit();

    const js_stream = ctx.newObjectClass(rc.classes.writable_stream);
    try ctx.setOpaque(js_stream, stream);

    return js_stream;
}

//! JavaScript Worker API implementation

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const Mailbox = z.Mailbox;

/// Message types for inter-thread communication
pub const WorkerMessage = struct {
    tag: enum { PostMessage, Terminate, Error },
    data: []u8,
};

/// Worker thread state (lives in worker thread)
pub const WorkerThread = struct {
    allocator: std.mem.Allocator,
    script_path: [:0]const u8,
    inbox: *Mailbox(WorkerMessage),
    outbox: *Mailbox(WorkerMessage),
    terminate_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn run(self: *WorkerThread) void {
        defer {
            self.allocator.free(self.script_path);
            self.allocator.destroy(self);
        }

        const rt = zqjs.Runtime.init(self.allocator) catch return;
        defer rt.deinit();

        rt.setInterruptHandler(js_interrupt_handler, @ptrCast(self));

        const ctx = zqjs.Context.init(rt);
        defer ctx.deinit();
        ctx.setAllocator(&self.allocator);

        var loop = EventLoop.create(self.allocator, rt) catch return;
        defer loop.destroy();
        loop.install(ctx) catch return;

        self.installWorkerGlobals(ctx) catch return;

        const script = self.loadScript() catch |err| {
            self.sendError(@errorName(err)) catch {};
            return;
        };
        defer self.allocator.free(script);

        // Execute script
        const result = ctx.eval(script, self.script_path, .{}) catch |err| {
            self.sendError(@errorName(err)) catch {};
            return;
        };
        ctx.freeValue(result);

        // Event loop
        var running = true;
        while (running) {
            _ = rt.executePendingJob() catch {};
            _ = loop.processAsyncTasks();

            const wait_ms: i64 = loop.processTimers() catch 100;
            const timeout_ns = @as(u64, @intCast(@max(wait_ms, 0))) * std.time.ns_per_ms;

            if (self.inbox.receive(timeout_ns)) |msg| {
                defer self.allocator.free(msg.data);
                switch (msg.tag) {
                    .PostMessage => self.fireMessageEvent(ctx, msg.data) catch {},
                    .Terminate => running = false,
                    .Error => {},
                }
            } else |err| {
                switch (err) {
                    error.Timeout => {},
                    error.MailboxClosed => running = false,
                }
            }
        }
    }

    fn loadScript(self: *WorkerThread) ![]u8 {
        const file = try std.fs.cwd().openFile(self.script_path, .{});
        defer file.close();
        return try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
    }

    fn installWorkerGlobals(self: *WorkerThread, ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        try registerWorkerClass(ctx);
        ctx.setContextOpaque(self);

        const post_message_fn = ctx.newCFunction(js_postMessage, "postMessage", 1);
        _ = try ctx.setPropertyStr(global, "postMessage", post_message_fn);

        const close_fn = ctx.newCFunction(js_close, "close", 0);
        _ = try ctx.setPropertyStr(global, "close", close_fn);

        const import_scripts_fn = ctx.newCFunction(js_importScripts, "importScripts", 1);
        _ = try ctx.setPropertyStr(global, "importScripts", import_scripts_fn);
    }

    fn fireMessageEvent(_: *WorkerThread, ctx: zqjs.Context, data: []const u8) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const onmessage = ctx.getPropertyStr(global, "onmessage");
        defer ctx.freeValue(onmessage);

        if (!ctx.isFunction(onmessage)) return;

        const event_obj = ctx.newObject();
        defer ctx.freeValue(event_obj);

        const data_val = ctx.readObject(data, .{});
        // Note: setPropertyStr steals ownership, so NO defer freeValue(data_val)
        if (ctx.isException(data_val)) return;

        _ = try ctx.setPropertyStr(event_obj, "data", data_val);
        const result = ctx.call(onmessage, global, &[_]zqjs.Value{event_obj});
        defer ctx.freeValue(result);
    }

    fn sendError(self: *WorkerThread, error_msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, error_msg);
        errdefer self.allocator.free(copy);
        try self.outbox.send(.{ .tag = .Error, .data = copy });
    }
};

fn js_interrupt_handler(_: ?*qjs.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const ptr = opaque_ptr orelse return 0;
    const self: *WorkerThread = @ptrCast(@alignCast(ptr));
    return if (self.terminate_flag.load(.seq_cst)) 1 else 0;
}

threadlocal var worker_class_id: qjs.JSClassID = 0;

pub const JSWorker = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    inbox: Mailbox(WorkerMessage),
    outbox: Mailbox(WorkerMessage),
    worker_thread: *WorkerThread,
    loop: *EventLoop,
    ctx: zqjs.Context,
    onmessage: zqjs.Value,
    onerror: zqjs.Value,
    self_ref: zqjs.Value,

    pub fn create(
        allocator: std.mem.Allocator,
        loop: *EventLoop,
        ctx: zqjs.Context,
        script_path: []const u8,
    ) !*JSWorker {
        const self = try allocator.create(JSWorker);
        errdefer allocator.destroy(self);

        const worker_thread = try allocator.create(WorkerThread);
        errdefer allocator.destroy(worker_thread);

        self.* = .{
            .allocator = allocator,
            .thread = undefined,
            .loop = loop,
            .inbox = Mailbox(WorkerMessage).init(allocator),
            .outbox = Mailbox(WorkerMessage).init(allocator),
            .worker_thread = worker_thread,
            .ctx = ctx,
            .onmessage = zqjs.UNDEFINED,
            .onerror = zqjs.UNDEFINED,
            .self_ref = zqjs.UNDEFINED,
        };

        self.onmessage = ctx.dupValue(zqjs.UNDEFINED);
        self.onerror = ctx.dupValue(zqjs.UNDEFINED);

        worker_thread.* = .{
            .allocator = allocator,
            .script_path = try allocator.dupeZ(u8, script_path),
            .inbox = &self.outbox,
            .outbox = &self.inbox,
        };

        self.thread = try std.Thread.spawn(.{}, WorkerThread.run, .{worker_thread});
        return self;
    }

    pub fn destroy(self: *JSWorker) void {
        self.terminate() catch {};
        self.thread.join();
        self.inbox.deinit();
        self.outbox.deinit();
        self.allocator.destroy(self);
    }

    pub fn postMessage(self: *JSWorker, data: []const u8) !void {
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        try self.outbox.send(.{ .tag = .PostMessage, .data = copy });
    }

    pub fn terminate(self: *JSWorker) !void {
        if (!self.ctx.isUndefined(self.self_ref)) {
            self.ctx.freeValue(self.self_ref);
            self.self_ref = zqjs.UNDEFINED;
        }

        self.worker_thread.terminate_flag.store(true, .seq_cst);
        const empty = try self.allocator.alloc(u8, 0);
        try self.outbox.send(.{ .tag = .Terminate, .data = empty });
    }
    // Poll for incoming messages from the worker thread in the main thread
    pub fn poll(self: *JSWorker) !void {
        while (true) {
            const msg = self.inbox.receive(0) catch |err| {
                if (err == error.Timeout) return;
                return err;
            };
            defer self.allocator.free(msg.data);

            // Safety check: if terminated, stop polling
            if (self.ctx.isUndefined(self.self_ref)) return;

            switch (msg.tag) {
                .PostMessage => {
                    if (!self.ctx.isFunction(self.onmessage)) continue;
                    const event = self.ctx.newObject();
                    defer self.ctx.freeValue(event);

                    // read and deserialize message data
                    const data_val = self.ctx.readObject(msg.data, .{});
                    // Note: setPropertyStr steals ownership
                    if (self.ctx.isException(data_val)) continue;

                    _ = try self.ctx.setPropertyStr(event, "data", data_val);
                    const result = self.ctx.call(self.onmessage, zqjs.UNDEFINED, &[_]zqjs.Value{event});
                    defer self.ctx.freeValue(result);
                },
                .Error => {
                    if (!self.ctx.isFunction(self.onerror)) continue;
                    const event = self.ctx.newObject();
                    defer self.ctx.freeValue(event);

                    const msg_val = self.ctx.newString(msg.data);
                    // setPropertyStr steals ownership

                    _ = try self.ctx.setPropertyStr(event, "message", msg_val);
                    const result = self.ctx.call(self.onerror, zqjs.UNDEFINED, &[_]zqjs.Value{event});
                    defer self.ctx.freeValue(result);
                },
                .Terminate => {},
            }
        }
    }
};

// ... C Functions ...

fn js_postMessage(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("postMessage requires 1 argument");

    const worker_thread = ctx.getContextOpaque(WorkerThread) orelse return ctx.throwInternalError("Worker context not found");

    // 1. Serialize (QJS Allocator)
    const binary_data = ctx.writeObject(argv[0], .{}) catch return ctx.throwInternalError("Failed to serialize message");

    // 2. Copy (Zig Allocator)
    const copy = worker_thread.allocator.dupe(u8, binary_data) catch {
        ctx.free(@ptrCast(binary_data.ptr));
        return ctx.throwOutOfMemory();
    };

    // 3. Free QJS memory
    ctx.free(@ptrCast(binary_data.ptr));

    // 4. Send
    worker_thread.outbox.send(.{ .tag = .PostMessage, .data = copy }) catch {
        worker_thread.allocator.free(copy);
        return ctx.throwInternalError("Failed to send message");
    };

    return zqjs.UNDEFINED;
}

// ... Getters/Setters ...
fn js_Worker_get_onmessage(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker) |w_ptr| {
        const w: *JSWorker = @ptrCast(@alignCast(w_ptr));
        return ctx.dupValue(w.onmessage);
    }
    return zqjs.UNDEFINED;
}

fn js_Worker_set_onmessage(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return zqjs.UNDEFINED;
    const val = argv[0];
    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker) |w_ptr| {
        const w: *JSWorker = @ptrCast(@alignCast(w_ptr));
        ctx.freeValue(w.onmessage);
        w.onmessage = ctx.dupValue(val);
    }
    return zqjs.UNDEFINED;
}

fn js_close(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const worker_thread = ctx.getContextOpaque(WorkerThread) orelse return ctx.throwInternalError("Worker context not found");
    const empty = worker_thread.allocator.alloc(u8, 0) catch return ctx.throwInternalError("Out of memory");
    worker_thread.inbox.close();
    worker_thread.allocator.free(empty);
    return zqjs.UNDEFINED;
}

fn js_importScripts(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("importScripts requires at least one argument");
    const worker_thread = ctx.getContextOpaque(WorkerThread) orelse return ctx.throwInternalError("Worker context not found");

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const path_cstr = ctx.toCString(argv[@intCast(i)]) catch return zqjs.EXCEPTION;
        defer ctx.freeCString(path_cstr);
        const path = std.mem.span(path_cstr);
        const file = std.fs.cwd().openFile(path, .{}) catch return ctx.throwError();
        defer file.close();
        const script = file.readToEndAlloc(worker_thread.allocator, 10 * 1024 * 1024) catch return ctx.throwError();
        defer worker_thread.allocator.free(script);
        const result = ctx.eval(script, path_cstr, .{}) catch return ctx.throwError();
        ctx.freeValue(result);
    }
    return zqjs.UNDEFINED;
}

pub fn js_Worker_constructor(
    ctx_ptr: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("Worker constructor requires scriptPath argument");

    const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const path_cstr = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_cstr);
    const script_path = std.mem.span(path_cstr);

    const worker = JSWorker.create(loop.allocator, loop, ctx, script_path) catch return ctx.throwError();

    var proto = ctx.getPropertyStr(new_target, "prototype");
    if (ctx.isException(proto) or ctx.isUndefined(proto)) {
        if (ctx.isException(proto)) _ = ctx.getException();
        proto = ctx.getClassProto(loop.worker_class_id);
    }
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, loop.worker_class_id);
    if (ctx.isException(obj)) {
        ctx.freeValue(worker.onmessage);
        ctx.freeValue(worker.onerror);
        worker.destroy();
        return obj;
    }

    _ = qjs.JS_SetOpaque(obj, worker);

    // PIN THE OBJECT: Keep it alive until terminate()
    worker.self_ref = ctx.dupValue(obj);

    loop.registerWorker(worker) catch {
        ctx.freeValue(obj);
        return ctx.throwError();
    };

    return obj;
}

pub fn js_Worker_postMessage(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("postMessage requires 1 argument");

    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker == null) return ctx.throwTypeError("Not a Worker instance");
    const w: *JSWorker = @ptrCast(@alignCast(worker));

    // 1. Serialize (QJS Allocator)
    const binary_data = ctx.writeObject(argv[0], .{}) catch return ctx.throwError();

    // 2. Copy (Zig Allocator)
    const copy = w.allocator.dupe(u8, binary_data) catch {
        ctx.free(@ptrCast(binary_data.ptr));
        return ctx.throwOutOfMemory();
    };

    // 3. Free QJS Memory
    ctx.free(@ptrCast(binary_data.ptr));

    // 4. Send
    w.outbox.send(.{ .tag = .PostMessage, .data = copy }) catch {
        w.allocator.free(copy);
        return ctx.throwError();
    };

    return zqjs.UNDEFINED;
}

pub fn js_Worker_terminate(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker == null) return ctx.throwTypeError("Not a Worker instance");
    const w: *JSWorker = @ptrCast(@alignCast(worker));
    w.terminate() catch return ctx.throwError();
    return zqjs.UNDEFINED;
}

// FIX: Added ?*const to make it a function pointer, satisfying the C Calling Convention
fn workerGCMark(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue, mark_func: ?*const qjs.JS_MarkFunc) callconv(.c) void {
    const ptr = qjs.JS_GetOpaque(val, worker_class_id);
    if (ptr) |p| {
        const worker: *JSWorker = @ptrCast(@alignCast(p));
        // Tell GC that this Worker object holds references to these JSValues
        qjs.JS_MarkValue(rt_ptr, worker.onmessage, mark_func);
        qjs.JS_MarkValue(rt_ptr, worker.onerror, mark_func);
    }
}

pub fn registerWorkerClass(ctx: zqjs.Context) !void {
    const rt = ctx.getRuntime();
    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;

    loop.worker_class_id = rt.newClassID();
    worker_class_id = loop.worker_class_id;

    try rt.newClass(loop.worker_class_id, .{
        .class_name = "Worker",
        .finalizer = workerFinalizer,
        .gc_mark = workerGCMark,
    });

    const proto = ctx.newObject();
    defer ctx.freeValue(proto);

    const postMessage_fn = ctx.newCFunction(js_Worker_postMessage, "postMessage", 1);
    _ = try ctx.setPropertyStr(proto, "postMessage", postMessage_fn);
    const terminate_fn = ctx.newCFunction(js_Worker_terminate, "terminate", 0);
    _ = try ctx.setPropertyStr(proto, "terminate", terminate_fn);
    const onmessage_get = ctx.newCFunction(js_Worker_get_onmessage, "onmessage", 0);
    const onmessage_set = ctx.newCFunction(js_Worker_set_onmessage, "onmessage", 1);

    const flags = zqjs.Context.PropertyFlags{ .configurable = true, .enumerable = true, .getset = true, .writable = false, .normal = false };
    _ = try ctx.definePropertyGetSet(proto, ctx.newAtom("onmessage"), onmessage_get, onmessage_set, flags);

    ctx.setClassProto(loop.worker_class_id, proto);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const ctor = ctx.newCFunctionConstructor(js_Worker_constructor, "Worker", 1);
    _ = try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
    _ = try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor));
    _ = try ctx.setPropertyStr(global, "Worker", ctor);
}

fn workerFinalizer(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const ptr = qjs.JS_GetOpaque(val, worker_class_id);
    if (ptr) |p| {
        const worker: *JSWorker = @ptrCast(@alignCast(p));
        worker.loop.unregisterWorker(worker);
        qjs.JS_FreeValueRT(rt_ptr, worker.onmessage);
        qjs.JS_FreeValueRT(rt_ptr, worker.onerror);
        worker.destroy();
    }
}

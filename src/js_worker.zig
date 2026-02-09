//! JavaScript Worker API implementation - Decoupled & Simplified

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const Mailbox = z.Mailbox;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_security = @import("js_security.zig");
const workers = @import("workers.zig");
const js_fetch_easy = @import("js_fetch_easy.zig");
// const js_fetch = @import("js_fetch.zig");
const js_blob = @import("js_blob.zig");
const js_formData = @import("js_formData.zig");
const js_headers = @import("js_headers.zig");
const js_fs = @import("js_fs.zig");

// -------------------------------------------------------------------------

pub const WorkerMessage = struct {
    tag: enum { PostMessage, Terminate, Error },
    data: []u8,
};

/// The "Shared State" (Bridge Pattern) that holds the Mailboxes and control flags
const WorkerCore = struct {
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(usize),
    inbox: Mailbox(WorkerMessage),
    outbox: Mailbox(WorkerMessage),
    terminate_flag: std.atomic.Value(bool),
    script_path: [:0]const u8,
    sandbox_root: [:0]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        script_path: []const u8,
        sandbox_root: []const u8,
    ) !*WorkerCore {
        std.debug.print("[WorkerCore] Init\n", .{});
        const self = try allocator.create(WorkerCore);
        self.* = .{
            .allocator = allocator,
            .ref_count = std.atomic.Value(usize).init(1),
            .inbox = Mailbox(WorkerMessage).init(allocator),
            .outbox = Mailbox(WorkerMessage).init(allocator),
            .terminate_flag = std.atomic.Value(bool).init(false),
            .script_path = try allocator.dupeZ(u8, script_path),
            .sandbox_root = try allocator.dupeZ(u8, sandbox_root),
        };

        std.debug.print("[Core] Initialized count: 1\n", .{});
        return self;
    }

    pub fn retain(self: *WorkerCore) void {
        const prev = self.ref_count.fetchAdd(1, .seq_cst);
        std.debug.print("[Core] Retain. New count: {}\n", .{prev + 1});
    }

    pub fn release(self: *WorkerCore) void {
        const prev = self.ref_count.fetchSub(1, .seq_cst);
        std.debug.print("[Core] Release. Prev count: {}\n", .{prev});
        if (prev == 1) {
            std.debug.print("[Core] RefCount 0. Destroying resources.\n", .{});
            while (true) {
                if (self.inbox.receive(0)) |msg| {
                    self.allocator.free(msg.data);
                } else |_| {
                    // Likely error.Timeout (queue empty) or error.MailboxClosed
                    break;
                }
            }
            self.inbox.deinit();
            while (true) {
                if (self.outbox.receive(0)) |msg| {
                    self.allocator.free(msg.data);
                } else |_| {
                    break;
                }
            }
            self.outbox.deinit();
            self.allocator.free(self.script_path);
            self.allocator.free(self.sandbox_root);
            self.allocator.destroy(self);
        }
    }

    pub fn signalTerminate(self: *WorkerCore) void {
        std.debug.print("[Core] signalTerminate called\n", .{});
        if (self.terminate_flag.load(.seq_cst)) return;
        self.terminate_flag.store(true, .seq_cst);
        std.debug.print("[Core] Flag stored. Sending wake message to INBOX...\n", .{});
        const empty = self.allocator.alloc(u8, 0) catch return;
        self.inbox.send(.{ .tag = .Terminate, .data = empty }) catch {};
    }
};

fn handleException(ctx: zqjs.Context, loop: *EventLoop, core: *WorkerCore) void {
    std.debug.print("[handleException] Called\n", .{});
    const exception_val = ctx.getException();
    // defer ctx.freeValue(exception_val); // Always free the exception object

    var handled = false;

    // 1. Check for local 'onerror' (Worker-side)
    if (!ctx.isUndefined(loop.on_error_handler)) {
        const event = ctx.newObject();
        const msg_cstr = ctx.toCString(exception_val) catch "Unknown Error"; // Convert exception to string
        std.debug.print("[handleException] {s}\n", .{msg_cstr});
        defer ctx.freeCString(msg_cstr);
        const msg_zstr: []const u8 = std.mem.span(msg_cstr);
        const msg_val = ctx.newString(msg_zstr);

        ctx.setPropertyStr(event, "message", msg_val) catch {};
        const ret = ctx.call(loop.on_error_handler, zqjs.UNDEFINED, &[_]zqjs.Value{event});
        // std.Io.Writer.flush(w: *Writer)
        const err_bool = ctx.toBool(ret) catch false;
        if (err_bool) handled = true;
        ctx.freeValue(ret);
        ctx.freeValue(event);
    }

    // 2. If NOT handled locally, send to Main Thread
    if (!handled) {
        const msg_str = ctx.toCString(exception_val) catch "Unknown Error";
        defer ctx.freeCString(msg_str);

        // This triggers 'w.onerror' in the Main Thread
        sendError(core, std.mem.span(msg_str)) catch {};
    }
    ctx.freeValue(exception_val);
}

const WorkerThread = struct {
    pub fn run(core: *WorkerCore) void {
        defer core.release();
        std.debug.print("[Thread] STARTING\n", .{});

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var sandbox = js_security.Sandbox.init(allocator, core.sandbox_root) catch return;
        defer sandbox.deinit();

        const rt = zqjs.Runtime.init(allocator) catch return;
        defer rt.deinit();

        rt.setMemoryLimit(64 * 1024 * 1024); // 64 MB
        rt.setGCThreshold(16 * 1024 * 1024); // 16MB before GC (avoid mid-render collection)
        rt.setMaxStackSize(2 * 1024 * 1024); // 2 MB stack for deep vnode trees

        rt.setInterruptHandler(js_interrupt_handler, @ptrCast(core));
        rt.setModuleLoader(
            js_security.js_secure_module_normalize,
            js_security.js_secure_module_loader,
            &sandbox,
        );

        const ctx = zqjs.Context.init(rt);
        defer ctx.deinit();
        // ctx.setAllocator(&allocator);

        var loop = EventLoop.create(allocator, rt) catch return;
        defer loop.destroy();
        std.debug.print("[Thread] Installing event loop...\n", .{});

        // Store WorkerCore in RuntimeContext for access from JS callbacks
        const rc = RuntimeContext.create(
            allocator,
            ctx,
            loop,
            &sandbox,
            core.sandbox_root,
        ) catch return;
        defer rc.destroy();
        // const rc = RuntimeContext.get(ctx);

        loop.install(ctx) catch |e| {
            std.debug.print("[Thread] Failed to install event loop: {}\n", .{e});
            return;
        };
        std.debug.print("[Thread] Event loop installed\n", .{});
        rc.worker_core = @ptrCast(core);

        installWorkerGlobals(ctx, core, loop) catch return;

        const script = std.fs.cwd().readFileAllocOptions(allocator, core.script_path, 1024 * 1024, null, std.mem.Alignment.fromByteUnits(1), 0) catch |err| {
            sendError(core, @errorName(err)) catch {};
            return;
        };
        defer allocator.free(script);

        const flags = qjs.JS_EVAL_TYPE_MODULE;
        const result_val = qjs.JS_Eval(
            ctx.ptr,
            script.ptr,
            script.len,
            core.script_path.ptr,
            @intCast(flags),
        );

        if (ctx.isException(result_val)) {
            _ = ctx.checkAndPrintException();
            sendError(core, "Worker Startup Failed") catch {};
            return;
        }

        // !! Execute pending jobs to resolve module imports BEFORE freeing
        std.debug.print("[Thread] Resolving module imports...\n", .{});
        while (rt.executePendingJob() catch null) |_| {}

        // Now it's safe to free the module namespace
        ctx.freeValue(result_val);

        std.debug.print("[Thread] Waiting for messages...\n", .{});

        var running = true;
        while (running) {
            // _ = rt.executePendingJob() catch {};
            const did_async_work = loop.processAsyncTasks();
            var err_ctx_ptr: ?*qjs.JSContext = null;
            const ret = qjs.JS_ExecutePendingJob(rt.ptr, &err_ctx_ptr);
            if (ret < 0) {
                // if (rt.executePendingJob() catch null) |err_ctx| {
                const err_ctx = zqjs.Context{ .ptr = err_ctx_ptr };
                handleException(err_ctx, loop, core);
            }
            // const wait_ms: i64 = loop.processTimers() catch 100;
            const wait_ms: i64 = loop.processTimers() catch |err| blk: {
                if (err == error.JSException) {
                    // Now the Timer error goes to the Main Thread!
                    handleException(ctx, loop, core);
                } else {
                    std.debug.print("[Thread] Timer error: {}\n", .{err});
                }
                // Return 0 wait time to immediately drain any resulting microtasks
                break :blk 0;
            };
            const effective_wait = if (did_async_work) 0 else wait_ms;
            const timeout_ns = @as(u64, @intCast(@max(effective_wait, 0))) * std.time.ns_per_ms;

            if (core.inbox.receive(timeout_ns)) |msg| {
                defer core.allocator.free(msg.data);
                std.debug.print("[core.inbox.receive] {any}\n", .{msg.tag});
                switch (msg.tag) {
                    .PostMessage => fireMessageEvent(ctx, msg.data, loop, core) catch {},
                    .Terminate => {
                        std.debug.print("[Thread] Received TERMINATE signal.\n", .{});
                        running = false;
                    },
                    .Error => {},
                }
            } else |err| {
                if (err == error.MailboxClosed) running = false;
            }

            if (core.terminate_flag.load(.seq_cst)) running = false;
        }
    }
};

fn installWorkerGlobals(ctx: zqjs.Context, core: *WorkerCore, loop: *EventLoop) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    try registerWorkerClass(ctx);
    loop.worker_core = @ptrCast(core);

    try installFn(ctx, js_postMessage, global, "postMessage", "postMessage", 1);
    try installFn(ctx, js_close, global, "close", "close", 0);
    try installFn(ctx, js_importScripts, global, "importScripts", "importScripts", 1);

    // try installFn(ctx, js_fetch.js_fetch, global, "fetch", "fetch", 1);
    try js_fetch_easy.FetchBridge.install(ctx);
    try js_blob.BlobBridge.install(ctx);
    try js_formData.FormDataBridge.install(ctx);
    try js_fs.FSBridge.install(ctx);

    // onmessage
    try ctx.setPropertyStr(global, "onmessage", zqjs.NULL);

    // on error
    const atom = qjs.JS_NewAtom(ctx.ptr, "onerror");
    defer qjs.JS_FreeAtom(ctx.ptr, atom);
    const getter = ctx.newCFunction(js_get_onerror, "get onerror", 0);
    const setter = ctx.newCFunction(js_set_onerror, "set onerror", 1);

    if (qjs.JS_IsException(getter) or qjs.JS_IsException(setter)) {
        ctx.freeValue(getter);
        ctx.freeValue(setter);
        // Discard the exception value, return Zig error
        _ = ctx.throwInternalError("Failed to create onerror accessors");
        return error.OutOfMemory;
    }

    const flags = qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE;
    // !! JS_DefinePropertyGetSet takes ownership of getter/setter JSValues
    const ret = qjs.JS_DefinePropertyGetSet(ctx.ptr, global, atom, getter, setter, @intCast(flags));

    if (ret < 0) {
        _ = ctx.throwInternalError("Failed to define onerror property");
        return error.InitializationFailed;
    }
}

fn fireMessageEvent(ctx: zqjs.Context, data: []const u8, loop: *EventLoop, core: *WorkerCore) !void {
    std.debug.print("[Thread] fireMessageEvent called\n", .{});
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const onmessage = ctx.getPropertyStr(global, "onmessage");
    defer ctx.freeValue(onmessage);

    if (!ctx.isFunction(onmessage)) return;

    const event_obj = ctx.newObject();
    defer ctx.freeValue(event_obj);

    const data_val = ctx.readObject(data, .{});
    if (ctx.isException(data_val)) return;

    // event.data
    try ctx.setPropertyStr(event_obj, "data", data_val);
    const result = ctx.call(
        onmessage,
        global,
        &[_]zqjs.Value{event_obj},
    );
    // const loop = EventLoop.getFromContext(ctx) orelse return error.NotFound;
    // const core_ptr = loop.worker_core orelse return error.NotFound;
    // const core: *WorkerCore = @ptrCast(@alignCast(core_ptr));

    if (ctx.isException(result)) {
        handleException(ctx, loop, core);
    }
    defer ctx.freeValue(result);
}

fn sendError(core: *WorkerCore, error_msg: []const u8) !void {
    const copy = try core.allocator.dupe(u8, error_msg);
    errdefer core.allocator.free(copy);
    try core.outbox.send(.{ .tag = .Error, .data = copy });
}

fn installFn(ctx: zqjs.Context, func: qjs.JSCFunction, obj: zqjs.Value, name: [:0]const u8, prop: [:0]const u8, len: c_int) !void {
    const named_fn = ctx.newCFunction(func, name, len);
    try ctx.setPropertyStr(obj, prop, named_fn);
}

fn js_interrupt_handler(_: ?*qjs.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const ptr = opaque_ptr orelse return 0;
    const core: *WorkerCore = @ptrCast(@alignCast(ptr));
    return if (core.terminate_flag.load(.seq_cst)) 1 else 0;
}

threadlocal var worker_class_id: qjs.JSClassID = 0;

pub const JSWorker = struct {
    core: *WorkerCore,
    ctx: zqjs.Context,
    self_ref: zqjs.Value,
    loop: ?*EventLoop,
    local_thread: std.Thread,

    pub fn create(
        allocator: std.mem.Allocator,
        loop: *EventLoop,
        ctx: zqjs.Context,
        script_path: []const u8,
        sandbox_root: []const u8,
        obj: zqjs.Value,
    ) !*JSWorker {
        std.debug.print("[JSWorker] Create\n", .{});
        const core = try WorkerCore.init(
            allocator,
            script_path,
            sandbox_root,
        );
        errdefer core.release();

        const self = try allocator.create(JSWorker);

        core.retain();
        const thread = try std.Thread.spawn(
            .{},
            WorkerThread.run,
            .{core},
        );
        // thread.detach();
        self.* = .{
            .core = core,
            .ctx = ctx,
            .self_ref = obj,
            .loop = loop,
            .local_thread = thread,
        };

        return self;
    }

    pub fn detachLoop(self: *JSWorker) void {
        self.loop = null;
    }

    pub fn postMessage(self: *JSWorker, data: []const u8) !void {
        const copy = try self.core.allocator.dupe(u8, data);
        errdefer self.core.allocator.free(copy);
        try self.core.inbox.send(.{ .tag = .PostMessage, .data = copy });
    }

    pub fn terminate(self: *JSWorker) void {
        std.debug.print("[JSWorker] Terminate called\n", .{});
        self.core.signalTerminate();

        // Don't free self_ref here - let the finalizer handle it
        // Just unregister from the event loop
        if (self.loop) |l| {
            l.unregisterWorker(self);
            self.loop = null;
        }
    }

    /// main thread polling for messages from worker
    pub fn poll(self: *JSWorker) !void {
        if (self.ctx.isUndefined(self.self_ref)) return;

        const protect = self.ctx.dupValue(self.self_ref);
        defer self.ctx.freeValue(protect);

        while (true) {
            const msg = self.core.outbox.receive(0) catch |err| {
                if (err == error.Timeout) return;
                return err;
            };
            defer self.core.allocator.free(msg.data);

            switch (msg.tag) {
                .PostMessage => {
                    const onmessage = self.ctx.getPropertyStr(self.self_ref, "onmessage");
                    defer self.ctx.freeValue(onmessage);

                    if (!self.ctx.isFunction(onmessage)) continue;

                    const event = self.ctx.newObject();
                    defer self.ctx.freeValue(event);

                    const data_val = self.ctx.readObject(msg.data, .{});
                    if (self.ctx.isException(data_val)) continue;

                    _ = try self.ctx.setPropertyStr(event, "data", data_val);
                    const result = self.ctx.call(onmessage, self.self_ref, &[_]zqjs.Value{event});
                    defer self.ctx.freeValue(result);
                },
                .Error => {
                    const onerror = self.ctx.getPropertyStr(self.self_ref, "onerror");
                    defer self.ctx.freeValue(onerror);

                    if (!self.ctx.isFunction(onerror)) continue;

                    const event = self.ctx.newObject();
                    defer self.ctx.freeValue(event);

                    const msg_val = self.ctx.newString(msg.data);
                    _ = try self.ctx.setPropertyStr(event, "message", msg_val);
                    const result = self.ctx.call(onerror, self.self_ref, &[_]zqjs.Value{event});
                    defer self.ctx.freeValue(result);
                },
                .Terminate => {},
            }
        }
    }

    pub fn destroy(self: *JSWorker) void {
        std.debug.print("[JSWorker] Destroy (Finalizer)\n", .{});
        self.core.signalTerminate();
        self.local_thread.join();
        const alloc = self.core.allocator;
        self.core.release();
        alloc.destroy(self);
    }
};

// the JS engine calls `js_postMessage()`  to push message through the Mailbox
fn js_postMessage(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    std.debug.print("[Worker] js_postMessage called\n", .{});
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("postMessage requires 1 argument");

    // Get WorkerCore from RuntimeContext
    // const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

    const rc = RuntimeContext.get(ctx);
    const core_ptr = rc.worker_core orelse {
        std.debug.print("[Worker] WorkerCore not found in RuntimeContext!\n", .{});
        return ctx.throwInternalError("WorkerCore not found");
    };
    std.debug.print("[Worker] Found rt.WorkerCore with Mailbox...\n", .{});

    const core: *WorkerCore = @ptrCast(@alignCast(core_ptr));

    std.debug.print("[Worker] Serializing message...\n", .{});
    const binary_data = ctx.writeObject(argv[0], .{}) catch |e| {
        std.debug.print("[Worker] writeObject failed: {}\n", .{e});
        return ctx.throwInternalError("Failed to serialize message");
    };
    const copy = core.allocator.dupe(u8, binary_data) catch {
        ctx.free(@ptrCast(binary_data.ptr));
        return ctx.throwOutOfMemory();
    };
    ctx.free(@ptrCast(binary_data.ptr));

    std.debug.print("[Worker] Sending to outbox...\n", .{});
    core.outbox.send(.{ .tag = .PostMessage, .data = copy }) catch {
        core.allocator.free(copy);
        return ctx.throwInternalError("Failed to send message");
    };
    std.debug.print("[Worker] Message sent to outbox\n", .{});
    return zqjs.UNDEFINED;
}

fn js_close(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const core_ptr = loop.worker_core orelse return ctx.throwInternalError("WorkerCore not found");
    const core: *WorkerCore = @ptrCast(@alignCast(core_ptr));

    core.terminate_flag.store(true, .seq_cst);
    std.debug.print("[js_close] Worker requested close.\n", .{});
    return zqjs.UNDEFINED;
}

fn js_importScripts(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("importScripts requires at least one argument");
    const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const core_ptr = loop.worker_core orelse return ctx.throwInternalError("WorkerCore not found");
    const core: *WorkerCore = @ptrCast(@alignCast(core_ptr));

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const path_cstr = ctx.toCString(argv[@intCast(i)]) catch return zqjs.EXCEPTION;
        defer ctx.freeCString(path_cstr);
        const path = std.mem.span(path_cstr);

        const script = std.fs.cwd().readFileAlloc(core.allocator, path, std.math.maxInt(usize)) catch return ctx.throwTypeError("Read file failed");
        defer core.allocator.free(script);

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

    // const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;
    if (loop.active_worker_count.load(.monotonic) >= loop.max_workers) {
        return ctx.throwInternalError("Worker quota exceeded");
    }
    _ = loop.active_worker_count.fetchAdd(1, .monotonic);
    const sandbox_root = rc.sandbox_root;

    const path_cstr = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_cstr);
    const script_path = std.mem.span(path_cstr);

    var proto = ctx.getPropertyStr(new_target, "prototype");
    if (ctx.isException(proto) or ctx.isUndefined(proto)) {
        if (ctx.isException(proto)) _ = ctx.getException();
        proto = ctx.getClassProto(loop.worker_class_id);
    }
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, loop.worker_class_id);
    if (ctx.isException(obj)) return obj;

    const worker = JSWorker.create(
        loop.allocator,
        loop,
        ctx,
        script_path,
        sandbox_root,
        obj,
    ) catch {
        ctx.freeValue(obj);
        return ctx.throwError();
    };

    _ = qjs.JS_SetOpaque(obj, worker);

    loop.registerWorker(worker) catch {
        worker.destroy();
        ctx.freeValue(obj);
        return ctx.throwError();
    };
    return obj;
}

pub fn js_Worker_postMessage(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    std.debug.print("[Main] js_Worker_postMessage called\n", .{});
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("postMessage requires 1 argument");

    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker == null) return ctx.throwTypeError("Not a Worker instance");
    const w: *JSWorker = @ptrCast(@alignCast(worker));

    const binary_data = ctx.writeObject(argv[0], .{}) catch return ctx.throwError();
    const copy = w.core.allocator.dupe(u8, binary_data) catch {
        ctx.free(@ptrCast(binary_data.ptr));
        return ctx.throwOutOfMemory();
    };
    ctx.free(@ptrCast(binary_data.ptr));

    std.debug.print("[Main] Sending message to worker inbox...\n", .{});
    w.core.inbox.send(.{ .tag = .PostMessage, .data = copy }) catch {
        w.core.allocator.free(copy);
        return ctx.throwError();
    };
    std.debug.print("[Main] Message sent to worker inbox\n", .{});
    return zqjs.UNDEFINED;
}

pub fn js_Worker_terminate(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    std.debug.print("[js_Worker_terminate] Called from JS.\n", .{});
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker == null) return ctx.throwTypeError("Not a Worker instance");
    const w: *JSWorker = @ptrCast(@alignCast(worker));
    w.terminate();
    return zqjs.UNDEFINED;
}

fn js_set_onerror(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue, // this ignored
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return zqjs.UNDEFINED;
    const loop = EventLoop.getFromContext(ctx) orelse return zqjs.UNDEFINED;

    // Release old handler if it exists => decr counter
    ctx.freeValue(loop.on_error_handler);

    // !! Retain the new function (Dup adds a ref count). 'val' is borrowed
    loop.on_error_handler = ctx.dupValue(argv[0]);

    return zqjs.UNDEFINED;
}

// Getter
fn js_get_onerror(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    // Get the loop instance (assuming you have a helper for this)
    const loop = EventLoop.getFromContext(ctx) orelse return zqjs.UNDEFINED;

    return ctx.dupValue(loop.on_error_handler);
}

fn workerGCMark(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue, mark_func: ?*const qjs.JS_MarkFunc) callconv(.c) void {
    _ = rt_ptr;
    _ = val;
    _ = mark_func;
}

fn workerFinalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    std.debug.print("[Finalizer] Worker object finalizing.\n", .{});
    const ptr = qjs.JS_GetOpaque(val, worker_class_id);
    if (ptr) |p| {
        const w: *JSWorker = @ptrCast(@alignCast(p));
        if (w.loop) |l| {
            _ = l.active_worker_count.fetchSub(1, .monotonic);
            l.unregisterWorker(w);
        }
        w.destroy();
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
    // defer ctx.freeValue(proto); // <--- the BUG!!!!!
    // because of a transfer of ownership to class prototype so DON'T free 'proto'
    ctx.setClassProto(loop.worker_class_id, proto);

    try installFn(ctx, js_Worker_postMessage, proto, "postMessage", "postMessage", 1);
    try installFn(ctx, js_Worker_terminate, proto, "terminate", "terminate", 0);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const ctor = ctx.newCFunctionConstructor(js_Worker_constructor, "Worker", 1);
    try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
    try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor));
    // ctx.setClassProto(loop.worker_class_id, proto);
    try ctx.setPropertyStr(global, "Worker", ctor);
}

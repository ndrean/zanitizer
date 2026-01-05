//! JavaScript Worker API implementation
//! Provides `new Worker(scriptPath)` with standard Worker API
//!
//! Architecture:
//! - Main thread creates Worker instance (JavaScript object)
//! - Worker instance spawns OS thread with isolated QuickJS runtime
//! - Communication via two mailboxes (main→worker, worker→main)
//! - Events: 'message', 'error', 'messageerror'

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const Mailbox = z.Mailbox;

/// Message types for inter-thread communication
pub const WorkerMessage = struct {
    tag: enum {
        PostMessage, // Data from main thread or worker thread
        Terminate, // Terminate worker thread
        Error, // Error occurred in worker
    },
    data: []u8, // JSON-serialized data or error message
};

/// Worker thread state (lives in worker thread)
pub const WorkerThread = struct {
    allocator: std.mem.Allocator,
    script_path: []const u8,
    inbox: *Mailbox(WorkerMessage), // Messages FROM main thread
    outbox: *Mailbox(WorkerMessage), // Messages TO main thread
    terminate_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn run(self: *WorkerThread) void {
        defer {
            self.allocator.free(self.script_path);
            self.allocator.destroy(self);
        }

        // Setup isolated JavaScript environment
        const rt = zqjs.Runtime.init(self.allocator) catch return;
        defer rt.deinit();

        // Install interrupt handler for graceful termination
        rt.setInterruptHandler(js_interrupt_handler, @ptrCast(self));

        const ctx = zqjs.Context.init(&rt);
        defer ctx.deinit();

        var loop = EventLoop.create(self.allocator, &rt) catch return;
        defer loop.destroy();
        loop.install(ctx) catch return;

        // Install Worker global APIs (postMessage, close)
        self.installWorkerGlobals(ctx) catch return;

        // Load and execute worker script
        const script = self.loadScript() catch |err| {
            self.sendError(@errorName(err)) catch {};
            return;
        };
        defer self.allocator.free(script);

        const result = ctx.eval(script, self.script_path, .{}) catch |err| {
            self.sendError(@errorName(err)) catch {};
            return;
        };
        ctx.freeValue(result);

        // Event loop
        var running = true;
        while (running) {
            // Execute pending JS tasks
            _ = rt.executePendingJob();

            // Process async tasks
            loop.processAsyncTasks() catch {};

            // Process timers and get next deadline
            const next_timer_ms = loop.processTimers() catch null;
            const wait_ms: i64 = next_timer_ms orelse 100;
            const timeout_ns = @as(u64, @intCast(@max(wait_ms, 0))) * std.time.ns_per_ms;

            // Wait for messages from main thread
            if (self.inbox.receive(timeout_ns)) |msg| {
                defer self.allocator.free(msg.data);

                switch (msg.tag) {
                    .PostMessage => {
                        // Fire 'onmessage' event
                        self.fireMessageEvent(ctx, msg.data) catch {};
                    },
                    .Terminate => {
                        running = false;
                    },
                    .Error => {}, // Shouldn't receive this in worker
                }
            } else |err| {
                switch (err) {
                    error.Timeout => {}, // Continue loop
                    error.MailboxClosed => running = false,
                    else => {},
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

        // Store WorkerThread pointer in context opaque
        ctx.setContextOpaque(self);

        // postMessage(data) - Send message to main thread
        const post_message_fn = ctx.newCFunction(js_postMessage, "postMessage", 1);
        _ = try ctx.setPropertyStr(global, "postMessage", post_message_fn);

        // close() - Terminate worker from inside
        const close_fn = ctx.newCFunction(js_close, "close", 0);
        _ = try ctx.setPropertyStr(global, "close", close_fn);
    }

    fn fireMessageEvent(_: *WorkerThread, ctx: zqjs.Context, data: []const u8) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        // Get onmessage handler
        const onmessage = ctx.getPropertyStr(global, "onmessage");
        defer ctx.freeValue(onmessage);

        if (!ctx.isFunction(onmessage)) return;

        // Create event object: { data: <parsed> }
        const event_obj = ctx.newObject();
        defer ctx.freeValue(event_obj);

        // Parse data as JSON
        const data_val = ctx.parseJSON(data, "<message>");
        const is_error = ctx.isException(data_val);

        if (is_error) {
            // Fallback to plain string if JSON parse fails
            const str_val = ctx.newString(data);
            _ = try ctx.setPropertyStr(event_obj, "data", str_val);
        } else {
            defer ctx.freeValue(data_val);
            _ = try ctx.setPropertyStr(event_obj, "data", data_val);
        }

        // Call onmessage(event)
        const result = ctx.call(onmessage, global, &[_]zqjs.Value{event_obj});
        defer ctx.freeValue(result);
    }

    fn sendError(self: *WorkerThread, error_msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, error_msg);
        errdefer self.allocator.free(copy);
        try self.outbox.send(.{ .tag = .Error, .data = copy });
    }
};

/// Interrupt handler for QuickJS runtime (allows graceful termination)
fn js_interrupt_handler(_: ?*qjs.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const ptr = opaque_ptr orelse return 0;
    const self: *WorkerThread = @ptrCast(@alignCast(ptr));
    // Return non-zero to interrupt JS execution
    return if (self.terminate_flag.load(.seq_cst)) 1 else 0;
}

/// JavaScript-side Worker instance (lives in main thread)
pub const JSWorker = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    inbox: Mailbox(WorkerMessage), // Messages FROM worker thread
    outbox: Mailbox(WorkerMessage), // Messages TO worker thread
    worker_thread: *WorkerThread, // Reference to worker thread state

    // Event handlers (stored as JSValue)
    ctx: zqjs.Context,
    onmessage: zqjs.Value,
    onerror: zqjs.Value,

    pub fn create(allocator: std.mem.Allocator, ctx: zqjs.Context, script_path: []const u8) !*JSWorker {
        const self = try allocator.create(JSWorker);
        errdefer allocator.destroy(self);

        // Create worker thread state first
        const worker_thread = try allocator.create(WorkerThread);
        errdefer allocator.destroy(worker_thread);

        self.* = .{
            .allocator = allocator,
            .thread = undefined,
            .inbox = Mailbox(WorkerMessage).init(allocator),
            .outbox = Mailbox(WorkerMessage).init(allocator),
            .worker_thread = worker_thread,
            .ctx = ctx,
            .onmessage = z.jsUndefined,
            .onerror = z.jsUndefined,
        };

        // Duplicate refs for event handlers
        self.onmessage = ctx.dupValue(z.jsUndefined);
        self.onerror = ctx.dupValue(z.jsUndefined);

        // Initialize worker thread state
        worker_thread.* = .{
            .allocator = allocator,
            .script_path = try allocator.dupe(u8, script_path),
            .inbox = &self.outbox, // Worker reads from main's outbox
            .outbox = &self.inbox, // Worker writes to main's inbox
        };

        // Spawn worker thread
        self.thread = try std.Thread.spawn(.{}, WorkerThread.run, .{worker_thread});

        return self;
    }

    pub fn destroy(self: *JSWorker) void {
        // Send terminate message
        self.terminate() catch {};

        // Wait for thread to finish
        self.thread.join();

        // Cleanup
        self.ctx.freeValue(self.onmessage);
        self.ctx.freeValue(self.onerror);
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
        // Set terminate flag to interrupt JS execution
        self.worker_thread.terminate_flag.store(true, .seq_cst);

        // THEN send mailbox message to wake up the thread if it's sleeping
        const empty = try self.allocator.alloc(u8, 0);
        try self.outbox.send(.{ .tag = .Terminate, .data = empty });
    }

    /// Check for messages from worker thread (called from main event loop)
    pub fn poll(self: *JSWorker) !void {
        while (true) {
            // Non-blocking receive
            const msg = self.inbox.receive(0) catch |err| {
                if (err == error.Timeout) return; // No more messages
                return err;
            };
            defer self.allocator.free(msg.data);

            switch (msg.tag) {
                .PostMessage => {
                    if (!self.ctx.isFunction(self.onmessage)) continue;

                    // Create event: { data: <parsed> }
                    const event = self.ctx.newObject();
                    defer self.ctx.freeValue(event);

                    // Parse JSON
                    const data_val = self.ctx.parseJSON(msg.data, "<worker-message>");
                    const is_error = self.ctx.isException(data_val);

                    if (is_error) {
                        const str_val = self.ctx.newString(msg.data);
                        _ = try self.ctx.setPropertyStr(event, "data", str_val);
                    } else {
                        defer self.ctx.freeValue(data_val);
                        _ = try self.ctx.setPropertyStr(event, "data", data_val);
                    }

                    // Call onmessage(event)
                    const result = self.ctx.call(self.onmessage, z.jsUndefined, &[_]zqjs.Value{event});
                    defer self.ctx.freeValue(result);
                },
                .Error => {
                    if (!self.ctx.isFunction(self.onerror)) continue;

                    // Create error event: { message: <error> }
                    const event = self.ctx.newObject();
                    defer self.ctx.freeValue(event);

                    const msg_val = self.ctx.newString(msg.data);
                    defer self.ctx.freeValue(msg_val);

                    _ = try self.ctx.setPropertyStr(event, "message", msg_val);

                    // Call onerror(event)
                    const result = self.ctx.call(self.onerror, z.jsUndefined, &[_]zqjs.Value{event});
                    defer self.ctx.freeValue(result);
                },
                .Terminate => {}, // Shouldn't receive in main thread
            }
        }
    }
};

// ============================================================================
// QuickJS C Functions (Worker thread global API)
// ============================================================================

/// postMessage(data) - Worker thread sends message to main thread
fn js_postMessage(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("postMessage requires 1 argument");

    const worker_thread = ctx.getContextOpaque(WorkerThread) orelse return ctx.throwInternalError("Worker context not found");

    // Serialize data to JSON
    const json_str = ctx.jsonStringifySimple(argv[0]) catch return ctx.throwError("Failed to serialize message");
    defer ctx.freeValue(json_str);

    const json_cstr = ctx.toCString(json_str) catch return z.jsException;
    defer ctx.freeCString(json_cstr);

    const json_slice = std.mem.span(json_cstr);
    const copy = worker_thread.allocator.dupe(u8, json_slice) catch return ctx.throwError("Out of memory");

    worker_thread.outbox.send(.{ .tag = .PostMessage, .data = copy }) catch {
        worker_thread.allocator.free(copy);
        return ctx.throwError("Failed to send message");
    };

    return z.jsUndefined;
}

/// close() - Worker thread terminates itself
fn js_close(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const worker_thread = ctx.getContextOpaque(WorkerThread) orelse return ctx.throwInternalError("Worker context not found");

    const empty = worker_thread.allocator.alloc(u8, 0) catch return ctx.throwError("Out of memory");
    worker_thread.inbox.close();
    worker_thread.allocator.free(empty);

    return z.jsUndefined;
}

// ============================================================================
// QuickJS C Functions (Main thread Worker class)
// ============================================================================

/// new Worker(scriptPath)
pub fn js_Worker_constructor(ctx_ptr: ?*qjs.JSContext, new_target: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("Worker constructor requires scriptPath argument");

    const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");

    // Get script path
    const path_cstr = ctx.toCString(argv[0]) catch return z.jsException;
    defer ctx.freeCString(path_cstr);
    const script_path = std.mem.span(path_cstr);

    // Create Worker instance
    const worker = JSWorker.create(loop.allocator, ctx, script_path) catch return ctx.throwError("Failed to create worker");

    // Create JavaScript object from new_target
    const obj = ctx.newObjectProtoClass(new_target, worker_class_id);
    if (ctx.isException(obj)) {
        worker.destroy();
        return obj;
    }

    // Attach worker pointer as opaque data
    qjs.JS_SetOpaque(obj, worker);

    // Register worker for polling in event loop
    loop.registerWorker(worker) catch {
        ctx.freeValue(obj);
        worker.destroy();
        return ctx.throwError("Failed to register worker");
    };

    return obj;
}

/// worker.postMessage(data)
pub fn js_Worker_postMessage(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("postMessage requires 1 argument");

    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker == null) return ctx.throwTypeError("Not a Worker instance");
    const w: *JSWorker = @ptrCast(@alignCast(worker));

    // Serialize to JSON
    const json_str = ctx.jsonStringifySimple(argv[0]) catch return ctx.throwError("Failed to serialize message");
    defer ctx.freeValue(json_str);

    const json_cstr = ctx.toCString(json_str) catch return z.jsException;
    defer ctx.freeCString(json_cstr);

    w.postMessage(std.mem.span(json_cstr)) catch return ctx.throwError("Failed to send message");

    return z.jsUndefined;
}

/// worker.terminate()
pub fn js_Worker_terminate(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    const worker = qjs.JS_GetOpaque(this, worker_class_id);
    if (worker == null) return ctx.throwTypeError("Not a Worker instance");
    const w: *JSWorker = @ptrCast(@alignCast(worker));

    w.terminate() catch return ctx.throwError("Failed to terminate worker");

    return z.jsUndefined;
}

// ============================================================================
// Class Registration
// ============================================================================

var worker_class_id: qjs.JSClassID = 0;

pub fn registerWorkerClass(ctx: zqjs.Context) !void {
    // Allocate class ID
    qjs.JS_NewClassID(&worker_class_id);

    // Define class
    var class_def = std.mem.zeroes(qjs.JSClassDef);
    class_def.class_name = "Worker";
    class_def.finalizer = workerFinalizer;

    _ = qjs.JS_NewClass(qjs.JS_GetRuntime(ctx.ptr), worker_class_id, &class_def);

    // Create prototype
    const proto = ctx.newObject();
    defer ctx.freeValue(proto);

    // Add methods to prototype
    const postMessage_fn = ctx.newCFunction(js_Worker_postMessage, "postMessage", 1);
    _ = try ctx.setPropertyStr(proto, "postMessage", postMessage_fn);

    const terminate_fn = ctx.newCFunction(js_Worker_terminate, "terminate", 0);
    _ = try ctx.setPropertyStr(proto, "terminate", terminate_fn);

    // Set class prototype
    qjs.JS_SetClassProto(ctx.ptr, worker_class_id, proto);

    // Create constructor
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const ctor = ctx.newCFunctionConstructor(js_Worker_constructor, "Worker", 1);
    _ = try ctx.setPropertyStr(global, "Worker", ctor);
}

fn workerFinalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    _ = rt;
    const worker = qjs.JS_GetOpaque(val, worker_class_id);
    if (worker) |w| {
        const worker_ptr: *JSWorker = @ptrCast(@alignCast(w));
        worker_ptr.destroy();
    }
}

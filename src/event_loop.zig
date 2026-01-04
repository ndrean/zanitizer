const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const utils = @import("utils.zig");

// Unique Class ID to safely store the *EventLoop pointer
var event_loop_class_id: zqjs.ClassID = 0;

pub const RunMode = enum {
    Script, // Exit when task queues are empty (Test/Batch mode)
    Server, // Run forever until should_exit is set (Long-running)
};

const Timer = struct {
    id: i32,
    ctx: zqjs.Context, // Keep wrapper context
    callback: zqjs.Value,
    interval_ms: i64,
    next_fire_time: i64,
    is_interval: bool,
    is_cancelled: bool = false,
};

// Async task result from worker threads (fetch, file I/O, etc.)
pub const AsyncTask = struct {
    ctx: zqjs.Context,
    resolve: zqjs.Value,
    reject: zqjs.Value,
    result: TaskResult,

    pub const TaskResult = union(enum) {
        success: []u8, // Response body (owned, must be freed)
        failure: []u8, // Error message (owned, must be freed)
    };
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    rt: *zqjs.Runtime,
    thread_pool: std.Thread.Pool,
    mutex: std.Thread.Mutex = .{},
    task_queue: std.ArrayList(AsyncTask),
    task_cond: std.Thread.Condition = .{},
    timers: std.ArrayList(Timer),
    next_timer_id: i32 = 1,
    should_exit: bool = false,
    external_quit_flag: ?*std.atomic.Value(bool) = null,

    pub fn create(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !*EventLoop {
        // allocate on the HEAP!!!!!
        const self = try allocator.create(EventLoop);

        self.* = .{
            .allocator = allocator,
            .rt = rt,
            .timers = .{},
            .task_queue = .{},
            .thread_pool = undefined,
        };

        try self.thread_pool.init(.{ .allocator = allocator });

        return self;
    }

    pub fn linkSignalFlag(self: *EventLoop, flag: *std.atomic.Value(bool)) void {
        self.external_quit_flag = flag;
    }

    /// Safe retrieval helper from context
    pub fn getFromContext(ctx: zqjs.Context) ?*EventLoop {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const loop_ref = ctx.getPropertyStr(global, "__native_event_loop__");
        defer ctx.freeValue(loop_ref);

        if (ctx.isUndefined(loop_ref)) return null;

        const ptr = ctx.getOpaque2(loop_ref, event_loop_class_id);
        if (ptr) |p| {
            return @ptrCast(@alignCast(p));
        }
        return null;
    }

    pub fn destroy(self: *EventLoop) void {
        // Deinit thread pool first (waits for tasks to complete)
        self.thread_pool.deinit();

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Clean up timers (each timer holds its own context reference)
            for (self.timers.items) |timer| {
                timer.ctx.freeValue(timer.callback);
            }
            self.timers.deinit(self.allocator);

            // Clean up pending async tasks (each task holds its own context reference)
            for (self.task_queue.items) |task| {
                task.ctx.freeValue(task.resolve);
                task.ctx.freeValue(task.reject);
                switch (task.result) {
                    .success => |data| self.allocator.free(data),
                    .failure => |msg| self.allocator.free(msg),
                }
            }
            self.task_queue.deinit(self.allocator);
        }
        self.allocator.destroy(self);
    }

    pub fn install(self: *EventLoop, ctx: zqjs.Context) !void {
        // A. Register class once (if needed)
        if (event_loop_class_id == 0) {
            event_loop_class_id = self.rt.newClassID();
            try self.rt.newClass(
                event_loop_class_id,
                .{
                    .class_name = "EventLoop",
                    .finalizer = null,
                },
            );
        }

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        // B. Create a hidden object holding our pointeranad set it to Global
        const loop_ref = ctx.newObjectClass(event_loop_class_id);
        try ctx.setOpaque(loop_ref, self);
        _ = try ctx.setPropertyStr(
            global,
            "__native_event_loop__",
            loop_ref,
        );

        // Install timer APIs
        const set_timeout_fn = ctx.newCFunction(js_setTimeout, "setTimeout", 2);
        _ = try ctx.setPropertyStr(global, "setTimeout", set_timeout_fn);

        const set_interval_fn = ctx.newCFunction(js_setInterval, "setInterval", 2);
        _ = try ctx.setPropertyStr(global, "setInterval", set_interval_fn);

        const clear_timeout_fn = ctx.newCFunction(js_clearTimeout, "clearTimeout", 1);
        _ = try ctx.setPropertyStr(global, "clearTimeout", clear_timeout_fn);

        const clear_interval_fn = ctx.newCFunction(js_clearTimeout, "clearInterval", 1);
        _ = try ctx.setPropertyStr(global, "clearInterval", clear_interval_fn);

        // Install console (for convenience in testing/standalone event loop usage)
        const console_obj = ctx.newObject();
        const log_fn = ctx.newCFunction(utils.js_consoleLog, "log", 1);
        _ = try ctx.setPropertyStr(console_obj, "log", log_fn);
        const error_fn = ctx.newCFunction(utils.js_consoleLog, "error", 1);
        _ = try ctx.setPropertyStr(console_obj, "error", error_fn);
        _ = try ctx.setPropertyStr(global, "console", console_obj);

        // Install fetch API
        const fetch_fn = ctx.newCFunction(utils.js_fetch, "fetch", 1);
        _ = try ctx.setPropertyStr(global, "fetch", fetch_fn);
    }

    fn addTimer(self: *EventLoop, ctx: zqjs.Context, callback: zqjs.Value, delay_ms: i64, is_interval: bool) !i32 {
        const now = std.time.milliTimestamp();
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const callback_dup = ctx.dupValue(callback);
        try self.timers.append(self.allocator, Timer{
            .id = timer_id,
            .ctx = ctx, // Store the context where this timer was created
            .callback = callback_dup,
            .interval_ms = delay_ms,
            .next_fire_time = now + delay_ms,
            .is_interval = is_interval,
        });
        return timer_id;
    }

    fn cancelTimer(self: *EventLoop, timer_id: i32) void {
        for (self.timers.items) |*timer| {
            if (timer.id == timer_id and !timer.is_cancelled) {
                timer.is_cancelled = true;
                break;
            }
        }
    }

    /// Called by worker threads to enqueue async results
    /// Thread-safe: can be called from any thread
    pub fn enqueueTask(self: *EventLoop, task: AsyncTask) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.task_queue.append(self.allocator, task) catch |err| {
            // If append fails, clean up to prevent leaks
            task.ctx.freeValue(task.resolve);
            task.ctx.freeValue(task.reject);
            switch (task.result) {
                .success => |data| self.allocator.free(data),
                .failure => |msg| self.allocator.free(msg),
            }
            z.print("ERROR: Failed to enqueue async task: {}\n", .{err});
            return;
        };

        // Wake up the event loop
        self.task_cond.signal();
    }

    /// Process all pending async tasks from worker threads
    /// Returns number of tasks processed
    fn processAsyncTasks(self: *EventLoop) bool {
        self.mutex.lock();
        if (self.task_queue.items.len == 0) {
            self.mutex.unlock();
            return false; // nothing to do
        }

        // Steal all tasks to process outside the lock
        const tasks = self.task_queue.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return false;
        };
        self.mutex.unlock();

        const count = tasks.len;
        for (tasks) |task| {
            // Free the JS function references we held
            defer task.ctx.freeValue(task.resolve);
            defer task.ctx.freeValue(task.reject);

            switch (task.result) {
                .success => |data| {
                    defer self.allocator.free(data);

                    // Create JS string from response
                    const js_str = task.ctx.newString(data);
                    defer task.ctx.freeValue(js_str);

                    // Call resolve(response)
                    const ret = task.ctx.call(
                        task.resolve,
                        zqjs.UNDEFINED,
                        &[_]zqjs.Value{js_str},
                    );
                    task.ctx.freeValue(ret);
                },
                .failure => |msg| {
                    defer self.allocator.free(msg);

                    // Create JS error
                    const js_err = task.ctx.newString(msg);
                    defer task.ctx.freeValue(js_err);

                    // Call reject(error)
                    const ret = task.ctx.call(
                        task.reject,
                        zqjs.UNDEFINED,
                        &[_]zqjs.Value{js_err},
                    );
                    task.ctx.freeValue(ret);
                },
            }
        }
        self.allocator.free(tasks);
        return (count > 0); // we did some work
    }

    /// Main event loop processing
    pub fn run(self: *EventLoop, mode: RunMode) !void {
        // const rt = self.rt;
        while (!self.should_exit) {

            // 0. Check Signal Flag (Ctrl+C)
            if (self.external_quit_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    // Signal received! Break the loop safely.
                    break;
                }
            }
            // flush pre-existing microtasks
            while (try self.rt.executePendingJob() != null) {}
            // check Timers
            const next_timeout = try self.processTimers();

            // Process Async I/O (Worker threads)
            const did_async_work = self.processAsyncTasks();

            // Flush new microtasks created by I/O
            while ((try self.rt.executePendingJob()) != null) {}

            // 5. AUTO-EXIT CHECK (Only for Script Mode)
            if (mode == .Script) {
                var queue_empty = false;
                {
                    self.mutex.lock();
                    queue_empty = (self.task_queue.items.len == 0);
                    self.mutex.unlock();
                }
                if (self.timers.items.len == 0 and !did_async_work and queue_empty) {
                    break;
                }
            }

            if (!did_async_work and next_timeout > 0) {
                const wait_cap: usize = if (mode == .Server) 50 else 10;
                const sleep_ns = @min(next_timeout, wait_cap) * 1_000_000;
                std.Thread.sleep(@intCast(sleep_ns));
            }
        }
    }

    fn processTimers(self: *EventLoop) !i64 {
        const now = std.time.milliTimestamp();
        var min_wait: i64 = 1000;

        var i: usize = 0;
        while (i < self.timers.items.len) {
            // check cancelation
            if (self.timers.items[i].is_cancelled) {
                self.timers.items[i].ctx.freeValue(self.timers.items[i].callback);
                _ = self.timers.swapRemove(i);
                continue;
            }

            const next_fire_time = self.timers.items[i].next_fire_time;
            // check time
            if (now >= next_fire_time) {
                // copy to stack before calling JS
                const ctx = self.timers.items[i].ctx;
                const callback = self.timers.items[i].callback;
                const is_interval = self.timers.items[i].is_interval;
                const interval = self.timers.items[i].interval_ms;

                const global = ctx.getGlobalObject();
                const ret = ctx.call(
                    callback,
                    global,
                    &.{},
                );
                ctx.freeValue(global);

                if (ctx.isException(ret)) {
                    _ = ctx.checkAndPrintException();
                }
                ctx.freeValue(ret);

                // re-evaluate: check if timer canceled during callback
                if (is_interval and !self.timers.items[i].is_cancelled) {
                    self.timers.items[i].next_fire_time = now + interval;
                    min_wait = @min(min_wait, interval);
                    i += 1;
                } else {
                    ctx.freeValue(callback);
                    _ = self.timers.swapRemove(i);
                }
                // if (ctx.isException(ret)) {
                //     _ = ctx.checkAndPrintException();
                // }
                // ctx.freeValue(ret);

                // if (timer.is_interval) {
                //     timer.next_fire_time = now + timer.interval_ms;
                //     min_wait = @min(min_wait, timer.interval_ms);
                //     i += 1;
                // } else {
                //     timer.ctx.freeValue(timer.callback);
                //     _ = self.timers.swapRemove(i);

            } else {
                min_wait = @min(min_wait, next_fire_time - now);
                i += 1;
            }
        }

        return min_wait;
    }

    /// Spawn a worker task on the thread pool and pass data Zig -> QJS
    ///
    /// The data passed in task_data is copied to the worker function
    /// The worker_fn should call enqueueTask() when done
    pub fn spawnWorker(
        self: *EventLoop,
        comptime worker_fn: anytype,
        task_data: anytype,
    ) !void {
        try self.thread_pool.spawn(worker_fn, .{task_data});
    }
};

fn js_setTimeout(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return zqjs.EXCEPTION;

    const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const callback = argv[0];
    if (!ctx.isFunction(callback)) return ctx.throwTypeError("Callback must be a function");

    var interval: i32 = 0;
    if (qjs.JS_ToInt32(ctx.ptr, &interval, argv[1]) != 0) return zqjs.EXCEPTION;
    if (interval < 0) interval = 0;

    const id = loop.addTimer(
        ctx,
        callback,
        interval,
        false,
    ) catch return ctx.throwInternalError("Failed to add timer");
    return ctx.newInt32(id);
}

fn js_setInterval(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return zqjs.EXCEPTION;

    const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");
    const callback = argv[0];
    if (!ctx.isFunction(callback)) return ctx.throwTypeError("Callback must be a function");

    var interval: i32 = 0;
    if (qjs.JS_ToInt32(ctx.ptr, &interval, argv[1]) != 0) return zqjs.EXCEPTION;
    if (interval < 0) interval = 0;

    const id = loop.addTimer(
        ctx,
        callback,
        interval,
        true,
    ) catch return ctx.throwInternalError("Failed to add timer");
    return ctx.newInt32(id);
}

fn js_clearTimeout(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return zqjs.UNDEFINED;
    const loop = EventLoop.getFromContext(ctx) orelse return zqjs.UNDEFINED;

    var id: i32 = 0;
    if (qjs.JS_ToInt32(ctx.ptr, &id, argv[0]) == 0) loop.cancelTimer(id);
    return zqjs.UNDEFINED;
}

// fn js_consoleLog(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
//     var i: c_int = 0;
//     while (i < argc) : (i += 1) {
//         const str = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
//         if (str != null) {
//             defer qjs.JS_FreeCString(ctx, str);
//             if (i > 0) z.print(" ", .{});
//             z.print("{s}", .{str});
//         }
//     }
//     z.print("\n", .{});
//     return zqjs.UNDEFINED;
// }

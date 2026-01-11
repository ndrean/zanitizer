const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const utils = z.utils;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
// [FIX] Disabled because generated bindings use global state (not thread-safe).
// We use manual bindings for Timers below instead.
const AsyncBindings = @import("async_bindings_generated.zig");
const JSWorker = @import("js_worker.zig").JSWorker;

// threadlocal var event_loop_class_id: zqjs.ClassID = 0;

pub const RunMode = enum {
    Script,
    Server,
};

const Timer = struct {
    id: i32,
    ctx: zqjs.Context,
    callback: zqjs.Value,
    interval_ms: i64,
    next_fire_time: i64,
    is_interval: bool,
    is_cancelled: bool = false,
};

pub const AsyncTask = struct {
    ctx: zqjs.Context,
    resolve: zqjs.Value,
    reject: zqjs.Value,
    result: TaskResult,

    pub const TaskResult = union(enum) {
        success_utf8: []u8,
        success_bin: []u8,
        failure: []u8,
        custom: struct {
            data: *anyopaque,
            callback: *const fn (ctx: zqjs.Context, data: *anyopaque) void,
            destroy: *const fn (allocator: std.mem.Allocator, data: *anyopaque) void,
        },
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
    active_tasks: usize = 0,
    external_quit_flag: ?*std.atomic.Value(bool) = null,
    workers: std.ArrayList(*JSWorker) = .{},
    worker_class_id: zqjs.ClassID = 0,
    worker_core: ?*anyopaque = null,

    pub fn create(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !*EventLoop {
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

    pub fn getFromContext(ctx: zqjs.Context) ?*EventLoop {
        const rc = RuntimeContext.get(ctx);
        const class_id = rc.classes.event_loop;
        if (class_id == 0) return null;

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const loop_ref = ctx.getPropertyStr(global, "__native_event_loop__");
        defer ctx.freeValue(loop_ref);

        if (ctx.isUndefined(loop_ref)) return null;

        const ptr = ctx.getOpaque2(loop_ref, class_id);
        if (ptr) |p| return @ptrCast(@alignCast(p));
        return null;
    }

    pub fn destroy(self: *EventLoop) void {
        self.thread_pool.deinit();
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.workers.items) |w| w.detachLoop();
            for (self.timers.items) |timer| timer.ctx.freeValue(timer.callback);
            self.timers.deinit(self.allocator);
            for (self.task_queue.items) |task| {
                task.ctx.freeValue(task.resolve);
                task.ctx.freeValue(task.reject);
                switch (task.result) {
                    .success_utf8 => |data| self.allocator.free(data),
                    .success_bin => |data| self.allocator.free(data),
                    .failure => |msg| self.allocator.free(msg),
                    .custom => |payload| {
                        payload.destroy(self.allocator, payload.data);
                    },
                }
            }
            self.task_queue.deinit(self.allocator);
            self.workers.deinit(self.allocator);
        }
        self.allocator.destroy(self);
    }

    pub fn registerWorker(self: *EventLoop, worker: *JSWorker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.workers.append(self.allocator, worker);
    }

    pub fn unregisterWorker(self: *EventLoop, worker: *JSWorker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.workers.items, 0..) |w, i| {
            if (w == worker) {
                _ = self.workers.swapRemove(i);
                break;
            }
        }
    }

    pub fn install(self: *EventLoop, ctx: zqjs.Context) !void {
        const rc = RuntimeContext.get(ctx);
        // var class_id = rc.classes.event_loop;
        if (rc.classes.event_loop == 0) {
            rc.classes.event_loop = self.rt.newClassID();
            try self.rt.newClass(rc.classes.event_loop, .{ .class_name = "EventLoop", .finalizer = null });
        }

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const loop_ref = ctx.newObjectClass(rc.classes.event_loop);
        try ctx.setOpaque(loop_ref, self);
        _ = try ctx.setPropertyStr(global, "__native_event_loop__", loop_ref);

        // Install Console Object
        const console_obj = ctx.newObject();
        const log_fn = ctx.newCFunction(utils.js_consoleLog, "log", 1);
        _ = try ctx.setPropertyStr(console_obj, "log", log_fn);

        const error_fn = ctx.newCFunction(utils.js_consoleLog, "error", 1);
        _ = try ctx.setPropertyStr(console_obj, "error", error_fn);
        _ = try ctx.setPropertyStr(global, "console", console_obj);

        // Install Manual Timers
        try utils.installFn(ctx, js_setTimeout, global, "setTimeout", "setTimeout", 2);
        try utils.installFn(ctx, js_setInterval, global, "setInterval", "setInterval", 2);
        try utils.installFn(ctx, js_clearTimer, global, "clearTimeout", "clearTimeout", 1);
        try installFn(ctx, js_clearTimer, global, "clearInterval", "clearInterval", 1);

        try AsyncBindings.installAllBindings(ctx, global);
    }

    pub fn addTimer(self: *EventLoop, ctx: zqjs.Context, callback: zqjs.Value, delay_ms: i64, is_interval: bool) !i32 {
        const now = std.time.milliTimestamp();
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;
        const callback_dup = ctx.dupValue(callback);
        try self.timers.append(self.allocator, Timer{
            .id = timer_id,
            .ctx = ctx,
            .callback = callback_dup,
            .interval_ms = delay_ms,
            .next_fire_time = now + delay_ms,
            .is_interval = is_interval,
        });
        return timer_id;
    }

    pub fn cancelTimer(self: *EventLoop, timer_id: i32) void {
        for (self.timers.items) |*timer| {
            if (timer.id == timer_id and !timer.is_cancelled) {
                timer.is_cancelled = true;
                break;
            }
        }
    }

    pub fn enqueueTask(self: *EventLoop, task: AsyncTask) void {
        std.debug.print("[EvtLoop] Enqueuing task\n", .{});
        self.mutex.lock();
        defer self.mutex.unlock();
        self.task_queue.append(self.allocator, task) catch {
            task.ctx.freeValue(task.resolve);
            task.ctx.freeValue(task.reject);
            switch (task.result) {
                .success_utf8 => |data| self.allocator.free(data),
                .success_bin => |data| self.allocator.free(data),
                .failure => |msg| self.allocator.free(msg),
                .custom => |payload| {
                    payload.destroy(self.allocator, payload.data);
                },
            }
            return;
        };
        self.task_cond.signal();
    }

    pub fn processAsyncTasks(self: *EventLoop) bool {
        self.mutex.lock();
        const count = self.task_queue.items.len;
        // std.debug.print("[EvtLoop] Processing async tasks: {d}\n", .{count});
        if (count == 0) {
            self.mutex.unlock();
            return false;
        }
        const tasks = self.task_queue.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return false;
        };
        if (self.active_tasks >= count) self.active_tasks -= count else self.active_tasks = 0;
        self.mutex.unlock();

        for (tasks) |task| {
            defer task.ctx.freeValue(task.resolve);
            defer task.ctx.freeValue(task.reject);
            switch (task.result) {
                .custom => |payload| {
                    // execute the function pointer stored in the task
                    payload.callback(task.ctx, payload.data);
                },
                .success_utf8 => |data| {
                    defer self.allocator.free(data);
                    const js_str = task.ctx.newString(data);
                    defer task.ctx.freeValue(js_str);
                    const ret = task.ctx.call(task.resolve, zqjs.UNDEFINED, &[_]zqjs.Value{js_str});
                    task.ctx.freeValue(ret);
                },
                .success_bin => |data| {
                    defer self.allocator.free(data);
                    // Create ArrayBuffer (Copies data into JS memory)
                    const js_ab = task.ctx.newArrayBufferCopy(data);
                    // Note: If you want a Uint8Array, you would wrap it here,
                    // but returning ArrayBuffer is standard.
                    defer task.ctx.freeValue(js_ab);

                    const ret = task.ctx.call(task.resolve, zqjs.UNDEFINED, &[_]zqjs.Value{js_ab});
                    task.ctx.freeValue(ret);
                },
                .failure => |msg| {
                    defer self.allocator.free(msg);
                    const js_err = task.ctx.newString(msg);
                    defer task.ctx.freeValue(js_err);
                    const ret = task.ctx.call(task.reject, zqjs.UNDEFINED, &[_]zqjs.Value{js_err});
                    task.ctx.freeValue(ret);
                },
            }
        }
        self.allocator.free(tasks);
        return (count > 0);
    }

    pub fn pollWorkers(self: *EventLoop) !void {
        self.mutex.lock();
        const workers_copy = try self.allocator.dupe(*JSWorker, self.workers.items);
        self.mutex.unlock();
        defer self.allocator.free(workers_copy);
        for (workers_copy) |worker| try worker.poll();
    }

    pub fn run(self: *EventLoop, mode: RunMode) !void {
        while (!self.should_exit) {
            // 1. Check External Signal
            if (self.external_quit_flag) |flag| {
                if (flag.load(.seq_cst)) break;
            }

            // 2. DRAIN MICROTASKS (Promises)
            // Execute all pending jobs before touching timers or sleeping.
            // This ensures "Promise.resolve().then(...)" runs immediately.
            while (true) {
                const ctx_ptr = try self.rt.executePendingJob();
                if (ctx_ptr == null) break;
            }

            // 3. EXIT CHECK
            // We only check for exit after draining jobs.
            if (mode == .Script) {
                self.mutex.lock();
                const queue_empty = (self.task_queue.items.len == 0);
                _ = self.active_tasks; // Access check
                self.mutex.unlock();

                const has_workers = (self.workers.items.len > 0);
                const has_timers = (self.timers.items.len > 0);
                // [CRITICAL] Check isJobPending to avoid quitting if a Promise just queued another Promise
                const has_jobs = self.rt.isJobPending();

                // if the last timer in the system created a Promise, the loop would see timers.len == 0 and exit immediately, killing the pending Promise before it could run
                if (!has_timers and queue_empty and self.active_tasks == 0 and !has_workers and !has_jobs) {
                    break;
                }
            }

            // 4. Run Macrotasks (Timers & Worker Results)
            // Note: processTimers now returns 0 immediately if it fires a timer,
            // forcing us to loop back to Step 2 to handle any new Microtasks.
            const next_timeout = try self.processTimers();
            const did_async_work = self.processAsyncTasks();
            self.pollWorkers() catch {};

            // 5. Sleep (Avoid CPU Spin)
            if (!did_async_work and next_timeout > 0) {
                // If we have pending jobs now (rare, but possible if pollWorkers queued one),
                // don't sleep!
                if (self.rt.isJobPending()) continue;

                const wait_cap: usize = if (mode == .Server) 50 else 10;
                const sleep_ns = @min(next_timeout, wait_cap) * 1_000_000;
                std.Thread.sleep(@intCast(sleep_ns));
            }
        }
    }

    pub fn processTimers(self: *EventLoop) !i64 {
        const now = std.time.milliTimestamp();
        var min_wait: i64 = 1000;
        var i: usize = 0;

        // We iterate, but we will BREAK/RETURN after the first execution
        while (i < self.timers.items.len) {
            // ... [Keep cancellation check logic same as source: 98] ...
            if (self.timers.items[i].is_cancelled) {
                self.timers.items[i].ctx.freeValue(self.timers.items[i].callback);
                _ = self.timers.swapRemove(i);
                continue;
            }

            const next_fire_time = self.timers.items[i].next_fire_time;

            if (now >= next_fire_time) {
                // --- FIRE TIMER ---
                const ctx = self.timers.items[i].ctx;
                const callback = self.timers.items[i].callback;
                const is_interval = self.timers.items[i].is_interval;
                const interval = self.timers.items[i].interval_ms;
                const global = ctx.getGlobalObject();

                // Call JS
                const ret = ctx.call(callback, global, &.{});

                // Cleanup
                ctx.freeValue(global);
                if (ctx.isException(ret)) _ = ctx.checkAndPrintException();
                ctx.freeValue(ret);

                // Update/Remove Timer
                if (is_interval and !self.timers.items[i].is_cancelled) {
                    self.timers.items[i].next_fire_time = now + interval;
                    // We don't need to update min_wait here because we return immediately
                } else {
                    ctx.freeValue(callback);
                    _ = self.timers.swapRemove(i);
                }

                // [CRITICAL FIX] Return 0 immediately!
                // This forces the Event Loop to go back to 'run()',
                // allowing 'executePendingJob' (Microtasks) to run BEFORE the next timer.
                return 0;
            } else {
                min_wait = @min(min_wait, next_fire_time - now);
                i += 1;
            }
        }
        return min_wait;
    }

    pub fn spawnWorker(self: *EventLoop, comptime worker_fn: anytype, task_data: anytype) !void {
        std.debug.print("[EvtLoop] Spawning worker task\n", .{});
        try self.thread_pool.spawn(worker_fn, .{task_data});
        self.mutex.lock();
        self.active_tasks += 1;
        self.mutex.unlock();
    }
};

// --- Timer C Functions ---

pub fn installFn(ctx: zqjs.Context, func: qjs.JSCFunction, obj: zqjs.Value, name: [:0]const u8, prop: [:0]const u8, len: c_int) !void {
    const named_fn = ctx.newCFunction(func, name, len);
    _ = try ctx.setPropertyStr(obj, prop, named_fn);
}

pub fn js_setTimeout(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return ctx.throwTypeError("setTimeout requires 2 arguments");

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    var delay: i64 = 0;
    _ = qjs.JS_ToInt64(ctx_ptr, &delay, argv[1]);
    const id = loop.addTimer(ctx, argv[0], delay, false) catch return ctx.throwOutOfMemory();
    return ctx.newInt32(id);
}

pub fn js_setInterval(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 2) return ctx.throwTypeError("setInterval requires 2 arguments");

    // [FIX] Use RuntimeContext
    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    var delay: i64 = 0;
    _ = qjs.JS_ToInt64(ctx_ptr, &delay, argv[1]);
    const id = loop.addTimer(ctx, argv[0], delay, true) catch return ctx.throwOutOfMemory();
    return ctx.newInt32(id);
}

pub fn js_clearTimer(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return zqjs.UNDEFINED;

    // [FIX] Use RuntimeContext
    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    var id: i32 = 0;
    _ = qjs.JS_ToInt32(ctx_ptr, &id, argv[0]);
    loop.cancelTimer(id);
    return zqjs.UNDEFINED;
}

fn js_reportResult(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = z.wrapper.Context{ .ptr = ctx_ptr };
    if (argc < 1) return z.wrapper.UNDEFINED;

    // Duplicate the value so it survives after this function returns
    return ctx.dupValue(argv[0]);
}

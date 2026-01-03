const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;

const Timer = struct {
    id: u32,
    ctx: ?*qjs.JSContext, // Context where this timer was created
    callback: qjs.JSValue,
    interval_ms: u64,
    next_fire_time: i64,
    is_interval: bool,
    is_cancelled: bool = false,
};

// Async task result from worker threads (fetch, file I/O, etc.)
pub const AsyncTask = struct {
    ctx: ?*qjs.JSContext,
    resolve: qjs.JSValue,
    reject: qjs.JSValue,
    result: TaskResult,

    pub const TaskResult = union(enum) {
        success: []u8, // Response body (owned, must be freed)
        failure: []u8, // Error message (owned, must be freed)
    };
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    rt: ?*qjs.JSRuntime,
    mutex: std.Thread.Mutex = .{},
    task_queue: std.ArrayList(AsyncTask),
    task_cond: std.Thread.Condition = .{},
    timers: std.ArrayList(Timer),
    next_timer_id: u32 = 1,
    should_exit: bool = false,

    pub fn init(allocator: std.mem.Allocator, rt: ?*qjs.JSRuntime) !EventLoop {
        return .{
            .allocator = allocator,
            .rt = rt,
            .timers = .{},
            .task_queue = .{},
        };
    }

    /// Borrow the global EventLoop from Runtime opaque pointer
    pub fn from(rt: ?*qjs.JSRuntime) *EventLoop {
        const ptr = qjs.JS_GetRuntimeOpaque(rt);
        return @ptrCast(@alignCast(ptr));
    }

    pub fn deinit(self: *EventLoop) void {
        // Clean up timers (each timer holds its own context reference)
        for (self.timers.items) |timer| {
            qjs.JS_FreeValue(timer.ctx, timer.callback);
        }
        self.timers.deinit(self.allocator);

        // Clean up pending async tasks (each task holds its own context reference)
        for (self.task_queue.items) |task| {
            qjs.JS_FreeValue(task.ctx, task.resolve);
            qjs.JS_FreeValue(task.ctx, task.reject);
            switch (task.result) {
                .success => |data| self.allocator.free(data),
                .failure => |msg| self.allocator.free(msg),
            }
        }
        self.task_queue.deinit(self.allocator);
    }

    pub fn installTimerAPIs(self: *EventLoop, ctx: ?*qjs.JSContext) !void {
        const rt = self.rt;
        const global = qjs.JS_GetGlobalObject(ctx);
        defer qjs.JS_FreeValue(ctx, global);

        qjs.JS_SetRuntimeOpaque(rt, @ptrCast(self));

        const set_timeout_fn = qjs.JS_NewCFunction2(ctx, js_setTimeout, "setTimeout", 2, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_SetPropertyStr(ctx, global, "setTimeout", set_timeout_fn);

        const set_interval_fn = qjs.JS_NewCFunction2(ctx, js_setInterval, "setInterval", 2, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_SetPropertyStr(ctx, global, "setInterval", set_interval_fn);

        const clear_timeout_fn = qjs.JS_NewCFunction2(ctx, js_clearTimeout, "clearTimeout", 1, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_SetPropertyStr(ctx, global, "clearTimeout", clear_timeout_fn);

        const clear_interval_fn = qjs.JS_NewCFunction2(ctx, js_clearTimeout, "clearInterval", 1, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_SetPropertyStr(ctx, global, "clearInterval", clear_interval_fn);

        // Install console (for convenience in testing/standalone event loop usage)
        const console_obj = qjs.JS_NewObject(ctx);
        const log_fn = qjs.JS_NewCFunction2(ctx, js_consoleLog, "log", 1, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_SetPropertyStr(ctx, console_obj, "log", log_fn);
        const error_fn = qjs.JS_NewCFunction2(ctx, js_consoleLog, "error", 1, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_SetPropertyStr(ctx, console_obj, "error", error_fn);
        _ = qjs.JS_SetPropertyStr(ctx, global, "console", console_obj);
    }

    fn addTimer(self: *EventLoop, ctx: ?*qjs.JSContext, callback: qjs.JSValue, delay_ms: u64, is_interval: bool) !u32 {
        const now = std.time.milliTimestamp();
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const callback_dup = qjs.JS_DupValue(ctx, callback);
        try self.timers.append(self.allocator, Timer{
            .id = timer_id,
            .ctx = ctx, // Store the context where this timer was created
            .callback = callback_dup,
            .interval_ms = delay_ms,
            .next_fire_time = now + @as(i64, @intCast(delay_ms)),
            .is_interval = is_interval,
        });
        return timer_id;
    }

    fn cancelTimer(self: *EventLoop, timer_id: u32) void {
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
            qjs.JS_FreeValue(task.ctx, task.resolve);
            qjs.JS_FreeValue(task.ctx, task.reject);
            switch (task.result) {
                .success => |data| self.allocator.free(data),
                .failure => |msg| self.allocator.free(msg),
            }
            z.print("ERROR: Failed to enqueue async task: {}\n", .{err});
            return;
        };

        // Wake up the event loop (no more 5ms sleep!)
        self.task_cond.signal();
    }

    /// Process all pending async tasks from worker threads
    /// Returns number of tasks processed
    fn processAsyncTasks(self: *EventLoop) usize {
        self.mutex.lock();
        if (self.task_queue.items.len == 0) {
            self.mutex.unlock();
            return 0;
        }

        // Steal all tasks to process outside the lock
        const tasks = self.task_queue.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return 0;
        };
        self.mutex.unlock();

        const count = tasks.len;
        for (tasks) |task| {
            defer qjs.JS_FreeValue(task.ctx, task.resolve);
            defer qjs.JS_FreeValue(task.ctx, task.reject);

            switch (task.result) {
                .success => |data| {
                    defer self.allocator.free(data);

                    // Create JS string from response
                    const js_str = qjs.JS_NewStringLen(task.ctx, data.ptr, data.len);
                    defer qjs.JS_FreeValue(task.ctx, js_str);

                    // Call resolve(response)
                    var args = [_]qjs.JSValue{js_str};
                    const ret = qjs.JS_Call(task.ctx, task.resolve, z.jsUndefined, 1, &args);
                    qjs.JS_FreeValue(task.ctx, ret);
                },
                .failure => |msg| {
                    defer self.allocator.free(msg);

                    // Create JS error
                    const js_err = qjs.JS_NewStringLen(task.ctx, msg.ptr, msg.len);
                    defer qjs.JS_FreeValue(task.ctx, js_err);

                    // Call reject(error)
                    var args = [_]qjs.JSValue{js_err};
                    const ret = qjs.JS_Call(task.ctx, task.reject, z.jsUndefined, 1, &args);
                    qjs.JS_FreeValue(task.ctx, ret);
                },
            }
        }
        self.allocator.free(tasks);
        return count;
    }

    pub fn run(self: *EventLoop) !void {
        const rt = self.rt;
        while (!self.should_exit) {
            // Process microtasks
            var ctx_ptr: ?*qjs.JSContext = undefined;
            while (qjs.JS_ExecutePendingJob(rt, &ctx_ptr) > 0) {}

            // Process async tasks from worker threads (fetch, file I/O, etc.)
            _ = self.processAsyncTasks();

            // Execute pending microtasks again (async tasks may have created new promises)
            while (qjs.JS_ExecutePendingJob(rt, &ctx_ptr) > 0) {}

            // Check if we have any active timers
            var has_active_timers = false;
            for (self.timers.items) |timer| {
                if (!timer.is_cancelled) {
                    has_active_timers = true;
                    break;
                }
            }

            // Exit if no timers (will add more exit conditions later for async tasks)
            if (!has_active_timers) break;

            const now = std.time.milliTimestamp();
            var i: usize = 0;
            while (i < self.timers.items.len) {
                var timer = &self.timers.items[i];
                if (timer.is_cancelled) {
                    qjs.JS_FreeValue(timer.ctx, timer.callback);
                    _ = self.timers.swapRemove(i);
                    continue;
                }

                if (now >= timer.next_fire_time) {
                    // Use the timer's own context (the "tab" it belongs to)
                    const timer_ctx = timer.ctx;
                    const undefined_val = z.jsUndefined;
                    const result = qjs.JS_Call(timer_ctx, timer.callback, undefined_val, 0, null);

                    if (z.isException(result)) {
                        const exception = qjs.JS_GetException(timer_ctx);
                        defer qjs.JS_FreeValue(timer_ctx, exception);
                        const str = qjs.JS_ToCString(timer_ctx, exception);
                        if (str != null) {
                            std.debug.print("Timer callback exception: {s}\n", .{str});
                            qjs.JS_FreeCString(timer_ctx, str);
                        }
                    }
                    qjs.JS_FreeValue(timer_ctx, result);

                    if (timer.is_interval) {
                        timer.next_fire_time = now + @as(i64, @intCast(timer.interval_ms));
                        i += 1;
                    } else {
                        qjs.JS_FreeValue(timer_ctx, timer.callback);
                        _ = self.timers.swapRemove(i);
                    }
                } else {
                    i += 1;
                }
            }

            var sleep_ms: u64 = 10;
            for (self.timers.items) |timer| {
                if (!timer.is_cancelled) {
                    const time_until_fire = timer.next_fire_time - now;
                    if (time_until_fire > 0) {
                        sleep_ms = @min(sleep_ms, @as(u64, @intCast(time_until_fire)));
                    }
                }
            }
            std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
        }
    }
};

fn js_setTimeout(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "setTimeout requires 2 arguments");

    const rt = qjs.JS_GetRuntime(ctx);
    const event_loop_ptr = qjs.JS_GetRuntimeOpaque(rt);
    if (event_loop_ptr == null) return qjs.JS_ThrowInternalError(ctx, "EventLoop not initialized");
    const event_loop: *EventLoop = @ptrCast(@alignCast(event_loop_ptr));

    const callback = argv[0];
    if (!z.isFunction(ctx, callback)) return qjs.JS_ThrowTypeError(ctx, "First argument must be a function");

    var delay_ms: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &delay_ms, argv[1]) != 0) return qjs.JS_ThrowTypeError(ctx, "Second argument must be a number");
    if (delay_ms < 0) delay_ms = 0;

    const timer_id = event_loop.addTimer(ctx, callback, @intCast(delay_ms), false) catch {
        return qjs.JS_ThrowInternalError(ctx, "Failed to create timer");
    };
    return qjs.JS_NewInt32(ctx, @intCast(timer_id));
}

fn js_setInterval(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_ThrowTypeError(ctx, "setInterval requires 2 arguments");

    const rt = qjs.JS_GetRuntime(ctx);
    const event_loop_ptr = qjs.JS_GetRuntimeOpaque(rt);
    if (event_loop_ptr == null) return qjs.JS_ThrowInternalError(ctx, "EventLoop not initialized");
    const event_loop: *EventLoop = @ptrCast(@alignCast(event_loop_ptr));

    const callback = argv[0];
    if (!z.isFunction(ctx, callback)) return qjs.JS_ThrowTypeError(ctx, "First argument must be a function");

    var interval_ms: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &interval_ms, argv[1]) != 0) return qjs.JS_ThrowTypeError(ctx, "Second argument must be a number");
    if (interval_ms < 0) interval_ms = 0;

    const timer_id = event_loop.addTimer(ctx, callback, @intCast(interval_ms), true) catch {
        return qjs.JS_ThrowInternalError(ctx, "Failed to create timer");
    };
    return qjs.JS_NewInt32(ctx, @intCast(timer_id));
}

fn js_clearTimeout(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    if (argc < 1) return z.jsUndefined;

    const rt = qjs.JS_GetRuntime(ctx);
    const event_loop_ptr = qjs.JS_GetRuntimeOpaque(rt);
    if (event_loop_ptr == null) return z.jsUndefined;
    const event_loop: *EventLoop = @ptrCast(@alignCast(event_loop_ptr));

    var timer_id: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &timer_id, argv[0]) == 0) {
        event_loop.cancelTimer(@intCast(timer_id));
    }
    return z.jsUndefined;
}

fn js_consoleLog(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const str = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (str != null) {
            defer qjs.JS_FreeCString(ctx, str);
            if (i > 0) z.print(" ", .{});
            z.print("{s}", .{str});
        }
    }
    z.print("\n", .{});
    return z.jsUndefined;
}

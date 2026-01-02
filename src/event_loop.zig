const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;

const Timer = struct {
    id: u32,
    callback: qjs.JSValue,
    interval_ms: u64,
    next_fire_time: i64,
    is_interval: bool,
    is_cancelled: bool = false,
};

pub const Task = struct {
    ctx: *qjs.JSContext,
    resolve: z.qjs.JSValue,
    reject: z.qjs.JSValue,
    data: []const u8,
    is_error: bool,
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    ctx: ?*qjs.JSContext,
    rt: ?*qjs.JSRuntime,
    mutex: std.Thread.Mutex = .{},
    task_queue: std.ArrayList(Task) = .{},
    timers: std.ArrayListUnmanaged(Timer),
    next_timer_id: u32 = 1,
    should_exit: bool = false,

    pub fn init(allocator: std.mem.Allocator, ctx: ?*qjs.JSContext, rt: ?*qjs.JSRuntime) !EventLoop {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .rt = rt,
            .timers = .{},
            .task_queue = .{},
        };
    }

    pub fn deinit(self: *EventLoop) void {
        const ctx = self.ctx;
        for (self.timers.items) |timer| {
            qjs.JS_FreeValue(ctx, timer.callback);
        }
        // FIX: Pass allocator to deinit
        self.timers.deinit(self.allocator);
    }

    pub fn installTimerAPIs(self: *EventLoop) !void {
        const ctx = self.ctx;
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
    }

    fn addTimer(self: *EventLoop, callback: qjs.JSValue, delay_ms: u64, is_interval: bool) !u32 {
        const ctx = self.ctx;
        const now = std.time.milliTimestamp();
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        const callback_dup = qjs.JS_DupValue(ctx, callback);
        // FIX: Pass allocator to append
        try self.timers.append(self.allocator, Timer{
            .id = timer_id,
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

    pub fn run(self: *EventLoop) !void {
        const ctx = self.ctx;
        const rt = self.rt;
        while (!self.should_exit) {
            var ctx_ptr: ?*qjs.JSContext = undefined;
            while (qjs.JS_ExecutePendingJob(rt, &ctx_ptr) > 0) {}

            var has_active_timers = false;
            for (self.timers.items) |timer| {
                if (!timer.is_cancelled) {
                    has_active_timers = true;
                    break;
                }
            }
            if (!has_active_timers) break;

            const now = std.time.milliTimestamp();
            var i: usize = 0;
            while (i < self.timers.items.len) {
                var timer = &self.timers.items[i];
                if (timer.is_cancelled) {
                    qjs.JS_FreeValue(ctx, timer.callback);
                    // FIX: Pass allocator to swapRemove
                    _ = self.timers.swapRemove(i);
                    continue;
                }

                if (now >= timer.next_fire_time) {
                    const undefined_val = z.jsUndefined;
                    const result = qjs.JS_Call(ctx, timer.callback, undefined_val, 0, null);

                    if (z.isException(result)) {
                        const exception = qjs.JS_GetException(ctx);
                        defer qjs.JS_FreeValue(ctx, exception);
                        const str = qjs.JS_ToCString(ctx, exception);
                        if (str != null) {
                            std.debug.print("Timer callback exception: {s}\n", .{str});
                            qjs.JS_FreeCString(ctx, str);
                        }
                    }
                    qjs.JS_FreeValue(ctx, result);

                    if (timer.is_interval) {
                        timer.next_fire_time = now + @as(i64, @intCast(timer.interval_ms));
                        i += 1;
                    } else {
                        qjs.JS_FreeValue(ctx, timer.callback);
                        // FIX: Pass allocator to swapRemove
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

    const timer_id = event_loop.addTimer(callback, @intCast(delay_ms), false) catch {
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

    const timer_id = event_loop.addTimer(callback, @intCast(interval_ms), true) catch {
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

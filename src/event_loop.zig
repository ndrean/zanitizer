/// Event Loop for QuickJS
/// Implements setTimeout, setInterval, and clearTimeout/clearInterval
/// This provides the missing event loop functionality that browsers/Node.js have built-in

const std = @import("std");
const qjs = @cImport({
    @cInclude("quickjs.h");
});

/// Timer callback entry
const Timer = struct {
    id: u32,
    callback: qjs.JSValue,
    interval_ms: u64,
    next_fire_time: i64, // Unix timestamp in milliseconds
    is_interval: bool, // true for setInterval, false for setTimeout
    is_cancelled: bool = false,
};

/// Event Loop manages timers and pending jobs
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque, // Use anyopaque to avoid @cImport conflicts
    rt: ?*anyopaque,  // Use anyopaque to avoid @cImport conflicts
    timers: std.ArrayList(Timer),
    next_timer_id: u32 = 1,
    should_exit: bool = false,

    pub fn init(allocator: std.mem.Allocator, ctx: anytype, rt: anytype) !EventLoop {
        return .{
            .allocator = allocator,
            .ctx = @ptrCast(ctx),
            .rt = @ptrCast(rt),
            .timers = std.ArrayList(Timer).empty,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        // Free all timer callbacks
        for (self.timers.items) |timer| {
            qjs.JS_FreeValue(ctx, timer.callback);
        }
        self.timers.deinit(self.allocator);
    }

    /// Install setTimeout/setInterval/clearTimeout/clearInterval as global functions
    pub fn installTimerAPIs(self: *EventLoop) !void {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const rt: ?*qjs.JSRuntime = @ptrCast(@alignCast(self.rt));
        const global = qjs.JS_GetGlobalObject(ctx);
        defer qjs.JS_FreeValue(ctx, global);

        // Store EventLoop pointer in runtime's user data
        qjs.JS_SetRuntimeOpaque(rt, @ptrCast(self));

        // Create setTimeout function
        const set_timeout_fn = qjs.JS_NewCFunction2(
            ctx,
            js_setTimeout,
            "setTimeout",
            2,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, global, "setTimeout", set_timeout_fn);

        // Create setInterval function
        const set_interval_fn = qjs.JS_NewCFunction2(
            ctx,
            js_setInterval,
            "setInterval",
            2,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, global, "setInterval", set_interval_fn);

        // Create clearTimeout function
        const clear_timeout_fn = qjs.JS_NewCFunction2(
            ctx,
            js_clearTimeout,
            "clearTimeout",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, global, "clearTimeout", clear_timeout_fn);

        // Create clearInterval function (same implementation as clearTimeout)
        const clear_interval_fn = qjs.JS_NewCFunction2(
            ctx,
            js_clearTimeout, // Same function works for both
            "clearInterval",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, global, "clearInterval", clear_interval_fn);
    }

    /// Add a timer to the queue
    fn addTimer(self: *EventLoop, callback: qjs.JSValue, delay_ms: u64, is_interval: bool) !u32 {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const now = std.time.milliTimestamp();
        const timer_id = self.next_timer_id;
        self.next_timer_id += 1;

        // Duplicate the callback so it doesn't get GC'd
        const callback_dup = qjs.JS_DupValue(ctx, callback);

        try self.timers.append(self.allocator, Timer{
            .id = timer_id,
            .callback = callback_dup,
            .interval_ms = delay_ms,
            .next_fire_time = now + @as(i64, @intCast(delay_ms)),
            .is_interval = is_interval,
        });

        return timer_id;
    }

    /// Cancel a timer by ID
    fn cancelTimer(self: *EventLoop, timer_id: u32) void {
        for (self.timers.items) |*timer| {
            if (timer.id == timer_id and !timer.is_cancelled) {
                timer.is_cancelled = true;
                // NOTE: Don't free the callback here! It might still be executing.
                // The callback will be freed when we remove the timer from the queue.
                break;
            }
        }
    }

    /// Run the event loop until no more timers or should_exit is true
    pub fn run(self: *EventLoop) !void {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const rt: ?*qjs.JSRuntime = @ptrCast(@alignCast(self.rt));
        while (!self.should_exit) {
            // Process pending jobs (Promises, async/await)
            var ctx_ptr: ?*qjs.JSContext = undefined;
            while (qjs.JS_ExecutePendingJob(rt, &ctx_ptr) > 0) {
                // Keep executing until no more pending jobs
            }

            // Check if there are any active timers
            var has_active_timers = false;
            for (self.timers.items) |timer| {
                if (!timer.is_cancelled) {
                    has_active_timers = true;
                    break;
                }
            }

            if (!has_active_timers) {
                // No more timers, exit loop
                break;
            }

            // Process timers
            const now = std.time.milliTimestamp();
            var i: usize = 0;
            while (i < self.timers.items.len) {
                var timer = &self.timers.items[i];

                if (timer.is_cancelled) {
                    // Free the callback and remove cancelled timer
                    qjs.JS_FreeValue(ctx, timer.callback);
                    _ = self.timers.swapRemove(i);
                    continue;
                }

                if (now >= timer.next_fire_time) {
                    // Fire the timer
                    const undefined_val = jsUndefined();
                    const result = qjs.JS_Call(
                        ctx,
                        timer.callback,
                        undefined_val,
                        0,
                        null,
                    );

                    // Check for exceptions
                    if (qjs.JS_IsException(result) != 0) {
                        // Print exception
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
                        // Reschedule interval timer
                        timer.next_fire_time = now + @as(i64, @intCast(timer.interval_ms));
                        i += 1;
                    } else {
                        // Remove one-time timer
                        qjs.JS_FreeValue(ctx, timer.callback);
                        _ = self.timers.swapRemove(i);
                    }
                } else {
                    i += 1;
                }
            }

            // Sleep until next timer or 10ms (whichever is sooner)
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

    /// Run a single iteration of the event loop (non-blocking)
    pub fn tick(self: *EventLoop) !bool {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const rt: ?*qjs.JSRuntime = @ptrCast(@alignCast(self.rt));

        // Process pending jobs
        var ctx_ptr: ?*qjs.JSContext = undefined;
        while (qjs.JS_ExecutePendingJob(rt, &ctx_ptr) > 0) {}

        // Process timers
        const now = std.time.milliTimestamp();
        var has_active_timers = false;
        var i: usize = 0;

        while (i < self.timers.items.len) {
            var timer = &self.timers.items[i];

            if (timer.is_cancelled) {
                // Free the callback and remove cancelled timer
                qjs.JS_FreeValue(ctx, timer.callback);
                _ = self.timers.swapRemove(i);
                continue;
            }

            has_active_timers = true;

            if (now >= timer.next_fire_time) {
                // Fire the timer
                const undefined_val = jsUndefined();
                const result = qjs.JS_Call(ctx, timer.callback, undefined_val, 0, null);

                if (qjs.JS_IsException(result) != 0) {
                    const exception = qjs.JS_GetException(ctx);
                    defer qjs.JS_FreeValue(ctx, exception);

                    const str = qjs.JS_ToCString(ctx, exception);
                    if (str != null) {
                        std.debug.print("Timer exception: {s}\n", .{str});
                        qjs.JS_FreeCString(ctx, str);
                    }
                }
                qjs.JS_FreeValue(ctx, result);

                if (timer.is_interval) {
                    timer.next_fire_time = now + @as(i64, @intCast(timer.interval_ms));
                    i += 1;
                } else {
                    qjs.JS_FreeValue(ctx, timer.callback);
                    _ = self.timers.swapRemove(i);
                }
            } else {
                i += 1;
            }
        }

        return has_active_timers;
    }
};

/// C callback for setTimeout
fn js_setTimeout(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 2) {
        return qjs.JS_ThrowTypeError(ctx, "setTimeout requires 2 arguments");
    }

    // Get EventLoop from runtime opaque
    const rt = qjs.JS_GetRuntime(ctx);
    const event_loop_ptr = qjs.JS_GetRuntimeOpaque(rt);
    if (event_loop_ptr == null) {
        return qjs.JS_ThrowInternalError(ctx, "EventLoop not initialized");
    }
    const event_loop: *EventLoop = @ptrCast(@alignCast(event_loop_ptr));

    // Get callback function
    const callback = argv[0];
    if (qjs.JS_IsFunction(ctx, callback) == 0) {
        return qjs.JS_ThrowTypeError(ctx, "First argument must be a function");
    }

    // Get delay in milliseconds
    var delay_ms: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &delay_ms, argv[1]) != 0) {
        return qjs.JS_ThrowTypeError(ctx, "Second argument must be a number");
    }
    if (delay_ms < 0) delay_ms = 0;

    // Add timer
    const timer_id = event_loop.addTimer(callback, @intCast(delay_ms), false) catch {
        return qjs.JS_ThrowInternalError(ctx, "Failed to create timer");
    };

    return qjs.JS_NewInt32(ctx, @intCast(timer_id));
}

/// C callback for setInterval
fn js_setInterval(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 2) {
        return qjs.JS_ThrowTypeError(ctx, "setInterval requires 2 arguments");
    }

    const rt = qjs.JS_GetRuntime(ctx);
    const event_loop_ptr = qjs.JS_GetRuntimeOpaque(rt);
    if (event_loop_ptr == null) {
        return qjs.JS_ThrowInternalError(ctx, "EventLoop not initialized");
    }
    const event_loop: *EventLoop = @ptrCast(@alignCast(event_loop_ptr));

    const callback = argv[0];
    if (qjs.JS_IsFunction(ctx, callback) == 0) {
        return qjs.JS_ThrowTypeError(ctx, "First argument must be a function");
    }

    var interval_ms: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &interval_ms, argv[1]) != 0) {
        return qjs.JS_ThrowTypeError(ctx, "Second argument must be a number");
    }
    if (interval_ms < 0) interval_ms = 0;

    const timer_id = event_loop.addTimer(callback, @intCast(interval_ms), true) catch {
        return qjs.JS_ThrowInternalError(ctx, "Failed to create timer");
    };

    return qjs.JS_NewInt32(ctx, @intCast(timer_id));
}

/// Helper to create JS_UNDEFINED value at runtime (Zig 0.15.2 can't evaluate C macros at comptime)
/// We create it using the raw tag value instead
fn jsUndefined() qjs.JSValue {
    // JS_UNDEFINED is defined as JS_MKVAL(JS_TAG_UNDEFINED, 0)
    // We need to create the value manually to avoid comptime evaluation issues
    var val: qjs.JSValue = undefined;
    val.tag = qjs.JS_TAG_UNDEFINED;
    val.u = std.mem.zeroes(qjs.JSValueUnion);
    return val;
}

/// C callback for clearTimeout/clearInterval
fn js_clearTimeout(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) {
        return jsUndefined();
    }

    const rt = qjs.JS_GetRuntime(ctx);
    const event_loop_ptr = qjs.JS_GetRuntimeOpaque(rt);
    if (event_loop_ptr == null) {
        return jsUndefined();
    }
    const event_loop: *EventLoop = @ptrCast(@alignCast(event_loop_ptr));

    var timer_id: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &timer_id, argv[0]) == 0) {
        event_loop.cancelTimer(@intCast(timer_id));
    }

    return jsUndefined();
}

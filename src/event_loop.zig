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
const js_timers = @import("js_timers.zig");
const js_console = @import("js_console.zig");
const CurlMulti = @import("curl_multi.zig").CurlMulti;

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
        success_json: []u8,
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
    wakeup_fds: [2]std.posix.fd_t,
    timers: std.ArrayList(Timer),
    next_timer_id: i32 = 1,
    should_exit: bool = false,
    active_tasks: usize = 0,
    external_quit_flag: ?*std.atomic.Value(bool) = null,
    workers: std.ArrayList(*JSWorker) = .{},
    worker_class_id: zqjs.ClassID = 0,
    active_worker_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    worker_core: ?*anyopaque = null,
    max_workers: usize = z.MAX_WORKERS,
    on_error_handler: qjs.JSValue = zqjs.UNDEFINED,
    pending_background_jobs: std.atomic.Value(usize) = .init(0),
    /// Curl Multi handle for non-blocking HTTP requests
    curl_multi: ?*CurlMulti = null,
    /// Arena for temporary allocations during task processing (reset per cycle)
    task_arena: std.heap.ArenaAllocator,

    pub fn create(allocator: std.mem.Allocator, rt: *zqjs.Runtime) !*EventLoop {
        const self = try allocator.create(EventLoop);

        // Non-blocking pipe for waking the event loop from worker threads
        const wakeup_fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer {
            std.posix.close(wakeup_fds[0]);
            std.posix.close(wakeup_fds[1]);
        }

        self.* = .{
            .allocator = allocator,
            .rt = rt,
            .timers = .{},
            .task_queue = .{},
            .wakeup_fds = wakeup_fds,
            .thread_pool = undefined,
            .task_arena = std.heap.ArenaAllocator.init(allocator),
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
                    .success_json => |data| self.allocator.free(data),
                    .failure => |msg| self.allocator.free(msg),
                    .custom => |payload| {
                        payload.destroy(self.allocator, payload.data);
                    },
                }
            }
            self.task_queue.deinit(self.allocator);
            self.workers.deinit(self.allocator);
        }
        // Clean up curl multi handle
        if (self.curl_multi) |cm| cm.deinit();
        self.task_arena.deinit();
        self.rt.freeValue(self.on_error_handler);

        // Close wakeup pipe (thread_pool already joined above)
        std.posix.close(self.wakeup_fds[0]);
        std.posix.close(self.wakeup_fds[1]);

        self.allocator.destroy(self);
    }

    /// Initialize curl multi handle for non-blocking HTTP
    pub fn initCurlMulti(self: *EventLoop) !void {
        if (self.curl_multi == null) {
            self.curl_multi = try CurlMulti.init(self.allocator);
        }
    }

    /// Get the curl multi handle, initializing if needed
    pub fn getCurlMulti(self: *EventLoop) !*CurlMulti {
        if (self.curl_multi == null) {
            try self.initCurlMulti();
        }
        return self.curl_multi.?;
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
        if (rc.classes.event_loop == 0) {
            rc.classes.event_loop = self.rt.newClassID();
            try self.rt.newClass(rc.classes.event_loop, .{ .class_name = "EventLoop", .finalizer = null });
        }

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const loop_ref = ctx.newObjectClass(rc.classes.event_loop);
        try ctx.setOpaque(loop_ref, self);
        _ = try ctx.setPropertyStr(global, "__native_event_loop__", loop_ref);

        try js_timers.install(ctx);
        try js_console.install(ctx);

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
        // [CRITICAL] Decrement background job counter — every spawnWorker eventually
        // calls enqueueTask, so this is the centralized decrement point.
        _ = self.pending_background_jobs.fetchSub(1, .monotonic);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.task_queue.append(self.allocator, task) catch {
            task.ctx.freeValue(task.resolve);
            task.ctx.freeValue(task.reject);
            switch (task.result) {
                .success_utf8 => |data| self.allocator.free(data),
                .success_bin => |data| self.allocator.free(data),
                .success_json => |data| self.allocator.free(data),
                .failure => |msg| self.allocator.free(msg),
                .custom => |payload| {
                    payload.destroy(self.allocator, payload.data);
                },
            }
            return;
        };
        self.wake();
    }

    /// Signal the event loop to wake up from poll().
    /// Safe to call from any thread. Non-blocking.
    fn wake(self: *EventLoop) void {
        _ = std.posix.write(self.wakeup_fds[1], &.{1}) catch {};
    }

    /// Drain all pending bytes from the wakeup pipe.
    fn drainWakeupPipe(self: *EventLoop) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.wakeup_fds[0], &buf) catch return;
            if (n == 0) return; // EOF — write end closed (shutdown)
        }
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

        // Use arena for temporary allocations - reset at end of cycle
        const arena = self.task_arena.allocator();
        defer _ = self.task_arena.reset(.retain_capacity);

        for (tasks) |task| {
            defer task.ctx.freeValue(task.resolve);
            defer task.ctx.freeValue(task.reject);
            switch (task.result) {
                .custom => |payload| {
                    // execute the function pointer stored in the task
                    payload.callback(task.ctx, payload.data);
                },
                .success_json => |data| {
                    defer self.allocator.free(data);

                    // QuickJS may read past buffer - add null terminator (arena allocated)
                    const data_z = arena.dupeZ(u8, data) catch {
                        _ = task.ctx.call(task.reject, zqjs.UNDEFINED, &.{zqjs.UNDEFINED});
                        continue;
                    };
                    // No defer free needed - arena reset handles it

                    // Parse the JSON string into a native JS Object
                    const js_val = task.ctx.parseJSON(data_z, "<async_json>");

                    if (task.ctx.isException(js_val)) {
                        const err = task.ctx.getException();
                        _ = task.ctx.call(task.reject, zqjs.UNDEFINED, &.{err});
                        task.ctx.freeValue(err);
                    } else {
                        const ret = task.ctx.call(task.resolve, zqjs.UNDEFINED, &.{js_val});
                        task.ctx.freeValue(ret);
                    }
                    task.ctx.freeValue(js_val);
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
            // Safety limit prevents infinite microtask chains (e.g. React scheduler
            // continuously queueing microtasks via queueMicrotask/Promise.resolve).
            {
                var micro_count: u32 = 0;
                const max_microtasks: u32 = 50_000;
                while (micro_count < max_microtasks) : (micro_count += 1) {
                    const ctx_ptr = self.rt.executePendingJob() catch |err| {
                        // JS job threw — log but don't kill the event loop
                        // (frameworks have unhandled rejections that aren't fatal)
                        std.debug.print("[EventLoop] Job error: {any}\n", .{err});
                        continue;
                    };
                    if (ctx_ptr == null) break;
                }
                if (micro_count >= max_microtasks) {
                    std.debug.print("[EventLoop] SAFETY: microtask drain hit {d} limit, yielding to timers/IO\n", .{max_microtasks});
                }
            }

            // 3. EXIT CHECK
            // We only check for exit after draining jobs.
            if (mode == .Script) {
                self.mutex.lock();
                const queue_empty = (self.task_queue.items.len == 0);
                _ = self.active_tasks; // Access check
                self.mutex.unlock();

                const has_bg_jobs = self.pending_background_jobs.load(.monotonic) > 0;

                const has_workers = (self.workers.items.len > 0);
                const has_timers = (self.timers.items.len > 0);
                // [CRITICAL] Check isJobPending to avoid quitting if a Promise just queued another Promise
                const has_jobs = self.rt.isJobPending();
                // Check for pending curl multi requests
                const has_curl_pending = if (self.curl_multi) |cm| cm.pendingCount() > 0 else false;

                // if the last timer in the system created a Promise, the loop would see timers.len == 0 and exit immediately, killing the pending Promise before it could run
                if (!has_timers and
                    queue_empty and
                    self.active_tasks == 0 and
                    !has_workers and
                    !has_jobs and
                    !has_curl_pending and
                    !has_bg_jobs)
                {
                    break;
                }
            }

            // 4. Run Macrotasks (Timers & Worker Results)
            // Note: processTimers now returns 0 immediately if it fires a timer,
            // forcing us to loop back to Step 2 to handle any new Microtasks.
            const next_timeout = try self.processTimers();
            const did_async_work = self.processAsyncTasks();
            self.pollWorkers() catch {};

            // 4.5. Poll curl multi for completed HTTP requests (non-blocking)
            var curl_did_work = false;
            if (self.curl_multi) |cm| {
                const result = cm.poll(0) catch .{ .running = 0, .completed = 0 };
                curl_did_work = result.completed > 0;
            }

            // 5. Wait for events (self-pipe wakeup replaces CPU-spinning sleep)
            if (!did_async_work and !curl_did_work and next_timeout > 0) {
                if (self.rt.isJobPending()) continue;

                const wait_cap: i64 = if (mode == .Server) 50 else 10;
                const timeout_ms: i32 = @intCast(@min(next_timeout, wait_cap));

                var poll_fds = [1]std.posix.pollfd{
                    .{ .fd = self.wakeup_fds[0], .events = std.posix.POLL.IN, .revents = 0 },
                };
                _ = std.posix.poll(&poll_fds, timeout_ms) catch 0;

                if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                    self.drainWakeupPipe();
                }
            }
        }
    }

    pub fn processTimers(self: *EventLoop) !i64 {
        const now = std.time.milliTimestamp();
        var min_wait: i64 = 1000;
        var i: usize = 0;

        // We iterate, but we will BREAK/RETURN after the first execution
        while (i < self.timers.items.len) {
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
                if (ctx.isException(ret)) {
                    const ex = ctx.getException();
                    const ex_str = ctx.toCString(ex) catch null;
                    if (ex_str) |s| {
                        std.debug.print("❌ Timer Error: {s}\n", .{s});
                        ctx.freeCString(s);
                    }
                    ctx.freeValue(ex);
                    // ctx.freeValue(callback);
                    // _ = self.timers.swapRemove(i);
                }
                ctx.freeValue(ret);

                // Update/Remove Timer
                if (is_interval and !self.timers.items[i].is_cancelled) {
                    self.timers.items[i].next_fire_time = now + interval;
                    // We don't need to update min_wait here because we return immediately
                } else {
                    ctx.freeValue(callback);
                    _ = self.timers.swapRemove(i);
                }

                // Return 0 immediately! Forces the EL to go back to 'run()',
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
        _ = self.pending_background_jobs.fetchAdd(1, .monotonic);
        self.mutex.lock();
        self.active_tasks += 1;
        self.mutex.unlock();
    }
};

fn js_reportResult(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = z.wrapper.Context{ .ptr = ctx_ptr };
    if (argc < 1) return z.wrapper.UNDEFINED;

    // Duplicate the value so it survives after this function returns
    return ctx.dupValue(argv[0]);
}

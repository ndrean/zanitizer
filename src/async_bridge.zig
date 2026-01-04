const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;

/// A generic task structure that carries your specific Payload
pub fn GenericTask(comptime Payload: type) type {
    return struct {
        loop: *EventLoop,
        ctx: zqjs.Context,
        resolve: zqjs.Value,
        reject: zqjs.Value,
        payload: Payload,
    };
}

/// The generic wrapper generator
/// Payload: The type of data your parser returns (e.g., struct, string, number)
/// parseFn: Runs on Main Thread. Converts JS args -> Payload
/// workFn:  Runs on Worker Thread. Converts Payload -> Result String (or error)
pub fn bindAsync(
    comptime Payload: type,
    comptime parseFn: fn (ctx: zqjs.Context, args: []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (allocator: std.mem.Allocator, payload: Payload) anyerror![]u8,
) qjs.JSCFunction {
    const binder = struct {
        // This is the actual C-compatible function QuickJS calls
        fn callback(
            ctx_ptr: ?*qjs.JSContext,
            _: qjs.JSValue,
            argc: c_int,
            argv: [*c]qjs.JSValue,
        ) callconv(.c) qjs.JSValue {
            const ctx = zqjs.Context{ .ptr = ctx_ptr };

            // 1. Get EventLoop (Boilerplate removed)
            const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");

            // 2. Prepare Arguments Slice (Zig-style)
            // We cast the C pointer to a Zig slice for easier handling in the parser
            const args = if (argc > 0) argv[0..@intCast(argc)] else &[_]zqjs.Value{};
            const safe_args: []const zqjs.Value = @ptrCast(args);

            // 3. Parse Arguments (User Logic)
            const payload = parseFn(ctx, safe_args) catch |err| {
                // If parsing fails, throw JS exception immediately
                if (err == error.OutOfMemory) return ctx.throwOutOfMemory();
                // Assume parser set a JS exception if it returned a different error,
                // or throw a generic one if not.
                if (!ctx.hasException()) return ctx.throwTypeError("Invalid arguments");
                return zqjs.EXCEPTION;
            };
            // Note: If payload needs freeing on error beyond this point, user logic handles it?
            // Actually, we transfer ownership to the worker task below.

            // 4. Create Promise (Boilerplate removed)
            var resolving_funcs: [2]qjs.JSValue = undefined;
            const promise = qjs.JS_NewPromiseCapability(ctx_ptr, &resolving_funcs);
            if (ctx.isException(promise)) {
                // If payload has a destructor, we technically leak it here unless Payload handles it.
                // For simple types/duped strings, we might need a `freePayload` fn if we want to be 100% safe.
                return promise;
            }

            // 5. Create Generic Task
            const task_data = GenericTask(Payload){
                .loop = loop,
                .ctx = ctx,
                .resolve = resolving_funcs[0],
                .reject = resolving_funcs[1],
                .payload = payload,
            };

            // 6. Spawn Worker
            loop.spawnWorker(workerWrapper, task_data) catch {
                qjs.JS_FreeValue(ctx_ptr, resolving_funcs[0]);
                qjs.JS_FreeValue(ctx_ptr, resolving_funcs[1]);
                qjs.JS_FreeValue(ctx_ptr, promise);
                // Also free payload if needed? Complex without a destructor trait.
                return ctx.throwInternalError("Failed to spawn worker");
            };

            return promise;
        }

        // The generic worker wrapper that runs on the thread
        fn workerWrapper(task: GenericTask(Payload)) void {
            // Run user work function
            // We pass the loop allocator so the user can allocate the result string
            const result_or_err = workFn(task.loop.allocator, task.payload);

            // Handle Result
            switch (result_or_err) {
                .ok => |success_msg| {
                    task.loop.enqueueTask(.{
                        .ctx = task.ctx,
                        .resolve = task.resolve,
                        .reject = task.reject,
                        .result = .{ .success = success_msg },
                    });
                },
                .err => |err| {
                    // 1. Try to format the specific Zig error
                    var final_msg: []u8 = undefined;

                    if (std.fmt.allocPrint(task.loop.allocator, "{s}", .{@errorName(err)})) |msg| {
                        final_msg = msg;
                    } else |_| {
                        // 2. Fallback: specific error allocation failed (OOM)
                        // We try to dupe a generic error message so 'enqueueTask' has something to free.
                        final_msg = task.loop.allocator.dupe(u8, "Unknown Error (OOM)") catch {
                            // 3. Catastrophic OOM: We cannot allocate ANY string.
                            // We simply return here. The Promise will hang (never settle),
                            // but this prevents a double-free crash or segfault.
                            return;
                        };
                    }

                    // 4. Enqueue the task with the valid 'final_msg'
                    task.loop.enqueueTask(.{
                        .ctx = task.ctx,
                        .resolve = task.resolve,
                        .reject = task.reject,
                        .result = .{ .failure = final_msg }, // FIX: Use final_msg, not err_msg
                    });
                },
            }
        }
    };

    return binder.callback;
}

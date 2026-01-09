const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;

/// The Bridge: Connects a JS Call -> Zig Parser -> Thread Pool -> JS Promise
pub fn bindAsync(
    comptime Payload: type,
    // 1. Parser: Runs on Main Thread (JS Context -> Zig Data)
    //    DESIGN: We pass EventLoop so the parser has direct access to the heap-persisted allocator
    comptime parseFn: fn (loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) anyerror!Payload,
    // 2. Worker: Runs on Thread Pool (Zig Data -> Result String)
    comptime workFn: fn (allocator: std.mem.Allocator, payload: Payload) anyerror![]u8,
) qjs.JSCFunction {

    // We generate a custom C-Function struct for this specific task type
    const Binder = struct {

        // This is the actual C-function exposed to QuickJS
        fn callback(
            ctx_ptr: ?*qjs.JSContext,
            _: qjs.JSValue,
            argc: c_int,
            argv: [*c]qjs.JSValue,
        ) callconv(.c) qjs.JSValue {
            const ctx = zqjs.Context{ .ptr = ctx_ptr };

            // A. Boilerplate: Get Event Loop ONCE (fetched here, passed to parser)
            const loop = EventLoop.getFromContext(ctx) orelse return ctx.throwInternalError("EventLoop not found");

            // B. Boilerplate: Argument Slicing
            const args = if (argc > 0) argv[0..@intCast(argc)] else &[_]zqjs.Value{};
            const safe_args: []const zqjs.Value = @ptrCast(args);

            // C. USER LOGIC: Parse Arguments
            //    CRITICAL: Pass 'loop' so parser can use loop.allocator directly
            //    This is the allocator created by EventLoop.create() - persisted on the heap
            const payload = parseFn(loop, ctx, safe_args) catch |err| {
                if (err == error.OutOfMemory) return ctx.throwOutOfMemory();
                // If the parser didn't throw a JS exception already, throw a generic one
                if (!ctx.hasException()) return ctx.throwTypeError("Invalid arguments");
                return zqjs.EXCEPTION;
            };

            // D. Boilerplate: Create Promise
            var resolving_funcs: [2]qjs.JSValue = undefined;
            const promise = qjs.JS_NewPromiseCapability(ctx_ptr, &resolving_funcs);
            if (ctx.isException(promise)) {
                // Technically we leak 'payload' here if it owns memory,
                // but this case (Promise creation failure) is catastrophic anyway.
                return promise;
            }

            // E. Pack data for the thread
            const task_data = GenericTask{
                .loop = loop,
                .ctx = ctx,
                .resolve = resolving_funcs[0],
                .reject = resolving_funcs[1],
                .payload = payload,
            };

            // F. Spawn Worker
            loop.spawnWorker(workerWrapper, task_data) catch {
                qjs.JS_FreeValue(ctx_ptr, resolving_funcs[0]);
                qjs.JS_FreeValue(ctx_ptr, resolving_funcs[1]);
                qjs.JS_FreeValue(ctx_ptr, promise);
                return ctx.throwInternalError("Failed to spawn worker");
            };

            return promise;
        }

        // The Task Data Structure
        const GenericTask = struct {
            loop: *EventLoop,
            ctx: zqjs.Context,
            resolve: zqjs.Value,
            reject: zqjs.Value,
            payload: Payload,
        };

        // The Worker Wrapper (Runs on Thread)
        fn workerWrapper(task: GenericTask) void {
            // Run the user's work function
            // We pass the loop's allocator so the user can allocate the result string
            const result_or_err = workFn(task.loop.allocator, task.payload);

            if (result_or_err) |success_msg| {
                // Success case
                task.loop.enqueueTask(.{
                    .ctx = task.ctx,
                    .resolve = task.resolve,
                    .reject = task.reject,
                    .result = .{ .success = success_msg },
                });
            } else |err| {
                // Error case
                const err_msg = std.fmt.allocPrint(task.loop.allocator, "{s}", .{@errorName(err)}) catch {
                    // OOM while formatting error - use stack literal
                    const fallback = task.loop.allocator.dupe(u8, "Unknown Error (OOM)") catch return;
                    task.loop.enqueueTask(.{
                        .ctx = task.ctx,
                        .resolve = task.resolve,
                        .reject = task.reject,
                        .result = .{ .failure = fallback },
                    });
                    return;
                };

                task.loop.enqueueTask(.{
                    .ctx = task.ctx,
                    .resolve = task.resolve,
                    .reject = task.reject,
                    .result = .{ .failure = err_msg },
                });
            }
        }
    };

    return Binder.callback;
}

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EL = @import("event_loop.zig");
const EventLoop = EL.EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

/// Standard String binding (UTF-8)
/// Worker returns []u8 -> JS receives String
pub fn bindAsync(
    comptime Payload: type,
    comptime parseFn: fn (*EventLoop, zqjs.Context, []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (std.mem.Allocator, Payload) anyerror![]u8,
) qjs.JSCFunction {
    return bindAsyncInternal(Payload, parseFn, workFn, false);
}

/// Binary binding (ArrayBuffer)
/// Worker returns []u8 -> JS receives ArrayBuffer
pub fn bindAsyncBuffer(
    comptime Payload: type,
    comptime parseFn: fn (*EventLoop, zqjs.Context, []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (std.mem.Allocator, Payload) anyerror![]u8,
) qjs.JSCFunction {
    return bindAsyncInternal(Payload, parseFn, workFn, true);
}

/// JSON Auto-Serialization Binding
/// Worker returns arbitrary Zig Type -> Bridge serializes to JSON String -> JS receives String
pub fn bindAsyncJson(
    comptime Payload: type,
    comptime Result: type,
    comptime parseFn: fn (loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (allocator: std.mem.Allocator, payload: Payload) anyerror!Result,
) qjs.JSCFunction {
    const Wrapper = struct {
        fn wrappedWorkFn(outer_allocator: std.mem.Allocator, payload: Payload) anyerror![]u8 {
            // Setup Arena for temporary Worker allocations (Result struct)
            var arena = std.heap.ArenaAllocator.init(outer_allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Run User Logic (using Arena Allocator)
            // 'result_struct' and all its fields are allocated inside the arena.
            const result_struct = workFn(arena_alloc, payload) catch |err| {
                if (Payload == []u8 or Payload == []const u8) {
                    outer_allocator.free(payload);
                }
                return err;
            };

            var out: std.Io.Writer.Allocating = .init(outer_allocator);
            try std.json.Stringify.value(result_struct, .{ .whitespace = .indent_2 }, &out.writer);

            if (Payload == []u8 or Payload == []const u8) {
                outer_allocator.free(payload);
            }

            return out.toOwnedSlice();
        }
    };

    // Wrapper to adapt the user's struct-returning function to the required []u8 signature

    // Use standard UTF-8 binding since JSON is text
    return bindAsync(Payload, parseFn, Wrapper.wrappedWorkFn);
}

// --- Internal Generic Generator ---

fn bindAsyncInternal(
    comptime Payload: type,
    comptime parseFn: fn (*EventLoop, zqjs.Context, []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (std.mem.Allocator, Payload) anyerror![]u8,
    comptime is_binary: bool,
) qjs.JSCFunction {
    const Binder = struct {
        fn callback(
            ctx_ptr: ?*qjs.JSContext,
            _: qjs.JSValue,
            argc: c_int,
            argv: [*c]qjs.JSValue,
        ) callconv(.c) qjs.JSValue {
            const ctx = zqjs.Context{ .ptr = ctx_ptr };

            // [FIX] Thread-safe context retrieval
            const rc = RuntimeContext.get(ctx);
            const loop = rc.loop;

            const args = if (argc > 0) argv[0..@intCast(argc)] else &[_]zqjs.Value{};
            const safe_args: []const zqjs.Value = @ptrCast(args);

            // Parse Arguments
            const payload = parseFn(loop, ctx, safe_args) catch |err| {
                if (err == error.OutOfMemory) return ctx.throwOutOfMemory();
                if (!ctx.hasException()) return ctx.throwTypeError("Invalid arguments");
                return zqjs.EXCEPTION;
            };

            // Create Promise
            var resolving_funcs: [2]qjs.JSValue = undefined;
            const promise = qjs.JS_NewPromiseCapability(ctx_ptr, &resolving_funcs);
            if (ctx.isException(promise)) return promise;

            const task_data = GenericTask{
                .loop = loop,
                .ctx = ctx,
                .resolve = resolving_funcs[0],
                .reject = resolving_funcs[1],
                .payload = payload,
            };

            loop.spawnWorker(workerWrapper, task_data) catch {
                qjs.JS_FreeValue(ctx_ptr, resolving_funcs[0]);
                qjs.JS_FreeValue(ctx_ptr, resolving_funcs[1]);
                qjs.JS_FreeValue(ctx_ptr, promise);
                return ctx.throwInternalError("Failed to spawn worker");
            };

            return promise;
        }

        const GenericTask = struct {
            loop: *EventLoop,
            ctx: zqjs.Context,
            resolve: zqjs.Value,
            reject: zqjs.Value,
            payload: Payload,
        };

        fn workerWrapper(task: GenericTask) void {
            const result_or_err = workFn(task.loop.allocator, task.payload);

            if (result_or_err) |success_data| {
                // Select the correct union variant based on is_binary flag
                const res_variant = if (is_binary)
                    EL.AsyncTask.TaskResult{ .success_bin = success_data }
                else
                    EL.AsyncTask.TaskResult{ .success_utf8 = success_data };

                task.loop.enqueueTask(.{
                    .ctx = task.ctx,
                    .resolve = task.resolve,
                    .reject = task.reject,
                    .result = res_variant,
                });
            } else |err| {
                const err_msg = std.fmt.allocPrint(task.loop.allocator, "{s}", .{@errorName(err)}) catch {
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

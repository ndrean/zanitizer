const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EL = @import("event_loop.zig");
const EventLoop = EL.EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

/// Enum to select the return type strategy
const ResultType = enum {
    String, // Returns String
    Binary, // Returns ArrayBuffer
    Json, // Returns Object (Parsed from JSON)
};

/// Standard String binding (UTF-8)
///
/// Worker returns []u8 -> JS receives String
pub fn bindAsync(
    comptime Payload: type,
    comptime parseFn: fn (*EventLoop, zqjs.Context, []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (std.mem.Allocator, Payload) anyerror![]u8,
) qjs.JSCFunction {
    return bindAsyncInternal(Payload, parseFn, workFn, .String);
}

/// Binary binding (ArrayBuffer)
///
/// Worker returns []u8 -> JS receives _ArrayBuffer_
pub fn bindAsyncBuffer(
    comptime Payload: type,
    comptime parseFn: fn (*EventLoop, zqjs.Context, []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (std.mem.Allocator, Payload) anyerror![]u8,
) qjs.JSCFunction {
    return bindAsyncInternal(Payload, parseFn, workFn, .Binary);
}

/// JSON Auto-Serialization Binding
///
/// Worker returns arbitrary Zig Type -> Bridge serializes to JSON String -> JS receives String
pub fn bindAsyncJson(
    comptime Payload: type,
    comptime Result: type,
    comptime parseFn: fn (loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (allocator: std.mem.Allocator, payload: Payload) anyerror!Result,
) qjs.JSCFunction {
    const Wrapper = struct {
        fn wrappedWorkFn(outer_allocator: std.mem.Allocator, payload: Payload) anyerror![]u8 {
            // Arena for temporary Worker allocations (Result struct)
            var arena = std.heap.ArenaAllocator.init(outer_allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Run User Logic (using Arena Allocator)
            // 'result_struct' and all its fields are allocated inside the arena.
            const result_struct = workFn(arena_alloc, payload) catch |err| {
                freePayload(outer_allocator, payload);
                return err;
            };

            // Stringify to JSON (Zig 0.15.2 API)
            var out: std.Io.Writer.Allocating = .init(outer_allocator);
            try std.json.Stringify.value(result_struct, .{}, &out.writer);

            freePayload(outer_allocator, payload);

            return try out.toOwnedSlice();
        }

        fn freePayload(allocator: std.mem.Allocator, payload: Payload) void {
            const type_info = @typeInfo(Payload);
            // Check if it's a struct with deinit method
            if (type_info == .@"struct") {
                if (@hasDecl(Payload, "deinit")) {
                    payload.deinit(allocator);
                    return;
                }
            }
            // Fallback: If it is just a slice, free it.
            // For complex structs without deinit, we assume they don't own deep memory
            // or user should have provided a deinit method.
            switch (type_info) {
                .pointer => |ptr| {
                    if (ptr.size == .slice) allocator.free(payload);
                },
                else => {},
            }
            // Free simple string payloads
            // if (Payload == []u8 or Payload == []const u8) {
            //     allocator.free(payload);
            //     return;
            // }

            // // Free struct payloads with string fields
            // const type_info = @typeInfo(Payload);
            // if (type_info == .@"struct") {
            //     inline for (std.meta.fields(Payload)) |field| {
            //         const T = field.type;
            //         if (T == []u8 or T == []const u8) {
            //             allocator.free(@field(payload, field.name));
            //         }
            //     }
            // }
        }
    };

    // Wrapper to adapt the user's struct-returning function to the required []u8 fsignature

    // Use standard UTF-8 binding since JSON is text
    return bindAsyncInternal(Payload, parseFn, Wrapper.wrappedWorkFn, .Json);
}

// --- Internal Generic Generator ---

fn bindAsyncInternal(
    comptime Payload: type,
    comptime parseFn: fn (*EventLoop, zqjs.Context, []const zqjs.Value) anyerror!Payload,
    comptime workFn: fn (std.mem.Allocator, Payload) anyerror![]u8,
    comptime result_type: ResultType,
) qjs.JSCFunction {
    const Binder = struct {
        fn callback(
            ctx_ptr: ?*qjs.JSContext,
            _: qjs.JSValue,
            argc: c_int,
            argv: [*c]qjs.JSValue,
        ) callconv(.c) qjs.JSValue {
            const ctx = zqjs.Context.from(ctx_ptr);
            const rc = RuntimeContext.get(ctx);
            const loop = rc.loop;

            const args = if (argc > 0) argv[0..@intCast(argc)] else &[_]zqjs.Value{};
            const safe_args: []const zqjs.Value = @ptrCast(args);

            // Parse Arguments
            const payload = parseFn(loop, ctx, safe_args) catch |err| {
                if (err == error.OutOfMemory) return ctx.throwOutOfMemory();
                // if (!ctx.hasException()) return ctx.throwTypeError("Invalid arguments");
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
                // Select variant based on enum
                const res_variant = switch (result_type) {
                    .String => EL.AsyncTask.TaskResult{ .success_utf8 = success_data },
                    .Binary => EL.AsyncTask.TaskResult{ .success_bin = success_data },
                    .Json => EL.AsyncTask.TaskResult{ .success_json = success_data },
                };

                task.loop.enqueueTask(.{
                    .ctx = task.ctx,
                    .resolve = task.resolve,
                    .reject = task.reject,
                    .result = res_variant,
                });
            } else |err| {
                // ... (Error handling remains same as before) ...
                const err_msg = std.fmt.allocPrint(task.loop.allocator, "{s}", .{@errorName(err)}) catch {
                    // ... OOM fallback ...
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

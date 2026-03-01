//! `zxp.importScript(url)` — fetch a JS library, eval it, and cache as bytecode.
//!
//! First call:  fetch (worker thread) → eval(src) on main → spawn compile thread.
//! Next calls:  eval from cached bytecode (~10x faster, no network, no parse).
//!
//! Cache states: absent → compiling → ready(bytecode)
//! Concurrent calls during compilation fall back to fetch+eval (no extra compile).

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const curl = z.curl;
const EventLoop = z.EventLoop;
const RuntimeContext = z.RuntimeContext;

// ============================================================
// Process-level Script Cache (survives across requests in serve mode)

const CacheEntry = union(enum) {
    compiling,          // fetch worker spawned, bytecode not ready yet
    ready: []const u8, // owned bytecode bytes, lives for process lifetime
};

// std.heap.c_allocator: thread-safe (malloc/free), no lifetime constraints
const cache_alloc = std.heap.c_allocator;

var cache_mutex: std.Thread.Mutex = .{};
var cache_map: std.StringHashMapUnmanaged(CacheEntry) = .{};

pub fn deinitCache() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    var it = cache_map.iterator();
    while (it.next()) |entry| {
        cache_alloc.free(entry.key_ptr.*);
        switch (entry.value_ptr.*) {
            .ready => |bc| cache_alloc.free(bc),
            .compiling => {},
        }
    }
    cache_map.deinit(cache_alloc);
}

// ============================================================
// STRUCTS

const FetchJob = struct {
    loop: *EventLoop,
    ctx: zqjs.Context,
    url: []const u8,      // owned by loop.allocator, freed in destroy
    resolve: zqjs.Value,
    reject: zqjs.Value,
    spawn_compile: bool,  // true only for the first caller (absent → compiling)
};

const FetchCallbackCtx = struct {
    url: []const u8,       // owned by loop.allocator
    src: ?[:0]u8,          // owned by loop.allocator, null on fetch failure
    resolve: zqjs.Value,
    reject: zqjs.Value,
    spawn_compile: bool,
};

const CompileThreadArgs = struct {
    url: []const u8,  // owned by cache_alloc, used for cache update key lookup
    src: [:0]u8,      // owned by cache_alloc, freed after compile (null-terminated for JS_Eval)
};

// ============================================================
// COMPILE THREAD
// Detached — updates cache directly, no event loop involvement.

fn compileThread(args: CompileThreadArgs) void {
    const bytecode: ?[]const u8 = compileToBytecode(args.src) catch null;
    cache_alloc.free(args.src);

    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (bytecode) |bc| {
        // Transition compiling → ready in-place (map key stays, value updated)
        if (cache_map.getPtr(args.url)) |entry| {
            entry.* = .{ .ready = bc };
        } else {
            cache_alloc.free(bc); // entry was removed externally
        }
    } else {
        // Compile failed: remove sentinel so next request retries
        if (cache_map.fetchRemove(args.url)) |kv| {
            cache_alloc.free(kv.key);
        }
    }
    cache_alloc.free(args.url);
}

fn compileToBytecode(src: []const u8) ![]const u8 {
    const rt = qjs.JS_NewRuntime() orelse return error.RuntimeFailed;
    defer qjs.JS_FreeRuntime(rt);
    const temp_ctx = qjs.JS_NewContext(rt) orelse return error.ContextFailed;
    defer qjs.JS_FreeContext(temp_ctx);

    const compiled = qjs.JS_Eval(
        temp_ctx,
        src.ptr,
        src.len,
        "<importScript>",
        qjs.JS_EVAL_TYPE_GLOBAL | qjs.JS_EVAL_FLAG_COMPILE_ONLY,
    );
    defer qjs.JS_FreeValue(temp_ctx, compiled);
    if (qjs.JS_IsException(compiled)) return error.CompileFailed;

    var bc_size: usize = 0;
    const bc_buf = qjs.JS_WriteObject(temp_ctx, &bc_size, compiled, qjs.JS_WRITE_OBJ_BYTECODE);
    if (bc_buf == null) return error.WriteFailed;
    defer qjs.js_free(temp_ctx, bc_buf);

    return try cache_alloc.dupe(u8, bc_buf[0..bc_size]);
}

// ============================================================
// FETCH WORKER (thread pool → enqueues main-thread callback)

fn fetchWorker(args: FetchJob) void {
    const loop = args.loop;

    const src: ?[:0]u8 = fetchUrl(loop.allocator, args.url) catch null;

    const cb = loop.allocator.create(FetchCallbackCtx) catch {
        if (src) |s| loop.allocator.free(s);
        loop.allocator.free(args.url);
        return; // promise leaks resolve/reject — OOM, nothing to do
    };
    cb.* = .{
        .url = args.url,
        .src = src,
        .resolve = args.resolve,
        .reject = args.reject,
        .spawn_compile = args.spawn_compile,
    };
    loop.enqueueTask(.{
        .ctx = args.ctx,
        .resolve = args.resolve,
        .reject = args.reject,
        .result = .{ .custom = .{
            .data = cb,
            .callback = finishImport,
            .destroy = destroyFetchCallbackCtx,
        } },
    });
}

fn fetchUrl(allocator: std.mem.Allocator, url: []const u8) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ca_bundle = try curl.allocCABundle(aa);
    defer ca_bundle.deinit();
    var easy = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
    defer easy.deinit();

    try easy.setUrl(try aa.dupeZ(u8, url));
    z.hardenEasy(easy);

    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try easy.setWriter(&writer.writer);

    const ret = try easy.perform();
    if (ret.status_code < 200 or ret.status_code >= 300) return error.HttpError;

    // JS_Eval requires input[input_len] = '\0' — use sentinel slice to guarantee it.
    return writer.toOwnedSliceSentinel(0) catch error.OutOfMemory;
}

// ============================================================
// MAIN-THREAD CALLBACK

fn finishImport(ctx: zqjs.Context, data: *anyopaque) void {
    const rc = RuntimeContext.get(ctx);
    defer destroyFetchCallbackCtx(rc.allocator, data);

    const cb: *FetchCallbackCtx = @ptrCast(@alignCast(data));

    const src = cb.src orelse {
        // Fetch failed: remove .compiling sentinel so next request retries
        if (cb.spawn_compile) {
            cache_mutex.lock();
            if (cache_map.fetchRemove(cb.url)) |kv| cache_alloc.free(kv.key);
            cache_mutex.unlock();
        }
        const err = ctx.newString("importScript: fetch failed");
        defer ctx.freeValue(err);
        _ = ctx.call(cb.reject, zqjs.UNDEFINED, &.{err});
        return;
    };

    // Eval source in the live context — sets library globals immediately.
    // src is [:0]u8 so src.ptr[src.len] == '\0', satisfying JS_Eval's requirement.
    const result = qjs.JS_Eval(ctx.ptr, src.ptr, src.len, "<importScript>",
        qjs.JS_EVAL_TYPE_GLOBAL);
    const eval_failed = qjs.JS_IsException(result);
    qjs.JS_FreeValue(ctx.ptr, result);

    if (eval_failed) {
        const err = qjs.JS_GetException(ctx.ptr);
        defer qjs.JS_FreeValue(ctx.ptr, err);
        if (cb.spawn_compile) {
            cache_mutex.lock();
            if (cache_map.fetchRemove(cb.url)) |kv| cache_alloc.free(kv.key);
            cache_mutex.unlock();
        }
        _ = ctx.call(cb.reject, zqjs.UNDEFINED, &.{err});
        return;
    }

    // Spawn detached compile thread (fire and forget — updates cache when done)
    if (cb.spawn_compile) {
        spawnCompileThread(cb.url, src) catch {
            // Thread spawn failed: remove .compiling so next request retries
            cache_mutex.lock();
            if (cache_map.fetchRemove(cb.url)) |kv| cache_alloc.free(kv.key);
            cache_mutex.unlock();
        };
    }

    _ = ctx.call(cb.resolve, zqjs.UNDEFINED, &.{zqjs.UNDEFINED});
}

fn spawnCompileThread(url: []const u8, src: []const u8) !void {
    const url_copy = try cache_alloc.dupe(u8, url);
    errdefer cache_alloc.free(url_copy);
    // dupeZ: null-terminates so JS_Eval in compileToBytecode gets input[input_len] = '\0'
    const src_copy = try cache_alloc.dupeZ(u8, src);
    errdefer cache_alloc.free(src_copy);
    const t = try std.Thread.spawn(.{}, compileThread, .{CompileThreadArgs{
        .url = url_copy,
        .src = src_copy,
    }});
    t.detach();
}

fn destroyFetchCallbackCtx(allocator: std.mem.Allocator, data: *anyopaque) void {
    const cb: *FetchCallbackCtx = @ptrCast(@alignCast(data));
    if (cb.src) |s| allocator.free(s);
    allocator.free(cb.url);
    allocator.destroy(cb);
}

// ============================================================
// JS BINDING

pub fn js_importScript(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("importScript requires a URL");

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;

    const url_str = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(url_str);

    // Fast path: bytecode cached and ready
    {
        cache_mutex.lock();
        const entry = cache_map.get(url_str);
        cache_mutex.unlock();
        if (entry) |e| switch (e) {
            .ready => |bc| {
                const fn_val = qjs.JS_ReadObject(ctx.ptr, bc.ptr, bc.len, qjs.JS_READ_OBJ_BYTECODE);
                if (qjs.JS_IsException(fn_val)) return ctx.throwInternalError("importScript: corrupt bytecode cache");
                const eval_result = qjs.JS_EvalFunction(ctx.ptr, fn_val); // fn_val consumed
                const failed = qjs.JS_IsException(eval_result);
                qjs.JS_FreeValue(ctx.ptr, eval_result);
                if (failed) return qjs.JS_GetException(ctx.ptr);
                return createPromiseResolved(ctx, zqjs.UNDEFINED);
            },
            .compiling => {}, // fall through to fetch (no compile worker needed)
        };
    }

    // Slow path: fetch (and for the first caller, compile in background)
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return promise;
    const resolve = resolvers[0];
    const reject = resolvers[1];

    // Insert .compiling sentinel only for the first caller
    const spawn_compile = blk: {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        if (cache_map.get(url_str) != null) break :blk false; // already compiling
        const key = cache_alloc.dupe(u8, url_str) catch break :blk false;
        cache_map.put(cache_alloc, key, .compiling) catch {
            cache_alloc.free(key);
            break :blk false;
        };
        break :blk true;
    };

    const url_owned = loop.allocator.dupe(u8, url_str) catch {
        ctx.freeValue(resolve);
        ctx.freeValue(reject);
        ctx.freeValue(promise);
        return ctx.throwOutOfMemory();
    };

    loop.spawnWorker(fetchWorker, FetchJob{
        .loop = loop,
        .ctx = ctx,
        .url = url_owned,
        .resolve = resolve,
        .reject = reject,
        .spawn_compile = spawn_compile,
    }) catch {
        loop.allocator.free(url_owned);
        ctx.freeValue(resolve);
        ctx.freeValue(reject);
        ctx.freeValue(promise);
        return ctx.throwInternalError("importScript: failed to spawn worker");
    };

    return promise;
}

fn createPromiseResolved(ctx: zqjs.Context, val: zqjs.Value) zqjs.Value {
    var funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &funcs);
    if (qjs.JS_IsException(promise)) return promise;
    var args = [1]qjs.JSValue{val};
    const ret = qjs.JS_Call(ctx.ptr, funcs[0], zqjs.UNDEFINED, 1, &args);
    qjs.JS_FreeValue(ctx.ptr, ret);
    qjs.JS_FreeValue(ctx.ptr, funcs[0]);
    qjs.JS_FreeValue(ctx.ptr, funcs[1]);
    return promise;
}

pub const ImportScriptBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        const zxp = ctx.getPropertyStr(global, "zxp");
        defer ctx.freeValue(zxp);
        try ctx.setPropertyStr(zxp, "importScript",
            ctx.newCFunction(js_importScript, "importScript", 1));
    }
};

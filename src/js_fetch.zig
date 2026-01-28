const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const curl = @import("curl");
const js_security = @import("js_security.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_formData = @import("js_formData.zig");

const FetchTask = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    method: []u8,
    body: ?[]u8,
    headers: [][]const u8,
    sandbox: *js_security.Sandbox,
};

const FetchResult = struct {
    arena: std.heap.ArenaAllocator,
    status: i64,
    ok: bool,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
};

const FetchCallbackCtx = struct {
    result: *FetchResult,
    resolve: zqjs.Value,
    reject: zqjs.Value,
};

const FetchWorkerArgs = struct {
    loop: *EventLoop,
    task: FetchTask,
    ctx: zqjs.Context,
    resolve: zqjs.Value,
    reject: zqjs.Value,
};

// -------------------------------------------------------------------------
// SYNCHRONOUS LOGIC
// -------------------------------------------------------------------------

fn js_res_text(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const body_val = ctx.getPropertyStr(this, "_body");
    defer ctx.freeValue(body_val);

    if (ctx.isUndefined(body_val)) return ctx.newString("");

    var len: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, body_val);
    if (ptr == null) return ctx.newString("");

    return ctx.newString(ptr[0..len]);
}

fn js_res_json(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const text_val = js_res_text(ctx_ptr, this, 0, null);
    defer ctx.freeValue(text_val);

    if (ctx.isException(text_val)) return text_val;

    const str = ctx.toZString(text_val) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(str);

    return ctx.parseJSON(str, "<json>");
}

fn js_res_blob(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    const body_val = ctx.getPropertyStr(this, "_body");
    defer ctx.freeValue(body_val);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const blob_ctor = ctx.getPropertyStr(global, "Blob");
    defer ctx.freeValue(blob_ctor);

    if (ctx.isUndefined(blob_ctor)) return ctx.throwTypeError("Blob class not found");

    const parts = ctx.newArray();
    defer ctx.freeValue(parts);
    ctx.setPropertyInt64(parts, 0, ctx.dupValue(body_val)) catch {};

    const options = ctx.newObject();
    defer ctx.freeValue(options);

    const headers = ctx.getPropertyStr(this, "headers");
    defer ctx.freeValue(headers);
    if (!ctx.isUndefined(headers)) {
        const ct = ctx.getPropertyStr(headers, "content-type");
        defer ctx.freeValue(ct);
        if (!ctx.isUndefined(ct)) {
            _ = ctx.setPropertyStr(options, "type", ctx.dupValue(ct)) catch {};
        }
    }

    var args = [_]qjs.JSValue{ parts, options };
    return qjs.JS_CallConstructor(ctx.ptr, blob_ctor, 2, &args);
}

fn js_res_arrayBuffer(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    return ctx.getPropertyStr(this, "_body");
}

// -------------------------------------------------------------------------
// ASYNC PROXY WRAPPERS
// -------------------------------------------------------------------------

fn js_async_wrapper(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, workFn: fn (?*qjs.JSContext, qjs.JSValue, c_int, [*c]qjs.JSValue) callconv(.c) qjs.JSValue) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    const resolve = resolvers[0];
    const reject = resolvers[1];

    // QuickJS requires we free these handles after use or if unused
    defer ctx.freeValue(resolve);
    defer ctx.freeValue(reject);

    const result = workFn(ctx_ptr, this, 0, null);

    if (ctx.isException(result)) {
        const err = ctx.getException();
        _ = ctx.call(reject, zqjs.UNDEFINED, &.{err});
        ctx.freeValue(err);
    } else {
        _ = ctx.call(resolve, zqjs.UNDEFINED, &.{result});
    }
    ctx.freeValue(result);
    return promise;
}

fn js_text_proxy(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_async_wrapper(ctx, this, js_res_text);
}
fn js_json_proxy(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_async_wrapper(ctx, this, js_res_json);
}
fn js_blob_proxy(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_async_wrapper(ctx, this, js_res_blob);
}
fn js_arrayBuffer_proxy(ctx: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_async_wrapper(ctx, this, js_res_arrayBuffer);
}

// -------------------------------------------------------------------------
// MAIN FETCH
// -------------------------------------------------------------------------

pub const FetchBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        const fetch_fn = ctx.newCFunction(js_fetch, "fetch", 2);
        _ = try ctx.setPropertyStr(global, "fetch", fetch_fn);
    }
};

fn js_fetch(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("fetch requires a URL");

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;
    const allocator = loop.allocator;

    const url_str = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(url_str);

    var method_str: []const u8 = "GET";
    var body_data: ?[]u8 = null;
    var headers_list: std.ArrayListUnmanaged([]const u8) = .empty;

    errdefer {
        for (headers_list.items) |h| allocator.free(h);
        headers_list.deinit(allocator);
        if (body_data) |b| allocator.free(b);
    }

    if (argc > 1 and ctx.isObject(argv[1])) {
        const opts = argv[1];
        const m_prop = ctx.getPropertyStr(opts, "method");
        defer ctx.freeValue(m_prop);
        if (!ctx.isUndefined(m_prop)) {
            const c_str = ctx.toCString(m_prop) catch return ctx.throwOutOfMemory();
            defer ctx.freeCString(c_str);
            method_str = std.mem.span(c_str);
        }

        const b_prop = ctx.getPropertyStr(opts, "body");
        defer ctx.freeValue(b_prop);
        if (!ctx.isUndefined(b_prop) and !ctx.isNull(b_prop)) {
            var len: usize = 0;
            const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, b_prop);
            if (ptr) |p| {
                body_data = allocator.dupe(u8, p[0..len]) catch return ctx.throwOutOfMemory();
            } else if (ctx.isString(b_prop)) {
                const c_str = ctx.toCString(b_prop) catch return ctx.throwOutOfMemory();
                defer ctx.freeCString(c_str);
                body_data = allocator.dupe(u8, std.mem.span(c_str)) catch return ctx.throwOutOfMemory();
            } else if (qjs.JS_GetOpaque(b_prop, rc.classes.form_data)) |fd_ptr| {
                const fd: *js_formData.FormData = @ptrCast(@alignCast(fd_ptr));
                const result = js_formData.serializeFormData(allocator, fd) catch return ctx.throwOutOfMemory();
                body_data = result.body;
                const ct_val = std.fmt.allocPrint(allocator, "Content-Type: multipart/form-data; boundary={s}", .{result.boundary}) catch return ctx.throwOutOfMemory();
                allocator.free(result.boundary);
                headers_list.append(allocator, ct_val) catch return ctx.throwOutOfMemory();
            }
        }

        const h_prop = ctx.getPropertyStr(opts, "headers");
        defer ctx.freeValue(h_prop);
        if (ctx.isObject(h_prop)) {
            var tab: ?[*]qjs.JSPropertyEnum = undefined;
            var len: u32 = 0;
            const flags = qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY;
            if (qjs.JS_GetOwnPropertyNames(ctx.ptr, &tab, &len, h_prop, flags) == 0) {
                if (tab) |props| {
                    var i: u32 = 0;
                    while (i < len) : (i += 1) {
                        const atom = props[i].atom;
                        const val = qjs.JS_GetProperty(ctx.ptr, h_prop, atom);
                        const key_cstr = qjs.JS_AtomToCString(ctx.ptr, atom);
                        const val_cstr = qjs.JS_ToCString(ctx.ptr, val);
                        if (key_cstr != null and val_cstr != null) {
                            const header_line = std.fmt.allocPrint(allocator, "{s}: {s}", .{ std.mem.span(key_cstr), std.mem.span(val_cstr) }) catch break;
                            headers_list.append(allocator, header_line) catch {
                                allocator.free(header_line);
                                break;
                            };
                        }
                        if (key_cstr != null) qjs.JS_FreeCString(ctx.ptr, key_cstr);
                        if (val_cstr != null) qjs.JS_FreeCString(ctx.ptr, val_cstr);
                        qjs.JS_FreeValue(ctx.ptr, val);
                    }
                    qjs.JS_FreePropertyEnum(ctx.ptr, props, len);
                }
            }
        }
    }

    const task = FetchTask{
        .allocator = allocator,
        .url = allocator.dupe(u8, url_str) catch return ctx.throwOutOfMemory(),
        .method = allocator.dupe(u8, method_str) catch return ctx.throwOutOfMemory(),
        .body = body_data,
        .headers = headers_list.toOwnedSlice(allocator) catch return ctx.throwOutOfMemory(),
        .sandbox = rc.sandbox,
    };

    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);

    if (qjs.JS_IsException(promise)) {
        destroyFetchTask(allocator, task);
        return promise;
    }

    const resolve = resolvers[0];
    const reject = resolvers[1];

    loop.spawnWorker(fetchWorkerWrapper, FetchWorkerArgs{ .loop = loop, .task = task, .ctx = ctx, .resolve = resolve, .reject = reject }) catch {
        destroyFetchTask(allocator, task);
        ctx.freeValue(resolve);
        ctx.freeValue(reject);
        ctx.freeValue(promise);
        return ctx.throwInternalError("Failed to spawn worker");
    };

    return promise;
}

fn fetchWorkerWrapper(args: FetchWorkerArgs) void {
    const loop = args.loop;
    const task = args.task;
    const ctx = args.ctx;
    const resolve = args.resolve;
    const reject = args.reject;

    const res = performIO(task);

    const cb_ctx = loop.allocator.create(FetchCallbackCtx) catch @panic("OOM");
    cb_ctx.* = .{
        .result = res,
        .resolve = resolve,
        .reject = reject,
    };

    loop.enqueueTask(.{
        .ctx = ctx,
        .resolve = resolve,
        .reject = reject,
        .result = .{ .custom = .{
            .data = cb_ctx,
            .callback = finishFetch,
            .destroy = destroyFetchCallbackCtx,
        } },
    });

    destroyFetchTask(task.allocator, task);
}

fn performIO(task: FetchTask) *FetchResult {
    const res = task.allocator.create(FetchResult) catch @panic("OOM");
    res.arena = std.heap.ArenaAllocator.init(task.allocator);
    const arena_alloc = res.arena.allocator();

    res.url = arena_alloc.dupe(u8, task.url) catch @panic("OOM");
    res.body = &.{};
    res.headers = &.{};
    res.status = 0;
    res.ok = false;

    if (std.mem.startsWith(u8, task.url, "http")) {
        performCurlRequest(task, res, arena_alloc);
    } else {
        const file = js_security.openFileNoSymlinkEscape(task.sandbox, task.url) catch {
            res.status = 404;
            return res;
        };
        defer file.close();
        res.body = file.readToEndAlloc(arena_alloc, 10 * 1024 * 1024) catch {
            res.status = 500;
            return res;
        };
        res.status = 200;
        res.ok = true;
    }
    return res;
}

fn performCurlRequest(task: FetchTask, res: *FetchResult, arena: std.mem.Allocator) void {
    const ca_bundle = curl.allocCABundle(arena) catch return;
    defer ca_bundle.deinit();

    var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch return;
    defer easy.deinit();

    const url_z = arena.dupeZ(u8, task.url) catch return;
    easy.setUrl(url_z) catch return;

    if (std.mem.eql(u8, task.method, "POST")) {
        easy.setMethod(.POST) catch return;
        if (task.body) |b| easy.setPostFields(b) catch return;
    } else if (std.mem.eql(u8, task.method, "PUT")) {
        easy.setMethod(.PUT) catch return;
        if (task.body) |b| easy.setPostFields(b) catch return;
    } else {
        easy.setMethod(.GET) catch return;
    }

    var headers = curl.Easy.Headers{};
    defer headers.deinit();

    if (task.headers.len > 0) {
        for (task.headers) |h| {
            const h_z = arena.dupeZ(u8, h) catch return;
            headers.add(h_z) catch return;
        }
        easy.setHeaders(headers) catch return;
    }

    var writer = std.Io.Writer.Allocating.init(arena);
    defer writer.deinit();

    easy.setWriter(&writer.writer) catch return;

    const ret = easy.perform() catch return;

    res.status = ret.status_code;
    res.ok = (ret.status_code >= 200 and ret.status_code < 300);
    res.body = writer.toOwnedSlice() catch return;

    if (curl.hasParseHeaderSupport()) {
        var header_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var iter = ret.iterateHeaders(.{}) catch return;
        while (iter.next() catch return) |h| {
            const line = std.fmt.allocPrint(arena, "{s}: {s}", .{ h.name, h.get() }) catch return;
            header_list.append(arena, line) catch return;
        }
        res.headers = header_list.items;
    }
}

fn destroyFetchTask(allocator: std.mem.Allocator, task: FetchTask) void {
    allocator.free(task.url);
    allocator.free(task.method);
    if (task.body) |b| allocator.free(b);
    for (task.headers) |h| allocator.free(h);
    allocator.free(task.headers);
}

fn destroyFetchCallbackCtx(allocator: std.mem.Allocator, data: *anyopaque) void {
    const ctx: *FetchCallbackCtx = @ptrCast(@alignCast(data));
    const res = ctx.result;
    res.arena.deinit();
    allocator.destroy(res);
    allocator.destroy(ctx);
}

fn finishFetch(ctx: zqjs.Context, data: *anyopaque) void {
    const rc = RuntimeContext.get(ctx);
    const cb_ctx: *FetchCallbackCtx = @ptrCast(@alignCast(data));
    defer destroyFetchCallbackCtx(rc.allocator, data);

    const res = cb_ctx.result;
    const real_resolve = cb_ctx.resolve;
    const real_reject = cb_ctx.reject;

    if (res.status == 0) {
        const err = ctx.newString("Network Error");
        defer ctx.freeValue(err);
        _ = ctx.call(real_reject, zqjs.UNDEFINED, &.{err});
        return;
    }

    const resp = ctx.newObject();
    defer ctx.freeValue(resp);

    const status_val = ctx.newInt64(res.status);
    ctx.setPropertyStr(resp, "status", status_val) catch {
        ctx.freeValue(status_val);
    };

    const ok_val = ctx.newBool(res.ok);
    ctx.setPropertyStr(resp, "ok", ok_val) catch {
        ctx.freeValue(ok_val);
    };

    const url_val = ctx.newString(res.url);
    ctx.setPropertyStr(resp, "url", url_val) catch {
        ctx.freeValue(url_val);
    };

    const ab = ctx.newArrayBufferCopy(res.body);
    ctx.setPropertyStr(resp, "_body", ab) catch {
        ctx.freeValue(ab);
    };

    // Build headers init object
    const headers_init = ctx.newObject();
    for (res.headers) |line| {
        if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
            const key = std.mem.trim(u8, line[0..idx], " \t\r\n");
            const val = std.mem.trim(u8, line[idx + 1 ..], " \t\r\n");

            const val_js = ctx.newString(val);
            const atom = ctx.newAtom(key);
            defer ctx.freeAtom(atom);
            _ = qjs.JS_SetProperty(ctx.ptr, headers_init, atom, val_js);
        }
    }

    // Create Headers instance
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const headers_ctor = ctx.getPropertyStr(global, "Headers");
    defer ctx.freeValue(headers_ctor);

    var args = [_]qjs.JSValue{headers_init};
    const headers_obj = qjs.JS_CallConstructor(ctx.ptr, headers_ctor, 1, &args);
    ctx.freeValue(headers_init);

    ctx.setPropertyStr(resp, "headers", headers_obj) catch {
        ctx.freeValue(headers_obj);
    };

    //  Explicit Proxy Functions using standard newCFunction - Debug prints removed
    const text_fn = qjs.JS_NewCFunction(ctx.ptr, js_text_proxy, "text", 0);
    ctx.setPropertyStr(resp, "text", text_fn) catch {
        ctx.freeValue(text_fn);
    };
    const json_fn = qjs.JS_NewCFunction(ctx.ptr, js_json_proxy, "json", 0);
    ctx.setPropertyStr(resp, "json", json_fn) catch {
        ctx.freeValue(json_fn);
    };
    const blob_fn = qjs.JS_NewCFunction(ctx.ptr, js_blob_proxy, "blob", 0);
    ctx.setPropertyStr(resp, "blob", blob_fn) catch {
        ctx.freeValue(blob_fn);
    };
    const ab_fn = qjs.JS_NewCFunction(ctx.ptr, js_arrayBuffer_proxy, "arrayBuffer", 0);
    ctx.setPropertyStr(resp, "arrayBuffer", ab_fn) catch {
        ctx.freeValue(ab_fn);
    };

    _ = ctx.call(real_resolve, zqjs.UNDEFINED, &.{resp});
}

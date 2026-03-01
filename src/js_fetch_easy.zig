//! Threaded fetch(). Used in Worker() context
//!
//! FormData is manually serialized via `js_formData.serializeFormData()`
//! Response methods delegated to `js_response.buildResponse()` / `addResponseMethods()`.
//! uses hardenEasy()

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const curl = z.curl;
const js_security = z.js_security;
const EventLoop = z.EventLoop;
const RuntimeContext = z.RuntimeContext;
const js_formData = z.js_formData;
const js_blob = z.js_blob;
const js_file = z.js_File;
const js_response = z.js_response;

// ============================================================================
// STRUCTS
// ============================================================================

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

// ==============================================================
// PROMISE HELPERS

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

fn createPromiseRejected(ctx: zqjs.Context, msg: [:0]const u8) zqjs.Value {
    var funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &funcs);
    if (qjs.JS_IsException(promise)) return promise;

    // pending exception
    _ = ctx.throwTypeError(msg);

    // Retrieve the object and clear the pending state
    const err_obj = ctx.getException();

    // Reject the promise with the actual Error Object
    var args = [1]qjs.JSValue{err_obj};
    const ret = qjs.JS_Call(ctx.ptr, funcs[1], zqjs.UNDEFINED, 1, &args);

    qjs.JS_FreeValue(ctx.ptr, ret);
    qjs.JS_FreeValue(ctx.ptr, err_obj); // Free our handle (reject has its own copy if needed)
    qjs.JS_FreeValue(ctx.ptr, funcs[0]);
    qjs.JS_FreeValue(ctx.ptr, funcs[1]);

    return promise;
}

// ==========================================================
// BLOB FETCH

fn js_blob_response_text(ctx_ptr: ?*qjs.JSContext, this_val: zqjs.Value, _: c_int, _: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const blob_val = ctx.getPropertyStr(this_val, "_blob");
    defer ctx.freeValue(blob_val);

    var blob_ptr: ?*js_blob.BlobObject = null;

    // Try as standard Blob
    if (ctx.getOpaque(blob_val, rc.classes.blob)) |ptr| {
        blob_ptr = @ptrCast(@alignCast(ptr));
    }
    // Try as File (which embeds Blob)
    else if (ctx.getOpaque(blob_val, rc.classes.file)) |ptr| {
        const file: *js_file.FileObject = @ptrCast(@alignCast(ptr));
        blob_ptr = &file.blob; // Safe field access
    }

    if (blob_ptr) |blob| {
        const str = ctx.newString(blob.data);
        const prom = createPromiseResolved(ctx, str);
        ctx.freeValue(str);
        return prom;
    }

    return createPromiseRejected(ctx, "Failed to read Blob/File data");
}

fn js_blob_response_json(ctx_ptr: ?*qjs.JSContext, this_val: zqjs.Value, _: c_int, _: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const blob_val = ctx.getPropertyStr(this_val, "_blob");
    defer ctx.freeValue(blob_val);

    var blob_ptr: ?*js_blob.BlobObject = null;

    // Try as standard Blob
    if (ctx.getOpaque(blob_val, rc.classes.blob)) |ptr| {
        blob_ptr = @ptrCast(@alignCast(ptr));
    }
    // Try as File
    else if (ctx.getOpaque(blob_val, rc.classes.file)) |ptr| {
        const file: *js_file.FileObject = @ptrCast(@alignCast(ptr));
        blob_ptr = &file.blob;
    }

    if (blob_ptr) |blob| {
        const json_val = ctx.parseJSON(blob.data, "<blob>");
        if (ctx.isException(json_val)) {
            const ex = ctx.getException();
            ctx.freeValue(ex); // Clear VM exception state
            return createPromiseRejected(ctx, "Invalid JSON in Blob");
        }

        const prom = createPromiseResolved(ctx, json_val);
        ctx.freeValue(json_val);
        return prom;
    }

    return createPromiseRejected(ctx, "Failed to read Blob/File data");
}

fn js_blob_response_blob(ctx_ptr: ?*qjs.JSContext, this_val: zqjs.Value, _: c_int, _: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = zqjs.Context.from(ctx_ptr);
    const blob_val = ctx.getPropertyStr(this_val, "_blob");
    const prom = createPromiseResolved(ctx, blob_val);
    ctx.freeValue(blob_val);
    return prom;
}

fn fetchBlob(ctx: zqjs.Context, url: []const u8) zqjs.Value {
    const rc = RuntimeContext.get(ctx);
    const blob_js = rc.blob_registry.get(url) orelse {
        return createPromiseRejected(ctx, "NetworkError: Blob URL not found");
    };

    var blob_struct_ptr: ?*js_blob.BlobObject = null;
    // Try a file
    if (ctx.getOpaque(blob_js, rc.classes.blob)) |ptr| {
        blob_struct_ptr = @ptrCast(@alignCast(ptr));
        // Try a Blb
    } else if (ctx.getOpaque(blob_js, rc.classes.file)) |ptr| {
        const file: *js_file.FileObject = @ptrCast(@alignCast(ptr));
        blob_struct_ptr = &file.blob;
    }

    if (blob_struct_ptr == null) return createPromiseRejected(ctx, "Invalid Blob in registry");

    const blob = blob_struct_ptr.?;

    const resp = ctx.newObject();

    ctx.setPropertyStr(resp, "ok", ctx.newBool(true)) catch {};
    ctx.setPropertyStr(resp, "statusText", ctx.newString("OK")) catch {};
    ctx.setPropertyStr(resp, "url", ctx.newString(url)) catch {};
    ctx.setPropertyStr(resp, "type", ctx.newString("basic")) catch {};
    ctx.setPropertyStr(resp, "_blob", ctx.dupValue(blob_js)) catch {};

    const headers = ctx.newObject();
    if (blob.mime_type.len > 0) {
        ctx.setPropertyStr(headers, "Content-Type", ctx.newString(blob.mime_type)) catch {};
    }
    ctx.setPropertyStr(resp, "headers", headers) catch {};
    ctx.setPropertyStr(
        resp,
        "text",
        ctx.newCFunction(js_blob_response_text, "text", 0),
    ) catch {};
    ctx.setPropertyStr(
        resp,
        "json",
        ctx.newCFunction(js_blob_response_json, "json", 0),
    ) catch {};
    ctx.setPropertyStr(
        resp,
        "blob",
        ctx.newCFunction(js_blob_response_blob, "blob", 0),
    ) catch {};
    ctx.setPropertyStr(
        resp,
        "arrayBuffer",
        ctx.newCFunction(js_blob_response_blob, "arrayBuffer", 0),
    ) catch {};

    const prom = createPromiseResolved(ctx, resp);
    ctx.freeValue(resp);
    return prom;
}

// ===========================================================
// FILE:// FETCH LOGIC
// ===========================================================

fn fetchFile(ctx: zqjs.Context, url: []const u8) zqjs.Value {
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.loop.allocator;

    const path = url["file://".len..];

    const file = js_security.openFileNoSymlinkEscape(rc.sandbox, path) catch {
        return createPromiseRejected(ctx, "NetworkError: file not found or access denied");
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return createPromiseRejected(ctx, "NetworkError: failed to read file");
    };
    defer allocator.free(data);

    const resp = js_response.buildResponse(ctx, .{ .url = url }, ctx.newArrayBufferCopy(data), ctx.newObject());
    defer ctx.freeValue(resp);
    return createPromiseResolved(ctx, resp);
}

// ===========================================================
// WORKER / IO LOGIC

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
    z.hardenEasy(easy);

    // --- UPDATED METHOD HANDLING ---
    if (std.mem.eql(u8, task.method, "POST")) {
        easy.setMethod(.POST) catch return;
        if (task.body) |b| easy.setPostFields(b) catch return;
    } else if (std.mem.eql(u8, task.method, "PUT")) {
        easy.setMethod(.PUT) catch return;
        if (task.body) |b| easy.setPostFields(b) catch return;
    } else if (std.mem.eql(u8, task.method, "PATCH")) {
        // Assuming your curl wrapper maps .PATCH.
        // If not, use: easy.setCustomRequest("PATCH") catch return;
        easy.setMethod(.PATCH) catch return;
        if (task.body) |b| easy.setPostFields(b) catch return;
    } else if (std.mem.eql(u8, task.method, "DELETE")) {
        easy.setMethod(.DELETE) catch return;
    } else if (std.mem.eql(u8, task.method, "HEAD")) {
        easy.setMethod(.HEAD) catch return;
    } else {
        // Default to GET
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

    // Build Headers object from response header lines
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
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const headers_ctor = ctx.getPropertyStr(global, "Headers");
    defer ctx.freeValue(headers_ctor);
    var args = [_]qjs.JSValue{headers_init};
    const headers_obj = qjs.JS_CallConstructor(ctx.ptr, headers_ctor, 1, &args);
    ctx.freeValue(headers_init);

    const resp = js_response.buildResponse(ctx, .{
        .status = res.status,
        .ok = res.ok,
        .url = res.url,
    }, ctx.newArrayBufferCopy(res.body), headers_obj);
    defer ctx.freeValue(resp);
    _ = ctx.call(real_resolve, zqjs.UNDEFINED, &.{resp});
}

// ===========================================================
// JS_FETCH (Threaded)

fn js_fetch(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("fetch requires a URL");

    const rc = RuntimeContext.get(ctx);
    const loop = rc.loop;
    const allocator = loop.allocator;

    const url_str = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(url_str);

    // BLOB INTERCEPTION
    if (std.mem.startsWith(u8, url_str, "blob:")) {
        return fetchBlob(ctx, url_str);
    }

    // FILE:// INTERCEPTION
    if (std.mem.startsWith(u8, url_str, "file://")) {
        return fetchFile(ctx, url_str);
    }

    // [SECURITY] SSRF gate: block requests to internal infrastructure in sanitize mode
    if (rc.sanitize_enabled and z.isBlockedUrl(url_str)) {
        return createPromiseRejected(ctx, "NetworkError: request to internal address blocked by SSRF filter");
    }

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

pub const FetchBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        const fetch_fn = ctx.newCFunction(js_fetch, "fetch", 2);
        try ctx.setPropertyStr(global, "fetch", fetch_fn);
    }
};

//! non blocking `curl_multi` (event-loop driven) used in Main runtime.
//!
//! Native multipart via `curl_multi.submitMultipartRequest()`.
//! Response methods are delegated to `js_response.addResponseMethods()`.
//!
//! hardenEasy() is applied inside `curl_multi.zig` at Easy handle creation.
const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const js_security = z.js_security;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_formData = @import("js_formData.zig");
const js_blob = z.js_blob;
const js_file = z.js_file;
const js_response = @import("js_response.zig");
const curl_multi_mod = @import("curl_multi.zig");
const CurlMulti = curl_multi_mod.CurlMulti;
const MultipartEntry = curl_multi_mod.MultipartEntry;

const FetchTask = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    method: []u8,
    body: ?[]u8,
    headers: [][]const u8,
    sandbox: *js_security.Sandbox,
};

// === PROMISE HELPERS (Var Args & Exception Safety)

fn createPromiseResolved(ctx: zqjs.Context, val: zqjs.Value) zqjs.Value {
    var funcs: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &funcs);
    if (qjs.JS_IsException(promise)) return promise;

    // [FIX] Must be var for JS_Call
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

    // 1. Create the Error Object and set it as pending exception
    _ = ctx.throwTypeError(msg);

    // 2. "Catch" it: Retrieve the object and clear the pending state
    const err_obj = ctx.getException();

    // 3. Reject the promise with the actual Error Object
    var args = [1]qjs.JSValue{err_obj};
    const ret = qjs.JS_Call(ctx.ptr, funcs[1], zqjs.UNDEFINED, 1, &args);

    // 4. Cleanup
    qjs.JS_FreeValue(ctx.ptr, ret);
    qjs.JS_FreeValue(ctx.ptr, err_obj); // Free our handle (reject has its own copy if needed)
    qjs.JS_FreeValue(ctx.ptr, funcs[0]);
    qjs.JS_FreeValue(ctx.ptr, funcs[1]);

    return promise;
}

// === BLOB FETCH LOGIC

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

// ============================================================================
// FILE:// FETCH LOGIC
// ============================================================================

fn fetchFile(ctx: zqjs.Context, url: []const u8) zqjs.Value {
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.loop.allocator;

    // Strip "file://" prefix to get the actual path
    const path = url["file://".len..];

    const file = js_security.openFileNoSymlinkEscape(rc.sandbox, path) catch {
        return createPromiseRejected(ctx, "NetworkError: file not found or access denied");
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return createPromiseRejected(ctx, "NetworkError: failed to read file");
    };
    defer allocator.free(data);

    const resp = ctx.newObject();

    ctx.setPropertyStr(resp, "status", ctx.newInt64(200)) catch {};
    ctx.setPropertyStr(resp, "ok", ctx.newBool(true)) catch {};
    ctx.setPropertyStr(resp, "url", ctx.newString(url)) catch {};

    const ab = ctx.newArrayBufferCopy(data);
    ctx.setPropertyStr(resp, "_body", ab) catch {
        ctx.freeValue(ab);
    };

    // Build Headers object using constructor (provides .get() method)
    {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        const headers_ctor = ctx.getPropertyStr(global, "Headers");
        defer ctx.freeValue(headers_ctor);
        if (!ctx.isUndefined(headers_ctor)) {
            var args = [_]qjs.JSValue{ctx.newObject()};
            const headers_obj = qjs.JS_CallConstructor(ctx.ptr, headers_ctor, 1, &args);
            ctx.freeValue(args[0]);
            ctx.setPropertyStr(resp, "headers", headers_obj) catch {
                ctx.freeValue(headers_obj);
            };
        } else {
            const headers_obj = ctx.newObject();
            ctx.setPropertyStr(resp, "headers", headers_obj) catch {
                ctx.freeValue(headers_obj);
            };
        }
    }

    js_response.addResponseMethods(ctx, resp);

    const prom = createPromiseResolved(ctx, resp);
    ctx.freeValue(resp);
    return prom;
}

// ============================================================================
// HELPERS
// ============================================================================

fn destroyFetchTask(allocator: std.mem.Allocator, task: FetchTask) void {
    allocator.free(task.url);
    allocator.free(task.method);
    if (task.body) |b| allocator.free(b);
    for (task.headers) |h| allocator.free(h);
    allocator.free(task.headers);
}

// ============================================================================
// MAIN FETCH

pub fn js_fetch(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
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
    var form_data_ptr: ?*js_formData.FormData = null;

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
                // Store FormData pointer for multipart submission (no manual serialization)
                form_data_ptr = @ptrCast(@alignCast(fd_ptr));
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

    // Use curl multi for non-blocking HTTP (no threads needed)
    const curl_multi = loop.getCurlMulti() catch {
        destroyFetchTask(allocator, task);
        ctx.freeValue(resolve);
        ctx.freeValue(reject);
        ctx.freeValue(promise);
        return ctx.throwInternalError("Failed to initialize curl multi");
    };

    // Use multipart API for FormData, regular request otherwise
    if (form_data_ptr) |fd| {
        // Build multipart entries from FormData
        var entries: std.ArrayListUnmanaged(MultipartEntry) = .empty;
        defer entries.deinit(allocator);

        for (fd.entries.items) |entry| {
            entries.append(allocator, .{
                .name = entry.name,
                .data = if (entry.value.len > 0) entry.value else null,
                .file_path = entry.file_path,
                .filename = entry.filename,
                .mime_type = entry.mime_type,
            }) catch {
                destroyFetchTask(allocator, task);
                ctx.freeValue(resolve);
                ctx.freeValue(reject);
                ctx.freeValue(promise);
                return ctx.throwOutOfMemory();
            };
        }

        curl_multi.submitMultipartRequest(
            ctx,
            task.url,
            entries.items,
            task.headers,
            resolve,
            reject,
        ) catch {
            destroyFetchTask(allocator, task);
            ctx.freeValue(resolve);
            ctx.freeValue(reject);
            ctx.freeValue(promise);
            return ctx.throwInternalError("Failed to submit multipart request");
        };
    } else {
        curl_multi.submitRequest(
            ctx,
            task.url,
            task.method,
            task.body,
            task.headers,
            resolve,
            reject,
        ) catch {
            destroyFetchTask(allocator, task);
            ctx.freeValue(resolve);
            ctx.freeValue(reject);
            ctx.freeValue(promise);
            return ctx.throwInternalError("Failed to submit HTTP request");
        };
    }

    // Cleanup task data (curl multi makes copies)
    destroyFetchTask(allocator, task);
    ctx.freeValue(resolve);
    ctx.freeValue(reject);

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

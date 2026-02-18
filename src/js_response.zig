//! Shared Response methods for fetch API
//!
//! This module provides the Response body methods (text, json, blob, arrayBuffer, body)
//! used by both js_fetch.zig (sync path) and curl_multi.zig (async path).

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const js_readable_stream = @import("js_readable_stream.zig");

// ============================================================
// Response Body Methods

fn js_res_text(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const body_val = ctx.getPropertyStr(this, "_body");
    defer ctx.freeValue(body_val);

    if (ctx.isUndefined(body_val)) return ctx.newString("");

    var len: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, body_val);
    if (ptr == null) return ctx.newString("");

    return ctx.newString(ptr[0..len]);
}

fn js_res_json(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const text_val = js_res_text(ctx_ptr, this, 0, null);
    defer ctx.freeValue(text_val);

    if (ctx.isException(text_val)) return text_val;

    const str = ctx.toZString(text_val) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(str);

    return ctx.parseJSON(str, "<json>");
}

fn js_res_blob(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
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
    const ctx = zqjs.Context.from(ctx_ptr);
    return ctx.getPropertyStr(this, "_body");
}

/// response.body getter - returns ReadableStream
fn js_res_body(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);

    // Check if we already created a stream (cached in _stream)
    const cached = ctx.getPropertyStr(this, "_stream");
    if (!ctx.isUndefined(cached)) {
        return cached;
    }
    ctx.freeValue(cached);

    // Get the ArrayBuffer data
    const body_val = ctx.getPropertyStr(this, "_body");
    defer ctx.freeValue(body_val);

    if (ctx.isUndefined(body_val)) {
        return zqjs.NULL;
    }

    var len: usize = 0;
    const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, body_val);
    if (ptr == null) {
        return zqjs.NULL;
    }

    // Create ReadableStream from the buffer
    const stream = js_readable_stream.createStreamFromBuffer(ctx, ptr[0..len]) catch {
        return ctx.throwOutOfMemory();
    };

    // Cache it on the response
    ctx.setPropertyStr(this, "_stream", ctx.dupValue(stream)) catch {};

    return stream;
}

// =============================================================
// Async Wrappers (return Promises)

fn js_async_wrapper(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, workFn: fn (?*qjs.JSContext, qjs.JSValue, c_int, [*c]qjs.JSValue) callconv(.c) qjs.JSValue) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    const resolve = resolvers[0];
    const reject = resolvers[1];
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

// ==========================================================
// Public API

/// Add all standard Response methods to a JS Response object.
/// The Response object must have `_body` property set to an ArrayBuffer.
/// Optionally can have `headers` property for blob() MIME type extraction.
pub fn addResponseMethods(ctx: zqjs.Context, resp: qjs.JSValue) void {
    // text() -> Promise<string>
    const text_fn = qjs.JS_NewCFunction(ctx.ptr, js_text_proxy, "text", 0);
    ctx.setPropertyStr(resp, "text", text_fn) catch {
        ctx.freeValue(text_fn);
    };

    // json() -> Promise<any>
    const json_fn = qjs.JS_NewCFunction(ctx.ptr, js_json_proxy, "json", 0);
    ctx.setPropertyStr(resp, "json", json_fn) catch {
        ctx.freeValue(json_fn);
    };

    // blob() -> Promise<Blob>
    const blob_fn = qjs.JS_NewCFunction(ctx.ptr, js_blob_proxy, "blob", 0);
    ctx.setPropertyStr(resp, "blob", blob_fn) catch {
        ctx.freeValue(blob_fn);
    };

    // arrayBuffer() -> Promise<ArrayBuffer>
    const ab_fn = qjs.JS_NewCFunction(ctx.ptr, js_arrayBuffer_proxy, "arrayBuffer", 0);
    ctx.setPropertyStr(resp, "arrayBuffer", ab_fn) catch {
        ctx.freeValue(ab_fn);
    };

    // body getter -> ReadableStream
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "body");
        const get = qjs.JS_NewCFunction2(ctx.ptr, js_res_body, "get_body", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, resp, atom, get, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }
}

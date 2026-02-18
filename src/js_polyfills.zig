const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// btoa: Binary to ASCII (Base64 Encode)
// Per spec, btoa treats each JS character as a Latin-1 byte (code point 0-255).
// QuickJS returns UTF-8 from JS_ToCStringLen, so we must decode UTF-8 back
// to Latin-1 before base64 encoding. Also uses toCStringLen (not toZString)
// to handle embedded null bytes in binary strings.
pub fn js_btoa(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 1) return w.UNDEFINED;
    const temp_alloc = std.heap.c_allocator;

    const utf8 = ctx.toCStringLen(argv[0]) catch return z.jsException;
    defer ctx.freeCString(utf8.ptr);

    // Decode UTF-8 → Latin-1 bytes (latin1_len <= utf8.len always holds)
    const latin1_buf = temp_alloc.alloc(u8, utf8.len) catch return z.jsException;
    defer temp_alloc.free(latin1_buf);

    var latin1_len: usize = 0;
    var i: usize = 0;
    while (i < utf8.len) {
        const byte = utf8[i];
        if (byte < 0x80) {
            // ASCII: single byte
            latin1_buf[latin1_len] = byte;
            latin1_len += 1;
            i += 1;
        } else if (byte >= 0xC0 and byte < 0xE0) {
            // 2-byte UTF-8 sequence: code points 0x80-0x7FF
            if (i + 1 >= utf8.len) return ctx.throwTypeError("btoa: invalid string");
            const cp: u32 = (@as(u32, byte & 0x1F) << 6) | @as(u32, utf8[i + 1] & 0x3F);
            if (cp > 0xFF) return ctx.throwTypeError("btoa: string contains characters outside Latin-1 range");
            latin1_buf[latin1_len] = @intCast(cp);
            latin1_len += 1;
            i += 2;
        } else {
            // 3+ byte UTF-8: code point > 0x7FF, always outside Latin-1
            return ctx.throwTypeError("btoa: string contains characters outside Latin-1 range");
        }
    }

    const latin1_data = latin1_buf[0..latin1_len];
    const encoder = std.base64.standard.Encoder;
    const alloc_len = encoder.calcSize(latin1_data.len);
    const output = temp_alloc.alloc(u8, alloc_len) catch return z.jsException;
    defer temp_alloc.free(output);

    _ = encoder.encode(output, latin1_data);

    return ctx.newString(output);
}

// __flush(): Drain all pending microtasks (Promises)
// Useful for waiting on React 19's async scheduler to complete
pub fn js_flush(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const rt = qjs.JS_GetRuntime(ctx_ptr);
    drainMicrotasksGCSafe(rt, ctx_ptr);
    return w.UNDEFINED;
}

/// Drain pending microtasks with GC suppressed.
///
/// QuickJS-ng's GC can crash on corrupted `mapped_arguments` objects when
/// triggered mid-render (e.g. during Preact's microtask-scheduled VDOM diff).
/// We suppress GC during the drain and run it explicitly afterwards, when
/// all temporary objects have been properly freed.
pub fn drainMicrotasksGCSafe(rt: ?*qjs.JSRuntime, ctx_ptr: ?*qjs.JSContext) void {
    const rt_nonnull = rt orelse return;
    // Suppress GC during microtask execution
    const saved_threshold = qjs.JS_GetGCThreshold(rt_nonnull);
    qjs.JS_SetGCThreshold(rt_nonnull, std.math.maxInt(usize));

    var ctx_out: ?*qjs.JSContext = ctx_ptr;
    var iterations: u32 = 0;
    const max_iterations: u32 = 10000;

    while (iterations < max_iterations) : (iterations += 1) {
        const ret = qjs.JS_ExecutePendingJob(rt_nonnull, &ctx_out);
        if (ret <= 0) break;
    }

    // Restore threshold and run GC now that we're in a safe state
    qjs.JS_SetGCThreshold(rt_nonnull, saved_threshold);
}

// atob: ASCII to Binary (Base64 Decode)
pub fn js_atob(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = z.wrapper.Context.from(ctx_ptr);
    if (argc < 1) return z.wrapper.UNDEFINED;
    const temp_alloc = std.heap.c_allocator;

    const str = ctx.toZString(argv[0]) catch return z.jsException;
    defer ctx.freeZString(str);

    const decoder = std.base64.standard.Decoder;
    const alloc_len = decoder.calcSizeForSlice(str) catch return ctx.throwTypeError("Invalid Base64");

    const output = temp_alloc.alloc(u8, alloc_len) catch return z.jsException;
    defer temp_alloc.free(output);

    decoder.decode(output, str) catch return ctx.throwTypeError("Invalid Base64");

    return ctx.newString(output);
}

// arrayBufferToBase64DataUri(arrayBuffer, contentType)
// Converts raw ArrayBuffer bytes to a base64-encoded data URI string entirely in Zig.
// Returns: "data:{contentType};base64,{encoded}"
pub fn js_arrayBufferToBase64DataUri(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 2) return ctx.throwTypeError("arrayBufferToBase64DataUri requires 2 arguments");
    const temp_alloc = std.heap.c_allocator;

    // Get raw bytes from ArrayBuffer or TypedArray
    var data_len: usize = 0;
    var data_ptr: ?[*]u8 = null;

    // Try ArrayBuffer first
    data_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &data_len, argv[0]);
    if (data_ptr == null) {
        // Try TypedArray (Uint8Array etc.)
        var byte_offset: usize = 0;
        var byte_len: usize = 0;
        var bytes_per_elem: usize = 0;
        const ab = qjs.JS_GetTypedArrayBuffer(ctx.ptr, argv[0], &byte_offset, &byte_len, &bytes_per_elem);
        if (ctx.isException(ab)) {
            return ctx.throwTypeError("First argument must be an ArrayBuffer or TypedArray");
        }
        defer ctx.freeValue(ab);
        var ab_size: usize = 0;
        data_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &ab_size, ab);
        if (data_ptr) |p| {
            data_ptr = p + byte_offset;
            data_len = byte_len;
        }
    }

    if (data_ptr == null) return ctx.throwTypeError("Could not read ArrayBuffer data");
    const data = data_ptr.?[0..data_len];

    // Get content type string
    const content_type = ctx.toCStringLen(argv[1]) catch return ctx.throwTypeError("Second argument must be a string");
    defer ctx.freeCString(content_type.ptr);

    // Base64 encode
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(data.len);

    // Build: "data:" + contentType + ";base64," + encoded
    const prefix_len = 5; // "data:"
    const mid_len = 8; // ";base64,"
    const total_len = prefix_len + content_type.len + mid_len + b64_len;

    const output = temp_alloc.alloc(u8, total_len) catch return z.jsException;
    defer temp_alloc.free(output);

    // Write prefix
    @memcpy(output[0..5], "data:");
    @memcpy(output[5 .. 5 + content_type.len], content_type);
    @memcpy(output[5 + content_type.len .. 5 + content_type.len + 8], ";base64,");

    // Encode directly into the output buffer
    _ = encoder.encode(output[prefix_len + content_type.len + mid_len ..], data);

    return ctx.newString(output);
}

pub fn install(ctx: w.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    // navigator — headless browser identity (must be set before any scripts run)
    {
        const nav_obj = ctx.newObject();
        try ctx.setPropertyStr(nav_obj, "userAgent", ctx.newString(
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Zexplorer/1.0",
        ));
        try ctx.setPropertyStr(nav_obj, "platform", ctx.newString("Linux x86_64"));
        try ctx.setPropertyStr(nav_obj, "language", ctx.newString("en-US"));
        try ctx.setPropertyStr(nav_obj, "maxTouchPoints", ctx.newInt32(0));
        try ctx.setPropertyStr(nav_obj, "cookieEnabled", w.FALSE);
        try ctx.setPropertyStr(nav_obj, "onLine", w.TRUE);
        try ctx.setPropertyStr(global, "navigator", nav_obj);
    }

    const env_polyfill =
        \\if (typeof globalThis.process === 'undefined') {
        \\    globalThis.process = { env: { NODE_ENV: 'production' } };
        \\}
    ;
    const env_result = qjs.JS_Eval(ctx.ptr, env_polyfill, env_polyfill.len, "<polyfill:env>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(env_result);

    // React/Preact needs to attach global listeners (e.g. "resize", "unhandledrejection")
    const window_events_polyfill =
        \\(function() {
        \\    const listeners = new Map();
        \\
        \\    globalThis.addEventListener = function(event, callback) {
        \\        if (!listeners.has(event)) listeners.set(event, new Set());
        \\        listeners.get(event).add(callback);
        \\    };
        \\
        \\    globalThis.removeEventListener = function(event, callback) {
        \\        if (listeners.has(event)) {
        \\            listeners.get(event).delete(callback);
        \\        }
        \\    };
        \\
        \\
        \\    globalThis.dispatchEvent = function(event) {
        \\        if (listeners.has(event.type)) {
        \\            listeners.get(event.type).forEach(cb => {
        \\                try { cb(event); } catch(e) { console.error(e); }
        \\            });
        \\        }
        \\        return true;
        \\    };
        \\})();
    ;
    const we_result = qjs.JS_Eval(ctx.ptr, window_events_polyfill, window_events_polyfill.len, "<polyfill:window_events>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(we_result);

    // HTML/SVG element constructors that frameworks check at startup
    // React 19: `instanceof window.HTMLIFrameElement`
    // Vue 3: `instanceof SVGElement` during mount
    const html_types_polyfill =
        \\(function() {
        \\    if (typeof globalThis.HTMLIFrameElement === 'undefined') {
        \\        globalThis.HTMLIFrameElement = class HTMLIFrameElement {};
        \\    }
        \\    if (typeof globalThis.SVGElement === 'undefined') {
        \\        globalThis.SVGElement = class SVGElement {};
        \\    }
        \\    if (typeof globalThis.Element === 'undefined') {
        \\        globalThis.Element = class Element {};
        \\    }
        \\})();
    ;
    const ht_result = qjs.JS_Eval(ctx.ptr, html_types_polyfill, html_types_polyfill.len, "<polyfill:html_types>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(ht_result);

    // Browser error types that React may check with instanceof
    const browser_types_polyfill =
        \\(function() {
        \\    if (typeof globalThis.DOMException === 'undefined') {
        \\        class DOMException extends Error {
        \\            constructor(message, name) {
        \\                super(message);
        \\                this.name = name || 'DOMException';
        \\                this.code = 0;
        \\            }
        \\        }
        \\        globalThis.DOMException = DOMException;
        \\    }
        \\    if (typeof globalThis.AbortController === 'undefined') {
        \\        class AbortSignal {
        \\            constructor() { this.aborted = false; this.onabort = null; }
        \\        }
        \\        class AbortController {
        \\            constructor() { this.signal = new AbortSignal(); }
        \\            abort() { this.signal.aborted = true; if (this.signal.onabort) this.signal.onabort(); }
        \\        }
        \\        globalThis.AbortController = AbortController;
        \\        globalThis.AbortSignal = AbortSignal;
        \\    }
        \\})();
    ;
    const bt_result = qjs.JS_Eval(ctx.ptr, browser_types_polyfill, browser_types_polyfill.len, "<polyfill:browser_types>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(bt_result);

    const btoa = ctx.newCFunction(js_btoa, "btoa", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "btoa", btoa);

    const atob = ctx.newCFunction(js_atob, "atob", 1);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "atob", atob);

    // __flush: drain pending microtasks (useful for React 19 async scheduler)
    const flush = ctx.newCFunction(js_flush, "__flush", 0);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "__flush", flush);

    // arrayBufferToBase64DataUri: native base64 data URI encoding
    const ab_to_b64 = ctx.newCFunction(js_arrayBufferToBase64DataUri, "arrayBufferToBase64DataUri", 2);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "arrayBufferToBase64DataUri", ab_to_b64);

    // requestAnimationFrame / cancelAnimationFrame polyfill
    // Uses setTimeout(cb, 0) for immediate execution in headless environment
    const raf_polyfill =
        \\(function() {
        \\    let callbacks = [];
        \\    let pending = false;
        \\    let idCounter = 0;
        \\
        \\    globalThis.requestAnimationFrame = function(callback) {
        \\        const id = ++idCounter;
        \\        callbacks.push({id, callback});
        \\        if (!pending) {
        \\            pending = true;
        \\            // Use a microtask to schedule the flush.
        \\            // This ensures all rAFs called in the same sync block of code
        \\            // are batched together.
        \\            Promise.resolve().then(function() {
        \\                pending = false;
        \\                const now = Date.now();
        \\                const cbs = callbacks;
        \\                callbacks = []; // Clear before calling, in case they queue more frames
        \\                for (let ci = 0; ci < cbs.length; ci++) {
        \\                    const item = cbs[ci];
        \\                    try {
        \\                        item.callback(now);
        \\                    } catch (e) {
        \\                        console.log("RAF[" + ci + "/" + cbs.length + "] error:", e);
        \\                        if (e && e.message) console.log("  msg:", e.message);
        \\                        if (e && e.stack) console.log("  stack:", e.stack.split('\n').slice(0, 5).join('\n'));
        \\                    }
        \\                }
        \\            });
        \\        }
        \\        return id;
        \\    };
        \\
        \\    globalThis.cancelAnimationFrame = function(id) {
        \\        callbacks = callbacks.filter(cb => cb.id !== id);
        \\    };
        \\})();
    ;
    const result = qjs.JS_Eval(ctx.ptr, raf_polyfill, raf_polyfill.len, "<polyfill:raf>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(result);

    const msg_channel_polyfill =
        \\(function() {
        \\    // MessageEvent: React 19 scheduler checks `event instanceof MessageEvent`
        \\    if (typeof globalThis.MessageEvent === 'undefined') {
        \\        class MessageEvent {
        \\            constructor(type, init) {
        \\                this.type = type || 'message';
        \\                this.data = init && init.data !== undefined ? init.data : null;
        \\                this.origin = init && init.origin || '';
        \\                this.lastEventId = init && init.lastEventId || '';
        \\                this.source = init && init.source || null;
        \\                this.ports = init && init.ports || [];
        \\                this.bubbles = false;
        \\                this.cancelable = false;
        \\            }
        \\        }
        \\        globalThis.MessageEvent = MessageEvent;
        \\    }
        \\
        \\    if (globalThis.MessageChannel) return; // Don't polyfill if it exists
        \\
        \\    class MessagePort {
        \\        constructor() {
        \\            this.onmessage = null;
        \\            this._other = null;
        \\            this._closed = false;
        \\            this._queue = [];
        \\        }
        \\        postMessage(data) {
        \\            if (this._closed) return;
        \\            if (this._other) {
        \\                this._other._queue.push(data);
        \\                // Schedule a microtask to deliver the message
        \\                Promise.resolve().then(() => {
        \\                    if (this._other && !this._other._closed && this._other.onmessage) {
        \\                        const message = this._other._queue.shift();
        \\                        if (message !== undefined) {
        \\                            try {
        \\                                this._other.onmessage(new MessageEvent('message', { data: message }));
        \\                            } catch(e) {
        \\                                console.log("Error in MessagePort onmessage:", e);
        \\                            }
        \\                        }
        \\                    }
        \\                });
        \\            }
        \\        }
        \\        start() {}
        \\        close() {
        \\            if (!this._closed) {
        \\                this._closed = true;
        \\                if (this._other) {
        \\                    this._other.close();
        \\                }
        \\            }
        \\        }
        \\    }
        \\
        \\    class MessageChannel {
        \\        constructor() {
        \\            this.port1 = new MessagePort();
        \\            this.port2 = new MessagePort();
        \\            this.port1._other = this.port2;
        \\            this.port2._other = this.port1;
        \\        }
        \\    }
        \\    globalThis.MessageChannel = MessageChannel;
        \\    globalThis.MessagePort = MessagePort;
        \\})();
    ;
    const mc_result = qjs.JS_Eval(ctx.ptr, msg_channel_polyfill, msg_channel_polyfill.len, "<polyfill:msgchannel>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(mc_result);

    const mutation_observer_polyfill =
        \\(function() {
        \\    if (globalThis.MutationObserver) return;
        \\
        \\    class MutationObserver {
        \\        constructor(callback) {
        \\            // This is a stub. The callback will never be called.
        \\            // It's here to prevent "MutationObserver is not a constructor" errors.
        \\        }
        \\        observe(target, options) { /* Do nothing */ }
        \\        disconnect() { /* Do nothing */ }
        \\        takeRecords() { return []; }
        \\    }
        \\
        \\    globalThis.MutationObserver = MutationObserver;
        \\})();
    ;
    const mo_result = qjs.JS_Eval(ctx.ptr, mutation_observer_polyfill, mutation_observer_polyfill.len, "<polyfill:mutation_observer>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(mo_result);

    const event_handler_polyfill =
        \\(function() {
        \\    const events = ['click', 'dblclick', 'mousedown', 'mouseup', 'mouseover', 'mouseout', 'mousemove', 'mouseenter', 'mouseleave', 'keydown', 'keyup', 'keypress', 'submit', 'input', 'change', 'focus', 'blur', 'load', 'error', 'scroll', 'resize'];
        \\
        \\    events.forEach(event => {
        \\        const prop = 'on' + event;
        \\        const privateProp = '_' + prop;
        \\        const guardProp = '__guard_' + prop;
        \\
        \\        Object.defineProperty(HTMLElement.prototype, prop, {
        \\            configurable: true,
        \\            enumerable: true,
        \\            get() {
        \\                return this[privateProp] || null;
        \\            },
        \\            set(handler) {
        \\                // 1. RECURSION GUARD: Stop if we are already handling this property
        \\                if (this[guardProp]) return;
        \\                this[guardProp] = true;
        \\
        \\                try {
        \\                    // 2. Remove old handler
        \\                    if (this[privateProp]) {
        \\                        this.removeEventListener(event, this[privateProp]);
        \\                    }
        \\                    
        \\                    // 3. Add new handler
        \\                    if (typeof handler === 'function') {
        \\                        this[privateProp] = handler;
        \\                        this.addEventListener(event, handler);
        \\                    } else {
        \\                        this[privateProp] = null;
        \\                    }
        \\                } finally {
        \\                    // 4. Release Guard
        \\                    this[guardProp] = false;
        \\                }
        \\            }
        \\        });
        \\    });
        \\})();
    ;
    const eh_result = qjs.JS_Eval(ctx.ptr, event_handler_polyfill, event_handler_polyfill.len, "<polyfill:events>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(eh_result);

}

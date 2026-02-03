const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// btoa: Binary to ASCII (Base64 Encode)
pub fn js_btoa(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return w.UNDEFINED;
    const temp_alloc = std.heap.c_allocator;

    const str = ctx.toZString(argv[0]) catch return z.jsException;
    defer ctx.freeZString(str);

    const encoder = std.base64.standard.Encoder;
    const alloc_len = encoder.calcSize(str.len);
    const output = temp_alloc.alloc(u8, alloc_len) catch return z.jsException;
    defer temp_alloc.free(output);

    _ = encoder.encode(output, str);

    return ctx.newString(output);
}

// atob: ASCII to Binary (Base64 Decode)
pub fn js_atob(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = z.wrapper.Context{ .ptr = ctx_ptr };
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

pub fn install(ctx: w.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const env_polyfill =
        \\if (typeof globalThis.process === 'undefined') {
        \\    globalThis.process = { env: { NODE_ENV: 'production' } };
        \\}
    ;
    const env_result = qjs.JS_Eval(ctx.ptr, env_polyfill, env_polyfill.len, "<polyfill:env>", qjs.JS_EVAL_TYPE_GLOBAL);
    ctx.freeValue(env_result);

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
        \\                for (const item of cbs) {
        \\                    try {
        \\                        item.callback(now);
        \\                    } catch (e) {
        \\                        console.log("Error in requestAnimationFrame callback:", e);
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
        \\                                this._other.onmessage({ data: message });
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

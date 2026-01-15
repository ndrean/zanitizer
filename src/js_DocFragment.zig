const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// 1. We don't define a struct, we use the Lexbor opaque type
const Fragment = z.DocumentFragment;
pub var class_id: z.qjs.JSClassID = 0;

// 2. Finalizer (Crucial!)
pub fn finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    // We need the class ID to unwrap securely
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr) |p| {
        const frag: *Fragment = @ptrCast(@alignCast(p));
        // Call your existing helper from fragment_template.zig
        z.destroyDocumentFragment(frag);
    }
}

// 3. Constructor
pub fn constructor(
    ctx_ptr: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    // We need a context document to create a fragment.
    // Usually we use the global document associated with the context.
    const doc = rc.global_document orelse return ctx.throwTypeError("No document context");

    // Call your existing helper
    const fragment = z.createDocumentFragment(doc) catch return w.EXCEPTION;

    // Create the JS Object
    const proto = qjs.JS_GetPropertyStr(ctx_ptr, new_target, "prototype");
    const obj = qjs.JS_NewObjectProtoClass(ctx_ptr, proto, class_id);
    qjs.JS_FreeValue(ctx_ptr, proto);

    // Link C pointer to JS Object
    _ = qjs.JS_SetOpaque(obj, fragment);
    return obj;
}

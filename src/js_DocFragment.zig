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
        // Call helper from fragment_template.zig
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

    const fragment = z.createDocumentFragment(doc) catch return w.EXCEPTION;

    // Create the JS Object
    const proto = ctx.getPropertyStr(new_target, "prototype");
    const obj = ctx.newObjectProtoClass(proto, class_id);
    defer ctx.freeValue(proto);

    // Link C pointer to JS Object
    ctx.setOpaque(obj, fragment) catch return w.EXCEPTION;
    return obj;
}

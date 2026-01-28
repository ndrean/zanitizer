const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

const Fragment = z.DocumentFragment;

pub fn finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    if (ptr) |p| {
        const frag: *Fragment = @ptrCast(@alignCast(p));
        // Call helper from fragment_template.zig
        z.destroyDocumentFragment(frag);
    }
}

// Constructor
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
    const obj = ctx.newObjectProtoClass(proto, rc.classes.document_fragment);
    defer ctx.freeValue(proto);

    // Link C pointer to JS Object
    ctx.setOpaque(obj, fragment) catch return w.EXCEPTION;
    return obj;
}

pub const DocFragmentBridge = struct {
    pub fn install(ctx: w.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt = ctx.getRuntime();
        if (rc.classes.document_fragment == 0)
            rc.classes.document_fragment = rt.newClassID();

        try rt.newClass(rc.classes.document_fragment, .{
            .class_name = "DocumentFragment",
            // [FIX] Use the finalizer you defined at the top of this file!
            .finalizer = finalizer,
        });

        // Prototype (Inherits from Node)
        const proto = ctx.newObject();
        if (rc.classes.dom_node != 0) {
            const node_proto = ctx.getClassProto(rc.classes.dom_node);
            defer ctx.freeValue(node_proto);
            try ctx.setPrototype(proto, node_proto);
        }

        const ctor = ctx.newCFunction2(constructor, "DocumentFragment", 0, z.qjs.JS_CFUNC_constructor, 0);
        ctx.setConstructor(ctor, proto);
        ctx.setClassProto(rc.classes.document_fragment, proto);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        try ctx.setPropertyStr(global, "DocumentFragment", ctor);
    }
};

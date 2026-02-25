const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DOMBridge = z.dom_bridge.DOMBridge;

/// Stateless — exists only to satisfy the class/opaque pattern.
const XMLSerializerState = struct {};

fn finalizer(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const opaque_ptr = qjs.JS_GetRuntimeOpaque(rt_ptr);
    if (opaque_ptr == null) return;
    const runtime: *w.Runtime = @ptrCast(@alignCast(opaque_ptr));
    const class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr) |p| {
        const self: *XMLSerializerState = @ptrCast(@alignCast(p));
        runtime.allocator.destroy(self);
    }
}

fn constructor(
    ctx_ptr: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = rc.allocator.create(XMLSerializerState) catch return ctx.throwOutOfMemory();
    self.* = .{};
    const proto = ctx.getPropertyStr(new_target, "prototype");
    defer ctx.freeValue(proto);
    const obj = qjs.JS_NewObjectProtoClass(ctx.ptr, proto, rc.classes.xml_serializer);
    _ = qjs.JS_SetOpaque(obj, self);
    return obj;
}

/// serializeToString(node) → string
fn serializeToString(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("serializeToString requires 1 argument");

    const rc = RuntimeContext.get(ctx);

    // unwrapNode handles dom_node, html_element, and document_fragment
    const node: *z.DomNode = DOMBridge.unwrapNode(ctx, argv[0]) orelse
        return ctx.throwTypeError("Argument is not a Node");

    const html = z.outerNodeHTML(rc.allocator, node) catch
        return ctx.throwInternalError("Serialization failed");
    defer rc.allocator.free(html);

    return ctx.newString(html);
}

pub const XMLSerializerBridge = struct {
    pub fn install(ctx: w.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt_ptr = qjs.JS_GetRuntime(ctx.ptr);

        // Register class on the runtime once; ID persists in rc.classes.
        if (rc.classes.xml_serializer == 0) {
            var class_id: qjs.JSClassID = 0;
            _ = qjs.JS_NewClassID(rt_ptr, &class_id);
            rc.classes.xml_serializer = class_id;

            const class_def = qjs.JSClassDef{
                .class_name = "XMLSerializer",
                .finalizer = finalizer,
            };
            _ = qjs.JS_NewClass(rt_ptr, class_id, &class_def);
        }

        // Per-context: prototype + constructor + global (always)
        const proto = ctx.newObject();
        defer ctx.freeValue(proto);
        try ctx.setPropertyStr(proto, "serializeToString", ctx.newCFunction(serializeToString, "serializeToString", 1));

        const ctor = ctx.newCFunction2(constructor, "XMLSerializer", 0, qjs.JS_CFUNC_constructor, 0);
        try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
        qjs.JS_SetClassProto(ctx.ptr, rc.classes.xml_serializer, ctx.dupValue(proto));

        // Expose globally
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        try ctx.setPropertyStr(global, "XMLSerializer", ctor);
    }
};

const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const bindings = @import("bindings_generated.zig");

// Finalizer
pub fn Finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    if (ptr) |p| {
        const parser: *z.DOMParser = @ptrCast(@alignCast(p));
        parser.deinit();
        parser.allocator.destroy(parser);
    }
}

// Constructor: new DOMParser()
pub fn constructor(
    ctx_ptr: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    // 1. Allocate on Heap
    const parser = rc.allocator.create(z.DOMParser) catch return w.EXCEPTION;

    // 2. Initialize (this returns the struct by value, so we assign to pointer)
    parser.* = z.DOMParser.init(rc.allocator) catch {
        rc.allocator.destroy(parser);
        return ctx.throwTypeError("Failed to init parser: ");
    };

    // 3. Create JS Object
    const proto = ctx.getPropertyStr(new_target, "prototype");
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, rc.classes.dom_parser);

    // 4. Attach
    ctx.setOpaque(obj, parser) catch return w.EXCEPTION;

    return obj;
}

pub const DOMParserBridge = struct {
    pub fn install(ctx: w.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt = ctx.getRuntime();

        // 1. Register Class
        if (rc.classes.dom_parser == 0) {
            rc.classes.dom_parser = rt.newClassID();
        }

        try rt.newClass(rc.classes.dom_parser, .{
            .class_name = "DOMParser",
            .finalizer = Finalizer,
        });

        // 2. Prototype & Bindings
        const proto = ctx.newObject();
        bindings.installDOMParserBindings(ctx.ptr, proto);

        const ctor = ctx.newCFunction2(constructor, "DOMParser", 0, z.qjs.JS_CFUNC_constructor, 0);
        ctx.setConstructor(ctor, proto);
        ctx.setClassProto(rc.classes.dom_parser, proto);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        try ctx.setPropertyStr(global, "DOMParser", ctor);
    }
};

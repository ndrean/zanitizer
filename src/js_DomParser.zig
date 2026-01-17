const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// Public ID
pub var class_id: z.qjs.JSClassID = 0;

// Finalizer
pub fn finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr) |p| {
        const parser: *z.DOMParser = @ptrCast(@alignCast(p));
        // 1. Clean up internal parser resources
        parser.deinit();
        // 2. Free the struct memory itself (since we allocated it in constructor)
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
    const ctx = w.Context{ .ptr = ctx_ptr };
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

    const obj = ctx.newObjectProtoClass(proto, class_id);

    // 4. Attach
    ctx.setOpaque(obj, parser) catch return w.EXCEPTION;

    return obj;
}

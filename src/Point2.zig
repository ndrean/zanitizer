const std = @import("std");
const z = @import("root.zig");
const w = z.wrapper;
const qjs = z.qjs;
const ClassBuilder = @import("class_builder.zig").ClassBuilder;

// ============================================================================
// 1. Define your data structure
// ============================================================================

pub const Point = struct {
    x: f64,
    y: f64,
};

// ============================================================================
// 2. Define custom methods (only what's NOT auto-generated)
// ============================================================================

/// Custom method: calculate distance from origin
fn js_norm(
    ctx_ptr: ?*qjs.JSContext,
    this: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const opaque_ptr = qjs.JS_GetOpaque2(ctx.ptr, this, PointClass.class_id);
    if (opaque_ptr == null) return ctx.throwTypeError("Invalid this");

    const instance: *Point = @ptrCast(@alignCast(opaque_ptr));
    const dist = @sqrt(instance.x * instance.x + instance.y * instance.y);

    return ctx.newFloat64(dist);
}

// ============================================================================
// 3. Build the class with ClassBuilder (auto-generates everything else!)
// ============================================================================

pub const PointClass = ClassBuilder.build(Point, .{
    .class_name = "Point",
    .custom_methods = &.{
        .{ .name = "norm", .func = js_norm },
    },
});

// ============================================================================
// 4. Public API
// ============================================================================

/// Register the Point class with the JavaScript context
pub fn register(ctx: w.Context) !void {
    try PointClass.register(ctx);
}

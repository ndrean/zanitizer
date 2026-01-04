const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;

// 1. The Native Data Structure
pub const Point = struct {
    x: f64,
    y: f64,
};

// Global Class ID (allocated once at startup)
var point_class_id: w.ClassID = 0;

// Finalizer
pub fn finalizer(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const opaque_ptr = qjs.JS_GetRuntimeOpaque(rt_ptr);
    const rt: *w.Runtime = @ptrCast(@alignCast(opaque_ptr));
    const allocator = rt.allocator;

    const ptr = qjs.JS_GetOpaque(val, point_class_id);
    if (ptr != null) {
        const point: *Point = @ptrCast(@alignCast(ptr));
        std.debug.print("[Zig] GC: Freeing Point({d}, {d})\n", .{ point.x, point.y });
        allocator.destroy(point);
    }
}

// Constructor
fn constructor(
    ctx_ptr: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const allocator = ctx.getAllocator();

    var x: f64 = 0;
    var y: f64 = 0;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx_ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx_ptr, &y, argv[1]);

    const pt = allocator.create(Point) catch return qjs.JS_ThrowOutOfMemory(ctx.ptr);
    pt.* = .{ .x = x, .y = y };

    const proto = qjs.JS_GetPropertyStr(ctx_ptr, new_target, "prototype");
    if (qjs.JS_IsException(proto)) {
        allocator.destroy(pt);
        return w.EXCEPTION;
    }
    const obj = qjs.JS_NewObjectProtoClass(ctx_ptr, proto, point_class_id);
    qjs.JS_FreeValue(ctx_ptr, proto);
    if (qjs.JS_IsException(obj)) {
        allocator.destroy(pt);
        return w.EXCEPTION;
    }

    _ = qjs.JS_SetOpaque(obj, pt);
    std.debug.print("[Zig] Constructor: Created Point({d}, {d})\n", .{ x, y });
    return obj;
}

// Method: distance
fn distance(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ptr = qjs.JS_GetOpaque2(ctx_ptr, this_val, point_class_id);
    if (ptr == null) return w.EXCEPTION;

    const pt: *Point = @ptrCast(@alignCast(ptr));
    const dist = @sqrt(pt.x * pt.x + pt.y * pt.y);

    return qjs.JS_NewFloat64(ctx_ptr, dist);
}

// Getter: x
fn get_x(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ptr = qjs.JS_GetOpaque2(ctx_ptr, this_val, point_class_id);
    if (ptr == null) return w.EXCEPTION;
    const pt: *Point = @ptrCast(@alignCast(ptr));
    return qjs.JS_NewFloat64(ctx_ptr, pt.x);
}

// Setter: x
fn set_x(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ptr = qjs.JS_GetOpaque2(ctx_ptr, this_val, point_class_id);
    if (ptr == null) return w.EXCEPTION;

    const pt: *Point = @ptrCast(@alignCast(ptr));
    const val = argv[0];
    var new_x: f64 = 0;
    if (qjs.JS_ToFloat64(ctx_ptr, &new_x, val) != 0) return w.EXCEPTION;
    pt.x = new_x;

    // FIX 1: Use w.UNDEFINED instead of qjs.JS_UNDEFINED
    return w.UNDEFINED;
}

fn get_y(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ptr = qjs.JS_GetOpaque2(ctx_ptr, this_val, point_class_id);
    if (ptr == null) return w.EXCEPTION;
    return qjs.JS_NewFloat64(ctx_ptr, @as(*Point, @ptrCast(@alignCast(ptr))).y);
}

fn set_y(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ptr = qjs.JS_GetOpaque2(ctx_ptr, this_val, point_class_id);
    if (ptr == null) return w.EXCEPTION;
    var val: f64 = 0;
    if (qjs.JS_ToFloat64(ctx_ptr, &val, argv[0]) != 0) return w.EXCEPTION;
    @as(*Point, @ptrCast(@alignCast(ptr))).y = val;
    return w.UNDEFINED;
}

pub fn install(rt: *w.Runtime, ctx: w.Context) !void {
    if (point_class_id == 0) {
        point_class_id = rt.newClassID();
    }

    try rt.newClass(point_class_id, .{
        .class_name = "Point",
        .finalizer = finalizer,
    });

    const proto = ctx.newObject();
    // defer ctx.freeValue(proto);

    const dist_fn = ctx.newCFunction(distance, "distance", 0);
    try ctx.setPropertyStr(proto, "distance", dist_fn);

    const atom_x = ctx.newAtom("x");
    defer ctx.freeAtom(atom_x);
    const getter_x = ctx.newCFunction(get_x, "get x", 0);
    const setter_x = ctx.newCFunction(set_x, "set x", 1);
    _ = try ctx.definePropertyGetSet(
        proto,
        atom_x,
        getter_x,
        setter_x,
        .{
            .configurable = true,
            .enumerable = true,
            .writable = false, // Required by Zig (even if unused for get/set)
            .normal = false, // Required
            .getset = false, // Required
        },
    );

    const getter_y = ctx.newCFunction(get_y, "get y", 0);
    const setter_y = ctx.newCFunction(set_y, "set y", 1);
    const atom_y = ctx.newAtom("y");
    defer ctx.freeAtom(atom_y);
    _ = try ctx.definePropertyGetSet(
        proto,
        atom_y,
        getter_y,
        setter_y,
        .{ .configurable = true, .enumerable = true, .writable = false, .normal = false, .getset = false },
    );

    // FIX 2: Initialize ALL fields of the packed struct

    ctx.setClassProto(point_class_id, proto);

    const ctor = ctx.newCFunction2(constructor, "Point", 2, qjs.JS_CFUNC_constructor, 0);
    ctx.setConstructor(ctor, proto);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    _ = try ctx.setPropertyStr(global, "Point", ctor);
}

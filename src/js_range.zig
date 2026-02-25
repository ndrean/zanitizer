const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DOMBridge = @import("dom_bridge.zig").DOMBridge;

pub const RangeObject = struct {
    // We only store the "Start" node.
    // For this benchmark, "End" is usually "After Last Child", so we assume "Rest of list"
    // if end_container is not set or matches start.
    // A full implementation would store start/end containers and offsets.

    start_node: ?*z.DomNode = null, // The child node to start at
    end_node: ?*z.DomNode = null, // The child node to end at (exclusive)
    common_parent: ?*z.DomNode = null,
};

/// Type-safe helper to unwrap an object using a known Class ID
pub fn getPtr(comptime T: type, val: qjs.JSValue, class_id: qjs.JSClassID) ?*T {
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

// ============================================================================
// JS METHODS
// ============================================================================

fn setStartBefore(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const self = getPtr(RangeObject, this_val, rc.classes.range) orelse return ctx.throwTypeError("Not a Range");

    // -- Logic ---
    const node = DOMBridge.unwrapNode(ctx, argv[0]) orelse return ctx.throwTypeError("Argument 1 must be a Node");
    self.start_node = node;
    self.common_parent = z.parentNode(node);

    return zqjs.UNDEFINED;
}

fn setEndAfter(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const rc = RuntimeContext.get(zqjs.Context.from(ctx_ptr));
    const ctx = zqjs.Context.from(ctx_ptr);
    const this = getPtr(RangeObject, this_val, rc.classes.range) orelse return ctx.throwTypeError("Not a Range");

    const node = DOMBridge.unwrapNode(ctx, argv[0]) orelse return ctx.throwTypeError("Argument 1 must be a Node");

    // Logic: If we are setting end AFTER a node, the boundary is the next sibling.
    // If nextSibling is null, we are at the end.
    if (z.nextSibling(node)) |next| {
        this.end_node = next;
    } else {
        this.end_node = null; // null implies "End of List"
    }

    return zqjs.UNDEFINED;
}

fn selectNodeContents(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(RangeObject, this_val, rc.classes.range) orelse return ctx.throwTypeError("Not a Range");

    const node = DOMBridge.unwrapNode(ctx, argv[0]) orelse return ctx.throwTypeError("Argument 1 must be a Node");

    // selectNodeContents(node) sets the range to span all children of node
    self.common_parent = node;
    self.start_node = z.firstChild(node);
    self.end_node = null; // null = end of children

    return zqjs.UNDEFINED;
}

fn insertNode(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = getPtr(RangeObject, this_val, rc.classes.range) orelse return ctx.throwTypeError("Not a Range");

    const new_node = DOMBridge.unwrapNode(ctx, argv[0]) orelse return ctx.throwTypeError("Argument 1 must be a Node");
    const parent = self.common_parent orelse return zqjs.UNDEFINED;

    // insertNode inserts at the start of the range
    if (self.start_node) |ref_node| {
        // Insert before the start node (lexbor: insertBefore(reference, new))
        z.insertBefore(ref_node, new_node);
    } else {
        // No start node = empty range or range covers all children; append
        z.appendChild(parent, new_node);
    }

    return zqjs.UNDEFINED;
}

fn deleteContents(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const rc = RuntimeContext.get(zqjs.Context.from(ctx_ptr));
    const ctx = zqjs.Context.from(ctx_ptr);
    const this = getPtr(RangeObject, this_val, rc.classes.range) orelse return ctx.throwTypeError("Not a Range");

    const parent = this.common_parent orelse return zqjs.UNDEFINED;

    // ITERATE AND DELETE
    // We start at start_node and delete until we hit end_node (or null)

    var curr = this.start_node;
    const limit = this.end_node; // If null, go to end

    // Safety check: ensure curr is actually a child of parent?
    // Lexbor is generally safe, but usually we'd trust the logic.

    while (curr) |node| {
        // Stop if we reached the limit
        if (limit) |l| {
            if (node == l) break;
        }

        // Save next before deleting current
        const next = z.nextSibling(node);
        // Remove from DOM
        _ = z.removeChild(parent, node);
        curr = next;
    }

    return zqjs.UNDEFINED;
}

// ============================================================================
// BOILERPLATE
// ============================================================================

fn range_finalizer(rt_ptr: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const opaque_ptr = qjs.JS_GetRuntimeOpaque(rt_ptr);
    if (opaque_ptr == null) return;

    // Cast to the Wrapper's Runtime type to get the allocator
    const runtime: *zqjs.Runtime = @ptrCast(@alignCast(opaque_ptr));
    const allocator = runtime.allocator;

    // 2. Get the Class ID dynamically from the object itself
    // (We know it is a Range because this finalizer is only used for Range)
    const class_id = qjs.JS_GetClassID(val);

    // 3. Unwrap and Destroy
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr) |p| {
        const range: *RangeObject = @ptrCast(@alignCast(p));
        allocator.destroy(range);
    }
}

pub const RangeBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const rt_ptr = qjs.JS_GetRuntime(ctx.ptr);
        const rc = RuntimeContext.get(ctx);

        if (rc.classes.range == 0) {
            var class_id: z.qjs.JSClassID = 0;
            _ = z.qjs.JS_NewClassID(rt_ptr, &class_id);
            rc.classes.range = class_id;

            const class_def = qjs.JSClassDef{
                .class_name = "Range",
                .finalizer = range_finalizer,
            };
            _ = qjs.JS_NewClass(rt_ptr, class_id, &class_def);
        }

        // Prototype
        const proto = ctx.newObject();
        defer ctx.freeValue(proto);

        try ctx.setPropertyStr(proto, "setStartBefore", ctx.newCFunction(setStartBefore, "setStartBefore", 1));
        try ctx.setPropertyStr(proto, "setEndAfter", ctx.newCFunction(setEndAfter, "setEndAfter", 1));
        try ctx.setPropertyStr(proto, "selectNodeContents", ctx.newCFunction(selectNodeContents, "selectNodeContents", 1));
        try ctx.setPropertyStr(proto, "insertNode", ctx.newCFunction(insertNode, "insertNode", 1));
        try ctx.setPropertyStr(proto, "deleteContents", ctx.newCFunction(deleteContents, "deleteContents", 0));

        const ctor = ctx.newCFunction2(js_Range_constructor, "Range", 0, qjs.JS_CFUNC_constructor, 0);
        try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
        qjs.JS_SetClassProto(ctx.ptr, rc.classes.range, ctx.dupValue(proto));

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        try ctx.setPropertyStr(global, "Range", ctor);
    }
};

fn js_Range_constructor(ctx_ptr: ?*qjs.JSContext, new_target: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    const proto = ctx.getPropertyStr(new_target, "prototype");
    const obj = qjs.JS_NewObjectProtoClass(ctx.ptr, proto, rc.classes.range);
    ctx.freeValue(proto);

    const self = rt.allocator.create(RangeObject) catch return ctx.throwOutOfMemory();
    self.* = .{};

    _ = qjs.JS_SetOpaque(obj, self);
    return obj;
}

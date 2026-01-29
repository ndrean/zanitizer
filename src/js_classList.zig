//! DOMTokenList implementation for element.classList
//! Lightweight "view" pattern - stores HTMLElement pointer, manipulates class attribute directly

const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

/// Helper: Unwrap 'this' (DOMTokenList) to get the underlying HTMLElement
fn getElement(ctx: w.Context, this_val: qjs.JSValue) !*z.HTMLElement {
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.dom_token_list);
    if (ptr == null) return error.NotDOMTokenList;
    return @ptrCast(@alignCast(ptr));
}

// ============================================================================
// DOMTokenList Methods
// ============================================================================

/// classList.add(token1, token2, ...)
pub fn add(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const el = getElement(ctx, this_val) catch |err| {
        if (err == error.NotDOMTokenList) {
            return ctx.throwTypeError("'this' is not a DOMTokenList");
        }
        return w.EXCEPTION;
    };

    if (argc < 1) return w.UNDEFINED;

    // Use lightweight addClass (no HashMap overhead)
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const token = ctx.toZString(argv[@intCast(i)]) catch return w.EXCEPTION;
        defer ctx.freeZString(token);
        z.addClass(rc.allocator, el, token) catch return w.EXCEPTION;
    }

    return w.UNDEFINED;
}

/// classList.remove(token1, token2, ...)
pub fn remove(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    if (argc < 1) return w.UNDEFINED;

    // Use lightweight removeClass (no HashMap overhead)
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const token = ctx.toZString(argv[@intCast(i)]) catch return w.EXCEPTION;
        defer ctx.freeZString(token);
        z.removeClass(rc.allocator, el, token) catch return w.EXCEPTION;
    }

    return w.UNDEFINED;
}

/// classList.toggle(token, force?) -> boolean
pub fn toggle(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    if (argc < 1) return ctx.throwTypeError("toggle requires at least 1 argument");

    const token = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(token);

    // Check for optional 'force' argument
    if (argc >= 2 and !ctx.isUndefined(argv[1])) {
        const force = qjs.JS_ToBool(ctx_ptr, argv[1]) != 0;
        const result = z.toggleClassForce(rc.allocator, el, token, force) catch return w.EXCEPTION;
        return ctx.newBool(result);
    }

    // Standard toggle (no HashMap overhead)
    const result = z.toggleClass(rc.allocator, el, token) catch return w.EXCEPTION;
    return ctx.newBool(result);
}

/// classList.contains(token) -> boolean
pub fn contains(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    if (argc < 1) return ctx.throwTypeError("contains requires 1 argument");

    const token = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(token);

    // Use lightweight hasClass (O(n) but no allocation)
    const result = z.hasClass(el, token);
    return ctx.newBool(result);
}

/// classList.replace(oldToken, newToken) -> boolean
pub fn replace(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    if (argc < 2) return ctx.throwTypeError("replace requires 2 arguments");

    const old_token = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(old_token);

    const new_token = ctx.toZString(argv[1]) catch return w.EXCEPTION;
    defer ctx.freeZString(new_token);

    var cl = z.ClassList.init(rc.allocator, el) catch return w.EXCEPTION;
    defer cl.deinit();

    const result = cl.replace(old_token, new_token) catch return w.EXCEPTION;
    return ctx.newBool(result);
}

/// classList.item(index) -> string | null
pub fn item(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    if (argc < 1) return w.NULL;

    var index_i64: i64 = 0;
    if (qjs.JS_ToInt64(ctx_ptr, &index_i64, argv[0]) != 0) return w.NULL;
    if (index_i64 < 0) return w.NULL;
    const index: usize = @intCast(index_i64);

    var cl = z.ClassList.init(rc.allocator, el) catch return w.EXCEPTION;
    defer cl.deinit();

    const slice = cl.toSlice(rc.allocator) catch return w.EXCEPTION;
    defer rc.allocator.free(slice);

    if (index >= slice.len) return w.NULL;
    return ctx.newString(slice[index]);
}

// ============================================================================
// DOMTokenList Properties (Getters)
// ============================================================================

/// classList.length -> number
pub fn get_length(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    _: c_int,
    _: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    // Count classes by iterating (lightweight, no allocation)
    const class_attr = z.getAttribute_zc(el, "class") orelse return ctx.newInt32(0);

    var count: i32 = 0;
    var iterator = std.mem.splitScalar(u8, class_attr, ' ');
    while (iterator.next()) |class| {
        const trimmed = std.mem.trim(u8, class, " \t\n\r");
        if (trimmed.len > 0) count += 1;
    }

    return ctx.newInt32(count);
}

/// classList.value -> string (the class attribute value)
pub fn get_value(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    _: c_int,
    _: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    const class_attr = z.classList_zc(el);
    return ctx.newString(class_attr);
}

/// classList.value = "foo bar" (setter)
pub fn set_value(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };

    const el = getElement(ctx, this_val) catch return ctx.throwTypeError("'this' is not a DOMTokenList");

    if (argc < 1) return w.UNDEFINED;

    const val = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(val);

    z.setAttribute(el, "class", val) catch return w.EXCEPTION;

    return w.UNDEFINED;
}

// ============================================================================
// HTMLElement.classList Accessor
// ============================================================================

pub fn install(ctx: w.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    if (rc.classes.dom_token_list == 0) {
        rc.classes.dom_token_list = rt.newClassID();
    }

    // Register Class (View-only, no finalizer needed)
    try rt.newClass(rc.classes.dom_token_list, .{
        .class_name = "DOMTokenList",
        .finalizer = null,
    });

    // Prototype
    const proto = ctx.newObject();

    // Methods
    _ = qjs.JS_SetPropertyStr(ctx.ptr, proto, "add", qjs.JS_NewCFunction(ctx.ptr, add, "add", 1));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, proto, "remove", qjs.JS_NewCFunction(ctx.ptr, remove, "remove", 1));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, proto, "toggle", qjs.JS_NewCFunction(ctx.ptr, toggle, "toggle", 1));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, proto, "contains", qjs.JS_NewCFunction(ctx.ptr, contains, "contains", 1));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, proto, "replace", qjs.JS_NewCFunction(ctx.ptr, replace, "replace", 2));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, proto, "item", qjs.JS_NewCFunction(ctx.ptr, item, "item", 1));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, proto, "toString", qjs.JS_NewCFunction(ctx.ptr, get_value, "toString", 0));

    // Accessors (length, value)
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "length");
        const get = qjs.JS_NewCFunction2(ctx.ptr, get_length, "get_length", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }
    {
        const atom = qjs.JS_NewAtom(ctx.ptr, "value");
        const get = qjs.JS_NewCFunction2(ctx.ptr, get_value, "get_value", 0, qjs.JS_CFUNC_generic, 0);
        const set = qjs.JS_NewCFunction2(ctx.ptr, set_value, "set_value", 1, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get, set, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        qjs.JS_FreeAtom(ctx.ptr, atom);
    }

    // Set Class Prototype
    ctx.setClassProto(rc.classes.dom_token_list, proto);
}

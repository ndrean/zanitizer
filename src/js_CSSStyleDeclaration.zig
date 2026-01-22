const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

/// Helper: Unwrap 'this' (CSSStyleDeclaration) to get the underlying HTMLElement
fn getElement(ctx: w.Context, this_val: qjs.JSValue) !*z.HTMLElement {
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.css_style_decl);
    if (ptr == null) return error.CSSStyleDeclaration;
    return @ptrCast(@alignCast(ptr));
}

/// style.getPropertyValue(prop)
pub fn getPropertyValue(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const el = getElement(ctx, this_val) catch |err| {
        if (err == error.CSSStyleDeclaration) {
            std.debug.print("Not a CSSStyleDeclaration object", .{});
            return ctx.throwTypeError("Not a CSSStyleDeclaration object");
        } else {
            return w.EXCEPTION;
        }
    };

    if (argc < 1) return ctx.throwTypeError("getPropertyValue requires 1 argument");

    const prop_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(prop_str);

    // Use getInlineStyle
    const val = z.getInlineStyle(rc.allocator, el, prop_str) catch |err|
        return ctx.throwTypeError(@errorName(err).ptr);
    defer if (val) |v| rc.allocator.free(v);

    if (val) |v| return ctx.newString(v);
    return ctx.newString("");
}

/// style.setProperty(prop, val)
pub fn setProperty(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const el = getElement(ctx, this_val) catch return w.EXCEPTION;
    if (argc < 2) return ctx.throwTypeError("setProperty requires 2 arguments");

    const prop = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(prop);

    const val = ctx.toZString(argv[1]) catch return w.EXCEPTION;
    defer ctx.freeZString(val);

    z.setStyleProperty(rc.allocator, el, prop, val) catch |err| return ctx.throwTypeError(@errorName(err).ptr);
    return w.UNDEFINED;
}

/// style.removeProperty(prop)
pub fn removeProperty(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const el = getElement(ctx, this_val) catch return w.EXCEPTION;
    if (argc < 1) return ctx.throwTypeError("removeProperty requires 1 argument");

    const prop = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(prop);

    const old_val = z.getInlineStyle(rc.allocator, el, prop) catch null;
    defer if (old_val) |v| rc.allocator.free(v);

    z.setStyleProperty(rc.allocator, el, prop, "") catch |err|
        return ctx.throwTypeError(@errorName(err).ptr);

    if (old_val) |v| return ctx.newString(v);
    return ctx.newString("");
}

// HTMLElement.style Accessors -----------------------

/// Getter: element.style
/// Signature matches JS_CFUNC_getter: fn(ctx, this) -> Value
pub fn get_element_style(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    _: c_int,
    _: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("Not an HTMLElement");

    const obj = ctx.newObjectClass(rc.classes.css_style_decl);
    ctx.setOpaque(obj, ptr) catch return w.EXCEPTION;
    return obj;
}

/// Setter: element.style = "color: red;"
/// Signature matches JS_CFUNC_setter: fn(ctx, this, val) -> Value
pub fn set_element_style(
    ctx_ptr: ?*qjs.JSContext,
    this_val: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("Not an HTMLElement");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

    // Safety check for arguments
    if (argc < 1) return ctx.throwTypeError("Setter requires a value");

    // [FIX] Get value from argv[0] (Standard Generic Call)
    const css_text = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(css_text);

    z.removeAttribute(el, "style") catch return w.EXCEPTION;
    z.setAttribute(el, "style", css_text) catch return w.EXCEPTION;

    return w.UNDEFINED;
}

/// window.getComputedStyle(el)
pub fn window_getComputedStyle(
    ctx_ptr: ?*qjs.JSContext,
    _: w.Value,
    argc: c_int,
    argv: [*c]w.Value,
) callconv(.c) w.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("getComputedStyle requires 1 argument");

    const ptr = qjs.JS_GetOpaque(argv[0], rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("Argument 1 must be an Element");

    // Return CSSStyleDeclaration wrapping the element
    const obj = ctx.newObjectClass(rc.classes.css_style_decl);
    ctx.setOpaque(obj, ptr) catch return w.EXCEPTION;

    return obj;
}
// const std = @import("std");
// const z = @import("root.zig");
// const w = @import("wrapper.zig");
// const qjs = z.qjs;
// const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// /// Helper: Unwrap 'this' (CSSStyleDeclaration) to get the underlying HTMLElement
// fn getElement(ctx: w.Context, this_val: qjs.JSValue) !*z.HTMLElement {
//     const rc = RuntimeContext.get(ctx);
//     const ptr = qjs.JS_GetOpaque(this_val, rc.classes.css_style_decl);
//     // is the stored'this' actually a CSSStyleDeclaratio?
//     if (ptr == null) return error.CSSStyleDeclaration;
//     return @ptrCast(@alignCast(ptr));
// }

// /// style.getPropertyValue(prop)
// pub fn getPropertyValue(
//     ctx_ptr: ?*qjs.JSContext,
//     this_val: qjs.JSValue,
//     argc: c_int,
//     argv: [*c]qjs.JSValue,
// ) callconv(.c) qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);
//     const el = getElement(ctx, this_val) catch |err| {
//         if (err == error.CSSStyleDeclaration) {
//             return ctx.throwTypeError("Not a CSSStyleDeclaration object");
//         } else {
//             return w.EXCEPTION;
//         }
//     };

//     if (argc < 1) return ctx.throwTypeError("getPropertyValue requires 1 argument");

//     const prop_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
//     defer ctx.freeZString(prop_str);

//     // Use getInlineStyle (strip "prop: " prefix)
//     const val = z.getInlineStyle(rc.allocator, el, prop_str) catch |err| return ctx.throwTypeError(@errorName(err).ptr);
//     defer if (val) |v| rc.allocator.free(v);

//     if (val) |v| return ctx.newString(v);
//     return ctx.newString("");
// }

// /// style.setProperty(prop, val)
// pub fn setProperty(
//     ctx_ptr: ?*qjs.JSContext,
//     this_val: qjs.JSValue,
//     argc: c_int,
//     argv: [*c]qjs.JSValue,
// ) callconv(.c) qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);
//     // Unwrap 'this' to get HTMLElement
//     const el = getElement(ctx, this_val) catch return w.EXCEPTION;

//     if (argc < 2) return ctx.throwTypeError("setProperty requires 2 arguments");

//     const prop = ctx.toZString(argv[0]) catch return w.EXCEPTION;
//     defer ctx.freeZString(prop);

//     const val = ctx.toZString(argv[1]) catch return w.EXCEPTION;
//     defer ctx.freeZString(val);
//     z.setStyleProperty(rc.allocator, el, prop, val) catch |err| return ctx.throwTypeError(@errorName(err).ptr);
//     return w.UNDEFINED;
// }

// /// style.removeProperty(prop)
// pub fn removeProperty(
//     ctx_ptr: ?*qjs.JSContext,
//     this_val: qjs.JSValue,
//     argc: c_int,
//     argv: [*c]qjs.JSValue,
// ) callconv(.c) qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);
//     const el = getElement(ctx, this_val) catch return w.EXCEPTION;

//     if (argc < 1) return ctx.throwTypeError("removeProperty requires 1 argument");

//     const prop = ctx.toZString(argv[0]) catch return w.EXCEPTION;
//     defer ctx.freeZString(prop);

//     const old_val = z.getInlineStyle(rc.allocator, el, prop) catch null;
//     defer if (old_val) |v| rc.allocator.free(v);
//     z.setStyleProperty(rc.allocator, el, prop, "") catch |err| return ctx.throwTypeError(@errorName(err).ptr);

//     if (old_val) |v| return ctx.newString(v);
//     return ctx.newString("");
// }

// // --- Getter/Setter for HTMLElement.style ---

// /// Getter: element.style
// /// Returns a CSSStyleDeclaration object that wraps the element.
// pub fn get_element_style(
//     ctx_ptr: ?*qjs.JSContext,
//     this_val: qjs.JSValue,
//     _: c_int,
//     _: [*c]qjs.JSValue,
// ) callconv(.c) qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);

//     // Ensure 'this' is an HTMLElement
//     const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
//     if (ptr == null) return ctx.throwTypeError("Not an HTMLElement");

//     // Return a CSSStyleDeclaration Wrapper: It wraps the SAME pointer, but uses the CSSStyleDeclaration Class ID
//     const obj = ctx.newObjectClass(rc.classes.css_style_decl);
//     ctx.setOpaque(obj, ptr) catch return w.EXCEPTION;

//     return obj;
// }

// /// Setter: element.style = "color: red;"
// /// Takes a string and updates the 'style' attribute.
// pub fn set_element_style(
//     ctx_ptr: ?*qjs.JSContext,
//     this_val: qjs.JSValue,
//     _: c_int,
//     argv: [*c]qjs.JSValue,
// ) callconv(.c) qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = @import("runtime_context.zig").RuntimeContext.get(ctx);

//     // Ensure 'this' is an HTMLElement
//     const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
//     if (ptr == null) return ctx.throwTypeError("Not an HTMLElement");
//     const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

//     // Get String Argument
//     const css_text = ctx.toZString(argv[0]) catch return w.EXCEPTION;
//     defer ctx.freeZString(css_text);

//     // Update Attribute
//     z.removeAttribute(el, "style") catch return w.EXCEPTION;
//     z.setAttribute(el, "style", css_text) catch return w.EXCEPTION;

//     return w.UNDEFINED;
// }

// // --- Window Functions ---

// /// window.getComputedStyle(el)
// pub fn window_getComputedStyle(
//     ctx_ptr: ?*qjs.JSContext,
//     _: qjs.JSValue,
//     argc: c_int,
//     argv: [*c]qjs.JSValue,
// ) callconv(.c) qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = @import("runtime_context.zig").RuntimeContext.get(ctx);

//     if (argc < 1) return ctx.throwTypeError("getComputedStyle requires 1 argument");

//     const ptr = qjs.JS_GetOpaque(argv[0], rc.classes.html_element);
//     if (ptr == null) return ctx.throwTypeError("Argument 1 must be an Element");

//     // Return CSSStyleDeclaration wrapping the element
//     const obj = ctx.newObjectClass(rc.classes.css_style_decl);
//     ctx.setOpaque(obj, ptr) catch return w.EXCEPTION;

//     return obj;
// }

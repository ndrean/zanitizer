//! DOMStringMap implementation for element.dataset
//! Provides proxy-like behavior for data-* attributes with camelCase property access
//!
//! Usage: element.dataset.userId = "123" → data-user-id="123"
//!        element.dataset.userId → "123"

const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

/// Helper: Unwrap 'this' (DOMStringMap) to get the underlying HTMLElement
fn getElement(ctx: w.Context, this_val: qjs.JSValue) !*z.HTMLElement {
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.dom_string_map);
    if (ptr == null) return error.NotDOMStringMap;
    return @ptrCast(@alignCast(ptr));
}

// ============================================================================
// Exotic Methods for property interception
// ============================================================================

/// Get property handler: dataset.camelKey → data-kebab-key
fn exoticGetProperty(
    ctx_ptr: ?*qjs.JSContext,
    obj: qjs.JSValue,
    prop: qjs.JSAtom,
    receiver: qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = receiver;
    const ctx = w.Context{ .ptr = ctx_ptr };

    // Get the element from opaque data
    const el = getElement(ctx, obj) catch return w.UNDEFINED;

    // Convert atom to string
    var prop_len: usize = 0;
    const prop_cstr = qjs.JS_AtomToCStringLen(ctx_ptr, &prop_len, prop);
    if (prop_cstr == null) return w.UNDEFINED;
    defer qjs.JS_FreeCString(ctx_ptr, prop_cstr);

    const prop_str = prop_cstr[0..prop_len];

    // Skip Symbol properties and built-in properties
    if (prop_len == 0) return w.UNDEFINED;

    // Get the data attribute
    const value = z.getDataAttribute(el, prop_str) orelse return w.UNDEFINED;
    return ctx.newString(value);
}

/// Set property handler: dataset.camelKey = value → data-kebab-key="value"
fn exoticSetProperty(
    ctx_ptr: ?*qjs.JSContext,
    obj: qjs.JSValue,
    prop: qjs.JSAtom,
    value: qjs.JSValue,
    receiver: qjs.JSValue,
    flags: c_int,
) callconv(.c) c_int {
    _ = receiver;
    _ = flags;
    const ctx = w.Context{ .ptr = ctx_ptr };

    // Get the element from opaque data
    const el = getElement(ctx, obj) catch return 0;

    // Convert atom to string
    var prop_len: usize = 0;
    const prop_cstr = qjs.JS_AtomToCStringLen(ctx_ptr, &prop_len, prop);
    if (prop_cstr == null) return 0;
    defer qjs.JS_FreeCString(ctx_ptr, prop_cstr);

    const prop_str = prop_cstr[0..prop_len];

    // Convert value to string
    const val_str = ctx.toZString(value) catch return 0;
    defer ctx.freeZString(val_str);

    // Set the data attribute
    z.setDataAttribute(el, prop_str, val_str) catch return 0;
    return 1; // Success
}

/// Delete property handler: delete dataset.camelKey → remove data-kebab-key
fn exoticDeleteProperty(
    ctx_ptr: ?*qjs.JSContext,
    obj: qjs.JSValue,
    prop: qjs.JSAtom,
) callconv(.c) c_int {
    const ctx = w.Context{ .ptr = ctx_ptr };

    // Get the element from opaque data
    const el = getElement(ctx, obj) catch return 0;

    // Convert atom to string
    var prop_len: usize = 0;
    const prop_cstr = qjs.JS_AtomToCStringLen(ctx_ptr, &prop_len, prop);
    if (prop_cstr == null) return 0;
    defer qjs.JS_FreeCString(ctx_ptr, prop_cstr);

    const prop_str = prop_cstr[0..prop_len];

    // Remove the data attribute
    z.removeDataAttribute(el, prop_str) catch return 0;
    return 1; // Success
}

/// Has property handler: "camelKey" in dataset
fn exoticHasProperty(
    ctx_ptr: ?*qjs.JSContext,
    obj: qjs.JSValue,
    prop: qjs.JSAtom,
) callconv(.c) c_int {
    const ctx = w.Context{ .ptr = ctx_ptr };

    // Get the element from opaque data
    const el = getElement(ctx, obj) catch return 0;

    // Convert atom to string
    var prop_len: usize = 0;
    const prop_cstr = qjs.JS_AtomToCStringLen(ctx_ptr, &prop_len, prop);
    if (prop_cstr == null) return 0;
    defer qjs.JS_FreeCString(ctx_ptr, prop_cstr);

    const prop_str = prop_cstr[0..prop_len];

    // Check if data attribute exists
    return if (z.hasDataAttribute(el, prop_str)) 1 else 0;
}

/// Get own property for Object.keys(), for...in, etc.
fn exoticGetOwnProperty(
    ctx_ptr: ?*qjs.JSContext,
    desc: ?*qjs.JSPropertyDescriptor,
    obj: qjs.JSValue,
    prop: qjs.JSAtom,
) callconv(.c) c_int {
    const ctx = w.Context{ .ptr = ctx_ptr };

    // Get the element from opaque data
    const el = getElement(ctx, obj) catch return 0;

    // Convert atom to string
    var prop_len: usize = 0;
    const prop_cstr = qjs.JS_AtomToCStringLen(ctx_ptr, &prop_len, prop);
    if (prop_cstr == null) return 0;
    defer qjs.JS_FreeCString(ctx_ptr, prop_cstr);

    const prop_str = prop_cstr[0..prop_len];

    // Check if this data attribute exists
    const value = z.getDataAttribute(el, prop_str) orelse return 0;

    // Fill in the property descriptor if requested
    if (desc) |d| {
        d.flags = qjs.JS_PROP_ENUMERABLE | qjs.JS_PROP_WRITABLE | qjs.JS_PROP_CONFIGURABLE;
        d.value = ctx.newString(value);
        d.getter = w.UNDEFINED;
        d.setter = w.UNDEFINED;
    }

    return 1; // Property exists
}

/// Get own property names for Object.keys() and for...in iteration
fn exoticGetOwnPropertyNames(
    ctx_ptr: ?*qjs.JSContext,
    ptab: [*c][*c]qjs.JSPropertyEnum,
    plen: [*c]u32,
    obj: qjs.JSValue,
) callconv(.c) c_int {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    // Get the element from opaque data
    const el = getElement(ctx, obj) catch {
        ptab.* = null;
        plen.* = 0;
        return 0;
    };

    // Get all data-* attributes
    const entries = z.getDataAttributes(rc.allocator, el) catch {
        ptab.* = null;
        plen.* = 0;
        return 0;
    };
    defer z.freeDataAttributes(rc.allocator, entries);

    if (entries.len == 0) {
        ptab.* = null;
        plen.* = 0;
        return 0;
    }

    // Allocate property enum array using QuickJS malloc
    const tab: [*c]qjs.JSPropertyEnum = @ptrCast(@alignCast(
        qjs.js_malloc(ctx_ptr, entries.len * @sizeOf(qjs.JSPropertyEnum)),
    ));
    if (tab == null) {
        ptab.* = null;
        plen.* = 0;
        return -1; // Error
    }

    // Fill in property names
    for (entries, 0..) |entry, i| {
        tab[i].is_enumerable = true;
        tab[i].atom = qjs.JS_NewAtomLen(ctx_ptr, entry.key.ptr, entry.key.len);
    }

    ptab.* = tab;
    plen.* = @intCast(entries.len);
    return 0; // Success
}

/// Define own property handler for Object.defineProperty()
fn exoticDefineOwnProperty(
    ctx_ptr: ?*qjs.JSContext,
    obj: qjs.JSValue,
    prop: qjs.JSAtom,
    val: qjs.JSValue,
    getter: qjs.JSValue,
    setter: qjs.JSValue,
    flags: c_int,
) callconv(.c) c_int {
    _ = getter;
    _ = setter;
    _ = flags;

    // For simple data properties, just set the value
    return exoticSetProperty(ctx_ptr, obj, prop, val, obj, 0);
}

/// Exotic methods structure for DOMStringMap
const exotic_methods = qjs.JSClassExoticMethods{
    .get_own_property = exoticGetOwnProperty,
    .get_own_property_names = exoticGetOwnPropertyNames,
    .delete_property = exoticDeleteProperty,
    .define_own_property = exoticDefineOwnProperty,
    .has_property = exoticHasProperty,
    .get_property = exoticGetProperty,
    .set_property = exoticSetProperty,
};

// ============================================================================
// Installation
// ============================================================================

pub fn install(ctx: w.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    if (rc.classes.dom_string_map == 0) {
        rc.classes.dom_string_map = rt.newClassID();
    }

    // Register Class with exotic methods
    try rt.newClass(rc.classes.dom_string_map, .{
        .class_name = "DOMStringMap",
        .finalizer = null, // View-only, no cleanup needed
        .exotic = &exotic_methods,
    });

    // Create prototype (empty for DOMStringMap - all access is via exotic handlers)
    const proto = ctx.newObject();
    ctx.setClassProto(rc.classes.dom_string_map, proto);
}

//! Template-based QuickJS binding generator
//! Simplified version using string interpolation instead of line-by-line building
//!
//! Usage:
//! ```sh
//! zig run tools/template_gen.zig -- src/temp_bindings.zig
//! ```

const std = @import("std");

// ============================================================================
// TYPE DEFINITIONS (copied from gen_bindings.zig for self-containment)
// ============================================================================

pub const BindingKind = enum {
    static,
    method,
    property,
    boolean_attribute,
    string_attribute,
};

pub const BindingSpec = struct {
    name: []const u8,
    kind: BindingKind,
    attr_name: ?[]const u8 = null,

    zig_func_name: []const u8 = "",
    args: []const ArgType = &.{},
    return_type: ReturnType = .void_type,

    getter: []const u8 = "",
    setter: []const u8 = "",
    prop_type: ReturnType = .void_type,
    prop_this: ArgType = .this_element,
};

pub const ArgType = union(enum) {
    allocator,
    context,
    callback,
    dom_bridge,
    js_value,

    this_parser,
    this_event,
    this_element,
    this_node,
    this_document,
    element,
    node,
    document,
    document_root,

    string,
    int32,
    uint32,
    boolean,
};

const ReturnType = union(enum) {
    void_type,
    void_with_error,
    element,
    optional_element,
    node,
    optional_node,
    document,
    owned_document,

    string,
    string_zc,
    optional_string,
    int32,
    uint32,
    boolean,
    error_boolean,

    error_string,
    error_document,
    error_owned_document,
};

const bindings_def = @import("bindings.zig");
const bindings = bindings_def.bindings;

// ============================================================================
// TEMPLATES - Complete function bodies with {placeholders}
// ============================================================================

const T = struct {
    // ========================================================================
    // BOOLEAN ATTRIBUTE (disabled, hidden, checked)
    // ========================================================================
    const BOOLEAN_ATTR_GETTER =
        \\// Boolean Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    return ctx.newBool(z.hasAttribute(el, "{s}"));
        \\}}
        \\
    ;

    const BOOLEAN_ATTR_SETTER =
        \\// Boolean Setter for {s}
        \\pub fn js_set_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const val = qjs.JS_ToBool(ctx_ptr, argv[0]) != 0;
        \\    if (val) {{
        \\        z.setAttribute(el, "{s}", "") catch return w.EXCEPTION;
        \\    }} else {{
        \\        z.removeAttribute(el, "{s}") catch return w.EXCEPTION;
        \\    }}
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // STRING ATTRIBUTE (id, title, lang, dir, role, nonce)
    // ========================================================================
    const STRING_ATTR_GETTER =
        \\// Reflected String Getter for {s} -> {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const val_opt = z.getAttribute(rc.allocator, el, "{s}") catch return w.EXCEPTION;
        \\    if (val_opt) |val| {{
        \\        defer rc.allocator.free(val);
        \\        return ctx.newString(val);
        \\    }}
        \\    return ctx.newString("");
        \\}}
        \\
    ;

    const STRING_ATTR_SETTER =
        \\// Reflected String Setter for {s} -> {s}
        \\pub fn js_set_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(val_str);
        \\    z.setAttribute(el, "{s}", val_str) catch return w.EXCEPTION;
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // NODE PROPERTY - Optional Node (firstChild, nextSibling, etc.)
    // ========================================================================
    const NODE_PROP_OPT_NODE_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return w.EXCEPTION;
        \\    const result = {s}(node);
        \\    if (result) |n| return DOMBridge.wrapNode(ctx, n) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // NODE PROPERTY - String Zero-Copy (textContent, nodeValue, innerText)
    // ========================================================================
    const NODE_PROP_STRING_ZC_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return w.EXCEPTION;
        \\    const result = {s}(node);
        \\    return ctx.newString(result);
        \\}}
        \\
    ;

    const NODE_PROP_STRING_ZC_SETTER =
        \\// Property Setter for {s}
        \\pub fn js_set_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node");
        \\    const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(val_str);
        \\    {s}(node, val_str) catch |err| {{
        \\        std.debug.print("JS Setter Error ({s}): {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error in Setter");
        \\    }};
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // NODE METHOD - Void (appendChild, insertBefore, remove)
    // ========================================================================
    const NODE_METHOD_VOID =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    {s}
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node");
        \\    {s}
        \\    {s}(node{s});
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // NODE METHOD - Optional Node (parentNode, cloneNode)
    // ========================================================================
    const NODE_METHOD_OPT_NODE =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    {s}
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node");
        \\    {s}
        \\    const result = {s}(node{s});
        \\    if (result) |n| return DOMBridge.wrapNode(ctx, n) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // ELEMENT PROPERTY - Error String (innerHTML)
    // ========================================================================
    const ELEMENT_PROP_ERROR_STRING_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an HTMLElement");
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(rc.allocator, el) catch return w.EXCEPTION;
        \\    defer rc.allocator.free(result);
        \\    return ctx.newString(result);
        \\}}
        \\
    ;

    const ELEMENT_PROP_ERROR_STRING_SETTER =
        \\// Property Setter for {s}
        \\pub fn js_set_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return ctx.throwTypeError("Setter called on object that is not an HTMLElement");
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(val_str);
        \\    {s}(el, val_str) catch |err| {{
        \\        std.debug.print("JS Setter Error ({s}): {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error in Setter");
        \\    }};
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // ELEMENT PROPERTY - String Zero-Copy (className)
    // ========================================================================
    const ELEMENT_PROP_STRING_ZC_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an HTMLElement");
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(el);
        \\    return ctx.newString(result);
        \\}}
        \\
    ;

    // ========================================================================
    // ELEMENT PROPERTY - Optional Node (content for <template>)
    // ========================================================================
    const ELEMENT_PROP_OPT_NODE_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an HTMLElement");
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(el);
        \\    if (result) |n| return DOMBridge.wrapNode(ctx, n) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // ELEMENT PROPERTY - Optional Element (nextElementSibling, lastElementChild)
    // ========================================================================
    const ELEMENT_PROP_OPT_ELEMENT_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an HTMLElement");
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(el);
        \\    if (result) |e| return DOMBridge.wrapElement(ctx, e) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // ELEMENT METHOD - Void with Error (setAttribute, removeAttribute)
    // ========================================================================
    const ELEMENT_METHOD_VOID_ERROR =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    {s}
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    {s}
        \\    {s}(el{s}) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // ELEMENT METHOD - Optional String (getAttribute)
    // ========================================================================
    const ELEMENT_METHOD_OPT_STRING =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const arg_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(arg_str);
        \\    const result = {s}(el, arg_str);
        \\    if (result) |str| return ctx.newString(str);
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // DOCUMENT METHOD - Element (createElement)
    // ========================================================================
    const DOC_METHOD_ELEMENT =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const doc: *z.HTMLDocument = blk: {{
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        return ctx.throwTypeError("Method called on object that is not a Document");
        \\    }};
        \\    const arg_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(arg_str);
        \\    const result = {s}(doc, arg_str) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    return DOMBridge.wrapElement(ctx, result) catch w.EXCEPTION;
        \\}}
        \\
    ;

    // ========================================================================
    // DOCUMENT METHOD - Node (createTextNode)
    // ========================================================================
    const DOC_METHOD_NODE =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const doc: *z.HTMLDocument = blk: {{
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        return ctx.throwTypeError("Method called on object that is not a Document");
        \\    }};
        \\    const arg_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(arg_str);
        \\    const result = {s}(doc, arg_str) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    return DOMBridge.wrapNode(ctx, result) catch w.EXCEPTION;
        \\}}
        \\
    ;

    // ========================================================================
    // DOCUMENT METHOD - Optional Element (getElementById)
    // ========================================================================
    const DOC_METHOD_OPT_ELEMENT =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const doc: *z.HTMLDocument = blk: {{
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        return ctx.throwTypeError("Method called on object that is not a Document");
        \\    }};
        \\    const arg_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(arg_str);
        \\    const result = {s}(doc, arg_str);
        \\    if (result) |el| return DOMBridge.wrapElement(ctx, el) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // DOCUMENT PROPERTY - Optional Element (body)
    // ========================================================================
    const DOC_PROP_OPT_ELEMENT_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const doc: *z.HTMLDocument = blk: {{
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        if (qjs.JS_GetOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
        \\        return ctx.throwTypeError("Method called on object that is not a Document");
        \\    }};
        \\    const result = {s}(doc);
        \\    if (result) |el| return DOMBridge.wrapElement(ctx, el) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // EVENT PROPERTY - String Zero-Copy (type)
    // ========================================================================
    const EVENT_PROP_STRING_ZC_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.event);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an Event");
        \\    const ev: *z.events.DomEvent = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(ev);
        \\    return ctx.newString(result);
        \\}}
        \\
    ;

    // ========================================================================
    // EVENT PROPERTY - Boolean (bubbles)
    // ========================================================================
    const EVENT_PROP_BOOL_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.event);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an Event");
        \\    const ev: *z.events.DomEvent = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(ev);
        \\    return ctx.newBool(result);
        \\}}
        \\
    ;

    // ========================================================================
    // EVENT PROPERTY - Optional Node (target, currentTarget)
    // ========================================================================
    const EVENT_PROP_OPT_NODE_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.event);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an Event");
        \\    const ev: *z.events.DomEvent = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(ev);
        \\    if (result) |n| return DOMBridge.wrapNode(ctx, n) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // EVENT METHOD - Void (stopPropagation, preventDefault)
    // ========================================================================
    const EVENT_METHOD_VOID =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.event);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not an Event");
        \\    const ev: *z.events.DomEvent = @ptrCast(@alignCast(ptr));
        \\    {s}(ev);
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // PARSER METHOD - Owned Document (parseFromString)
    // ========================================================================
    const PARSER_METHOD_OWNED_DOC =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.dom_parser);
        \\    if (ptr == null) return ctx.throwTypeError("Object is not a DOMParser");
        \\    const parser: *z.DOMParser = @ptrCast(@alignCast(ptr));
        \\    const arg_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(arg_str);
        \\    const result = {s}(parser, arg_str) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    const doc_obj = qjs.JS_NewObjectClass(ctx_ptr, @intCast(rc.classes.owned_document));
        \\    _ = qjs.JS_SetOpaque(doc_obj, @ptrCast(result));
        \\    return doc_obj;
        \\}}
        \\
    ;

    // ========================================================================
    // STATIC METHOD - Owned Document (parseHTML)
    // ========================================================================
    const STATIC_ALLOC_OWNED_DOC =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = this_val;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const arg_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(arg_str);
        \\    const result = {s}(rc.allocator, arg_str) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    const doc_obj = qjs.JS_NewObjectClass(ctx_ptr, @intCast(rc.classes.owned_document));
        \\    _ = qjs.JS_SetOpaque(doc_obj, @ptrCast(result));
        \\    return doc_obj;
        \\}}
        \\
    ;

    // ========================================================================
    // STATIC METHOD - Optional Node (documentRoot, ownerDocument)
    // ========================================================================
    const STATIC_DOC_OPT_NODE =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv; _ = this_val;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const global = ctx.getGlobalObject();
        \\    defer ctx.freeValue(global);
        \\    const doc_obj = ctx.getPropertyStr(global, "document");
        \\    defer ctx.freeValue(doc_obj);
        \\    const native_doc = ctx.getPropertyStr(doc_obj, "_native_doc");
        \\    defer ctx.freeValue(native_doc);
        \\    const doc_ptr = qjs.JS_GetOpaque(native_doc, rc.classes.document);
        \\    if (doc_ptr == null) return w.EXCEPTION;
        \\    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));
        \\    const result = {s}(doc);
        \\    if (result) |n| return DOMBridge.wrapNode(ctx, n) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // STATIC METHOD - Node to Document (ownerDocument)
    // ========================================================================
    const STATIC_NODE_DOCUMENT =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node (or unwrap failed)");
        \\    const result = {s}(node);
        \\    const doc_obj = qjs.JS_NewObjectClass(ctx_ptr, @intCast(rc.classes.document));
        \\    _ = qjs.JS_SetOpaque(doc_obj, @ptrCast(result));
        \\    return doc_obj;
        \\}}
        \\
    ;

    // ========================================================================
    // NODE METHOD with EventListener args (addEventListener, removeEventListener)
    // ========================================================================
    const NODE_METHOD_EVENT_LISTENER =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 2) return w.EXCEPTION;
        \\    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node");
        \\    const event_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(event_str);
        \\    const callback = argv[1];
        \\    {s}(ctx, bridge, node, event_str, callback) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    // ========================================================================
    // NODE METHOD - dispatchEvent (special: js_value arg)
    // ========================================================================
    const NODE_METHOD_DISPATCH_EVENT =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node");
        \\    const event_arg = argv[0];
        \\    const result = {s}(ctx, bridge, node, event_arg) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    return ctx.newBool(result);
        \\}}
        \\
    ;

    // ========================================================================
    // NODE PROPERTY - Optional Element (firstElementChild on Node)
    // ========================================================================
    const NODE_PROP_OPT_ELEMENT_GETTER =
        \\// Property Getter for {s}
        \\pub fn js_get_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return w.EXCEPTION;
        \\    const result = {s}(node);
        \\    if (result) |el| return DOMBridge.wrapElement(ctx, el) catch w.EXCEPTION;
        \\    return w.NULL;
        \\}}
        \\
    ;

    // ========================================================================
    // ELEMENT METHOD - Allocator + Element + String (setHTML, getHTML)
    // ========================================================================
    const ELEMENT_METHOD_ALLOC_STRING_VOID =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    if (argc < 1) return w.EXCEPTION;
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const arg_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        \\    defer ctx.freeZString(arg_str);
        \\    {s}(rc.allocator, el, arg_str) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    return w.UNDEFINED;
        \\}}
        \\
    ;

    const ELEMENT_METHOD_ALLOC_STRING_RETURN =
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {{
        \\    _ = argc; _ = argv;
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\    const rc = RuntimeContext.get(ctx);
        \\    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_element);
        \\    if (ptr == null) return w.EXCEPTION;
        \\    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        \\    const result = {s}(rc.allocator, el) catch |err| {{
        \\        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        \\        std.debug.print("JS Binding Error: {{}}\n", .{{err}});
        \\        return ctx.throwTypeError("Native Zig Error");
        \\    }};
        \\    defer rc.allocator.free(result);
        \\    return ctx.newString(result);
        \\}}
        \\
    ;

    // ========================================================================
    // INSTALLER LINE Templates
    // ========================================================================
    const INSTALL_METHOD =
        \\    _ = qjs.JS_SetPropertyStr(ctx, proto, "{s}", qjs.JS_NewCFunction(ctx, js_{s}, "{s}", {d}));
        \\
    ;

    const INSTALL_PROPERTY_RO =
        \\    {{
        \\        const atom = qjs.JS_NewAtom(ctx, "{s}");
        \\        const get_fn = qjs.JS_NewCFunction2(ctx, js_get_{s}, "get_{s}", 0, qjs.JS_CFUNC_generic, 0);
        \\        const set_fn = w.UNDEFINED;
        \\        _ = qjs.JS_DefinePropertyGetSet(ctx, proto, atom, get_fn, set_fn, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        \\        qjs.JS_FreeAtom(ctx, atom);
        \\    }}
        \\
    ;

    const INSTALL_PROPERTY_RW =
        \\    {{
        \\        const atom = qjs.JS_NewAtom(ctx, "{s}");
        \\        const get_fn = qjs.JS_NewCFunction2(ctx, js_get_{s}, "get_{s}", 0, qjs.JS_CFUNC_generic, 0);
        \\        const set_fn = qjs.JS_NewCFunction2(ctx, js_set_{s}, "set_{s}", 1, qjs.JS_CFUNC_generic, 0);
        \\        _ = qjs.JS_DefinePropertyGetSet(ctx, proto, atom, get_fn, set_fn, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        \\        qjs.JS_FreeAtom(ctx, atom);
        \\    }}
        \\
    ;
};

// ============================================================================
// PATTERN CLASSIFICATION
// ============================================================================

const Pattern = enum {
    boolean_attribute,
    string_attribute,
    node_prop_opt_node,
    node_prop_opt_element,
    node_prop_string_zc,
    node_method_void,
    node_method_opt_node,
    node_method_event_listener,
    node_method_dispatch_event,
    element_prop_error_string,
    element_prop_string_zc,
    element_prop_opt_node,
    element_prop_opt_element,
    element_method_void_error,
    element_method_opt_string,
    element_method_alloc_void,
    element_method_alloc_string,
    doc_method_element,
    doc_method_node,
    doc_method_opt_element,
    doc_prop_opt_element,
    event_prop_string_zc,
    event_prop_bool,
    event_prop_opt_node,
    event_method_void,
    parser_method_owned_doc,
    static_alloc_owned_doc,
    static_doc_opt_node,
    static_node_document,
    unknown,
};

fn classifyBinding(b: anytype) Pattern {
    // 1. Special kinds first
    if (b.kind == .boolean_attribute) return .boolean_attribute;
    if (b.kind == .string_attribute) return .string_attribute;

    // Helper to detect "this" type from args
    const this_type = getThisType(b);

    // 2. Properties
    if (b.kind == .property) {
        return switch (b.prop_this) {
            .this_event => switch (b.prop_type) {
                .string_zc => .event_prop_string_zc,
                .boolean => .event_prop_bool,
                .optional_node => .event_prop_opt_node,
                else => .unknown,
            },
            .this_document => switch (b.prop_type) {
                .optional_element => .doc_prop_opt_element,
                else => .unknown,
            },
            .this_node => switch (b.prop_type) {
                .optional_node => .node_prop_opt_node,
                .optional_element => .node_prop_opt_element,
                .string_zc => .node_prop_string_zc,
                else => .unknown,
            },
            .this_element => switch (b.prop_type) {
                .error_string => .element_prop_error_string,
                .string_zc => .element_prop_string_zc,
                .optional_node => .element_prop_opt_node,
                .optional_element => .element_prop_opt_element,
                else => .unknown,
            },
            else => .unknown,
        };
    }

    // 3. Methods - check by this_type (from args) and return_type
    if (b.kind == .method) {
        return switch (this_type) {
            .this_event => .event_method_void,
            .this_parser => .parser_method_owned_doc,
            .this_document => switch (b.return_type) {
                .element => .doc_method_element,
                .node => .doc_method_node,
                .optional_element => .doc_method_opt_element,
                else => .unknown,
            },
            .this_element => blk: {
                // Check for allocator in args
                for (b.args) |arg| {
                    if (arg == .allocator) {
                        break :blk if (b.return_type == .error_string) .element_method_alloc_string else .element_method_alloc_void;
                    }
                }
                break :blk switch (b.return_type) {
                    .void_type, .void_with_error => .element_method_void_error,
                    .optional_string => .element_method_opt_string,
                    else => .unknown,
                };
            },
            .this_node => blk: {
                // Check for special event listener patterns
                for (b.args) |arg| {
                    if (arg == .callback) {
                        break :blk .node_method_event_listener;
                    }
                    if (arg == .js_value) {
                        break :blk .node_method_dispatch_event;
                    }
                }
                break :blk switch (b.return_type) {
                    .void_type => .node_method_void,
                    .optional_node => .node_method_opt_node,
                    else => .unknown,
                };
            },
            else => .unknown,
        };
    }

    // 4. Static methods
    if (b.kind == .static) {
        for (b.args) |arg| {
            if (arg == .allocator) {
                if (b.return_type == .error_owned_document) return .static_alloc_owned_doc;
            }
            if (arg == .document) {
                if (b.return_type == .optional_node) return .static_doc_opt_node;
            }
            if (arg == .this_node) {
                if (b.return_type == .document) return .static_node_document;
            }
        }
    }

    return .unknown;
}

const ThisType = enum { this_element, this_node, this_document, this_event, this_parser, other };

fn getThisType(b: anytype) ThisType {
    // Check args for this_* types, otherwise use prop_this
    for (b.args) |arg| {
        switch (arg) {
            .this_element => return .this_element,
            .this_node => return .this_node,
            .this_document => return .this_document,
            .this_event => return .this_event,
            .this_parser => return .this_parser,
            else => {},
        }
    }
    // Fall back to prop_this
    return switch (b.prop_this) {
        .this_element => .this_element,
        .this_node => .this_node,
        .this_document => .this_document,
        .this_event => .this_event,
        .this_parser => .this_parser,
        else => .other,
    };
}

// ============================================================================
// MAIN GENERATOR
// ============================================================================

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <output_file>\n", .{args[0]});
        return;
    }

    const output_file_path = args[1];

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    // Header
    try writer.writeAll(
        \\// THIS FILE IS AUTO-GENERATED BY tools/template_gen.zig
        \\// DO NOT EDIT MANUALLY
        \\
        \\const std = @import("std");
        \\const z = @import("root.zig");
        \\const w = @import("wrapper.zig");
        \\const qjs = z.qjs;
        \\const DOMBridge = @import("dom_bridge.zig").DOMBridge;
        \\const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
        \\const js_CSSStyleDeclaration = @import("js_CSSStyleDeclaration.zig");
        \\
    );

    // Generate bindings
    for (bindings) |binding| {
        try generateBinding(writer, binding);
    }

    // Generate installers
    try generateInstallers(writer);

    // Write to file
    const file = try std.fs.cwd().createFile(output_file_path, .{});
    defer file.close();
    try file.writeAll(aw.writer.buffer[0..aw.writer.end]);

    std.debug.print("Generated {s}\n", .{output_file_path});
}

fn generateBinding(writer: anytype, b: anytype) !void {
    const pattern = classifyBinding(b);
    const name = b.name;
    const attr = if (b.attr_name) |a| a else b.name;

    switch (pattern) {
        .boolean_attribute => {
            try writer.print(T.BOOLEAN_ATTR_GETTER, .{ name, name, name });
            try writer.print(T.BOOLEAN_ATTR_SETTER, .{ name, name, name, name });
        },
        .string_attribute => {
            try writer.print(T.STRING_ATTR_GETTER, .{ name, attr, name, attr });
            try writer.print(T.STRING_ATTR_SETTER, .{ name, attr, name, attr });
        },
        .node_prop_opt_node => {
            try writer.print(T.NODE_PROP_OPT_NODE_GETTER, .{ name, name, b.getter });
        },
        .node_prop_opt_element => {
            try writer.print(T.NODE_PROP_OPT_ELEMENT_GETTER, .{ name, name, b.getter });
        },
        .node_prop_string_zc => {
            try writer.print(T.NODE_PROP_STRING_ZC_GETTER, .{ name, name, b.getter });
            if (b.setter.len > 0) {
                try writer.print(T.NODE_PROP_STRING_ZC_SETTER, .{ name, name, b.setter, name });
            }
        },
        .node_method_void => {
            const argc_check = if (countJsArgs(b.args) > 0) "if (argc < 1) return w.EXCEPTION;" else "_ = argc; _ = argv;";
            const extra_args = formatExtraArgsNode(b.args);
            const extra_extract = extractExtraArgsNode(b.args);
            try writer.print(T.NODE_METHOD_VOID, .{ b.zig_func_name, name, argc_check, extra_extract, b.zig_func_name, extra_args });
        },
        .node_method_opt_node => {
            const argc_check = if (countJsArgs(b.args) > 0) "if (argc < 1) return w.EXCEPTION;" else "_ = argc; _ = argv;";
            const extra_args = formatExtraArgsNode(b.args);
            const extra_extract = extractExtraArgsNode(b.args);
            try writer.print(T.NODE_METHOD_OPT_NODE, .{ b.zig_func_name, name, argc_check, extra_extract, b.zig_func_name, extra_args });
        },
        .node_method_event_listener => {
            try writer.print(T.NODE_METHOD_EVENT_LISTENER, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .node_method_dispatch_event => {
            try writer.print(T.NODE_METHOD_DISPATCH_EVENT, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .element_prop_error_string => {
            try writer.print(T.ELEMENT_PROP_ERROR_STRING_GETTER, .{ name, name, b.getter });
            if (b.setter.len > 0) {
                try writer.print(T.ELEMENT_PROP_ERROR_STRING_SETTER, .{ name, name, b.setter, name });
            }
        },
        .element_prop_string_zc => {
            try writer.print(T.ELEMENT_PROP_STRING_ZC_GETTER, .{ name, name, b.getter });
        },
        .element_prop_opt_node => {
            try writer.print(T.ELEMENT_PROP_OPT_NODE_GETTER, .{ name, name, b.getter });
        },
        .element_prop_opt_element => {
            try writer.print(T.ELEMENT_PROP_OPT_ELEMENT_GETTER, .{ name, name, b.getter });
        },
        .element_method_void_error => {
            const argc_check = getArgcCheck(countJsArgs(b.args));
            const extra_args = formatExtraArgsElement(b.args);
            const extra_extract = extractExtraArgsElement(b.args);
            try writer.print(T.ELEMENT_METHOD_VOID_ERROR, .{ b.zig_func_name, name, argc_check, extra_extract, b.zig_func_name, extra_args });
        },
        .element_method_opt_string => {
            try writer.print(T.ELEMENT_METHOD_OPT_STRING, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .element_method_alloc_void => {
            try writer.print(T.ELEMENT_METHOD_ALLOC_STRING_VOID, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .element_method_alloc_string => {
            try writer.print(T.ELEMENT_METHOD_ALLOC_STRING_RETURN, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .doc_method_element => {
            try writer.print(T.DOC_METHOD_ELEMENT, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .doc_method_node => {
            try writer.print(T.DOC_METHOD_NODE, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .doc_method_opt_element => {
            try writer.print(T.DOC_METHOD_OPT_ELEMENT, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .doc_prop_opt_element => {
            try writer.print(T.DOC_PROP_OPT_ELEMENT_GETTER, .{ name, name, b.getter });
        },
        .event_prop_string_zc => {
            try writer.print(T.EVENT_PROP_STRING_ZC_GETTER, .{ name, name, b.getter });
        },
        .event_prop_bool => {
            try writer.print(T.EVENT_PROP_BOOL_GETTER, .{ name, name, b.getter });
        },
        .event_prop_opt_node => {
            try writer.print(T.EVENT_PROP_OPT_NODE_GETTER, .{ name, name, b.getter });
        },
        .event_method_void => {
            try writer.print(T.EVENT_METHOD_VOID, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .parser_method_owned_doc => {
            try writer.print(T.PARSER_METHOD_OWNED_DOC, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .static_alloc_owned_doc => {
            try writer.print(T.STATIC_ALLOC_OWNED_DOC, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .static_doc_opt_node => {
            try writer.print(T.STATIC_DOC_OPT_NODE, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .static_node_document => {
            try writer.print(T.STATIC_NODE_DOCUMENT, .{ b.zig_func_name, name, b.zig_func_name });
        },
        .unknown => {
            try writer.print("\n// TODO: Unknown pattern for '{s}' - needs manual implementation\n", .{name});
        },
    }
}

fn generateInstallers(writer: anytype) !void {
    // Document bindings
    try writer.writeAll("\npub fn installDocumentBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {\n");
    for (bindings) |b| {
        if (b.kind == .static or b.prop_this == .this_document) {
            try generateInstallerLine(writer, b);
        }
    }
    try writer.writeAll("}\n");

    // Node bindings
    try writer.writeAll("\npub fn installNodeBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {\n");
    for (bindings) |b| {
        if (isNodeBinding(b)) {
            try generateInstallerLine(writer, b);
        }
    }
    try writer.writeAll("}\n");

    // Element bindings
    try writer.writeAll("\npub fn installElementBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {\n");
    for (bindings) |b| {
        if (isElementBinding(b)) {
            try generateInstallerLine(writer, b);
        }
    }
    try writer.writeAll("}\n");

    // DOMParser bindings
    try writer.writeAll("\npub fn installDOMParserBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {\n");
    for (bindings) |b| {
        if (b.prop_this == .this_parser) {
            try generateInstallerLine(writer, b);
        }
    }
    try writer.writeAll("}\n");

    // Event bindings
    try writer.writeAll("\npub fn installEventBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {\n");
    for (bindings) |b| {
        if (b.prop_this == .this_event) {
            try generateInstallerLine(writer, b);
        }
    }
    try writer.writeAll("}\n");
}

fn generateInstallerLine(writer: anytype, b: anytype) !void {
    if (b.kind == .method or b.kind == .static) {
        try writer.print(T.INSTALL_METHOD, .{ b.name, b.name, b.name, countJsArgs(b.args) });
    } else {
        // Property or attribute
        if (b.setter.len > 0 or b.kind == .boolean_attribute or b.kind == .string_attribute) {
            try writer.print(T.INSTALL_PROPERTY_RW, .{ b.name, b.name, b.name, b.name, b.name });
        } else {
            try writer.print(T.INSTALL_PROPERTY_RO, .{ b.name, b.name, b.name });
        }
    }
}

fn isNodeBinding(b: anytype) bool {
    if (b.kind == .static) return false;
    return switch (b.prop_this) {
        .this_node => true,
        else => if (b.args.len > 0 and b.args[0] == .this_node) true else false,
    };
}

fn isElementBinding(b: anytype) bool {
    if (b.kind == .static) return false;
    if (isNodeBinding(b)) return false;
    return switch (b.prop_this) {
        .this_document, .this_parser, .this_event => false,
        else => true,
    };
}

fn getArgcCheck(count: usize) []const u8 {
    return switch (count) {
        0 => "_ = argc; _ = argv;",
        1 => "if (argc < 1) return w.EXCEPTION;",
        2 => "if (argc < 2) return w.EXCEPTION;",
        3 => "if (argc < 3) return w.EXCEPTION;",
        4 => "if (argc < 4) return w.EXCEPTION;",
        else => "if (argc < 1) return w.EXCEPTION;", // fallback
    };
}

fn countJsArgs(args: anytype) usize {
    var count: usize = 0;
    for (args) |arg| {
        switch (arg) {
            .string, .int32, .uint32, .boolean, .element, .node, .js_value, .callback => count += 1,
            else => {},
        }
    }
    return count;
}

fn formatExtraArgsNode(args: anytype) []const u8 {
    // For node methods, check if there's a node arg or boolean arg
    for (args) |arg| {
        switch (arg) {
            .node => return ", child",
            .boolean => return ", deep",
            else => {},
        }
    }
    return "";
}

fn extractExtraArgsNode(args: anytype) []const u8 {
    for (args) |arg| {
        switch (arg) {
            .node => return "const child = DOMBridge.unwrapNode(ctx, argv[0]) orelse return ctx.throwTypeError(\"Argument must be a Node\");",
            .boolean => return "const deep = qjs.JS_ToBool(ctx_ptr, argv[0]) != 0;",
            else => {},
        }
    }
    return "";
}

fn formatExtraArgsElement(args: anytype) []const u8 {
    var count: usize = 0;
    for (args) |arg| {
        switch (arg) {
            .string => count += 1,
            else => {},
        }
    }
    if (count == 2) return ", arg1, arg2";
    if (count == 1) return ", arg1";
    return "";
}

fn extractExtraArgsElement(args: anytype) []const u8 {
    var count: usize = 0;
    for (args) |arg| {
        if (arg == .string) count += 1;
    }
    if (count == 2) {
        return
            \\const arg1 = ctx.toZString(argv[0]) catch return w.EXCEPTION;
            \\    defer ctx.freeZString(arg1);
            \\    const arg2 = ctx.toZString(argv[1]) catch return w.EXCEPTION;
            \\    defer ctx.freeZString(arg2);
        ;
    }
    if (count == 1) {
        return
            \\const arg1 = ctx.toZString(argv[0]) catch return w.EXCEPTION;
            \\    defer ctx.freeZString(arg1);
        ;
    }
    return "";
}

const std = @import("std");
const z = @import("root.zig");
const qjs = @cImport({
    @cInclude("quickjs.h");
});

/// DOM Bridge: Maps JavaScript Window/Document API to lexbor primitives
pub const DOMBridge = struct {
    ctx: ?*anyopaque,
    doc: *z.HTMLDocument,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: ?*anyopaque) !DOMBridge {
        const doc = try z.createDocument();
        return .{
            .ctx = ctx,
            .doc = doc,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DOMBridge) void {
        z.destroyDocument(self.doc);
    }

    /// Install browser-like APIs into QuickJS global scope
    pub fn installAPIs(self: *DOMBridge) !void {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const global = qjs.JS_GetGlobalObject(ctx);
        defer qjs.JS_FreeValue(ctx, global);

        // Create document object
        try self.createDocumentAPI(global);

        // Create window object
        try self.createWindowAPI(global);

        // Add console object
        try self.createConsoleAPI(global);
    }

    fn createDocumentAPI(self: *DOMBridge, global: qjs.JSValue) !void {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const doc_obj = qjs.JS_NewObject(ctx);
        defer qjs.JS_FreeValue(ctx, doc_obj);

        // document.createElement(tagName)
        const create_element_fn = qjs.JS_NewCFunction2(
            ctx,
            js_createElement,
            "createElement",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createElement", create_element_fn);

        // document.createTextNode(text)
        const create_text_fn = qjs.JS_NewCFunction2(
            ctx,
            js_createTextNode,
            "createTextNode",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "createTextNode", create_text_fn);

        // document.querySelector(selector)
        const query_selector_fn = qjs.JS_NewCFunction2(
            ctx,
            js_querySelector,
            "querySelector",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelector", query_selector_fn);

        // document.querySelectorAll(selector)
        const query_selector_all_fn = qjs.JS_NewCFunction2(
            ctx,
            js_querySelectorAll,
            "querySelectorAll",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelectorAll", query_selector_all_fn);

        // document.body
        const body_node = z.bodyNode(self.doc);
        if (body_node) |body| {
            const body_element = z.nodeToElement(body).?;
            const body_val = try wrapElement(ctx, body_element);
            _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "body", body_val);
        }

        // Store document reference in global
        const opaque_obj = qjs.JS_NewObjectClass(ctx, 1);
        _ = qjs.JS_SetOpaque(opaque_obj, @ptrCast(self.doc));
        _ = qjs.JS_SetPropertyStr(ctx, doc_obj, "_native_doc", opaque_obj);

        _ = qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);
    }

    fn createWindowAPI(self: *DOMBridge, global: qjs.JSValue) !void {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const window_obj = qjs.JS_NewObject(ctx);
        defer qjs.JS_FreeValue(ctx, window_obj);

        // window.location (basic support)
        const location_obj = qjs.JS_NewObject(ctx);
        const href = qjs.JS_NewString(ctx, "about:blank");
        _ = qjs.JS_SetPropertyStr(ctx, location_obj, "href", href);
        _ = qjs.JS_SetPropertyStr(ctx, window_obj, "location", location_obj);

        // window.navigator
        const navigator_obj = qjs.JS_NewObject(ctx);
        const user_agent = qjs.JS_NewString(ctx, "Zexplorer/1.0 (QuickJS; Lexbor)");
        _ = qjs.JS_SetPropertyStr(ctx, navigator_obj, "userAgent", user_agent);
        _ = qjs.JS_SetPropertyStr(ctx, window_obj, "navigator", navigator_obj);

        _ = qjs.JS_SetPropertyStr(ctx, global, "window", window_obj);

        // Make 'window' also available as 'globalThis' and 'self'
        _ = qjs.JS_SetPropertyStr(ctx, global, "globalThis", window_obj);
        _ = qjs.JS_SetPropertyStr(ctx, global, "self", window_obj);
    }

    fn createConsoleAPI(self: *DOMBridge, global: qjs.JSValue) !void {
        const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(self.ctx));
        const console_obj = qjs.JS_NewObject(ctx);
        defer qjs.JS_FreeValue(ctx, console_obj);

        // console.log
        const log_fn = qjs.JS_NewCFunction2(
            ctx,
            js_consoleLog,
            "log",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, console_obj, "log", log_fn);

        // console.error
        const error_fn = qjs.JS_NewCFunction2(
            ctx,
            js_consoleLog,
            "error",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, console_obj, "error", error_fn);

        _ = qjs.JS_SetPropertyStr(ctx, global, "console", console_obj);
    }

    /// Wrap a lexbor Element into a JavaScript object with DOM methods
    fn wrapElement(ctx: ?*qjs.JSContext, element: z.Element) !qjs.JSValue {
        const elem_obj = qjs.JS_NewObject(ctx);

        // Store native element pointer
        const opaque_obj = qjs.JS_NewObjectClass(ctx, 1);
        _ = qjs.JS_SetOpaque(opaque_obj, @ptrCast(element));
        _ = qjs.JS_SetPropertyStr(ctx, elem_obj, "_native_element", opaque_obj);

        // element.tagName
        const tag_name = z.tagName_zc(element);
        const tag_val = qjs.JS_NewString(ctx, tag_name.ptr);
        _ = qjs.JS_SetPropertyStr(ctx, elem_obj, "tagName", tag_val);

        // element.appendChild(child)
        const append_child_fn = qjs.JS_NewCFunction2(
            ctx,
            js_appendChild,
            "appendChild",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, elem_obj, "appendChild", append_child_fn);

        // element.setAttribute(name, value)
        const set_attr_fn = qjs.JS_NewCFunction2(
            ctx,
            js_setAttribute,
            "setAttribute",
            2,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, elem_obj, "setAttribute", set_attr_fn);

        // element.getAttribute(name)
        const get_attr_fn = qjs.JS_NewCFunction2(
            ctx,
            js_getAttribute,
            "getAttribute",
            1,
            qjs.JS_CFUNC_generic,
            0,
        );
        _ = qjs.JS_SetPropertyStr(ctx, elem_obj, "getAttribute", get_attr_fn);

        // element.textContent
        const text_content = z.textContent_zc(z.elementToNode(element));
        const text_val = qjs.JS_NewString(ctx, text_content.ptr);
        _ = qjs.JS_SetPropertyStr(ctx, elem_obj, "textContent", text_val);

        return elem_obj;
    }
};

// ========================================================================
// JavaScript C Function Implementations
// ========================================================================

fn js_createElement(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_EXCEPTION;

    const tag_name_c = qjs.JS_ToCString(ctx, argv[0]);
    if (tag_name_c == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, tag_name_c);

    const tag_name = std.mem.span(tag_name_c);

    // Get document from global
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);

    const native_doc_val = qjs.JS_GetPropertyStr(ctx, doc_obj, "_native_doc");
    defer qjs.JS_FreeValue(ctx, native_doc_val);

    const doc_ptr = qjs.JS_GetOpaque(native_doc_val, 1);
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    // Create element using lexbor
    const element = z.createElement(doc, tag_name) catch return qjs.JS_EXCEPTION;

    // Wrap and return
    return DOMBridge.wrapElement(ctx, element) catch qjs.JS_EXCEPTION;
}

fn js_createTextNode(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_EXCEPTION;

    const text_c = qjs.JS_ToCString(ctx, argv[0]);
    if (text_c == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, text_c);

    const text = std.mem.span(text_c);

    // Get document
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);

    const native_doc_val = qjs.JS_GetPropertyStr(ctx, doc_obj, "_native_doc");
    defer qjs.JS_FreeValue(ctx, native_doc_val);

    const doc_ptr = qjs.JS_GetOpaque(native_doc_val, 1);
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    // Create text node using lexbor
    const text_node = z.createTextNode(doc, text) catch return qjs.JS_EXCEPTION;

    // Wrap as object
    const text_obj = qjs.JS_NewObject(ctx);
    const opaque_obj = qjs.JS_NewObjectClass(ctx, 1);
    _ = qjs.JS_SetOpaque(opaque_obj, @ptrCast(text_node));
    _ = qjs.JS_SetPropertyStr(ctx, text_obj, "_native_node", opaque_obj);

    return text_obj;
}

fn js_appendChild(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_EXCEPTION;

    // Get parent element from 'this'
    const native_elem_val = qjs.JS_GetPropertyStr(ctx, this, "_native_element");
    defer qjs.JS_FreeValue(ctx, native_elem_val);

    const parent_ptr = qjs.JS_GetOpaque(native_elem_val, 1);
    const parent: z.Element = @ptrCast(@alignCast(parent_ptr));

    // Get child from argument
    const child_elem_val = qjs.JS_GetPropertyStr(ctx, argv[0], "_native_element");
    const child_node_val = qjs.JS_GetPropertyStr(ctx, argv[0], "_native_node");

    var child_node: z.Node = undefined;
    if (qjs.JS_IsUndefined(child_elem_val) == 0) {
        defer qjs.JS_FreeValue(ctx, child_elem_val);
        const child_ptr = qjs.JS_GetOpaque(child_elem_val, 1);
        const child_elem: z.Element = @ptrCast(@alignCast(child_ptr));
        child_node = z.elementToNode(child_elem);
    } else if (qjs.JS_IsUndefined(child_node_val) == 0) {
        defer qjs.JS_FreeValue(ctx, child_node_val);
        const node_ptr = qjs.JS_GetOpaque(child_node_val, 1);
        child_node = @ptrCast(@alignCast(node_ptr));
    } else {
        return qjs.JS_EXCEPTION;
    }

    // Append using lexbor
    z.appendChild(z.elementToNode(parent), child_node);

    return argv[0]; // Return the child
}

fn js_setAttribute(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 2) return qjs.JS_EXCEPTION;

    const name_c = qjs.JS_ToCString(ctx, argv[0]);
    if (name_c == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, name_c);

    const value_c = qjs.JS_ToCString(ctx, argv[1]);
    if (value_c == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, value_c);

    const name = std.mem.span(name_c);
    const value = std.mem.span(value_c);

    // Get element from 'this'
    const native_elem_val = qjs.JS_GetPropertyStr(ctx, this, "_native_element");
    defer qjs.JS_FreeValue(ctx, native_elem_val);

    const elem_ptr = qjs.JS_GetOpaque(native_elem_val, 1);
    const element: z.Element = @ptrCast(@alignCast(elem_ptr));

    // Set attribute using lexbor
    _ = z.setAttribute(element, name, value);

    return qjs.JS_UNDEFINED;
}

fn js_getAttribute(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return qjs.JS_EXCEPTION;

    const name_c = qjs.JS_ToCString(ctx, argv[0]);
    if (name_c == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, name_c);

    const name = std.mem.span(name_c);

    // Get element from 'this'
    const native_elem_val = qjs.JS_GetPropertyStr(ctx, this, "_native_element");
    defer qjs.JS_FreeValue(ctx, native_elem_val);

    const elem_ptr = qjs.JS_GetOpaque(native_elem_val, 1);
    const element: z.Element = @ptrCast(@alignCast(elem_ptr));

    // Get attribute using lexbor
    const attr_value = z.getAttribute_zc(element, name);
    if (attr_value) |val| {
        return qjs.JS_NewString(ctx, val.ptr);
    }

    return qjs.JS_NULL;
}

fn js_querySelector(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_EXCEPTION;

    const selector_c = qjs.JS_ToCString(ctx, argv[0]);
    if (selector_c == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, selector_c);

    const selector = std.mem.span(selector_c);

    // Get document
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);

    const native_doc_val = qjs.JS_GetPropertyStr(ctx, doc_obj, "_native_doc");
    defer qjs.JS_FreeValue(ctx, native_doc_val);

    const doc_ptr = qjs.JS_GetOpaque(native_doc_val, 1);
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    // Query using CSS selector (need allocator - this is simplified)
    // In real implementation, pass allocator through context
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    _ = z.documentRoot(doc) orelse return qjs.JS_NULL;
    const elements = z.querySelectorAll(allocator, doc, selector) catch return qjs.JS_EXCEPTION;
    defer allocator.free(elements);

    if (elements.len > 0) {
        return DOMBridge.wrapElement(ctx, elements[0]) catch qjs.JS_EXCEPTION;
    }

    return qjs.JS_NULL;
}

fn js_querySelectorAll(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this;
    if (argc < 1) return qjs.JS_EXCEPTION;

    const selector_c = qjs.JS_ToCString(ctx, argv[0]);
    if (selector_c == null) return qjs.JS_EXCEPTION;
    defer qjs.JS_FreeCString(ctx, selector_c);

    const selector = std.mem.span(selector_c);

    // Get document
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    const doc_obj = qjs.JS_GetPropertyStr(ctx, global, "document");
    defer qjs.JS_FreeValue(ctx, doc_obj);

    const native_doc_val = qjs.JS_GetPropertyStr(ctx, doc_obj, "_native_doc");
    defer qjs.JS_FreeValue(ctx, native_doc_val);

    const doc_ptr = qjs.JS_GetOpaque(native_doc_val, 1);
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    // Query using CSS selector
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const elements = z.querySelectorAll(allocator, doc, selector) catch return qjs.JS_EXCEPTION;
    defer allocator.free(elements);

    // Create array
    const array = qjs.JS_NewArray(ctx);
    for (elements, 0..) |elem, i| {
        const elem_obj = DOMBridge.wrapElement(ctx, elem) catch continue;
        _ = qjs.JS_SetPropertyUint32(ctx, array, @intCast(i), elem_obj);
    }

    return array;
}

fn js_consoleLog(
    ctx: ?*qjs.JSContext,
    this: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = this;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const str = qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (str != null) {
            defer qjs.JS_FreeCString(ctx, str);
            z.print("{s} ", .{str});
        }
    }
    z.print("\n", .{});
    return qjs.JS_UNDEFINED;
}

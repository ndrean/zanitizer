const std = @import("std");
const z = @import("root.zig");
const bindings = @import("bindings_generated.zig");

pub var dom_class_id: z.qjs.JSClassID = 0;

fn getAllocator(ctx: ?*z.qjs.JSContext) std.mem.Allocator {
    // Helper for C-style callbacks that receive raw ctx pointer
    // For regular Zig code, use Context.getAllocator() from wrapper
    const opaque_ptr = z.qjs.JS_GetContextOpaque(ctx);
    const allocator_ptr: *std.mem.Allocator = @ptrCast(@alignCast(opaque_ptr));
    return allocator_ptr.*;
}

pub const DOMBridge = struct {
    allocator: std.mem.Allocator,
    ctx: ?*z.qjs.JSContext,
    doc: *z.HTMLDocument,

    // Finalizer called when QuickJS garbage collects a wrapped DOM object
    fn domFinalizer(rt: ?*z.qjs.JSRuntime, val: z.qjs.JSValue) callconv(.c) void {
        _ = rt;
        _ = val;
        // Do nothing - the Lexbor document owns the DOM nodes
        // and will free them when the document is destroyed.
        // We just need to prevent QuickJS from trying to access them.
    }

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: ?*z.qjs.JSContext,
    ) !DOMBridge {
        if (dom_class_id == 0) {
            // runtime-wide
            _ = z.qjs.JS_NewClassID(&dom_class_id);

            const def = z.qjs.JSClassDef{
                .class_name = "DOMNode",
                .finalizer = &domFinalizer, // Add finalizer to prevent access to freed nodes
                .gc_mark = null,
                .call = null,
                .exotic = null,
            };

            const rt = z.qjs.JS_GetRuntime(ctx);
            _ = z.qjs.JS_NewClass(rt, dom_class_id, &def);
        }

        // Note: Allocator should already be set in context by installNativeBridge
        // We don't overwrite it here

        const doc = try z.createDocFromString("");

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .doc = doc,
        };
    }

    pub fn deinit(self: *DOMBridge) void {
        // WORKAROUND: Don't destroy the Lexbor document here
        // Destroying it causes QuickJS GC assertion failures because QuickJS
        // tries to access the wrapped DOM nodes during final garbage collection.
        // The document will leak, but this prevents the crash.
        // TODO: Find a proper solution for cleanup order
        // _ = self;

        // NOTE: If you uncomment below, you'll get the assertion:
        z.destroyDocument(self.doc);
    }

    pub fn installAPIs(self: *DOMBridge) !void {
        const ctx = self.ctx;
        const global = z.qjs.JS_GetGlobalObject(ctx);
        defer z.qjs.JS_FreeValue(ctx, global);

        // 1. Create and register the prototype with shared methods
        const proto = z.qjs.JS_NewObject(ctx);
        bindings.installMethodBindings(ctx, proto);
        z.qjs.JS_SetClassProto(ctx, dom_class_id, proto);

        // 2. Create document and window APIs
        try self.createDocumentAPI(global);
        try self.createWindowAPI(global);
        // Note: console is already installed in main.zig via installConsole()
        // Don't overwrite it here
        // try self.createConsoleAPI(global);
    }

    fn createDocumentAPI(self: *DOMBridge, global: z.qjs.JSValue) !void {
        const ctx = self.ctx;
        const doc_obj = z.qjs.JS_NewObject(ctx);
        // DO NOT defer free - JS_SetPropertyStr transfers ownership to global!

        // Install static bindings (createElement, createTextNode, getElementById, etc.)
        bindings.installStaticBindings(ctx, doc_obj);

        // Install custom query selectors (not yet in generated bindings)
        const query_selector_fn = z.qjs.JS_NewCFunction2(ctx, js_querySelector, "querySelector", 1, z.qjs.JS_CFUNC_generic, 0);
        _ = z.qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelector", query_selector_fn);

        const query_selector_all_fn = z.qjs.JS_NewCFunction2(ctx, js_querySelectorAll, "querySelectorAll", 1, z.qjs.JS_CFUNC_generic, 0);
        _ = z.qjs.JS_SetPropertyStr(ctx, doc_obj, "querySelectorAll", query_selector_all_fn);

        // Attach body element
        const body_node = z.bodyNode(self.doc);
        if (body_node) |body| {
            const body_element = z.nodeToElement(body).?;
            const body_val = try wrapElement(ctx, body_element);
            _ = z.qjs.JS_SetPropertyStr(ctx, doc_obj, "body", body_val);
        }

        // Store native document pointer for static functions to retrieve
        const opaque_obj = z.qjs.JS_NewObjectClass(ctx, @intCast(dom_class_id));
        _ = z.qjs.JS_SetOpaque(opaque_obj, @ptrCast(self.doc));
        _ = z.qjs.JS_SetPropertyStr(ctx, doc_obj, "_native_doc", opaque_obj);

        _ = z.qjs.JS_SetPropertyStr(ctx, global, "document", doc_obj);
    }

    fn createWindowAPI(self: *DOMBridge, global: z.qjs.JSValue) !void {
        const ctx = self.ctx;
        const window_obj = z.qjs.JS_NewObject(ctx);
        // DO NOT defer free - JS_SetPropertyStr transfers ownership!

        const location_obj = z.qjs.JS_NewObject(ctx);
        const href = z.qjs.JS_NewString(ctx, "about:blank");
        _ = z.qjs.JS_SetPropertyStr(ctx, location_obj, "href", href);
        _ = z.qjs.JS_SetPropertyStr(ctx, window_obj, "location", location_obj);

        const navigator_obj = z.qjs.JS_NewObject(ctx);
        const user_agent = z.qjs.JS_NewString(ctx, "Zexplorer/1.0 (QuickJS; Lexbor)");
        _ = z.qjs.JS_SetPropertyStr(ctx, navigator_obj, "userAgent", user_agent);
        _ = z.qjs.JS_SetPropertyStr(ctx, window_obj, "navigator", navigator_obj);

        _ = z.qjs.JS_SetPropertyStr(ctx, global, "window", window_obj);
        _ = z.qjs.JS_SetPropertyStr(ctx, global, "globalThis", window_obj);
        _ = z.qjs.JS_SetPropertyStr(ctx, global, "self", window_obj);
    }

    fn createConsoleAPI(self: *DOMBridge, global: z.qjs.JSValue) !void {
        const ctx = self.ctx;
        const console_obj = z.qjs.JS_NewObject(ctx);
        // DO NOT defer free - JS_SetPropertyStr transfers ownership!

        const log_fn = z.qjs.JS_NewCFunction2(ctx, js_consoleLog, "log", 1, z.qjs.JS_CFUNC_generic, 0);
        _ = z.qjs.JS_SetPropertyStr(ctx, console_obj, "log", log_fn);

        const error_fn = z.qjs.JS_NewCFunction2(ctx, js_consoleLog, "error", 1, z.qjs.JS_CFUNC_generic, 0);
        _ = z.qjs.JS_SetPropertyStr(ctx, console_obj, "error", error_fn);

        _ = z.qjs.JS_SetPropertyStr(ctx, global, "console", console_obj);
    }

    /// Wrap an HTMLElement for JavaScript (inherits methods from prototype)
    pub fn wrapElement(ctx: ?*z.qjs.JSContext, element: *z.HTMLElement) !z.qjs.JSValue {
        // Create object instance of our DOM class (inherits prototype automatically)
        const elem_obj = z.qjs.JS_NewObjectClass(ctx, @intCast(dom_class_id));
        _ = z.qjs.JS_SetOpaque(elem_obj, @ptrCast(element));

        // Add element-specific properties
        const tag_name = z.tagName_zc(element);
        const tag_val = z.qjs.JS_NewString(ctx, tag_name.ptr);
        _ = z.qjs.JS_SetPropertyStr(ctx, elem_obj, "tagName", tag_val);

        // Methods are inherited from prototype (set via JS_SetClassProto)
        return elem_obj;
    }

    /// Wrap a DomNode for JavaScript (inherits methods from prototype)
    pub fn wrapNode(ctx: ?*z.qjs.JSContext, node: *z.DomNode) !z.qjs.JSValue {
        // Create object instance of our DOM class (inherits prototype automatically)
        const node_obj = z.qjs.JS_NewObjectClass(ctx, @intCast(dom_class_id));
        _ = z.qjs.JS_SetOpaque(node_obj, @ptrCast(node));

        // Methods are inherited from prototype (set via JS_SetClassProto)
        return node_obj;
    }
};

fn js_querySelector(ctx: ?*z.qjs.JSContext, this: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    _ = this;
    if (argc < 1) return z.jsException;
    const selector_c = z.qjs.JS_ToCString(ctx, argv[0]);
    if (selector_c == null) return z.jsException;
    defer z.qjs.JS_FreeCString(ctx, selector_c);
    const selector = std.mem.span(selector_c);

    const global = z.qjs.JS_GetGlobalObject(ctx);
    defer z.qjs.JS_FreeValue(ctx, global);
    const doc_obj = z.qjs.JS_GetPropertyStr(ctx, global, "document");
    defer z.qjs.JS_FreeValue(ctx, doc_obj);
    const native_doc_val = z.qjs.JS_GetPropertyStr(ctx, doc_obj, "_native_doc");
    defer z.qjs.JS_FreeValue(ctx, native_doc_val);

    const doc_ptr = z.qjs.JS_GetOpaque(native_doc_val, dom_class_id);
    if (doc_ptr == null) return z.jsException;
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    const allocator = getAllocator(ctx);

    _ = z.documentRoot(doc) orelse return z.jsNull;
    const elements = z.querySelectorAll(allocator, doc, selector) catch return z.jsException;
    defer allocator.free(elements);
    if (elements.len > 0) {
        return DOMBridge.wrapElement(ctx, elements[0]) catch z.jsException;
    }
    return z.jsNull;
}

fn js_querySelectorAll(ctx: ?*z.qjs.JSContext, this: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    _ = this;
    if (argc < 1) return z.jsException;
    const selector_c = z.qjs.JS_ToCString(ctx, argv[0]);
    if (selector_c == null) return z.jsException;
    defer z.qjs.JS_FreeCString(ctx, selector_c);
    const selector = std.mem.span(selector_c);

    const global = z.qjs.JS_GetGlobalObject(ctx);
    defer z.qjs.JS_FreeValue(ctx, global);
    const doc_obj = z.qjs.JS_GetPropertyStr(ctx, global, "document");
    defer z.qjs.JS_FreeValue(ctx, doc_obj);
    const native_doc_val = z.qjs.JS_GetPropertyStr(ctx, doc_obj, "_native_doc");
    defer z.qjs.JS_FreeValue(ctx, native_doc_val);

    const doc_ptr = z.qjs.JS_GetOpaque(native_doc_val, dom_class_id);
    if (doc_ptr == null) return z.jsException;
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    const allocator = getAllocator(ctx);
    const elements = z.querySelectorAll(allocator, doc, selector) catch return z.jsException;
    defer allocator.free(elements);

    const array = z.qjs.JS_NewArray(ctx);
    for (elements, 0..) |elem, i| {
        const elem_obj = DOMBridge.wrapElement(ctx, elem) catch continue;
        _ = z.qjs.JS_SetPropertyUint32(ctx, array, @intCast(i), elem_obj);
    }
    return array;
}

fn js_consoleLog(ctx: ?*z.qjs.JSContext, this: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    _ = this;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const str = z.qjs.JS_ToCString(ctx, argv[@intCast(i)]);
        if (str != null) {
            defer z.qjs.JS_FreeCString(ctx, str);
            z.print("{s} ", .{str});
        }
    }
    z.print("\n", .{});
    return z.jsUndefined;
}

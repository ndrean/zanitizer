const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig"); // Your new safe wrapper
const bindings = @import("bindings_generated.zig");

// Global Class ID (shared across contexts)
pub var dom_class_id: w.ClassID = 0;

pub const DOMBridge = struct {
    allocator: std.mem.Allocator,
    ctx: w.Context,
    doc: *z.HTMLDocument,

    // 1. FINALIZER (Lexbor owns the nodes, we just detach)
    fn domFinalizer(rt_ptr: ?*z.qjs.JSRuntime, val: z.qjs.JSValue) callconv(.c) void {
        _ = rt_ptr;
        _ = val;
        // No-op: Lexbor manages the memory lifecycle of the nodes.
    }

    // 2. INIT (Register Class & Create internal Doc)
    pub fn init(allocator: std.mem.Allocator, ctx: w.Context) !DOMBridge {
        // Register the class once per Runtime
        if (dom_class_id == 0) {
            const rt = ctx.getRuntime();
            dom_class_id = rt.newClassID();

            try rt.newClass(dom_class_id, .{
                .class_name = "DOMNode",
                .finalizer = domFinalizer,
            });
        }

        // Create the internal Lexbor document
        const doc = try z.createDocFromString("");

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .doc = doc,
        };
    }

    pub fn deinit(self: *DOMBridge) void {
        z.destroyDocument(self.doc);
    }

    // 3. INSTALLATION (Connect JS objects to Zig)
    pub fn installAPIs(self: *DOMBridge) !void {
        const ctx = self.ctx;
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        // A. Setup Prototype (Methods shared by all nodes)
        const proto = ctx.newObject();
        // Install generated methods (appendChild, etc.)
        bindings.installMethodBindings(ctx.ptr, proto);

        // Register this prototype for our Class ID
        ctx.setClassProto(dom_class_id, proto);

        // B. Install Global APIs
        try self.createDocumentAPI(global);
        try self.createWindowAPI(global);
        try self.createConsoleAPI(global);
    }

    fn createDocumentAPI(self: *DOMBridge, global: w.Value) !void {
        const ctx = self.ctx;
        const doc_obj = ctx.newObject();

        // 1. Install Static Bindings (createElement, etc.)
        bindings.installStaticBindings(ctx.ptr, doc_obj);

        // 2. Install Manual Bindings (querySelector)
        const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
        try ctx.setPropertyStr(doc_obj, "querySelector", qs_fn);

        const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
        try ctx.setPropertyStr(doc_obj, "querySelectorAll", qsa_fn);

        // 3. Attach 'body' property
        if (z.bodyNode(self.doc)) |body_node| {
            if (z.nodeToElement(body_node)) |body_elem| {
                const body_val = try wrapElement(ctx, body_elem);
                try ctx.setPropertyStr(doc_obj, "body", body_val);
            }
        }

        // 4. Store Native Pointer (Hidden _native_doc)
        // This is crucial for static bindings to find the C document
        const opaque_obj = ctx.newObjectClass(dom_class_id);
        try ctx.setOpaque(opaque_obj, self.doc);
        try ctx.setPropertyStr(doc_obj, "_native_doc", opaque_obj);

        // 5. Expose 'document' on global
        try ctx.setPropertyStr(global, "document", doc_obj);
    }

    fn createWindowAPI(self: *DOMBridge, global: w.Value) !void {
        const ctx = self.ctx;
        const window_obj = ctx.newObject();

        // Location
        const loc_obj = ctx.newObject();
        try ctx.setPropertyStr(loc_obj, "href", ctx.newString("about:blank"));
        try ctx.setPropertyStr(window_obj, "location", loc_obj);

        // Navigator
        const nav_obj = ctx.newObject();
        try ctx.setPropertyStr(nav_obj, "userAgent", ctx.newString("Zexplorer/1.0"));
        try ctx.setPropertyStr(window_obj, "navigator", nav_obj);

        // Attach to global
        try ctx.setPropertyStr(global, "window", window_obj);

        // Standard global aliases
        try ctx.setPropertyStr(global, "globalThis", ctx.dupValue(global));
        try ctx.setPropertyStr(global, "self", ctx.dupValue(global));
    }

    fn createConsoleAPI(self: *DOMBridge, global: w.Value) !void {
        const ctx = self.ctx;
        const console = ctx.newObject();

        const log_fn = ctx.newCFunction(js_consoleLog, "log", 1);
        try ctx.setPropertyStr(console, "log", log_fn);

        const error_fn = ctx.newCFunction(js_consoleLog, "error", 1);
        try ctx.setPropertyStr(console, "error", error_fn);

        try ctx.setPropertyStr(global, "console", console);
    }

    // --- WRAPPERS (Helpers for bindings) ---

    pub fn wrapElement(ctx: w.Context, element: *z.HTMLElement) !w.Value {
        const obj = ctx.newObjectClass(dom_class_id);
        try ctx.setOpaque(obj, element);

        // Add convenience properties like tagName
        const tag = z.tagName_zc(element);
        const tag_str = ctx.newString(tag);
        try ctx.setPropertyStr(obj, "tagName", tag_str);

        return obj;
    }

    pub fn wrapNode(ctx: w.Context, node: *z.DomNode) !w.Value {
        const obj = ctx.newObjectClass(dom_class_id);
        try ctx.setOpaque(obj, node);
        return obj;
    }
};

// --- NATIVE CALLBACKS (Using Wrapper API) ---

fn js_querySelector(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return w.EXCEPTION;

    // 1. Get Selector
    const selector_str = ctx.toCString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeCString(selector_str);
    const selector = std.mem.span(selector_str);

    // 2. Get Document (via global.document._native_doc)
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const doc_obj = ctx.getPropertyStr(global, "document");
    defer ctx.freeValue(doc_obj);
    const native_doc = ctx.getPropertyStr(doc_obj, "_native_doc");
    defer ctx.freeValue(native_doc);

    const doc_ptr = ctx.getOpaque2(native_doc, dom_class_id);
    if (doc_ptr == null) return w.EXCEPTION;
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    // 3. Execute Query
    const allocator = ctx.getAllocator();

    // We need a root to search from
    _ = z.documentRoot(doc) orelse return w.NULL;

    const elements = z.querySelectorAll(allocator, doc, selector) catch return w.EXCEPTION;
    defer allocator.free(elements);

    if (elements.len > 0) {
        return DOMBridge.wrapElement(ctx, elements[0]) catch w.EXCEPTION;
    }
    return w.NULL;
}

fn js_querySelectorAll(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return w.EXCEPTION;

    const selector_str = ctx.toCString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeCString(selector_str);
    const selector = std.mem.span(selector_str);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const doc_obj = ctx.getPropertyStr(global, "document");
    defer ctx.freeValue(doc_obj);
    const native_doc = ctx.getPropertyStr(doc_obj, "_native_doc");
    defer ctx.freeValue(native_doc);

    const doc_ptr = ctx.getOpaque2(native_doc, dom_class_id);
    if (doc_ptr == null) return w.EXCEPTION;
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    const allocator = ctx.getAllocator();
    const elements = z.querySelectorAll(allocator, doc, selector) catch return w.EXCEPTION;
    defer allocator.free(elements);

    const array = ctx.newArray();
    for (elements, 0..) |elem, i| {
        const elem_obj = DOMBridge.wrapElement(ctx, elem) catch continue;
        ctx.setPropertyUint32(array, @intCast(i), elem_obj) catch {}; // setProperty consumes elem_obj ref
    }
    return array;
}

fn js_consoleLog(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) z.print(" ", .{});
        const str = ctx.toCString(argv[@intCast(i)]) catch continue;
        z.print("{s}", .{str});
        ctx.freeCString(str);
    }
    z.print("\n", .{});
    return w.UNDEFINED;
}

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const w = @import("wrapper.zig");
const bindings = @import("bindings_generated.zig");
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DocFragment = @import("js_DocFragment.zig");
const DOMParserClass = @import("js_DOMParser.zig");

pub const DOMBridge = struct {
    allocator: std.mem.Allocator,
    ctx: w.Context,
    doc: *z.HTMLDocument,
    registry: std.AutoHashMap(usize, std.StringHashMap(std.ArrayList(Listener))), // events registry

    // 1. FINALIZER (Lexbor owns the nodes, we just detach)
    fn domFinalizer(_: ?*z.qjs.JSRuntime, _: z.qjs.JSValue) callconv(.c) void {}

    fn documentFinalizer(rt_ptr: ?*z.qjs.JSRuntime, val: z.qjs.JSValue) callconv(.c) void {
        _ = rt_ptr;
        const ptr = z.qjs.JS_GetOpaque(val, 0); // Get ptr regardless of class ID
        if (ptr) |p| {
            const doc: *z.HTMLDocument = @ptrCast(@alignCast(p));
            z.destroyDocument(doc); // Calls lxb_html_document_destroy
        }
    }

    // 2. INIT (Register Class & Create internal Doc)
    pub fn init(allocator: std.mem.Allocator, ctx: w.Context) !DOMBridge {
        // the Thread-Local RuntimeContext
        const rc = RuntimeContext.get(ctx);
        var rt = ctx.getRuntime();

        // Register class ONLY if not already registered for this runtime ????
        if (rc.classes.dom_node == 0) {
            // --- DOM_NODE: class & Node.prototype
            rc.classes.dom_node = rt.newClassID();
            try rt.newClass(rc.classes.dom_node, .{
                .class_name = "Node",
                .finalizer = domFinalizer,
            });
            const node_proto = ctx.newObject();
            bindings.installNodeBindings(ctx.ptr, node_proto);
            ctx.setClassProto(rc.classes.dom_node, node_proto); // Consumes node_proto

            // --- HTML_ELEMENT: class & HTMLElement.prototype. Inherits from Node
            rc.classes.html_element = rt.newClassID();
            try rt.newClass(rc.classes.html_element, .{
                .class_name = "HTMLElement",
                .finalizer = null,
            });
            const el_proto = ctx.newObject();
            bindings.installElementBindings(ctx.ptr, el_proto);
            // INHERITANCE: HTMLElement.prototype -> Node.prototype
            {
                // Get a reference to Node.prototype (+1 ref count)
                const parent_proto = ctx.getClassProto(rc.classes.dom_node);
                defer ctx.freeValue(parent_proto); // Free the reference after use

                // Chain them: el_proto.__proto__ = parent_proto
                try ctx.setPrototype(el_proto, parent_proto);
            }

            // Register: HTMLElement class uses el_proto
            ctx.setClassProto(rc.classes.html_element, el_proto);

            // --- DOCUMENT (Inherits from Node)
            rc.classes.document = rt.newClassID();
            try rt.newClass(rc.classes.document, .{
                .class_name = "Document",
                .finalizer = null,
            });

            const doc_proto = ctx.newObject();
            // Install Document methods (createElement, body, etc.)
            bindings.installDocumentBindings(ctx.ptr, doc_proto);

            // INHERITANCE: Document.prototype -> Node.prototype
            {
                const parent_proto = ctx.getClassProto(rc.classes.dom_node);
                defer ctx.freeValue(parent_proto);
                try ctx.setPrototype(doc_proto, parent_proto);
            }

            // Register: Document class uses doc_proto
            ctx.setClassProto(rc.classes.document, doc_proto);

            // --- OWNED_DOCUMENT (Inherits from Document)
            rc.classes.owned_document = rt.newClassID();
            try rt.newClass(rc.classes.owned_document, .{
                .class_name = "OwnedDocument",
                .finalizer = documentFinalizer,
            });

            const owned_doc_proto = ctx.getClassProto(rc.classes.document);
            ctx.setClassProto(rc.classes.owned_document, owned_doc_proto);

            // ============================================================
            // Other Classes
            try initDocumentFragmentClass(rt, ctx);
            try initDomParserClass(rt, ctx);
        }

        // Create the internal Lexbor document
        const doc = try z.parseHTML(allocator, "");
        rc.global_document = doc;
        // var current_ctx = ctx;

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .doc = doc,
            .registry = std.AutoHashMap(usize, std.StringHashMap(std.ArrayList(Listener))).init(allocator),
        };
    }

    pub fn deinit(self: *DOMBridge) void {
        z.destroyDocument(self.doc);
        const rc = RuntimeContext.get(self.ctx);
        rc.global_document = null;

        var it = self.registry.iterator();
        while (it.next()) |node_entry| {
            var event_it = node_entry.value_ptr.iterator();
            while (event_it.next()) |event_entry| {
                for (event_entry.value_ptr.items) |listener| {
                    // Release the JS callback
                    self.ctx.freeValue(listener.callback);
                }
                event_entry.value_ptr.deinit(self.allocator);
            }
            node_entry.value_ptr.deinit();
        }
        self.registry.deinit();
        // self.allocator.destroy(self); // BUG! ScriptEngine cleans DOMBridge struct
    }

    // 3. INSTALLATION (Connect JS objects to Zig)
    pub fn installAPIs(self: *DOMBridge) !void {
        const ctx = self.ctx;
        const rc = RuntimeContext.get(ctx);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        // install*Bindings called inside init() on the prottypes

        // B. Install Global APIs
        try self.createDocumentAPI(global, rc.classes.dom_node);
        try self.createWindowAPI(global);
        try self.createConsoleAPI(global);

        // Host Communication API Helper (sendToHost)
        const fn_val = ctx.newCFunction(js_reportResult, "sendToHost", 1);
        try ctx.setPropertyStr(global, "sendToHost", fn_val);
    }

    fn createDocumentAPI(self: *DOMBridge, global: w.Value, _: w.ClassID) !void {
        const ctx = self.ctx;
        const rc = RuntimeContext.get(ctx);

        // 'document' instance inherits from Document.prototype
        const doc_obj = ctx.newObjectClass(rc.classes.document);

        try ctx.setOpaque(doc_obj, self.doc);
        try ctx.setPropertyStr(doc_obj, "_native_doc", ctx.dupValue(doc_obj));

        // 2. Install Manual Bindings (querySelector)
        const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
        try ctx.setPropertyStr(doc_obj, "querySelector", qs_fn);

        const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
        try ctx.setPropertyStr(doc_obj, "querySelectorAll", qsa_fn);

        // Store Native Pointer (Hidden _native_doc)
        // create a separate opaque object to hold the pointer
        // const opaque_obj = ctx.newObjectClass(rc.classes.document);
        // try ctx.setOpaque(opaque_obj, self.doc);
        // try ctx.setPropertyStr(doc_obj, "_native_doc", opaque_obj);

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
        // Get ID from context
        const rc = RuntimeContext.get(ctx);
        const obj = ctx.newObjectClass(rc.classes.html_element);
        try ctx.setOpaque(obj, element);

        // Add convenience properties like tagName
        const tag = z.tagName_zc(element);
        const tag_str = ctx.newString(tag);
        try ctx.setPropertyStr(obj, "tagName", tag_str);

        return obj;
    }

    pub fn wrapNode(ctx: w.Context, node: *z.DomNode) !w.Value {
        // Get ID from context
        const rc = RuntimeContext.get(ctx);
        const obj = ctx.newObjectClass(rc.classes.dom_node);
        try ctx.setOpaque(obj, node);
        const nodeName = z.nodeName_zc(node);
        const name_str = ctx.newString(nodeName);
        try ctx.setPropertyStr(obj, "nodeName", name_str);
        return obj;
    }

    /// Helper to unwrap ANY class that inherits from Node
    pub fn unwrapNode(ctx: w.Context, val: zqjs.Value) ?*z.DomNode {
        const rc = RuntimeContext.get(ctx);

        // 1. Is it a generic Node? (Text, Comment)
        if (ctx.getOpaque(val, rc.classes.dom_node)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }

        // 2. Is it an Element? (div, span)
        if (ctx.getOpaque(val, rc.classes.html_element)) |ptr| {
            const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
            return z.elementToNode(el); // Cast *HTMLElement -> *DomNode
        }

        // 3. Is it a DocumentFragment?
        if (ctx.getOpaque(val, rc.classes.document_fragment)) |ptr| {
            const frag: *z.DocumentFragment = @ptrCast(@alignCast(ptr));
            return z.fragmentToNode(frag); // Cast *DocumentFragment -> *DomNode
        }

        // 4. Is it a Document?
        if (ctx.getOpaque(val, rc.classes.document)) |ptr| {
            const doc: *z.HTMLDocument = @ptrCast(@alignCast(ptr));
            return z.documentRoot(doc); // Cast *HTMLDocument -> *DomNode
        } else {
            // Check OwnedDocument as well
            if (ctx.getOpaque(val, rc.classes.owned_document)) |ptr| {
                const doc: *z.HTMLDocument = @ptrCast(@alignCast(ptr));
                return z.documentRoot(doc); // Cast *HTMLDocument -> *DomNode
            }
        }

        return null;
    }
};

pub fn initDomParserClass(rt: zqjs.Runtime, ctx: w.Context) !void {
    DOMParserClass.class_id = rt.newClassID();

    const rc = RuntimeContext.get(ctx);
    rc.classes.dom_parser = DOMParserClass.class_id;

    const class_def = zqjs.Runtime.ClassDef{
        .class_name = "DOMParser",
        .finalizer = DOMParserClass.finalizer,
    };
    rt.newClass(DOMParserClass.class_id, class_def) catch |err| {
        std.debug.print("Failed to register DOMParser class: {}\n", .{err});
        return err;
    };
    // Setup Prototype Inheritance: DOMParser -> Object
    const proto = ctx.newObject();

    bindings.installDOMParserBindings(ctx.ptr, proto);

    // Install the constructor
    const ctor = ctx.newCFunction2(
        DOMParserClass.constructor,
        "DOMParser",
        0,
        z.qjs.JS_CFUNC_constructor,
        0,
    );
    ctx.setConstructor(ctor, proto);
    // takes ownership & consume proto
    ctx.setClassProto(DOMParserClass.class_id, proto);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    try ctx.setPropertyStr(global, "DOMParser", ctor);
}

pub fn initDocumentFragmentClass(rt: zqjs.Runtime, ctx: zqjs.Context) !void {
    // 1. Create Class ID
    // if (DocFragment.class_id == 0) {
    DocFragment.class_id = rt.newClassID();
    // }

    const rc = RuntimeContext.get(ctx);
    rc.classes.document_fragment = DocFragment.class_id;

    // 2. Define Class with Finalizer
    const class_def = zqjs.Runtime.ClassDef{
        .class_name = "DocumentFragment",
        .finalizer = null, //DocFragment.finalizer,
    };
    rt.newClass(DocFragment.class_id, class_def) catch |err| {
        // Handle error (log or panic, don't just swallow if possible)
        std.debug.print("Failed to register DocumentFragment class: {}\n", .{err});
        return;
    };

    // 3. Setup Prototype Inheritance: DocumentFragment -> Node -> EventTarget
    const proto = ctx.newObject();
    // defer ctx.freeValue(proto);
    const node_proto = ctx.getClassProto(rc.classes.dom_node);
    defer ctx.freeValue(node_proto);

    // MAGIC: This makes fragment inherit appendChild, removeChild, etc.
    ctx.setPrototype(proto, node_proto) catch return;
    // 4. Install the constructor
    const ctor = ctx.newCFunction2(
        DocFragment.constructor,
        "DocumentFragment",
        0,
        z.qjs.JS_CFUNC_constructor,
        0,
    );
    ctx.setConstructor(ctor, proto);
    ctx.setClassProto(DocFragment.class_id, proto);
    // Attach to global object
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    try ctx.setPropertyStr(global, "DocumentFragment", ctor);
}

const Listener = struct {
    callback: z.qjs.JSValue,
};

pub fn addEventListener(
    ctx: zqjs.Context,
    self: *DOMBridge, // via rc.dom_bridge
    node: *z.DomNode,
    event: []const u8,
    callback: zqjs.Value,
) !void {
    const node_id = @intFromPtr(node);

    // Get/Create Node Entry
    var node_entry = try self.registry.getOrPut(node_id);
    // allocator will be received from rc.allocator
    if (!node_entry.found_existing) {
        node_entry.value_ptr.* = std.StringHashMap(std.ArrayList(Listener)).init(self.allocator);
    }

    // Get/Create Event Type Entry (eg "click")
    var event_entry = try node_entry.value_ptr.getOrPut(event);
    if (!event_entry.found_existing) {
        event_entry.value_ptr.* = .{};
    }

    // Store Callback
    // CRITICAL: Increment refcount so the function isn't garbage collected!
    const dup_cb = ctx.dupValue(callback);
    try event_entry.value_ptr.append(self.allocator, .{ .callback = dup_cb });
}

pub fn dispatchEvent(
    ctx: zqjs.Context,
    self: *DOMBridge,
    node: *z.DomNode,
    event: []const u8,
) !void {
    const node_id = @intFromPtr(node);
    if (self.registry.getPtr(node_id)) |node_map| {
        if (node_map.getPtr(event)) |listeners| {
            const prev_def_fn = ctx.newCFunction(js_preventDefault, "preventDefault", 0);
            defer ctx.freeValue(prev_def_fn);

            for (listeners.items) |l| {
                const event_obj = ctx.newObject();
                defer ctx.freeValue(event_obj);
                _ = try ctx.setPropertyStr(event_obj, "type", ctx.newString(event));

                // [FIX] Wrap as Element if possible, otherwise generic Node
                // You will need to check your 'z' wrapper for the specific casting function.
                // Assuming something like z.isElement(node) or checking node type exists:
                var target_obj: zqjs.Value = zqjs.NULL;

                // Hypothetical check: Adjust 'z.isElement' to match your bindings
                if (z.nodeType(node) == .element) {
                    const el: *z.HTMLElement = @ptrCast(@alignCast(node));
                    target_obj = DOMBridge.wrapElement(ctx, el) catch zqjs.NULL;
                } else {
                    target_obj = DOMBridge.wrapNode(ctx, node) catch zqjs.NULL;
                }

                _ = try ctx.setPropertyStr(event_obj, "target", target_obj);
                _ = try ctx.setPropertyStr(event_obj, "preventDefault", ctx.dupValue(prev_def_fn));

                const ret = ctx.call(l.callback, zqjs.UNDEFINED, &.{event_obj});
                ctx.freeValue(ret);
            }
        }
    }
}
// pub fn dispatchEvent(
//     ctx: zqjs.Context,
//     self: *DOMBridge,
//     node: *z.DomNode,
//     event: []const u8,
// ) !void {
//     const node_id = @intFromPtr(node);

//     if (self.registry.getPtr(node_id)) |node_map| {
//         if (node_map.getPtr(event)) |listeners| {
//             const prev_def_fn = ctx.newCFunction(js_preventDefault, "preventDefault", 0);
//             defer ctx.freeValue(prev_def_fn);

//             for (listeners.items) |l| {
//                 // set { type: "click" } )
//                 const event_obj = ctx.newObject();
//                 defer ctx.freeValue(event_obj);
//                 _ = try ctx.setPropertyStr(event_obj, "type", ctx.newString(event));

//                 // 2. Set 'target' (The node itself!)
//                 // We wrap the node again so JS sees 'e.target === btn'
//                 // (Optimization: In a real engine, we'd cache this wrapper)
//                 const target_obj = DOMBridge.wrapNode(ctx, node) catch zqjs.NULL;
//                 _ = try ctx.setPropertyStr(event_obj, "target", target_obj);

//                 // 3. Set 'preventDefault'
//                 _ = try ctx.setPropertyStr(event_obj, "preventDefault", ctx.dupValue(prev_def_fn));

//                 // Call the JS function
//                 const ret = ctx.call(l.callback, zqjs.UNDEFINED, &.{event_obj});
//                 ctx.freeValue(ret); // Ignore result, but free it
//             }
//         }
//     }
// }

fn js_reportResult(
    ctx_ptr: ?*z.qjs.JSContext,
    _: z.qjs.JSValue,
    argc: c_int,
    argv: [*c]zqjs.Value,
) callconv(.c) zqjs.Value {
    const ctx = z.wrapper.Context{ .ptr = ctx_ptr };
    if (argc < 1) return z.wrapper.UNDEFINED;

    const str = ctx.toCString(argv[0]) catch "???";
    std.debug.print("[HOST MSG] {s}\n", .{str});
    ctx.freeCString(str);

    // 1. Get the Context State
    const rc = RuntimeContext.get(ctx);

    // 2. Free old result if exists
    if (rc.last_result) |old_val| {
        ctx.freeValue(old_val);
    }

    // 3. Store new result (Duplicate it so it survives!)
    rc.last_result = ctx.dupValue(argv[0]);

    return z.wrapper.UNDEFINED;
}

// --- NATIVE CALLBACKS (Using Wrapper API) ---

fn js_querySelector(
    ctx_ptr: ?*z.qjs.JSContext,
    _: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return w.EXCEPTION;

    // [FIX] Get RuntimeContext
    const rc = RuntimeContext.get(ctx);

    const selector_str = ctx.toCString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeCString(selector_str);
    const selector = std.mem.span(selector_str);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const doc_obj = ctx.getPropertyStr(global, "document");
    defer ctx.freeValue(doc_obj);
    const native_doc = ctx.getPropertyStr(doc_obj, "_native_doc");
    defer ctx.freeValue(native_doc);

    // [FIX] Use rc.classes.dom_node
    const doc_ptr = ctx.getOpaque2(native_doc, rc.classes.dom_node);
    if (doc_ptr == null) return w.EXCEPTION;
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    // [FIX] Use rc.allocator (Thread-safe)
    const allocator = rc.allocator;

    // We need a root to search from
    _ = z.documentRoot(doc) orelse return w.NULL;

    const elements = z.querySelectorAll(allocator, doc, selector) catch return w.EXCEPTION;
    defer allocator.free(elements);

    if (elements.len > 0) {
        return DOMBridge.wrapElement(ctx, elements[0]) catch w.EXCEPTION;
    }
    return w.NULL;
}

fn js_querySelectorAll(
    ctx_ptr: ?*z.qjs.JSContext,
    _: z.qjs.JSValue,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return w.EXCEPTION;

    // [FIX] Get RuntimeContext
    const rc = RuntimeContext.get(ctx);

    const selector_str = ctx.toCString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeCString(selector_str);
    const selector = std.mem.span(selector_str);

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const doc_obj = ctx.getPropertyStr(global, "document");
    defer ctx.freeValue(doc_obj);
    const native_doc = ctx.getPropertyStr(doc_obj, "_native_doc");
    defer ctx.freeValue(native_doc);

    // [FIX] Use rc.classes.dom_node
    const doc_ptr = ctx.getOpaque2(native_doc, rc.classes.dom_node);
    if (doc_ptr == null) return w.EXCEPTION;
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr));

    // [FIX] Use rc.allocator
    const allocator = rc.allocator;

    const elements = z.querySelectorAll(allocator, doc, selector) catch return w.EXCEPTION;
    defer allocator.free(elements);

    const array = ctx.newArray();
    for (elements, 0..) |elem, i| {
        const elem_obj = DOMBridge.wrapElement(ctx, elem) catch continue;
        ctx.setPropertyUint32(array, @intCast(i), elem_obj) catch {};
    }
    return array;
}

fn js_consoleLog(
    ctx_ptr: ?*z.qjs.JSContext,
    _: z.qjs.JSValue,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
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

// A dummy implementation of preventDefault to stop JS from crashing
fn js_preventDefault(
    _: ?*z.qjs.JSContext,
    _: z.qjs.JSValue,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    // In a real browser, this sets a 'defaultPrevented' flag.
    // For a headless scraper, a no-op is often sufficient to satisfy the script.
    return w.UNDEFINED;
}

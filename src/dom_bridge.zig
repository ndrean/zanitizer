const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const w = @import("wrapper.zig");
const bindings = @import("bindings_generated.zig");
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DocFragment = @import("js_DocFragment.zig");
const DOMParserClass = @import("js_DOMParser.zig");
const CssSelectorEngine = z.CssSelectorEngine;

pub const DOMBridge = struct {
    allocator: std.mem.Allocator,
    ctx: w.Context,
    doc: *z.HTMLDocument,
    registry: std.AutoHashMap(usize, std.StringHashMap(std.ArrayListUnmanaged(Listener))), // events registry
    node_cache: std.AutoHashMap(usize, zqjs.Value), // (Ptr Address -> JS Object)
    css_engine: CssSelectorEngine, // CSS Selector Engine

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

            {
                const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
                try ctx.setPropertyStr(el_proto, "querySelector", qs_fn);

                const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
                try ctx.setPropertyStr(el_proto, "querySelectorAll", qsa_fn);
            }

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

            // Install Element.matches()

            {
                const matches_fn = ctx.newCFunction(js_matches, "matches", 1);
                try ctx.setPropertyStr(el_proto, "matches", matches_fn);
            }

            {
                const atom = z.qjs.JS_NewAtom(ctx.ptr, "childNodes");
                const get_fn = ctx.newCFunction(js_get_childNodes, "get_childNodes", 0);

                // Define as a GETTER (Read-Only)
                _ = z.qjs.JS_DefinePropertyGetSet(ctx.ptr, node_proto, atom, get_fn, zqjs.UNDEFINED, z.qjs.JS_PROP_CONFIGURABLE | z.qjs.JS_PROP_ENUMERABLE);
                z.qjs.JS_FreeAtom(ctx.ptr, atom);
            }
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
            .node_cache = std.AutoHashMap(usize, zqjs.Value).init(allocator),
            .css_engine = try CssSelectorEngine.init(allocator),
        };
    }

    pub fn deinit(self: *DOMBridge) void {
        z.destroyDocument(self.doc);
        const rc = RuntimeContext.get(self.ctx);
        rc.global_document = null;

        self.css_engine.deinit();

        var it_reg = self.registry.iterator();
        while (it_reg.next()) |node_entry| {
            var event_it = node_entry.value_ptr.iterator();
            while (event_it.next()) |event_entry| {
                for (event_entry.value_ptr.items) |listener| {
                    // Release the JS callback
                    self.ctx.freeValue(listener.callback);
                }
                event_entry.value_ptr.deinit(self.allocator);
                self.allocator.free(event_entry.key_ptr.*);
            }
            node_entry.value_ptr.deinit();
        }
        self.registry.deinit();

        var it_cache = self.node_cache.iterator();
        while (it_cache.next()) |entry| {
            // Free the JS value (decrement refcount)
            self.ctx.freeValue(entry.value_ptr.*);
        }
        self.node_cache.deinit();

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
        const rc = RuntimeContext.get(ctx);
        const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
        const ptr_addr = @intFromPtr(element); // Elements are just nodes in Lexbor

        // Check cache
        if (bridge.node_cache.getPtr(ptr_addr)) |cached_val| {
            return ctx.dupValue(cached_val.*); //<-- new reference to SAME object
        }
        // create new wrapper
        const obj = ctx.newObjectClass(rc.classes.html_element);
        try ctx.setOpaque(obj, element);

        // Add convenience properties like tagName
        const tag = z.tagName_zc(element);
        const tag_str = ctx.newString(tag);
        try ctx.setPropertyStr(obj, "tagName", tag_str);

        // store in cache
        const dup_for_cache = ctx.dupValue(obj);
        try bridge.node_cache.put(ptr_addr, dup_for_cache);

        return obj;
    }

    pub fn wrapNode(ctx: w.Context, node: *z.DomNode) !w.Value {
        const rc = RuntimeContext.get(ctx);
        const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
        const ptr_addr = @intFromPtr(node);
        // Check cache
        if (bridge.node_cache.getPtr(ptr_addr)) |cached_val| {
            return ctx.dupValue(cached_val.*);
            //<-- new reference to SAME object
        }

        var class_id = rc.classes.dom_node; // Default
        const n_type = z.nodeType(node);
        if (n_type == .element) {
            class_id = rc.classes.html_element;
        } else if (n_type == .document_fragment) {
            class_id = rc.classes.document_fragment;
        } else if (n_type == .document) {
            class_id = rc.classes.document;
        }

        // create new wrapper
        const obj = ctx.newObjectClass(rc.classes.dom_node);
        try ctx.setOpaque(obj, node);
        const nodeName = z.nodeName_zc(node);
        const name_str = ctx.newString(nodeName);
        try ctx.setPropertyStr(obj, "nodeName", name_str);
        // store in cache
        const dup_for_cache = ctx.dupValue(obj);
        try bridge.node_cache.put(ptr_addr, dup_for_cache);

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

// [hashmap]= https://devlog.hexops.com/2022/zig-hashmaps-explained/
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
        node_entry.value_ptr.* = std.StringHashMap(std.ArrayListUnmanaged(Listener)).init(self.allocator);
    }

    // Get/Create Event Type Entry (eg "click")
    var event_entry = try node_entry.value_ptr.getOrPut(event);
    if (!event_entry.found_existing) {
        event_entry.key_ptr.* = try self.allocator.dupe(u8, event);
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
    target_node: *z.DomNode,
    event_name: []const u8,
) !void {
    var js_target: zqjs.Value = zqjs.NULL;
    // 'freeze' target after wrapping
    if (z.nodeType(target_node) == .element) {
        js_target = try DOMBridge.wrapElement(ctx, @ptrCast(@alignCast(target_node)));
    } else {
        js_target = try DOMBridge.wrapNode(ctx, target_node);
    }
    defer ctx.freeValue(js_target);

    // bubbling loop
    var current_node: ?*z.DomNode = target_node;
    while (current_node) |node| : (current_node = z.parentNode(node)) {
        // try self.dispatchEventAtNode(ctx, node, event);
        const node_id = @intFromPtr(node);
        // Check if this node has listeners
        if (self.registry.getPtr(node_id)) |node_map| {
            if (node_map.getPtr(event_name)) |listeners| {
                const prev_def_fn = ctx.newCFunction(js_preventDefault, "preventDefault", 0);
                defer ctx.freeValue(prev_def_fn);

                // Create the event object for this listener
                // (In a full engine, we'd reuse the object and update currentTarget)
                for (listeners.items) |l| {
                    const event_obj = ctx.newObject();
                    defer ctx.freeValue(event_obj);

                    _ = try ctx.setPropertyStr(event_obj, "type", ctx.newString(event_name));

                    // Critical: e.target is the button (original target), not the current node
                    _ = try ctx.setPropertyStr(event_obj, "target", ctx.dupValue(js_target));

                    _ = try ctx.setPropertyStr(event_obj, "preventDefault", ctx.dupValue(prev_def_fn));

                    const ret = ctx.call(l.callback, zqjs.UNDEFINED, &.{event_obj});
                    ctx.freeValue(ret);
                }
            }
        }

        // Stop bubbling if we hit #document root (whohse parent is NULL)
    }
}

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
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]zqjs.Value,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.EXCEPTION;

    // 1. Unwrap 'this' (Polymorphic)
    // We try Element first (most common), then Document, then Fragment
    var root_node: ?*z.DomNode = null;

    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        root_node = z.elementToNode(@ptrCast(ptr));
    } else if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| {
        // Document: start searching from the document root (usually <html>)
        const doc: *z.HTMLDocument = @ptrCast(ptr);
        root_node = z.documentRoot(doc);
    } else if (ctx.getOpaque(this_val, rc.classes.document_fragment)) |ptr| {
        root_node = z.fragmentToNode(@ptrCast(ptr));
    } else {
        return ctx.throwTypeError("querySelector called on invalid object");
    }

    if (root_node == null) return w.NULL;

    // 2. Get Selector
    const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(selector_str);

    // 3. Execute
    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

    // Pass generic *DomNode to your new engine API
    if (bridge.css_engine.querySelector(root_node.?, selector_str) catch return w.EXCEPTION) |found_node| {
        // 4. Wrap Result (Polymorphic wrapNode handles Element vs Node)
        return DOMBridge.wrapElement(ctx, found_node) catch w.EXCEPTION;
    }

    return w.NULL;
}
// fn js_querySelector(
//     ctx_ptr: ?*z.qjs.JSContext,
//     this_val: z.qjs.JSValue, // <---  Use 'this_val' directly
//     argc: c_int,
//     argv: [*c]z.qjs.JSValue,
// ) callconv(.c) z.qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);
//     if (argc < 1) return w.EXCEPTION;

//     // Polymorphic Lookup: Check both Document types: global document & owned documents
//     const doc: *z.HTMLDocument = blk: {
//         if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
//         if (ctx.getOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
//         return ctx.throwTypeError("querySelector called on object that is not a Document");
//     };

//     // Get Selector
//     const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
//     defer ctx.freeZString(selector_str);
//     // const selector = std.mem.span(selector_str);

//     const root_node = z.documentRoot(doc) orelse return w.NULL;
//     const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

//     if (bridge.css_engine.querySelector(root_node, selector_str) catch return w.EXCEPTION) |node| {
//         // Most querySelector results are elements
//         if (z.nodeToElement(node)) |el| {
//             return DOMBridge.wrapElement(ctx, el) catch w.EXCEPTION;
//         }
//     }

//     return w.NULL;
// }

fn js_querySelectorAll(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]zqjs.Value,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.EXCEPTION;

    // 1. Unwrap 'this' (Polymorphic: Element, Document, or Fragment)
    var root_node: ?*z.DomNode = null;

    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        root_node = z.elementToNode(@ptrCast(ptr));
    } else if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| {
        const doc: *z.HTMLDocument = @ptrCast(ptr);
        root_node = z.documentRoot(doc);
    } else if (ctx.getOpaque(this_val, rc.classes.document_fragment)) |ptr| {
        root_node = z.fragmentToNode(@ptrCast(ptr));
    } else {
        return ctx.throwTypeError("querySelectorAll called on invalid object");
    }

    if (root_node == null) return ctx.newArray(); // Return empty array if root is null

    // 2. Get Selector
    const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(selector_str);

    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

    // 3. Execute Query
    // engine.querySelectorAll now returns []*z.HTMLElement
    const elements = bridge.css_engine.querySelectorAll(root_node.?, selector_str) catch return w.EXCEPTION;
    defer bridge.allocator.free(elements); // Free the slice

    // 4. Create JS Array
    const array = ctx.newArray();
    for (elements, 0..) |el, i| {
        // Optimization: Use wrapElement directly (skips nodeType check)
        const val = DOMBridge.wrapElement(ctx, el) catch continue;
        _ = ctx.setPropertyUint32(array, @intCast(i), val) catch {};
    }

    return array;
}
// fn js_querySelectorAll(
//     ctx_ptr: ?*z.qjs.JSContext,
//     this_val: z.qjs.JSValue, // <---  Use 'this_val' directly
//     argc: c_int,
//     argv: [*c]z.qjs.JSValue,
// ) callconv(.c) z.qjs.JSValue {
//     const ctx = w.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);
//     if (argc < 1) return w.EXCEPTION;

//     // Polymorphic Lookup: global document & owned documents
//     const doc: *z.HTMLDocument = blk: {
//         if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
//         if (ctx.getOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
//         return ctx.throwTypeError("querySelectorAll called on object that is not a Document");
//     };

//     const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
//     defer ctx.freeZString(selector_str);
//     // const selector = std.mem.span(selector_str);
//     const root_node = z.documentRoot(doc) orelse return w.NULL;

//     const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

//     const nodes = bridge.css_engine.querySelectorAll(root_node, selector_str) catch return w.EXCEPTION;
//     defer bridge.allocator.free(nodes); // Free the slice (nodes themselves are owned by Doc)

//     const array = ctx.newArray();
//     var idx: u32 = 0;
//     for (nodes) |node| {
//         if (z.nodeToElement(node)) |el| {
//             const elem_obj = DOMBridge.wrapElement(ctx, el) catch continue;
//             _ = ctx.setPropertyUint32(array, idx, elem_obj) catch {};
//             idx += 1;
//         }
//     }

//     // const allocator = rc.allocator;
//     // const elements = z.querySelectorAll(allocator, doc, selector_str) catch return w.EXCEPTION;
//     // defer allocator.free(elements);

//     // // Return Array
//     // const array = ctx.newArray();
//     // for (elements, 0..) |elem, i| {
//     //     const elem_obj = DOMBridge.wrapElement(ctx, elem) catch continue;
//     //     _ = ctx.setPropertyUint32(array, @intCast(i), elem_obj) catch {};
//     // }
//     return array;
// }

fn js_matches(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.EXCEPTION;

    // 1. Get Element from 'this'
    const ptr = ctx.getOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("matches() called on non-Element");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

    // 2. Get Selector
    const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(selector_str);

    // 3. Use Engine
    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

    // Note: matchNode expects a generic *DomNode
    // const node = z.elementToNode(el);
    const result = bridge.css_engine.matchElement(el, selector_str) catch return w.EXCEPTION;

    return ctx.newBool(result);
}

fn js_get_childNodes(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    // Unwrap 'this' to *DomNode
    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return w.EXCEPTION;

    const children = z.childNodes(rc.allocator, node) catch return w.EXCEPTION;
    defer rc.allocator.free(children); // Free the slice (pointers inside are owned by Doc)

    const array = ctx.newArray();
    for (children, 0..) |child, i| {
        // each child
        const val = DOMBridge.wrapNode(ctx, child) catch continue;
        // accessor array[i] = child
        _ = ctx.setPropertyUint32(array, @intCast(i), val) catch {};
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

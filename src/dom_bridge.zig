const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const w = @import("wrapper.zig");
const bindings = @import("bindings_generated.zig");
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_DocFragment = @import("js_DocFragment.zig");
const js_DOMParser = @import("js_DomParser.zig");
const CssSelectorEngine = z.CssSelectorEngine;
const js_style = @import("js_CSSStyleDeclaration.zig");
const js_classList = @import("js_classList.zig");
const js_dataset = @import("js_dataset.zig");
pub const js_url = @import("js_url.zig");
const js_headers = @import("js_headers.zig");
const js_events = @import("js_events.zig");
const js_blob = @import("js_blob.zig");
const js_file = @import("js_File.zig");
const js_formData = @import("js_formData.zig");
const js_polyfills = @import("js_polyfills.zig");
const js_filelist = @import("js_filelist.zig");
const js_file_reader_sync = @import("js_file_reader_sync.zig");
const js_file_reader = @import("js_file_reader.zig");
const js_text_encoding = @import("js_text_encoding.zig");
const js_readable_stream = @import("js_readable_stream.zig");
const js_writable_stream = @import("js_writable_stream.zig");

pub const DOMBridge = struct {
    allocator: std.mem.Allocator,
    ctx: w.Context,
    doc: *z.HTMLDocument,
    registry: std.AutoHashMap(usize, std.StringHashMap(std.ArrayListUnmanaged(Listener))), // events registry
    node_cache: std.AutoHashMap(usize, zqjs.Value), // (Ptr Address -> JS Object)
    css_engine: CssSelectorEngine, // CSS Selector Engine
    css_style_parser: *z.CssStyleParser,
    stylesheet: *z.CssStyleSheet,

    // (Lexbor owns the nodes, we just detach)
    fn domFinalizer(_: ?*z.qjs.JSRuntime, _: z.qjs.JSValue) callconv(.c) void {}

    fn documentFinalizer(rt_ptr: ?*z.qjs.JSRuntime, val: z.qjs.JSValue) callconv(.c) void {
        _ = rt_ptr;
        // document or ownedDocument
        const class_id = z.qjs.JS_GetClassID(val);
        const ptr = z.qjs.JS_GetOpaque(val, class_id);
        if (ptr) |p| {
            const doc: *z.HTMLDocument = @ptrCast(@alignCast(p));
            z.destroyDocument(doc); // Calls lxb_html_document_destroy
        }
    }

    fn styleFinalizer(_: ?*z.qjs.JSRuntime, _: z.qjs.JSValue) callconv(.c) void {}

    // (Register Class & Create internal Doc)
    pub fn init(allocator: std.mem.Allocator, ctx: w.Context) !DOMBridge {
        const rc = RuntimeContext.get(ctx);
        var rt = ctx.getRuntime();

        // infrastructure classes (Node, HTLMElement, CSSStyleDeclaration, Document)
        if (rc.classes.dom_node == 0) {
            // --- NODE --------------------------
            rc.classes.dom_node = rt.newClassID();
            try rt.newClass(rc.classes.dom_node, .{
                .class_name = "Node",
                .finalizer = domFinalizer,
            });

            const node_proto = ctx.newObject();
            // !!NO DEFER HERE! setClassProto takes ownership.

            bindings.installNodeBindings(ctx.ptr, node_proto);
            {
                const atom = z.qjs.JS_NewAtom(ctx.ptr, "childNodes");
                const get_fn = ctx.newCFunction(js_get_childNodes, "get_childNodes", 0);
                _ = z.qjs.JS_DefinePropertyGetSet(
                    ctx.ptr,
                    node_proto,
                    atom,
                    get_fn,
                    zqjs.UNDEFINED,
                    z.qjs.JS_PROP_CONFIGURABLE | z.qjs.JS_PROP_ENUMERABLE,
                );
                z.qjs.JS_FreeAtom(ctx.ptr, atom);
            }

            // Manual: insertBefore(newChild, refChild) - refChild can be null
            {
                const ib_fn = ctx.newCFunction(js_insertBefore, "insertBefore", 2);
                _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "insertBefore", ib_fn);
            }

            ctx.setClassProto(rc.classes.dom_node, node_proto);

            // --- HTML_ELEMENT ------------------
            rc.classes.html_element = rt.newClassID();
            try rt.newClass(rc.classes.html_element, .{
                .class_name = "HTMLElement",
                .finalizer = domFinalizer,
            });

            const el_proto = ctx.newObject();
            bindings.installElementBindings(ctx.ptr, el_proto);

            {
                const atom = z.qjs.JS_NewAtom(ctx.ptr, "style");
                defer z.qjs.JS_FreeAtom(ctx.ptr, atom);

                // Getter (Generic, 0 args)
                const get_fn_val = ctx.newCFunction(js_style.get_element_style, "get_style", 0);

                const set_fn_val = ctx.newCFunction(js_style.set_element_style, "set_style", 1);

                // define Property (Configurable + Enumerable)
                _ = z.qjs.JS_DefinePropertyGetSet(ctx.ptr, el_proto, // The prototype object
                    atom, // "style"
                    get_fn_val, // Getter function
                    set_fn_val, // Setter function
                    z.qjs.JS_PROP_CONFIGURABLE | z.qjs.JS_PROP_ENUMERABLE);
            }

            const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
            try ctx.setPropertyStr(
                el_proto,
                "querySelector",
                qs_fn,
            );

            const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
            try ctx.setPropertyStr(
                el_proto,
                "querySelectorAll",
                qsa_fn,
            );

            const matches_fn = ctx.newCFunction(js_matches, "matches", 1);
            try ctx.setPropertyStr(
                el_proto,
                "matches",
                matches_fn,
            );

            // Inheritance: HTMLElement -> Node
            {
                const parent_proto = ctx.getClassProto(rc.classes.dom_node);
                defer ctx.freeValue(parent_proto);
                try ctx.setPrototype(el_proto, parent_proto);
            }
            ctx.setClassProto(rc.classes.html_element, el_proto);

            // --- DOCUMENT ----------------------
            rc.classes.document = rt.newClassID();
            try rt.newClass(rc.classes.document, .{ .class_name = "Document", .finalizer = null });

            const doc_proto = ctx.newObject();
            bindings.installDocumentBindings(ctx.ptr, doc_proto);
            {
                const parent_proto = ctx.getClassProto(rc.classes.dom_node);
                defer ctx.freeValue(parent_proto);
                try ctx.setPrototype(doc_proto, parent_proto);
            }
            ctx.setClassProto(rc.classes.document, doc_proto);

            // --- OWNED_DOCUMENT ----------------
            rc.classes.owned_document = rt.newClassID();
            try rt.newClass(rc.classes.owned_document, .{
                .class_name = "OwnedDocument",
                .finalizer = documentFinalizer,
            });
            const owned_doc_proto = ctx.getClassProto(rc.classes.document);
            ctx.setClassProto(rc.classes.owned_document, owned_doc_proto);

            // --- CSSStyleDeclaration (no data, ,just a "view")
            rc.classes.css_style_decl = rt.newClassID();
            try rt.newClass(rc.classes.css_style_decl, .{
                .class_name = "CSSStyleDeclaration",
                .finalizer = styleFinalizer,
            });

            const style_proto = ctx.newObject();

            {
                // 1. getPropertyValue
                const get_prop_fn = ctx.newCFunction(js_style.getPropertyValue, "getPropertyValue", 1);
                try ctx.setPropertyStr(style_proto, "getPropertyValue", get_prop_fn);

                // 2. setProperty
                const set_prop_fn = ctx.newCFunction(js_style.setProperty, "setProperty", 2);
                try ctx.setPropertyStr(style_proto, "setProperty", set_prop_fn);

                // 3. removeProperty
                const remove_prop_fn = ctx.newCFunction(js_style.removeProperty, "removeProperty", 1);
                try ctx.setPropertyStr(style_proto, "removeProperty", remove_prop_fn);
            }

            ctx.setClassProto(rc.classes.css_style_decl, style_proto);
        }

        // Web APIs classes
        try js_DocFragment.DocFragmentBridge.install(ctx);
        try js_DOMParser.DOMParserBridge.install(ctx);
        try js_headers.HeadersBridge.install(ctx);
        try js_blob.BlobBridge.install(ctx);
        try js_formData.FormDataBridge.install(ctx);
        try js_url.URLBridge.install(ctx);
        try js_events.EventBridge.install(ctx);
        try js_classList.install(ctx);
        try js_dataset.install(ctx);
        try js_polyfills.install(ctx);
        try js_file.install(ctx);
        try js_filelist.install(ctx);
        try js_file_reader.FileReaderBridge.install(ctx);
        try js_text_encoding.install(ctx);
        try js_readable_stream.install(ctx);
        try js_writable_stream.install(ctx);

        const doc = try z.createDocument();
        errdefer z.destroyDocument(doc);

        try z.initDocumentCSS(doc, true);
        try z.insertHTML(doc, "<html><head></head><body></body></html>");
        const parser = try z.createCssStyleParser();
        errdefer z.destroyCssStyleParser(parser);
        const stylesheet = try z.createStylesheet();
        errdefer z.destroyStylesheet(stylesheet);

        rc.global_document = doc;

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .doc = doc,
            .registry = std.AutoHashMap(usize, std.StringHashMap(std.ArrayListUnmanaged(Listener))).init(allocator),
            .node_cache = std.AutoHashMap(usize, zqjs.Value).init(allocator),
            .css_engine = try CssSelectorEngine.init(allocator),
            .css_style_parser = try z.createCssStyleParser(),
            .stylesheet = stylesheet,
        };
    }

    pub fn deinit(self: *DOMBridge) void {
        z.destroyDocument(self.doc);
        const rc = RuntimeContext.get(self.ctx);
        rc.global_document = null;

        self.css_engine.deinit();
        z.destroyCssStyleParser(self.css_style_parser);
        z.destroyStylesheet(self.stylesheet);

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

    // (Connect JS objects to Zig)
    pub fn installAPIs(self: *DOMBridge) !void {
        const ctx = self.ctx;
        const rc = RuntimeContext.get(ctx);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        // install*Bindings called inside init() on the prottypes

        // B. Install Global APIs
        try self.createDocumentAPI(global, rc.classes.dom_node);
        try self.createWindowAPI(global);

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

        // Manual Bindings (querySelector)
        const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
        try ctx.setPropertyStr(doc_obj, "querySelector", qs_fn);

        const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
        try ctx.setPropertyStr(doc_obj, "querySelectorAll", qsa_fn);

        // Expose 'document' on global
        try ctx.setPropertyStr(global, "document", doc_obj);
    }

    fn createWindowAPI(self: *DOMBridge, global: w.Value) !void {
        const ctx = self.ctx;
        const window_obj = ctx.newObject();

        const loc_obj = ctx.newObject();
        try ctx.setPropertyStr(loc_obj, "href", ctx.newString("about:blank"));
        try ctx.setPropertyStr(window_obj, "location", loc_obj);

        const nav_obj = ctx.newObject();
        try ctx.setPropertyStr(nav_obj, "userAgent", ctx.newString("Zexplorer/1.0"));
        try ctx.setPropertyStr(window_obj, "navigator", nav_obj);

        // Attach to global

        const gcs_fn = ctx.newCFunction(js_style.window_getComputedStyle, "getComputedStyle", 1);
        try ctx.setPropertyStr(global, "getComputedStyle", gcs_fn);
        // Also attach it to the window object proxy
        try ctx.setPropertyStr(window_obj, "getComputedStyle", ctx.dupValue(gcs_fn));

        // Copy polyfills from globalThis to window (React checks window.requestAnimationFrame)
        const raf = ctx.getPropertyStr(global, "requestAnimationFrame");
        if (!ctx.isUndefined(raf)) {
            try ctx.setPropertyStr(window_obj, "requestAnimationFrame", raf);
        } else {
            ctx.freeValue(raf);
        }
        const caf = ctx.getPropertyStr(global, "cancelAnimationFrame");
        if (!ctx.isUndefined(caf)) {
            try ctx.setPropertyStr(window_obj, "cancelAnimationFrame", caf);
        } else {
            ctx.freeValue(caf);
        }
        const mc = ctx.getPropertyStr(global, "MessageChannel");
        if (!ctx.isUndefined(mc)) {
            try ctx.setPropertyStr(window_obj, "MessageChannel", mc);
        } else {
            ctx.freeValue(mc);
        }
        const mp = ctx.getPropertyStr(global, "MessagePort");
        if (!ctx.isUndefined(mp)) {
            try ctx.setPropertyStr(window_obj, "MessagePort", mp);
        } else {
            ctx.freeValue(mp);
        }

        try ctx.setPropertyStr(global, "window", window_obj);

        // Standard global aliases
        try ctx.setPropertyStr(global, "globalThis", ctx.dupValue(global));
        try ctx.setPropertyStr(global, "self", ctx.dupValue(global));
    }

    pub fn applyStylesToElement(self: *DOMBridge, el: *z.HTMLElement) !void {
        try z.attachElementStyles(
            self.allocator,
            el,
            self.stylesheet,
            &self.css_engine, // pass pointer to engine struct
        );
    }

    // --- WRAPPERS (Helpers for bindings) ---

    /// Wraps a Zig Document pointer into a JS Value
    pub fn wrapDocument(ctx: w.Context, doc: *z.HTMLDocument) !w.Value {
        const rc = RuntimeContext.get(ctx);
        // const obj = z.qjs.JS_NewObjectClass(ctx.ptr, rc.classes.document);
        // if (z.qjs.JS_IsException(obj)) return error.Exception;

        const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
        const ptr_addr = @intFromPtr(doc);
        if (ptr_addr == @intFromPtr(bridge.doc)) {
            const global = ctx.getGlobalObject();
            defer ctx.freeValue(global);
            return ctx.getPropertyStr(global, "document");
        }

        // Check Cahce
        if (bridge.node_cache.getPtr(ptr_addr)) |cached_val| {
            return ctx.dupValue(cached_val.*);
        }

        const obj = ctx.newObjectClass(rc.classes.owned_document);
        try ctx.setOpaque(obj, doc);

        const dup_for_cache = ctx.dupValue(obj);
        try bridge.node_cache.put(ptr_addr, dup_for_cache);

        // 2. Link the Native Pointer
        // Note: We cast to *anyopaque because JS_SetOpaque expects void*
        // _ = z.qjs.JS_SetOpaque(obj, @ptrCast(doc));

        // 3. (Optional but Recommended) Identity Preservation
        // In a full implementation, you would cache this object so that
        // multiple calls to 'ownerDocument' return the exact same JS object (===).
        // For now, returning a new wrapper is functional but breaks 'doc === doc'.

        return obj;
    }

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

        // Add nodeType (ELEMENT_NODE = 1)
        try ctx.setPropertyStr(obj, "nodeType", ctx.newInt32(1));

        // store in cache
        const dup_for_cache = ctx.dupValue(obj);
        try bridge.node_cache.put(ptr_addr, dup_for_cache);

        return obj;
    }

    pub fn wrapNode(ctx: w.Context, node: *z.DomNode) !w.Value {
        const rc = RuntimeContext.get(ctx);
        const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

        // Special case: document nodes should return the global document object
        // This ensures parentNode chain terminates correctly (document.parentNode = null)
        const n_type = z.nodeType(node);
        if (n_type == .document) {
            const doc: *z.HTMLDocument = @ptrCast(@alignCast(node));
            return wrapDocument(ctx, doc);
            // const global = ctx.getGlobalObject();
            // defer ctx.freeValue(global);
            // return ctx.getPropertyStr(global, "document");
        }

        const ptr_addr = @intFromPtr(node);
        // Check cache
        if (bridge.node_cache.getPtr(ptr_addr)) |cached_val| {
            return ctx.dupValue(cached_val.*);
            //<-- new reference to SAME object
        }

        var class_id = rc.classes.dom_node; // Default
        if (n_type == .element) {
            class_id = rc.classes.html_element;
        }
        // Note: document_fragment nodes from templates are document-owned,
        // so we use dom_node class (no finalizer). The document_fragment class
        // with its finalizer is only for JS-created fragments via new DocumentFragment().

        // create new wrapper using the appropriate class
        const obj = ctx.newObjectClass(class_id);
        try ctx.setOpaque(obj, node);

        // nodeType is set as instance property (for fast access)
        // nodeName uses the prototype getter
        const node_type_num: i32 = @intCast(@intFromEnum(n_type));
        try ctx.setPropertyStr(obj, "nodeType", ctx.newInt32(node_type_num));

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

const Listener = struct {
    callback: z.qjs.JSValue,
};

pub fn removeEventListener(
    ctx: zqjs.Context,
    self: *DOMBridge,
    node: *z.DomNode,
    event: []const u8,
    callback: zqjs.Value,
) !void {
    const node_id = @intFromPtr(node);

    if (self.registry.getPtr(node_id)) |node_map| {
        if (node_map.getPtr(event)) |listeners| {
            for (listeners.items, 0..) |l, i| {
                const cb_a = std.mem.asBytes(&l.callback);
                const cb_b = std.mem.asBytes(&callback);
                if (std.mem.eql(u8, cb_a, cb_b)) {
                    // Release the JS reference. duped it in addEventListener
                    ctx.freeValue(l.callback);
                    _ = listeners.orderedRemove(i);
                    return;
                }
            }
        }
    }
}

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
    // !! CRITICAL !!: Increment refcount so the function isn't garbage collected!
    const dup_cb = ctx.dupValue(callback);
    try event_entry.value_ptr.append(self.allocator, .{ .callback = dup_cb });
}

/// Dispatch an event to a target node, handling bubbling and invoking listeners.Takes a raw JS Value for the event (either a string type or an Event object).
pub fn dispatchEvent(
    ctx: zqjs.Context,
    self: *DOMBridge,
    target_node: *z.DomNode,
    event_arg: zqjs.Value, // Raw JS Value
) !bool {
    const rc = RuntimeContext.get(ctx);
    var js_event = event_arg;
    var ev_struct: *js_events.DomEvent = undefined;
    var created_locally = false;

    // PATH A: dispatchEvent("click")
    if (ctx.isString(event_arg)) {
        const type_str = try ctx.toZString(event_arg);
        defer ctx.freeZString(type_str);

        ev_struct = try js_events.DomEvent.init(
            rc.allocator,
            type_str,
            true,
            true,
        );

        js_event = ctx.newObjectClass(rc.classes.event);
        try ctx.setOpaque(js_event, ev_struct);
        created_locally = true;
    }
    // PATH B: Standard with class Event: dispatchEvent(new Event("click"))
    else {
        const ptr = ctx.getOpaque(event_arg, rc.classes.event);
        if (ptr == null) return false;

        ev_struct = @ptrCast(@alignCast(ptr));
    }

    // Clean up if we created a temporary wrapper
    defer if (created_locally) ctx.freeValue(js_event);

    // --- Standard Bubbling  ---
    ev_struct.target = @ptrCast(target_node);
    ev_struct.phase = .AT_TARGET;
    ev_struct.current_target = null;

    var current_node: ?*z.DomNode = target_node;

    while (current_node) |node| : (current_node = z.parentNode(node)) {
        if (ev_struct.stop_propagation) break;
        if (!ev_struct.bubbles and node != target_node) break;

        ev_struct.current_target = @ptrCast(node);
        if (node != target_node) ev_struct.phase = .BUBBLING_PHASE;

        const node_id = @intFromPtr(node);
        if (self.registry.getPtr(node_id)) |node_map| {
            if (node_map.getPtr(ev_struct.type)) |listeners| {
                const js_this = try DOMBridge.wrapNode(ctx, node);
                defer ctx.freeValue(js_this);

                for (listeners.items) |l| {
                    if (ev_struct.stop_immediate) break;
                    // Pass the JS Event Object
                    const ret = ctx.call(l.callback, js_this, &.{js_event});
                    ctx.freeValue(ret);
                }
            }
        }
    }

    return !ev_struct.default_prevented;
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

    const rc = RuntimeContext.get(ctx);

    // Free old result if exists
    if (rc.last_result) |old_val| {
        ctx.freeValue(old_val);
    }

    // Store new result (duplicate to survive)
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

    // Unwrap 'this' (Polymorphic): try Element first (most common), then Document, then Fragment
    var root_node: ?*z.DomNode = null;

    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        root_node = z.elementToNode(@ptrCast(ptr));
    } else if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| {
        // Document: start searching from the document root (<html>)
        const doc: *z.HTMLDocument = @ptrCast(ptr);
        root_node = z.documentRoot(doc);
    } else if (ctx.getOpaque(this_val, rc.classes.document_fragment)) |ptr| {
        root_node = z.fragmentToNode(@ptrCast(ptr));
    } else {
        return ctx.throwTypeError("querySelector called on invalid object");
    }

    if (root_node == null) return w.NULL;

    const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(selector_str);

    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

    // Pass generic *DomNode to your new engine API
    if (bridge.css_engine.querySelector(root_node.?, selector_str) catch return w.EXCEPTION) |found_node| {
        // 4. Wrap Result (Polymorphic wrapNode handles Element vs Node)
        return DOMBridge.wrapElement(ctx, found_node) catch w.EXCEPTION;
    }

    return w.NULL;
}

fn js_querySelectorAll(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]zqjs.Value,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.EXCEPTION;

    // Unwrap 'this' (Polymorphic: Element, Document, or Fragment)
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

    const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(selector_str);

    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

    // engine.querySelectorAll returns []*z.HTMLElement
    const elements = bridge.css_engine.querySelectorAll(root_node.?, selector_str) catch return w.EXCEPTION;
    defer bridge.allocator.free(elements); // Free the slice

    // JS Array
    const array = ctx.newArray();
    for (elements, 0..) |el, i| {
        const val = DOMBridge.wrapElement(ctx, el) catch continue;
        _ = ctx.setPropertyUint32(array, @intCast(i), val) catch {};
    }

    return array;
}

fn js_matches(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.EXCEPTION;

    // Get Element from 'this'
    const ptr = ctx.getOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("matches() called on non-Element");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

    const selector_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(selector_str);

    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

    // Note: matchNode expects a generic *DomNode
    const result = bridge.css_engine.matches(el, selector_str) catch return w.EXCEPTION;

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

/// parent.insertBefore(newChild, refChild) - refChild can be null
fn js_insertBefore(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };

    if (argc < 1) return ctx.throwTypeError("insertBefore requires at least 1 argument");

    // Unwrap parent (this)
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse
        return ctx.throwTypeError("'this' is not a Node");

    // Unwrap newChild (first argument)
    const new_child = DOMBridge.unwrapNode(ctx, argv[0]) orelse
        return ctx.throwTypeError("First argument must be a Node");

    // Unwrap refChild (second argument, can be null/undefined)
    const ref_child: ?*z.DomNode = if (argc >= 2 and !ctx.isNull(argv[1]) and !ctx.isUndefined(argv[1]))
        DOMBridge.unwrapNode(ctx, argv[1])
    else
        null;

    // Call the Zig implementation
    const result = z.jsInsertBefore(parent, new_child, ref_child);

    // Return the inserted node
    return DOMBridge.wrapNode(ctx, result) catch return w.EXCEPTION;
}

fn js_get_parentNode(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return w.EXCEPTION;
    const parent = z.parentNode(node);
    if (parent) |p| {
        return DOMBridge.wrapNode(ctx, p) catch return w.EXCEPTION;
    }
    return w.NULL;
}

fn js_get_ownerDocument(
    ctx_ptr: ?*z.qjs.JSContext,
    _: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    // Return the global document object
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    return ctx.getPropertyStr(global, "document");
}

// Dummy implementation to stop JS from crashing
fn js_preventDefault(
    _: ?*z.qjs.JSContext,
    _: z.qjs.JSValue,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    return w.UNDEFINED;
}

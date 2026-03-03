const std = @import("std");
const builtin = @import("builtin");
const z = @import("root.zig");
const zqjs = z.wrapper;
const w = @import("wrapper.zig");
const bindings = @import("bindings_generated.zig");
const RuntimeContext = z.RuntimeContext;
const js_DocFragment = z.js_DocFragment;
const js_DOMParser = z.js_DOMParser;
const CssSelectorEngine = z.CssSelectorEngine;
const js_style = z.js_CSSStyleDeclaration;
const js_classList = z.js_classList;
const js_dataset = z.js_dataset;
pub const js_url = z.js_url;
const js_headers = z.js_headers;
const js_events = z.js_events;
const js_blob = z.js_blob;
const js_file = z.js_File;
const js_formData = z.js_formData;
const js_polyfills = z.js_polyfills;
const js_store = z.js_store;
const js_filelist = z.js_filelist;
const js_file_reader_sync = z.js_file_reader_sync;
const js_file_reader = z.js_file_reader;
const js_text_encoding = z.js_text_encoding;
const js_readable_stream = z.js_readable_stream;
const js_writable_stream = z.js_writable_stream;
const js_range = z.js_range;
const js_tree_walker = z.js_tree_walker;
const js_XMLSerializer = z.js_XMLSerializer;
const js_streamfrom = z.js_streamfrom;
const js_llm = z.js_llm;
const js_markdown = z.js_markdown;
const js_csv = z.js_csv;
const js_canvas = z.js_canvas;
const js_image = z.js_image;
const js_pdf = z.js_pdf;
const js_utils = z.js_utils;
const js_compositor = z.js_compositor;
const js_stdin = z.js_stdin;
const SanitizeOptions = z.sanitize.SanitizeOptions;

pub const DOMBridge = struct {
    allocator: std.mem.Allocator,
    ctx: w.Context,
    doc: *z.HTMLDocument,
    registry: std.AutoHashMap(usize, std.StringHashMap(std.ArrayListUnmanaged(Listener))), // events registry
    node_cache: std.AutoHashMap(usize, zqjs.Value), // (Ptr Address -> JS Object)
    css_engine: CssSelectorEngine, // CSS Selector Engine
    css_style_parser: *z.CssStyleParser,
    stylesheet: *z.CssStyleSheet,
    stylesheet_attached: bool = false, // true after attachStylesheet — destroyDocumentStylesheets handles cleanup

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

    /// Custom createElement that handles canvas and template elements specially
    /// - canvas: Returns a native Canvas object with a backing DOM <canvas> element
    /// - template: Uses z.createTemplate() which properly creates the content DocumentFragment
    fn js_createElement_with_canvas(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
        const ctx = w.Context.from(ctx_ptr);
        const rc = RuntimeContext.get(ctx);

        if (argc < 1) return w.EXCEPTION;

        // Get tag name
        const tag_name = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        defer ctx.freeZString(tag_name);

        // Get document from this_val (needed for all element types)
        const doc: *z.HTMLDocument = blk: {
            if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
            if (ctx.getOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
            return ctx.throwTypeError("Method called on object that is not a Document");
        };

        // Handle canvas specially - native Canvas with backing DOM element
        if (std.ascii.eqlIgnoreCase(tag_name, "canvas")) {
            // Create Canvas instance (default 300x150 per HTML spec)
            const canvas_struct = js_canvas.Canvas.init(rc.allocator, 300, 150) catch return ctx.throwOutOfMemory();

            // Create backing DOM <canvas> element for DOM tree participation
            canvas_struct.element = z.createElement(doc, "canvas") catch {
                canvas_struct.deinit();
                return ctx.throwInternalError("createElement canvas failed");
            };

            // Create JS object with canvas class
            const obj = ctx.newObjectClass(rc.classes.canvas);
            if (ctx.isException(obj)) {
                canvas_struct.deinit();
                return w.EXCEPTION;
            }

            // Link opaque pointer
            ctx.setOpaque(obj, canvas_struct) catch return w.EXCEPTION;

            // Register in node_cache keyed by the backing DOM element so that
            // querySelector / wrapNode returns this Canvas object (not a plain html_element).
            if (canvas_struct.element) |el| {
                const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
                const ptr_addr = @intFromPtr(@as(*z.DomNode, @ptrCast(@alignCast(el))));
                const dup_for_cache = ctx.dupValue(obj);
                bridge.node_cache.put(ptr_addr, dup_for_cache) catch {};
            }

            return obj;
        }

        // Note: createElement("img") falls through to the default path and returns
        // a regular html_element wrapped <img> DOM element. This gives it full DOM
        // methods (className, style, getAttribute, appendChild, etc.).
        // Only `new Image()` creates the full HTMLImageElement wrapper with bitmap/onload.

        // Handle template specially - requires z.createTemplate for proper content DocumentFragment
        if (std.ascii.eqlIgnoreCase(tag_name, "template")) {
            const template = z.createTemplate(doc) catch return ctx.throwInternalError("createTemplate failed");
            const element = z.templateToElement(template);
            return DOMBridge.wrapElement(ctx, element) catch return ctx.throwOutOfMemory();
        }

        // For all other elements, use the standard createElement
        const result = z.createElement(doc, tag_name) catch return ctx.throwInternalError("createElement failed");
        return DOMBridge.wrapElement(ctx, result) catch return ctx.throwOutOfMemory();
    }

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
            js_utils.defineGetter(ctx, node_proto, "childNodes", js_get_childNodes);
            js_utils.defineGetter(ctx, node_proto, "children", js_get_children);
            js_utils.defineGetter(ctx, node_proto, "isConnected", js_get_isConnected);

            js_utils.defineMethod(ctx, node_proto, "insertBefore", js_insertBefore, 2);
            js_utils.defineMethod(ctx, node_proto, "appendChild", js_appendChild_manual, 1);
            js_utils.defineMethod(ctx, node_proto, "querySelector", js_querySelector, 1);
            js_utils.defineMethod(ctx, node_proto, "querySelectorAll", js_querySelectorAll, 1);
            js_utils.defineMethod(ctx, node_proto, "getElementsByClassName", js_getElementsByClassName, 1);
            js_utils.defineMethod(ctx, node_proto, "append", js_append, -1);
            js_utils.defineMethod(ctx, node_proto, "prepend", js_prepend, -1);
            js_utils.defineMethod(ctx, node_proto, "before", js_before, -1);
            js_utils.defineMethod(ctx, node_proto, "after", js_after, -1);
            js_utils.defineMethod(ctx, node_proto, "replaceWith", js_replaceWith, -1);
            js_utils.defineMethod(ctx, node_proto, "replaceChildren", js_replaceChildren, -1);
            js_utils.defineMethod(ctx, node_proto, "splitText", js_splitText, 1);

            ctx.setClassProto(rc.classes.dom_node, node_proto);

            // --- HTML_ELEMENT ------------------
            rc.classes.html_element = rt.newClassID();
            try rt.newClass(rc.classes.html_element, .{
                .class_name = "HTMLElement",
                .finalizer = domFinalizer,
                .exotic = &form_exotic_methods,
            });

            const el_proto = ctx.newObject();
            bindings.installElementBindings(ctx.ptr, el_proto);

            // Methods (override generated bindings where needed)
            js_utils.defineMethod(ctx, el_proto, "setAttribute", js_setAttribute_sanitized, 2);
            js_utils.defineMethod(ctx, el_proto, "querySelector", js_querySelector, 1);
            js_utils.defineMethod(ctx, el_proto, "querySelectorAll", js_querySelectorAll, 1);
            js_utils.defineMethod(ctx, el_proto, "getElementsByClassName", js_getElementsByClassName, 1);
            js_utils.defineMethod(ctx, el_proto, "matches", js_matches, 1);
            js_utils.defineMethod(ctx, el_proto, "closest", js_closest, 1);
            js_utils.defineMethod(ctx, el_proto, "insertAdjacentHTML", js_insertAdjacentHTML, 2);
            js_utils.defineMethod(ctx, el_proto, "insertAdjacentElement", js_insertAdjacentElement, 2);
            js_utils.defineMethod(ctx, el_proto, "focus", js_focus, 0);
            js_utils.defineMethod(ctx, el_proto, "getBoundingClientRect", js_HTMLElement_getBoundingClientRect, 0);
            js_utils.defineMethod(ctx, el_proto, "getAttributeNames", js_getAttributeNames, 0);
            js_utils.defineMethod(ctx, el_proto, "hasAttributes", js_hasAttributes, 0);

            // Accessor properties (getter + setter)
            js_utils.defineAccessor(ctx, el_proto, "innerHTML", js_get_innerHTML, js_set_innerHTML);
            js_utils.defineAccessor(ctx, el_proto, "outerHTML", js_get_outerHTML, js_set_outerHTML);
            js_utils.defineAccessor(ctx, el_proto, "style", js_style.get_element_style, js_style.set_element_style);
            js_utils.defineAccessor(ctx, el_proto, "src", js_HTMLElement_get_src, js_HTMLElement_set_src);
            js_utils.defineAccessor(ctx, el_proto, "href", js_HTMLElement_get_href, js_HTMLElement_set_href);
            js_utils.defineAccessor(ctx, el_proto, "value", js_get_value, js_set_value);

            // Getter-only properties
            js_utils.defineGetter(ctx, el_proto, "clientWidth", js_HTMLElement_clientWidth);
            js_utils.defineGetter(ctx, el_proto, "clientHeight", js_HTMLElement_clientHeight);
            js_utils.defineGetter(ctx, el_proto, "attributes", js_get_attributes);

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

            // Override createElement to handle canvas elements
            const create_elem_fn = ctx.newCFunction(js_createElement_with_canvas, "createElement", 1);
            try ctx.setPropertyStr(doc_proto, "createElement", create_elem_fn);

            // Native importNode — properly handles ownerDocument adoption (Lit needs this)
            const import_node_fn = ctx.newCFunction(js_importNode, "importNode", 2);
            try ctx.setPropertyStr(doc_proto, "importNode", import_node_fn);

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

            // Install getPropertyValue, setProperty, removeProperty
            // AND all CSS property getter/setters (style.color, style.fontSize, etc.)
            bindings.installCSSStyleDeclarationBindings(ctx.ptr, style_proto);

            ctx.setClassProto(rc.classes.css_style_decl, style_proto);
        }

        // Expose DOM constructor globals BEFORE polyfills
        // (frameworks like Svelte need Node.prototype, Text.prototype, Element.prototype)
        {
            const global = ctx.getGlobalObject();
            defer ctx.freeValue(global);

            // HTMLElement (polyfills like onclick need HTMLElement.prototype)
            const html_element_ctor = ctx.newCFunction2(js_HTMLElement_constructor, "HTMLElement", 0, z.qjs.JS_CFUNC_constructor, 0);
            const html_element_proto = ctx.getClassProto(rc.classes.html_element);
            try ctx.setPropertyStr(html_element_ctor, "prototype", html_element_proto);
            try ctx.setPropertyStr(global, "HTMLElement", html_element_ctor);

            // Node — callable constructor so `instanceof Node` works.
            // Svelte uses Object.getOwnPropertyDescriptor(Node.prototype, 'firstChild')
            {
                const node_ctor = ctx.newCFunction2(js_illegal_constructor, "Node", 0, z.qjs.JS_CFUNC_constructor, 0);
                try ctx.setPropertyStr(node_ctor, "prototype", ctx.getClassProto(rc.classes.dom_node));
                try ctx.setPropertyStr(node_ctor, "ELEMENT_NODE", ctx.newInt32(1));
                try ctx.setPropertyStr(node_ctor, "TEXT_NODE", ctx.newInt32(3));
                try ctx.setPropertyStr(node_ctor, "COMMENT_NODE", ctx.newInt32(8));
                try ctx.setPropertyStr(node_ctor, "DOCUMENT_NODE", ctx.newInt32(9));
                try ctx.setPropertyStr(node_ctor, "DOCUMENT_FRAGMENT_NODE", ctx.newInt32(11));
                try ctx.setPropertyStr(global, "Node", node_ctor);
            }

            // Text — Svelte checks Object.isExtensible(Text.prototype)
            {
                const text_ctor = ctx.newCFunction2(js_illegal_constructor, "Text", 0, z.qjs.JS_CFUNC_constructor, 0);
                try ctx.setPropertyStr(text_ctor, "prototype", ctx.getClassProto(rc.classes.dom_node));
                try ctx.setPropertyStr(global, "Text", text_ctor);
            }

            // Element — Svelte patches Element.prototype with __click, __className etc.
            {
                const element_ctor = ctx.newCFunction2(js_illegal_constructor, "Element", 0, z.qjs.JS_CFUNC_constructor, 0);
                try ctx.setPropertyStr(element_ctor, "prototype", ctx.getClassProto(rc.classes.html_element));
                try ctx.setPropertyStr(global, "Element", element_ctor);
            }

            // Document
            {
                const doc_ctor = ctx.newCFunction2(js_illegal_constructor, "Document", 0, z.qjs.JS_CFUNC_constructor, 0);
                try ctx.setPropertyStr(doc_ctor, "prototype", ctx.getClassProto(rc.classes.document));
                try ctx.setPropertyStr(global, "Document", doc_ctor);
            }
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
        try js_canvas.install(ctx); // Must be before polyfills for document.createElement('canvas')
        try js_image.install(ctx);
        try js_polyfills.install(ctx);
        try js_file.install(ctx);
        try js_filelist.install(ctx);
        try js_file_reader.FileReaderBridge.install(ctx);
        try js_text_encoding.install(ctx);
        try js_readable_stream.install(ctx);
        try js_writable_stream.install(ctx);
        try js_file_reader_sync.FileReaderSyncBridge.install(ctx);
        try js_range.RangeBridge.install(ctx);
        try js_tree_walker.TreeWalkerBridge.install(ctx);
        try js_XMLSerializer.XMLSerializerBridge.install(ctx);
        try js_pdf.install(ctx);

        const doc = try z.createDocument();
        errdefer z.destroyDocument(doc);

        // NOTE: Do NOT call initDocumentCSS here - it will be called by
        // loadHTML/loadPage after the actual HTML is parsed and sanitized.
        // Calling it here on the empty doc causes corruption when the doc
        // is later re-parsed by insertHTML (lxb_html_document_parse).
        try z.insertHTML(doc, "<html><head></head><body></body></html>");
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
        // Destroy attached <style>-tag stylesheets before the document CSS state.
        // lxb_dom_document_css_destroy() only frees the array pointer, NOT the
        // individual stylesheet objects (each has its own memory pool).
        z.destroyDocumentStylesheets(self.doc);
        // Destroy document CSS state — pairs with initDocumentCSS() in loadPage.
        // lxb_dom_document_css_destroy() is null-safe (no-op if not initialized).
        z.destroyDocumentCSS(self.doc);
        z.destroyDocument(self.doc);
        const rc = RuntimeContext.get(self.ctx);
        rc.global_document = null;

        self.css_engine.deinit();
        z.destroyCssStyleParser(self.css_style_parser);
        // Only destroy if not attached: destroyDocumentStylesheets already freed it if it was attached.
        if (!self.stylesheet_attached) {
            z.destroyStylesheet(self.stylesheet);
        }

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

        // Compositor: generateRoutePng(mapData, svgString, filename)
        try ctx.setPropertyStr(global, "__native_generateRoutePng", ctx.newCFunction(js_compositor.js_generateRoutePng, "generateRoutePng", 5));

        try ctx.setPropertyStr(global, "__native_stdinRead", ctx.newCFunction(js_stdin.js_native_stdinRead, "stdinRead", 0));
        try ctx.setPropertyStr(global, "__native_stdinReadBytes", ctx.newCFunction(js_stdin.js_native_stdinReadBytes, "stdinReadBytes", 0));
        try ctx.setPropertyStr(global, "__native_paintDOM", ctx.newCFunction(js_compositor.js_paintDOM, "paintDOM", 5));
        try ctx.setPropertyStr(global, "__native_paintElement", ctx.newCFunction(js_compositor.js_paintElement, "paintElement", 2));
        try ctx.setPropertyStr(global, "__native_paintSVG", ctx.newCFunction(js_paintSVG, "paintSVG", 1));
        try ctx.setPropertyStr(global, "__native_streamFrom", ctx.newCFunction(js_streamfrom.js_native_streamFrom, "streamFrom", 1));
        try ctx.setPropertyStr(global, "__native_llmHTML", ctx.newCFunction(js_llm.js_native_llmHTML, "llmHTML", 1));
        try ctx.setPropertyStr(global, "__native_llmStream", ctx.newCFunction(js_llm.js_native_llmStream, "llmStream", 1));
        try ctx.setPropertyStr(global, "__native_markdownToHTML", ctx.newCFunction(js_markdown.js_native_markdownToHTML, "markdownToHTML", 1));
        try ctx.setPropertyStr(global, "__native_parseCSV", ctx.newCFunction(js_csv.js_native_parseCSV, "parseCSV", 1));
        try ctx.setPropertyStr(global, "__native_stringifyCSV", ctx.newCFunction(js_csv.js_native_stringifyCSV, "stringifyCSV", 1));
        try ctx.setPropertyStr(global, "__native_evalModule", ctx.newCFunction(js_native_evalModule, "evalModule", 2));

        // Persistent store — zxp.store.* (backed by SQLite in {sandbox_root}/zxp_store.db)
        try ctx.setPropertyStr(global, "__native_store_save", ctx.newCFunction(js_store.js_store_save, "store_save", 3));
        try ctx.setPropertyStr(global, "__native_store_get", ctx.newCFunction(js_store.js_store_get, "store_get", 1));
        try ctx.setPropertyStr(global, "__native_store_list", ctx.newCFunction(js_store.js_store_list, "store_list", 0));
        try ctx.setPropertyStr(global, "__native_store_delete", ctx.newCFunction(js_store.js_store_delete, "store_delete", 1));

        // HTMLElement constructor is now exposed in init() before polyfills

        {
            const crypto_obj = ctx.newObject();
            const get_rand_fn = ctx.newCFunction(js_crypto_getRandomValues, "getRandomValues", 1);
            try ctx.setPropertyStr(crypto_obj, "getRandomValues", get_rand_fn);
            try ctx.setPropertyStr(global, "crypto", crypto_obj);
        }

        {
            const ls_obj = ctx.newObject();
            try ctx.setPropertyStr(ls_obj, "getItem", ctx.newCFunction(js_localStorage_getItem, "getItem", 1));
            try ctx.setPropertyStr(ls_obj, "setItem", ctx.newCFunction(js_localStorage_setItem, "setItem", 2));
            try ctx.setPropertyStr(ls_obj, "removeItem", ctx.newCFunction(js_localStorage_removeItem, "removeItem", 1));
            try ctx.setPropertyStr(ls_obj, "clear", ctx.newCFunction(js_localStorage_clear, "clear", 0));
            try ctx.setPropertyStr(global, "localStorage", ls_obj);
        }
    }

    fn createDocumentAPI(self: *DOMBridge, global: w.Value, _: w.ClassID) !void {
        const ctx = self.ctx;
        const rc = RuntimeContext.get(ctx);

        // 'document' instance inherits from Document.prototype
        const doc_obj = ctx.newObjectClass(rc.classes.document);

        try ctx.setOpaque(doc_obj, self.doc);
        try ctx.setPropertyStr(doc_obj, "_native_doc", ctx.dupValue(doc_obj));
        // nodeType = 9 (DOCUMENT_NODE) — required by DOMPurify's isSupported check
        try ctx.setPropertyStr(doc_obj, "nodeType", ctx.newInt32(9));

        // Manual Bindings (querySelector, createRange)
        const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
        try ctx.setPropertyStr(doc_obj, "querySelector", qs_fn);

        const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
        try ctx.setPropertyStr(doc_obj, "querySelectorAll", qsa_fn);

        const cr_fn = ctx.newCFunction(js_createRange, "createRange", 0);
        try ctx.setPropertyStr(doc_obj, "createRange", cr_fn);

        const gtn_fn = ctx.newCFunction(js_getElementsByTagName, "getElementsByTagName", 1);
        try ctx.setPropertyStr(doc_obj, "getElementsByTagName", gtn_fn);

        const gcn_fn = ctx.newCFunction(js_getElementsByClassName, "getElementsByClassName", 1);
        try ctx.setPropertyStr(doc_obj, "getElementsByClassName", gcn_fn);

        const ctn_fn = ctx.newCFunction(js_createTextNode, "createTextNode", 1);
        try ctx.setPropertyStr(doc_obj, "createTextNode", ctn_fn);

        const ctw_fn = ctx.newCFunction(js_tree_walker.js_createTreeWalker, "createTreeWalker", 2);
        try ctx.setPropertyStr(doc_obj, "createTreeWalker", ctw_fn);

        // Sanitizer API - parseHTMLSafe(html, options?)
        const phs_fn = ctx.newCFunction(js_parseHTMLSafe, "parseHTMLSafe", 2);
        try ctx.setPropertyStr(doc_obj, "parseHTMLSafe", phs_fn);

        // Expose 'document' on global
        try ctx.setPropertyStr(global, "document", doc_obj);
    }

    fn createWindowAPI(self: *DOMBridge, global: w.Value) !void {
        const ctx = self.ctx;

        // window === globalThis === self (browser invariant)
        // Do NOT create a separate object — frameworks use window/self/globalThis
        // interchangeably and expect them to be the same object.
        try ctx.setPropertyStr(global, "window", ctx.dupValue(global));
        try ctx.setPropertyStr(global, "self", ctx.dupValue(global));

        const loc_obj = ctx.newObject();
        try ctx.setPropertyStr(loc_obj, "href", ctx.newString("about:blank"));
        try ctx.setPropertyStr(global, "location", loc_obj);

        // navigator is set in js_polyfills.install()

        // history API (Next.js router uses pushState/replaceState)
        const history_obj = ctx.newObject();
        const noop_fn = ctx.newCFunction(struct {
            fn f(_: ?*z.qjs.JSContext, _: w.Value, _: c_int, _: [*c]w.Value) callconv(.c) w.Value {
                return w.UNDEFINED;
            }
        }.f, "noop", 3);
        try ctx.setPropertyStr(history_obj, "pushState", ctx.dupValue(noop_fn));
        try ctx.setPropertyStr(history_obj, "replaceState", ctx.dupValue(noop_fn));
        try ctx.setPropertyStr(history_obj, "back", ctx.dupValue(noop_fn));
        try ctx.setPropertyStr(history_obj, "forward", ctx.dupValue(noop_fn));
        try ctx.setPropertyStr(history_obj, "go", noop_fn);
        try ctx.setPropertyStr(history_obj, "state", w.NULL);
        try ctx.setPropertyStr(global, "history", history_obj);

        const gcs_fn = ctx.newCFunction(js_style.window_getComputedStyle, "getComputedStyle", 1);
        try ctx.setPropertyStr(global, "getComputedStyle", gcs_fn);

        // document.defaultView → globalThis (React 19 accesses constructors like
        // document.defaultView.HTMLIFrameElement; in browsers defaultView === window === globalThis)
        const doc_val = ctx.getPropertyStr(global, "document");
        if (!ctx.isUndefined(doc_val)) {
            try ctx.setPropertyStr(doc_val, "defaultView", ctx.dupValue(global));
            ctx.freeValue(doc_val);
        } else {
            ctx.freeValue(doc_val);
        }

        // Standard global aliases
        try ctx.setPropertyStr(global, "globalThis", ctx.dupValue(global));
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
        ctx.setOpaque(obj, doc) catch {
            _ = ctx.throwTypeError("Failed to wrap document node");
            return error.Exception;
        };

        const dup_for_cache = ctx.dupValue(obj);
        bridge.node_cache.put(ptr_addr, dup_for_cache) catch {
            _ = ctx.throwTypeError("Out of memory caching document node");
            return error.Exception;
        };

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
        ctx.setOpaque(obj, element) catch {
            _ = ctx.throwTypeError("Failed to wrap element");
            return error.Exception;
        };

        // Add convenience properties like tagName / nodeName (zero-copy)
        const tag = z.tagName_zc(element);
        ctx.setPropertyStr(obj, "tagName", ctx.newString(tag)) catch {
            _ = ctx.throwTypeError("Failed to set tagName on element");
            return error.Exception;
        };
        ctx.setPropertyStr(obj, "nodeName", ctx.newString(tag)) catch {
            _ = ctx.throwTypeError("Failed to set nodeName on element");
            return error.Exception;
        };

        // Add nodeType (ELEMENT_NODE = 1)
        ctx.setPropertyStr(obj, "nodeType", ctx.newInt32(1)) catch {
            _ = ctx.throwTypeError("Failed to set nodeType on element");
            return error.Exception;
        };

        // <template> only: install read-only .content getter on this instance
        if (z.elementToTemplate(element) != null) {
            js_utils.defineGetter(ctx, obj, "content", js_get_template_content);
        }

        // store in cache
        const dup_for_cache = ctx.dupValue(obj);
        bridge.node_cache.put(ptr_addr, dup_for_cache) catch {
            _ = ctx.throwTypeError("Out of memory caching element node");
            return error.Exception;
        };

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
        ctx.setOpaque(obj, node) catch {
            _ = ctx.throwTypeError("Failed to wrap node");
            return error.Exception;
        };

        // nodeType and nodeName as instance properties (for fast access)
        const node_type_num: i32 = @intCast(@intFromEnum(n_type));
        ctx.setPropertyStr(obj, "nodeType", ctx.newInt32(node_type_num)) catch {
            _ = ctx.throwTypeError("Failed to set nodeType on node");
            return error.Exception;
        };

        // nodeName: uses zero-copy lexbor lookup (#text, #comment, DIV, etc.)
        const node_name = z.nodeName_zc(node);
        ctx.setPropertyStr(obj, "nodeName", ctx.newString(node_name)) catch {
            _ = ctx.throwTypeError("Failed to set nodeName on node");
            return error.Exception;
        };

        // For element nodes, also set tagName (consistent with wrapElement)
        // This is critical because cloneNode uses wrapNode, and cached nodes
        // must have tagName for children[] access to work correctly
        if (n_type == .element) {
            const element: *z.HTMLElement = @ptrCast(@alignCast(node));
            const tag = z.tagName_zc(element);
            ctx.setPropertyStr(obj, "tagName", ctx.newString(tag)) catch {
                _ = ctx.throwTypeError("Failed to set tagName on node");
                return error.Exception;
            };

            // <template> only: install read-only .content getter on this instance
            if (z.elementToTemplate(element) != null) {
                js_utils.defineGetter(ctx, obj, "content", js_get_template_content);
            }
        }

        // store in cache
        const dup_for_cache = ctx.dupValue(obj);
        bridge.node_cache.put(ptr_addr, dup_for_cache) catch {
            _ = ctx.throwTypeError("Out of memory caching node");
            return error.Exception;
        };

        return obj;
    }

    /// Helper to unwrap ANY class that inherits from Node
    pub fn unwrapNode(ctx: w.Context, val: zqjs.Value) ?*z.DomNode {
        const rc = RuntimeContext.get(ctx);

        // 1. Is it a generic Node? (Text, Comment)
        if (ctx.getOpaque(val, rc.classes.dom_node)) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }

        // Element? (div, span)
        if (ctx.getOpaque(val, rc.classes.html_element)) |ptr| {
            const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
            return z.elementToNode(el); // Cast *HTMLElement -> *DomNode
        }

        // DocumentFragment?
        if (ctx.getOpaque(val, rc.classes.document_fragment)) |ptr| {
            const frag: *z.DocumentFragment = @ptrCast(@alignCast(ptr));
            return z.fragmentToNode(frag); // Cast *DocumentFragment -> *DomNode
        }

        // Document?
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

        // Canvas with a backing DOM element?
        if (ctx.getOpaque(val, rc.classes.canvas)) |ptr| {
            const canvas: *js_canvas.Canvas = @ptrCast(@alignCast(ptr));
            if (canvas.element) |el| return z.elementToNode(el);
        }

        // Image? (HTMLImageElement has a backing DOM <img> element)
        if (ctx.getOpaque(val, rc.classes.html_image)) |ptr| {
            const img: *js_image.HTMLImageElement = @ptrCast(@alignCast(ptr));
            if (img.element) |el| return z.elementToNode(el);
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
                    // DOM spec: listener can be a function OR an object with handleEvent method
                    if (ctx.isFunction(l.callback)) {
                        const ret = ctx.call(l.callback, js_this, &.{js_event});
                        ctx.freeValue(ret);
                    } else if (ctx.isObject(l.callback)) {
                        const handle_fn = ctx.getPropertyStr(l.callback, "handleEvent");
                        defer ctx.freeValue(handle_fn);
                        if (ctx.isFunction(handle_fn)) {
                            const ret = ctx.call(handle_fn, l.callback, &.{js_event});
                            ctx.freeValue(ret);
                        }
                    }
                }
            }
        }
    }

    // Browser spec: drain microtask queue after dispatching an event.
    // This lets frameworks like Vue/React flush their schedulers (nextTick)
    // without requiring an explicit __flush() call after every dispatchEvent.
    js_polyfills.drainMicrotasksGCSafe(z.qjs.JS_GetRuntime(ctx.ptr), ctx.ptr);

    return !ev_struct.default_prevented;
}

fn js_reportResult(
    ctx_ptr: ?*z.qjs.JSContext,
    _: z.qjs.JSValue,
    argc: c_int,
    argv: [*c]zqjs.Value,
) callconv(.c) zqjs.Value {
    const ctx = z.wrapper.Context.from(ctx_ptr);
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

// HTMLElement constructor (throws - elements cannot be constructed directly)
/// Shared "Illegal constructor" — browsers throw when you `new Node()`, `new Element()`, etc.
fn js_illegal_constructor(
    ctx_ptr: ?*z.qjs.JSContext,
    _: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    return ctx.throwTypeError("Illegal constructor");
}

const js_HTMLElement_constructor = js_illegal_constructor;

// --- NATIVE CALLBACKS (Using Wrapper API) ---
fn js_querySelector(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]zqjs.Value,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return ctx.throwTypeError("querySelector requires 1 argument");

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
    } else if (ctx.getOpaque(this_val, rc.classes.dom_node)) |ptr| {
        // Generic node (includes cloned DocumentFragments wrapped as dom_node)
        root_node = @ptrCast(@alignCast(ptr));
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
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return ctx.throwTypeError("querySelectorAll requires 1 argument");

    // Unwrap 'this' (Polymorphic: Element, Document, Fragment, or generic Node)
    var root_node: ?*z.DomNode = null;

    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        root_node = z.elementToNode(@ptrCast(ptr));
    } else if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| {
        const doc: *z.HTMLDocument = @ptrCast(ptr);
        root_node = z.documentRoot(doc);
    } else if (ctx.getOpaque(this_val, rc.classes.document_fragment)) |ptr| {
        root_node = z.fragmentToNode(@ptrCast(ptr));
    } else if (ctx.getOpaque(this_val, rc.classes.dom_node)) |ptr| {
        // Generic node (includes cloned DocumentFragments wrapped as dom_node)
        root_node = @ptrCast(@alignCast(ptr));
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
    const ctx = w.Context.from(ctx_ptr);
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

fn js_closest(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.NULL;

    const el = ctx.getOpaqueAs(z.HTMLElement, this_val, rc.classes.html_element) orelse {
        return ctx.throwTypeError("closest() called on non-Element");
    };

    const selector_str = ctx.toZString(argv[0]) catch return w.NULL;
    defer ctx.freeZString(selector_str);

    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
    const result = bridge.css_engine.closest(el, selector_str) catch return w.NULL;

    if (result) |found| {
        return DOMBridge.wrapElement(ctx, found) catch return w.NULL;
    }
    return w.NULL;
}

fn js_getAttributeNames(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const el = ctx.getOpaqueAs(z.HTMLElement, this_val, rc.classes.html_element) orelse {
        return ctx.throwTypeError("getAttributeNames() called on non-Element");
    };

    const arr = ctx.newArray();
    var iter = z.iterateAttributes(el);
    var i: u32 = 0;
    while (iter.next()) |pair| {
        const name_val = ctx.newString(pair.name);
        _ = ctx.setPropertyUint32(arr, i, name_val) catch {};
        i += 1;
    }
    return arr;
}

fn js_hasAttributes(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const el = ctx.getOpaqueAs(z.HTMLElement, this_val, rc.classes.html_element) orelse {
        return ctx.throwTypeError("hasAttributes() called on non-Element");
    };

    return if (z.hasAttributes(el)) w.TRUE else w.FALSE;
}

fn js_getElementsByTagName(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.EXCEPTION;

    // Get document from 'this'
    const ptr = ctx.getOpaque(this_val, rc.classes.document);
    if (ptr == null) return ctx.throwTypeError("getElementsByTagName() called on non-Document");
    const doc: *z.HTMLDocument = @ptrCast(@alignCast(ptr));

    const tag_name = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(tag_name);

    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));

    // Convert to uppercase for lexbor (HTML spec: case-insensitive)
    var upper_buf: [64]u8 = undefined;
    const upper_tag = blk: {
        if (tag_name.len > upper_buf.len) break :blk tag_name; // Too long, use as-is
        for (tag_name, 0..) |c, i| {
            upper_buf[i] = std.ascii.toUpper(c);
        }
        break :blk upper_buf[0..tag_name.len];
    };

    // Use Zig's getElementsByTagName
    const elements = z.getElementsByTagName(bridge.allocator, doc, upper_tag) catch return w.EXCEPTION;
    defer bridge.allocator.free(elements);

    // Convert to JS Array
    const array = ctx.newArray();
    for (elements, 0..) |el, i| {
        const val = DOMBridge.wrapElement(ctx, el) catch continue;
        _ = ctx.setPropertyUint32(array, @intCast(i), val) catch {};
    }

    return array;
}

fn js_getElementsByClassName(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return ctx.throwTypeError("getElementsByClassName requires 1 argument");

    // Unwrap 'this' (Polymorphic: Element, Document, Fragment, or generic Node)
    var root_node: ?*z.DomNode = null;

    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        root_node = z.elementToNode(@ptrCast(ptr));
    } else if (ctx.getOpaque(this_val, rc.classes.document)) |ptr| {
        const doc: *z.HTMLDocument = @ptrCast(ptr);
        root_node = z.documentRoot(doc);
    } else if (ctx.getOpaque(this_val, rc.classes.document_fragment)) |ptr| {
        root_node = z.fragmentToNode(@ptrCast(ptr));
    } else if (ctx.getOpaque(this_val, rc.classes.dom_node)) |ptr| {
        root_node = @ptrCast(@alignCast(ptr));
    } else {
        return ctx.throwTypeError("getElementsByClassName called on invalid object");
    }

    if (root_node == null) return ctx.newArray();

    const class_name = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(class_name);

    const bridge: *DOMBridge = @ptrCast(@alignCast(rc.dom_bridge.?));
    const elements = z.getElementsByClassNameFromNode(bridge.allocator, root_node.?, class_name) catch return w.EXCEPTION;
    defer bridge.allocator.free(elements);

    const array = ctx.newArray();
    for (elements, 0..) |el, i| {
        const val = DOMBridge.wrapElement(ctx, el) catch continue;
        _ = ctx.setPropertyUint32(array, @intCast(i), val) catch {};
    }

    return array;
}

fn js_get_childNodes(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    // Unwrap 'this' to *DomNode
    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("childNodes: 'this' is not a Node");

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

// children property - returns only element children (not text nodes)
fn js_get_children(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);

    // Unwrap 'this' to *DomNode
    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("children: 'this' is not a Node");

    const array = ctx.newArray();
    var idx: u32 = 0;

    // Iterate through children, only include elements
    var child = z.firstChild(node);
    while (child) |c| : (child = z.nextSibling(c)) {
        if (z.nodeToElement(c)) |el| {
            const val = DOMBridge.wrapElement(ctx, el) catch continue;
            _ = ctx.setPropertyUint32(array, idx, val) catch {};
            idx += 1;
        }
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
    const ctx = w.Context.from(ctx_ptr);

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

    if (z.parentNode(new_child)) |_| {
        z.removeNode(new_child);
    }

    if (z.nodeType(new_child) == .document_fragment) {
        var frag_child = z.firstChild(new_child);
        while (frag_child) |fc| {
            const next = z.nextSibling(fc);
            z.removeNode(fc); // Detach from the fragment!
            _ = z.jsInsertBefore(parent, fc, ref_child) catch
                return ctx.throwTypeError("NotFoundError: refChild is not a child of parent");
            frag_child = next;
        }

        return DOMBridge.wrapNode(ctx, new_child) catch return w.EXCEPTION;
    }

    // Call the Zig implementation
    const result = z.jsInsertBefore(parent, new_child, ref_child) catch
        return ctx.throwTypeError("NotFoundError: refChild is not a child of parent");

    // Return the inserted node
    return DOMBridge.wrapNode(ctx, result) catch return w.EXCEPTION;
}

/// parent.appendChild(child) - handles DocumentFragment specially (moves children)
/// Also handles dynamic <script> loading: when a <script src="..."> is appended,
/// synchronously fetches + evals + fires onload/onerror (like a browser).
fn js_appendChild_manual(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);

    if (argc < 1) return ctx.throwTypeError("appendChild requires 1 argument");

    // Unwrap parent (this)
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse
        return ctx.throwTypeError("'this' is not a Node");

    // Unwrap child (first argument)
    const child = DOMBridge.unwrapNode(ctx, argv[0]) orelse
        return ctx.throwTypeError("Argument must be a Node");

    if (z.parentNode(child)) |_| {
        z.removeNode(child);
    }

    // Check if child is a DocumentFragment
    const child_type = z.nodeType(child);

    // DEBUG: trace ALL appendChild calls

    {
        const parent_tag = if (z.nodeToElement(parent)) |pe| z.tagName_zc(pe) else "#node";
        const child_tag = switch (child_type) {
            .element => if (z.nodeToElement(child)) |ce| z.tagName_zc(ce) else "?element",
            .text => "#text",
            .comment => "#comment",
            .document_fragment => "#fragment",
            else => "#other",
        };
        if (builtin.mode == .Debug) {
            std.debug.print("[Zig appendChild] {s} into {s}\n", .{ child_tag, parent_tag });
        }
    }

    if (child_type == .document_fragment) {
        // Move all children from fragment to parent
        var frag_child = z.firstChild(child);
        while (frag_child) |fc| {
            const next = z.nextSibling(fc);
            z.appendChild(parent, fc);
            frag_child = next;
        }
        // Return the (now empty) fragment
        return DOMBridge.wrapNode(ctx, child) catch return w.EXCEPTION;
    } else {
        // Normal appendChild
        z.appendChild(parent, child);

        // Dynamic <script> loading: synchronously fetch + eval + fire onload
        if (child_type == .element) {
            const element: *z.HTMLElement = @ptrCast(@alignCast(child));
            if (std.mem.eql(u8, z.tagName_zc(element), "SCRIPT")) {
                if (z.getAttribute_zc(element, "src")) |src| {
                    handleDynamicScriptLoad(ctx, argv[0], src);
                }
            }
        }

        return DOMBridge.wrapNode(ctx, child) catch return w.EXCEPTION;
    }
}

/// document.importNode(node, deep) — clones a node and adopts it into this document.
/// Unlike cloneNode, this properly sets ownerDocument on the clone.
/// Critical for Lit which uses importNode to clone template content.
fn js_importNode(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("importNode requires at least 1 argument");

    // 'this' is the document
    const doc = ctx.getOpaqueAs(z.HTMLDocument, this_val, rc.classes.document) orelse
        ctx.getOpaqueAs(z.HTMLDocument, this_val, rc.classes.owned_document) orelse
        return ctx.throwTypeError("importNode called on non-Document object");

    // First argument: node to import
    const node = DOMBridge.unwrapNode(ctx, argv[0]) orelse
        return ctx.throwTypeError("First argument must be a Node");

    // Second argument: deep (default false)
    const deep = if (argc >= 2) z.qjs.JS_ToBool(ctx_ptr, argv[1]) != 0 else false;

    // Use lexbor's native importNode which handles ownerDocument adoption
    const result = z.importNode(node, doc, deep) orelse
        return ctx.throwTypeError("importNode failed");

    return DOMBridge.wrapNode(ctx, result) catch return w.EXCEPTION;
}

/// Synchronous fetch + eval for dynamically inserted <script src="...">.
/// Uses z.get() (blocking std.http.Client) so it completes immediately.
fn handleDynamicScriptLoad(ctx: w.Context, script_js: zqjs.Value, src: []const u8) void {
    const rc = RuntimeContext.get(ctx);

    z.print("[DynamicScript] Loading: {s}\n", .{src});

    // Synchronous HTTP GET
    const code = z.get(rc.allocator, src) catch |err| {
        z.print("[DynamicScript] Fetch failed '{s}': {}\n", .{ src, err });
        fireScriptEvent(ctx, script_js, "onerror");
        return;
    };
    defer rc.allocator.free(code);

    // Set document.currentScript
    const global = ctx.getGlobalObject();
    const doc_obj = ctx.getPropertyStr(global, "document");
    ctx.freeValue(global);
    if (!ctx.isUndefined(doc_obj)) {
        _ = ctx.setPropertyStr(doc_obj, "currentScript", ctx.dupValue(script_js)) catch {};
    }

    // Eval in global scope using QuickJS directly
    const c_code = rc.allocator.dupeZ(u8, code) catch {
        if (!ctx.isUndefined(doc_obj)) {
            _ = ctx.setPropertyStr(doc_obj, "currentScript", zqjs.NULL) catch {};
        }
        ctx.freeValue(doc_obj);
        fireScriptEvent(ctx, script_js, "onerror");
        return;
    };
    defer rc.allocator.free(c_code);

    const c_filename = rc.allocator.dupeZ(u8, src) catch {
        if (!ctx.isUndefined(doc_obj)) {
            _ = ctx.setPropertyStr(doc_obj, "currentScript", zqjs.NULL) catch {};
        }
        ctx.freeValue(doc_obj);
        fireScriptEvent(ctx, script_js, "onerror");
        return;
    };
    defer rc.allocator.free(c_filename);

    const val = z.qjs.JS_Eval(ctx.ptr, c_code.ptr, c_code.len, c_filename.ptr, z.qjs.JS_EVAL_TYPE_GLOBAL);

    if (z.qjs.JS_IsException(val)) {
        _ = ctx.checkAndPrintException();
        if (!ctx.isUndefined(doc_obj)) {
            _ = ctx.setPropertyStr(doc_obj, "currentScript", zqjs.NULL) catch {};
        }
        ctx.freeValue(doc_obj);
        fireScriptEvent(ctx, script_js, "onerror");
        return;
    }
    ctx.freeValue(val);

    // Reset document.currentScript
    if (!ctx.isUndefined(doc_obj)) {
        _ = ctx.setPropertyStr(doc_obj, "currentScript", zqjs.NULL) catch {};
    }
    ctx.freeValue(doc_obj);

    // Fire onload
    z.print("[DynamicScript] Loaded OK: {s}\n", .{src});
    fireScriptEvent(ctx, script_js, "onload");
}

/// Helper: call script_element.onload() or script_element.onerror()
fn fireScriptEvent(ctx: w.Context, script_js: zqjs.Value, event_name: [:0]const u8) void {
    const handler = ctx.getPropertyStr(script_js, event_name);
    defer ctx.freeValue(handler);
    if (z.qjs.JS_IsFunction(ctx.ptr, handler)) {
        const ret = z.qjs.JS_Call(ctx.ptr, handler, script_js, 0, null);
        ctx.freeValue(ret);
    }
}

fn js_get_parentNode(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
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
    const ctx = w.Context.from(ctx_ptr);
    // Return the global document object
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    return ctx.getPropertyStr(global, "document");
}

pub fn documentCreateRange(ctx: zqjs.Context, _: *z.HTMLDocument) !zqjs.Value {
    // Just call new Range() logic
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const ctor = ctx.getPropertyStr(global, "Range");
    defer ctx.freeValue(ctor);

    // Call constructor with 0 args
    return ctx.callConstructor(ctor, &.{});
}

fn js_createRange(
    ctx_ptr: ?*z.qjs.JSContext,
    _: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    // Call Range constructor with 0 args
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const ctor = ctx.getPropertyStr(global, "Range");
    defer ctx.freeValue(ctor);
    // Use JS_CallConstructor directly with argc=0
    return z.qjs.JS_CallConstructor(ctx.ptr, ctor, 0, null);
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

fn js_createTextNode(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    // const rc = RuntimeContext.get(ctx);

    // 'this' is the document object. We need to unwrap it to create a node in the right context.
    const doc_node = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("createTextNode called on invalid object");
    const doc = z.ownerDocument(doc_node);

    if (argc < 1) {
        // DOM spec says createTextNode with no arguments creates an empty text node.
        const empty_text_node = z.createTextNode(doc, "") catch return w.EXCEPTION;
        return DOMBridge.wrapNode(ctx, empty_text_node) catch w.EXCEPTION;
    }

    const text_content = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(text_content);

    const text_node = z.createTextNode(doc, text_content) catch return w.EXCEPTION;

    return DOMBridge.wrapNode(ctx, text_node) catch w.EXCEPTION;
}

/// document.parseHTMLSafe(html, options?) - Parse and sanitize HTML
/// - argc == 1: Parse with safe defaults (.{})
/// - argc == 2: Parse with custom options from JS object
///
/// Returns an OwnedDocument that the caller is responsible for.
/// The document is fully sanitized and has CSS engine initialized.
fn js_parseHTMLSafe(
    ctx_ptr: ?*z.qjs.JSContext,
    _: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const allocator = rc.allocator;

    if (argc < 1) {
        return ctx.throwTypeError("parseHTMLSafe requires at least 1 argument (html string)");
    }

    // Get HTML string
    const html = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(html);

    // Parse options from JS object (if provided)
    const opts = if (argc >= 2)
        jsToSanitizeOptions(ctx, argv[1])
    else
        z.SanitizeOptions{};

    // Parse and sanitize
    const doc = z.parseHTMLSafe(allocator, html, opts) catch {
        return ctx.throwTypeError("parseHTMLSafe failed");
    };

    // Wrap as OwnedDocument (caller owns it, will be finalized when GC'd)
    const doc_obj = ctx.newObjectClass(rc.classes.owned_document);
    ctx.setOpaque(doc_obj, doc) catch {
        z.destroyDocument(doc);
        return w.EXCEPTION;
    };

    return doc_obj;
}

/// Convert JS options object to SanitizeOptions
fn jsToSanitizeOptions(ctx: w.Context, opts_val: zqjs.Value) z.SanitizeOptions {
    var opts = z.SanitizeOptions{};

    // If not an object, return defaults
    if (!z.qjs.JS_IsObject(opts_val)) return opts;

    // Read boolean properties (undefined/missing = keep default)
    opts.remove_scripts = getJsBoolProperty(ctx, opts_val, "removeScripts") orelse opts.remove_scripts;
    opts.remove_styles = getJsBoolProperty(ctx, opts_val, "removeStyles") orelse opts.remove_styles;
    opts.sanitize_css = getJsBoolProperty(ctx, opts_val, "sanitizeCss") orelse opts.sanitize_css;
    opts.remove_comments = getJsBoolProperty(ctx, opts_val, "removeComments") orelse opts.remove_comments;
    opts.strict_uri = getJsBoolProperty(ctx, opts_val, "strictUri") orelse opts.strict_uri;
    opts.sanitize_dom_clobbering = getJsBoolProperty(ctx, opts_val, "sanitizeDomClobbering") orelse opts.sanitize_dom_clobbering;
    opts.allow_custom_elements = getJsBoolProperty(ctx, opts_val, "allowCustomElements") orelse opts.allow_custom_elements;
    opts.allow_embeds = getJsBoolProperty(ctx, opts_val, "allowEmbeds") orelse opts.allow_embeds;
    opts.allow_iframes = getJsBoolProperty(ctx, opts_val, "allowIframes") orelse opts.allow_iframes;
    opts.bypass_safety = getJsBoolProperty(ctx, opts_val, "bypassSafety") orelse opts.bypass_safety;

    // Read frameworks object (if present)
    const fw_val = ctx.getPropertyStr(opts_val, "frameworks");
    defer ctx.freeValue(fw_val);
    if (z.qjs.JS_IsObject(fw_val)) {
        opts.frameworks.allow_alpine = getJsBoolProperty(ctx, fw_val, "allowAlpine") orelse opts.frameworks.allow_alpine;
        opts.frameworks.allow_vue = getJsBoolProperty(ctx, fw_val, "allowVue") orelse opts.frameworks.allow_vue;
        opts.frameworks.allow_htmx = getJsBoolProperty(ctx, fw_val, "allowHtmx") orelse opts.frameworks.allow_htmx;
        opts.frameworks.allow_phoenix = getJsBoolProperty(ctx, fw_val, "allowPhoenix") orelse opts.frameworks.allow_phoenix;
        opts.frameworks.allow_angular = getJsBoolProperty(ctx, fw_val, "allowAngular") orelse opts.frameworks.allow_angular;
        opts.frameworks.allow_svelte = getJsBoolProperty(ctx, fw_val, "allowSvelte") orelse opts.frameworks.allow_svelte;
        opts.frameworks.allow_data_attrs = getJsBoolProperty(ctx, fw_val, "allowDataAttrs") orelse opts.frameworks.allow_data_attrs;
        opts.frameworks.allow_aria_attrs = getJsBoolProperty(ctx, fw_val, "allowAriaAttrs") orelse opts.frameworks.allow_aria_attrs;
    }

    return opts;
}

/// Helper to get a boolean property from a JS object, returns null if not present
fn getJsBoolProperty(ctx: w.Context, obj: zqjs.Value, name: [*:0]const u8) ?bool {
    const val = ctx.getPropertyStr(obj, name);
    defer ctx.freeValue(val);
    if (z.qjs.JS_IsUndefined(val)) return null;
    return ctx.toBool(val) catch null;
}

/// Helper to convert a list of JS values (nodes or strings) into a single DocumentFragment
fn jsValuesToFragment(ctx: w.Context, doc: *z.HTMLDocument, argc: c_int, argv: [*c]const zqjs.Value) !*z.DomNode {
    const frag_node = z.createDocumentFragmentNode(doc) catch return error.LexborError;

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        if (DOMBridge.unwrapNode(ctx, argv[i])) |node| {
            _ = z.appendChild(frag_node, node);
        } else {
            // Convert to string if not a node
            const str = ctx.toZString(argv[i]) catch ""; // Convert null/undefined to ""
            defer ctx.freeZString(str);
            if (str.len > 0) {
                const text_node = z.createTextNode(doc, str) catch return error.LexborError;
                _ = z.appendChild(frag_node, text_node);
            }
        }
    }
    return frag_node;
}

fn js_append(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for append");
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);

    // Move fragment's children to parent (detach from fragment first to avoid sibling chain corruption)
    var frag_child = z.firstChild(frag);
    while (frag_child) |fc| {
        const next = z.nextSibling(fc);
        z.removeNode(fc);
        z.appendChild(parent, fc);
        frag_child = next;
    }
    return w.UNDEFINED;
}

fn js_get_isConnected(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, _: c_int, _: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const node = DOMBridge.unwrapNode(ctx, this_val) orelse return zqjs.FALSE;

    // Walk up parentNode chain; if we reach a document node, it's connected
    var current: ?*z.DomNode = node;
    while (current) |cur| {
        if (z.nodeType(cur) == .document) return zqjs.TRUE;
        current = z.parentNode(cur);
    }
    return zqjs.FALSE;
}

fn js_focus(_: ?*z.qjs.JSContext, _: zqjs.Value, _: c_int, _: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    // No-op in headless environment
    return w.UNDEFINED;
}

fn js_prepend(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for prepend");
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);
    _ = z.jsInsertBefore(parent, frag, z.firstChild(parent)) catch return ctx.throwTypeError("NotFoundError: insertBefore failed");
    return w.UNDEFINED;
}

fn js_before(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const child = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for before");
    const parent = z.parentNode(child) orelse return w.UNDEFINED;
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);
    _ = z.jsInsertBefore(parent, frag, child) catch return ctx.throwTypeError("NotFoundError: insertBefore failed");
    return w.UNDEFINED;
}

fn js_after(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const child = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for after");
    const parent = z.parentNode(child) orelse return w.UNDEFINED;
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);
    _ = z.jsInsertBefore(parent, frag, z.nextSibling(child)) catch return ctx.throwTypeError("NotFoundError: insertBefore failed");
    return w.UNDEFINED;
}

/// Text.splitText(offset) - splits a text node at the given offset
fn js_splitText(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("splitText requires 1 argument");

    const node = DOMBridge.unwrapNode(ctx, this_val) orelse
        return ctx.throwTypeError("'this' is not a Node");

    var offset: i32 = undefined;
    if (z.qjs.JS_ToInt32(ctx_ptr, &offset, argv[0]) < 0) return w.EXCEPTION;
    if (offset < 0) return ctx.throwTypeError("Offset must be non-negative");

    const result = z.splitText(node, @intCast(offset)) catch |err| {
        return switch (err) {
            z.Err.NotTextNode => ctx.throwTypeError("splitText called on non-text node"),
            z.Err.DomException => ctx.throwTypeError("INDEX_SIZE_ERR: offset exceeds text length"),
            else => ctx.throwTypeError("splitText failed"),
        };
    };

    return DOMBridge.wrapNode(ctx, result) catch w.EXCEPTION;
}

/// Element.insertAdjacentHTML(position, html) - inserts parsed HTML relative to element
///
/// Strategy: Instead of DOMParser (creates elements in a separate document with wrong
/// owner_document and no CSS structures), we use setInnerHTML on a temp <div> in the
/// MAIN document. This ensures:
/// 1. Elements have correct owner_document (main doc with CSS initialized)
/// 2. CSS event watchers fire during parsing (lxb_style_event_insert)
/// 3. Stylesheet rules are applied immediately to new elements
///
/// When sanitization is enabled, HTML is first sanitized via temp doc roundtrip.
fn js_insertAdjacentHTML(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 2) return ctx.throwTypeError("insertAdjacentHTML requires 2 arguments");

    const el = unwrapElement(ctx, this_val, "insertAdjacentHTML called on non-Element") orelse return w.EXCEPTION;

    const position_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(position_str);

    const html_str = ctx.toZString(argv[1]) catch return w.EXCEPTION;
    defer ctx.freeZString(html_str);

    // Determine the final HTML (sanitized or raw)
    var clean_html_alloc: ?[]const u8 = null;
    defer if (clean_html_alloc) |ch| rc.allocator.free(ch);

    if (rc.sanitize_enabled) {
        const sanitizer_mod = @import("modules/sanitizer.zig");
        const strict_options = strictSanitizeOptions(rc);
        var san = sanitizer_mod.Sanitizer.init(rc.allocator, strict_options) catch {
            return ctx.throwTypeError("Failed to initialize sanitizer");
        };
        defer san.deinit();

        const temp_doc = z.parseHTML(rc.allocator, html_str) catch {
            return ctx.throwTypeError("insertAdjacentHTML: failed to parse HTML");
        };
        defer z.destroyDocument(temp_doc);

        const temp_body = z.bodyElement(temp_doc) orelse {
            return ctx.throwTypeError("insertAdjacentHTML: no body in parsed HTML");
        };
        san.sanitizeNodeInternal(z.elementToNode(temp_body)) catch {
            return ctx.throwTypeError("insertAdjacentHTML: sanitization failed");
        };

        clean_html_alloc = z.innerHTML(rc.allocator, temp_body) catch {
            return ctx.throwTypeError("insertAdjacentHTML: serialization failed");
        };
    }

    const final_html = clean_html_alloc orelse html_str;

    // Parse via setInnerHTML on a temp element in the MAIN document.
    // This uses lxb_html_element_inner_html_set which internally calls
    // lxb_html_document_parse_fragment(doc, &element->element, ...) so the
    const target_node = z.elementToNode(el);

    // Parse via a temp <div> in the MAIN document using setInnerHTML.
    // This ensures new elements get the correct owner_document (main doc),
    // so getComputedStyle and CSS rule application work correctly.
    // The sanitize path strips <style> tags before this point, so CSS
    // watchers won't crash. For trusted content (no sanitize), <style>
    // fragments are rare in insertAdjacentHTML usage.
    const main_doc = z.ownerDocument(target_node);
    const temp_div = z.createElement(main_doc, "div") catch {
        return ctx.throwInternalError("insertAdjacentHTML: failed to create temp div");
    };
    const temp_node = z.elementToNode(temp_div);
    defer z.destroyNode(temp_node);

    z.setInnerHTML(temp_div, final_html) catch {
        return ctx.throwInternalError("insertAdjacentHTML: setInnerHTML failed");
    };

    // Move children from temp element to the correct position
    if (std.ascii.eqlIgnoreCase(position_str, "beforeend")) {
        var child = z.firstChild(temp_node);
        while (child) |c| {
            const next = z.nextSibling(c);
            z.appendChild(target_node, c);
            child = next;
        }
    } else if (std.ascii.eqlIgnoreCase(position_str, "afterbegin")) {
        const first = z.firstChild(target_node);
        var child = z.firstChild(temp_node);
        while (child) |c| {
            const next = z.nextSibling(c);
            if (first) |f| {
                z.insertBefore(f, c);
            } else {
                z.appendChild(target_node, c);
            }
            child = next;
        }
    } else if (std.ascii.eqlIgnoreCase(position_str, "beforebegin")) {
        const parent = z.parentNode(target_node) orelse {
            return ctx.throwTypeError("insertAdjacentHTML beforebegin: no parent node");
        };
        _ = parent;
        var child = z.firstChild(temp_node);
        while (child) |c| {
            const next = z.nextSibling(c);
            z.insertBefore(target_node, c);
            child = next;
        }
    } else if (std.ascii.eqlIgnoreCase(position_str, "afterend")) {
        var insert_after = target_node;
        var child = z.firstChild(temp_node);
        while (child) |c| {
            const next = z.nextSibling(c);
            if (z.nextSibling(insert_after)) |sibling| {
                z.insertBefore(sibling, c);
            } else if (z.parentNode(insert_after)) |parent| {
                z.appendChild(parent, c);
            }
            insert_after = c;
            child = next;
        }
    } else {
        return ctx.throwTypeError("Invalid position for insertAdjacentHTML");
    }

    return w.UNDEFINED;
}

/// Element.insertAdjacentElement(position, newElement) - inserts element relative to target
fn js_insertAdjacentElement(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 2) return ctx.throwTypeError("insertAdjacentElement requires 2 arguments");

    const el = unwrapElement(ctx, this_val, "insertAdjacentElement called on non-Element") orelse return w.EXCEPTION;

    const position_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(position_str);

    // Unwrap second argument as HTMLElement (also supports Canvas via backing element)
    const new_el: *z.HTMLElement = blk: {
        if (ctx.getOpaque(argv[1], rc.classes.html_element)) |p|
            break :blk @ptrCast(@alignCast(p));
        if (ctx.getOpaque(argv[1], rc.classes.canvas)) |p| {
            const canvas: *js_canvas.Canvas = @ptrCast(@alignCast(p));
            if (canvas.element) |backing| break :blk backing;
        }
        return ctx.throwTypeError("Second argument must be an Element");
    };

    z.insertAdjacentElement(el, position_str, new_el) catch |err| {
        return switch (err) {
            z.Err.InvalidPosition => ctx.throwTypeError("Invalid position for insertAdjacentElement"),
            else => ctx.throwTypeError("insertAdjacentElement failed"),
        };
    };

    return ctx.dupValue(argv[1]);
}

/// setAttribute with sanitization gate.
/// When sanitize_enabled: blocks event handlers (on*), sanitizes style attr CSS values.
/// Overrides the generated js_setAttribute on the HTMLElement prototype.
fn js_setAttribute_sanitized(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 2) return ctx.throwTypeError("setAttribute requires 2 arguments");

    const el = unwrapElement(ctx, this_val, "setAttribute called on non-Element") orelse return w.EXCEPTION;

    const attr_name = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(attr_name);
    const attr_value = ctx.toZString(argv[1]) catch return w.EXCEPTION;
    defer ctx.freeZString(attr_value);

    if (rc.sanitize_enabled) {
        // Block event handler attributes (onclick, onerror, etc.)
        if (attr_name.len >= 2 and attr_name[0] == 'o' and attr_name[1] == 'n') {
            return w.UNDEFINED; // Silently ignore
        }

        // Sanitize style attribute CSS values
        if (std.ascii.eqlIgnoreCase(attr_name, "style")) {
            const css_san = @import("modules/sanitizer_css.zig");
            var sanitizer = css_san.CssSanitizer.init(rc.allocator, .{
                .sanitize_inline_styles = true,
                .sanitize_style_elements = true,
                .sanitize_style_attributes = true,
                .allow_css_urls = !rc.sanitize_options.strict_uri,
            }) catch {
                return ctx.throwTypeError("Failed to initialize CSS sanitizer");
            };
            defer sanitizer.deinit();

            const clean = sanitizer.sanitizeStyleString(attr_value) catch {
                return ctx.throwTypeError("CSS sanitization failed");
            };
            if (clean.len == 0) {
                z.removeAttribute(el, "style") catch {};
                return w.UNDEFINED;
            }
            z.setAttribute(el, attr_name, clean) catch |err| {
                std.debug.print("setAttribute style error: {}\n", .{err});
                return ctx.throwTypeError("Native Zig Error");
            };
            // Re-parse the inline style so serializeElementStyles() sees the update.
            z.parseElementStyle(el) catch {};
            return w.UNDEFINED;
        }
    }

    // Keep the style cascade in sync for non-sanitized setAttribute("style", ...) calls too.
    if (std.ascii.eqlIgnoreCase(attr_name, "style")) {
        z.setAttribute(el, attr_name, attr_value) catch |err| {
            std.debug.print("setAttribute style (unsanitized) error: {}\n", .{err});
            return ctx.throwTypeError("Native Zig Error");
        };
        z.parseElementStyle(el) catch {};
        return w.UNDEFINED;
    }

    z.setAttribute(el, attr_name, attr_value) catch |err| {
        std.debug.print("setAttribute error: {}\n", .{err});
        return ctx.throwTypeError("Native Zig Error");
    };
    return w.UNDEFINED;
}

// content getter for <template> elements only (installed per-instance in wrapNode, no tag check needed)
fn js_get_template_content(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    _ = argv;
    const ctx = w.Context.from(ctx_ptr);
    const el = unwrapElement(ctx, this_val, "Object is not an HTMLElement") orelse return w.EXCEPTION;
    const result = z.getTemplateContentAsNode(el);
    if (result) |n| return DOMBridge.wrapNode(ctx, n) catch w.EXCEPTION;
    return w.NULL;
}

// Manual innerHTML getter
fn js_get_innerHTML(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    _ = argv;
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const el = unwrapElement(ctx, this_val, "Object is not an HTMLElement") orelse return w.EXCEPTION;
    const result = z.innerHTML(rc.allocator, el) catch return w.EXCEPTION;
    defer rc.allocator.free(result);
    return ctx.newString(result);
}

// Manual innerHTML setter — sanitizes when sanitize_enabled + attaches styles
fn js_set_innerHTML(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const el = unwrapElement(ctx, this_val, "Setter called on object that is not an HTMLElement") orelse return w.EXCEPTION;
    const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(val_str);

    if (rc.sanitize_enabled) {
        const sanitizer_mod = @import("modules/sanitizer.zig");
        const strict_options = strictSanitizeOptions(rc);
        var san = sanitizer_mod.Sanitizer.init(rc.allocator, strict_options) catch |err| {
            std.debug.print("JS Setter Error (innerHTML sanitizer init): {}\n", .{err});
            return ctx.throwTypeError("Failed to initialize sanitizer");
        };
        defer san.deinit();

        san.setInnerHTMLSanitized(el, val_str) catch |err| {
            std.debug.print("JS Setter Error (innerHTML sanitized): {}\n", .{err});
            return ctx.throwTypeError("Native Zig Error in Setter");
        };
    } else {
        z.setInnerHTML(el, val_str) catch |err| {
            std.debug.print("JS Setter Error (innerHTML): {}\n", .{err});
            return ctx.throwTypeError("Native Zig Error in Setter");
        };
    }

    // Always attach styles to newly inserted nodes
    const node = z.elementToNode(el);
    z.attachSubtreeStyles(node) catch |err| {
        std.debug.print("JS Setter Warning (innerHTML styles): {}\n", .{err});
    };

    return w.UNDEFINED;
}

// Manual outerHTML getter
fn js_get_outerHTML(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    _ = argv;
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const el = unwrapElement(ctx, this_val, "Object is not an HTMLElement") orelse return w.EXCEPTION;
    const result = z.outerHTML(rc.allocator, el) catch return w.EXCEPTION;
    defer rc.allocator.free(result);
    return ctx.newString(result);
}

// Manual outerHTML setter — sanitizes when sanitize_enabled + attaches styles
fn js_set_outerHTML(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const el = unwrapElement(ctx, this_val, "Setter called on object that is not an HTMLElement") orelse return w.EXCEPTION;
    const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(val_str);

    // Get parent before replacement (for style attachment)
    const parent_node = z.parentNode(z.elementToNode(el));

    if (rc.sanitize_enabled) {
        const sanitizer_mod = @import("modules/sanitizer.zig");
        const strict_options = strictSanitizeOptions(rc);
        var san = sanitizer_mod.Sanitizer.init(rc.allocator, strict_options) catch |err| {
            std.debug.print("JS Setter Error (outerHTML sanitizer init): {}\n", .{err});
            return ctx.throwTypeError("Failed to initialize sanitizer");
        };
        defer san.deinit();

        const temp_doc = san.parseHTML(val_str) catch |err| {
            std.debug.print("JS Setter Error (outerHTML parse/sanitize): {}\n", .{err});
            return ctx.throwTypeError("Failed to parse HTML");
        };
        defer z.destroyDocument(temp_doc);

        const temp_body = z.bodyElement(temp_doc) orelse return ctx.throwTypeError("No body in parsed HTML");

        const clean_html = z.innerHTML(rc.allocator, temp_body) catch |err| {
            std.debug.print("JS Setter Error (outerHTML serialize): {}\n", .{err});
            return ctx.throwTypeError("Failed to serialize HTML");
        };
        defer rc.allocator.free(clean_html);

        z.setOuterHTMLSimple(el, clean_html) catch |err| {
            std.debug.print("JS Setter Error (outerHTML): {}\n", .{err});
            return ctx.throwTypeError("Native Zig Error in Setter");
        };
    } else {
        z.setOuterHTMLSimple(el, val_str) catch |err| {
            std.debug.print("JS Setter Error (outerHTML): {}\n", .{err});
            return ctx.throwTypeError("Native Zig Error in Setter");
        };
    }

    // Attach styles to newly inserted content
    if (parent_node) |parent| {
        z.attachSubtreeStyles(parent) catch |err| {
            std.debug.print("JS Setter Warning (outerHTML styles): {}\n", .{err});
        };
    }

    return w.UNDEFINED;
}

fn js_replaceWith(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const child = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for replaceWith");
    const parent = z.parentNode(child) orelse return w.UNDEFINED;
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);

    // Insert fragment children before the old child, then remove old child
    var frag_child = z.firstChild(frag);
    while (frag_child) |fc| {
        const next = z.nextSibling(fc);
        z.removeNode(fc);
        z.insertBefore(child, fc);
        frag_child = next;
    }
    z.removeNode(child);
    return w.UNDEFINED;
}

// spces: clear all existing children, then append the new ones.
fn js_replaceChildren(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context.from(ctx_ptr);
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for replaceChildren");

    // Remove all existing children
    while (z.firstChild(parent)) |child| {
        z.removeNode(child);
    }

    //  Append new children (if any)
    if (argc > 0) {
        const doc = z.ownerDocument(parent);
        const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
        defer z.destroyNode(frag);

        var frag_child = z.firstChild(frag);
        while (frag_child) |fc| {
            const next = z.nextSibling(fc);
            z.removeNode(fc);
            z.appendChild(parent, fc);
            frag_child = next;
        }
    }
    return w.UNDEFINED;
}

// --- Helpers ---

/// Unwrap an HTMLElement from a JS this_val. Returns null with a TypeError if not an element.
fn unwrapElement(ctx: w.Context, this_val: zqjs.Value, err_msg: [*:0]const u8) ?*z.HTMLElement {
    const rc = RuntimeContext.get(ctx);
    return ctx.getOpaqueAs(z.HTMLElement, this_val, rc.classes.html_element) orelse {
        _ = ctx.throwTypeError(err_msg);
        return null;
    };
}

/// Build strict sanitize options from RuntimeContext (DRY helper for innerHTML/outerHTML/insertAdjacentHTML)
fn strictSanitizeOptions(rc: *RuntimeContext) z.SanitizeOptions {
    return .{
        .remove_scripts = true,
        .remove_styles = false,
        .sanitize_css = true,
        .remove_comments = rc.sanitize_options.remove_comments,
        .strict_uri = rc.sanitize_options.strict_uri,
        .sanitize_dom_clobbering = true,
        .allow_custom_elements = rc.sanitize_options.allow_custom_elements,
        .allow_embeds = false,
        .allow_iframes = false,
        .frameworks = rc.sanitize_options.frameworks,
    };
}

/// Parse a pixel dimension from an element: checks width/height attribute first,
/// then falls back to parsing the style attribute (e.g. "width: 800px").
fn parseDimension(element: *z.HTMLElement, attr_name: []const u8, style_prop: []const u8) ?i32 {
    // 1. Check HTML attribute: <div width="800">
    if (z.getAttribute_zc(element, attr_name)) |val| {
        if (std.fmt.parseInt(i32, val, 10)) |v| return v else |_| {}
    }
    // 2. Parse from style attribute: style="width: 800px; ..."
    if (z.getAttribute_zc(element, "style")) |style| {
        var it = std.mem.splitScalar(u8, style, ';');
        while (it.next()) |decl| {
            const trimmed = std.mem.trim(u8, decl, " \t\r\n");
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                const prop = std.mem.trim(u8, trimmed[0..colon], " \t");
                if (std.ascii.eqlIgnoreCase(prop, style_prop)) {
                    const raw_val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                    // Strip "px" suffix if present
                    const num_str = if (std.mem.endsWith(u8, raw_val, "px"))
                        raw_val[0 .. raw_val.len - 2]
                    else
                        raw_val;
                    if (std.fmt.parseInt(i32, std.mem.trim(u8, num_str, " "), 10)) |v| return v else |_| {}
                }
            }
        }
    }
    return null;
}

/// clientWidth getter — reads from attribute/style, fallback 0
fn js_HTMLElement_clientWidth(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        if (parseDimension(el, "width", "width")) |v| return ctx.newInt32(v);
    }
    return ctx.newInt32(600);
}

/// clientHeight getter — reads from attribute/style, fallback 0
fn js_HTMLElement_clientHeight(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        if (parseDimension(el, "height", "height")) |v| return ctx.newInt32(v);
    }
    return ctx.newInt32(800);
}

/// element.attributes getter — returns a NamedNodeMap-like array of {name, value} Attr objects.
/// HTMX iterates this with `elt.attributes[i].name` to find hx-on:* handlers.
fn js_get_attributes(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const el = ctx.getOpaqueAs(z.HTMLElement, this_val, rc.classes.html_element) orelse {
        return ctx.throwTypeError("attributes called on non-Element");
    };

    // Walk lexbor's attribute linked list
    var attr = z.firstAttribute(el);
    const arr = ctx.newArray();
    var i: u32 = 0;
    while (attr) |a| : (i += 1) {
        const name_zc = z.getAttributeName_zc(a);
        const value_zc = z.getAttributeValue_zc(a);

        const obj = ctx.newObject();
        ctx.setPropertyStr(obj, "name", ctx.newString(name_zc)) catch {};
        ctx.setPropertyStr(obj, "value", ctx.newString(value_zc)) catch {};

        ctx.setPropertyUint32(arr, i, obj) catch {};
        attr = z.nextAttribute(a);
    }
    ctx.setPropertyStr(arr, "length", ctx.newInt32(@intCast(i))) catch {};
    return arr;
}

/// getBoundingClientRect() — returns rect based on element dimensions (headless: no layout)
fn js_HTMLElement_getBoundingClientRect(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    var cw: i32 = 0;
    var ch: i32 = 0;

    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        cw = parseDimension(el, "width", "width") orelse 0;
        ch = parseDimension(el, "height", "height") orelse 0;
    }

    const obj = ctx.newObject();
    ctx.setPropertyStr(obj, "x", ctx.newInt32(0)) catch {};
    ctx.setPropertyStr(obj, "y", ctx.newInt32(0)) catch {};
    ctx.setPropertyStr(obj, "top", ctx.newInt32(0)) catch {};
    ctx.setPropertyStr(obj, "left", ctx.newInt32(0)) catch {};
    ctx.setPropertyStr(obj, "width", ctx.newInt32(cw)) catch {};
    ctx.setPropertyStr(obj, "height", ctx.newInt32(ch)) catch {};
    ctx.setPropertyStr(obj, "bottom", ctx.newInt32(ch)) catch {};
    ctx.setPropertyStr(obj, "right", ctx.newInt32(cw)) catch {};

    return obj;
}

/// Generic reflected attribute getter — returns getAttribute(attr) or ""
fn reflectedAttrGetter(ctx: w.Context, this_val: z.qjs.JSValue, comptime attr: []const u8) z.qjs.JSValue {
    const rc = RuntimeContext.get(ctx);
    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        if (z.getAttribute_zc(el, attr)) |val| return ctx.newString(val);
    }
    return ctx.newString("");
}

/// Generic reflected attribute setter — calls setAttribute(attr, value)
fn reflectedAttrSetter(ctx: w.Context, this_val: z.qjs.JSValue, argv: [*c]w.Value, comptime attr: []const u8) z.qjs.JSValue {
    const rc = RuntimeContext.get(ctx);
    if (ctx.getOpaque(this_val, rc.classes.html_element)) |ptr| {
        const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
        const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        defer ctx.freeZString(val_str);
        z.setAttribute(el, attr, val_str) catch {};
    }
    return w.UNDEFINED;
}

fn js_HTMLElement_get_src(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    return reflectedAttrGetter(.{ .ptr = ctx_ptr }, this_val, "src");
}
fn js_HTMLElement_set_src(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    return reflectedAttrSetter(.{ .ptr = ctx_ptr }, this_val, argv, "src");
}
fn js_HTMLElement_get_href(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    return reflectedAttrGetter(.{ .ptr = ctx_ptr }, this_val, "href");
}
fn js_HTMLElement_set_href(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    return reflectedAttrSetter(.{ .ptr = ctx_ptr }, this_val, argv, "href");
}

// ── HTMLFormControl .value accessor ──────────────────────────────────────────
// textarea.value  → text content (read/write)
// select.value    → first selected option's value attr (read), set selected (write)
// input/button    → reflected "value" attribute

fn getSelectValue(el: *z.HTMLElement) ?[]const u8 {
    var first: ?[]const u8 = null;
    var node = z.firstChild(z.elementToNode(el));
    while (node) |n| {
        if (z.nodeToElement(n)) |opt| {
            if (std.ascii.eqlIgnoreCase(z.tagName_zc(opt), "option")) {
                const v = z.getAttribute_zc(opt, "value") orelse z.textContent_zc(z.elementToNode(opt));
                if (first == null) first = v;
                if (z.hasAttribute(opt, "selected")) return v;
            }
        }
        node = z.nextSibling(n);
    }
    return first;
}

fn js_get_value(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const ptr = ctx.getOpaque(this_val, rc.classes.html_element) orelse return ctx.newString("");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
    const tag = z.tagName_zc(el);
    if (std.ascii.eqlIgnoreCase(tag, "textarea")) {
        return ctx.newString(z.textContent_zc(z.elementToNode(el)));
    }
    if (std.ascii.eqlIgnoreCase(tag, "select")) {
        return ctx.newString(getSelectValue(el) orelse "");
    }
    return ctx.newString(z.getAttribute_zc(el, "value") orelse "");
}

fn js_set_value(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, _: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const ptr = ctx.getOpaque(this_val, rc.classes.html_element) orelse return w.UNDEFINED;
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
    const val = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(val);
    const tag = z.tagName_zc(el);
    if (std.ascii.eqlIgnoreCase(tag, "textarea")) {
        z.setTextContent(rc.allocator, z.elementToNode(el), val) catch {};
    } else {
        z.setAttribute(el, "value", val) catch {};
    }
    return w.UNDEFINED;
}

// ── HTMLFormElement named control access ──────────────────────────────────────
// Implements form["controlName"] → HTMLElement via exotic get_own_property on
// the shared html_element class.  Returning 0 (not-found) for non-FORM elements
// leaves the normal prototype chain intact — getAttribute, querySelector, etc.
// all continue to resolve normally for every element type.

fn findNamedControl(start: ?*z.DomNode, name: []const u8) ?*z.HTMLElement {
    var node = start;
    while (node) |n| {
        if (z.nodeToElement(n)) |el| {
            const tag = z.tagName_zc(el);
            const is_ctrl = std.ascii.eqlIgnoreCase(tag, "input") or
                std.ascii.eqlIgnoreCase(tag, "textarea") or
                std.ascii.eqlIgnoreCase(tag, "select") or
                std.ascii.eqlIgnoreCase(tag, "button") or
                std.ascii.eqlIgnoreCase(tag, "output");
            if (is_ctrl) {
                if (z.getAttribute_zc(el, "name")) |attr| {
                    if (std.mem.eql(u8, attr, name)) return el;
                }
            }
            if (findNamedControl(z.firstChild(n), name)) |found| return found;
        }
        node = z.nextSibling(n);
    }
    return null;
}

fn formGetOwnProperty(
    ctx_ptr: ?*z.qjs.JSContext,
    desc: ?*z.qjs.JSPropertyDescriptor,
    obj: z.qjs.JSValue,
    prop: z.qjs.JSAtom,
) callconv(.c) c_int {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const ptr = ctx.getOpaque(obj, rc.classes.html_element) orelse return 0;
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
    if (!std.ascii.eqlIgnoreCase(z.tagName_zc(el), "form")) return 0;

    var prop_len: usize = 0;
    const prop_cstr = z.qjs.JS_AtomToCStringLen(ctx_ptr, &prop_len, prop);
    if (prop_cstr == null) return 0;
    defer z.qjs.JS_FreeCString(ctx_ptr, prop_cstr);
    const prop_name = prop_cstr[0..prop_len];
    if (prop_name.len == 0) return 0;

    const found = findNamedControl(z.firstChild(z.elementToNode(el)), prop_name) orelse return 0;

    if (desc) |d| {
        d.value = DOMBridge.wrapElement(ctx, found) catch return -1;
        d.getter = w.UNDEFINED;
        d.setter = w.UNDEFINED;
        d.flags = z.qjs.JS_PROP_ENUMERABLE | z.qjs.JS_PROP_WRITABLE | z.qjs.JS_PROP_CONFIGURABLE;
    }
    return 1;
}

fn formHasProperty(
    ctx_ptr: ?*z.qjs.JSContext,
    obj: z.qjs.JSValue,
    prop: z.qjs.JSAtom,
) callconv(.c) c_int {
    // IMPORTANT: JS_HasProperty returns the exotic handler's result immediately, without
    // searching the prototype chain. We must do the prototype-chain fallback ourselves.
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const ptr = ctx.getOpaque(obj, rc.classes.html_element) orelse return protoHasProperty(ctx_ptr, obj, prop);
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

    if (std.ascii.eqlIgnoreCase(z.tagName_zc(el), "form")) {
        var prop_len: usize = 0;
        const prop_cstr = z.qjs.JS_AtomToCStringLen(ctx_ptr, &prop_len, prop);
        if (prop_cstr != null) {
            defer z.qjs.JS_FreeCString(ctx_ptr, prop_cstr);
            const prop_name = prop_cstr[0..prop_len];
            if (prop_name.len > 0 and findNamedControl(z.firstChild(z.elementToNode(el)), prop_name) != null)
                return 1;
        }
    }

    return protoHasProperty(ctx_ptr, obj, prop);
}

// Fall back to normal prototype-chain lookup when the exotic handler doesn't own the property.
// We call JS_HasProperty on the object's __proto__ so we skip the exotic handler on `obj`
// itself (which would cause infinite recursion) and let QuickJS walk the rest of the chain.
fn protoHasProperty(ctx_ptr: ?*z.qjs.JSContext, obj: z.qjs.JSValue, prop: z.qjs.JSAtom) c_int {
    const proto = z.qjs.JS_GetPrototype(ctx_ptr, obj);
    defer z.qjs.JS_FreeValue(ctx_ptr, proto);
    if (z.qjs.JS_IsNull(proto) or z.qjs.JS_IsUndefined(proto)) return 0;
    return z.qjs.JS_HasProperty(ctx_ptr, proto, prop);
}

const form_exotic_methods = z.qjs.JSClassExoticMethods{
    .get_own_property = formGetOwnProperty,
    .get_own_property_names = null,
    .delete_property = null,
    .define_own_property = null,
    .has_property = formHasProperty,
    .get_property = null,
    .set_property = null,
};

fn js_localStorage_setItem(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 2) return w.UNDEFINED;

    const key = ctx.toZString(argv[0]) catch return w.UNDEFINED;
    const val = ctx.toZString(argv[1]) catch {
        ctx.freeZString(key);
        return w.UNDEFINED;
    };

    // Duplicate strings so they live in the hash map
    const key_dup = rc.allocator.dupe(u8, key) catch return w.UNDEFINED;
    const val_dup = rc.allocator.dupe(u8, val) catch return w.UNDEFINED;

    ctx.freeZString(key);
    ctx.freeZString(val);

    // Free old value if overwriting
    if (rc.local_storage.fetchPut(key_dup, val_dup) catch null) |kv| {
        rc.allocator.free(kv.key);
        rc.allocator.free(kv.value);
    }

    return w.UNDEFINED;
}

fn js_localStorage_getItem(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.NULL;

    const key = ctx.toZString(argv[0]) catch return w.NULL;
    defer ctx.freeZString(key);

    if (rc.local_storage.get(key)) |val| {
        return ctx.newString(val);
    }
    return w.NULL;
}

fn js_localStorage_removeItem(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 1) return w.UNDEFINED;

    const key = ctx.toZString(argv[0]) catch return w.UNDEFINED;
    defer ctx.freeZString(key);

    if (rc.local_storage.fetchRemove(key)) |kv| {
        rc.allocator.free(kv.key);
        rc.allocator.free(kv.value);
    }
    return w.UNDEFINED;
}

fn js_localStorage_clear(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, _: c_int, _: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const rc = RuntimeContext.get(w.Context.from(ctx_ptr));

    var it = rc.local_storage.iterator();
    while (it.next()) |entry| {
        rc.allocator.free(entry.key_ptr.*);
        rc.allocator.free(entry.value_ptr.*);
    }
    rc.local_storage.clearRetainingCapacity();

    return w.UNDEFINED;
}

fn js_crypto_getRandomValues(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    if (argc < 1) return w.UNDEFINED;

    const ctx = w.Context.from(ctx_ptr);

    // Extract the raw memory pointer from the JS Uint8Array/TypedArray
    const typed_arr = ctx.getTypedArrayBuffer(argv[0]) catch return w.UNDEFINED;
    defer ctx.freeValue(typed_arr.buffer);

    const full_buffer_slice = ctx.getArrayBuffer(typed_arr.buffer) catch return w.UNDEFINED;

    const target_slice = full_buffer_slice[typed_arr.byte_offset .. typed_arr.byte_offset + typed_arr.byte_length];
    // fill the range
    std.crypto.random.bytes(target_slice);

    // Return the same array back to JS
    return ctx.dupValue(argv[0]);
}

/// __native_evalModule(code, filename) — eval a string as an ES module (JS_EVAL_TYPE_MODULE).
/// Used by zxp.runScripts() to handle <script type="module"> tags.
/// The module loader (js_security.zig) resolves 'import' specifiers — including HTTPS URLs.
fn js_native_evalModule(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    if (argc < 2) return w.UNDEFINED;

    var code_len: usize = 0;
    const code_ptr = z.qjs.JS_ToCStringLen(ctx_ptr, &code_len, argv[0]);
    if (code_ptr == null) return w.EXCEPTION;
    defer z.qjs.JS_FreeCString(ctx_ptr, code_ptr);

    const filename_ptr = z.qjs.JS_ToCString(ctx_ptr, argv[1]);
    if (filename_ptr == null) return w.EXCEPTION;
    defer z.qjs.JS_FreeCString(ctx_ptr, filename_ptr);

    // JS_ToCStringLen guarantees null termination: code_ptr[code_len] == '\0'
    const val = z.qjs.JS_Eval(ctx_ptr, code_ptr, code_len, filename_ptr, z.qjs.JS_EVAL_TYPE_MODULE);
    if (z.qjs.JS_IsException(val)) {
        const ctx = w.Context.from(ctx_ptr);
        _ = ctx.checkAndPrintException();
    }
    return val;
}

/// __native_paintSVG(svgBytes) — rasterize raw SVG bytes → { data: ArrayBuffer, width, height }
/// Input: Uint8Array or ArrayBuffer containing SVG source text.
/// ThorVG reads the viewBox and scales so the longest side ≥ 800px.
/// Returns the same { data, width, height } shape as paintDOM / paintElement.
fn js_paintSVG(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    if (argc < 1) return w.UNDEFINED;
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    // Accept: string | ArrayBuffer | TypedArray
    var svg_slice: []const u8 = undefined;
    var maybe_owned_buf: ?w.Value = null;
    var maybe_cstr: ?[*:0]const u8 = null;
    defer if (maybe_owned_buf) |v| ctx.freeValue(v);
    defer if (maybe_cstr) |s| ctx.freeCString(s);

    if (ctx.isString(argv[0])) {
        const s = ctx.toCString(argv[0]) catch return w.UNDEFINED;
        maybe_cstr = s;
        svg_slice = std.mem.span(s);
    } else if (ctx.isArrayBuffer(argv[0])) {
        svg_slice = ctx.getArrayBuffer(argv[0]) catch return w.UNDEFINED;
    } else {
        const ta = ctx.getTypedArrayBuffer(argv[0]) catch return w.UNDEFINED;
        maybe_owned_buf = ta.buffer;
        const full = ctx.getArrayBuffer(ta.buffer) catch return w.UNDEFINED;
        svg_slice = full[ta.byte_offset .. ta.byte_offset + ta.byte_length];
    }

    // ThorVG doesn't recognise the CSS keyword "transparent" — it falls back to the
    // SVG default fill (black). Replace it only inside attribute values ("transparent")
    // and CSS style values (:transparent) so text content is not affected.
    const needs_fixup = std.mem.indexOf(u8, svg_slice, "transparent") != null;
    const svg_to_render: []const u8 = if (needs_fixup) blk: {
        var buf = std.ArrayList(u8).empty;
        buf.ensureTotalCapacity(rc.allocator, svg_slice.len) catch break :blk svg_slice;
        var rest = svg_slice;
        while (std.mem.indexOf(u8, rest, "transparent")) |pos| {
            // Check that it appears inside a quoted attribute value or after a CSS colon
            const before = if (pos > 0) rest[pos - 1] else 0;
            const after_end = pos + "transparent".len;
            const after = if (after_end < rest.len) rest[after_end] else 0;
            const in_attr = (before == '"' or before == '\'') and (after == '"' or after == '\'');
            const in_css = (before == ':' or before == ' ') and (after == ';' or after == '"' or after == '\'' or after == ' ');
            buf.appendSlice(rc.allocator, rest[0..pos]) catch break :blk svg_slice;
            if (in_attr or in_css) {
                buf.appendSlice(rc.allocator, "none") catch break :blk svg_slice;
            } else {
                buf.appendSlice(rc.allocator, "transparent") catch break :blk svg_slice;
            }
            rest = rest[after_end..];
        }
        buf.appendSlice(rc.allocator, rest) catch break :blk svg_slice;
        break :blk buf.toOwnedSlice(rc.allocator) catch svg_slice;
    } else svg_slice;
    defer if (needs_fixup and svg_to_render.ptr != svg_slice.ptr) rc.allocator.free(svg_to_render);

    const img = js_image.Image.initFromSvg(rc.allocator, svg_to_render, 0) catch |err| {
        std.debug.print("[paintSVG] initFromSvg failed: {}\n", .{err});
        return w.UNDEFINED;
    };
    defer img.deinit();

    const pixel_bytes: []const u8 = img.pixels[0 .. @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4];
    const result = ctx.newObject();
    ctx.setPropertyStr(result, "data", ctx.newArrayBufferCopy(pixel_bytes)) catch return w.UNDEFINED;
    ctx.setPropertyStr(result, "width", ctx.newFloat64(@floatFromInt(img.width))) catch return w.UNDEFINED;
    ctx.setPropertyStr(result, "height", ctx.newFloat64(@floatFromInt(img.height))) catch return w.UNDEFINED;
    return result;
}

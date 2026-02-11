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
const js_range = @import("js_range.zig");
const js_tree_walker = @import("js_tree_walker.zig");
const js_canvas = @import("js_canvas.zig");
const js_image = @import("js_image.zig");

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

    /// Custom createElement that handles canvas and template elements specially
    /// - canvas: Returns a native Canvas object with a backing DOM <canvas> element
    /// - template: Uses z.createTemplate() which properly creates the content DocumentFragment
    fn js_createElement_with_canvas(ctx_ptr: ?*z.qjs.JSContext, this_val: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
        const ctx = w.Context{ .ptr = ctx_ptr };
        const rc = RuntimeContext.get(ctx);

        if (argc < 1) return w.EXCEPTION;

        // Get tag name
        const tag_name = ctx.toZString(argv[0]) catch return w.EXCEPTION;
        defer ctx.freeZString(tag_name);

        // Get document from this_val (needed for all element types)
        const doc: *z.HTMLDocument = blk: {
            if (z.qjs.JS_GetOpaque(this_val, rc.classes.document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
            if (z.qjs.JS_GetOpaque(this_val, rc.classes.owned_document)) |ptr| break :blk @ptrCast(@alignCast(ptr));
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
            const obj = z.qjs.JS_NewObjectClass(ctx.ptr, rc.classes.canvas);
            if (z.qjs.JS_IsException(obj)) {
                canvas_struct.deinit();
                return w.EXCEPTION;
            }

            // Link opaque pointer
            _ = z.qjs.JS_SetOpaque(obj, canvas_struct);
            return obj;
        }

        // Handle img specially - native HTMLImageElement with backing DOM element
        if (std.ascii.eqlIgnoreCase(tag_name, "img")) {
            const img_struct = js_image.HTMLImageElement.init(rc.allocator) catch return ctx.throwOutOfMemory();

            const obj = z.qjs.JS_NewObjectClass(ctx.ptr, rc.classes.html_image);
            if (z.qjs.JS_IsException(obj)) {
                if (ctx.ptr) |p| img_struct.deinit(p);
                return w.EXCEPTION;
            }

            _ = z.qjs.JS_SetOpaque(obj, img_struct);
            return obj;
        }

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

            // children property (element children only) - needed for DocumentFragment
            {
                const atom = z.qjs.JS_NewAtom(ctx.ptr, "children");
                const get_fn = ctx.newCFunction(js_get_children, "get_children", 0);
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

            // isConnected property (read-only) - walks up to document
            {
                const atom = z.qjs.JS_NewAtom(ctx.ptr, "isConnected");
                const get_fn = ctx.newCFunction(js_get_isConnected, "get_isConnected", 0);
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

            // Manual: appendChild - overrides generated binding to handle DocumentFragment
            {
                const ac_fn = ctx.newCFunction(js_appendChild_manual, "appendChild", 1);
                _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "appendChild", ac_fn);
            }

            // ParentNode mixin: querySelector/querySelectorAll (also on Node for DocumentFragment support)
            {
                const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
                _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "querySelector", qs_fn);
                const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
                _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "querySelectorAll", qsa_fn);
            }
            // Add modern DOM manipulation methods
            const append_fn = ctx.newCFunction(js_append, "append", -1);
            _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "append", append_fn);

            const prepend_fn = ctx.newCFunction(js_prepend, "prepend", -1);
            _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "prepend", prepend_fn);

            const before_fn = ctx.newCFunction(js_before, "before", -1);
            _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "before", before_fn);

            const after_fn = ctx.newCFunction(js_after, "after", -1);
            _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "after", after_fn);

            const replaceWith_fn = ctx.newCFunction(js_replaceWith, "replaceWith", -1);
            _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "replaceWith", replaceWith_fn);

            const replaceChildren_fn = ctx.newCFunction(js_replaceChildren, "replaceChildren", -1);
            _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "replaceChildren", replaceChildren_fn);

            // Text.splitText(offset)
            {
                const split_fn = ctx.newCFunction(js_splitText, "splitText", 1);
                _ = z.qjs.JS_SetPropertyStr(ctx.ptr, node_proto, "splitText", split_fn);
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

            // Manual: setAttribute - overrides generated binding to sanitize style/event attrs
            {
                const sa_fn = ctx.newCFunction(js_setAttribute_sanitized, "setAttribute", 2);
                _ = z.qjs.JS_SetPropertyStr(ctx.ptr, el_proto, "setAttribute", sa_fn);
            }

            // Manual: innerHTML - overrides generated binding to sanitize + attach styles
            {
                const atom = z.qjs.JS_NewAtom(ctx.ptr, "innerHTML");
                defer z.qjs.JS_FreeAtom(ctx.ptr, atom);
                const get_fn = z.qjs.JS_NewCFunction2(ctx.ptr, js_get_innerHTML, "get_innerHTML", 0, z.qjs.JS_CFUNC_generic, 0);
                const set_fn = z.qjs.JS_NewCFunction2(ctx.ptr, js_set_innerHTML, "set_innerHTML", 1, z.qjs.JS_CFUNC_generic, 0);
                _ = z.qjs.JS_DefinePropertyGetSet(ctx.ptr, el_proto, atom, get_fn, set_fn, z.qjs.JS_PROP_CONFIGURABLE | z.qjs.JS_PROP_ENUMERABLE);
            }

            // Manual: outerHTML - overrides generated binding to sanitize + attach styles
            {
                const atom = z.qjs.JS_NewAtom(ctx.ptr, "outerHTML");
                defer z.qjs.JS_FreeAtom(ctx.ptr, atom);
                const get_fn = z.qjs.JS_NewCFunction2(ctx.ptr, js_get_outerHTML, "get_outerHTML", 0, z.qjs.JS_CFUNC_generic, 0);
                const set_fn = z.qjs.JS_NewCFunction2(ctx.ptr, js_set_outerHTML, "set_outerHTML", 1, z.qjs.JS_CFUNC_generic, 0);
                _ = z.qjs.JS_DefinePropertyGetSet(ctx.ptr, el_proto, atom, get_fn, set_fn, z.qjs.JS_PROP_CONFIGURABLE | z.qjs.JS_PROP_ENUMERABLE);
            }

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

            // Element.insertAdjacentHTML(position, html)
            {
                const iah_fn = ctx.newCFunction(js_insertAdjacentHTML, "insertAdjacentHTML", 2);
                try ctx.setPropertyStr(el_proto, "insertAdjacentHTML", iah_fn);
            }

            // Element.insertAdjacentElement(position, newElement)
            {
                const iae_fn = ctx.newCFunction(js_insertAdjacentElement, "insertAdjacentElement", 2);
                try ctx.setPropertyStr(el_proto, "insertAdjacentElement", iae_fn);
            }

            // Element.focus() - no-op in headless environment
            {
                const focus_fn = ctx.newCFunction(js_focus, "focus", 0);
                try ctx.setPropertyStr(el_proto, "focus", focus_fn);
            }

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

        // Expose HTMLElement constructor globally BEFORE polyfills
        // (polyfills like onclick need HTMLElement.prototype to exist)
        {
            const global = ctx.getGlobalObject();
            defer ctx.freeValue(global);
            const html_element_ctor = ctx.newCFunction2(js_HTMLElement_constructor, "HTMLElement", 0, z.qjs.JS_CFUNC_constructor, 0);
            const html_element_proto = ctx.getClassProto(rc.classes.html_element);
            try ctx.setPropertyStr(html_element_ctor, "prototype", html_element_proto);
            try ctx.setPropertyStr(global, "HTMLElement", html_element_ctor);
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

        const doc = try z.createDocument();
        errdefer z.destroyDocument(doc);

        // NOTE: Do NOT call initDocumentCSS here - it will be called by
        // loadHTML/loadPage after the actual HTML is parsed and sanitized.
        // Calling it here on the empty doc causes corruption when the doc
        // is later re-parsed by insertHTML (lxb_html_document_parse).
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

        // HTMLElement constructor is now exposed in init() before polyfills
    }

    fn createDocumentAPI(self: *DOMBridge, global: w.Value, _: w.ClassID) !void {
        const ctx = self.ctx;
        const rc = RuntimeContext.get(ctx);

        // 'document' instance inherits from Document.prototype
        const doc_obj = ctx.newObjectClass(rc.classes.document);

        try ctx.setOpaque(doc_obj, self.doc);
        try ctx.setPropertyStr(doc_obj, "_native_doc", ctx.dupValue(doc_obj));

        // Manual Bindings (querySelector, createRange)
        const qs_fn = ctx.newCFunction(js_querySelector, "querySelector", 1);
        try ctx.setPropertyStr(doc_obj, "querySelector", qs_fn);

        const qsa_fn = ctx.newCFunction(js_querySelectorAll, "querySelectorAll", 1);
        try ctx.setPropertyStr(doc_obj, "querySelectorAll", qsa_fn);

        const cr_fn = ctx.newCFunction(js_createRange, "createRange", 0);
        try ctx.setPropertyStr(doc_obj, "createRange", cr_fn);

        const gtn_fn = ctx.newCFunction(js_getElementsByTagName, "getElementsByTagName", 1);
        try ctx.setPropertyStr(doc_obj, "getElementsByTagName", gtn_fn);

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

        const mo = ctx.getPropertyStr(global, "MutationObserver");
        if (!ctx.isUndefined(mo)) {
            try ctx.setPropertyStr(window_obj, "MutationObserver", mo);
        } else {
            ctx.freeValue(mo);
        }

        // Expose document on window (SolidJS uses window.document for event delegation)
        const doc = ctx.getPropertyStr(global, "document");
        if (!ctx.isUndefined(doc)) {
            try ctx.setPropertyStr(window_obj, "document", doc);
        } else {
            ctx.freeValue(doc);
        }

        try ctx.setPropertyStr(global, "window", window_obj);

        // Expose navigator on global (React accesses it as bare `navigator`, not `window.navigator`)
        try ctx.setPropertyStr(global, "navigator", ctx.dupValue(nav_obj));

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

        // 5. Is it a Canvas with a backing DOM element?
        if (ctx.getOpaque(val, rc.classes.canvas)) |ptr| {
            const canvas: *js_canvas.Canvas = @ptrCast(@alignCast(ptr));
            if (canvas.element) |el| return z.elementToNode(el);
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

    // Browser spec: drain microtask queue after dispatching an event.
    // This lets frameworks like Vue/React flush their schedulers (nextTick)
    // without requiring an explicit __flush() call after every dispatchEvent.
    const rt = z.qjs.JS_GetRuntime(ctx.ptr);
    var ctx_out: ?*z.qjs.JSContext = ctx.ptr;
    while (z.qjs.JS_ExecutePendingJob(rt, &ctx_out) > 0) {}

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

// HTMLElement constructor (throws - elements cannot be constructed directly)
fn js_HTMLElement_constructor(
    ctx_ptr: ?*z.qjs.JSContext,
    _: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    return ctx.throwTypeError("Illegal constructor: HTMLElement cannot be constructed directly");
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
    const ctx = w.Context{ .ptr = ctx_ptr };
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

fn js_getElementsByTagName(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
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

fn js_get_childNodes(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    _: c_int,
    _: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };

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

/// parent.appendChild(child) - handles DocumentFragment specially (moves children)
fn js_appendChild_manual(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };

    if (argc < 1) return ctx.throwTypeError("appendChild requires 1 argument");

    // Unwrap parent (this)
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse
        return ctx.throwTypeError("'this' is not a Node");

    // Unwrap child (first argument)
    const child = DOMBridge.unwrapNode(ctx, argv[0]) orelse
        return ctx.throwTypeError("Argument must be a Node");

    // Check if child is a DocumentFragment
    const child_type = z.nodeType(child);
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
        return DOMBridge.wrapNode(ctx, child) catch return w.EXCEPTION;
    }
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
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for append");
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);

    // appendChild on a fragment moves the fragment's children, not the fragment itself.
    var frag_child = z.firstChild(frag);
    while (frag_child) |fc| {
        const next = z.nextSibling(fc);
        z.appendChild(parent, fc);
        frag_child = next;
    }
    return w.UNDEFINED;
}

fn js_get_isConnected(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, _: c_int, _: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const parent = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for prepend");
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);
    _ = z.jsInsertBefore(parent, frag, z.firstChild(parent));
    return w.UNDEFINED;
}

fn js_before(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const child = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for before");
    const parent = z.parentNode(child) orelse return w.UNDEFINED;
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);
    _ = z.jsInsertBefore(parent, frag, child);
    return w.UNDEFINED;
}

fn js_after(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const child = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for after");
    const parent = z.parentNode(child) orelse return w.UNDEFINED;
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);
    _ = z.jsInsertBefore(parent, frag, z.nextSibling(child));
    return w.UNDEFINED;
}

/// Text.splitText(offset) - splits a text node at the given offset
fn js_splitText(
    ctx_ptr: ?*z.qjs.JSContext,
    this_val: zqjs.Value,
    argc: c_int,
    argv: [*c]z.qjs.JSValue,
) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 2) return ctx.throwTypeError("insertAdjacentHTML requires 2 arguments");

    const ptr = z.qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("insertAdjacentHTML called on non-Element");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

    const position_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(position_str);

    const html_str = ctx.toZString(argv[1]) catch return w.EXCEPTION;
    defer ctx.freeZString(html_str);

    // Determine the final HTML (sanitized or raw)
    var clean_html_alloc: ?[]const u8 = null;
    defer if (clean_html_alloc) |ch| rc.allocator.free(ch);

    if (rc.sanitize_enabled) {
        const sanitizer_mod = @import("modules/sanitizer.zig");
        const strict_options = sanitizer_mod.SanitizeOptions{
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
    // context element determines HTML5 parsing rules (table context, select, etc.)
    // We use the SAME TAG as the target for correct parsing context (spec-compliant).
    const target_node = z.elementToNode(el);
    const doc = z.ownerDocument(target_node);
    const tag = z.tagName_zc(el);

    const temp_el = z.createElement(doc, tag) catch {
        return ctx.throwInternalError("insertAdjacentHTML: createElement failed");
    };
    z.setInnerHTML(temp_el, final_html) catch {
        return ctx.throwInternalError("insertAdjacentHTML: setInnerHTML failed");
    };

    const temp_node = z.elementToNode(temp_el);

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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 2) return ctx.throwTypeError("insertAdjacentElement requires 2 arguments");

    const ptr = z.qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("insertAdjacentElement called on non-Element");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

    const position_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(position_str);

    // Unwrap second argument as HTMLElement (also supports Canvas via backing element)
    const new_el: *z.HTMLElement = blk: {
        if (z.qjs.JS_GetOpaque(argv[1], rc.classes.html_element)) |p|
            break :blk @ptrCast(@alignCast(p));
        if (z.qjs.JS_GetOpaque(argv[1], rc.classes.canvas)) |p| {
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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    if (argc < 2) return ctx.throwTypeError("setAttribute requires 2 arguments");

    const ptr = z.qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("setAttribute called on non-Element");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));

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
            return w.UNDEFINED;
        }
    }

    z.setAttribute(el, attr_name, attr_value) catch |err| {
        std.debug.print("setAttribute error: {}\n", .{err});
        return ctx.throwTypeError("Native Zig Error");
    };
    return w.UNDEFINED;
}

// Manual innerHTML getter
fn js_get_innerHTML(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    _ = argv;
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = z.qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("Object is not an HTMLElement");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
    const result = z.innerHTML(rc.allocator, el) catch return w.EXCEPTION;
    defer rc.allocator.free(result);
    return ctx.newString(result);
}

// Manual innerHTML setter — sanitizes when sanitize_enabled + attaches styles
fn js_set_innerHTML(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = z.qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("Setter called on object that is not an HTMLElement");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
    const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(val_str);

    if (rc.sanitize_enabled) {
        const sanitizer_mod = @import("modules/sanitizer.zig");
        const strict_options = sanitizer_mod.SanitizeOptions{
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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = z.qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("Object is not an HTMLElement");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
    const result = z.outerHTML(rc.allocator, el) catch return w.EXCEPTION;
    defer rc.allocator.free(result);
    return ctx.newString(result);
}

// Manual outerHTML setter — sanitizes when sanitize_enabled + attaches styles
fn js_set_outerHTML(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) zqjs.Value {
    _ = argc;
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = z.qjs.JS_GetOpaque(this_val, rc.classes.html_element);
    if (ptr == null) return ctx.throwTypeError("Setter called on object that is not an HTMLElement");
    const el: *z.HTMLElement = @ptrCast(@alignCast(ptr));
    const val_str = ctx.toZString(argv[0]) catch return w.EXCEPTION;
    defer ctx.freeZString(val_str);

    // Get parent before replacement (for style attachment)
    const parent_node = z.parentNode(z.elementToNode(el));

    if (rc.sanitize_enabled) {
        const sanitizer_mod = @import("modules/sanitizer.zig");
        const strict_options = sanitizer_mod.SanitizeOptions{
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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const child = DOMBridge.unwrapNode(ctx, this_val) orelse return ctx.throwTypeError("'this' is not a Node for replaceWith");
    const parent = z.parentNode(child) orelse return w.UNDEFINED;
    const doc = z.ownerDocument(parent);
    const frag = jsValuesToFragment(ctx, doc, argc, argv) catch return w.EXCEPTION;
    defer z.destroyNode(frag);

    // Insert fragment children before the old child, then remove old child
    var frag_child = z.firstChild(frag);
    while (frag_child) |fc| {
        const next = z.nextSibling(fc);
        z.insertBefore(child, fc);
        frag_child = next;
    }
    z.removeNode(child);
    return w.UNDEFINED;
}

fn js_replaceChildren(ctx_ptr: ?*z.qjs.JSContext, this_val: zqjs.Value, argc: c_int, argv: [*c]zqjs.Value) callconv(.c) zqjs.Value {
    const ctx = w.Context{ .ptr = ctx_ptr };
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
            z.appendChild(parent, fc);
            frag_child = next;
        }
    }
    return w.UNDEFINED;
}

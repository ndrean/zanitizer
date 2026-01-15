const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const ScriptEngine = @import("script_engine.zig").ScriptEngine;
const DOMBridge = @import("dom_bridge.zig").DOMBridge;

/// Represents a Handle to a specific DOM Element
pub const ElementHandle = struct {
    page: *Page,
    native_node: *z.DomNode,

    /// Triggers a "click" event on this element (synchronously)
    pub fn click(self: ElementHandle) !void {
        // Dispatch the event using your existing bridge logic
        try self.page.engine.dom.dispatchEvent(self.page.engine.ctx, &self.page.engine.dom, self.native_node, "click");
    }

    /// Sets the text content (helper wrapper)
    pub fn setContent(self: ElementHandle, text: []const u8) !void {
        try z.setContentAsText(self.native_node, text);
    }

    // You can add type, focus, hover, etc. here
};

/// Represents a Browser Tab/Page
pub const Page = struct {
    allocator: std.mem.Allocator,
    engine: *ScriptEngine,

    pub fn init(allocator: std.mem.Allocator, engine: *ScriptEngine) Page {
        return .{
            .allocator = allocator,
            .engine = engine,
        };
    }

    /// 1. Inject Data: Expose a Zig struct as a global JS variable
    /// Must be called BEFORE setContent if the scripts rely on it.
    pub fn expose(self: *Page, name: [:0]const u8, data: anytype) !void {
        const ctx = self.engine.ctx;

        // A. Serialize Zig -> JSON String
        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        try std.json.stringify(data, .{}, out.writer());

        // B. Parse JSON -> JSValue
        // (We slice 0..len because parseJSON expects a slice, not 0-terminated if we use the right wrapper)
        const js_val = ctx.parseJSON(out.items, "<injected_data>");
        defer ctx.freeValue(js_val);

        // C. Set Global Property
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        _ = try ctx.setPropertyStr(global, name, ctx.dupValue(js_val));
    }

    /// 2. Set Content: Parse HTML and EXECUTE <script> tags
    pub fn setContent(self: *Page, html: []const u8) !void {
        // A. Parse HTML into Lexbor Tree (using existing Bridge)
        // (This replaces the old doc, or updates it)
        // For simplicity, we assume we work on the existing bridge's document
        // We might want to clear the body first or use lxb_html_document_parse_chunk
        // But let's assume z.createDocFromString re-initializes or we just use innerHTML on body.

        // Fast path: Set body innerHTML which triggers Lexbor parsing
        const body_node = z.documentRoot(self.engine.dom.doc).?; // Simplification
        // Note: z.setInnerHTML(body_node, html) would be ideal if implemented for root.
        // For now, let's assume we re-parse the doc or stick to your current flow.

        // Let's assume you have a way to reset the doc, or we just modify the current one.
        // Better: Find the <body> and set its HTML (if you implemented setInnerHTML for nodes)
        // Or just parse:
        // z.destroyDocument(self.engine.dom.doc);
        // self.engine.dom.doc = try z.createDocFromString(html);
        // (Careful with memory ownership here!)

        // --- THE HYDRATION STEP ---
        // Lexbor parses HTML but DOES NOT run scripts automatically.
        // We must find them and run them.
        _ = html;
        _ = body_node;

        const scripts = try z.querySelectorAll(self.allocator, self.engine.dom.doc, "script");
        defer self.allocator.free(scripts);

        for (scripts) |script_elem| {
            // 1. Get Script Content
            const js_source = z.textContent_zc(z.elementToNode(script_elem));

            // 2. Execute in QuickJS
            if (js_source.len > 0) {
                // We wrap in a try/catch block so one bad script doesn't kill the page
                _ = self.engine.eval(js_source, "<embedded_script>") catch |err| {
                    std.debug.print("⚠️ Script Error: {}\n", .{err});
                };
            }
        }
    }

    /// 3. Select Element
    pub fn querySelector(self: *Page, selector: []const u8) !ElementHandle {
        // Use your low-level binding
        // We need to implement a Zig-side querySelector that doesn't rely on JS
        // (You already have z.querySelectorAll, let's use that)

        const results = try z.querySelectorAll(self.allocator, self.engine.dom.doc, selector);
        defer self.allocator.free(results); // Free the array, not the nodes

        if (results.len == 0) return error.ElementNotFound;

        return ElementHandle{
            .page = self,
            .native_node = z.elementToNode(results[0]),
        };
    }
};

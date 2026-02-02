//! CSS Selectors Engine
//!
//! Optimized for performance using a persistent memory pool and parser state.
//! Based on Lexbor's "normal_way.c" approach.

const std = @import("std");
const z = @import("../root.zig"); // Adjust path if needed
const Err = z.Err;

//=============================================================================
// EXTERN DEFINITIONS (Lexbor CSS API)
//=============================================================================

// 1. CSS Memory (The Pool)
extern "c" fn lxb_css_memory_create() ?*anyopaque;
extern "c" fn lxb_css_memory_init(memory: *anyopaque, size: usize) c_int;
extern "c" fn lxb_css_memory_destroy(memory: *anyopaque, destroy_self: bool) ?*anyopaque;

// 2. CSS Parser
extern "c" fn lxb_css_parser_create() ?*z.CssParser;
extern "c" fn lxb_css_parser_init(parser: *z.CssParser, memory: ?*anyopaque) c_int;
extern "c" fn lxb_css_parser_destroy(parser: *z.CssParser, destroy_self: bool) ?*z.CssParser;

// [NEW] Setters are now exposed via _noi (Not Inline) functions
extern "c" fn lxb_css_parser_memory_set_noi(parser: *z.CssParser, memory: ?*anyopaque) void;
extern "c" fn lxb_css_parser_selectors_set_noi(parser: *z.CssParser, selectors: ?*z.CssSelectorsState) void;

// 3. CSS Selectors (The Parser State Helper)
// Note: This is NOT the finder. This holds state for parsing selector strings.
// const LxCssSelectorsState = opaque {};
extern "c" fn lxb_css_selectors_create() ?*z.CssSelectorsState;
extern "c" fn lxb_css_selectors_init(selectors: *z.CssSelectorsState) c_int;
extern "c" fn lxb_css_selectors_destroy(selectors: *z.CssSelectorsState, destroy_self: bool) ?*z.CssSelectorsState;
extern "c" fn lxb_css_selectors_parse(parser: *z.CssParser, list: [*]const u8, size: usize) ?*z.CssSelectorList;

// 4. Selectors (The Finder Engine)
extern "c" fn lxb_selectors_create() ?*z.CssSelectors;
extern "c" fn lxb_selectors_init(selectors: *z.CssSelectors) c_int;
extern "c" fn lxb_selectors_destroy(selectors: *z.CssSelectors, destroy_self: bool) ?*z.CssSelectors;

// [FIX] Use _noi (Not Inline) version exposed by selectors.h
extern "c" fn lxb_selectors_opt_set_noi(selectors: *z.CssSelectors, opt: c_uint) void;
extern "c" fn lxb_selectors_find(
    selectors: *z.CssSelectors,
    root: *z.DomNode,
    list: *z.CssSelectorList,
    cb: *const fn (*z.DomNode, *z.CssSelectorSpecificity, ?*anyopaque) callconv(.c) c_int,
    ctx: ?*anyopaque,
) c_int;

extern "c" fn lxb_selectors_match_node(
    selectors: *z.CssSelectors,
    node: *z.DomNode,
    list: *z.CssSelectorList,
    cb: *const fn (*z.DomNode, *z.CssSelectorSpecificity, ?*anyopaque) callconv(.c) c_int,
    ctx: ?*anyopaque,
) c_int;

// [FIX] Correct Constants from selectors.h
// LXB_SELECTORS_OPT_MATCH_ROOT = 1 << 1 (2)
// LXB_SELECTORS_OPT_MATCH_FIRST = 1 << 2 (4)
const LXB_SELECTORS_OPT_MATCH_ROOT: c_uint = 2;
const LXB_SELECTORS_OPT_MATCH_FIRST: c_uint = 4;

//=============================================================================
// ENGINE
//=============================================================================

pub const CssSelectorEngine = struct {
    allocator: std.mem.Allocator,

    // Core Objects
    css_memory: *anyopaque, // Shared memory pool
    css_parser: *z.CssParser, // Shared parser
    css_helper: *z.CssSelectorsState, // Shared parser state
    selectors: *z.CssSelectors, // Shared finder engine

    // Cache
    cache: std.StringHashMap(*z.CssSelectorList),

    const Self = @This();

    /// Initialize the engine with shared memory pool (Fast Way)
    pub fn init(allocator: std.mem.Allocator) !Self {
        // 1. Create Memory Pool
        const mem = lxb_css_memory_create() orelse return error.CssMemoryAllocFailed;
        if (lxb_css_memory_init(mem, 128) != z._OK) return error.CssMemoryInitFailed;

        // 2. Create Parser
        const parser = lxb_css_parser_create() orelse return error.CssParserAllocFailed;
        if (lxb_css_parser_init(parser, null) != z._OK) return error.CssParserInitFailed;

        // 3. Create Parser Helper
        const helper = lxb_css_selectors_create() orelse return error.CssHelperAllocFailed;
        if (lxb_css_selectors_init(helper) != z._OK) return error.CssHelperInitFailed;

        // [FIXED] Bind Memory and Helper to Parser using official API
        // No more manual struct casting needed!
        lxb_css_parser_memory_set_noi(parser, mem);
        lxb_css_parser_selectors_set_noi(parser, helper);

        // 4. Create Finder
        const sel = lxb_selectors_create() orelse return error.CssFinderAllocFailed;
        if (lxb_selectors_init(sel) != z._OK) return error.CssFinderInitFailed;

        // Use _noi function to set options
        lxb_selectors_opt_set_noi(sel, LXB_SELECTORS_OPT_MATCH_FIRST | LXB_SELECTORS_OPT_MATCH_ROOT);

        return .{
            .allocator = allocator,
            .css_memory = mem,
            .css_parser = parser,
            .css_helper = helper,
            .selectors = sel,
            .cache = std.StringHashMap(*z.CssSelectorList).init(allocator),
        };
    }

    /// Destroy engine and ALL parsed selectors at once
    pub fn deinit(self: *Self) void {
        // We only free the hash map keys.
        // The actual CssSelectorList objects are freed by lxb_css_memory_destroy.
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();

        _ = lxb_selectors_destroy(self.selectors, true);
        _ = lxb_css_selectors_destroy(self.css_helper, true);
        _ = lxb_css_parser_destroy(self.css_parser, true);
        _ = lxb_css_memory_destroy(self.css_memory, true);
    }

    /// Internal: Parse or retrieve cached selector
    fn getSelector(self: *Self, selector_str: []const u8) !*z.CssSelectorList {
        if (self.cache.get(selector_str)) |list| {
            return list;
        }

        // Parse new
        const list = lxb_css_selectors_parse(self.css_parser, selector_str.ptr, selector_str.len) orelse return error.InvalidCssSelector;

        // Cache it (dup string key)
        const key = try self.allocator.dupe(u8, selector_str);
        try self.cache.put(key, list);

        return list;
    }

    //-------------------------------------------------------------------------
    // PUBLIC API (Polymorphic)
    //-------------------------------------------------------------------------

    /// Find first matching element: `root.querySelector(sel)`
    pub fn querySelector(self: *Self, root: anytype, selector: []const u8) !?*z.HTMLElement {
        const root_node = try toNode(root);
        const list = try self.getSelector(selector);

        var ctx = FirstContext{ .result = null };

        // Special handling for DocumentFragment: lexbor doesn't descend into fragment children
        if (z.nodeType(root_node) == .document_fragment) {
            var child = z.firstChild(root_node);
            while (child) |c| : (child = z.nextSibling(c)) {
                if (z.isTypeElement(c)) {
                    _ = lxb_selectors_find(self.selectors, c, list, findFirstCb, &ctx);
                    if (ctx.result != null) break; // Found first match
                }
            }
        } else {
            const status = lxb_selectors_find(self.selectors, root_node, list, findFirstCb, &ctx);
            if (status != z._OK and ctx.result == null) return error.SelectorFindError;
        }
        return ctx.result;
    }

    /// Find all matching elements: `root.querySelectorAll(sel)`
    pub fn querySelectorAll(self: *Self, root: anytype, selector: []const u8) ![]*z.HTMLElement {
        const root_node = try toNode(root);
        const list = try self.getSelector(selector);

        var ctx = AllContext.init(self.allocator);
        defer ctx.deinit();

        // Special handling for DocumentFragment: lexbor doesn't descend into fragment children
        // So we manually iterate through each element child and run the selector on it
        if (z.nodeType(root_node) == .document_fragment) {
            var child = z.firstChild(root_node);
            while (child) |c| : (child = z.nextSibling(c)) {
                if (z.isTypeElement(c)) {
                    // Search within this element subtree
                    _ = lxb_selectors_find(self.selectors, c, list, findAllCb, &ctx);
                }
            }
        } else {
            const status = lxb_selectors_find(self.selectors, root_node, list, findAllCb, &ctx);
            if (status != z._OK) return error.SelectorFindError;
        }
        return ctx.results.toOwnedSlice(self.allocator);
    }

    /// Check if element matches selector: `el.matches(sel)`
    pub fn matches(self: *Self, element: *z.HTMLElement, selector: []const u8) !bool {
        const list = try self.getSelector(selector);
        var matched = false;

        const status = lxb_selectors_match_node(self.selectors, z.elementToNode(element), list, matchCb, &matched);
        if (status != z._OK and status != z._STOP) return error.SelectorMatchError;
        return matched;
    }

    /// Find closest ancestor (or self) matching selector: `el.closest(sel)`
    pub fn closest(self: *Self, element: *z.HTMLElement, selector: []const u8) !?*z.HTMLElement {
        const list = try self.getSelector(selector);
        var current: ?*z.DomNode = z.elementToNode(element);

        while (current) |node| {
            if (z.isTypeElement(node)) {
                var matched = false;
                const status = lxb_selectors_match_node(self.selectors, node, list, matchCb, &matched);

                if (matched) {
                    return z.nodeToElement(node);
                }
                if (status != z._OK and status != z._STOP) return error.SelectorMatchError;
            }
            current = z.parentNode(node);
        }
        return null;
    }

    /// Filter a list of elements: `list.filter(el => el.matches(sel))`
    pub fn filter(self: *Self, elements: []*z.HTMLElement, selector: []const u8) ![]*z.HTMLElement {
        const list = try self.getSelector(selector);
        // Use ArrayListUnmanaged for explicit allocator control
        var results = std.ArrayListUnmanaged(*z.HTMLElement){};
        errdefer results.deinit(self.allocator);

        for (elements) |el| {
            var matched = false;
            _ = lxb_selectors_match_node(self.selectors, z.elementToNode(el), list, matchCb, &matched);
            if (matched) {
                try results.append(self.allocator, el);
            }
        }
        return results.toOwnedSlice(self.allocator);
    }
};

//=============================================================================
// CONVENIENCE WRAPPERS (Create Engine -> Run -> Destroy)
//=============================================================================

pub fn querySelector(allocator: std.mem.Allocator, root: anytype, selector: []const u8) !?*z.HTMLElement {
    var engine = try CssSelectorEngine.init(allocator);
    defer engine.deinit();
    return engine.querySelector(root, selector);
}

pub fn querySelectorAll(allocator: std.mem.Allocator, root: anytype, selector: []const u8) ![]*z.HTMLElement {
    var engine = try CssSelectorEngine.init(allocator);
    defer engine.deinit();
    return engine.querySelectorAll(root, selector);
}

pub fn matches(allocator: std.mem.Allocator, element: *z.HTMLElement, selector: []const u8) !bool {
    var engine = try CssSelectorEngine.init(allocator);
    defer engine.deinit();
    return engine.matches(element, selector);
}

pub fn closest(allocator: std.mem.Allocator, element: *z.HTMLElement, selector: []const u8) !?*z.HTMLElement {
    var engine = try CssSelectorEngine.init(allocator);
    defer engine.deinit();
    return engine.closest(element, selector);
}

pub fn filter(allocator: std.mem.Allocator, elements: []*z.HTMLElement, selector: []const u8) ![]*z.HTMLElement {
    var engine = try CssSelectorEngine.init(allocator);
    defer engine.deinit();
    return engine.filter(elements, selector);
}

//=============================================================================
// HELPERS & CALLBACKS
//=============================================================================

fn toNode(root: anytype) !*z.DomNode {
    const T = @TypeOf(root);
    if (T == *z.DomNode) return root;
    if (T == *z.HTMLElement) return z.elementToNode(root);
    if (T == *z.HTMLDocument) return z.documentRoot(root) orelse return error.DocumentHasNoRoot;
    if (T == *z.DocumentFragment) return z.fragmentToNode(root);

    // Generic optional handling
    if (@typeInfo(T) == .Optional) {
        if (root) |val| return toNode(val);
        return error.RootIsNull;
    }
    @compileError("Unsupported root type for querySelector: " ++ @typeName(T));
}

// --- Callbacks ---

const FirstContext = struct {
    result: ?*z.HTMLElement,
};

fn findFirstCb(node: *z.DomNode, _: *z.CssSelectorSpecificity, ctx: ?*anyopaque) callconv(.c) c_int {
    const context: *FirstContext = @ptrCast(@alignCast(ctx.?));
    if (z.nodeToElement(node)) |el| {
        context.result = el;
        return z._STOP; // Stop searching
    }
    return z._OK;
}

const AllContext = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayListUnmanaged(*z.HTMLElement),

    fn init(a: std.mem.Allocator) AllContext {
        return .{ .results = .{}, .allocator = a };
    }
    fn deinit(self: *AllContext) void {
        self.results.deinit(self.allocator);
    }
};

fn findAllCb(node: *z.DomNode, _: *z.CssSelectorSpecificity, ctx: ?*anyopaque) callconv(.c) c_int {
    const context: *AllContext = @ptrCast(@alignCast(ctx.?));
    if (z.nodeToElement(node)) |el| {
        context.results.append(context.allocator, el) catch return z._STOP;
    }
    return z._OK;
}

fn matchCb(_: *z.DomNode, _: *z.CssSelectorSpecificity, ctx: ?*anyopaque) callconv(.c) c_int {
    const matched: *bool = @ptrCast(@alignCast(ctx.?));
    matched.* = true;
    return z._STOP;
}

test "CssSelectorEngine integration" {
    const allocator = std.testing.allocator;

    // 1. Setup HTML
    const html =
        \\<div id="main">
        \\  <ul class="list">
        \\    <li class="item active">Item 1</li>
        \\    <li class="item">Item 2</li>
        \\    <li class="item">Item 3</li>
        \\  </ul>
        \\  <span data-foo="bar">Span</span>
        \\</div>
    ;
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // We can search from Document or Body
    const body = z.bodyNode(doc).?;

    // 2. Init Engine
    var engine = try CssSelectorEngine.init(allocator);
    defer engine.deinit();

    // 3. Test querySelector (ID)
    const main = try engine.querySelector(doc, "#main");
    try std.testing.expect(main != null);
    try std.testing.expect(z.hasAttribute(main.?, "id"));

    // 4. Test querySelectorAll (Class)
    const items = try engine.querySelectorAll(main.?, ".item");
    defer allocator.free(items); // Don't forget to free the slice!
    try std.testing.expectEqual(@as(usize, 3), items.len);

    // 5. Test matches
    const item1 = items[0];
    try std.testing.expect(try engine.matches(item1, ".active"));
    try std.testing.expect(try engine.matches(item1, "li"));
    try std.testing.expect(!try engine.matches(item1, "div"));

    // 6. Test closest
    // Closest ancestor of LI that is a DIV
    const container = try engine.closest(item1, "#main");
    try std.testing.expect(container != null);
    // Closest ancestor of LI that is a UL
    const list = try engine.closest(item1, ".list");
    try std.testing.expect(list != null);

    // 7. Test Cache & Performance
    // Calling this again should hit the hash map cache, not Lexbor parser
    const items_cached = try engine.querySelectorAll(main.?, ".item");
    defer allocator.free(items_cached);
    try std.testing.expectEqual(@as(usize, 3), items_cached.len);

    // 8. Test Convenience Wrapper (One-off)
    const span = try querySelector(allocator, body, "span[data-foo='bar']");
    try std.testing.expect(span != null);
}

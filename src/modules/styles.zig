//! CSS Styling Support
//!
//! Wraps Lexbor's Document and Stylesheet API.
//! Uses Lexbor's native DOM functions to handle the CSS Cascade automatically.

const std = @import("std");
const z = @import("../root.zig");

// ============================================================================
// EXTERN DECLARATIONS
// ============================================================================

const lxb_serialize_cb_f = *const fn (
    data: [*]const u8,
    len: usize,
    ctx: ?*anyopaque,
) callconv(.c) c_int;

// Document CSS Init/Destroy
extern "c" fn lxb_dom_document_css_init(document: *z.DomDocument, init_events: bool) c_int;
extern "c" fn lxb_dom_document_css_destroy(document: *z.DomDocument) void;

// Element Style Attachment (The "Magic" Function that runs the cascade)
extern "c" fn lxb_dom_document_element_styles_attach(element: *z.HTMLElement) c_int;

extern "c" fn lexbor_css_parser_memory_wrapper(parser: *z.CssStyleParser) ?*z.CssMemory;

// Element Style Accessors
extern "c" fn lxb_dom_element_style_by_name(
    element: *z.HTMLElement,
    name: [*]const u8,
    len: usize,
) ?*const z.CssRuleDeclaration;

extern "c" fn lxb_dom_element_style_serialize(
    element: *z.HTMLElement,
    opt: c_uint,
    cb: lxb_serialize_cb_f,
    ctx: ?*anyopaque,
) c_int;

extern "c" fn lxb_dom_element_style_remove_by_name(
    element: *z.HTMLElement,
    name: [*]const u8,
    size: usize,
) void;

extern "c" fn lxb_dom_element_style_parse(
    element: *z.HTMLElement,
    style: [*]const u8,
    size: usize,
) c_int;

// CSS Core
extern "c" fn lxb_css_parser_create() ?*z.CssStyleParser;
extern "c" fn lxb_css_parser_init(parser: *z.CssStyleParser, tokenizer: ?*anyopaque) c_int;
extern "c" fn lxb_css_parser_destroy(parser: *z.CssStyleParser, self_destroy: bool) void;
extern "c" fn lxb_css_rule_declaration_serialize(decl: *const z.CssRuleDeclaration, cb: lxb_serialize_cb_f, ctx: ?*anyopaque) c_int;

// Stylesheet
extern "c" fn lxb_css_stylesheet_create(memory: ?*z.CssMemory) ?*z.CssStyleSheet;
extern "c" fn lxb_css_stylesheet_parse(sst: *z.CssStyleSheet, parser: *z.CssStyleParser, data: [*]const u8, length: usize) c_int;
extern "c" fn lxb_css_stylesheet_destroy(sst: *z.CssStyleSheet, self_destroy: bool) void;
extern "c" fn lxb_dom_document_stylesheet_attach(document: *z.DomDocument, sst: *z.CssStyleSheet) c_int;

// ============================================================================
// IMPLEMENTATION
// ============================================================================

pub fn initDocumentCSS(doc: *z.HTMLDocument, init_events: bool) !void {
    if (lxb_dom_document_css_init(doc.asDom(), init_events) != z._OK) return error.CSSInitFailed;
}

pub fn destroyDocumentCSS(doc: *z.HTMLDocument) void {
    lxb_dom_document_css_destroy(doc.asDom());
}

pub fn createCssStyleParser() !*z.CssStyleParser {
    const parser = lxb_css_parser_create() orelse return error.CssParserAllocFailed;
    if (lxb_css_parser_init(parser, null) != z._OK) {
        lxb_css_parser_destroy(parser, true);
        return error.CssParserInitFailed;
    }
    return parser;
}

pub fn destroyCssStyleParser(parser: *z.CssStyleParser) void {
    lxb_css_parser_destroy(parser, true);
}

pub fn createStylesheet() !*z.CssStyleSheet {
    return lxb_css_stylesheet_create(null) orelse error.StylesheetAllocFailed;
}

pub fn destroyStylesheet(sst: *z.CssStyleSheet) void {
    lxb_css_stylesheet_destroy(sst, true);
}

pub fn parseStylesheet(sst: *z.CssStyleSheet, parser: *z.CssStyleParser, css_text: []const u8) !void {
    if (lxb_css_stylesheet_parse(sst, parser, css_text.ptr, css_text.len) != z._OK) {
        return error.StylesheetParseFailed;
    }
}

pub fn attachStylesheet(doc: *z.HTMLDocument, sst: *z.CssStyleSheet) !void {
    if (lxb_dom_document_stylesheet_attach(doc.asDom(), sst) != z._OK) {
        return error.StylesheetAttachFailed;
    }
}

pub fn attachElementStyles(element: *z.HTMLElement) !void {
    // Lexbor's native function. It iterates the document's stylesheets
    // and applies matching rules to this element's internal style list.
    if (lxb_dom_document_element_styles_attach(element) != z._OK) {
        return error.StyleAttachFailed;
    }
}

// ----------------------------------------------------------------------------
// INLINE STYLE HELPERS
// ----------------------------------------------------------------------------

const SerializeContext = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
};

fn serializeStructCb(data: [*]const u8, len: usize, ptr: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SerializeContext = @ptrCast(@alignCast(ptr));
    ctx.list.appendSlice(ctx.allocator, data[0..len]) catch return z._STOP;
    return z._OK;
}

pub fn serializeElementStyles(allocator: std.mem.Allocator, element: *z.HTMLElement) ![]u8 {
    var writer = std.ArrayListUnmanaged(u8){};
    errdefer writer.deinit(allocator);
    var ctx = SerializeContext{ .list = &writer, .allocator = allocator };

    if (lxb_dom_element_style_serialize(element, 0, serializeStructCb, &ctx) != z._OK) {
        writer.deinit(allocator);
        return try allocator.dupe(u8, "");
    }
    return writer.toOwnedSlice(allocator);
}

/// [Styles] Get a property from the element's style.
/// Returns the effective style (Stylesheet + Inline).
pub fn getComputedStyle(
    allocator: std.mem.Allocator,
    element: *z.HTMLElement,
    property: []const u8,
) !?[]u8 {
    const decl = lxb_dom_element_style_by_name(element, property.ptr, property.len);
    if (decl == null) return null;

    var writer = std.ArrayListUnmanaged(u8){};
    defer writer.deinit(allocator);
    var ctx = SerializeContext{ .list = &writer, .allocator = allocator };

    if (lxb_css_rule_declaration_serialize(decl.?, serializeStructCb, &ctx) != z._OK) {
        return error.StyleSerializeFailed;
    }

    const full_decl = try writer.toOwnedSlice(allocator);
    // Parse "prop: value" -> "value"
    if (std.mem.indexOf(u8, full_decl, ":")) |colon_idx| {
        var val_start = colon_idx + 1;
        while (val_start < full_decl.len and full_decl[val_start] == ' ') : (val_start += 1) {}
        const value_part = try allocator.dupe(u8, full_decl[val_start..]);
        allocator.free(full_decl);
        return value_part;
    }
    return full_decl;
}

pub const getInlineStyle = getComputedStyle;

pub fn setStyleProperty(
    allocator: std.mem.Allocator,
    element: *z.HTMLElement,
    property: []const u8,
    value: []const u8,
) !void {
    lxb_dom_element_style_remove_by_name(element, property.ptr, property.len);
    const rule = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ property, value });
    defer allocator.free(rule);
    _ = lxb_dom_element_style_parse(element, rule.ptr, rule.len);
    try syncStyleAttribute(allocator, element);
}

pub fn removeInlineStyleProperty(
    allocator: std.mem.Allocator,
    element: *z.HTMLElement,
    property: []const u8,
) !void {
    lxb_dom_element_style_remove_by_name(element, property.ptr, property.len);
    try syncStyleAttribute(allocator, element);
}

pub fn parseElementStyle(element: *z.HTMLElement) !void {
    const style_attr = z.getAttribute_zc(element, "style");
    if (style_attr == null) return;
    _ = lxb_dom_element_style_parse(element, style_attr.?.ptr, style_attr.?.len);
}

// INTERNAL HELPER: Syncs the CSSOM state back to the string attribute `style="..."`
// Should ONLY be called when modifying inline styles directly.
fn syncStyleAttribute(allocator: std.mem.Allocator, element: *z.HTMLElement) !void {
    const new_attr_str = try serializeElementStyles(allocator, element);
    defer allocator.free(new_attr_str);

    // 1. Always clear the existing attribute to avoid conflicts/re-parsing loops
    if (z.hasAttribute(element, "style")) {
        try z.removeAttribute(element, "style");
    }

    // 2. Set the new value if it's not empty
    if (new_attr_str.len > 0) {
        try z.setAttribute(element, "style", new_attr_str);
    }
}

/// [Styles] Scan the document for <style> tags and parse their content into the stylesheet.
/// This connects the DOM <style> elements to the CSS Engine.
pub fn loadStyleTags(
    allocator: std.mem.Allocator,
    doc: *z.HTMLDocument,
    parser: *z.CssStyleParser, // Removed the 'sst' argument
) !void {
    const style_elements = try z.querySelectorAll(allocator, z.documentRoot(doc).?, "style");
    defer allocator.free(style_elements);

    for (style_elements) |el| {
        const content = z.textContent_zc(z.elementToNode(el));

        if (content.len > 0) {
            // Get the parser's memory pool
            const parser_memory = lexbor_css_parser_memory_wrapper(@ptrCast(parser));
            // Create a FRESH stylesheet for this specific <style> tag
            // We use the parser's memory pool, so it gets cleaned up automatically later.
            const tag_sst = lxb_css_stylesheet_create(parser_memory) orelse return error.StylesheetAllocFailed;

            if (lxb_css_stylesheet_parse(tag_sst, parser, content.ptr, content.len) != z._OK) {
                lxb_css_stylesheet_destroy(tag_sst, true);
                return error.ParseFailed;
            }

            try z.attachStylesheet(doc, tag_sst);
        }
    }
}

// ============================================================================

test "order" {
    const allocator = std.testing.allocator;
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);

    const sst = try z.createStylesheet();
    defer z.destroyStylesheet(sst);

    const html = "<html><head></head><body><div id='target'></div></body></html>";
    try z.insertHTML(doc, html);

    const css = "div { color: red; }";
    try z.parseStylesheet(sst, parser, css);
    try z.attachStylesheet(doc, sst);

    const div = try z.querySelector(allocator, doc, "#target");

    const color = try z.getComputedStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, color.?, "red") != null);

    // const div_style = try serializeElementStyles(allocator, div.?);

    // defer allocator.free(div_style);
    // z.print("{s}\n", .{div_style});
    // try std.testing.expect(std.mem.indexOf(u8, div_style, "color: red") != null);

    const has_div_style_attr = z.hasAttribute(div.?, "style");
    try std.testing.expect(!has_div_style_attr);

    try z.attachElementStyles(div.?);

    // try z.prettyPrint(allocator, z.bodyNode(doc).?); // you see <div id="target">
    var is_synced_style = z.hasAttribute(div.?, "style");

    try std.testing.expect(!is_synced_style); // style setup with stylesheet, not inline, so no attribute 'style'

    try syncStyleAttribute(allocator, div.?);
    // forcing sync, this time it should appear
    is_synced_style = z.hasAttribute(div.?, "style");
    try std.testing.expect(is_synced_style);

    // try z.prettyPrint(allocator, z.bodyNode(doc).?); // you see <div id="target" style="color: red">
}
test "Styles: Manual Stylesheet Attachment" {
    const allocator = std.testing.allocator;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    try initDocumentCSS(doc, true);
    defer destroyDocumentCSS(doc);

    const parser = try createCssStyleParser();
    defer destroyCssStyleParser(parser);

    const sst = try createStylesheet();
    defer destroyStylesheet(sst);

    const html = "<html><head></head><body><div id='target'></div></body></html>";
    try z.insertHTML(doc, html);

    const css = "#target { width: 100px; color: red; }";
    try parseStylesheet(sst, parser, css);

    try attachStylesheet(doc, sst);

    const div = try z.querySelector(allocator, doc, "#target");
    try attachElementStyles(div.?);

    const width = try getComputedStyle(allocator, div.?, "width");
    defer if (width) |w| allocator.free(w);

    const color = try getComputedStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);

    try std.testing.expect(width != null);
    try std.testing.expect(std.mem.indexOf(u8, width.?, "100px") != null);

    try std.testing.expect(color != null);
    try std.testing.expect(std.mem.indexOf(u8, color.?, "red") != null);
}

test "Styles: Inline Style (Fixed Order)" {
    const allocator = std.testing.allocator;

    // SCENARIO 1: The "Wrong" Order (Parse -> Init)
    const html = "<html><body><div id='late' style='color: blue;'></div></body></html>";
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try initDocumentCSS(doc, false); // Init happens TOO LATE for the parsing phase

    const div = z.querySelector(allocator, doc, "#late") catch unreachable;

    // FAILS because the style wasn't parsed:
    // const fail = try getComputedStyle(allocator, div.?, "color");

    // !! Manually trigger parsing for this element
    try parseElementStyle(div.?);
    const color = try getComputedStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);

    try std.testing.expect(color != null);
    try std.testing.expect(std.mem.indexOf(u8, color.?, "blue") != null);
}

test "Styles: The Correct Order (Create -> Init -> Parse)" {
    const allocator = std.testing.allocator;

    // 1.Create Empty Document FIRST
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // 2.Init CSS Engine <-- now watching
    try initDocumentCSS(doc, true);

    // 3.Parse HTML into the document (CSS Engine sees attributes as they are parsed)
    const html = "<html><body><div id='correct' style='color: green;'></div></body></html>";
    try z.insertHTML(doc, html);
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);

    const div = try z.querySelector(allocator, doc, "#correct");
    const color = try getComputedStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);

    try std.testing.expect(color != null);
    try std.testing.expect(std.mem.indexOf(u8, color.?, "green") != null);
    try std.testing.expect(z.hasAttribute(div.?, "style"));
    try z.removeInlineStyleProperty(allocator, div.?, "color");
    try std.testing.expect(!z.hasAttribute(div.?, "style")); // ony oneproperty existed
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);
}
test "Styles: JS-like Getters and Setters" {
    const allocator = std.testing.allocator;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);
    try initDocumentCSS(doc, true); // Events MUST be on for setters to sync!

    const html = "<html><body><div id='box' style='color: red; width: 100px;'></div></body></html>";
    try z.insertHTML(doc, html);

    const div = z.querySelector(allocator, doc, "#box") catch unreachable;

    // Test Getter <- JS: div.style.color
    const color = try getComputedStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);
    try std.testing.expectEqualStrings("red", color.?);
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);

    // Test Setter <- JS: div.style.color = "green";
    try setStyleProperty(allocator, div.?, "color", "green");
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);

    const new_color = try getComputedStyle(allocator, div.?, "color");
    defer if (new_color) |c| allocator.free(c);
    try std.testing.expectEqualStrings("green", new_color.?);

    // Check Attribute String SYNC
    const style_attr = z.getAttribute_zc(div.?, "style").?;
    // order is not guaranteed, but it should contain both
    try std.testing.expect(std.mem.indexOf(u8, style_attr, "green") != null);
    try std.testing.expect(std.mem.indexOf(u8, style_attr, "width: 100px") != null);

    // Test Removal <- JS: div.style.removeProperty("width");
    try z.removeInlineStyleProperty(allocator, div.?, "width");
    try std.testing.expect(z.hasAttribute(div.?, "style"));
    const after_removal = z.getAttribute_zc(div.?, "style").?;
    try std.testing.expect(std.mem.indexOf(u8, after_removal, "color") != null);
}

test "Styles: Dynamic Insert (Lexbor port)" {
    const allocator = std.testing.allocator;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);
    try initDocumentCSS(doc, true);

    const parser = try createCssStyleParser();
    defer destroyCssStyleParser(parser);
    const sst = try createStylesheet();
    defer destroyStylesheet(sst);

    const css = ".father {width: 30%}";

    const html = "<div id='parent' class='father'></div>";
    try z.insertHTML(doc, html);

    // !! ⚠️ Attach Stylesheet AFTER parsing the HTML
    try parseStylesheet(sst, parser, css);
    try attachStylesheet(doc, sst);

    const parent_el = z.getElementById(doc, "parent").?;

    // Check not attached yet

    const st = try serializeElementStyles(allocator, parent_el);
    defer allocator.free(st);
    try std.testing.expect(std.mem.indexOf(u8, st, "width: 30%") != null);

    // Check parent style
    const p_width = try getComputedStyle(allocator, parent_el, "width");
    defer if (p_width) |w| allocator.free(w);
    try std.testing.expectEqualStrings("30%", p_width.?);

    // Add Child dynamically
    const child_el = try z.createElement(doc, "div");
    try z.setAttribute(child_el, "style", "height: 100px");
    z.appendChild(z.elementToNode(parent_el), z.elementToNode(child_el));

    // !! Should be processed upon insertion <-- DYNAMIC STYLE APPLICATION
    const c_height = try getComputedStyle(allocator, child_el, "height");
    defer if (c_height) |h| allocator.free(h);
    try std.testing.expectEqualStrings("100px", c_height.?);
}

test "Styles: Attribute Style (Lexbor port)" {
    const allocator = std.testing.allocator;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    try initDocumentCSS(doc, true);

    const html = "<div id='d' style='width: 10px; width: 123%; height: 20pt !important; height: 10px'></div>";
    try z.insertHTML(doc, html);

    const div_el = z.getElementById(doc, "d").?;

    const width = try getComputedStyle(allocator, div_el, "width");
    defer if (width) |w| allocator.free(w);
    try std.testing.expectEqualStrings("123%", width.?);

    // 3. Check Height (Should be 20pt !important, !important overrides the later 10px)
    const height = try getComputedStyle(allocator, div_el, "height");
    defer if (height) |h| allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, height.?, "20pt") != null);
}

test "Styles: Stylesheet Attachment (Lexbor port)" {
    const allocator = std.testing.allocator;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);
    try initDocumentCSS(doc, true);

    const parser = try createCssStyleParser();
    defer destroyCssStyleParser(parser);
    const sst = try createStylesheet();
    defer destroyStylesheet(sst);

    const css = "div {width: 5pt !important; height: 200px !important}";
    try parseStylesheet(sst, parser, css);

    const html = "<div id='d'></div>";
    try z.insertHTML(doc, html);

    try attachStylesheet(doc, sst);

    const div_el = z.getElementById(doc, "d").?;

    const width = try getComputedStyle(allocator, div_el, "width");
    defer if (width) |w| allocator.free(w);
    try std.testing.expect(std.mem.indexOf(u8, width.?, "5pt") != null);

    const height = try getComputedStyle(allocator, div_el, "height");
    defer if (height) |h| allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, height.?, "200px") != null);
}

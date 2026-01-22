//! CSS Styling Support
//!
//! Wraps Lexbor's Document and Stylesheet API.
//! Allows manual stylesheet creation, parsing, and application.

const std = @import("std");
const z = @import("../root.zig");

// ============================================================================
// TYPES & DEFINITIONS
// ============================================================================

const lxb_status_t = c_int;

const lxb_serialize_cb_f = *const fn (
    data: [*]const u8,
    len: usize,
    ctx: ?*anyopaque,
) callconv(.c) lxb_status_t;

// Opaque handles
const lxb_css_rule_declaration_t = opaque {};
// const lxb_css_parser_t = opaque {}; CssStyleParser
// const lxb_css_stylesheet_t = opaque {};CssStyleSheet
const lxb_css_memory_t = opaque {};

// ============================================================================
// EXTERN DEFINITIONS
// ============================================================================

// Document CSS Init/Destroy
extern "c" fn lxb_dom_document_css_init(document: *z.DomDocument, init_events: bool) lxb_status_t;
extern "c" fn lxb_dom_document_css_destroy(document: *z.DomDocument) void;

// Element Style Attachment
extern "c" fn lxb_dom_document_element_styles_attach(element: *z.HTMLElement) lxb_status_t;
extern "c" fn lxb_dom_element_style_by_name(
    element: *z.HTMLElement,
    name: [*]const u8,
    len: usize,
) ?*const lxb_css_rule_declaration_t;

// Serialize all styles of an element (for syncing back to attribute)
extern "c" fn lxb_dom_element_style_serialize(
    element: *z.HTMLElement,
    opt: c_uint,
    cb: lxb_serialize_cb_f,
    ctx: ?*anyopaque,
) lxb_status_t;

extern "c" fn lxb_dom_element_style_remove_by_name(
    element: *z.HTMLElement,
    name: [*]const u8,
    size: usize,
) void;
// Parse 'style' attribute string into element styles
extern "c" fn lxb_dom_element_style_parse(
    element: *z.HTMLElement,
    style: [*]const u8,
    size: usize,
) c_int;

extern "c" fn lxb_css_parser_create() ?*z.CssStyleParser;
extern "c" fn lxb_css_parser_init(parser: *z.CssStyleParser, tokenizer: ?*anyopaque) lxb_status_t;
extern "c" fn lxb_css_parser_destroy(parser: *z.CssStyleParser, self_destroy: bool) void;

const lxb_html_style_element_t = opaque {};
extern "c" fn lxb_html_style_element_parse(style_element: *lxb_html_style_element_t) lxb_status_t;
extern "c" fn lxb_html_style_element_remove(style_element: *lxb_html_style_element_t) lxb_status_t;

// CSS Rule Serialization
extern "c" fn lxb_css_rule_declaration_serialize(decl: *const lxb_css_rule_declaration_t, cb: lxb_serialize_cb_f, ctx: ?*anyopaque) lxb_status_t;

// Stylesheet
extern "c" fn lxb_css_stylesheet_create(memory: ?*lxb_css_memory_t) ?*z.CssStyleSheet;
extern "c" fn lxb_css_stylesheet_parse(sst: *z.CssStyleSheet, parser: *z.CssStyleParser, data: [*]const u8, length: usize) lxb_status_t;
extern "c" fn lxb_css_stylesheet_destroy(sst: *z.CssStyleSheet, self_destroy: bool) void;

// Document <-> Stylesheet Attachment
extern "c" fn lxb_dom_document_stylesheet_attach(document: *z.DomDocument, sst: *z.CssStyleSheet) lxb_status_t;

// ============================================================================
// ZIG WRAPPERS
// ============================================================================

pub fn initDocumentCSS(doc: *z.HTMLDocument, init_events: bool) !void {
    if (lxb_dom_document_css_init(doc.asDom(), init_events) != z._OK) {
        return error.CSSInitFailed;
    }
}

pub fn destroyDocumentCSS(doc: *z.HTMLDocument) void {
    lxb_dom_document_css_destroy(doc.asDom());
}

/// [Styles] Create a new CSS Parser.
/// You usually only need one of these to parse multiple stylesheets.
pub fn createCssStyleParser() !*z.CssStyleParser {
    const parser = lxb_css_parser_create() orelse return error.CssParserAllocFailed;
    if (lxb_css_parser_init(parser, null) != z._OK) {
        // Destroy if init fails (though create succeeded)
        lxb_css_parser_destroy(parser, true);
        return error.CssParserInitFailed;
    }
    return parser;
}

pub fn destroyCssStyleParser(parser: *z.CssStyleParser) void {
    lxb_css_parser_destroy(parser, true);
}

/// [Styles] Create a new empty Stylesheet.
pub fn createStylesheet() !*z.CssStyleSheet {
    return lxb_css_stylesheet_create(null) orelse error.StylesheetAllocFailed;
}

pub fn destroyStylesheet(sst: *z.CssStyleSheet) void {
    lxb_css_stylesheet_destroy(sst, true);
}

/// [Styles] Parse CSS text into a Stylesheet.
pub fn parseStylesheet(sst: *z.CssStyleSheet, parser: *z.CssStyleParser, css_text: []const u8) !void {
    if (lxb_css_stylesheet_parse(sst, parser, css_text.ptr, css_text.len) != z._OK) {
        return error.StylesheetParseFailed;
    }
}

/// [Styles] Attach a stylesheet to the document.
/// This makes the rules in the stylesheet active for the document.
pub fn attachStylesheet(doc: *z.HTMLDocument, sst: *z.CssStyleSheet) !void {
    if (lxb_dom_document_stylesheet_attach(doc.asDom(), sst) != z._OK) {
        return error.StylesheetAttachFailed;
    }
}

/// [Styles] Calculate and attach matching styles to a specific Element.
pub fn attachElementStyles(element: *z.HTMLElement) !void {
    if (lxb_dom_document_element_styles_attach(element) != z._OK) {
        return error.StyleAttachFailed;
    }
}

/// [Styles] Manually parse the 'style' attribute of an element.
/// Use this if the element was created/parsed BEFORE CSS was initialized.
pub fn parseElementStyle(element: *z.HTMLElement) !void {
    // 1. Get the raw style attribute string (e.g. "color: red;")
    const style_attr = z.getAttribute_zc(element, "style");
    if (style_attr == null) return; // No style to parse

    // 2. Feed it to the CSS engine
    if (lxb_dom_element_style_parse(element, style_attr.?.ptr, style_attr.?.len) != z._OK) {
        return error.StyleParseFailed;
    }
}

/// [Styles] Serialize the element's current CSSOM to a string
/// e.g. "color: red; width: 10px;"
fn serializeElementStyles(allocator: std.mem.Allocator, element: *z.HTMLElement) ![]u8 {
    var writer = std.ArrayListUnmanaged(u8){};
    errdefer writer.deinit(allocator);

    const Context = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    };
    var ctx = Context{ .list = &writer, .allocator = allocator };

    const cb = struct {
        fn impl(data: [*]const u8, len: usize, ptr: ?*anyopaque) callconv(.c) lxb_status_t {
            const self: *Context = @ptrCast(@alignCast(ptr));
            self.list.appendSlice(self.allocator, data[0..len]) catch return z._STOP;
            return z._OK;
        }
    }.impl;

    if (lxb_dom_element_style_serialize(element, 0, cb, &ctx) != z._OK) {
        writer.deinit(allocator);
        return try allocator.dupe(u8, "");
    }
    return writer.toOwnedSlice(allocator);
}

/// NOTE: This does NOT return values from stylesheets (<style> or <link>).
/// For that, you need a Cascade Walker (future implementation).
/// [Styles] Get a property from the element's INLINE style.
/// This corresponds to JS: `element.style.getPropertyValue(prop)`
pub fn getInlineStyle(
    allocator: std.mem.Allocator,
    element: *z.HTMLElement,
    property: []const u8,
) !?[]u8 {
    // 1. Get declaration
    const decl = lxb_dom_element_style_by_name(element, property.ptr, property.len);
    if (decl == null) return null;

    // 2. Serialize full declaration (e.g. "color: green")
    var writer = std.ArrayListUnmanaged(u8){};
    defer writer.deinit(allocator);

    const Context = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    };
    var ctx = Context{ .list = &writer, .allocator = allocator };

    const cb = struct {
        fn impl(data: [*]const u8, len: usize, ptr: ?*anyopaque) callconv(.c) c_int {
            const self: *Context = @ptrCast(@alignCast(ptr));
            self.list.appendSlice(self.allocator, data[0..len]) catch return z._STOP;
            return z._OK;
        }
    }.impl;

    if (lxb_css_rule_declaration_serialize(decl.?, cb, &ctx) != z._OK) {
        return error.StyleSerializeFailed;
    }

    const full_decl = try writer.toOwnedSlice(allocator);
    // defer allocator.free(full_decl); // We will return a slice or copy of this

    // 3. Strip key ("color: green" -> "green")
    if (std.mem.indexOf(u8, full_decl, ":")) |colon_idx| {
        // Find start of value (skip colon and spaces)
        var val_start = colon_idx + 1;
        while (val_start < full_decl.len and full_decl[val_start] == ' ') : (val_start += 1) {}

        // Move the value to the front of the buffer (overlap is handled by std.mem.copy usually,
        // but here we are destructively slicing).
        // Safer: Duplicate the value part and free the full string.
        const value_part = try allocator.dupe(u8, full_decl[val_start..]);
        allocator.free(full_decl);
        return value_part;
    }

    // Fallback: return full string if parsing failed (unlikely)
    return full_decl;
}

pub fn removeInlineStyleProperty(
    allocator: std.mem.Allocator,
    element: *z.HTMLElement,
    property: []const u8,
) !void {
    // Remove from CSSOM
    lxb_dom_element_style_remove_by_name(element, property.ptr, property.len);

    // SYNC: Serialize CSSOM back to the 'style' attribute
    // If we don't do this, the "style" attribute string will still contain the old value
    const new_attr_str = try serializeElementStyles(allocator, element);
    defer allocator.free(new_attr_str);

    if (new_attr_str.len == 0) {
        // If style is empty, remove the attribute entirely
        if (z.hasAttribute(element, "style")) {
            try z.removeAttribute(element, "style");
        }
    } else {
        try z.removeAttribute(element, "style");
        try z.setAttribute(element, "style", new_attr_str);
    }
}

/// [Styles] Set a specific inline style property.
/// Equivalent to JS: `element.style.setProperty(prop, val)` or `element.style.prop = val`
///
/// This removes any existing inline declaration for this property and appends the new one.
pub fn setStyleProperty(
    allocator: std.mem.Allocator,
    element: *z.HTMLElement,
    property: []const u8,
    value: []const u8,
) !void {
    // Remove old property from CSSOM to prevent duplicates
    lxb_dom_element_style_remove_by_name(element, property.ptr, property.len);

    // Add new property to CSSOM
    // format"prop: value" because parse expects a declaration
    const rule = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ property, value });
    defer allocator.free(rule);

    if (lxb_dom_element_style_parse(element, rule.ptr, rule.len) != z._OK) {
        return error.StyleParseFailed;
    }

    // SYNC: Serialize CSSOM back to the 'style' attribute
    const new_attr_str = try serializeElementStyles(allocator, element);
    defer allocator.free(new_attr_str);

    if (z.hasAttribute(element, "style")) {
        try z.removeAttribute(element, "style");
    }
    try z.setAttribute(element, "style", new_attr_str);
}

/// [Styles] Get the computed CSS declaration for a specific property.
pub fn getComputedStyle(
    allocator: std.mem.Allocator,
    element: *z.HTMLElement,
    property: []const u8,
) !?[]u8 {
    // 1. Get the declaration (Returns *const)
    const decl = lxb_dom_element_style_by_name(element, property.ptr, property.len);
    if (decl == null) return null;

    // 2. Serialize
    var writer = std.ArrayListUnmanaged(u8){};
    errdefer writer.deinit(allocator);

    const Context = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    };
    var ctx = Context{ .list = &writer, .allocator = allocator };

    const cb = struct {
        fn impl(data: [*]const u8, len: usize, ptr: ?*anyopaque) callconv(.c) lxb_status_t {
            const self: *Context = @ptrCast(@alignCast(ptr));
            self.list.appendSlice(self.allocator, data[0..len]) catch return z._STOP;
            return z._OK;
        }
    }.impl;

    if (lxb_css_rule_declaration_serialize(decl.?, cb, &ctx) != z._OK) {
        return error.StyleSerializeFailed;
    }

    return try writer.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "Styles: Manual Stylesheet Attachment" {
    const allocator = std.testing.allocator;

    const html = "<html><head></head><body><div id='target'></div></body></html>";
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // 1. Init Document CSS
    try initDocumentCSS(doc, true);
    defer destroyDocumentCSS(doc);

    // 2. Setup Parser and Stylesheet
    const parser = try createCssStyleParser();
    defer destroyCssStyleParser(parser);

    const sst = try createStylesheet();
    // In Lexbor, attaching a stylesheet transfers ownership to the document/memory pool usually,
    // but explicit destruction is safer in tests to prevent leaks if attachment fails.
    defer destroyStylesheet(sst);

    // 3. Parse CSS
    const css = "#target { width: 100px; color: red; }";
    try parseStylesheet(sst, parser, css);

    // 4. Attach Stylesheet to Document
    try attachStylesheet(doc, sst);

    // 5. Apply styles to target
    const div = try z.querySelector(allocator, doc, "#target");
    try attachElementStyles(div.?);

    // 6. Verify (Should now work!)
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
    // This simulates your current issue.
    const html = "<html><body><div id='late' style='color: blue;'></div></body></html>";
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try initDocumentCSS(doc, false); // Init happens TOO LATE for the parsing phase

    const div = z.querySelector(allocator, doc, "#late") catch unreachable;

    // This would FAIL (return null) because the style wasn't parsed:
    // const fail = try getInlineStyle(allocator, div.?, "color");

    // FIX: Manually trigger parsing for this element
    try parseElementStyle(div.?);

    // Now it works!
    const color = try getInlineStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);

    try std.testing.expect(color != null);
    try std.testing.expect(std.mem.indexOf(u8, color.?, "blue") != null);
}

test "Styles: The Correct Order (Create -> Init -> Parse)" {
    const allocator = std.testing.allocator;

    // 1. Create Empty Document FIRST
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // 2. Init CSS Engine (Now it's watching!)
    try initDocumentCSS(doc, true);

    // 3. Parse HTML into the document (CSS Engine sees attributes as they are parsed)
    const html = "<html><body><div id='correct' style='color: green;'></div></body></html>";
    try z.insertHTML(doc, html);
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);

    const div = z.querySelector(allocator, doc, "#correct") catch unreachable;

    // Works immediately!
    const color = try getInlineStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);

    try std.testing.expect(color != null);
    try std.testing.expect(std.mem.indexOf(u8, color.?, "green") != null);
    try std.testing.expect(z.hasAttribute(div.?, "style"));
    try removeInlineStyleProperty(allocator, div.?, "color");
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

    // 1. Test Getter (Initial)
    const color = try getInlineStyle(allocator, div.?, "color");
    defer if (color) |c| allocator.free(c);
    try std.testing.expectEqualStrings("red", color.?);
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);

    // 2. Test Setter (Change color)
    // JS: div.style.color = "green";
    try setStyleProperty(allocator, div.?, "color", "green");
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);

    const new_color = try getInlineStyle(allocator, div.?, "color");
    defer if (new_color) |c| allocator.free(c);
    try std.testing.expectEqualStrings("green", new_color.?);

    // 4. Verify Attribute String Sync
    // Lexbor should have automatically updated the string to match
    const style_attr = z.getAttribute_zc(div.?, "style").?;
    // Note: order is not guaranteed, but it should contain both
    try std.testing.expect(std.mem.indexOf(u8, style_attr, "green") != null);
    try std.testing.expect(std.mem.indexOf(u8, style_attr, "width: 100px") != null);

    try removeInlineStyleProperty(allocator, div.?, "width");
    try std.testing.expect(z.hasAttribute(div.?, "style"));
    const after_removal = z.getAttribute_zc(div.?, "style").?;
    try std.testing.expect(std.mem.indexOf(u8, after_removal, "color") != null);
}

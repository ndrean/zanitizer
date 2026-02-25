//! Simple slice-based element search using walker for efficiency
//!
//! This module provides getElementsByX functions that return []const *z.HTMLElement
//! using the fast walker traversal system instead of heavy C collection wrappers.
//!
//! /// GENERIC DOM SEARCH PATTERN
//!
//! GENERIC DOM SEARCH PATTERN
//!
//! The search functions below use a generic pattern from walker.zig that allows
//! efficient DOM traversal with custom matching logic. Here's how it works:
//!
//! **Pattern Structure:**
//! 1. Define a Context struct with mandatory fields:
//!    - `found_element: ?*z.HTMLElement` (for single element search)
//!    - `matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int` (callback)
//!    - Custom fields for search criteria (target_id, target_class, etc.)
//!
//! 2. Implement the matcher function that:
//!    - Returns `z._CONTINUE` to keep searching
//!    - Returns `z._STOP` when match found (sets `found_element`)
//!
//! 3. Call `z.genSearchElement(ContextType, root_node, &context_instance)`
//!
//! **Example Pattern:**
//! ```zig
//! const MyContext = struct {
//!     target: []const u8,
//!     found_element: ?*z.HTMLElement = null,
//!     matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int,
//!
//!     fn implement(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
//!         // Your matching logic here
//!         if (matches_criteria(node, ctx.target)) {
//!             ctx.found_element = z.nodeToElement(node);
//!             return z._STOP;
//!         }
//!         return z._CONTINUE;
//!     }
//! };
//! ```
//!
//! This pattern provides:
//! - Type-safe context passing
//! - Efficient single-pass DOM traversal
//! - Early termination on first match
//! - Zero heap allocation for search logic
//!
//! See walker.zig for genSearchElements() (multiple results) and genProcessAll() (side effects)

const std = @import("std");
const z = @import("../root.zig");
const walker = @import("walker.zig");
const Err = z.Err;

const testing = std.testing;
const print = std.debug.print;

//=============================================================================
// ELEMENT SEARCH FUNCTIONS (Browser-like API but returns slices)
//=============================================================================

/// Find elements by class name using token-based matching (like document.getElementsByClassName)
/// Returns owned slice - caller must free with allocator.free(result)
pub fn getElementsByClassName(allocator: std.mem.Allocator, doc: *z.HTMLDocument, class_name: []const u8) ![]const *z.HTMLElement {
    const root = z.bodyElement(doc) orelse return &[_]*z.HTMLElement{};

    const ClassContext = struct {
        allocator: std.mem.Allocator,
        results: std.ArrayList(*z.HTMLElement),
        matcher: *const fn (*z.DomNode, ctx: *@This()) callconv(.c) c_int,
        target_class: []const u8,

        fn findClass(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node) orelse return z._CONTINUE;
            if (z.hasClass(element, ctx.target_class)) {
                ctx.results.append(ctx.allocator, element) catch return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var ctx = ClassContext{
        .allocator = allocator,
        .results = .empty,
        .matcher = ClassContext.findClass,
        .target_class = class_name,
    };

    return walker.genSearchElements(ClassContext, z.elementToNode(root), &ctx);
}

/// Find elements by class name starting from a given DOM node (like element.getElementsByClassName)
/// Returns owned slice - caller must free with allocator.free(result)
pub fn getElementsByClassNameFromNode(allocator: std.mem.Allocator, root_node: *z.DomNode, class_name: []const u8) ![]const *z.HTMLElement {
    const ClassContext = struct {
        allocator: std.mem.Allocator,
        results: std.ArrayList(*z.HTMLElement),
        matcher: *const fn (*z.DomNode, ctx: *@This()) callconv(.c) c_int,
        target_class: []const u8,

        fn findClass(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node) orelse return z._CONTINUE;
            if (z.hasClass(element, ctx.target_class)) {
                ctx.results.append(ctx.allocator, element) catch return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var ctx = ClassContext{
        .allocator = allocator,
        .results = .empty,
        .matcher = ClassContext.findClass,
        .target_class = class_name,
    };

    return walker.genSearchElements(ClassContext, root_node, &ctx);
}

/// Find elements by tag name (like document.getElementsByTagName)
/// Returns owned slice - caller must free with allocator.free(result)
pub fn getElementsByTagName(allocator: std.mem.Allocator, doc: *z.HTMLDocument, tag_name: []const u8) ![]const *z.HTMLElement {
    // Search from document root (<html>), not <body>, so <head> and its children are found too
    const root_node = z.documentRoot(doc) orelse return &[_]*z.HTMLElement{};
    const root = z.nodeToElement(root_node) orelse return &[_]*z.HTMLElement{};

    const TagContext = struct {
        allocator: std.mem.Allocator,
        results: std.ArrayList(*z.HTMLElement),
        matcher: *const fn (*z.DomNode, ctx: *@This()) callconv(.c) c_int,
        target_tag: []const u8,

        fn findTag(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node) orelse return z._CONTINUE;
            const element_tag = z.tagName_zc(element);
            if (std.mem.eql(u8, element_tag, ctx.target_tag)) {
                ctx.results.append(ctx.allocator, element) catch return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var ctx = TagContext{
        .allocator = allocator,
        .results = .empty,
        .matcher = TagContext.findTag,
        .target_tag = tag_name,
    };

    return walker.genSearchElements(TagContext, z.elementToNode(root), &ctx);
}

/// Find elements by ID attribute (like document.getElementById, but returns slice for consistency)
/// Returns owned slice - caller must free with allocator.free(result)
pub fn getElementsById(allocator: std.mem.Allocator, doc: *z.HTMLDocument, id: []const u8) ![]const *z.HTMLElement {
    const root = z.bodyElement(doc) orelse return &[_]*z.HTMLElement{};

    const IdContext = struct {
        allocator: std.mem.Allocator,
        results: std.ArrayList(*z.HTMLElement),
        matcher: *const fn (*z.DomNode, ctx: *@This()) callconv(.c) c_int,
        target_id: []const u8,

        fn findId(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node) orelse return z._CONTINUE;
            const element_id = z.getAttribute_zc(element, "id") orelse return z._CONTINUE;
            if (std.mem.eql(u8, element_id, ctx.target_id)) {
                ctx.results.append(ctx.allocator, element) catch return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var ctx = IdContext{
        .allocator = allocator,
        .results = .empty,
        .matcher = IdContext.findId,
        .target_id = id,
    };

    return walker.genSearchElements(IdContext, z.elementToNode(root), &ctx);
}

/// Find elements by attribute name and value (case-sensitive exact match)
/// Returns owned slice - caller must free with allocator.free(result)
pub fn getElementsByAttribute(allocator: std.mem.Allocator, doc: *z.HTMLDocument, attr: z.AttributePair, case_insensitive: bool) ![]const *z.HTMLElement {
    const root = z.bodyElement(doc) orelse return &[_]*z.HTMLElement{};

    const AttrContext = struct {
        allocator: std.mem.Allocator,
        results: std.ArrayList(*z.HTMLElement),
        matcher: *const fn (*z.DomNode, ctx: *@This()) callconv(.c) c_int,
        target_attr: z.AttributePair,
        case_insensitive: bool,

        fn findAttr(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node) orelse return z._CONTINUE;
            const attr_value = z.getAttribute_zc(element, ctx.target_attr.name) orelse return z._CONTINUE;

            const matches = if (ctx.case_insensitive)
                std.ascii.eqlIgnoreCase(attr_value, ctx.target_attr.value)
            else
                std.mem.eql(u8, attr_value, ctx.target_attr.value);

            if (matches) {
                ctx.results.append(ctx.allocator, element) catch return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var ctx = AttrContext{
        .allocator = allocator,
        .results = .empty,
        .matcher = AttrContext.findAttr,
        .target_attr = attr,
        .case_insensitive = case_insensitive,
    };

    return walker.genSearchElements(AttrContext, z.elementToNode(root), &ctx);
}

/// Find elements by name attribute (like document.getElementsByName)
/// Returns owned slice - caller must free with allocator.free(result)
pub fn getElementsByName(allocator: std.mem.Allocator, doc: *z.HTMLDocument, name: []const u8) ![]const *z.HTMLElement {
    return getElementsByAttribute(allocator, doc, .{ .name = "name", .value = name }, false);
}

/// Find elements that have a specific attribute name (regardless of value)
/// Returns owned slice - caller must free with allocator.free(result)
pub fn getElementsByAttributeName(allocator: std.mem.Allocator, doc: *z.HTMLDocument, attr_name: []const u8) ![]const *z.HTMLElement {
    const root = z.bodyElement(doc) orelse return &[_]*z.HTMLElement{};

    const AttrNameContext = struct {
        allocator: std.mem.Allocator,
        results: std.ArrayList(*z.HTMLElement),
        matcher: *const fn (*z.DomNode, ctx: *@This()) callconv(.c) c_int,
        target_attr_name: []const u8,

        fn findAttrName(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node) orelse return z._CONTINUE;
            if (z.hasAttribute(element, ctx.target_attr_name)) {
                ctx.results.append(ctx.allocator, element) catch return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var ctx = AttrNameContext{
        .allocator = allocator,
        .results = .empty,
        .matcher = AttrNameContext.findAttrName,
        .target_attr_name = attr_name,
    };

    return walker.genSearchElements(AttrNameContext, z.elementToNode(root), &ctx);
}

//=============================================================================
// Single element search functions
//=============================================================================

/// String utility functions
pub fn stringEquals(first: []const u8, second: []const u8) bool {
    return std.mem.eql(u8, first, second);
}

pub fn stringContains(where: []const u8, what: []const u8) bool {
    return std.mem.indexOf(u8, where, what) != null;
}
// ----------------------------------------------------------------------------

/// Check if [parent] contains [child] in the DOM tree
///
/// [JS] Node.contains(childNode) equivalent
pub fn contains(parent: *z.DomNode, child: *z.DomNode) bool {
    // ! create a var because arg are cst, and type it optional for loop
    var current: ?*z.DomNode = child;
    while (current) |node| {
        if (node == parent) {
            return true;
        }
        current = z.parentNode(node);
    }

    return false;
}

/// DOM Node position constants for compareDocumentPosition
/// These match the W3C DOM specification values
pub const DocumentPosition = struct {
    pub const DISCONNECTED: u16 = 1;
    pub const PRECEDING: u16 = 2;
    pub const FOLLOWING: u16 = 4;
    pub const CONTAINS: u16 = 8;
    pub const CONTAINED_BY: u16 = 16;
    pub const IMPLEMENTATION_SPECIFIC: u16 = 32;
};

/// [DOM] Compare the document position of two nodes
///
/// [JS] `node.compareDocumentPosition(other)` method
///
/// Returns a bitmask indicating the relationship between the nodes:
/// - DISCONNECTED (1): Nodes are in different documents or disconnected
/// - PRECEDING (2): other is preceding this node
/// - FOLLOWING (4): other is following this node
/// - CONTAINS (8): other contains this node
/// - CONTAINED_BY (16): other is contained by this node
/// - IMPLEMENTATION_SPECIFIC (32): Implementation-specific
pub fn compareDocumentPosition(reference: *z.DomNode, other: *z.DomNode) u16 {
    // Same node
    if (reference == other) return 0;

    // Check if nodes share the same document
    const ref_doc = z.ownerDocument(reference);
    const other_doc = z.ownerDocument(other);
    if (ref_doc != other_doc) {
        // Disconnected, use pointer comparison for consistent ordering
        return DocumentPosition.DISCONNECTED |
            DocumentPosition.IMPLEMENTATION_SPECIFIC |
            (if (@intFromPtr(reference) < @intFromPtr(other))
                DocumentPosition.PRECEDING
            else
                DocumentPosition.FOLLOWING);
    }

    // Check containment
    if (contains(reference, other)) {
        // reference contains other -> other is CONTAINED_BY reference
        // In the DOM spec, we're asking "where is other relative to reference"
        // If reference contains other, then other is a descendant (CONTAINED_BY)
        // and other FOLLOWS reference in document order
        return DocumentPosition.CONTAINED_BY | DocumentPosition.FOLLOWING;
    }
    if (contains(other, reference)) {
        // other contains reference -> other CONTAINS reference
        // reference is a descendant of other, so other PRECEDES reference
        return DocumentPosition.CONTAINS | DocumentPosition.PRECEDING;
    }

    // Neither contains the other - find document order
    // Walk up to find common ancestor, then determine order among siblings
    // Use stack buffer for efficiency (DOM depth rarely exceeds 64 levels)

    // Get ancestors of reference using stack arrays
    var ref_buf: [64]*z.DomNode = undefined;
    var ref_count: usize = 0;
    var current: ?*z.DomNode = reference;
    while (current) |node| {
        if (ref_count >= ref_buf.len) break; // Safety limit
        ref_buf[ref_count] = node;
        ref_count += 1;
        current = z.parentNode(node);
    }

    // Get ancestors of other
    var other_buf: [64]*z.DomNode = undefined;
    var other_count: usize = 0;
    current = other;
    while (current) |node| {
        if (other_count >= other_buf.len) break; // Safety limit
        other_buf[other_count] = node;
        other_count += 1;
        current = z.parentNode(node);
    }

    // Find common ancestor and divergence point
    // Ancestors are stored child->parent, so reverse iteration to go root->child
    var ref_idx = ref_count;
    var other_idx = other_count;

    // Find where paths diverge
    while (ref_idx > 0 and other_idx > 0) {
        ref_idx -= 1;
        other_idx -= 1;
        if (ref_buf[ref_idx] != other_buf[other_idx]) {
            // Found divergence - compare sibling order
            const ref_sibling = ref_buf[ref_idx];
            const other_sibling = other_buf[other_idx];

            // Walk through siblings to determine order
            var sibling: ?*z.DomNode = ref_sibling;
            while (sibling) |s| {
                if (s == other_sibling) {
                    // other_sibling comes after ref_sibling
                    return DocumentPosition.FOLLOWING;
                }
                sibling = z.nextSibling(s);
            }
            // other_sibling must come before ref_sibling
            return DocumentPosition.PRECEDING;
        }
    }

    // Shouldn't reach here if nodes are in same document
    return DocumentPosition.DISCONNECTED;
}

test "compareDocumentPosition" {
    const allocator = std.testing.allocator;
    const doc = try z.parseHTML(allocator, "<div id=\"a\"><span id=\"b\"></span></div><p id=\"c\"></p>");
    defer z.destroyDocument(doc);

    const a = z.elementToNode(z.getElementById(doc, "a").?);
    const b = z.elementToNode(z.getElementById(doc, "b").?);
    const c = z.elementToNode(z.getElementById(doc, "c").?);

    // Same node
    try std.testing.expectEqual(@as(u16, 0), compareDocumentPosition(a, a));

    // a contains b
    const a_b = compareDocumentPosition(a, b);
    try std.testing.expect(a_b & DocumentPosition.CONTAINED_BY != 0);

    // b is contained by a
    const b_a = compareDocumentPosition(b, a);
    try std.testing.expect(b_a & DocumentPosition.CONTAINS != 0);

    // a precedes c (siblings)
    const a_c = compareDocumentPosition(a, c);
    try std.testing.expect(a_c & DocumentPosition.FOLLOWING != 0);

    // c follows a
    const c_a = compareDocumentPosition(c, a);
    try std.testing.expect(c_a & DocumentPosition.PRECEDING != 0);
}

/// [attrs] getElementById traversal DOM search
///
/// Returns the first element with matching ID, or null if not found.
pub fn getElementById(doc: *z.HTMLDocument, id: []const u8) ?*z.HTMLElement {
    const root_node = z.bodyNode(doc) orelse return null;

    const IdContext = struct {
        target_id: []const u8,
        found_element: ?*z.HTMLElement = null,
        matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int,

        fn implement(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const elt = z.nodeToElement(node).?;
            if (!z.hasAttribute(elt, "id")) return z._CONTINUE;
            const id_value = z.getElementId_zc(elt);

            if (stringEquals(id_value, ctx.target_id)) {
                ctx.found_element = elt;
                return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var context = IdContext{ .target_id = id, .matcher = IdContext.implement };
    return walker.genSearchElement(
        IdContext,
        root_node,
        &context,
    );
}

/// [attrs] getElementByClass traversal DOM search
///
/// Returns the first element with matching class name (using token-based matching), or null if not found.
/// Uses hasClass() for proper CSS class token matching - not substring matching.
pub fn getElementByClass(root_node: *z.DomNode, class_name: []const u8) ?*z.HTMLElement {
    const ClassContext = struct {
        target_class: []const u8,
        found_element: ?*z.HTMLElement = null,
        matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int,

        fn implement(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node).?;
            if (!z.hasAttribute(element, "class")) return z._CONTINUE;

            if (z.hasClass(element, ctx.target_class)) {
                ctx.found_element = element;
                return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var context = ClassContext{ .target_class = class_name, .matcher = ClassContext.implement };
    return walker.genSearchElement(ClassContext, root_node, &context);
}

/// [attrs] Get element by attribute name/value (single result)
pub fn getElementByAttribute(root_node: *z.DomNode, attr_name: []const u8, attr_value: ?[]const u8) ?*z.HTMLElement {
    const AttrContext = struct {
        attr_name: []const u8,
        attr_value: ?[]const u8,
        found_element: ?*z.HTMLElement = null,
        matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int,

        fn implement(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node).?;
            if (!z.hasAttribute(element, ctx.attr_name)) return z._CONTINUE;

            if (ctx.attr_value) |expected| {
                const actual = z.getAttribute_zc(element, ctx.attr_name) orelse return z._CONTINUE;
                if (!std.mem.eql(u8, actual, expected)) return z._CONTINUE;
            }

            ctx.found_element = element;
            return z._STOP;
        }
    };

    var context = AttrContext{
        .attr_name = attr_name,
        .attr_value = attr_value,
        .matcher = AttrContext.implement,
    };
    return walker.genSearchElement(AttrContext, root_node, &context);
}

/// [attrs] Fast search by data-attributes
///
/// Example:
/// ```
/// const doc = try z.parseHTML("<form><input phx-click=\"increment\" disabled></form>");
/// defer z.destroyDocument(doc);
/// try z.getElementByDataAttribute(root_node, "phx", "click", "increment");
/// ```
pub fn getElementByDataAttribute(root_node: *z.DomNode, prefix: []const u8, data_name: []const u8, value: ?[]const u8) !?*z.HTMLElement {
    var attr_name_buffer: [32]u8 = undefined;
    const attr_name = try std.fmt.bufPrint(
        attr_name_buffer[0..],
        "{s}-{s}",
        .{ prefix, data_name },
    );

    return getElementByAttribute(root_node, attr_name, value);
}

/// [attrs] Get element by tag name (single result)
pub fn getElementByTag(root_node: *z.DomNode, tag: z.HtmlTag) ?*z.HTMLElement {
    const TagContext = struct {
        target_tag: z.HtmlTag,
        found_element: ?*z.HTMLElement = null,
        matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int,

        fn implement(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
            const element = z.nodeToElement(node).?;
            const element_tag = z.tagFromElement(element);
            if (element_tag == ctx.target_tag) {
                ctx.found_element = element;
                return z._STOP;
            }
            return z._CONTINUE;
        }
    };

    var context = TagContext{ .target_tag = tag, .matcher = TagContext.implement };
    return walker.genSearchElement(TagContext, root_node, &context);
}

//=============================================================================
// TESTS
//=============================================================================

test "getElementsByClassName with token-based matching" {
    const allocator = testing.allocator;
    const html = "<div><h1 class='title main'>Main Title</h1><p class='text main-text'>Paragraph</p><footer class='footer main-footer'>Footer</footer></div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Should find only the h1 with "main" as a token
    const results = try getElementsByClassName(allocator, doc, "main");
    defer allocator.free(results);

    try testing.expect(results.len == 1);
    const tag = z.tagName_zc(results[0]);
    const class_attr = z.getAttribute_zc(results[0], "class").?;
    try testing.expectEqualStrings("H1", tag);
    try testing.expectEqualStrings("title main", class_attr);
}

test "getElementsByTagName case sensitivity" {
    const allocator = testing.allocator;
    const html = "<div><p>Para 1</p><P>Para 2</P><span>Span</span></div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Lexbor normalizes to uppercase
    const results = try getElementsByTagName(allocator, doc, "P");
    defer allocator.free(results);

    try testing.expect(results.len == 2);
}

test "getElementsById exact matching" {
    const allocator = testing.allocator;
    const html = "<div><p id='test'>Found</p><p id='test-suffix'>Not found</p></div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const results = try getElementsById(allocator, doc, "test");
    defer allocator.free(results);

    try testing.expect(results.len == 1);
    const id_attr = z.getAttribute_zc(results[0], "id").?;
    try testing.expectEqualStrings("test", id_attr);
}

test "getElementsByAttributeName finds any element with attribute" {
    const allocator = testing.allocator;
    const html = "<div><p id='foo'>Has ID</p><span data-value='bar'>Has data</span><div>No attributes</div></div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const id_results = try getElementsByAttributeName(allocator, doc, "id");
    defer allocator.free(id_results);
    try testing.expect(id_results.len == 1);

    const data_results = try getElementsByAttributeName(allocator, doc, "data-value");
    defer allocator.free(data_results);
    try testing.expect(data_results.len == 1);

    const nonexistent_results = try getElementsByAttributeName(allocator, doc, "nonexistent");
    defer allocator.free(nonexistent_results);
    try testing.expect(nonexistent_results.len == 0);
}

test "comparison with CSS selectors" {
    const allocator = testing.allocator;
    const html = "<div><h1 class='title main'>Title</h1><p class='text main-text'>Para</p></div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Walker-based search (token matching)
    const walker_results = try getElementsByClassName(allocator, doc, "main");
    defer allocator.free(walker_results);

    // CSS selector search (token matching, case insensitive)
    const css_results = try z.querySelectorAll(allocator, doc, ".main");
    defer allocator.free(css_results);

    // Both should find the same element(s) - the h1 with "main" token
    try testing.expect(walker_results.len == css_results.len);
    try testing.expect(walker_results.len == 1);

    const walker_class = z.getAttribute_zc(walker_results[0], "class").?;
    const css_class = z.getAttribute_zc(css_results[0], "class").?;
    try testing.expectEqualStrings(walker_class, css_class);
    try testing.expectEqualStrings("title main", walker_class);
}

test "single element functions return first match" {
    const allocator = testing.allocator;
    const html = "<div><h1 class='main'>First</h1><h2 class='main'>Second</h2></div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;

    // Should return first matching element
    const element = getElementByClass(body, "main");
    try testing.expect(element != null);

    const tag = z.tagName_zc(element.?);
    try testing.expectEqualStrings("H1", tag);

    // Non-existent should return null
    const missing = getElementByClass(body, "nonexistent");
    try testing.expect(missing == null);
}

test "getElementById" {
    const allocator = testing.allocator;
    const doc = try z.parseHTML(allocator, "<div id=\"1\"><p ></p><span id=\"2\"></span></div>");
    defer z.destroyDocument(doc);
    const element = getElementById(doc, "2").?;
    try testing.expect(z.tagFromElement(element) == .span);
}

test "getElementByClass" {
    const allocator = testing.allocator;
    const doc = try z.parseHTML(allocator, "<div id=\"1\"><p class=\"test\"></p><span class=\"test\"></span></div>");
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;
    const element = getElementByClass(body, "test");
    try testing.expect(z.tagFromElement(element.?) == .p);
}

test "getElementByAttribute" {
    const allocator = testing.allocator;
    const doc = try z.parseHTML(allocator, "<div id=\"1\" data-test=\"value1\"><p ></p><span data-test=\"value2\"></span></div>");
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;
    const element_2 = getElementByAttribute(body, "data-test", "value2");
    try testing.expect(z.tagFromElement(element_2.?) == .span);
    const element_1 = getElementByAttribute(body, "data-test", null);
    try testing.expect(z.tagFromElement(element_1.?) == .div);
}

test "getElementByDataAttribute" {
    const allocator = testing.allocator;
    const html =
        \\<div id="user" data-id="1234567890" data-user="carinaanand" data-date-of-birth>
        \\Carina Anand
        \\</div>
    ;
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;
    const div = z.nodeToElement(z.firstChild(body).?).?;

    const elt = getElementById(doc, "user").?;
    try testing.expect(div == elt);

    const date_of_birth = try getElementByDataAttribute(
        body,
        "data",
        "date-of-birth",
        null,
    );
    try testing.expect(div == date_of_birth);

    const user = try getElementByDataAttribute(
        body,
        "data",
        "user",
        "carinaanand",
    );
    try testing.expect(user == div);
    try testing.expect(z.hasAttribute(user.?, "data-id"));
}

test "getElementByTag" {
    const allocator = testing.allocator;
    const doc = try z.parseHTML(allocator, "<div id=\"1\"><p class=\"test\"></p><span id=\"2\"></span></div>");
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;
    const element = getElementByTag(body, .span);
    try testing.expectEqualStrings(z.getElementId_zc(element.?), "2");
}

//! DOM Node.normalize() and HTML minification utilities
//!
//! Two distinct operations:
//!
//! 1. `normalizeDOM()` - Standard DOM Node.normalize() behavior:
//!    - Merges adjacent Text nodes into a single Text node
//!    - Removes empty Text nodes (length === 0)
//!    - Does NOT touch comments or whitespace-only nodes
//!
//! 2. `minifyDOM()` - HTML minification (non-standard):
//!    - Removes whitespace-only text nodes (\r, \n, \t)
//!    - Optionally removes comments
//!    - Preserves whitespace in <pre>, <code>, <script>, <style>, <textarea>

const std = @import("std");
const z = @import("../root.zig");
const Err = z.Err;

const testing = std.testing;
const print = std.debug.print;

// ============================================================================
// TRUE DOM Node.normalize() - Merges adjacent text nodes, removes empty ones
// ============================================================================

/// [normalize] Standard DOM Node.normalize() implementation
///
/// Per DOM spec: https://dom.spec.whatwg.org/#dom-node-normalize
/// - Merges adjacent Text nodes into a single Text node
/// - Removes empty Text nodes (textContent.length === 0)
/// - Does NOT touch comments, whitespace-only nodes, or other node types
pub fn normalizeDOM(allocator: std.mem.Allocator, node: *z.DomNode) void {
    normalizeNodeRecursive(allocator, node);
}

/// Normalize an element (convenience wrapper)
pub fn normalizeElement(allocator: std.mem.Allocator, element: *z.HTMLElement) void {
    normalizeDOM(allocator, z.elementToNode(element));
}

/// Returns a normalized serialized DOM string of a document
pub fn normalizeDoc(allocator: std.mem.Allocator, doc: *z.HTMLDocument) ![]const u8 {
    const root = z.documentRoot(doc) orelse return Err.NoDocumentRoot;
    normalizeDOM(allocator, root);
    return try z.outerHTML(allocator, z.nodeToElement(root).?);
}

/// Returns a minified serialized HTML string of a document
pub fn minifyDoc(allocator: std.mem.Allocator, doc: *z.HTMLDocument, options: MinifyOptions) ![]const u8 {
    const root = z.documentRoot(doc) orelse return Err.NoDocumentRoot;
    const root_elt = z.nodeToElement(root) orelse unreachable;
    try minifyDOMwithOptions(allocator, root_elt, options);
    return try z.outerHTML(allocator, root_elt);
}

fn normalizeNodeRecursive(allocator: std.mem.Allocator, node: *z.DomNode) void {
    var child = z.firstChild(node);

    while (child) |current| {
        const next = z.nextSibling(current);

        switch (z.nodeType(current)) {
            .text => {
                const text_content = z.textContent_zc(current);

                // Remove empty text nodes
                if (text_content.len == 0) {
                    z.removeNode(current);
                    z.destroyNode(current);
                    child = next;
                    continue;
                }

                // Merge with following adjacent text nodes
                var merged_next = next;
                while (merged_next) |following| {
                    if (z.nodeType(following) != .text) break;

                    const following_text = z.textContent_zc(following);
                    if (following_text.len > 0) {
                        // Concatenate and replace text in current node
                        const current_text = z.textContent_zc(current);
                        const merged = std.mem.concat(allocator, u8, &.{ current_text, following_text }) catch break;
                        defer allocator.free(merged);
                        z.replaceText(current, merged) catch break;
                    }

                    const after_following = z.nextSibling(following);
                    z.removeNode(following);
                    z.destroyNode(following);
                    merged_next = after_following;
                }

                child = merged_next;
            },
            .element => {
                // Recurse into element children
                normalizeNodeRecursive(allocator, current);
                child = next;
            },
            else => {
                child = next;
            },
        }
    }
}

// ============================================================================
// HTML MINIFICATION - Removes whitespace nodes (non-standard)
// ============================================================================

/// [normalize] Returns true if text contains ONLY whitespace characters (\n\t\r or " ")
pub fn isWhitespaceOnly(text: []const u8) bool {
    if (text.len == 0) return true;

    // Fast path: check against common single-character whitespace
    if (text.len == 1) {
        const char = text[0];
        return char == ' ' or char == '\t' or char == '\n' or char == '\r';
    }

    const data = text.ptr;
    for (0..text.len) |i| {
        const char = data[i];
        if (char != ' ' and char != '\t' and char != '\n' and char != '\r') {
            return false;
        }
    }
    return true;
}

/// Returns true if text contains ONLY the whitespace characters \t or \n or \r
fn isUndesirableWhitespace(text: []const u8) bool {
    if (text.len == 0) return true;

    // Check if text contains ONLY problematic whitespace (\r, \n, \t)
    // These are whitespace characters that browsers collapse anyway
    for (text) |char| {
        if (char != '\r' and char != '\n' and char != '\t') {
            return false; // Contains non-collapsible content
        }
    }
    return true; // All characters are collapsible whitespace
}

test "isWhitespaceOnly & isUndesirableWhitespace" {
    const t1 = "  ";
    std.debug.assert(isWhitespaceOnly(t1));
    std.debug.assert(!isUndesirableWhitespace(t1));

    const t2 = "\n\t\r";
    std.debug.assert(isWhitespaceOnly(t2));
    std.debug.assert(isUndesirableWhitespace(t2));

    const t3 = " \n\t\r";
    std.debug.assert(isWhitespaceOnly(t3));
    std.debug.assert(!isUndesirableWhitespace(t3));

    const t4 = " \n\t\ra";
    std.debug.assert(!isWhitespaceOnly(t4));
    std.debug.assert(!isUndesirableWhitespace(t4));
}

/// convert from "aligned" `anyopaque` to the target pointer type `T`
/// because of the callback signature:
///
/// Source: Andrew Gossage <https://www.youtube.com/watch?v=qJNHUIIFMlo>
fn castContext(comptime T: type, ctx: ?*anyopaque) *T {
    return @as(*T, @ptrCast(@alignCast(ctx.?)));
}

/// [minify] Minify HTML by removing collapsible whitespace
///
/// Removes collapsible whitespace (\r, \n, \t) but preserves meaningful spaces.
/// Always preserves whitespace in special elements (<pre>, <code>, <script>, <style>, <textarea>)
///
/// Use `minifyDOMwithOptions` to customize comment handling.
pub fn minifyDOM(allocator: std.mem.Allocator, root_elt: *z.HTMLElement) (std.mem.Allocator.Error || z.Err)!void {
    return minifyDOMwithOptions(allocator, root_elt, .{});
}

/// [minify] Aggressive minification for clean terminal/display output
///
/// Removes ALL whitespace-only text nodes and comments for clean visual output.
/// Used internally by prettyPrint for clean TTY display.
pub fn minifyDOMForDisplay(allocator: std.mem.Allocator, root_elt: *z.HTMLElement) (std.mem.Allocator.Error || z.Err)!void {
    var context = MinifyContext.init(allocator, .{ .skip_comments = true });
    defer context.deinit();

    z.simpleWalk(
        z.elementToNode(root_elt),
        aggressiveCollectorCallback,
        &context,
    );

    try minifyPostWalkOperations(
        allocator,
        &context,
        .{ .skip_comments = true },
    );
}

pub const MinifyOptions = struct {
    skip_comments: bool = false, // Whether to remove comments
    // Note: Special elements (<pre>, <code>, <script>, <style>, <textarea>) are always preserved
    // Note: Collapsible whitespace (\r, \n, \t) is always removed
};

// Context for the minification walk
// All temporary allocations use arena for single bulk deallocation
const MinifyContext = struct {
    arena: std.heap.ArenaAllocator,
    options: MinifyOptions,

    // post-walk cleanup - uses arena allocator
    nodes_to_remove: std.ArrayListUnmanaged(*z.DomNode),
    template_nodes: std.ArrayListUnmanaged(*z.DomNode),

    // Simple cache for last checked parent (most text nodes share parents)
    last_parent: ?*z.DomNode,
    last_parent_preserves: bool,

    fn init(backing_allocator: std.mem.Allocator, opts: MinifyOptions) @This() {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .options = opts,
            .nodes_to_remove = .empty,
            .template_nodes = .empty,
            .last_parent = null,
            .last_parent_preserves = false,
        };
    }

    /// Single bulk deallocation - arena handles everything
    fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    /// Get arena allocator for all temporary allocations
    inline fn alloc(self: *@This()) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// _Walk-up_ the tree to check if the node is inside a whitespace preserved element.
    /// Uses simple parent caching since adjacent text nodes often share the same parent.
    fn shouldPreserveWhitespace(self: *@This(), node: *z.DomNode) bool {
        const parent = z.parentNode(node) orelse return false;

        // Check simple cache first
        if (self.last_parent == parent) {
            return self.last_parent_preserves;
        }

        // Walk up tree and cache result
        var current: ?*z.DomNode = parent;
        var preserve = false;
        while (current) |p| {
            if (z.nodeToElement(p)) |element| {
                const tag = z.tagFromQualifiedName(z.qualifiedName_zc(element)) orelse break;
                if (z.WhitespacePreserveTagSet.contains(tag)) {
                    preserve = true;
                    break;
                }
            }
            current = z.parentNode(p);
        }

        // Update cache
        self.last_parent = parent;
        self.last_parent_preserves = preserve;
        return preserve;
    }
};

/// [normalize] Normalize the DOM with options `MinifyOptions`.
///
/// - To remove comments, use `skip_comments=true`.
/// - Always preserves whitespace in specific elements (`pre`, `textarea`, `script`, `style`, `code`).
/// - Removes collapsible whitespace (\r, \n, \t) from other elements while preserving meaningful spaces.
pub fn minifyDOMwithOptions(
    allocator: std.mem.Allocator,
    root_elt: *z.HTMLElement,
    options: MinifyOptions,
) (std.mem.Allocator.Error || z.Err)!void {
    var context = MinifyContext.init(allocator, options);
    defer context.deinit();

    z.simpleWalk(
        z.elementToNode(root_elt),
        collectorCallBack,
        &context,
    );

    try minifyPostWalkOperations(
        allocator,
        &context,
        options,
    );
}

/// Browser-like collector callback for standard normalization
/// Removes collapsible whitespace (\r, \n, \t) but preserves meaningful spaces
fn collectorCallBack(node: *z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int {
    const context_ptr: *MinifyContext = castContext(MinifyContext, ctx);

    switch (z.nodeType(node)) {
        .comment => {
            if (context_ptr.options.skip_comments) {
                // collect comments for post-processing
                context_ptr.nodes_to_remove.append(context_ptr.alloc(), node) catch {
                    return z._STOP;
                };
            }
        },
        .element => {
            if (z.isTemplate(node)) {
                // Collect template nodes for post-processing
                context_ptr.template_nodes.append(context_ptr.alloc(), node) catch {
                    return z._STOP;
                };
                return z._CONTINUE;
            }
        },
        .text => {
            // Always preserve whitespace in special elements (<pre>, <script>, etc.)
            if (context_ptr.shouldPreserveWhitespace(node)) {
                return z._CONTINUE;
            }

            // Use zero-copy text access
            const original_content = z.textContent_zc(node);

            // Browser-like behavior: remove collapsible whitespace (\r, \n, \t) but preserve spaces
            if (isUndesirableWhitespace(original_content)) {
                context_ptr.nodes_to_remove.append(context_ptr.alloc(), node) catch {
                    return z._STOP;
                };
            }
        },

        else => {},
    }

    return z._CONTINUE;
}

/// Aggressive collector callback for display/TTY output
/// Removes ALL whitespace-only text nodes (including spaces) and comments for clean visual output
fn aggressiveCollectorCallback(node: *z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int {
    const context_ptr: *MinifyContext = castContext(MinifyContext, ctx);

    switch (z.nodeType(node)) {
        .comment => {
            // Always remove comments for clean display
            context_ptr.nodes_to_remove.append(context_ptr.alloc(), node) catch {
                return z._STOP;
            };
        },
        .element => {
            if (z.isTemplate(node)) {
                // Collect template nodes for post-processing
                context_ptr.template_nodes.append(context_ptr.alloc(), node) catch {
                    return z._STOP;
                };
                return z._CONTINUE;
            }
        },
        .text => {
            // Always preserve whitespace in special elements (<pre>, <script>, etc.)
            if (context_ptr.shouldPreserveWhitespace(node)) {
                return z._CONTINUE;
            }

            // Use zero-copy text access
            const original_content = z.textContent_zc(node);

            // Aggressive: remove ALL whitespace-only text nodes (including spaces)
            if (isWhitespaceOnly(original_content)) {
                context_ptr.nodes_to_remove.append(context_ptr.alloc(), node) catch {
                    return z._STOP;
                };
            }
        },

        else => {},
    }

    return z._CONTINUE;
}

fn minifyPostWalkOperations(
    allocator: std.mem.Allocator,
    context: *MinifyContext,
    options: MinifyOptions,
) (std.mem.Allocator.Error || z.Err)!void {
    // Remove whitespace-only text nodes and comments if selected
    for (context.nodes_to_remove.items) |node| {
        z.removeNode(node);
        z.destroyNode(node);
    }

    // Process template content with its own "simple_walk" on the document fragment content
    for (context.template_nodes.items) |template_node| {
        try minifyTemplateContent(
            allocator,
            template_node,
            options,
        );
    }
}

/// simple_walk in the template _content_ (#document-fragment)
fn minifyTemplateContent(
    allocator: std.mem.Allocator,
    template_node: *z.DomNode,
    options: MinifyOptions,
) (std.mem.Allocator.Error || z.Err)!void {
    const template = z.nodeToTemplate(template_node) orelse return;

    const content_node = z.templateContent(template);

    var template_context = MinifyContext.init(allocator, options);
    defer template_context.deinit();

    z.simpleWalk(
        content_node,
        collectorCallBack,
        &template_context,
    );

    try minifyPostWalkOperations(
        allocator,
        &template_context,
        options,
    );
}

test "first minification test - whitespaceOnly text nodes removal" {
    const allocator = testing.allocator;

    // Create HTML with various whitespace types
    const html = "<div>\r<p>Text</p>\r\n<span> Regular space </span>\n\t<em>Tab and newline</em>\r</div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const body_elt = z.bodyElement(doc).?;

    // Minification: removes collapsible whitespace
    try minifyDOM(allocator, body_elt);

    const result = try z.innerHTML(allocator, body_elt);
    defer allocator.free(result);

    // Should remove \r, \n, \t patterns but preserve meaningful spaces
    const expected = "<div><p>Text</p><span> Regular space </span><em>Tab and newline</em></div>";
    try testing.expectEqualStrings(expected, result);
}

// multiline version
test "normalizeOptions: preserve script and remove whitespace text nodes" {
    const allocator = testing.allocator;
    const html =
        \\<div>
        \\  <!-- a comment -->
        \\  <script> console.log("hello"); </script>
        \\  <pre>  Preserve   spaces  </pre>
        \\  <div> Some <i> bold and italic   </i> text</div>
        \\</div>
    ;
    // whitespace preserved in script element and in elements, empty text nodes removed
    {
        const doc = try z.parseHTML(allocator, html);
        defer z.destroyDocument(doc);

        const body_elt = z.bodyElement(doc).?;

        try z.minifyDOMwithOptions(
            allocator,
            body_elt,
            .{
                .skip_comments = false,
            },
        );

        const serialized = try z.innerHTML(allocator, body_elt);
        defer allocator.free(serialized);

        // only whitespace-only text nodes should be removed
        const expected =
            \\<div>
            \\  <!-- a comment -->
            \\  <script> console.log("hello"); </script>
            \\  <pre>  Preserve   spaces  </pre>
            \\  <div> Some <i> bold and italic   </i> text</div></div>
        ;

        try testing.expectEqualStrings(expected, serialized);
    }
    // comment removal: leaves whitespace characters as they were
    {
        const doc = try z.parseHTML(allocator, html);
        defer z.destroyDocument(doc);

        const body_elt = z.bodyElement(doc).?;

        try z.minifyDOMwithOptions(
            allocator,
            body_elt,
            .{
                .skip_comments = true,
            },
        );

        const serialized = try z.innerHTML(allocator, body_elt);
        defer allocator.free(serialized);

        // the whitespace characters before the comment are maintained
        const expected =
            \\<div>
            \\  
            \\  <script> console.log("hello"); </script>
            \\  <pre>  Preserve   spaces  </pre>
            \\  <div> Some <i> bold and italic   </i> text</div></div>
        ;

        try testing.expectEqualStrings(expected, serialized);
    }
}

test "normalization for display: removal of comments don't leave empty text node" {
    const allocator = testing.allocator;
    const html =
        \\<div>
        \\  <!-- comment -->
        \\  <p>Text</p>
        \\  <span> Keep spaces </span>
        \\</div>
    ;

    // const html = "<div><!-- comment -->\n<p>Text</p> \n<span> Keep spaces </span>\t</div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const body_elt = z.bodyElement(doc).?;

    // Aggressive normalization for display
    try minifyDOMForDisplay(allocator, body_elt);

    const result = try z.innerHTML(allocator, body_elt);
    defer allocator.free(result);

    // Should remove comments and ALL whitespace-only nodes (including spaces)
    const expected = "<div><p>Text</p><span> Keep spaces </span></div>";
    try testing.expectEqualStrings(expected, result);
}
// TODO
test "template normalize" {
    const allocator = testing.allocator;

    const html =
        \\<div>
        \\  <p>Before template</p>
        \\  <template id="test">
        \\  <!-- comment in template -->
        \\  <span>  Template content  </span><em>  </em>
        \\  <strong>  Bold text</strong>
        \\  </template>
        \\  <p>After template</p>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const root = z.documentRoot(doc).?;

    try z.minifyDOMwithOptions(
        allocator,
        z.nodeToElement(root).?,
        .{
            .skip_comments = true,
        },
    );

    const serialized = try z.outerHTML(allocator, z.nodeToElement(root).?);
    defer allocator.free(serialized);

    const expected =
        \\<html><head></head><body><div>
        \\  <p>Before template</p>
        \\  <template id="test">
        \\  
        \\  <span>  Template content  </span><em>  </em>
        \\  <strong>  Bold text</strong>
        \\  </template>
        \\  <p>After template</p></div></body></html>
    ;

    try testing.expectEqualStrings(expected, serialized);
}

test "string vs DOM minification" {
    const allocator = testing.allocator;
    const messy_html =
        \\<div>
        \\<!-- comment -->
        \\
        \\<p>Content</p>
        \\
        \\<pre>  preserve  this  </pre>
        \\
        \\</div>
    ;
    {
        const doc = try z.parseHTML(allocator, messy_html);
        defer z.destroyDocument(doc);
        const body_elt = z.bodyElement(doc).?;
        try z.minifyDOM(allocator, body_elt);
        const result = try z.innerHTML(allocator, body_elt);
        defer allocator.free(result);
        const expected = "<div><!-- comment --><p>Content</p><pre>  preserve  this  </pre></div>";
        try testing.expectEqualStrings(expected, result);
    }
    {
        const cleaned = try z.minifyHtmlStringWithOptions(
            allocator,
            messy_html,
            .{ .remove_comments = false },
        );
        defer allocator.free(cleaned);

        const expected = "<div><!-- comment --><p>Content</p><pre>  preserve  this  </pre></div>";
        try testing.expectEqualStrings(expected, cleaned);

        {
            const doc = try z.parseHTML(allocator, cleaned);
            defer z.destroyDocument(doc);
            const body_elt = z.bodyElement(doc).?;
            const result = try z.innerHTML(allocator, body_elt);
            defer allocator.free(result);
            try testing.expectEqualStrings(expected, result);
        }
        {
            const doc = try z.parseHTML(allocator, messy_html);
            defer z.destroyDocument(doc);
            const body_elt2 = z.bodyElement(doc).?;
            try z.minifyDOM(allocator, body_elt2);
            const result2 = try z.innerHTML(allocator, body_elt2);
            defer allocator.free(result2);
            try testing.expectEqualStrings(expected, result2);
        }
    }
}

test "true DOM normalize - merge adjacent text nodes" {
    const allocator = testing.allocator;

    // Create a document with adjacent text nodes (simulate dynamic DOM manipulation)
    const doc = try z.parseHTML(allocator, "<div></div>");
    defer z.destroyDocument(doc);

    const div = z.firstElementChild(z.bodyElement(doc).?).?;
    const div_node = z.elementToNode(div);

    // Manually create adjacent text nodes by adding them one after another
    const text1 = try z.createTextNode(doc, "Hello ");
    const text2 = try z.createTextNode(doc, "World");
    const text3 = try z.createTextNode(doc, "!");

    z.appendChild(div_node, text1);
    z.appendChild(div_node, text2);
    z.appendChild(div_node, text3);

    // Before normalize: 3 text nodes
    var count: usize = 0;
    var child = z.firstChild(div_node);
    while (child) |c| : (child = z.nextSibling(c)) {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);

    // Normalize: merges adjacent text nodes
    normalizeDOM(allocator, div_node);

    // After normalize: 1 text node with merged content
    count = 0;
    child = z.firstChild(div_node);
    while (child) |c| : (child = z.nextSibling(c)) {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);

    // Check merged content using textContent (not innerHTML since no element children)
    const result = z.textContent_zc(div_node);
    try testing.expectEqualStrings("Hello World!", result);
}

test "true DOM normalize - removes empty text nodes" {
    const allocator = testing.allocator;

    const doc = try z.parseHTML(allocator, "<div></div>");
    defer z.destroyDocument(doc);

    const div = z.firstElementChild(z.bodyElement(doc).?).?;
    const div_node = z.elementToNode(div);

    // Create text nodes including empty ones
    const text1 = try z.createTextNode(doc, "Hello");
    const empty = try z.createTextNode(doc, "");
    const text2 = try z.createTextNode(doc, " World");

    z.appendChild(div_node, text1);
    z.appendChild(div_node, empty);
    z.appendChild(div_node, text2);

    // Normalize: removes empty, merges adjacent
    normalizeDOM(allocator, div_node);

    // Check merged content using textContent
    const result = z.textContent_zc(div_node);
    try testing.expectEqualStrings("Hello World", result);
}
test "normalizeDOM merges text nodes across elements" {
    const allocator = testing.allocator;
    const doc = try z.parseHTML(allocator, "<div>Hello<span> World</span>!</div>");
    defer z.destroyDocument(doc);

    const div = z.firstElementChild(z.bodyElement(doc).?).?;
    normalizeDOM(allocator, z.elementToNode(div));

    // Text nodes inside span shouldn't merge with text outside span
    const inner_result = try z.innerHTML(allocator, div);
    defer allocator.free(inner_result);

    try testing.expectEqualStrings("Hello<span> World</span>!", inner_result);
    const outer_result = try z.outerHTML(allocator, div);
    defer allocator.free(outer_result);
    try testing.expectEqualStrings("<div>Hello<span> World</span>!</div>", outer_result);
}

test "normalizeDoc merges adjacent text nodes in full document" {
    const allocator = testing.allocator;

    // Create a document with adjacent text nodes
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <div>Hello</div>
        \\  <div>World</div>
        \\</body>
        \\</html>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Create adjacent text nodes in first div
    const first_div = try z.querySelector(allocator, doc, "div");
    const div_node = z.elementToNode(first_div.?);

    // Add adjacent text nodes
    const text1 = try z.createTextNode(doc, "Hi ");
    const text2 = try z.createTextNode(doc, "there!");
    z.appendChild(div_node, text1);
    z.appendChild(div_node, text2);

    // Use normalizeDoc on entire document
    const result = try normalizeDoc(allocator, doc);
    defer allocator.free(result);

    // Check that text nodes were merged
    const merged_text = z.textContent_zc(z.elementToNode(first_div.?));
    try testing.expectEqualStrings("HelloHi there!", merged_text);

    // Check full document still has structure
    try testing.expect(std.mem.indexOf(u8, result, "<html>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<body>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<div>") != null);
}

test "minifyDoc removes whitespace from full document" {
    const allocator = testing.allocator;

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>Test</title>
        \\</head>
        \\<body>
        \\  <div>
        \\    <!-- Comment to keep or remove -->
        \\    <p>Some text</p>
        \\    \t\n\r
        \\    <pre>  preserve   this  </pre>
        \\  </div>
        \\</body>
        \\</html>
    ;

    // Test with comments preserved
    {
        const doc = try z.parseHTML(allocator, html);
        defer z.destroyDocument(doc);

        const result = try minifyDoc(allocator, doc, .{ .skip_comments = false });
        defer allocator.free(result);

        // Should keep comment, remove \t\n\r, preserve <pre> whitespace
        try testing.expect(std.mem.indexOf(u8, result, "<!-- Comment") != null);
        try testing.expect(std.mem.indexOf(u8, result, "\t\n\r") == null);
        try testing.expect(std.mem.indexOf(u8, result, "  preserve   this  ") != null);
    }

    // Test with comments removed
    {
        const doc = try z.parseHTML(allocator, html);
        defer z.destroyDocument(doc);

        const result = try minifyDoc(allocator, doc, .{ .skip_comments = true });
        defer allocator.free(result);

        // Should remove comment
        try testing.expect(std.mem.indexOf(u8, result, "<!-- Comment") == null);
    }
}

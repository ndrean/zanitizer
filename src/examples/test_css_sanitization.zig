const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    try demo_css_sanitization1(allocator);

    try demo_framework_sanitization(allocator);
    try demo_svg_sanitization(allocator);
    // try demo_sanitizer_config(allocator);
    try stylesheet(allocator);
}

fn demo_css_sanitization1(allocator: std.mem.Allocator) !void {
    const dirty_html =
        \\<style>
        \\  body { background: url(javascript:alert('xss')); }
        \\  div { -moz-binding: url("http://evil.com/xss.xml#xss"); }
        \\  p { behavior: url(#default#something); }
        \\  span { color: red; font-size: 16px; } /* safe */
        \\</style>
        \\<div style="background: expression(alert('xss')); color: blue;">
        \\  Content with dangerous inline style
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, dirty_html);
    defer z.destroyDocument(doc);

    const body = z.bodyNode(doc).?;
    try z.prettyPrint(allocator, body);

    // Initialize CSS sanitizer for inline style cleaning
    var css_san = try z.CssSanitizer.init(allocator, .{});
    defer css_san.deinit();

    // Sanitize with CSS-aware cleaning (keeps styles but removes threats)
    try z.sanitizeWithCss(allocator, body, .{
        .custom = .{
            .remove_styles = false, // Keep <style> but sanitize content
            .sanitize_inline_styles = true,
        },
    }, &css_san);

    try z.prettyPrint(allocator, body);
    // Output: <style> block has only "span { color: red; font-size: 16px; }"
    // Output: div has style="color: blue" (expression() removed)
}

fn demo_framework_sanitization(allocator: std.mem.Allocator) !void {
    const html =
        \\<div x-data="{ open: false }" 
        \\     x-show="open" 
        \\     @click="open = !open"
        \\     onclick="alert('XSS')">
        \\  <button hx-get="/api/data" 
        \\          hx-target="#result"
        \\          onmouseover="steal()">
        \\    Load Data
        \\  </button>
        \\  <span v-if="show" 
        \\        :class="{ active: isActive }"
        \\        onfocus="evil()">
        \\    {{ message }}
        \\  </span>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;
    try z.prettyPrint(allocator, body);

    try z.sanitizePermissive(allocator, z.bodyNode(doc).?);

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // ✅ Preserved: x-data, x-show, @click, hx-get, hx-target, v-if, :class
    // ❌ Removed: onclick, onmouseover, onfocus
    z.print("{s}\n", .{result});
    // try z.prettyPrint(allocator, body);
}

fn demo_sanitizer_config(allocator: std.mem.Allocator) !void {
    // Scenario: CMS accepting user content with HTMX only
    const config = z.SanitizerConfig{
        .frameworks = .{
            .allow_htmx = true,
            .allow_alpine = false, // Block Alpine
            .allow_vue = false, // Block Vue
        },
        .removeElements = &[_][]const u8{ "script", "iframe", "object" },
        .dataAttributes = true, // Allow data-*
        .comments = false, // Strip comments
    };

    try config.validate(); // Catches invalid configs

    const sanitizer = try z.Sanitizer.init(allocator, config);
    defer sanitizer.deinit();

    const dirty =
        \\<div hx-get="/api" x-data="{}" v-if="true" data-id="123">
        \\  <!-- secret comment -->
        \\  <script>alert('xss')</script>
        \\  Content
        \\</div>
    ;

    const clean = try sanitizer.sanitize(dirty);
    defer allocator.free(clean);
    // Result: <div hx-get="/api" data-id="123">Content</div>
}

fn demo_svg_sanitization(allocator: std.mem.Allocator) !void {
    const html =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
        \\  <circle cx="50" cy="50" r="40" fill="red"/>
        \\  <script>alert('xss')</script>
        \\  <foreignObject><body onload="evil()"/></foreignObject>
        \\  <animate attributeName="href" to="javascript:alert()"/>
        \\  <use xlink:href="javascript:attack()"/>
        \\  <rect x="10" y="10" width="80" height="80" fill="blue"/>
        \\</svg>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;
    try z.prettyPrint(allocator, body);

    try z.sanitizeStrict(allocator, z.bodyNode(doc).?);

    // Result: Only <circle> and <rect> remain
    // Removed: <script>, <foreignObject>, <animate>, dangerous xlink:href
    try z.prettyPrint(allocator, body);
}

fn stylesheet(allocator: std.mem.Allocator) !void {
    const dirty_html =
        \\<html>
        \\<head>
        \\  <style>
        \\    body { background: url(javascript:alert('xss')); }
        \\    .danger { -moz-binding: url("http://evil.com/xss.xml#xss"); }
        \\    .exploit { behavior: url(#default#something); }
        \\    .safe { color: red; font-size: 16px; margin: 10px; }
        \\    p { expression(alert('xss')); padding: 5px; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="safe" style="background: expression(alert('xss')); border: 1px solid black;">
        \\    Safe content with dangerous inline style
        \\  </div>
        \\  <p class="danger">This paragraph has dangerous class styles</p>
        \\</body>
        \\</html>
    ;

    const doc = try z.parseHTML(allocator, dirty_html);
    defer z.destroyDocument(doc);

    z.print("\n\n", .{});
    z.print("\n=== Initial DOM ===\n", .{});
    try z.prettyPrint(allocator, z.documentRoot(doc).?);

    // --

    var css_san = try z.CssSanitizer.init(allocator, .{});
    defer css_san.deinit();
    try z.sanitizeWithCss(allocator, z.documentRoot(doc).?, .{
        .custom = .{
            .remove_styles = false, // Keep <style> but sanitize content
            .sanitize_inline_styles = true, // Clean inline style="" attributes
        },
    }, &css_san);

    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);
    defer z.destroyDocumentStylesheets(doc);
    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);
    try z.loadStyleTags(allocator, doc, parser);

    z.print("=== After Sanitization ===\n", .{});
    // Show the cleaned <style> content
    if (try z.querySelector(allocator, doc, "style")) |style_el| {
        z.print("<style> content:\n{s}\n\n", .{z.textContent_zc(z.elementToNode(style_el))});
    }

    // Show the div's inline style was also cleaned
    if (try z.querySelector(allocator, doc, "div.safe")) |div| {
        const style_attr = z.getAttribute_zc(div, "style") orelse "(none)";
        z.print("div.safe style attribute: \"{s}\"\n\n", .{style_attr});
    }

    // Demonstrate that lexbor correctly attached the cleaned styles
    if (try z.querySelector(allocator, doc, "div.safe")) |div| {
        const color = try z.getComputedStyle(allocator, div, "color");
        const font_size = try z.getComputedStyle(allocator, div, "font-size");
        defer if (color) |c| allocator.free(c);
        defer if (font_size) |f| allocator.free(f);
        z.print("Computed styles on div.safe:\n", .{});
        z.print("  color: {s}\n", .{color orelse "(not set)"});
        z.print("  font-size: {s}\n", .{font_size orelse "(not set)"});
    }

    z.print("\n=== Full final DOM ===\n", .{});
    try z.printDoc(allocator, doc, "Cleaned CSS");
}

const std = @import("std");
const z = @import("zexplorer");

// =============================================================================
// COMPLETE CSS & SANITIZATION PATHWAY TEST
// =============================================================================
//
// This file demonstrates ALL pathways through the CSS sanitization system.
// It serves as both documentation and validation of the current API.
//
// TWO SEPARATE CONCERNS:
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ 1. SANITIZATION (Security)                                              │
// │    - CssSanitizer: Cleans CSS text to remove XSS vectors               │
// │    - sanitizeWithCss(): Walks DOM, cleans <style> content & style=""   │
// │    - Rules defined in html_spec.zig (DANGEROUS_CSS_*, SAFE_CSS_*)      │
// │                                                                         │
// │ 2. CSS ENGINE (Functionality)                                           │
// │    - Lexbor CSS: Parses CSS into rules, attaches to elements           │
// │    - initDocumentCSS(): Start watching for style changes               │
// │    - loadStyleTags(): Parse <style> content into engine                │
// │    - getComputedStyle(): Query effective style on element              │
// └─────────────────────────────────────────────────────────────────────────┘
//
// CRITICAL INSIGHT: Sanitization modifies DOM TEXT. CSS engine parses TEXT.
// If CSS engine parses BEFORE sanitization, it caches the DIRTY rules!
//
// =============================================================================

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    z.print("\n" ++ "=" ** 70 ++ "\n", .{});
    z.print("  COMPLETE CSS & SANITIZATION PATHWAY TESTS\n", .{});
    z.print("=" ** 70 ++ "\n\n", .{});

    // =========================================================================
    // PATHWAY 1: Trusted HTML (No sanitization needed)
    // =========================================================================
    z.print("━━━ PATHWAY 1: Trusted HTML ━━━\n", .{});
    z.print("Use when: You control the HTML source (templates, static content)\n\n", .{});
    try pathway1_trusted_html(allocator);

    // =========================================================================
    // PATHWAY 2: Untrusted HTML with full sanitization
    // =========================================================================
    z.print("\n━━━ PATHWAY 2: Untrusted HTML (Full Sanitization) ━━━\n", .{});
    z.print("Use when: User-generated content, external HTML\n\n", .{});
    try pathway2_untrusted_full_sanitize(allocator);

    // =========================================================================
    // PATHWAY 3: Untrusted HTML, keep styles but sanitize them
    // =========================================================================
    z.print("\n━━━ PATHWAY 3: Keep Styles, Sanitize Content ━━━\n", .{});
    z.print("Use when: Allow user styling but remove XSS vectors\n\n", .{});
    try pathway3_sanitize_keep_styles(allocator);

    // =========================================================================
    // PATHWAY 4: External CSS file (not in DOM)
    // =========================================================================
    z.print("\n━━━ PATHWAY 4: External CSS File ━━━\n", .{});
    z.print("Use when: Loading CSS from files/network\n\n", .{});
    try pathway4_external_css(allocator);

    // =========================================================================
    // PATHWAY 5: Dynamic style manipulation
    // =========================================================================
    z.print("\n━━━ PATHWAY 5: Dynamic Style Manipulation ━━━\n", .{});
    z.print("Use when: JavaScript-like programmatic style changes\n\n", .{});
    try pathway5_dynamic_styles(allocator);

    // =========================================================================
    // PATHWAY 6: Framework attributes with sanitization
    // =========================================================================
    z.print("\n━━━ PATHWAY 6: Framework Attributes ━━━\n", .{});
    z.print("Use when: HTMX, Alpine, Vue, Phoenix LiveView content\n\n", .{});
    try pathway6_framework_attrs(allocator);

    z.print("\n" ++ "=" ** 70 ++ "\n", .{});
    z.print("  ALL PATHWAYS COMPLETE\n", .{});
    z.print("=" ** 70 ++ "\n", .{});
}

// =============================================================================
// PATHWAY 1: Trusted HTML
// =============================================================================
// Order: createDocument → initDocumentCSS → insertHTML → use
// CSS engine watches from the start, no sanitization needed.

fn pathway1_trusted_html(allocator: std.mem.Allocator) !void {
    const html =
        \\<html>
        \\<head>
        \\  <style>
        \\    .highlight { color: blue; font-weight: bold; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="highlight" style="padding: 10px;">Trusted content</div>
        \\</body>
        \\</html>
    ;

    // Step 1: Create document
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // Step 2: Init CSS engine FIRST (will watch insertHTML)
    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    // Step 3: Insert HTML (CSS engine sees style="" as it's parsed)
    try z.insertHTML(doc, html);

    // Step 4: Load <style> tags into engine
    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);
    try z.loadStyleTags(allocator, doc, parser);

    // Step 5: Query styles - works immediately
    if (try z.querySelector(allocator, doc, ".highlight")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        const padding = try z.getComputedStyle(allocator, el, "padding");
        defer if (padding) |p| allocator.free(p);

        z.print("  .highlight color: {s}\n", .{color orelse "(none)"});
        z.print("  .highlight padding: {s}\n", .{padding orelse "(none)"});
    }

    z.print("  ✓ Trusted pathway: CSS engine watched from start\n", .{});
}

// =============================================================================
// PATHWAY 2: Untrusted HTML - Full Sanitization
// =============================================================================
// Order: createDocument → insertHTML → sanitize → (optionally init CSS)
// Removes scripts, styles, dangerous attributes.

fn pathway2_untrusted_full_sanitize(allocator: std.mem.Allocator) !void {
    const dirty_html =
        \\<html>
        \\  <style>.evil { behavior: url(evil.htc); color: red; }</style>
        \\<body>
        \\  <script>alert('XSS')</script>
        \\  <div onclick="steal()" style="expression(alert(1))" class="evil">
        \\    User content
        \\  </div>
        \\  <img src="javascript:attack()" onerror="evil()">
        \\</body>
        \\</html>
    ;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // Step 1: Insert HTML (NO CSS engine yet!)
    try z.insertHTML(doc, dirty_html);

    z.print("  BEFORE sanitization:\n", .{});
    const before = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(before);
    z.print("    {s}...\n", .{before[0..@min(before.len, 80)]});

    // Step 2: Sanitize with STRICT mode (removes <script>, <style>, etc.)
    try z.sanitizeStrict(allocator, z.bodyNode(doc).?);

    z.print("  AFTER sanitization:\n", .{});
    const after = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(after);
    z.print("    {s}\n", .{after});

    // Verify dangerous content removed
    std.debug.assert(std.mem.indexOf(u8, after, "<script>") == null);
    std.debug.assert(std.mem.indexOf(u8, after, "<style>") == null);
    std.debug.assert(std.mem.indexOf(u8, after, "onclick") == null);
    std.debug.assert(std.mem.indexOf(u8, after, "onerror") == null);
    std.debug.assert(std.mem.indexOf(u8, after, "javascript:") == null);

    try z.initDocumentCSS(doc, false);
    defer z.destroyDocumentCSS(doc);

    // check if styles are present
    const div = try z.querySelector(allocator, doc, ".evil");
    try z.parseElementStyle(div.?);
    const color = try z.getComputedStyle(allocator, div.?, "color");
    try std.testing.expect(color == null);
    z.print("  Computed color on .evil: {s}\n", .{color orelse "(none)"});

    // try z.printDoc(allocator, doc, "");
    z.print("  ✓ Full sanitization: all dangerous content removed\n", .{});
}

// =============================================================================
// PATHWAY 3: Keep Styles but Sanitize Their Content
// =============================================================================
// Order: createDocument → insertHTML → sanitizeWithCss → initDocumentCSS → loadStyleTags
// Keeps <style> elements but removes dangerous CSS properties/values.

fn pathway3_sanitize_keep_styles(allocator: std.mem.Allocator) !void {
    const html =
        \\<html>
        \\<head>
        \\  <style>
        \\    .safe { color: green; font-size: 16px; }
        \\    .dangerous { behavior: url(evil.htc); -moz-binding: url(xss.xml); }
        \\    .mixed { padding: 10px; expression(alert('xss')); margin: 5px; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="safe" style="background: expression(evil()); border: 1px solid blue;">
        \\    Content with mixed inline style
        \\  </div>
        \\</body>
        \\</html>
    ;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // Step 1: Insert HTML (no CSS engine yet)
    try z.insertHTML(doc, html);

    // Step 2: Create CSS sanitizer
    var css_san = try z.CssSanitizer.init(allocator, .{});
    defer css_san.deinit();

    // Step 3: Sanitize with CSS-aware mode
    // z.print("{s}\n", .{z.nodeName_zc(z.documentRoot(doc).?)}); // is HTML
    try z.sanitizeWithCss(allocator, z.documentRoot(doc).?, .{
        .custom = .{
            .remove_styles = false, // Keep <style> elements
            .sanitize_inline_styles = true, // But sanitize their content
        },
    }, &css_san);

    // Step 4: Show sanitized <style> content
    if (try z.querySelector(allocator, doc, "style")) |style_el| {
        const css_content = z.textContent_zc(z.elementToNode(style_el));
        z.print("  <style> after sanitization:\n", .{});
        z.print("    {s}\n", .{css_content[0..@min(css_content.len, 100)]});

        // Verify dangerous CSS removed
        std.debug.assert(std.mem.indexOf(u8, css_content, "behavior") == null);
        std.debug.assert(std.mem.indexOf(u8, css_content, "-moz-binding") == null);
        // Safe CSS preserved
        std.debug.assert(std.mem.indexOf(u8, css_content, "color: green") != null);
    }

    // Step 5: Show sanitized inline style as 'attributes' only (no styles)
    if (try z.querySelector(allocator, doc, ".safe")) |el| {
        const style_attr = z.getAttribute_zc(el, "style") orelse "(none)";
        z.print("  .safe style=\"{s}\"\n", .{style_attr});

        // Verify expression() removed, border kept
        std.debug.assert(std.mem.indexOf(u8, style_attr, "expression") == null);
        std.debug.assert(std.mem.indexOf(u8, style_attr, "border") != null);

        // checkc that no Lexbor style applied yet
        const styles = try z.serializeElementStyles(allocator, el);
        defer allocator.free(styles);
        try std.testing.expect(std.mem.indexOf(u8, styles, "color") == null);
    }

    // Step 6: NOW init CSS engine (sees only clean CSS)
    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);
    try z.loadStyleTags(allocator, doc, parser);

    // Step 7: getComputedStyle works with clean rules
    if (try z.querySelector(allocator, doc, ".safe")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        z.print("  Computed color on .safe: {s}\n", .{color orelse "(none)"});

        const styles = try z.serializeElementStyles(allocator, el);
        defer allocator.free(styles);
        z.print(".  Styles are: {s}\n", .{styles});
    }

    z.print("  ✓ Styles kept and sanitized, CSS engine has only clean rules\n", .{});
}

// =============================================================================
// PATHWAY 4: External CSS File
// =============================================================================
// For CSS that comes from a file or network (not in DOM).
// Order: CssSanitizer.sanitizeStylesheet → parseStylesheet → attachStylesheet

fn pathway4_external_css(allocator: std.mem.Allocator) !void {
    // Simulated external CSS file content
    const external_css =
        \\.header { color: navy; font-size: 24px; }
        \\.exploit { -moz-binding: url("http://evil.com/xss.xml#payload"); }
        \\@import url('https://evil.com/inject.css');
        \\.footer { padding: 20px; background: #f0f0f0; }
    ;

    // Step 1: Sanitize the CSS string
    var css_san = try z.CssSanitizer.init(allocator, .{});
    defer css_san.deinit();

    const clean_css = try css_san.sanitizeStylesheet(external_css);
    defer allocator.free(clean_css);

    z.print("  Original CSS length: {d} bytes\n", .{external_css.len});
    z.print("  Sanitized CSS length: {d} bytes\n", .{clean_css.len});
    z.print("  Sanitized CSS:\n    {s}\n", .{clean_css});

    // Verify dangerous parts removed
    std.debug.assert(std.mem.indexOf(u8, clean_css, "@import") == null);
    std.debug.assert(std.mem.indexOf(u8, clean_css, "-moz-binding") == null);
    // Safe parts preserved
    std.debug.assert(std.mem.indexOf(u8, clean_css, "color: navy") != null);
    std.debug.assert(std.mem.indexOf(u8, clean_css, "padding: 20px") != null);

    // Step 2: Create document with HTML first
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    // Insert HTML first (element must exist before stylesheet rules applied)
    try z.insertHTML(doc, "<html><body><div class='header'>Title</div></body></html>");

    // Step 3: Attach sanitized stylesheet (rules apply to existing elements)
    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);

    const sst = try z.createStylesheet();
    defer z.destroyStylesheet(sst);

    try z.parseStylesheet(sst, parser, clean_css);
    try z.attachStylesheet(doc, sst);

    // Step 4: Verify styles applied
    if (try z.querySelector(allocator, doc, ".header")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        z.print("  .header color from external CSS: {s}\n", .{color orelse "(none)"});
    }

    z.print("  ✓ External CSS sanitized and attached\n", .{});
}

// =============================================================================
// PATHWAY 5: Dynamic Style Manipulation
// =============================================================================
// Programmatic style changes (like JavaScript element.style.color = "red")

fn pathway5_dynamic_styles(allocator: std.mem.Allocator) !void {
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // Must init CSS engine for dynamic styles to work
    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    try z.insertHTML(doc, "<html><body><div id='box'>Box</div></body></html>");

    const box = (try z.querySelector(allocator, doc, "#box")).?;

    // Method 1: setAttribute("style", ...)
    z.print("  Method 1: setAttribute\n", .{});
    try z.setAttribute(box, "style", "color: red; padding: 5px;");
    {
        const color = try z.getComputedStyle(allocator, box, "color");
        defer if (color) |c| allocator.free(c);
        z.print("    color after setAttribute: {s}\n", .{color orelse "(none)"});
    }

    // Method 2: setStyleProperty (JS-like: element.style.color = "blue")
    z.print("  Method 2: setStyleProperty\n", .{});
    try z.setStyleProperty(allocator, box, "color", "blue");
    {
        const color = try z.getComputedStyle(allocator, box, "color");
        defer if (color) |c| allocator.free(c);
        z.print("    color after setStyleProperty: {s}\n", .{color orelse "(none)"});
    }

    // Method 3: Remove a property
    z.print("  Method 3: removeInlineStyleProperty\n", .{});
    try z.removeInlineStyleProperty(allocator, box, "padding");
    const padding = try z.getComputedStyle(allocator, box, "padding");
    defer if (padding) |p| allocator.free(p);
    z.print("    padding after removal: {s}\n", .{padding orelse "(none)"});

    // Verify style attribute reflects changes
    const style_attr = z.getAttribute_zc(box, "style") orelse "(none)";
    z.print("    Final style attribute: \"{s}\"\n", .{style_attr});

    z.print("  ✓ Dynamic style manipulation works\n", .{});
}

// =============================================================================
// PATHWAY 6: Framework Attributes
// =============================================================================
// HTMX, Alpine, Vue, Phoenix LiveView attributes with sanitization

fn pathway6_framework_attrs(allocator: std.mem.Allocator) !void {
    const html =
        \\<div x-data="{ open: false }"
        \\     x-show="open"
        \\     hx-get="/api/data"
        \\     hx-target="#result"
        \\     phx-click="update"
        \\     v-if="show"
        \\     onclick="alert('XSS')"
        \\     onmouseover="steal()">
        \\  Framework content
        \\</div>
    ;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    try z.insertHTML(doc, html);

    z.print("  BEFORE sanitization (permissive mode):\n", .{});

    // Permissive mode: keeps framework attrs, removes traditional event handlers
    try z.sanitizePermissive(allocator, z.bodyNode(doc).?);

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    z.print("  AFTER sanitization:\n    {s}\n", .{result});

    // Framework attributes preserved
    std.debug.assert(std.mem.indexOf(u8, result, "x-data") != null);
    std.debug.assert(std.mem.indexOf(u8, result, "x-show") != null);
    std.debug.assert(std.mem.indexOf(u8, result, "hx-get") != null);
    std.debug.assert(std.mem.indexOf(u8, result, "hx-target") != null);
    std.debug.assert(std.mem.indexOf(u8, result, "phx-click") != null);
    std.debug.assert(std.mem.indexOf(u8, result, "v-if") != null);

    // Traditional event handlers removed
    std.debug.assert(std.mem.indexOf(u8, result, "onclick") == null);
    std.debug.assert(std.mem.indexOf(u8, result, "onmouseover") == null);

    z.print("  ✓ Framework attrs preserved, event handlers removed\n", .{});

    // Compare with STRICT mode
    z.print("\n  Comparison with STRICT mode:\n", .{});
    const doc2 = try z.createDocument();
    defer z.destroyDocument(doc2);
    try z.insertHTML(doc2, html);
    try z.sanitizeStrict(allocator, z.bodyNode(doc2).?);
    const strict_result = try z.innerHTML(allocator, z.bodyElement(doc2).?);
    defer allocator.free(strict_result);
    z.print("    Strict removes framework attrs too:\n    {s}\n", .{strict_result});
    std.debug.assert(std.mem.indexOf(u8, strict_result, "x-data") == null);
    std.debug.assert(std.mem.indexOf(u8, strict_result, "hx-get") == null);
}

// =============================================================================
// SUMMARY: Quick Reference
// =============================================================================
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │ SCENARIO                          │ FUNCTIONS TO USE                    │
// ├───────────────────────────────────┼─────────────────────────────────────┤
// │ Trusted HTML                      │ createDocument → initDocumentCSS →  │
// │                                   │ insertHTML → loadStyleTags          │
// ├───────────────────────────────────┼─────────────────────────────────────┤
// │ Untrusted HTML (full sanitize)    │ createDocument → insertHTML →       │
// │                                   │ sanitizeStrict                      │
// ├───────────────────────────────────┼─────────────────────────────────────┤
// │ Untrusted HTML (keep clean CSS)   │ createDocument → insertHTML →       │
// │                                   │ sanitizeWithCss → initDocumentCSS → │
// │                                   │ loadStyleTags                       │
// ├───────────────────────────────────┼─────────────────────────────────────┤
// │ External CSS file                 │ CssSanitizer.sanitizeStylesheet →   │
// │                                   │ parseStylesheet → attachStylesheet  │
// ├───────────────────────────────────┼─────────────────────────────────────┤
// │ Dynamic style changes             │ setStyleProperty / setAttribute     │
// │                                   │ (CSS engine must be init'd)         │
// ├───────────────────────────────────┼─────────────────────────────────────┤
// │ Framework attrs (HTMX, Vue, etc)  │ sanitizePermissive (not strict)     │
// └───────────────────────────────────┴─────────────────────────────────────┘
//
// KEY RULE: Always sanitize BEFORE initDocumentCSS when processing untrusted HTML!
// =============================================================================

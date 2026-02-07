const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    z.print("\n" ++ "=" ** 70 ++ "\n", .{});
    z.print("  REAL-WORLD SANITIZER + CSS ENGINE TEST\n", .{});
    z.print("=" ** 70 ++ "\n\n", .{});

    // Run all three approaches
    try verboseApproach(allocator);
    try simplifiedApproach(allocator);
    try scriptEngineApproach(allocator);

    z.print("\n" ++ "=" ** 70 ++ "\n", .{});
    z.print("  ALL TESTS COMPLETE\n", .{});
    z.print("=" ** 70 ++ "\n", .{});
}

/// The OLD verbose approach - many manual steps
fn verboseApproach(allocator: std.mem.Allocator) !void {
    z.print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    z.print("║  APPROACH 1: VERBOSE (OLD WAY - MANY STEPS)                      ║\n", .{});
    z.print("╚══════════════════════════════════════════════════════════════════╝\n\n", .{});

    const html = @embedFile("test_real.html");
    const external_css = @embedFile("test_real.css");

    z.print("━━━ Step 1: Create Sanitizer ━━━\n", .{});
    var zan = try z.Sanitizer.init(allocator, .{});
    defer zan.deinit();
    z.print("  var zan = try z.Sanitizer.init(allocator, .{{}});\n", .{});

    z.print("\n━━━ Step 2: Parse HTML ━━━\n", .{});
    const doc = try zan.parseHTML(html);
    defer z.destroyDocument(doc);
    z.print("  const doc = try zan.parseHTML(html);\n", .{});

    z.print("\n━━━ Step 3: Sanitize external CSS ━━━\n", .{});
    const clean_css = try zan.sanitizeStylesheet(external_css);
    defer allocator.free(clean_css);
    z.print("  const clean_css = try zan.sanitizeStylesheet(external_css);\n", .{});

    z.print("\n━━━ Step 4: Create CSS parser ━━━\n", .{});
    const parser = try z.createCssStyleParser();
    defer z.destroyCssStyleParser(parser);
    z.print("  const parser = try z.createCssStyleParser();\n", .{});

    z.print("\n━━━ Step 5: Create stylesheet ━━━\n", .{});
    const sst = try z.createStylesheet();
    defer z.destroyStylesheet(sst);
    z.print("  const sst = try z.createStylesheet();\n", .{});

    z.print("\n━━━ Step 6: Parse stylesheet ━━━\n", .{});
    try z.parseStylesheet(sst, parser, clean_css);
    z.print("  try z.parseStylesheet(sst, parser, clean_css);\n", .{});

    z.print("\n━━━ Step 7: Attach stylesheet ━━━\n", .{});
    try z.attachStylesheet(doc, sst);
    z.print("  try z.attachStylesheet(doc, sst);\n", .{});

    // Test it works
    z.print("\n━━━ Verify CSS Engine ━━━\n", .{});
    if (try z.querySelector(allocator, doc, ".header")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        z.print("  .header color = {s} ✓\n", .{color orelse "(none)"});
    }

    z.print("\n  Total: 7 steps + 4 defers = 11 cleanup points!\n\n", .{});
}

/// The NEW simplified approach - just 3 calls
fn simplifiedApproach(allocator: std.mem.Allocator) !void {
    z.print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    z.print("║  APPROACH 2: SIMPLIFIED (NEW WAY - 3 CALLS)                      ║\n", .{});
    z.print("╚══════════════════════════════════════════════════════════════════╝\n\n", .{});

    const html = @embedFile("test_real.html");
    const external_css = @embedFile("test_real.css");

    z.print("━━━ Step 1: Create Sanitizer ━━━\n", .{});
    var zan = try z.Sanitizer.init(allocator, .{});
    defer zan.deinit();
    z.print("  var zan = try z.Sanitizer.init(allocator, .{{}});\n", .{});
    z.print("  defer zan.deinit();\n", .{});

    z.print("\n━━━ Step 2: Parse HTML (sanitize + CSS engine) ━━━\n", .{});
    const doc = try zan.parseHTML(html);
    defer z.destroyDocument(doc);
    z.print("  const doc = try zan.parseHTML(html);\n", .{});
    z.print("  defer z.destroyDocument(doc);\n", .{});

    z.print("\n━━━ Step 3: Load external CSS (sanitize + parse + attach) ━━━\n", .{});
    try zan.loadStylesheet(doc, external_css);
    z.print("  try zan.loadStylesheet(doc, external_css);\n", .{});

    // Test it works
    z.print("\n━━━ Verify CSS Engine ━━━\n", .{});
    if (try z.querySelector(allocator, doc, ".header")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        z.print("  .header color = {s} ✓\n", .{color orelse "(none)"});
    }

    // Verify sanitization happened
    z.print("\n━━━ Verify Sanitization ━━━\n", .{});
    if (try z.querySelector(allocator, doc, "style")) |style_el| {
        const content = z.textContent_zc(z.elementToNode(style_el));
        const has_behavior = std.mem.indexOf(u8, content, "behavior") != null;
        const has_moz = std.mem.indexOf(u8, content, "-moz-binding") != null;
        z.print("  <style> behavior removed: {}\n", .{!has_behavior});
        z.print("  <style> -moz-binding removed: {}\n", .{!has_moz});
    }
    try z.prettyPrint(allocator, z.bodyNode(doc).?);

    z.print("\n  Total: 3 calls + 2 defers = CLEAN!\n", .{});
    z.print("\n  Full API:\n", .{});
    z.print("    var zan = try z.Sanitizer.init(allocator, .{{}});\n", .{});
    z.print("    defer zan.deinit();\n", .{});
    z.print("    const doc = try zan.parseHTML(html);\n", .{});
    z.print("    defer z.destroyDocument(doc);\n", .{});
    z.print("    try zan.loadStylesheet(doc, external_css);  // Optional\n\n", .{});
}

/// The NEWEST approach - ScriptEngine.loadPage() for full page with JS
fn scriptEngineApproach(allocator: std.mem.Allocator) !void {
    z.print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    z.print("║  APPROACH 3: SCRIPT ENGINE (HIGHEST LEVEL - WITH JS EXECUTION)  ║\n", .{});
    z.print("╚══════════════════════════════════════════════════════════════════╝\n\n", .{});

    const html = @embedFile("test_real.html");

    // Get sandbox root (current directory)
    const sandbox_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sandbox_root);

    z.print("━━━ Step 1: Create ScriptEngine ━━━\n", .{});
    var engine = try z.ScriptEngine.init(allocator, sandbox_root);
    defer engine.deinit();
    z.print("  var engine = try z.ScriptEngine.init(allocator, sandbox_root);\n", .{});
    z.print("  defer engine.deinit();\n", .{});

    z.print("\n━━━ Step 2: loadPage (sanitize + CSS + scripts) ━━━\n", .{});
    try engine.loadPage(html, .{
        .sanitize = true, // Enable sanitization for untrusted content
        .base_dir = "src/examples", // Resolve relative paths from examples dir
        .execute_scripts = true, // Execute <script> tags
        .load_stylesheets = true, // Load <link rel="stylesheet">
        .sanitizer_options = .{ .remove_scripts = false }, // Keep scripts for JS execution
        .run_loop = true, // Run event loop to process module Promises
    });

    try z.prettyPrint(allocator, z.bodyNode(engine.dom.doc).?);

    z.print("  try engine.loadPage(html, .{{\n", .{});
    z.print("      .sanitize = true,\n", .{});
    z.print("      .base_dir = \".\",\n", .{});
    z.print("      .execute_scripts = true,\n", .{});
    z.print("      .load_stylesheets = true,\n", .{});
    z.print("      .sanitizer_options = .{{ .remove_scripts = false }},\n", .{});
    z.print("  }});\n", .{});

    // Verify it worked
    z.print("\n━━━ Verify Document ━━━\n", .{});
    const doc = engine.dom.doc;

    // Check if script tags exist
    const scripts = try z.querySelectorAll(allocator, doc, "script");
    defer allocator.free(scripts);
    z.print("  Script tags found: {d}\n", .{scripts.len});
    for (scripts) |script| {
        const src = z.getAttribute_zc(script, "src");
        const script_type = z.getAttribute_zc(script, "type");
        z.print("    - src={s}, type={s}\n", .{ src orelse "(inline)", script_type orelse "(none)" });
    }

    // Check CSS from external stylesheet (.header is defined in test_real.css)
    if (try z.querySelector(allocator, doc, ".header")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        z.print("  .header color = {s} ✓\n", .{color orelse "(none)"});
    }

    // Check CSS from <style> element (.safe { color: green; font-size: 16px; })
    // This verifies styles apply to JS-injected content
    if (try z.querySelector(allocator, doc, ".safe")) |el| {
        // BEFORE attaching styles
        const color_before = try z.getComputedStyle(allocator, el, "color");
        defer if (color_before) |c| allocator.free(c);
        z.print("  .safe BEFORE attachElementStyles: color = {s}\n", .{color_before orelse "(none)"});

        // Attach stylesheet rules to this element (needed for dynamically inserted nodes)
        try z.attachElementStyles(el);

        // AFTER attaching styles
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        const font_size = try z.getComputedStyle(allocator, el, "font-size");
        defer if (font_size) |f| allocator.free(f);
        z.print("  .safe AFTER attachElementStyles: color = {s}, font-size = {s}\n", .{ color orelse "(none)", font_size orelse "(none)" });
    } else {
        z.print("  .safe element NOT found (JS injection failed?)\n", .{});
    }

    // Check inline styles on injected content
    if (try z.querySelector(allocator, doc, "#span1")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        const padding = try z.getComputedStyle(allocator, el, "padding");
        defer if (padding) |p| allocator.free(p);
        z.print("  #span1 (inline) color = {s}, padding = {s}\n", .{ color orelse "(none)", padding orelse "(none)" });
    }

    z.print("\n  Total: 2 calls + 2 defers = SIMPLEST!\n", .{});
    z.print("\n  This is the recommended API for:\n", .{});
    z.print("    - Loading untrusted HTML with sanitization\n", .{});
    z.print("    - Executing JavaScript after page load\n", .{});
    z.print("    - Full page orchestration in one call\n\n", .{});
}

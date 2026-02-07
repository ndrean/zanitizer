const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    z.print("\n" ++ "=" ** 70 ++ "\n", .{});
    z.print("  REAL-WORLD SANITIZER + CSS ENGINE TEST\n", .{});
    z.print("=" ** 70 ++ "\n\n", .{});

    // Run both approaches
    try verboseApproach(allocator);
    try simplifiedApproach(allocator);

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

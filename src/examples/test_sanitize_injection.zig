/// Test: DOM mutation sanitization
///
/// Verifies that JS-driven HTML injection is sanitized when sanitize=true:
///   - innerHTML =    (parsed HTML string)
///   - outerHTML =    (parsed HTML string, replaces element)
///   - insertAdjacentHTML()  (parsed HTML string)
///   - createElement + setAttribute("style") + appendChild  (no HTML parsing)
///
/// Each vector injects a <p> with:
///   - color: red          ← safe, must survive
///   - background-image: url(evil.com)  ← threat, must be stripped
///
/// Run: zig build example -Dname=test_sanitize_injection
const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const sbr = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sbr);

    const html = @embedFile("test_sanitize_injection.html");

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("  sanitize = true  (untrusted content)\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    try runTest(allocator, sbr, html, true);

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("  sanitize = false (trusted content — threats survive)\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    try runTest(allocator, sbr, html, false);
}

fn runTest(ta: std.mem.Allocator, sbr: []const u8, html: []const u8, sanitize: bool) !void {
    var engine = try z.ScriptEngine.init(ta, sbr);
    defer engine.deinit();

    try engine.loadPage(html, .{
        .sanitize = sanitize,
        .base_dir = "src/examples",
        .execute_scripts = true,
        .load_stylesheets = false,
        .sanitizer_options = .{ .remove_scripts = false },
        .run_loop = false,
    });

    const doc = engine.dom.doc;

    const vectors = [_]struct { id: []const u8, label: []const u8 }{
        .{ .id = "r1", .label = "innerHTML" },
        .{ .id = "r2", .label = "outerHTML" },
        .{ .id = "r3", .label = "insertAdjacentHTML" },
        .{ .id = "r4", .label = "createElement+setAttribute" },
    };

    var all_pass = true;

    for (vectors) |v| {
        const el = z.getElementById(doc, v.id);
        if (el == null) {
            std.debug.print("  [{s}]  NOT FOUND\n", .{v.label});
            if (sanitize) all_pass = false; // element should exist even when sanitized
            continue;
        }

        const style_attr = z.getAttribute_zc(el.?, "style") orelse "(none)";
        const color = try z.getComputedStyle(ta, el.?, "color");
        defer if (color) |c| ta.free(c);
        const bg_img = try z.getComputedStyle(ta, el.?, "background-image");
        defer if (bg_img) |c| ta.free(c);

        const color_ok  = if (color) |c| std.mem.eql(u8, c, "red") else false;
        const threat_gone = bg_img == null;
        const pass = if (sanitize) color_ok and threat_gone else !threat_gone;

        std.debug.print("  [{s}]\n", .{v.label});
        std.debug.print("    style attr : \"{s}\"\n", .{style_attr});
        std.debug.print("    color      : {s}  {s}\n", .{
            color orelse "(none)",
            if (color_ok) "✓" else "✗",
        });
        std.debug.print("    bg-image   : {s}  {s}\n", .{
            bg_img orelse "(stripped)",
            if (sanitize) (if (threat_gone) "✓ stripped" else "✗ LEAKED") else (if (!threat_gone) "present (expected)" else "✗"),
        });
        std.debug.print("    result     : {s}\n\n", .{if (pass) "PASS" else "FAIL"});

        if (!pass) all_pass = false;
    }

    std.debug.print("  Overall: {s}\n", .{if (all_pass) "ALL PASS" else "FAILURES DETECTED"});
}

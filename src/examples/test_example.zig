const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const sbr = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sbr);

    z.print("\n" ++ "=" ** 60 ++ "\n", .{});
    z.print("  RUN 1: sanitize = true (untrusted content)\n", .{});
    z.print("=" ** 60 ++ "\n", .{});
    try runTest(allocator, sbr, true);

    z.print("\n" ++ "=" ** 60 ++ "\n", .{});
    z.print("  RUN 2: sanitize = false (trusted code / full risk)\n", .{});
    z.print("=" ** 60 ++ "\n", .{});
    try runTest(allocator, sbr, false);
}

fn runTest(ta: std.mem.Allocator, sbr: []const u8, sanitize: bool) !void {
    var engine = try z.ScriptEngine.init(ta, sbr);
    defer engine.deinit();

    try engine.loadPage(@embedFile("test_example.html"), .{
        .sanitize = sanitize,
        .base_dir = "src/examples",
        .execute_scripts = true,
        .load_stylesheets = true,
        .sanitizer_options = .{ .remove_scripts = false },
        .run_loop = true,
    });

    const doc = engine.dom.doc;

    // === Static HTML elements ===
    z.print("\n--- Static HTML ---\n", .{});

    if (try z.querySelector(ta, doc, "div.untrusted")) |div| {
        const color = try z.getComputedStyle(ta, div, "color");
        defer if (color) |c| ta.free(c);
        z.print("  div.untrusted: color={s}, onclick={s}\n", .{
            color orelse "(none)",
            z.getAttribute_zc(div, "onclick") orelse "(removed)",
        });
    }

    // === JS-injected elements ===
    z.print("\n--- JS-injected elements ---\n", .{});

    const test_ids = [_][]const u8{ "js1", "js2", "js3", "js4" };
    const test_labels = [_][]const u8{
        "insertAdjacentHTML(beforeend)",
        "innerHTML",
        "outerHTML",
        "insertAdjacentHTML(afterbegin)",
    };

    for (test_ids, test_labels) |id, label| {
        z.print("  {s}:\n", .{label});
        if (z.getElementById(doc, id)) |el| {
            const color = try z.getComputedStyle(ta, el, "color");
            defer if (color) |c| ta.free(c);

            const style_attr = z.getAttribute_zc(el, "style") orelse "(none)";

            const has_color = if (color) |c| std.mem.eql(u8, c, "red") else false;
            const sanitized = !std.mem.containsAtLeast(u8, style_attr, 1, "behavior");

            z.print("    style=\"{s}\"\n", .{style_attr});
            z.print("    CSS applied: {s}  Sanitized: {s}\n", .{
                if (has_color) "YES" else "NO",
                if (sanitized) "YES" else "NO",
            });
        } else {
            z.print("    NOT FOUND\n", .{});
        }
    }
}

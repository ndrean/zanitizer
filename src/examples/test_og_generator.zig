const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ScriptEngine = z.ScriptEngine;
const js_canvas = z.js_canvas;

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

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    try run_test(gpa, sandbox_root);
}

fn run_test(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();
    const script = @embedFile("test_og_generator.js");

    const val = try engine.eval(script, "<script>", .global);
    defer engine.ctx.freeValue(val);

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, "renderTemplate()", "<svg-template>");
    defer allocator.free(png_bytes);

    try std.fs.cwd().writeFile(
        .{
            .sub_path = "svg_og_template_generator.png",
            .data = png_bytes,
        },
    );
}

// std.debug.print("  [8] Saved 'svg_og_template_generator.png' ({d} bytes) — SVG template + dynamic text\n", .{png_bytes.len});

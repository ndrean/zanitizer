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
        _ = .ok == debug_allocator.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    var engine = try ScriptEngine.init(gpa, sandbox_root);
    defer engine.deinit();

    const html = @embedFile("test_htm_paint.html");
    try engine.loadPage(html, .{});

    // Print DOM
    std.debug.print("\n=== DOM ===\n", .{});
    try z.prettyPrint(gpa, z.bodyNode(engine.dom.doc).?);

    // Paint
    const script =
        \\ const body = document.querySelector("body");
        \\ zxp.paintDOM(body, "htm_paint.png")
    ;
    const val = try engine.eval(script, "<htm-paint>", .global);
    engine.ctx.freeValue(val);
}

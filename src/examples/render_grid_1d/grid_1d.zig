const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ZxpRuntime = z.ZxpRuntime;
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

    var zxp_rt = try z.ZxpRuntime.init(gpa, sandbox_root);
    defer zxp_rt.deinit();

    var engine = try ScriptEngine.init(gpa, zxp_rt);
    defer engine.deinit();

    const html = @embedFile("grid_1d.html"); // relative to source file
    try engine.loadPage(html, .{});

    try z.prettyPrint(gpa, z.bodyNode(engine.dom.doc).?);

    // Paint
    const script =
        \\ const body = document.querySelector("body");
        \\ zxp.save(zxp.paintDOM(body), "src/examples/render_grid_1d/grid_1d.jpeg")
    ;
    const val = try engine.eval(script, "<grid-paint>", .global);
    engine.ctx.freeValue(val);
}

const std = @import("std");
const builtin = @import("builtin");
const z = @import("zxp");
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

    const chartjs = @embedFile("chart.js");
    std.debug.print("Chart.js bundle size: {d}\n", .{chartjs.len});
    const chartjs_val = try engine.eval(chartjs, "<chartjs>", .global);
    engine.ctx.freeValue(chartjs_val);

    const html = @embedFile("test_chartjs.html");
    try engine.loadHTML(html);

    const body = z.bodyNode(engine.dom.doc);
    const maybe_script = z.getElementByTag(body.?, .script);
    if (maybe_script) |script_elt| {
        const script = z.textContent_zc(z.elementToNode(script_elt));

        const png_bytes = try engine.evalAsyncAs(gpa, []const u8, script, "<image>");
        defer gpa.free(png_bytes);
        // z.print("{s}\n", .{png_bytes[0..15]});
        std.debug.print("\n🎆 Example GraphJS in Canvas ----\n\n", .{});
        // try js_canvas.verifyPngStructure(png_bytes);
        try std.fs.cwd().writeFile(.{ .sub_path = "src/examples/chartjs/chart_JS_test.png", .data = png_bytes });
    }
}

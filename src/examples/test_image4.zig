const std = @import("std");
const z = @import("zexplorer");
const js_canvas = z.js_canvas;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const sbr = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sbr);

    var engine = try z.ScriptEngine.init(allocator, sbr);
    defer engine.deinit();

    // Engine already provides a document with <body> via DOMBridge.init
    // try engine.loadHTML("<html><body></body></html>");

    const js = @embedFile("test_image4.js");
    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, js, "<image4>");
    defer allocator.free(png_bytes);

    z.print("PNG size: {d} bytes\n", .{png_bytes.len});
    try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "canvas_rhino_tile_test4.png", .data = png_bytes });
    std.debug.print("Saved 'canvas_rhino_tile_test4.png'\n", .{});
}

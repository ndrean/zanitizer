const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const js_canvas = z.js_canvas;
const ScriptEngine = z.ScriptEngine;

extern fn stbi_write_png_to_mem(
    pixels: [*]const u8,
    stride_in_bytes: c_int,
    x: c_int,
    y: c_int,
    n: c_int,
    out_len: *c_int,
) ?[*]u8;

const opengraph_svg = @embedFile("test_opengraph-me.svg");
const opengraph_text_svg = @embedFile("test_opengraph-text.svg");

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

    try testDirectSvg(gpa);
    try testSvgViaInitFromMemory(gpa);
    try testSvgDrawOnCanvas(gpa);
    try testRealSvgFromZig(gpa);
    try testRealSvgFromJS(gpa, sandbox_root);
    try testSvgBlobFromJS(gpa, sandbox_root);
    try testReadSvgBlobFromJS(gpa, sandbox_root);
    try testSvgTemplateFromJS(gpa, sandbox_root);
    try testSvgNativeText(gpa);

    std.debug.print("\nAll SVG raster tests passed.\n", .{});
}

/// Test 1: Direct initFromSvg with a simple red circle
fn testDirectSvg(allocator: std.mem.Allocator) !void {
    const svg =
        \\<svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
        \\  <circle cx="50" cy="50" r="40" fill="red"/>
        \\</svg>
    ;

    const img = try z.js_image.Image.initFromSvg(allocator, svg, 1.0);
    defer img.deinit();

    std.debug.assert(img.width == 100);
    std.debug.assert(img.height == 100);
    std.debug.assert(img.channels == 4);

    // Check center pixel is red (RGBA: 255, 0, 0, 255)
    const cx: usize = 50;
    const cy: usize = 50;
    const idx = (cy * @as(usize, @intCast(img.width)) + cx) * 4;
    const r = img.pixels[idx];
    const g = img.pixels[idx + 1];
    const b = img.pixels[idx + 2];
    const a = img.pixels[idx + 3];
    std.debug.print("  [1] initFromSvg: {d}x{d}, center pixel RGBA=({d},{d},{d},{d})\n", .{
        img.width, img.height, r, g, b, a,
    });
    std.debug.assert(r == 255 and g == 0 and b == 0 and a == 255);

    // Encode to PNG and save
    var out_len: c_int = 0;
    const png_ptr = stbi_write_png_to_mem(
        img.pixels,
        0,
        img.width,
        img.height,
        4,
        &out_len,
    ) orelse return error.PngEncodeFailed;
    const png_bytes = png_ptr[0..@intCast(out_len)];
    defer std.c.free(png_ptr);

    try std.fs.cwd().writeFile(.{ .sub_path = "svg_raster_circle.png", .data = png_bytes });
    std.debug.print("  [1] Saved 'svg_raster_circle.png' ({d} bytes)\n", .{png_bytes.len});
}

/// Test 2: SVG auto-detected via initFromMemory (same path as <img src="data:...">)
fn testSvgViaInitFromMemory(allocator: std.mem.Allocator) !void {
    const svg =
        \\<svg width="80" height="60" xmlns="http://www.w3.org/2000/svg">
        \\  <rect x="10" y="10" width="60" height="40" fill="blue"/>
        \\</svg>
    ;

    const img = try z.js_image.Image.initFromMemory(allocator, svg);
    defer img.deinit();

    // initFromMemory auto-scales small SVGs (min 800px on longest side)
    // 80x60 → scale 10x → 800x600
    std.debug.assert(img.width >= 80);
    std.debug.assert(img.height >= 60);
    std.debug.assert(img.channels == 4);

    std.debug.print("  [2] initFromMemory (SVG auto-detect): {d}x{d}\n", .{ img.width, img.height });

    // Check center of the blue rect (scale-adjusted)
    const scale_x = @as(f32, @floatFromInt(img.width)) / 80.0;
    const scale_y = @as(f32, @floatFromInt(img.height)) / 60.0;
    const cx: usize = @intFromFloat(40.0 * scale_x);
    const cy: usize = @intFromFloat(30.0 * scale_y);
    const idx = (cy * @as(usize, @intCast(img.width)) + cx) * 4;
    const r = img.pixels[idx];
    const g = img.pixels[idx + 1];
    const b = img.pixels[idx + 2];
    std.debug.print("  [2] center pixel RGB=({d},{d},{d})\n", .{ r, g, b });
    std.debug.assert(r == 0 and g == 0 and b == 255);
}

/// Test 3: Rasterize SVG, draw onto Canvas, export as PNG
fn testSvgDrawOnCanvas(allocator: std.mem.Allocator) !void {
    const svg =
        \\<svg width="64" height="64" xmlns="http://www.w3.org/2000/svg">
        \\  <rect width="64" height="64" fill="#228B22"/>
        \\  <circle cx="32" cy="32" r="20" fill="gold"/>
        \\</svg>
    ;

    const img = try z.js_image.Image.initFromSvg(allocator, svg, 1.0);
    defer img.deinit();

    // Create a canvas and draw the SVG image onto it
    var canvas = try js_canvas.Canvas.init(allocator, 128, 128);
    defer canvas.deinit();

    // Draw at (0,0) and also at (64,64) to test tiling
    canvas.drawImage(img, 0, 0, 64, 64, 0, 0, 64, 64);
    canvas.drawImage(img, 0, 0, 64, 64, 64, 64, 64, 64);

    // Encode canvas to PNG
    var out_len: c_int = 0;
    const png_ptr = stbi_write_png_to_mem(
        canvas.pixels.ptr,
        0,
        @intCast(canvas.width),
        @intCast(canvas.height),
        4,
        &out_len,
    ) orelse return error.PngEncodeFailed;
    const png_bytes = png_ptr[0..@intCast(out_len)];
    defer std.c.free(png_ptr);

    try std.fs.cwd().writeFile(.{ .sub_path = "svg_raster_canvas.png", .data = png_bytes });
    std.debug.print("  [3] Saved 'svg_raster_canvas.png' ({d} bytes) — 128x128 with 2 tiled SVGs\n", .{png_bytes.len});
}

/// Test 4: Real-world SVG file Direct: loaded from @embedFile via Zig API
fn testRealSvgFromZig(allocator: std.mem.Allocator) !void {
    const img = try z.js_image.Image.initFromMemory(allocator, opengraph_svg);
    defer img.deinit();

    std.debug.print("  [4] Real SVG from Zig: {d}x{d} (channels={d})\n", .{ img.width, img.height, img.channels });
    // std.debug.assert(img.width == 800);
    // std.debug.assert(img.height == 800);
    std.debug.assert(img.channels == 4);

    // Encode to PNG and save
    var out_len: c_int = 0;
    const png_ptr = stbi_write_png_to_mem(
        img.pixels,
        0,
        img.width,
        img.height,
        4,
        &out_len,
    ) orelse return error.PngEncodeFailed;
    const png_bytes = png_ptr[0..@intCast(out_len)];
    defer std.c.free(png_ptr);

    try std.fs.cwd().writeFile(.{ .sub_path = "svg_raster_opengraph_zig.png", .data = png_bytes });
    std.debug.print("  [4] Saved 'svg_raster_opengraph_zig.png' ({d} bytes)\n", .{png_bytes.len});
}

/// Test 5: Real-world SVG loaded via JS `new Image()` + data URL, drawn on Canvas
fn testRealSvgFromJS(allocator: std.mem.Allocator, sbr: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbr);
    defer engine.deinit();

    // Base64-encode the SVG at runtime for the JS data URL
    const b64_len = std.base64.standard.Encoder.calcSize(opengraph_svg.len);
    const svg_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(svg_b64);
    _ = std.base64.standard.Encoder.encode(svg_b64, opengraph_svg);

    // Build the JS script with the data URL embedded
    const script = try std.fmt.allocPrint(allocator,
        \\async function testSvgImage() {{
        \\  const canvas = document.createElement('canvas');
        \\  canvas.width = 400;
        \\  canvas.height = 400;
        \\  const ctx = canvas.getContext('2d');
        \\
        \\  // White background
        \\  ctx.fillStyle = 'white';
        \\  ctx.fillRect(0, 0, 400, 400);
        \\
        // "old" way via Image()
        // to pass the output to Zig, need to use a Promise wrapper
        // as `evalAsyncAs` needs a return value, and you can't return
        // from inside a callback, only from the async function itself.
        \\  const img = new Image();
        \\  const loaded = new Promise((resolve, reject) => {{
        \\    img.onload = () => resolve();
        \\    img.onerror = () => reject('SVG load failed');
        \\  }});
        \\  img.src = 'data:image/svg+xml;base64,{s}';
        \\  await loaded;
        \\
        \\  console.log('[JS] SVG loaded:', img.width, 'x', img.height);
        \\
        \\  // Draw SVG scaled down to fit 400x400 canvas
        \\  ctx.drawImage(img, 0, 0, img.width, img.height, 0, 0, 400, 400);
        \\
        \\  // Add a label
        \\  ctx.fillStyle = 'red';
        \\  ctx.font = '20px';
        \\  ctx.fillText('SVG via JS', 10, 390);
        \\
        \\  const blob = await canvas.toBlob();
        \\  return await blob.arrayBuffer();
        \\}}
        \\testSvgImage();
    , .{svg_b64});
    defer allocator.free(script);

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, script, "<svg-js>");
    defer allocator.free(png_bytes);

    try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "svg_raster_opengraph_js.png", .data = png_bytes });
    std.debug.print("  [5] Saved 'svg_raster_opengraph_js.png' ({d} bytes) — SVG via JS Image + Canvas\n", .{png_bytes.len});
}

/// Test 6: SVG loaded via Blob + createImageBitmap (no base64 needed)
fn testSvgBlobFromJS(allocator: std.mem.Allocator, sbr: []const u8) !void {
    const sandbox_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sandbox_root);

    var engine = try ScriptEngine.init(allocator, sbr);
    defer engine.deinit();

    // Embed SVG as a JS template literal — no base64 overhead.
    // The SVG has no backticks or ${} so template literal is safe.
    const script = try std.fmt.allocPrint(allocator,
        \\async function testSvgBlob() {{
        \\  const svgText = `{s}`;
        \\  const blob = new Blob([svgText], {{type: 'image/svg+xml'}});
        // "modern" way via the Promise based `createImageBitmap` API
        \\  const img = await createImageBitmap(blob);
        \\
        \\  console.log('[JS] SVG from Blob:', img.width, 'x', img.height);
        \\
        \\  const canvas = document.createElement('canvas');
        \\  const w = 800;
        \\  const h = w * img.height / img.width;
        \\  canvas.width = w;
        \\  canvas.height = h;
        \\  const ctx = canvas.getContext('2d');
        \\
        \\  ctx.fillStyle = 'white';
        \\  ctx.fillRect(0, 0, w, h);
        \\  ctx.drawImage(img, 0, 0, img.width, img.height, 0, 0, w, h);
        \\
        \\  ctx.fillStyle = 'blue';
        \\  ctx.font = '20px';
        \\  ctx.fillText('SVG via Blob', 10, 390);
        // return value to Zig
        \\  const result = await canvas.toBlob();
        \\  return await result.arrayBuffer();
        \\}}
        \\testSvgBlob();
    , .{opengraph_svg});
    defer allocator.free(script);

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, script, "<svg-blob>");
    defer allocator.free(png_bytes);

    try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "svg_raster_opengraph_blob.png", .data = png_bytes });
    std.debug.print("  [6] Saved 'svg_raster_opengraph_blob.png' ({d} bytes) — SVG via Blob + createImageBitmap\n", .{png_bytes.len});
}

fn testReadSvgBlobFromJS(allocator: std.mem.Allocator, sbr: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbr);
    defer engine.deinit();

    const opengraph_svg2 = @embedFile("test_opengraph-me.svg");
    const js = @embedFile("test_svg_read_render.js");

    const val = try engine.eval(js, "<init>", .global);
    defer engine.ctx.freeValue(val);

    const scope = z.wrapper.Context.GlobalScope.init(engine.ctx);
    defer scope.deinit();
    try scope.setString("MY_SVG_DATA", opengraph_svg2);

    const png_bytes = try engine.evalAsyncAs(allocator, []const u8, "renderSVG(MY_SVG_DATA)", "<svg-blob>");
    defer allocator.free(png_bytes);

    try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = "svg_read_raster_opengraph_blob.png", .data = png_bytes });
    std.debug.print("  [7] Saved 'svg_read_raster_opengraph_blob.png' ({d} bytes) — SVG via Blob + createImageBitmap\n", .{png_bytes.len});
}

/// Test 8: SVG template with dynamic data injected from Zig
/// Proves the OG image generator concept: SVG background + dynamic text overlay.
fn testSvgTemplateFromJS(allocator: std.mem.Allocator, sbr: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbr);
    defer engine.deinit();

    const js = @embedFile("test_svg_template_render.js");

    const val = try engine.eval(js, "<template-init>", .global);
    defer engine.ctx.freeValue(val);

    const scope = z.wrapper.Context.GlobalScope.init(engine.ctx);
    defer scope.deinit();

    try scope.setString("TEMPLATE_SVG", opengraph_svg);

    // Build and inject the data object
    const data = scope.newObject();
    try engine.ctx.setPropertyStr(data, "title", scope.newString("Built by Zexplorer"));

    try engine.ctx.setPropertyStr(data, "footer", scope.newString("Built with Zig, nanosvg, stb_truetype & QuickJS"));
    try scope.set("TEMPLATE_DATA", data);

    const png_bytes = try engine.evalAsyncAs(
        allocator,
        []const u8,
        "renderTemplate(TEMPLATE_SVG, TEMPLATE_DATA)",
        "<svg-template>",
    );
    defer allocator.free(png_bytes);

    try js_canvas.verifyPngStructure(png_bytes);
    try std.fs.cwd().writeFile(
        .{
            .sub_path = "svg_template_opengraph.png",
            .data = png_bytes,
        },
    );
    std.debug.print("  [8] Saved 'svg_template_opengraph.png' ({d} bytes) — SVG template + dynamic text\n", .{png_bytes.len});
}

/// Test 9: Native SVG <text> rendering via ThorVG (nanosvg cannot render <text> elements)
fn testSvgNativeText(allocator: std.mem.Allocator) !void {
    const img = try z.js_image.Image.initFromMemory(allocator, opengraph_text_svg);
    defer img.deinit();

    z.print("  [9] Native SVG text: {d}x{d} (channels={d})\n", .{ img.width, img.height, img.channels });
    std.debug.assert(img.width >= 1200);
    std.debug.assert(img.height >= 630);
    std.debug.assert(img.channels == 4);

    // Encode to PNG and save
    var out_len: c_int = 0;
    const png_ptr = stbi_write_png_to_mem(
        img.pixels,
        0,
        img.width,
        img.height,
        4,
        &out_len,
    ) orelse return error.PngEncodeFailed;
    const png_bytes = png_ptr[0..@intCast(out_len)];
    defer std.c.free(png_ptr);

    try std.fs.cwd().writeFile(.{ .sub_path = "svg_native_text.png", .data = png_bytes });
    std.debug.print("  [9] Saved 'svg_native_text.png' ({d} bytes) — ThorVG native <text> rendering\n", .{png_bytes.len});
}

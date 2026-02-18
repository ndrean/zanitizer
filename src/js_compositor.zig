const std = @import("std");
const z = @import("root.zig");
const RuntimeContext = z.RuntimeContext;
const qjs = z.qjs;
const w = z.wrapper;
const stbi = @cImport({
    @cInclude("stb_image.h");
});
const stbi_write = @cImport({
    @cInclude("stb_image_write.h");
});
const thorvg = z.thorvg;

extern fn stbi_write_png_to_mem(
    pixels: [*]const u8,
    stride_in_bytes: c_int,
    x: c_int,
    y: c_int,
    n: c_int,
    out_len: *c_int,
) ?[*]u8;

fn stbiw_free(ptr: ?*anyopaque) void {
    if (ptr) |p| std.c.free(p);
}

pub fn js_generateRoutePng(ctx_ptr: ?*z.qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 2) return w.UNDEFINED;

    const rc = RuntimeContext.get(ctx);

    // Arg 3 (index 3): Width, Arg 4 (index 4): Height
    const page_width: u32 = if (argc >= 4 and !ctx.isUndefined(argv[3]) and !ctx.isNull(argv[3]))
        ctx.toUint32(argv[3]) catch 800
    else
        800;
    const page_height: u32 = if (argc >= 5 and !ctx.isUndefined(argv[4]) and !ctx.isNull(argv[4]))
        ctx.toUint32(argv[4]) catch 600
    else
        600;

    // 1. Allocate the Master ARGB Buffer
    // ThorVG defaults to ARGB8888 for software canvases
    const buffer_size = page_width * page_height;
    const master_buffer = rc.allocator.alloc(u32, buffer_size) catch {
        std.debug.print("[Compositor] FATAL: Could not allocate Master Buffer!\n", .{});
        return w.UNDEFINED;
    };
    defer rc.allocator.free(master_buffer);

    // Fill with white background
    @memset(master_buffer, 0xFFFFFFFF);

    // ---------------------------------------------------------
    // PHASE 1: Draw the Map Tiles (via stb_image)
    // ---------------------------------------------------------
    const js_tiles = argv[0];
    const len_val = ctx.getPropertyStr(js_tiles, "length");
    defer ctx.freeValue(len_val);

    const arr_len = ctx.toUint32(len_val) catch 0;
    std.debug.print("[Compositor] Blitting {} tiles into Master Buffer...\n", .{arr_len});

    for (0..arr_len) |i| {
        const tile_obj = ctx.getPropertyUint32(js_tiles, @intCast(i));
        defer ctx.freeValue(tile_obj);

        const x_val = ctx.getPropertyStr(tile_obj, "x");
        defer ctx.freeValue(x_val);
        const y_val = ctx.getPropertyStr(tile_obj, "y");
        defer ctx.freeValue(y_val);

        const tile_x = ctx.toInt32(x_val) catch 0;
        const tile_y = ctx.toInt32(y_val) catch 0;

        const buf_val = ctx.getPropertyStr(tile_obj, "buffer");
        defer ctx.freeValue(buf_val);

        const buf = ctx.getArrayBuffer(buf_val) catch continue;

        var img_w: c_int = 0;
        var img_h: c_int = 0;
        var channels: c_int = 0;
        const pixels = stbi.stbi_load_from_memory(buf.ptr, @intCast(buf.len), &img_w, &img_h, &channels, 4);

        if (pixels) |px| {
            defer stbi.stbi_image_free(px);
            blitTile(master_buffer, page_width, page_height, px, img_w, img_h, tile_x, tile_y);
        } else {
            std.debug.print("[Compositor] Failed to decode tile at {},{}\n", .{ tile_x, tile_y });
        }
    }

    // ---------------------------------------------------------
    // PHASE 2: Overlay the GeoJSON SVG (via ThorVG)
    // ---------------------------------------------------------
    const svg_str = ctx.toZString(argv[1]) catch return w.UNDEFINED;
    defer ctx.freeZString(svg_str);

    // Use the safe Zig API — rasterizes SVG into RGBA pixels
    const svg_pixels = thorvg.rasterizeSVG(rc.allocator, svg_str, page_width, page_height) catch return w.UNDEFINED;
    defer rc.allocator.free(svg_pixels);

    // Alpha-composite SVG overlay onto master buffer
    const svg_u32: [*]const u32 = @ptrCast(@alignCast(svg_pixels.ptr));
    alphaComposite(master_buffer, svg_u32, buffer_size);

    // ---------------------------------------------------------
    // PHASE 3: Encode PNG (in-memory or to disk)
    // ---------------------------------------------------------
    var filename: ?[]const u8 = null;
    if (argc >= 3 and ctx.isString(argv[2])) {
        filename = ctx.toZString(argv[2]) catch null;
    }
    defer {
        if (filename) |f| ctx.freeZString(f);
    }

    const master_u8: [*]const u8 = @ptrCast(master_buffer.ptr);
    if (filename) |fname| {
        return saveToDisk(fname, master_u8, page_width, page_height);
    } else {
        return encodeToArrayBuffer(ctx, master_u8, page_width, page_height);
    }
}

/// Blit a decoded RGBA tile onto the master ARGB buffer at (tile_x, tile_y).
fn blitTile(
    master: []u32,
    page_w: u32,
    page_h: u32,
    px: [*]const u8,
    img_w: c_int,
    img_h: c_int,
    tile_x: i32,
    tile_y: i32,
) void {
    for (0..@intCast(img_h)) |row| {
        for (0..@intCast(img_w)) |col| {
            const dst_x = @as(i32, @intCast(col)) + tile_x;
            const dst_y = @as(i32, @intCast(row)) + tile_y;

            if (dst_x >= 0 and dst_x < page_w and dst_y >= 0 and dst_y < page_h) {
                const src_idx = (row * @as(usize, @intCast(img_w)) + col) * 4;
                const dst_idx = @as(usize, @intCast(dst_y)) * @as(usize, page_w) + @as(usize, @intCast(dst_x));

                const r = px[src_idx];
                const g = px[src_idx + 1];
                const b = px[src_idx + 2];

                // Pack as ABGR little-endian (matches STB PNG output)
                master[dst_idx] = 0xFF000000 | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
            }
        }
    }
}

/// Alpha-composite an ABGR overlay onto the master ARGB buffer.
fn alphaComposite(master: []u32, overlay: [*]const u32, count: usize) void {
    for (0..count) |i| {
        const src = overlay[i];
        const sa = (src >> 24) & 0xFF;
        if (sa > 0) {
            if (sa == 255) {
                master[i] = src;
            } else {
                const da = 255 - sa;
                const dst = master[i];
                const r_val = ((src & 0xFF) * sa + (dst & 0xFF) * da) / 255;
                const g_val = (((src >> 8) & 0xFF) * sa + ((dst >> 8) & 0xFF) * da) / 255;
                const b_val = (((src >> 16) & 0xFF) * sa + ((dst >> 16) & 0xFF) * da) / 255;
                master[i] = 0xFF000000 | (b_val << 16) | (g_val << 8) | r_val;
            }
        }
    }
}

/// Encode master buffer to PNG and return as JS ArrayBuffer.
fn encodeToArrayBuffer(ctx: w.Context, master_u8: [*]const u8, width: u32, height: u32) w.Value {
    std.debug.print("[Compositor] Generating PNG in memory...\n", .{});
    var out_len: c_int = 0;

    const png_c_ptr = stbi_write_png_to_mem(
        master_u8,
        0,
        @intCast(width),
        @intCast(height),
        4,
        &out_len,
    );

    if (png_c_ptr) |ptr| {
        defer stbiw_free(ptr);
        const js_buffer = ctx.newArrayBufferCopy(ptr[0..@intCast(out_len)]);
        std.debug.print("[Compositor] Returning {} bytes to JS.\n", .{out_len});
        return js_buffer;
    } else {
        std.debug.print("[Compositor] Failed to encode PNG to memory!\n", .{});
        return w.UNDEFINED;
    }
}

/// Save master buffer to disk as PNG.
fn saveToDisk(fname: []const u8, master_u8: [*]const u8, width: u32, height: u32) w.Value {
    std.debug.print("[Compositor] Saving final image to {s}...\n", .{fname});

    const result = stbi_write.stbi_write_png(
        fname.ptr,
        @intCast(width),
        @intCast(height),
        4,
        master_u8,
        @intCast(width * 4),
    );

    if (result == 0) {
        std.debug.print("[Compositor] Failed to write PNG to disk!\n", .{});
    } else {
        std.debug.print("[Compositor] Saved to disk.\n", .{});
    }

    return w.UNDEFINED;
}

//! # Rendering pipeline — library responsibilities
//!
//! ## DECODERS  (compressed bytes → RGBA pixel buffer)
//!
//!   stb_image        PNG, JPEG, GIF, BMP … → RGBA u8 buffer     (js_image_thorvg.zig, js_compositor.zig, js_pdf.zig)
//!   libwebp          WebP                  → RGBA u8 buffer     (js_image_thorvg.zig)
//!   ThorVG           SVG                   → RGBA u32 buffer    (js_image_thorvg.zig via tvg_picture_load_data)
//!
//! ## CANVAS  (the central pixel accumulator — js_canvas.zig)
//!
//!   `Canvas.pixels` is the single RGBA framebuffer everything writes into.
//!
//!   Sources that feed pixels INTO the canvas:
//!     drawImage(Image)     — blits a decoded Image (PNG/JPEG/WebP/SVG) pixel-by-pixel
//!     paintDOM (below)     — compositor renders a full DOM subtree via Yoga+ThorVG then
//!                            copies the ThorVG swcanvas buffer into Canvas.pixels
//!
//!   Text drawn ON the canvas (2D API path):
//!     fillText / strokeText — stb_truetype  (font.zig, uses embedded Roboto-Regular.ttf)
//!                             rasterises glyphs directly into Canvas.pixels
//!
//! ## THREE INDEPENDENT TEXT STACKS
//!
//!   1. stb_truetype   Canvas 2D API   canvas.fillText()   → glyphs blended into Canvas.pixels
//!   2. ThorVG         Compositor      paintDOM() text      → glyphs into ThorVG swcanvas buffer
//!   3. libharu        PDF API         pdf.fillText()       → vector text on PDF page
//!
//!   Each has its own font loading, glyph metrics, and output target. They never share state.
//!
//! ## COMPOSITOR  (DOM → pixel buffer, this file)
//!
//!   Pass 1 — buildYogaTree:   Lexbor DOM → Yoga layout nodes
//!                              CSS parsed via serializeElementStyles → applyInlineStyle
//!                              text measurement via ThorVG tvg_text_new (not added to canvas)
//!
//!   Pass 2 — paintYogaTree:   walks Yoga result, paints into a ThorVG swcanvas:
//!                               backgrounds / borders via tvg_shape_new
//!                               text           via tvg_text_new + tvg_text_set_font
//!                               raster images  via tvg_picture_load_data (PNG/JPEG bytes)
//!                               SVG images     via tvg_picture_load_data (SVG bytes)
//!                               WebP images    decoded to RGBA first (stb_image), then fed as raw pixels
//!
//!   The ThorVG swcanvas buffer is then copied verbatim into the caller's Canvas.pixels.
//!   Text in the compositor uses ThorVG fonts (thorvg.loadEmbeddedFonts), NOT stb_truetype.
//!
//! ## ENCODERS  (RGBA pixel buffer → compressed bytes)
//!
//!   stb_image_write  PNG    — stbi_write_png_to_mem           (js_canvas.zig)
//!   stb_image_write  JPEG   — stbi_write_jpg_to_func          (js_canvas.zig)
//!   libwebp          WebP   — WebPEncodeRGBA / LosslessRGBA   (js_canvas.zig)
//!   libharu          PDF    — reads PNG IHDR for dimensions,
//!                             draws PNG as image on an A4 page (main.zig / js_pdf.zig)
//!
//!   PDF text overlay (js_pdf.zig):
//!     fillText / setFont — libharu HPDF_Page_ShowText, uses its own embedded Roboto copies
//!     drawImageFromBuffer — stbi_load_from_memory (RGB, no alpha) → HPDF raw image
//!
//! ## SUMMARY TABLE
//!
//!   Library          Decode                    Encode / Draw
//!   ─────────────────────────────────────────────────────────────────────────────
//!   stb_image        PNG JPEG GIF BMP WebP*    —
//!   stb_image_write  —                         PNG JPEG
//!   libwebp          WebP                      WebP
//!   ThorVG           SVG (vector)              shapes, text, images → swcanvas buffer
//!   stb_truetype     —                         glyph raster → Canvas.pixels (2D API)
//!   libharu          —                         PDF pages, text, raster images
//!   Yoga             —                         CSS layout → absolute coordinates
//!
//!   * stb_image can decode WebP but libwebp is used directly for better fidelity / alpha support

const std = @import("std");
const builtin = @import("builtin");
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
const hpdf = @cImport({
    @cInclude("hpdf.h");
});

// JPEG-to-buffer callback (stb has no jpeg_to_mem, only jpeg_to_func)
const JpegWriteContext = struct {
    data: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
};
extern fn stbi_write_jpg_to_func(
    func: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void,
    context: ?*anyopaque,
    x: c_int,
    y: c_int,
    comp: c_int,
    data: ?*const anyopaque,
    quality: c_int,
) c_int;
fn stbiJpegWriteCallback(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const jctx: *JpegWriteContext = @ptrCast(@alignCast(context));
    if (data) |d| {
        const slice: []const u8 = @as([*]const u8, @ptrCast(d))[0..@intCast(size)];
        jctx.data.appendSlice(jctx.allocator, slice) catch {};
    }
}

fn localPdfErrorHandler(_: hpdf.HPDF_STATUS, _: hpdf.HPDF_STATUS, _: ?*anyopaque) callconv(.c) void {}

fn saveRgbaAsPdf(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, path: []const u8) !void {
    const doc = hpdf.HPDF_New(&localPdfErrorHandler, null) orelse return error.PdfInitFailed;
    defer hpdf.HPDF_Free(doc);
    _ = hpdf.HPDF_UseUTFEncodings(doc);
    const page = hpdf.HPDF_AddPage(doc);
    const pdf_w: f32 = 595.0;
    const pdf_h: f32 = @as(f32, @floatFromInt(height)) * (pdf_w / @as(f32, @floatFromInt(width)));
    _ = hpdf.HPDF_Page_SetWidth(page, pdf_w);
    _ = hpdf.HPDF_Page_SetHeight(page, pdf_h);
    const pixel_count = @as(usize, width) * height;
    const rgb = try allocator.alloc(u8, pixel_count * 3);
    defer allocator.free(rgb);
    for (0..pixel_count) |i| {
        rgb[i * 3 + 0] = rgba[i * 4 + 0];
        rgb[i * 3 + 1] = rgba[i * 4 + 1];
        rgb[i * 3 + 2] = rgba[i * 4 + 2];
    }
    const hpdf_img = hpdf.HPDF_LoadRawImageFromMem(doc, rgb.ptr, @intCast(width), @intCast(height), hpdf.HPDF_CS_DEVICE_RGB, 8);
    _ = hpdf.HPDF_Page_DrawImage(page, hpdf_img, 0, 0, pdf_w, pdf_h);
    _ = hpdf.HPDF_SaveToFile(doc, path.ptr);
}

fn encodeRgbaAsPdf(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    const doc = hpdf.HPDF_New(&localPdfErrorHandler, null) orelse return error.PdfInitFailed;
    defer hpdf.HPDF_Free(doc);
    _ = hpdf.HPDF_UseUTFEncodings(doc);
    const page = hpdf.HPDF_AddPage(doc);
    const pdf_w: f32 = 595.0;
    const pdf_h: f32 = @as(f32, @floatFromInt(height)) * (pdf_w / @as(f32, @floatFromInt(width)));
    _ = hpdf.HPDF_Page_SetWidth(page, pdf_w);
    _ = hpdf.HPDF_Page_SetHeight(page, pdf_h);
    const pixel_count = @as(usize, width) * height;
    const rgb = try allocator.alloc(u8, pixel_count * 3);
    defer allocator.free(rgb);
    for (0..pixel_count) |i| {
        rgb[i * 3 + 0] = rgba[i * 4 + 0];
        rgb[i * 3 + 1] = rgba[i * 4 + 1];
        rgb[i * 3 + 2] = rgba[i * 4 + 2];
    }
    const hpdf_img = hpdf.HPDF_LoadRawImageFromMem(doc, rgb.ptr, @intCast(width), @intCast(height), hpdf.HPDF_CS_DEVICE_RGB, 8);
    _ = hpdf.HPDF_Page_DrawImage(page, hpdf_img, 0, 0, pdf_w, pdf_h);
    if (hpdf.HPDF_SaveToStream(doc) != hpdf.HPDF_OK) return error.PdfSaveFailed;
    _ = hpdf.HPDF_ResetStream(doc);
    var size = hpdf.HPDF_GetStreamSize(doc);
    if (size == 0) return error.EmptyPdf;
    const buf = try allocator.alloc(u8, size);
    _ = hpdf.HPDF_ReadFromStream(doc, buf.ptr, &size);
    return buf[0..size];
}

const yoga = z.yoga;
const thorvg = z.thorvg;
const Tvg_Canvas = thorvg.Tvg_Canvas;
const Tvg_Paint = thorvg.Tvg_Paint;
const css_color = z.css_color;

// =============================================================================
// Thorvg C-API
// =============================================================================
extern "c" fn tvg_engine_init(threads: c_uint) c_int;
extern "c" fn tvg_engine_term() c_int;
extern "c" fn tvg_swcanvas_create(op: c_uint) ?*Tvg_Canvas;
extern "c" fn tvg_canvas_destroy(canvas: *Tvg_Canvas) c_int;
extern "c" fn tvg_swcanvas_set_target(canvas: *Tvg_Canvas, buffer: [*]u32, stride: u32, w_: u32, h_: u32, cs: c_uint) c_int;
extern "c" fn tvg_canvas_add(canvas: *Tvg_Canvas, paint: *Tvg_Paint) c_int;
extern "c" fn tvg_canvas_draw(canvas: *Tvg_Canvas, clear: bool) c_int;
extern "c" fn tvg_canvas_sync(canvas: *Tvg_Canvas) c_int;
extern "c" fn tvg_shape_new() ?*Tvg_Paint;
extern "c" fn tvg_shape_append_rect(paint: *Tvg_Paint, x: f32, y: f32, w_: f32, h_: f32, rx: f32, ry: f32, cw: bool) c_int;
extern "c" fn tvg_shape_set_fill_color(paint: *Tvg_Paint, r: u8, g: u8, b: u8, a: u8) c_int;
extern "c" fn tvg_text_new() ?*Tvg_Paint;
extern "c" fn tvg_text_set_text(paint: *Tvg_Paint, text: [*c]const u8) c_int;
extern "c" fn tvg_text_set_font(paint: *Tvg_Paint, name: [*c]const u8) c_int;
extern "c" fn tvg_text_set_size(paint: *Tvg_Paint, size: f32) c_int;
extern "c" fn tvg_text_set_color(paint: *Tvg_Paint, r: u8, g: u8, b: u8) c_int;
extern "c" fn tvg_paint_unref(paint: *Tvg_Paint, free: bool) u16;
extern "c" fn tvg_paint_translate(paint: *Tvg_Paint, x: f32, y: f32) c_int;
extern "c" fn tvg_paint_get_aabb(paint: *Tvg_Paint, x: *f32, y: *f32, w_: *f32, h_: *f32) c_int;
extern "c" fn tvg_picture_new() ?*Tvg_Paint;
extern "c" fn tvg_picture_load_data(paint: *Tvg_Paint, data: [*]const u8, size: u32, mimetype: [*c]const u8, rpath: [*c]const u8, copy: bool) c_int;
extern "c" fn tvg_picture_set_size(paint: *Tvg_Paint, w: f32, h: f32) c_int;
extern "c" fn tvg_shape_set_stroke_width(paint: *Tvg_Paint, width: f32) c_int;
extern "c" fn tvg_shape_set_stroke_color(paint: *Tvg_Paint, r: u8, g: u8, b: u8, a: u8) c_int;

const FONT_SIZE: f32 = 16.0;
const CHAR_WIDTH: f32 = 9.0; // approximate monospace width at 16px
const LINE_HEIGHT: f32 = 22.0;

extern fn stbi_write_png_to_mem(
    pixels: [*]const u8,
    stride_in_bytes: c_int,
    x: c_int,
    y: c_int,
    n: c_int,
    out_len: *c_int,
) ?[*]u8;

extern fn WebPEncodeRGBA(rgba: [*]const u8, width: c_int, height: c_int, stride: c_int, quality_factor: f32, output: *[*]u8) usize;
extern fn WebPFree(ptr: ?[*]u8) void;

fn stbiw_free(ptr: ?*anyopaque) void {
    if (ptr) |p| std.c.free(p);
}

// =============================================================================
// Yoga Layout Integration
// =============================================================================

/// Context stored on each Yoga node to link back to the DOM element
const NodeInfo = struct {
    dom_node: *z.DomNode,
    text_content: []const u8, // concatenated textContent of this element
    bg_color: [4]u8, // RGBA
    fg_color: [3]u8, // RGB
    font_size: f32,
    measured_width: f32 = 0, // ThorVG-measured text width (for leaf text elements)
    measured_height: f32 = 0,
    img_data: ?[]const u8 = null, // raw file bytes for <img> elements
    img_is_svg: bool = false, // true → pass "svg" mime to ThorVG, false → auto-detect (PNG/JPEG)
    border_width: f32 = 0,
    border_color: [4]u8 = .{ 0, 0, 0, 0 },
    border_radius: f32 = 0,
    /// Which border sides are active: bit0=top, bit1=right, bit2=bottom, bit3=left.
    /// 0b1111 = all sides (uses rect stroke); partial = individual thin rects.
    border_sides: u4 = 0,
    text_align: enum { left, center, right } = .left,
    /// Number of equal-fr columns from `grid-template-columns: repeat(N, 1fr)`.
    /// Non-zero means this element is a grid container mapped to flex-wrap.
    grid_columns: u32 = 0,
};

/// Measure callback for leaf elements with text — Yoga calls this for intrinsic size
fn textMeasure(
    node: yoga.c.YGNodeConstRef,
    width: f32,
    width_mode: yoga.c.YGMeasureMode,
    _: f32,
    _: yoga.c.YGMeasureMode,
) callconv(.c) yoga.c.YGSize {
    const info: *const NodeInfo = @ptrCast(@alignCast(yoga.c.YGNodeGetContext(node)));
    const natural_w = if (info.measured_width > 0) info.measured_width else blk: {
        const text_len: f32 = @floatFromInt(info.text_content.len);
        break :blk text_len * CHAR_WIDTH;
    };
    const natural_h = if (info.measured_height > 0) info.measured_height else LINE_HEIGHT;

    const result_w = switch (width_mode) {
        yoga.c.YGMeasureModeExactly => width,
        yoga.c.YGMeasureModeAtMost => @min(natural_w, width),
        else => natural_w,
    };

    // If text wraps, estimate height proportionally (avoids ThorVG calls in C callback)
    const result_h: f32 = if (result_w > 0 and natural_w > result_w) blk: {
        const line_count = @ceil(natural_w / result_w);
        break :blk line_count * natural_h;
    } else natural_h;

    return .{ .width = result_w, .height = result_h };
}

/// Recursively collect all textContent from a DOM subtree (like JS .textContent)
fn collectTextContent(node: *z.DomNode, allocator: std.mem.Allocator) []const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 64) catch return "";
    collectTextContentInner(node, &buf, allocator);
    // Collapse whitespace
    const raw = buf.items;
    const collapsed = collapseWhitespace(allocator, raw) orelse return "";
    return collapsed;
}

// Recursive collector
fn collectTextContentInner(node: *z.DomNode, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
    const nt = z.nodeType(node);
    if (nt == .text) {
        const text = z.nodeValue_zc(node);
        buf.appendSlice(allocator, text) catch {};
        return;
    }
    var child = z.firstChild(node);
    while (child) |c_node| : (child = z.nextSibling(c_node)) {
        collectTextContentInner(c_node, buf, allocator);
    }
}

/// Check if an element has any non-inline element children.
/// Known inline elements are treated as text; everything else (including
/// custom elements) is block-level and triggers child recursion.
/// Exception: inline-tagged elements (e.g. <span>) with `background` or
/// `display: block/inline-block` in their style attribute are promoted to
/// block so they get their own Yoga node (coloured pill badges, etc.).
fn hasBlockChildren(node: *z.DomNode) bool {
    var child = z.firstChild(node);
    while (child) |c_node| : (child = z.nextSibling(c_node)) {
        if (z.nodeType(c_node) == .element) {
            if (z.nodeToElement(c_node)) |el| {
                const tag = z.tagName_zc(el);
                if (!isInlineElement(tag)) return true;
                // Inline-tagged element promoted to block if it has a visual box style
                if (z.getAttribute_zc(el, "style")) |s| {
                    if (std.mem.indexOf(u8, s, "background") != null or
                        std.mem.indexOf(u8, s, "display: block") != null or
                        std.mem.indexOf(u8, s, "display:block") != null or
                        std.mem.indexOf(u8, s, "display: inline-block") != null or
                        std.mem.indexOf(u8, s, "display:inline-block") != null or
                        std.mem.indexOf(u8, s, "display: flex") != null or
                        std.mem.indexOf(u8, s, "display:flex") != null)
                    {
                        return true;
                    }
                }
                // Inline element wrapping block-level content (e.g. <a><img></a>)
                if (hasBlockChildren(c_node)) return true;
            }
        }
    }
    return false;
}

fn isInlineElement(tag: []const u8) bool {
    // Lexbor returns uppercase tag names
    const inline_tags = [_][]const u8{
        "SPAN", "A",    "STRONG", "EM",    "B",   "I",   "U",    "S",    "CODE",  "KBD",
        "VAR",  "SAMP", "MARK",   "SMALL", "SUB", "SUP", "ABBR", "CITE", "Q",     "DFN",
        "TIME", "DATA", "RUBY",   "RT",    "RP",  "BDI", "BDO",  "WBR",  "LABEL", "OUTPUT",
    };
    for (inline_tags) |it| {
        if (std.mem.eql(u8, tag, it)) return true;
    }
    return false;
}

/// Returns true when there is at least one non-inline-element child AND every such
/// child has CSS `display: inline-block` or `display: inline-flex`.
/// Used to detect inline formatting contexts, e.g. a row of pill badges inside a div.
fn allBlockChildrenHaveInlineDisplay(node: *z.DomNode, allocator: std.mem.Allocator) bool {
    var found_any = false;
    var child = z.firstChild(node);
    while (child) |c_node| : (child = z.nextSibling(c_node)) {
        if (z.nodeType(c_node) != .element) continue;
        if (z.nodeToElement(c_node)) |el| {
            const tag = z.tagName_zc(el);
            if (isInlineElement(tag)) continue; // known inline — skip
            // Non-inline element child: must declare display:inline-block/inline-flex
            const style_str = z.serializeElementStyles(allocator, el) catch return false;
            defer allocator.free(style_str);
            const is_inline_block =
                std.mem.indexOf(u8, style_str, "display: inline-block") != null or
                std.mem.indexOf(u8, style_str, "display:inline-block") != null or
                std.mem.indexOf(u8, style_str, "display: inline-flex") != null or
                std.mem.indexOf(u8, style_str, "display:inline-flex") != null;
            if (!is_inline_block) return false;
            found_any = true;
        }
    }
    return found_any;
}

fn isRemoteUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "//");
}

/// Resolve a (possibly relative) src against a base URL or directory.
/// Caller owns the returned slice.
///   base = "https://example.com/foo/bar"  + src = "/_next/image?x=1" → "https://example.com/_next/image?x=1"
///   base = "https://example.com/foo/"     + src = "img.png"          → "https://example.com/foo/img.png"
///   base = "some/local/dir"               + src = "img.png"          → "some/local/dir/img.png"
fn resolveUrl(allocator: std.mem.Allocator, base: []const u8, src: []const u8) ![]u8 {
    if (isRemoteUrl(src)) return allocator.dupe(u8, src);
    if (std.mem.startsWith(u8, src, "//"))
        return std.fmt.allocPrint(allocator, "https:{s}", .{src});

    if (isRemoteUrl(base)) {
        if (std.mem.startsWith(u8, src, "/")) {
            // Absolute path: keep only scheme+host from base
            const after_scheme = (std.mem.indexOf(u8, base, "://") orelse return error.BadBase) + 3;
            const host_end = std.mem.indexOfScalarPos(u8, base, after_scheme, '/') orelse base.len;
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0..host_end], src });
        }
        // Relative path: resolve against base directory (strip trailing filename if any).
        // Skip past "://" so we don't mistake the scheme slashes for a path separator.
        const after_scheme = (std.mem.indexOf(u8, base, "://") orelse return error.BadBase) + 3;
        const dir_end = if (std.mem.lastIndexOfScalar(u8, base[after_scheme..], '/')) |d|
            after_scheme + d
        else
            base.len; // bare hostname, no path — use the full base
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base[0..dir_end], src });
    }

    // Local filesystem: simple path join
    return std.fs.path.join(allocator, &.{ base, src });
}

/// Synchronous HTTP GET for an image.
/// `referer` should be the page origin (e.g. "https://demo.vercel.store") so that
/// same-site image proxies (like Next.js /_next/image) accept the request.
/// Accept is restricted to formats our decoders support — avoids AVIF from Vary:Accept servers.
fn fetchImageBytes(allocator: std.mem.Allocator, url: []const u8, referer: ?[]const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ca_bundle = z.curl.allocCABundle(aa) catch {
        std.debug.print("[Compositor] fetchImageBytes: allocCABundle failed\n", .{});
        return null;
    };
    defer ca_bundle.deinit();

    var easy = z.curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch {
        std.debug.print("[Compositor] fetchImageBytes: Easy.init failed\n", .{});
        return null;
    };
    defer easy.deinit();

    const url_z = aa.dupeZ(u8, url) catch return null;
    easy.setUrl(url_z) catch {
        std.debug.print("[Compositor] fetchImageBytes: setUrl failed\n", .{});
        return null;
    };
    z.hardenEasy(easy);

    var headers = z.curl.Easy.Headers{};
    defer headers.deinit();
    headers.add("Accept: image/png,image/jpeg,image/webp,image/gif,image/svg+xml,*/*;q=0.5") catch return null;
    if (referer) |ref| {
        var ref_buf: [2048]u8 = undefined;
        const ref_hdr = std.fmt.bufPrintZ(&ref_buf, "Referer: {s}", .{ref}) catch return null;
        headers.add(ref_hdr) catch return null;
    }
    easy.setHeaders(headers) catch {
        std.debug.print("[Compositor] fetchImageBytes: setHeaders failed\n", .{});
        return null;
    };

    var writer = std.Io.Writer.Allocating.init(allocator);
    easy.setWriter(&writer.writer) catch {
        std.debug.print("[Compositor] fetchImageBytes: setWriter failed\n", .{});
        writer.deinit();
        return null;
    };

    const ret = easy.perform() catch {
        writer.deinit();
        std.debug.print("[Compositor] ⚠️ Failed to fetch image {s}\n", .{url});
        return null;
    };
    if (ret.status_code < 200 or ret.status_code >= 300) {
        writer.deinit();
        std.debug.print("[Compositor] HTTP {} for image: {s}\n", .{ ret.status_code, url });
        return null;
    }
    return writer.toOwnedSlice() catch null;
}

/// Build a Yoga tree from the DOM. Only element nodes become Yoga nodes.
/// Leaf elements (no element children) get their textContent measured as a whole.
fn buildYogaTree(
    dom_node: *z.DomNode,
    allocator: std.mem.Allocator,
    base_dir: []const u8,
) ?yoga.Node {
    const nt = z.nodeType(dom_node);
    if (nt != .element) return null;

    const yg = yoga.nodeNew();

    const info = allocator.create(NodeInfo) catch return null;
    info.* = .{
        .dom_node = dom_node,
        .text_content = "",
        .bg_color = .{ 0, 0, 0, 0 },
        .fg_color = .{ 0, 0, 0 },
        .font_size = FONT_SIZE,
    };

    // Parse computed style (cascade: <link>, <style>, inline) and apply tag defaults
    var has_explicit_flex = false;
    if (z.nodeToElement(dom_node)) |el| {
        const tag = z.tagName_zc(el);

        // Non-visual head elements — skip entirely (never paint their text content)
        const non_visual = [_][]const u8{ "HEAD", "STYLE", "SCRIPT", "LINK", "META", "TITLE", "NOSCRIPT", "TEMPLATE", "BASE" };
        for (non_visual) |skip| {
            if (std.mem.eql(u8, tag, skip)) {
                yoga.nodeFree(yg);
                allocator.destroy(info);
                return null;
            }
        }

        // Use serializeElementStyles to get the full CSS cascade (not just inline style="")
        const style_str = z.serializeElementStyles(allocator, el) catch null;
        defer if (style_str) |s| allocator.free(s);
        if (style_str) |s| {
            if (s.len > 0) {
                applyInlineStyle(yg, info, s);
                // Track whether an explicit flex/grid context was declared in CSS.
                // We use this below to avoid overriding intentional column flex containers.
                has_explicit_flex =
                    std.mem.indexOf(u8, s, "display: flex") != null or
                    std.mem.indexOf(u8, s, "display:flex") != null or
                    std.mem.indexOf(u8, s, "display: grid") != null or
                    std.mem.indexOf(u8, s, "display:grid") != null;
            }
        }

        // Inline-tagged elements (SPAN, A, STRONG, etc.) should never stretch to fill the
        // parent's cross axis — they always shrink-wrap their content.
        if (isInlineElement(tag)) {
            yoga.setAlignSelf(yg, yoga.ALIGN_FLEX_START);
        }

        // Table row defaults: flex-direction row
        if (std.mem.eql(u8, tag, "TR")) {
            yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW);
        }

        // Inline <svg>: serialize to SVG string and pass to ThorVG — do NOT recurse into children.
        // SVG-namespace elements have lowercase tag names in Lexbor (unlike HTML elements which are uppercase).
        if (std.ascii.eqlIgnoreCase(tag, "svg")) {
            if (z.getAttribute_zc(el, "width")) |ws| {
                if (parseFloat(ws)) |v| yoga.setWidth(yg, v);
            }
            if (z.getAttribute_zc(el, "height")) |hs| {
                if (parseFloat(hs)) |v| yoga.setHeight(yg, v);
            }
            if (z.outerHTML(allocator, el)) |svg_str| {
                info.img_data = svg_str;
                info.img_is_svg = true;
            } else |_| {}
        }

        // <img> support: load file bytes and set Yoga dimensions
        if (std.mem.eql(u8, tag, "IMG")) {
            var img_loaded = false;
            if (z.getAttribute_zc(el, "src")) |src| {
                if (src.len > 0) {
                    if (std.mem.startsWith(u8, src, "data:")) {
                        // Decode base64 data URI directly — no file/network fetch needed.
                        // Format: data:[mime][;base64],<payload>
                        if (std.mem.indexOfScalar(u8, src, ',')) |comma| {
                            const header = src[5..comma]; // after "data:"
                            const payload = src[comma + 1 ..];
                            if (std.mem.endsWith(u8, header, ";base64")) {
                                const decoder = std.base64.standard.Decoder;
                                if (decoder.calcSizeForSlice(payload) catch null) |decoded_len| {
                                    if (allocator.alloc(u8, decoded_len) catch null) |buf| {
                                        if (decoder.decode(buf, payload)) {
                                            info.img_data = buf;
                                            info.img_is_svg = std.mem.startsWith(u8, header, "image/svg");

                                            // HTML width/height attributes (e.g. <img width="400">)
                                            var attr_w: f32 = 0;
                                            var attr_h: f32 = 0;
                                            if (z.getAttribute_zc(el, "width")) |ws| attr_w = parseFloat(ws) orelse 0;
                                            if (z.getAttribute_zc(el, "height")) |hs| attr_h = parseFloat(hs) orelse 0;
                                            if (attr_w > 0) yoga.setWidth(yg, attr_w);
                                            if (attr_h > 0) yoga.setHeight(yg, attr_h);

                                            // Natural size fallback via stbi (raster only)
                                            if (attr_w == 0 and attr_h == 0 and !info.img_is_svg) {
                                                var iw: c_int = 0;
                                                var ih: c_int = 0;
                                                var ic: c_int = 0;
                                                if (stbi.stbi_info_from_memory(buf.ptr, @intCast(buf.len), &iw, &ih, &ic) != 0) {
                                                    yoga.setWidth(yg, @floatFromInt(iw));
                                                    yoga.setHeight(yg, @floatFromInt(ih));
                                                }
                                            }

                                            img_loaded = true;
                                        } else |_| allocator.free(buf);
                                    }
                                }
                            }
                        }
                    } else {
                        // Derive origin from base_dir for use as Referer (e.g. "https://demo.vercel.store")
                        const referer: ?[]const u8 = if (isRemoteUrl(base_dir)) blk: {
                            const after_scheme = (std.mem.indexOf(u8, base_dir, "://") orelse break :blk null) + 3;
                            const host_end = std.mem.indexOfScalarPos(u8, base_dir, after_scheme, '/') orelse base_dir.len;
                            break :blk base_dir[0..host_end];
                        } else null;

                        // Resolve src against base_dir (handles relative, absolute-path, and protocol-relative)
                        const resolved = resolveUrl(allocator, base_dir, src) catch null;
                        defer if (resolved) |r| allocator.free(r);
                        const maybe_data: ?[]const u8 = if (resolved) |r| blk: {
                            if (isRemoteUrl(r)) {
                                break :blk fetchImageBytes(allocator, r, referer);
                            } else {
                                break :blk std.fs.cwd().readFileAlloc(allocator, r, 32 * 1024 * 1024) catch {
                                    std.debug.print("⚠️ [Compositor] Failed to load image: {s}\n", .{r});
                                    break :blk null;
                                };
                            }
                        } else null;

                        if (maybe_data) |data| {
                            info.img_data = data;
                            info.img_is_svg = std.mem.endsWith(u8, src, ".svg") or
                                std.mem.endsWith(u8, src, ".svg?v=1") or
                                std.mem.indexOf(u8, src, ".svg?") != null;

                            // 1. HTML width/height attributes
                            var attr_w: f32 = 0;
                            var attr_h: f32 = 0;
                            if (z.getAttribute_zc(el, "width")) |ws| attr_w = parseFloat(ws) orelse 0;
                            if (z.getAttribute_zc(el, "height")) |hs| attr_h = parseFloat(hs) orelse 0;
                            if (attr_w > 0) yoga.setWidth(yg, attr_w);
                            if (attr_h > 0) yoga.setHeight(yg, attr_h);

                            // 2. Natural size fallback via stbi (raster only)
                            if (attr_w == 0 and attr_h == 0 and !info.img_is_svg) {
                                var iw: c_int = 0;
                                var ih: c_int = 0;
                                var ic: c_int = 0;
                                if (stbi.stbi_info_from_memory(data.ptr, @intCast(data.len), &iw, &ih, &ic) != 0) {
                                    yoga.setWidth(yg, @floatFromInt(iw));
                                    yoga.setHeight(yg, @floatFromInt(ih));
                                }
                            }
                            img_loaded = true;
                        }
                    }
                }
            }
            // Alt-text fallback when image couldn't be loaded
            if (!img_loaded) {
                if (z.getAttribute_zc(el, "alt")) |alt| {
                    if (alt.len > 0) {
                        info.text_content = allocator.dupe(u8, alt) catch alt;
                    }
                }
                // If no alt text either, reserve a minimum placeholder size
                if (info.text_content.len == 0) {
                    yoga.setMinWidth(yg, 64);
                    yoga.setMinHeight(yg, 64);
                }
            }
        }
    }

    yoga.setContext(yg, info);

    // Inline SVG and <img> with loaded data are leaf nodes — don't recurse into DOM children
    if (info.img_is_svg and info.img_data != null) return yg;

    // Inline formatting context: when a plain block container has only inline-block children
    // (e.g. a div full of badge/pill elements), switch to row+wrap so they flow horizontally.
    // Skip when CSS already set an explicit flex/grid context on this element.
    if (!has_explicit_flex and allBlockChildrenHaveInlineDisplay(dom_node, allocator)) {
        yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW);
        yoga.setFlexWrap(yg, yoga.WRAP_WRAP);
        yoga.setAlignItems(yg, yoga.ALIGN_FLEX_START);
    }

    if (hasBlockChildren(dom_node)) {
        // Has element children → recurse into them
        var child_idx: usize = 0;
        var child = z.firstChild(dom_node);
        while (child) |c_node| : (child = z.nextSibling(c_node)) {
            if (buildYogaTree(c_node, allocator, base_dir)) |child_yg| {
                yoga.insertChild(yg, child_yg, child_idx);
                child_idx += 1;
            }
        }

        // Grid repeat(N, 1fr): give each child a percentage width = 100/N.
        // Applied after all children are inserted so the count is known.
        if (info.grid_columns > 0 and child_idx > 0) {
            const child_pct = 100.0 / @as(f32, @floatFromInt(info.grid_columns));
            for (0..child_idx) |ci| {
                const child_yg = yoga.getChild(yg, ci);
                yoga.setWidthPercent(child_yg, child_pct);
            }
        }
    } else {
        // Leaf element → collect all text, measure it, use as intrinsic size
        // (text_content may already be set by <img> alt-text fallback)
        const text = if (info.text_content.len > 0)
            info.text_content
        else
            collectTextContent(dom_node, allocator);
        if (text.len > 0) {
            info.text_content = text;
            const measured = measureText(allocator, text, info.font_size);
            info.measured_width = measured.w;
            info.measured_height = measured.h;
            yoga.setNodeType(yg, yoga.NODE_TYPE_TEXT);
            yoga.setMeasureFunc(yg, textMeasure);
        }
    }

    return yg;
}

/// Parse "repeat(N, 1fr)" or "repeat(N, Xfr)" → N columns.
/// Returns null for non-repeat values, named lines, auto, mixed track types, etc.
/// Only equal-fr tracks are handled — anything else falls through to pass-through.
fn parseRepeatNFr(val: []const u8) ?u32 {
    const v = std.mem.trim(u8, val, " \t");
    if (!std.mem.startsWith(u8, v, "repeat(")) return null;
    const inner_start = "repeat(".len;
    const paren_end = std.mem.lastIndexOfScalar(u8, v, ')') orelse return null;
    if (paren_end <= inner_start) return null;
    const inner = v[inner_start..paren_end];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return null;
    const n_str = std.mem.trim(u8, inner[0..comma], " \t");
    const track = std.mem.trim(u8, inner[comma + 1 ..], " \t");
    // Require an "fr" unit — equal-fraction tracks only.
    if (std.mem.indexOf(u8, track, "fr") == null) return null;
    return std.fmt.parseInt(u32, n_str, 10) catch null;
}

/// Parse a CSS inline style string and apply properties to a Yoga node
fn applyInlineStyle(yg: yoga.Node, info: *NodeInfo, style: []const u8) void {
    // Grid normalisation state — collected during the single pass, applied after the loop.
    // `display: grid` maps to flex; the axis, wrap, and alignment are derived from the
    // companion grid properties.
    var is_grid = false;
    var grid_columns: u32 = 0; // from repeat(N, 1fr)
    var grid_auto_flow_col = false; // grid-auto-flow: column
    var grid_place_items_center = false; // place-items: center

    var iter = std.mem.splitSequence(u8, style, ";");
    while (iter.next()) |decl| {
        const trimmed = std.mem.trim(u8, decl, " \t\n\r");
        if (trimmed.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const prop = std.mem.trim(u8, trimmed[0..colon], " \t");
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

        if (std.mem.eql(u8, prop, "display")) {
            if (std.mem.eql(u8, val, "flex")) {
                yoga.setDisplay(yg, yoga.DISPLAY_FLEX);
                // CSS flex default direction is row; Yoga's default is column — must align them.
                // An explicit flex-direction: column later in the cascade will override this.
                yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW);
            } else if (std.mem.eql(u8, val, "grid")) {
                // Defer actual Yoga calls — collect remaining grid props first.
                is_grid = true;
            } else if (std.mem.eql(u8, val, "none")) {
                yoga.setDisplay(yg, yoga.DISPLAY_NONE);
            } else if (std.mem.eql(u8, val, "inline-block") or std.mem.eql(u8, val, "inline-flex")) {
                // inline-block/inline-flex: behaves like block but shrinks to intrinsic width.
                // Map to align-self: flex-start so the element doesn't stretch in the parent's cross axis.
                yoga.setAlignSelf(yg, yoga.ALIGN_FLEX_START);
            }
        } else if (std.mem.eql(u8, prop, "grid-template-columns")) {
            grid_columns = parseRepeatNFr(val) orelse 0;
        } else if (std.mem.eql(u8, prop, "grid-auto-flow")) {
            grid_auto_flow_col = std.mem.eql(u8, val, "column");
        } else if (std.mem.eql(u8, prop, "place-items")) {
            // "place-items: <align> <justify>" shorthand; single-value = both axes.
            // We support the common "center" case; others fall through.
            const first_token = std.mem.trim(u8, std.mem.sliceTo(val, ' '), " \t");
            grid_place_items_center = std.mem.eql(u8, first_token, "center");
        } else if (std.mem.eql(u8, prop, "flex-direction")) {
            if (std.mem.eql(u8, val, "row")) {
                yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW);
            } else if (std.mem.eql(u8, val, "column")) {
                yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_COLUMN);
            } else if (std.mem.eql(u8, val, "row-reverse")) {
                yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW_REVERSE);
            } else if (std.mem.eql(u8, val, "column-reverse")) {
                yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_COLUMN_REVERSE);
            }
        } else if (std.mem.eql(u8, prop, "justify-content")) {
            if (std.mem.eql(u8, val, "center")) {
                yoga.setJustifyContent(yg, yoga.JUSTIFY_CENTER);
            } else if (std.mem.eql(u8, val, "flex-start")) {
                yoga.setJustifyContent(yg, yoga.JUSTIFY_FLEX_START);
            } else if (std.mem.eql(u8, val, "flex-end")) {
                yoga.setJustifyContent(yg, yoga.JUSTIFY_FLEX_END);
            } else if (std.mem.eql(u8, val, "space-between")) {
                yoga.setJustifyContent(yg, yoga.JUSTIFY_SPACE_BETWEEN);
            } else if (std.mem.eql(u8, val, "space-around")) {
                yoga.setJustifyContent(yg, yoga.JUSTIFY_SPACE_AROUND);
            }
        } else if (std.mem.eql(u8, prop, "align-items")) {
            if (std.mem.eql(u8, val, "center")) {
                yoga.setAlignItems(yg, yoga.ALIGN_CENTER);
            } else if (std.mem.eql(u8, val, "flex-start")) {
                yoga.setAlignItems(yg, yoga.ALIGN_FLEX_START);
            } else if (std.mem.eql(u8, val, "flex-end")) {
                yoga.setAlignItems(yg, yoga.ALIGN_FLEX_END);
            } else if (std.mem.eql(u8, val, "stretch")) {
                yoga.setAlignItems(yg, yoga.ALIGN_STRETCH);
            }
        } else if (std.mem.eql(u8, prop, "flex-wrap")) {
            if (std.mem.eql(u8, val, "wrap")) {
                yoga.setFlexWrap(yg, yoga.WRAP_WRAP);
            } else if (std.mem.eql(u8, val, "nowrap")) {
                yoga.setFlexWrap(yg, yoga.WRAP_NO_WRAP);
            }
        } else if (std.mem.eql(u8, prop, "flex-grow")) {
            if (parseFloat(val)) |v| yoga.setFlexGrow(yg, v);
        } else if (std.mem.eql(u8, prop, "flex-shrink")) {
            if (parseFloat(val)) |v| yoga.setFlexShrink(yg, v);
        } else if (std.mem.eql(u8, prop, "width")) {
            applyDimension(yg, val, yoga.setWidth, yoga.setWidthPercent);
        } else if (std.mem.eql(u8, prop, "height")) {
            applyDimension(yg, val, yoga.setHeight, yoga.setHeightPercent);
        } else if (std.mem.eql(u8, prop, "min-width")) {
            applyDimension(yg, val, yoga.setMinWidth, null);
        } else if (std.mem.eql(u8, prop, "min-height")) {
            applyDimension(yg, val, yoga.setMinHeight, null);
        } else if (std.mem.eql(u8, prop, "max-width")) {
            applyDimension(yg, val, yoga.setMaxWidth, null);
        } else if (std.mem.eql(u8, prop, "max-height")) {
            applyDimension(yg, val, yoga.setMaxHeight, null);
        } else if (std.mem.eql(u8, prop, "padding")) {
            const bv = parseBoxShorthand(val);
            if (bv.top) |v| yoga.setPadding(yg, yoga.EDGE_TOP, v);
            if (bv.right) |v| yoga.setPadding(yg, yoga.EDGE_RIGHT, v);
            if (bv.bottom) |v| yoga.setPadding(yg, yoga.EDGE_BOTTOM, v);
            if (bv.left) |v| yoga.setPadding(yg, yoga.EDGE_LEFT, v);
        } else if (std.mem.eql(u8, prop, "padding-left")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_LEFT, v);
        } else if (std.mem.eql(u8, prop, "padding-right")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_RIGHT, v);
        } else if (std.mem.eql(u8, prop, "padding-top")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_TOP, v);
        } else if (std.mem.eql(u8, prop, "padding-bottom")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_BOTTOM, v);
        } else if (std.mem.eql(u8, prop, "margin")) {
            const bv = parseBoxShorthand(val);
            if (bv.top) |v| yoga.setMargin(yg, yoga.EDGE_TOP, v);
            if (bv.right) |v| yoga.setMargin(yg, yoga.EDGE_RIGHT, v);
            if (bv.bottom) |v| yoga.setMargin(yg, yoga.EDGE_BOTTOM, v);
            if (bv.left) |v| yoga.setMargin(yg, yoga.EDGE_LEFT, v);
        } else if (std.mem.eql(u8, prop, "margin-left")) {
            if (parsePixelValue(val)) |v| yoga.setMargin(yg, yoga.EDGE_LEFT, v);
        } else if (std.mem.eql(u8, prop, "margin-right")) {
            if (parsePixelValue(val)) |v| yoga.setMargin(yg, yoga.EDGE_RIGHT, v);
        } else if (std.mem.eql(u8, prop, "margin-top")) {
            if (parsePixelValue(val)) |v| yoga.setMargin(yg, yoga.EDGE_TOP, v);
        } else if (std.mem.eql(u8, prop, "margin-bottom")) {
            if (parsePixelValue(val)) |v| yoga.setMargin(yg, yoga.EDGE_BOTTOM, v);
        } else if (std.mem.eql(u8, prop, "gap")) {
            if (parsePixelValue(val)) |v| yoga.setGap(yg, yoga.c.YGGutterAll, v);
        } else if (std.mem.eql(u8, prop, "background") or std.mem.eql(u8, prop, "background-color") or std.mem.eql(u8, prop, "fill")) {
            if (parseCSSColor(val)) |clr| {
                info.bg_color = clr;
            }
        } else if (std.mem.eql(u8, prop, "color")) {
            if (parseCSSColor(val)) |clr| {
                info.fg_color = .{ clr[0], clr[1], clr[2] };
            }
        } else if (std.mem.eql(u8, prop, "font-family")) {
            // monospace hint — adjust char width
            if (std.mem.indexOf(u8, val, "monospace") != null) {
                info.font_size = FONT_SIZE;
            }
        } else if (std.mem.eql(u8, prop, "font-size")) {
            if (parsePixelValue(val)) |v| {
                info.font_size = v;
            }
        } else if (std.mem.eql(u8, prop, "border")) {
            parseBorderShorthand(val, info);
            info.border_sides = 0b1111;
        } else if (std.mem.eql(u8, prop, "border-top")) {
            parseBorderShorthand(val, info);
            info.border_sides |= 0b0001;
        } else if (std.mem.eql(u8, prop, "border-right")) {
            parseBorderShorthand(val, info);
            info.border_sides |= 0b0010;
        } else if (std.mem.eql(u8, prop, "border-bottom")) {
            parseBorderShorthand(val, info);
            info.border_sides |= 0b0100;
        } else if (std.mem.eql(u8, prop, "border-left")) {
            parseBorderShorthand(val, info);
            info.border_sides |= 0b1000;
        } else if (std.mem.eql(u8, prop, "border-width") or
            std.mem.eql(u8, prop, "border-top-width") or
            std.mem.eql(u8, prop, "border-right-width") or
            std.mem.eql(u8, prop, "border-bottom-width") or
            std.mem.eql(u8, prop, "border-left-width"))
        {
            if (parsePixelValue(val)) |v| info.border_width = @max(info.border_width, v);
        } else if (std.mem.eql(u8, prop, "border-color") or
            std.mem.eql(u8, prop, "border-top-color") or
            std.mem.eql(u8, prop, "border-right-color") or
            std.mem.eql(u8, prop, "border-bottom-color") or
            std.mem.eql(u8, prop, "border-left-color"))
        {
            if (parseCSSColor(val)) |clr| info.border_color = clr;
        } else if (std.mem.eql(u8, prop, "border-radius")) {
            if (parsePixelValue(val)) |v| info.border_radius = v;
        } else if (std.mem.eql(u8, prop, "text-align")) {
            if (std.mem.eql(u8, val, "center")) {
                info.text_align = .center;
            } else if (std.mem.eql(u8, val, "right")) {
                info.text_align = .right;
            } else if (std.mem.eql(u8, val, "left")) {
                info.text_align = .left;
            }
        } else if (std.mem.eql(u8, prop, "position")) {
            if (std.mem.eql(u8, val, "absolute")) {
                yoga.setPositionType(yg, yoga.POSITION_ABSOLUTE);
            }
        } else if (std.mem.eql(u8, prop, "top")) {
            if (parsePixelValue(val)) |v| yoga.setPosition(yg, yoga.EDGE_TOP, v);
        } else if (std.mem.eql(u8, prop, "right")) {
            if (parsePixelValue(val)) |v| yoga.setPosition(yg, yoga.EDGE_RIGHT, v);
        } else if (std.mem.eql(u8, prop, "bottom")) {
            if (parsePixelValue(val)) |v| yoga.setPosition(yg, yoga.EDGE_BOTTOM, v);
        } else if (std.mem.eql(u8, prop, "left")) {
            if (parsePixelValue(val)) |v| yoga.setPosition(yg, yoga.EDGE_LEFT, v);
        }
    }

    // -------------------------------------------------------------------------
    // Grid → Flex normalisation (applied after all properties are collected)
    // -------------------------------------------------------------------------
    // Supported 1D patterns:
    //   repeat(N, 1fr)          → flex-wrap row, children get 100/N % width
    //   grid-auto-flow: column  → flex row (no wrap; items flow horizontally)
    //   place-items: center     → align-items + justify-content center
    //   gap                     → already handled above (Yoga native gap)
    //
    // Hard limits: 2D layout, grid-template-areas, mixed track types,
    //              and child span > 1 are NOT supported.
    if (is_grid) {
        yoga.setDisplay(yg, yoga.DISPLAY_FLEX);

        if (grid_auto_flow_col) {
            // Items fill columns first (left→right) — map to flex row, no wrap.
            yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW);
        } else if (grid_columns > 1) {
            // N equal columns — map to wrapping flex row.
            // Child widths (100/N %) are applied in buildYogaTree after children are built.
            yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW);
            yoga.setFlexWrap(yg, yoga.WRAP_WRAP);
        } else {
            // Fallback: single-column or unrecognised template → column flex.
            yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_COLUMN);
        }

        if (grid_place_items_center) {
            yoga.setAlignItems(yg, yoga.ALIGN_CENTER);
            yoga.setJustifyContent(yg, yoga.JUSTIFY_CENTER);
        }

        // Store column count so buildYogaTree can size children.
        info.grid_columns = grid_columns;
    }
}

/// Parse a CSS box shorthand (padding / margin) with 1–4 space-separated values.
/// Returns .{ top, right, bottom, left } following standard CSS expansion rules:
///   1 val  → all sides
///   2 vals → top/bottom | left/right
///   3 vals → top | left/right | bottom
///   4 vals → top | right | bottom | left
const BoxValues = struct { top: ?f32, right: ?f32, bottom: ?f32, left: ?f32 };
fn parseBoxShorthand(val: []const u8) BoxValues {
    var parts: [4]?f32 = .{ null, null, null, null };
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, val, " \t");
    while (tokens.next()) |tok| {
        if (count >= 4) break;
        parts[count] = parsePixelValue(tok);
        count += 1;
    }
    return switch (count) {
        1 => .{ .top = parts[0], .right = parts[0], .bottom = parts[0], .left = parts[0] },
        2 => .{ .top = parts[0], .right = parts[1], .bottom = parts[0], .left = parts[1] },
        3 => .{ .top = parts[0], .right = parts[1], .bottom = parts[2], .left = parts[1] },
        4 => .{ .top = parts[0], .right = parts[1], .bottom = parts[2], .left = parts[3] },
        else => .{ .top = null, .right = null, .bottom = null, .left = null },
    };
}

/// Parse "1px solid #color" border shorthand — extracts width and color, ignores style keyword
fn parseBorderShorthand(val: []const u8, info: *NodeInfo) void {
    var iter = std.mem.splitScalar(u8, val, ' ');
    while (iter.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (t.len == 0) continue;
        if (parsePixelValue(t)) |v| {
            info.border_width = @max(info.border_width, v);
        } else if (parseCSSColor(t)) |clr| {
            info.border_color = clr;
        }
        // "solid", "dashed", "dotted" — ignored, we only render solid
    }
}

fn applyDimension(
    yg: yoga.Node,
    val: []const u8,
    set_px: fn (yoga.Node, f32) void,
    set_pct: ?fn (yoga.Node, f32) void,
) void {
    if (std.mem.endsWith(u8, val, "%")) {
        if (set_pct) |setter| {
            if (parseFloat(val[0 .. val.len - 1])) |v| setter(yg, v);
        }
    } else if (std.mem.eql(u8, val, "auto")) {
        // auto is the default, nothing to set
    } else {
        if (parsePixelValue(val)) |v| set_px(yg, v);
    }
}

fn parsePixelValue(val: []const u8) ?f32 {
    // Strip "px" suffix if present
    const num = if (std.mem.endsWith(u8, val, "px"))
        val[0 .. val.len - 2]
    else
        val;
    return parseFloat(num);
}

fn parseFloat(s: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, s) catch null;
}

/// Measure text dimensions using ThorVG (requires engine + font already loaded)
fn measureText(allocator: std.mem.Allocator, text: []const u8, font_size: f32) struct { w: f32, h: f32 } {
    const paint = tvg_text_new() orelse return .{ .w = 0, .h = 0 };
    // Not added to canvas — must be freed manually (canvas_add transfers ownership).
    defer _ = tvg_paint_unref(paint, true);

    const c_str = allocator.dupeZ(u8, text) catch return .{ .w = 0, .h = 0 };
    defer allocator.free(c_str);

    _ = tvg_text_set_font(paint, "Roboto");
    _ = tvg_text_set_size(paint, font_size);
    _ = tvg_text_set_text(paint, c_str.ptr);

    var bx: f32 = 0;
    var by: f32 = 0;
    var bw: f32 = 0;
    var bh: f32 = 0;
    const rc = tvg_paint_get_aabb(paint, &bx, &by, &bw, &bh);
    if (rc == 0) {
        // aabb returns (x, y) origin + (w, h) size; total extent = origin + size
        return .{ .w = bx + bw, .h = by + bh };
    }
    return .{ .w = 0, .h = 0 };
}

/// __native_measureText(text: string, fontSize: number) → { width: number, height: number }
/// Measures pixel dimensions of text rendered in Roboto at the given font size.
/// Uses ThorVG layout — results match SVG paintSVG output exactly.
/// Useful for dynamic SVG text wrapping without a browser geometry engine.
pub fn js_measureText(ctx_ptr: ?*z.qjs.JSContext, _: z.qjs.JSValue, argc: c_int, argv: [*c]z.qjs.JSValue) callconv(.c) z.qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 2) return ctx.throwTypeError("measureText(text, fontSize) requires two arguments");
    const rc = RuntimeContext.get(ctx);

    const text_c = ctx.toCString(argv[0]) catch return w.UNDEFINED;
    defer ctx.freeCString(text_c);
    const font_size: f32 = @floatCast(ctx.toFloat64(argv[1]) catch return w.UNDEFINED);

    _ = tvg_engine_init(0);
    defer _ = tvg_engine_term();
    thorvg.loadEmbeddedFonts() catch {};

    const dims = measureText(rc.allocator, std.mem.span(text_c), font_size);

    const obj = ctx.newObject();
    ctx.setPropertyStr(obj, "width", ctx.newFloat64(dims.w)) catch return w.UNDEFINED;
    ctx.setPropertyStr(obj, "height", ctx.newFloat64(dims.h)) catch return w.UNDEFINED;
    return obj;
}

/// Split text into lines that fit within max_width at the given font_size.
/// Each returned string is allocated from allocator. Caller owns the slice.
fn wordWrapText(
    allocator: std.mem.Allocator,
    text: []const u8,
    font_size: f32,
    max_width: f32,
) [][]const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    var current: std.ArrayListUnmanaged(u8) = .empty;

    var words = std.mem.tokenizeAny(u8, text, " \t\n\r");
    while (words.next()) |word| {
        const needs_sep = current.items.len > 0;
        // Build candidate: current + " " + word
        const cand_len = current.items.len + (if (needs_sep) @as(usize, 1) else 0) + word.len;
        const cand = allocator.alloc(u8, cand_len) catch continue;
        defer allocator.free(cand);
        var ci: usize = 0;
        @memcpy(cand[ci .. ci + current.items.len], current.items);
        ci += current.items.len;
        if (needs_sep) {
            cand[ci] = ' ';
            ci += 1;
        }
        @memcpy(cand[ci..], word);

        const m = measureText(allocator, cand, font_size);
        if (m.w <= max_width or current.items.len == 0) {
            current.clearRetainingCapacity();
            current.appendSlice(allocator, cand) catch {};
        } else {
            // Flush current line, start new one with this word
            result.append(allocator, allocator.dupe(u8, current.items) catch "") catch {};
            current.clearRetainingCapacity();
            current.appendSlice(allocator, word) catch {};
        }
    }
    if (current.items.len > 0) {
        result.append(allocator, allocator.dupe(u8, current.items) catch "") catch {};
    }
    current.deinit(allocator);

    if (result.items.len == 0) {
        // Fallback: single line with original text
        result.append(allocator, allocator.dupe(u8, text) catch "") catch {};
    }
    return result.toOwnedSlice(allocator) catch result.items;
}

/// Collapse whitespace CSS-style: runs of whitespace → single space.
/// Returns null on allocation failure. Returns empty slice if all whitespace.
fn collapseWhitespace(allocator: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    // Quick check: is it all whitespace?
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    if (trimmed.len == 0) return "";

    var buf = allocator.alloc(u8, raw.len) catch return null;
    var len: usize = 0;
    var in_ws = false;
    for (raw) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
            if (!in_ws) {
                buf[len] = ' ';
                len += 1;
                in_ws = true;
            }
        } else {
            buf[len] = ch;
            len += 1;
            in_ws = false;
        }
    }
    return buf[0..len];
}

/// Parse CSS color values: named keywords, #hex, rgb(), rgba().
/// Covers all formats that Lexbor's serializer may emit.
fn parseCSSColor(val: []const u8) ?[4]u8 {
    // Named colors — O(1) lookup via the full 148-entry StaticStringMap in css_color.zig.
    // Lowercase into a stack buffer first (CSS color names are case-insensitive).
    if (val.len <= 32) {
        var buf: [32]u8 = undefined;
        const lc = std.ascii.lowerString(buf[0..val.len], val);
        if (css_color.NamedColors.get(lc)) |c| return .{ c.r, c.g, c.b, c.a };
    }

    // #RGB, #RRGGBB, #RRGGBBAA
    if (val.len > 0 and val[0] == '#') {
        const hex = val[1..];
        if (hex.len == 3) {
            const r = parseHexNibble(hex[0]) orelse return null;
            const g = parseHexNibble(hex[1]) orelse return null;
            const b = parseHexNibble(hex[2]) orelse return null;
            return .{ r | (r << 4), g | (g << 4), b | (b << 4), 255 };
        } else if (hex.len == 6) {
            const r = parseHexByte(hex[0..2]) orelse return null;
            const g = parseHexByte(hex[2..4]) orelse return null;
            const b = parseHexByte(hex[4..6]) orelse return null;
            return .{ r, g, b, 255 };
        } else if (hex.len == 8) {
            const r = parseHexByte(hex[0..2]) orelse return null;
            const g = parseHexByte(hex[2..4]) orelse return null;
            const b = parseHexByte(hex[4..6]) orelse return null;
            const a = parseHexByte(hex[6..8]) orelse return null;
            return .{ r, g, b, a };
        }
    }

    // rgb(r, g, b) and rgba(r, g, b, a) — Lexbor may emit this format
    const is_rgba = std.mem.startsWith(u8, val, "rgba(");
    const is_rgb = std.mem.startsWith(u8, val, "rgb(");
    if (is_rgb or is_rgba) {
        const paren_open = std.mem.indexOfScalar(u8, val, '(') orelse return null;
        const paren_close = std.mem.lastIndexOfScalar(u8, val, ')') orelse return null;
        if (paren_close <= paren_open) return null;
        const inner = val[paren_open + 1 .. paren_close];
        // Split on commas; allow spaces
        var parts: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |tok| {
            if (count >= 4) break;
            parts[count] = std.mem.trim(u8, tok, " \t");
            count += 1;
        }
        if (count < 3) return null;
        const r: u8 = @intFromFloat(@min(255.0, @max(0.0, parseFloat(parts[0]) orelse return null)));
        const g: u8 = @intFromFloat(@min(255.0, @max(0.0, parseFloat(parts[1]) orelse return null)));
        const b: u8 = @intFromFloat(@min(255.0, @max(0.0, parseFloat(parts[2]) orelse return null)));
        const a: u8 = if (count >= 4) blk: {
            const af = parseFloat(parts[3]) orelse 1.0;
            // alpha may be 0..1 (float) or 0..255 (integer)
            break :blk if (af <= 1.0)
                @intFromFloat(@min(255.0, af * 255.0))
            else
                @intFromFloat(@min(255.0, af));
        } else 255;
        return .{ r, g, b, a };
    }

    return null;
}

fn parseHexNibble(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn parseHexByte(hex: *const [2]u8) ?u8 {
    const hi = parseHexNibble(hex[0]) orelse return null;
    const lo = parseHexNibble(hex[1]) orelse return null;
    return (hi << 4) | lo;
}

/// Result of searching for a DOM node in the post-layout Yoga tree
const FoundYogaNode = struct {
    abs_x: f32,
    abs_y: f32,
    width: f32,
    height: f32,
};

/// Depth-first search: find the Yoga node whose NodeInfo.dom_node matches `target`.
/// Accumulates absolute x/y by summing yoga.getLeft/getTop down the tree
/// as nodes know only their position relative to thier parent
fn findYogaNode(
    yg: yoga.Node,
    target: *z.DomNode,
    parent_x: f32,
    parent_y: f32,
) ?FoundYogaNode {
    const ctx_ptr = yoga.getContext(yg) orelse return null;
    const info: *const NodeInfo = @ptrCast(@alignCast(ctx_ptr));
    const x = parent_x + yoga.getLeft(yg);
    const y = parent_y + yoga.getTop(yg);

    if (info.dom_node == target) {
        return .{
            .abs_x = x,
            .abs_y = y,
            .width = yoga.getWidth(yg),
            .height = yoga.getHeight(yg),
        };
    }

    const child_count = yoga.getChildCount(yg);
    for (0..child_count) |i| {
        if (findYogaNode(yoga.getChild(yg, i), target, x, y)) |found| return found;
    }
    return null;
}

/// Walk the Yoga tree after layout and paint each node using ThorVG
fn paintYogaTree(
    yg: yoga.Node,
    canvas: *Tvg_Canvas,
    parent_x: f32,
    parent_y: f32,
    parent_fg: [3]u8,
    allocator: std.mem.Allocator,
) void {
    const info: *const NodeInfo = @ptrCast(@alignCast(yoga.getContext(yg) orelse return));
    const x = parent_x + yoga.getLeft(yg);
    const y = parent_y + yoga.getTop(yg);
    const node_w = yoga.getWidth(yg);
    const node_h = yoga.getHeight(yg);

    // Guard against degenerate Yoga values.
    // ThorVG's TO_SWCOORD does `int32(v * 64)` — overflows at v > ~33M.
    // Use 100K as a safe cap; also skip zero/negative and NaN/Inf.
    const MAX_TVG: f32 = 100_000.0;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(node_w) or !std.math.isFinite(node_h) or
        @abs(x) > MAX_TVG or @abs(y) > MAX_TVG or
        node_w <= 0 or node_w > MAX_TVG or
        node_h <= 0 or node_h > MAX_TVG) return;

    // Determine text color: inherit from parent if not explicitly set
    const fg = if (info.fg_color[0] != 0 or info.fg_color[1] != 0 or info.fg_color[2] != 0)
        info.fg_color
    else
        parent_fg;

    // Paint background rect
    if (info.bg_color[3] > 0) {
        const shape = tvg_shape_new() orelse return;
        const r = info.border_radius;
        _ = tvg_shape_append_rect(shape, x, y, node_w, node_h, r, r, true);
        _ = tvg_shape_set_fill_color(shape, info.bg_color[0], info.bg_color[1], info.bg_color[2], info.bg_color[3]);
        _ = tvg_canvas_add(canvas, shape);
    }

    // Paint border — all 4 sides: rect stroke; individual sides: thin filled rects
    if (info.border_sides > 0 and info.border_width > 0 and info.border_color[3] > 0) {
        const bw = info.border_width;
        const bc = info.border_color;
        if (info.border_sides == 0b1111) {
            // All sides: rect stroke (honours border_radius)
            const shape = tvg_shape_new() orelse return;
            const r = info.border_radius;
            _ = tvg_shape_append_rect(shape, x, y, node_w, node_h, r, r, true);
            _ = tvg_shape_set_stroke_width(shape, bw);
            _ = tvg_shape_set_stroke_color(shape, bc[0], bc[1], bc[2], bc[3]);
            _ = tvg_canvas_add(canvas, shape);
        } else {
            // Individual sides: thin filled rects (no radius)
            if (info.border_sides & 0b0001 != 0) { // top
                if (tvg_shape_new()) |s| {
                    _ = tvg_shape_append_rect(s, x, y, node_w, bw, 0, 0, true);
                    _ = tvg_shape_set_fill_color(s, bc[0], bc[1], bc[2], bc[3]);
                    _ = tvg_canvas_add(canvas, s);
                }
            }
            if (info.border_sides & 0b0010 != 0) { // right
                if (tvg_shape_new()) |s| {
                    _ = tvg_shape_append_rect(s, x + node_w - bw, y, bw, node_h, 0, 0, true);
                    _ = tvg_shape_set_fill_color(s, bc[0], bc[1], bc[2], bc[3]);
                    _ = tvg_canvas_add(canvas, s);
                }
            }
            if (info.border_sides & 0b0100 != 0) { // bottom
                if (tvg_shape_new()) |s| {
                    _ = tvg_shape_append_rect(s, x, y + node_h - bw, node_w, bw, 0, 0, true);
                    _ = tvg_shape_set_fill_color(s, bc[0], bc[1], bc[2], bc[3]);
                    _ = tvg_canvas_add(canvas, s);
                }
            }
            if (info.border_sides & 0b1000 != 0) { // left
                if (tvg_shape_new()) |s| {
                    _ = tvg_shape_append_rect(s, x, y, bw, node_h, 0, 0, true);
                    _ = tvg_shape_set_fill_color(s, bc[0], bc[1], bc[2], bc[3]);
                    _ = tvg_canvas_add(canvas, s);
                }
            }
        }
    }

    // Content origin: offset by the node's computed padding
    const pad_left = yoga.c.YGNodeLayoutGetPadding(yg, yoga.c.YGEdgeLeft);
    const pad_top = yoga.c.YGNodeLayoutGetPadding(yg, yoga.c.YGEdgeTop);
    const cx = x + pad_left;
    const cy = y + pad_top;

    // Paint <img> content using ThorVG picture
    if (info.img_data) |img_data| {
        if (tvg_picture_new()) |pic| {
            const mime: [*c]const u8 = if (info.img_is_svg) "svg" else null;
            const load_ok = tvg_picture_load_data(pic, img_data.ptr, @intCast(img_data.len), mime, null, true);
            if (load_ok == 0) { // 0 = TVG_RESULT_SUCCESS
                const pic_w = @max(1.0, node_w - pad_left - yoga.c.YGNodeLayoutGetPadding(yg, yoga.c.YGEdgeRight));
                const pic_h = @max(1.0, node_h - pad_top - yoga.c.YGNodeLayoutGetPadding(yg, yoga.c.YGEdgeBottom));
                _ = tvg_picture_set_size(pic, pic_w, pic_h);
                _ = tvg_paint_translate(pic, cx, cy);
                _ = tvg_canvas_add(canvas, pic);
            } else {
                // Unsupported format (webp, avif, etc.) or corrupt data — free and skip
                if (builtin.mode == .Debug) std.debug.print("[Compositor] ⚠️ tvg_picture_load_data failed (code={}, svg={}, len={})\n", .{ load_ok, info.img_is_svg, img_data.len });
                _ = tvg_paint_unref(pic, true);
            }
        }
    }

    // Paint text content — word-wrap to stay within the node's content width
    if (info.text_content.len > 0) {
        const pad_right = yoga.c.YGNodeLayoutGetPadding(yg, yoga.c.YGEdgeRight);
        const content_w = node_w - pad_left - pad_right;
        const max_w = if (content_w > 0) content_w else @as(f32, 800.0);

        const lines = wordWrapText(allocator, info.text_content, info.font_size, max_w);
        // Arena allocator owns all line strings — no manual free needed
        for (lines, 0..) |line_text, li| {
            const text_paint = tvg_text_new() orelse continue;
            const c_string = allocator.dupeZ(u8, line_text) catch continue;

            _ = tvg_text_set_font(text_paint, "Roboto");
            _ = tvg_text_set_size(text_paint, info.font_size);
            _ = tvg_text_set_text(text_paint, c_string.ptr);
            _ = tvg_text_set_color(text_paint, fg[0], fg[1], fg[2]);

            const line_measured = measureText(allocator, line_text, info.font_size);
            const line_y = cy + @as(f32, @floatFromInt(li)) * LINE_HEIGHT;
            const tx = switch (info.text_align) {
                .left => cx,
                .center => cx + @max(0.0, (content_w - line_measured.w) / 2.0),
                .right => cx + @max(0.0, content_w - line_measured.w),
            };
            _ = tvg_paint_translate(text_paint, tx, line_y);
            _ = tvg_canvas_add(canvas, text_paint);
        }
    }

    // Paint children
    const child_count = yoga.getChildCount(yg);
    for (0..child_count) |i| {
        const child_yg = yoga.getChild(yg, i);
        paintYogaTree(child_yg, canvas, x, y, fg, allocator);
    }
}

// =============================================================================
// Public JS API
// =============================================================================

pub fn js_paintDOM(ctx_ptr: ?*z.qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 1) return w.UNDEFINED;

    const rc = RuntimeContext.get(ctx);

    // 1. Extract the Lexbor DOM Node from the JS Argument (Arg 0)
    var ptr = ctx.getOpaque(argv[0], rc.classes.html_element);
    if (ptr == null) ptr = ctx.getOpaque(argv[0], rc.classes.dom_node);
    if (ptr == null) {
        std.debug.print("[Compositor] FATAL: Arg 0 is not a valid DOM Node!\n", .{});
        return w.UNDEFINED;
    }
    const root_node: *z.DomNode = @ptrCast(@alignCast(ptr));

    // 2. Width (Arg 1: number or undefined, default 800px)
    //    JS resolves {dpi} → number before calling __paintDOM.
    const page_width: u32 = blk: {
        if (argc >= 2 and !ctx.isUndefined(argv[1]) and !ctx.isNull(argv[1])) {
            var w_f64: f64 = 800;
            if (qjs.JS_ToFloat64(ctx.ptr, &w_f64, argv[1]) == 0 and w_f64 > 0)
                break :blk @as(u32, @intFromFloat(w_f64));
        }
        break :blk 800;
    };

    // 3. Initialize ThorVG early (needed for text measurement during tree build)
    _ = tvg_engine_init(0);
    defer _ = tvg_engine_term();
    thorvg.loadEmbeddedFonts() catch {};

    // 4. Build Yoga layout tree from DOM (arena-allocated)
    var arena = std.heap.ArenaAllocator.init(rc.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const yg_root = buildYogaTree(root_node, arena_alloc, rc.base_dir) orelse {
        std.debug.print("[Compositor] Failed to build Yoga tree\n", .{});
        return w.UNDEFINED;
    };
    defer yoga.nodeFreeRecursive(yg_root);

    // Set root width; height is determined by content
    yoga.setWidth(yg_root, @floatFromInt(page_width));

    // 5. Calculate layout — undefined height → Yoga computes natural content height
    yoga.calculateLayout(yg_root, @floatFromInt(page_width), yoga.Undefined, yoga.DIRECTION_LTR);

    // Read back computed height (always at least 1px)
    const page_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(yoga.getHeight(yg_root)))));

    // 6. Allocate pixel buffer
    const master_buffer = rc.allocator.alloc(u32, page_width * page_height) catch return w.UNDEFINED;
    defer rc.allocator.free(master_buffer);
    @memset(master_buffer, 0xFFFFFFFF); // white background

    const canvas = tvg_swcanvas_create(0) orelse return w.UNDEFINED;
    defer _ = tvg_canvas_destroy(canvas);

    _ = tvg_swcanvas_set_target(canvas, master_buffer.ptr, page_width, page_width, page_height, 2);

    // 7. Paint the Yoga tree
    std.debug.print("[Compositor] Painting with Yoga layout...\n", .{});
    paintYogaTree(yg_root, canvas, 0, 0, .{ 0, 0, 0 }, arena_alloc);

    // 8. Render and save
    _ = tvg_canvas_draw(canvas, false);
    _ = tvg_canvas_sync(canvas);

    // Return raw RGBA as { data: ArrayBuffer, width, height }
    const master_u8: [*]const u8 = @ptrCast(master_buffer.ptr);
    const pixel_bytes = master_u8[0 .. @as(usize, page_width) * page_height * 4];
    const result = ctx.newObject();
    ctx.setPropertyStr(result, "data", ctx.newArrayBufferCopy(pixel_bytes)) catch return w.UNDEFINED;
    ctx.setPropertyStr(result, "width", ctx.newFloat64(@floatFromInt(page_width))) catch return w.UNDEFINED;
    ctx.setPropertyStr(result, "height", ctx.newFloat64(@floatFromInt(page_height))) catch return w.UNDEFINED;
    return result;
}

/// Render a single DOM element by building the full layout tree from document body,
/// finding the element's absolute position after Yoga layout, then painting into a
/// canvas sized to that element and shifting the scene so the element is at the origin.
/// This ensures CSS inheritance from ancestor elements (body, parents) is respected.
///
/// JS signature: __native_paintElement(element, page_width) → { data, width, height }
pub fn js_paintElement(ctx_ptr: ?*z.qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    if (argc < 1) return w.UNDEFINED;

    const rc = RuntimeContext.get(ctx);

    // 1. Unwrap target DOM node from argv[0]
    var ptr = ctx.getOpaque(argv[0], rc.classes.html_element);
    if (ptr == null) ptr = ctx.getOpaque(argv[0], rc.classes.dom_node);
    if (ptr == null) return w.UNDEFINED;
    const target_node: *z.DomNode = @ptrCast(@alignCast(ptr));

    // 2. Page layout width (argv[1]: number, default 800)
    const page_width: u32 = blk: {
        if (argc >= 2 and !ctx.isUndefined(argv[1]) and !ctx.isNull(argv[1])) {
            var w_f64: f64 = 800;
            if (qjs.JS_ToFloat64(ctx.ptr, &w_f64, argv[1]) == 0 and w_f64 > 0)
                break :blk @as(u32, @intFromFloat(w_f64));
        }
        break :blk 800;
    };

    // 3. Find document body — the root for full CSS-aware layout
    const doc = z.ownerDocument(target_node);
    const body_el = z.bodyElement(doc) orelse return w.UNDEFINED;
    const root_node = z.elementToNode(@ptrCast(body_el));

    // 4. Initialize ThorVG (needed for text measurement during tree build)
    _ = tvg_engine_init(0);
    defer _ = tvg_engine_term();
    thorvg.loadEmbeddedFonts() catch {};

    // 5. Build Yoga tree from document body (arena-allocated)
    var arena = std.heap.ArenaAllocator.init(rc.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const yg_root = buildYogaTree(root_node, arena_alloc, rc.base_dir) orelse return w.UNDEFINED;
    defer yoga.nodeFreeRecursive(yg_root);

    yoga.setWidth(yg_root, @floatFromInt(page_width));
    yoga.calculateLayout(yg_root, @floatFromInt(page_width), yoga.Undefined, yoga.DIRECTION_LTR);

    // 6. Locate the target element in the post-layout Yoga tree
    const found = findYogaNode(yg_root, target_node, 0, 0) orelse {
        std.debug.print("[Compositor] paintElement: target element not found in Yoga tree\n", .{});
        return w.UNDEFINED;
    };

    const elem_w = @max(1, @as(u32, @intFromFloat(@ceil(found.width))));
    const elem_h = @max(1, @as(u32, @intFromFloat(@ceil(found.height))));

    // 7. Allocate pixel buffer sized to the element
    const buffer = rc.allocator.alloc(u32, elem_w * elem_h) catch return w.UNDEFINED;
    defer rc.allocator.free(buffer);
    @memset(buffer, 0xFFFFFFFF); // white background

    const canvas = tvg_swcanvas_create(0) orelse return w.UNDEFINED;
    defer _ = tvg_canvas_destroy(canvas);
    _ = tvg_swcanvas_set_target(canvas, buffer.ptr, elem_w, elem_w, elem_h, 2);

    // 8. Paint the full scene shifted so the target element appears at (0,0).
    //    ThorVG clips to the canvas bounds — only the element's region is rendered.
    paintYogaTree(yg_root, canvas, -found.abs_x, -found.abs_y, .{ 0, 0, 0 }, arena_alloc);

    _ = tvg_canvas_draw(canvas, false);
    _ = tvg_canvas_sync(canvas);

    // 9. Return { data: ArrayBuffer, width, height }
    const u8_buf: [*]const u8 = @ptrCast(buffer.ptr);
    const pixel_bytes = u8_buf[0 .. @as(usize, elem_w) * elem_h * 4];
    const result = ctx.newObject();
    ctx.setPropertyStr(result, "data", ctx.newArrayBufferCopy(pixel_bytes)) catch return w.UNDEFINED;
    ctx.setPropertyStr(result, "width", ctx.newFloat64(@floatFromInt(elem_w))) catch return w.UNDEFINED;
    ctx.setPropertyStr(result, "height", ctx.newFloat64(@floatFromInt(elem_h))) catch return w.UNDEFINED;
    return result;
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

    // Allocate the Master ARGB Buffer
    const buffer_size = page_width * page_height;
    const master_buffer = rc.allocator.alloc(u32, buffer_size) catch {
        std.debug.print("[Compositor] FATAL: Could not allocate Master Buffer!\n", .{});
        return w.UNDEFINED;
    };
    defer rc.allocator.free(master_buffer);
    @memset(master_buffer, 0xFFFFFFFF);

    // Draw the Map Tiles (via stb_image)
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

    // Overlay the GeoJSON SVG (via ThorVG)
    const svg_str = ctx.toZString(argv[1]) catch return w.UNDEFINED;
    defer ctx.freeZString(svg_str);

    const svg_pixels = thorvg.rasterizeSVG(rc.allocator, svg_str, page_width, page_height) catch return w.UNDEFINED;
    defer rc.allocator.free(svg_pixels);

    const svg_u32: [*]const u32 = @ptrCast(@alignCast(svg_pixels.ptr));
    alphaComposite(master_buffer, svg_u32, buffer_size);

    // Encode PNG
    var filename: ?[]const u8 = null;
    if (argc >= 3 and ctx.isString(argv[2])) {
        filename = ctx.toZString(argv[2]) catch null;
    }
    defer {
        if (filename) |f| ctx.freeZString(f);
    }

    const master_u8: [*]const u8 = @ptrCast(master_buffer.ptr);
    if (filename) |fname| {
        std.debug.print("[Compositor] Saving route PNG to {s}...\n", .{fname});
        const r = stbi_write.stbi_write_png(fname.ptr, @intCast(page_width), @intCast(page_height), 4, master_u8, @intCast(page_width * 4));
        if (r == 0) std.debug.print("[Compositor] ⚠️ Failed to write PNG\n", .{});
        return w.UNDEFINED;
    } else {
        var out_len: c_int = 0;
        const png_ptr = stbi_write_png_to_mem(master_u8, 0, @intCast(page_width), @intCast(page_height), 4, &out_len);
        if (png_ptr) |p| {
            defer stbiw_free(p);
            return ctx.newArrayBufferCopy(p[0..@intCast(out_len)]);
        }
        return w.UNDEFINED;
    }
}

// =============================================================================
// Pixel helpers

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

                master[dst_idx] = 0xFF000000 | (@as(u32, b) << 16) | (@as(u32, g) << 8) | @as(u32, r);
            }
        }
    }
}

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

// =============================================================================
// __native_save(dataAB, width, height, path) — encode RGBA + write to disk
// =============================================================================

pub fn js_native_save(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 4) return w.UNDEFINED;

    const rgba = ctx.getArrayBuffer(argv[0]) catch return w.UNDEFINED;
    var width: u32 = 0;
    var height: u32 = 0;
    _ = qjs.JS_ToUint32(ctx.ptr, &width, argv[1]);
    _ = qjs.JS_ToUint32(ctx.ptr, &height, argv[2]);
    if (width == 0 or height == 0) return w.UNDEFINED;

    const path = ctx.toZString(argv[3]) catch return w.UNDEFINED;
    defer ctx.freeZString(path);

    const lower = std.ascii.allocLowerString(std.heap.c_allocator, path) catch path;
    defer if (lower.ptr != path.ptr) std.heap.c_allocator.free(lower);

    std.debug.print("[Compositor] Saving to {s}...\n", .{path});

    const ok: bool = blk: {
        if (std.mem.endsWith(u8, lower, ".jpg") or std.mem.endsWith(u8, lower, ".jpeg")) {
            const r = stbi_write.stbi_write_jpg(path.ptr, @intCast(width), @intCast(height), 4, rgba.ptr, 90);
            break :blk r != 0;
        } else if (std.mem.endsWith(u8, lower, ".webp")) {
            var out_ptr: [*]u8 = undefined;
            const out_len = WebPEncodeRGBA(rgba.ptr, @intCast(width), @intCast(height), @intCast(width * 4), 90.0, &out_ptr);
            if (out_len == 0) break :blk false;
            defer WebPFree(out_ptr);
            std.fs.cwd().writeFile(.{ .sub_path = path, .data = out_ptr[0..out_len] }) catch break :blk false;
            break :blk true;
        } else if (std.mem.endsWith(u8, lower, ".pdf")) {
            saveRgbaAsPdf(rc.allocator, rgba, width, height, path) catch break :blk false;
            break :blk true;
        } else {
            // default: PNG
            const r = stbi_write.stbi_write_png(path.ptr, @intCast(width), @intCast(height), 4, rgba.ptr, @intCast(width * 4));
            break :blk r != 0;
        }
    };

    if (!ok) std.debug.print("[Compositor] ⚠️ Failed to save image\n", .{});
    return w.UNDEFINED;
}

// =============================================================================
// __native_encode(dataAB, width, height, format) → ArrayBuffer
// =============================================================================

pub fn js_native_encode(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    if (argc < 4) return w.UNDEFINED;

    const rgba = ctx.getArrayBuffer(argv[0]) catch return w.UNDEFINED;
    var width: u32 = 0;
    var height: u32 = 0;
    _ = qjs.JS_ToUint32(ctx.ptr, &width, argv[1]);
    _ = qjs.JS_ToUint32(ctx.ptr, &height, argv[2]);
    if (width == 0 or height == 0) return w.UNDEFINED;

    const fmt = ctx.toZString(argv[3]) catch return w.UNDEFINED;
    defer ctx.freeZString(fmt);

    const lower = std.ascii.allocLowerString(std.heap.c_allocator, fmt) catch fmt;
    defer if (lower.ptr != fmt.ptr) std.heap.c_allocator.free(lower);

    if (std.mem.eql(u8, lower, "jpg") or std.mem.eql(u8, lower, "jpeg")) {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(rc.allocator);
        var jctx = JpegWriteContext{ .data = &list, .allocator = rc.allocator };
        _ = stbi_write_jpg_to_func(stbiJpegWriteCallback, &jctx, @intCast(width), @intCast(height), 4, rgba.ptr, 90);
        return ctx.newArrayBufferCopy(list.items);
    } else if (std.mem.eql(u8, lower, "webp")) {
        var out_ptr: [*]u8 = undefined;
        const out_len = WebPEncodeRGBA(rgba.ptr, @intCast(width), @intCast(height), @intCast(width * 4), 90.0, &out_ptr);
        if (out_len == 0) return w.UNDEFINED;
        defer WebPFree(out_ptr);
        return ctx.newArrayBufferCopy(out_ptr[0..out_len]);
    } else if (std.mem.eql(u8, lower, "pdf")) {
        const pdf_bytes = encodeRgbaAsPdf(rc.allocator, rgba, width, height) catch return w.UNDEFINED;
        defer rc.allocator.free(pdf_bytes);
        return ctx.newArrayBufferCopy(pdf_bytes);
    } else {
        // default: PNG
        var out_len: c_int = 0;
        const png_ptr = stbi_write_png_to_mem(rgba.ptr, 0, @intCast(width), @intCast(height), 4, &out_len);
        if (png_ptr) |p| {
            defer stbiw_free(p);
            return ctx.newArrayBufferCopy(p[0..@intCast(out_len)]);
        }
        return w.UNDEFINED;
    }
}

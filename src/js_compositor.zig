//! Layout flow with `Yoga` & `Thorvg`
//! - It traverses the Lexbor DOM , parses the inline CSS styles (like display: flex, padding, background)
//! - maps them to `YGNode` properties
//! - Uses custom measurement function `textMeasure()` using `ThorVG` to calculate the intrinsic size of text blocks
//!
//! Pass 2 (paintYogaTree): After calling `yoga.calculateLayout`, it
//! - walks the calculated tree,
//! - extracts the absolute X and Y coordinates (yoga.getLeft, yoga.getTop),
//! - tells ThorVG to draw the rectangles and text exactly where Yoga positioned them

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

const yoga = z.yoga;
const thorvg = z.thorvg;
const Tvg_Canvas = thorvg.Tvg_Canvas;
const Tvg_Paint = thorvg.Tvg_Paint;

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
    text_align: enum { left, center, right } = .left,
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
fn hasBlockChildren(node: *z.DomNode) bool {
    var child = z.firstChild(node);
    while (child) |c_node| : (child = z.nextSibling(c_node)) {
        if (z.nodeType(c_node) == .element) {
            if (z.nodeToElement(c_node)) |el| {
                if (!isInlineElement(z.tagName_zc(el))) return true;
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

fn isRemoteUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "//");
}

/// Synchronous HTTP GET; bytes are allocated from `allocator`. Returns null on error.
fn fetchImageBytes(allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    var buf = std.Io.Writer.Allocating.init(allocator);
    const resp = client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .response_writer = &buf.writer,
    }) catch |err| {
        buf.deinit();
        std.debug.print("[Compositor] Failed to fetch image {s}: {}\n", .{ url, err });
        return null;
    };
    if (resp.status != .ok) {
        buf.deinit();
        std.debug.print("[Compositor] HTTP {} for image: {s}\n", .{ @intFromEnum(resp.status), url });
        return null;
    }
    return buf.toOwnedSlice() catch null;
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
    if (z.nodeToElement(dom_node)) |el| {
        const tag = z.tagName_zc(el);

        // Use serializeElementStyles to get the full CSS cascade (not just inline style="")
        const style_str = z.serializeElementStyles(allocator, el) catch null;
        defer if (style_str) |s| allocator.free(s);
        if (style_str) |s| {
            if (s.len > 0) {
                applyInlineStyle(yg, info, s);
            }
        }

        // Table row defaults: flex-direction row
        if (std.mem.eql(u8, tag, "TR")) {
            yoga.setFlexDirection(yg, yoga.FLEX_DIRECTION_ROW);
        }

        // <img> support: load file bytes and set Yoga dimensions
        if (std.mem.eql(u8, tag, "IMG")) {
            var img_loaded = false;
            if (z.getAttribute_zc(el, "src")) |src| {
                if (src.len > 0) {
                    // Load image: remote URLs are fetched; relative paths resolved to base_dir
                    z.print("{s}\n", .{src});
                    const maybe_data: ?[]const u8 = if (isRemoteUrl(src)) blk: {
                        const url = if (std.mem.startsWith(u8, src, "//"))
                            std.fmt.allocPrint(allocator, "https:{s}", .{src}) catch src
                        else
                            src;
                        break :blk fetchImageBytes(allocator, url);
                    } else blk: {
                        const path = std.fs.path.join(allocator, &.{ base_dir, src }) catch src;
                        break :blk std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024) catch {
                            std.debug.print("[Compositor] Failed to load image: {s}\n", .{path});
                            break :blk null;
                        };
                    };

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

/// Parse a CSS inline style string and apply properties to a Yoga node
fn applyInlineStyle(yg: yoga.Node, info: *NodeInfo, style: []const u8) void {
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
            } else if (std.mem.eql(u8, val, "none")) {
                yoga.setDisplay(yg, yoga.DISPLAY_NONE);
            }
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
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_ALL, v);
        } else if (std.mem.eql(u8, prop, "padding-left")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_LEFT, v);
        } else if (std.mem.eql(u8, prop, "padding-right")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_RIGHT, v);
        } else if (std.mem.eql(u8, prop, "padding-top")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_TOP, v);
        } else if (std.mem.eql(u8, prop, "padding-bottom")) {
            if (parsePixelValue(val)) |v| yoga.setPadding(yg, yoga.EDGE_BOTTOM, v);
        } else if (std.mem.eql(u8, prop, "margin")) {
            if (parsePixelValue(val)) |v| yoga.setMargin(yg, yoga.EDGE_ALL, v);
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
        } else if (std.mem.eql(u8, prop, "background") or std.mem.eql(u8, prop, "background-color")) {
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
        } else if (std.mem.eql(u8, prop, "border-top") or
            std.mem.eql(u8, prop, "border-right") or
            std.mem.eql(u8, prop, "border-bottom") or
            std.mem.eql(u8, prop, "border-left"))
        {
            parseBorderShorthand(val, info);
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

/// Parse simple CSS color values (named colors, #hex)
fn parseCSSColor(val: []const u8) ?[4]u8 {
    // Named colors
    if (std.mem.eql(u8, val, "black")) return .{ 0, 0, 0, 255 };
    if (std.mem.eql(u8, val, "white")) return .{ 255, 255, 255, 255 };
    if (std.mem.eql(u8, val, "red")) return .{ 255, 0, 0, 255 };
    if (std.mem.eql(u8, val, "green")) return .{ 0, 128, 0, 255 };
    if (std.mem.eql(u8, val, "blue")) return .{ 0, 0, 255, 255 };
    if (std.mem.eql(u8, val, "transparent")) return .{ 0, 0, 0, 0 };

    // #RGB or #RRGGBB
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
        }
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

    // Paint background rect and/or border on a single shape
    if (info.bg_color[3] > 0 or info.border_width > 0) {
        const shape = tvg_shape_new() orelse return;
        const r = info.border_radius;
        _ = tvg_shape_append_rect(shape, x, y, node_w, node_h, r, r, true);
        if (info.bg_color[3] > 0) {
            _ = tvg_shape_set_fill_color(shape, info.bg_color[0], info.bg_color[1], info.bg_color[2], info.bg_color[3]);
        }
        if (info.border_width > 0 and info.border_color[3] > 0) {
            _ = tvg_shape_set_stroke_width(shape, info.border_width);
            _ = tvg_shape_set_stroke_color(shape, info.border_color[0], info.border_color[1], info.border_color[2], info.border_color[3]);
        }
        _ = tvg_canvas_add(canvas, shape);
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

    // 2. Optional width (Arg 1: number, default 800px)
    //    Examples: zxp.paintDOM(el, 595)   // A4 at 72 DPI
    //              zxp.paintDOM(el, 2480)  // A4 at 300 DPI (print)
    const page_width: u32 = blk: {
        if (argc >= 2 and !ctx.isString(argv[1])) {
            var w_f64: f64 = 800;
            if (qjs.JS_ToFloat64(ctx.ptr, &w_f64, argv[1]) == 0 and w_f64 > 0)
                break :blk @as(u32, @intFromFloat(w_f64));
        }
        break :blk 800;
    };

    // Optional filename (Arg 1: string legacy, or Arg 2: string)
    var filename: ?[]const u8 = null;
    if (argc >= 2 and ctx.isString(argv[1])) {
        filename = ctx.toZString(argv[1]) catch null;
    } else if (argc >= 3 and ctx.isString(argv[2])) {
        filename = ctx.toZString(argv[2]) catch null;
    }

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

    const master_u8: [*]const u8 = @ptrCast(master_buffer.ptr);
    if (filename) |fname| {
        defer ctx.freeZString(fname);
        return saveToDisk(fname, master_u8, page_width, page_height);
    } else {
        return encodeToArrayBuffer(ctx, master_u8, page_width, page_height);
    }
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
    const buffer_size = page_width * page_height;
    const master_buffer = rc.allocator.alloc(u32, buffer_size) catch {
        std.debug.print("[Compositor] FATAL: Could not allocate Master Buffer!\n", .{});
        return w.UNDEFINED;
    };
    defer rc.allocator.free(master_buffer);
    @memset(master_buffer, 0xFFFFFFFF);

    // PHASE 1: Draw the Map Tiles (via stb_image)
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

    // PHASE 2: Overlay the GeoJSON SVG (via ThorVG)
    const svg_str = ctx.toZString(argv[1]) catch return w.UNDEFINED;
    defer ctx.freeZString(svg_str);

    const svg_pixels = thorvg.rasterizeSVG(rc.allocator, svg_str, page_width, page_height) catch return w.UNDEFINED;
    defer rc.allocator.free(svg_pixels);

    const svg_u32: [*]const u32 = @ptrCast(@alignCast(svg_pixels.ptr));
    alphaComposite(master_buffer, svg_u32, buffer_size);

    // PHASE 3: Encode PNG
    var filename: ?[]const u8 = null;
    if (argc >= 3 and ctx.isString(argv[2])) {
        filename = ctx.toZString(argv[2]) catch null;
    }
    defer {
        if (filename) |f| ctx.freeZString(f);
    }

    const master_u8: [*]const u8 = @ptrCast(master_buffer.ptr);
    if (filename) |fname| {
        std.debug.print("[Compositor] Saving final image to {s}...\n", .{fname});
        return saveToDisk(fname, master_u8, page_width, page_height);
    } else {
        return encodeToArrayBuffer(ctx, master_u8, page_width, page_height);
    }
}

// =============================================================================
// Pixel helpers (unchanged)
// =============================================================================

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

fn encodeToArrayBuffer(ctx: w.Context, master_u8: [*]const u8, width: u32, height: u32) w.Value {
    var out_len: c_int = 0;

    const png_c_ptr = stbi_write_png_to_mem(
        master_u8,
        0,
        @intCast(width),
        @intCast(height),
        4,
        &out_len,
    );

    if (png_c_ptr) |png_ptr| {
        defer stbiw_free(png_ptr);
        return ctx.newArrayBufferCopy(png_ptr[0..@intCast(out_len)]);
    } else {
        std.debug.print("[Compositor] Failed to encode PNG to memory!\n", .{});
        return w.UNDEFINED;
    }
}

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

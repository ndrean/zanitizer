const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const DOMBridge = @import("dom_bridge.zig").DOMBridge;
const BlobObject = @import("js_blob.zig").BlobObject;
const css_color = @import("css_color.zig");
const js_utils = @import("js_utils.zig");
const js_image = @import("js_image.zig");
const Font = @import("font.zig").Font;

// stb_image_write C bindings - manual declaration since stbi_write_png_to_mem
// is only defined in the implementation section, not declared in the header
extern fn stbi_write_png_to_mem(
    pixels: [*]const u8,
    stride_in_bytes: c_int,
    x: c_int,
    y: c_int,
    n: c_int,
    out_len: *c_int,
) ?[*]u8;

// needed for the Jpeg Callback
const JpegWriteContext = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
};

// no jpeg_to_mem but use a version with callback
extern fn stbi_write_jpg_to_func(
    func: *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) void,
    context: ?*anyopaque,
    x: c_int,
    y: c_int,
    comp: c_int,
    data: ?*const anyopaque,
    quality: c_int,
) c_int;

// Callback for STB to write data into our Zig ArrayList
fn stbiWriteCallback(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const ctx: *JpegWriteContext = @ptrCast(@alignCast(context));
    if (data) |d| {
        const ptr: [*]const u8 = @ptrCast(d);
        const len: usize = @intCast(size);

        // 2. Use the allocator stored in the context
        ctx.list.appendSlice(ctx.allocator, ptr[0..len]) catch {};
    }
}

// STBIW_FREE is a C macro (defaults to free), so we use libc free directly
fn stbiw_free(ptr: ?*anyopaque) void {
    if (ptr) |p| std.c.free(p);
}

/// 2. Helper to unwrap using RuntimeContext
pub fn unwrapCanvas(ctx: zqjs.Context, val: zqjs.Value) ?*Canvas {
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(val, rc.classes.canvas);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

pub const CanvasState = struct {
    fill_color: css_color.Color,
    stroke_color: css_color.Color,
    font: ?*Font,
    font_size: f32,
    tx: f32,
    ty: f32,
    sx: f32,
    sy: f32,
};

const Point = struct { x: f32, y: f32 };

pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA buffer
    fill_color: css_color.Color,
    stroke_color: css_color.Color,
    font: ?*Font, // Reference to current font (nullable)
    font_size: f32, // e.g. 24.0
    line_width: f32, // e.g. 1.0
    // Transform State
    tx: f32, // Translate X
    ty: f32, // Translate Y
    sx: f32, // Scale X
    sy: f32, // Scale Y
    state_stack: std.ArrayList(CanvasState),
    path: std.ArrayList(Point),
    has_start_point: bool,
    subpath_start: Point,
    allocator: std.mem.Allocator,
    element: ?*z.HTMLElement = null, // Backing DOM <canvas> element for DOM tree participation

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !*Canvas {
        const self = try allocator.create(Canvas);
        self.width = w;
        self.height = h;
        self.allocator = allocator;
        self.font = null;
        self.font_size = 10.0;
        self.path = .empty;
        self.has_start_point = false;
        self.line_width = 1.0;
        self.subpath_start = .{ .x = 0, .y = 0 };

        const size = @as(usize, @intCast(w * h * 4)); // RGBA
        self.pixels = try allocator.alloc(u8, size);
        // zeroed allocatoed to default transparent black
        @memset(self.pixels, 0);

        self.fill_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        self.stroke_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

        // identity transform
        self.tx = 0;
        self.ty = 0;
        self.sx = 1;
        self.sy = 1;

        self.state_stack = .empty;
        return self;
    }

    pub fn deinit(self: *Canvas) void {
        self.state_stack.deinit(self.allocator);
        self.path.deinit(self.allocator);
        self.allocator.free(self.pixels);
        self.allocator.destroy(self);
    }

    pub fn save(self: *Canvas) !void {
        // Create a copy of the current state
        const state = CanvasState{
            .fill_color = self.fill_color,
            .font = self.font,
            .font_size = self.font_size,
            .stroke_color = self.stroke_color,
            .tx = self.tx,
            .ty = self.ty,
            .sx = self.sx,
            .sy = self.sy,
        };
        try self.state_stack.append(self.allocator, state);
    }

    pub fn restore(self: *Canvas) void {
        // Pop the last state and overwrite current settings
        if (self.state_stack.pop()) |state| {
            self.fill_color = state.fill_color;
            self.stroke_color = state.stroke_color;
            self.font = state.font;
            self.font_size = state.font_size;
            self.tx = state.tx;
            self.ty = state.ty;
            self.sx = state.sx;
            self.sy = state.sy;
        }
    }

    // Set the global font object, not owned, managed JS side
    pub fn setFont(self: *Canvas, font: *Font, size: f32) void {
        self.font = font;
        self.font_size = size;
    }

    pub fn fillText(self: *Canvas, text: []const u8, x: f32, y: f32) void {
        const font = self.font orelse return; // No font? Do nothing
        const scale_factor = font.getFontScale(self.font_size);
        const final_sx = scale_factor * self.sx;
        const final_sy = scale_factor * self.sy;

        // Transform the starting position
        const origin = self.applyTransform(@as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)));

        var cursor_x = @as(f32, @floatFromInt(origin.x));
        const baseline = @as(f32, @floatFromInt(origin.y));

        for (text) |char| {
            // Ask STB for a bitmap scaled by OUR transform
            if (font.getGlyphBitmap(char, final_sx, final_sy)) |glyph| {
                defer std.c.free(glyph.pixels);

                const draw_x = @as(i32, @intFromFloat(cursor_x)) + glyph.xoff;
                const draw_y = @as(i32, @intFromFloat(baseline)) + glyph.yoff;

                self.blendAlphaMap(glyph.pixels, glyph.w, glyph.h, draw_x, draw_y);
            }

            // Advance cursor (scaled)
            const advance = font.getGlyphAdvance(char);
            cursor_x += @as(f32, @floatFromInt(advance)) * final_sx;
        }
    }

    // Helper: Blends a generic 1-channel alpha map onto the canvas
    fn blendAlphaMap(self: *Canvas, mask: [*]u8, w: i32, h: i32, dx: i32, dy: i32) void {
        const color = self.fill_color;

        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const dest_y = dy + row;
            if (dest_y < 0 or dest_y >= self.height) continue;

            var col: i32 = 0;
            while (col < w) : (col += 1) {
                const dest_x = dx + col;
                if (dest_x < 0 or dest_x >= self.width) continue;

                // Indexing
                const mask_idx = @as(usize, @intCast(row * w + col));
                const dest_idx = @as(usize, @intCast((dest_y * @as(i32, @intCast(self.width)) + dest_x) * 4));

                // Alpha Composition
                // Source Alpha = (Mask Value / 255) * (Color Alpha / 255)
                const mask_val = mask[mask_idx];
                if (mask_val == 0) continue; // Optimization

                // Simple implementation: Overwrite (assuming color.a=255)
                // Real implementation: Alpha blend

                // Let's just do a "Tinted Add" or simple overwrite for MVP
                // If the font pixel is 255 (solid), we paint our fill color.
                // If 128 (50%), we should blend.

                // MVP: Treat > 0 as filled
                self.pixels[dest_idx + 0] = color.r;
                self.pixels[dest_idx + 1] = color.g;
                self.pixels[dest_idx + 2] = color.b;
                self.pixels[dest_idx + 3] = mask_val; // Use the mask as the alpha!
            }
        }
    }

    pub fn fillRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32) void {
        const p1 = self.applyTransform(x, y);
        const p2 = self.applyTransform(x + w, y + h);
        // shrink, negative scale
        const fx = @min(p1.x, p2.x);
        const fy = @min(p1.y, p2.y);
        const fw = @abs(p2.x - p1.x);
        const fh = @abs(p2.y - p1.y);

        const rect_w = @as(i32, @intCast(fw));
        const rect_h = @as(i32, @intCast(fh));
        // clip
        const cv_w = @as(i32, @intCast(self.width));
        const cv_h = @as(i32, @intCast(self.height));

        const x_start = @max(0, fx);
        const y_start = @max(0, fy);
        const x_end = @min(cv_w, fx + rect_w);
        const y_end = @min(cv_h, fy + rect_h);

        if (x_start >= x_end or y_start >= y_end) return;

        const color = self.fill_color;
        const stride = self.width;

        var row = y_start;
        while (row < y_end) : (row += 1) {
            const row_idx = @as(usize, @intCast(row)) * stride;
            var col = x_start;
            while (col < x_end) : (col += 1) {
                const idx = (row_idx + @as(usize, @intCast(col))) * 4;
                self.pixels[idx + 0] = color.r;
                self.pixels[idx + 1] = color.g;
                self.pixels[idx + 2] = color.b;
                self.pixels[idx + 3] = color.a;
            }
        }
    }

    pub fn setFillStyle(self: *Canvas, style: []const u8) void {
        self.fill_color = css_color.parse(style);
    }

    pub fn resize(self: *Canvas, new_w: u32, new_h: u32) !void {
        self.allocator.free(self.pixels);
        self.width = new_w;
        self.height = new_h;

        const size = @as(usize, new_w) * @as(usize, new_h) * 4;
        self.pixels = try self.allocator.alloc(u8, size);
        @memset(self.pixels, 0);
    }

    pub fn beginPath(self: *Canvas) void {
        self.path.clearRetainingCapacity();
        self.has_start_point = false;
    }

    pub fn moveTo(self: *Canvas, x: f32, y: f32) void {
        // Start a new sub-path (for MVP, we just add the point)
        // In a full engine, moveTo breaks the line continuity.
        // For simple charts, we just clear and add.
        if (self.path.items.len > 0) {
            // If we already have points, moveTo usually starts a new disconnected line.
            // For MVP: We will treat 'path' as a single continuous line strip.
            // To support multiple disconnected lines, we'd need a list of lists.
            // Let's keep it simple: moveTo clears if called mid-stream?
            // No, standard canvas allows multiple subpaths.
            // Let's just add it for now, but mark it as a "jump"?
            // EASIEST MVP: Just add it.
        }
        self.path.append(self.allocator, .{ .x = x, .y = y }) catch return;
        self.has_start_point = true;
        self.subpath_start = .{ .x = x, .y = y };
    }

    pub fn closePath(self: *Canvas) void {
        if (self.has_start_point) {
            self.lineTo(self.subpath_start.x, self.subpath_start.y);
        }
    }

    pub fn lineTo(self: *Canvas, x: f32, y: f32) void {
        if (!self.has_start_point) {
            self.moveTo(x, y);
            return;
        }
        self.path.append(self.allocator, .{ .x = x, .y = y }) catch return;
    }

    pub fn stroke(self: *Canvas) void {
        if (self.path.items.len < 2) return;

        // Iterate through points and draw lines
        var i: usize = 0;
        while (i < self.path.items.len - 1) : (i += 1) {
            const p1 = self.path.items[i];
            const p2 = self.path.items[i + 1];

            // Apply Transform to endpoints
            const t1 = self.applyTransform(@intFromFloat(p1.x), @intFromFloat(p1.y));
            const t2 = self.applyTransform(@intFromFloat(p2.x), @intFromFloat(p2.y));

            self.bresenhamLine(t1.x, t1.y, t2.x, t2.y);
        }
    }
    // --- Bresenham's Line Algorithm ---
    // Draws a 1px line between (x0, y0) and (x1, y1)
    fn bresenhamLine(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32) void {
        const dx = @abs(x1 - x0);
        const dy = -@as(i32, @intCast(@abs(y1 - y0))); // dy is negative for the algorithm

        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;

        var err: i32 = @intCast(@as(i32, @intCast(dx)) + @as(i32, @intCast(dy)));

        var curr_x = x0;
        var curr_y = y0;

        // If width is 4.0, radius is 2. We draw from -2 to +2
        const radius = @as(i32, @intFromFloat(self.line_width / 2.0));
        const color = self.stroke_color;
        const cv_w = @as(i32, @intCast(self.width));
        const cv_h = @as(i32, @intCast(self.height));

        while (true) {

            // "The Marker Pen": Draw a block of pixels around the center
            if (radius == 0) {
                // Fast path for 1px lines
                if (curr_x >= 0 and curr_x < cv_w and curr_y >= 0 and curr_y < cv_h) {
                    const idx = @as(usize, @intCast((curr_y * cv_w + curr_x) * 4));
                    self.pixels[idx + 0] = color.r;
                    self.pixels[idx + 1] = color.g;
                    self.pixels[idx + 2] = color.b;
                    self.pixels[idx + 3] = 255;
                }
            } else {
                // Thick Line Loop
                var r: i32 = -radius;
                while (r <= radius) : (r += 1) {
                    var c: i32 = -radius;
                    while (c <= radius) : (c += 1) {
                        const draw_x = curr_x + c;
                        const draw_y = curr_y + r;

                        if (draw_x >= 0 and draw_x < cv_w and draw_y >= 0 and draw_y < cv_h) {
                            const idx = @as(usize, @intCast((draw_y * cv_w + draw_x) * 4));
                            self.pixels[idx + 0] = color.r;
                            self.pixels[idx + 1] = color.g;
                            self.pixels[idx + 2] = color.b;
                            self.pixels[idx + 3] = 255;
                        }
                    }
                }
            }

            if (curr_x == x1 and curr_y == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                curr_x += sx;
            }
            if (e2 <= dx) {
                err += @as(i32, @intCast(dx));
                curr_y += sy;
            }
        }
    }

    pub fn setStrokeStyle(self: *Canvas, style: []const u8) void {
        self.stroke_color = css_color.parse(style);
    }

    // ctx.arc(x, y, radius, start_angle, end_angle)
    pub fn arc(self: *Canvas, x: f32, y: f32, r: f32, start_angle: f32, end_angle: f32) void {
        // Resolution: The larger the radius, the more steps we need for it to look round.
        // A step of ~0.1 radians (6 degrees) is usually fine for small circles.
        const step = 0.1;

        var angle = start_angle;
        while (angle < end_angle) : (angle += step) {
            const px = x + std.math.cos(angle) * r;
            const py = y + std.math.sin(angle) * r;
            self.lineTo(px, py);
        }

        // Connect to the final point to close the gap accurately
        const end_x = x + std.math.cos(end_angle) * r;
        const end_y = y + std.math.sin(end_angle) * r;
        self.lineTo(end_x, end_y);
    }

    /// Encodes the pixel buffer to PNG format (Raw Bytes)
    ///
    /// Caller owns the returned slice!
    pub fn getPngData(self: *Canvas) ![]u8 {
        var png_len: c_int = 0;

        // stbi_write_png_to_mem(pixels, stride_bytes, x, y, n, out_len)
        // stride = 0 means auto (width * components)
        const png_c_ptr = stbi_write_png_to_mem(
            self.pixels.ptr,
            0, // stride (0 = auto)
            @intCast(self.width),
            @intCast(self.height),
            4, // components (RGBA)
            &png_len,
        );

        const png_ptr = png_c_ptr orelse return error.EncodingFailed;
        defer stbiw_free(png_ptr);

        // ! Copy to Zig memory so we manage lifecycle properly
        const png_slice = png_ptr[0..@intCast(png_len)];
        return self.allocator.dupe(u8, png_slice);
    }

    /// Encodes pixel buffer to JPEG.
    ///
    /// Returns owned slice.
    pub fn getJpegData(self: *Canvas, quality: f32) ![]u8 {
        // 1. Init Unmanaged List (No allocator passed here)
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(self.allocator);

        // 2. Prepare Context (Bundle list ptr + allocator)
        var ctx = JpegWriteContext{
            .list = &list,
            .allocator = self.allocator,
        };

        const q_val = std.math.clamp(quality, 0.0, 1.0) * 100.0;
        const q_int = @as(c_int, @intFromFloat(q_val));

        // 3. Pass pointer to 'ctx', NOT 'list'
        const res = stbi_write_jpg_to_func(
            stbiWriteCallback,
            &ctx,
            @intCast(self.width),
            @intCast(self.height),
            4,
            self.pixels.ptr,
            q_int,
        );

        if (res == 0) return error.EncodingFailed;
        return list.toOwnedSlice(self.allocator);
    }

    // /// Returns a Base64 Data URL string: "data:image/png;base64,..."
    // pub fn toDataURL(self: *Canvas) ![]u8 {
    //     var png_len: c_int = 0;

    //     // Compress to PNG (Heap allocated by STB)
    //     // stride_in_bytes = width * 4 (RGBA)
    //     const png_data_c = stbi_write_png_to_mem(
    //         self.pixels.ptr,
    //         0, // stride_in_bytes (0 = auto)
    //         @intCast(self.width),
    //         @intCast(self.height),
    //         4, // components (RGBA)
    //         &png_len,
    //     );

    //     const png_data = png_data_c orelse return error.ImageEncodingFailed;

    //     // Wrap the C pointer in a Zig slice
    //     const png_bytes = png_data[0..@intCast(png_len)];
    //     defer stbiw_free(png_data);

    //     // 2. Base64 Encode
    //     const encoder = std.base64.standard.Encoder;
    //     const b64_len = encoder.calcSize(png_bytes.len);
    //     const prefix = "data:image/png;base64,";

    //     // Allocate final string (Prefix + B64)
    //     const result = try self.allocator.alloc(u8, prefix.len + b64_len);

    //     // Copy prefix
    //     @memcpy(result[0..prefix.len], prefix);

    //     // Encode content
    //     _ = encoder.encode(result[prefix.len..], png_bytes);

    //     return result;
    // }

    pub fn drawImage(self: *Canvas, img: *js_image.Image, dx: i32, dy: i32, dw: i32, dh: i32) void {
        // 1. Transform Coords
        const p1 = self.applyTransform(dx, dy);
        const p2 = self.applyTransform(dx + dw, dy + dh);

        const final_x = @min(p1.x, p2.x);
        const final_y = @min(p1.y, p2.y);
        const final_w = @as(i32, @intCast(@abs(p2.x - p1.x)));
        const final_h = @as(i32, @intCast(@abs(p2.y - p1.y)));

        if (final_w == 0 or final_h == 0) return;

        // 2. Clipping
        const cv_w = @as(i32, @intCast(self.width));
        const cv_h = @as(i32, @intCast(self.height));

        const x_start = @max(0, final_x);
        const y_start = @max(0, final_y);
        const x_end = @min(cv_w, final_x + final_w);
        const y_end = @min(cv_h, final_y + final_h);

        if (x_start >= x_end or y_start >= y_end) return;

        const dest_stride = @as(usize, @intCast(self.width));
        const src_stride = @as(usize, @intCast(img.width));

        // 3. Render Loop (Nearest Neighbor with Transforms)
        var dest_y = y_start;
        while (dest_y < y_end) : (dest_y += 1) {

            // Map Screen Pixel -> Source Pixel
            const row_progress = dest_y - final_y;
            // (progress / total_height) * src_height
            const s_y = @as(usize, @intCast(@divFloor(row_progress * img.height, final_h)));
            const d_y = @as(usize, @intCast(dest_y));

            var dest_x = x_start;
            while (dest_x < x_end) : (dest_x += 1) {
                const col_progress = dest_x - final_x;
                const s_x = @as(usize, @intCast(@divFloor(col_progress * img.width, final_w)));
                const d_x = @as(usize, @intCast(dest_x));

                const dest_idx = (d_y * dest_stride + d_x) * 4;
                const src_idx = (s_y * src_stride + s_x) * 4;

                // Simple Copy (Add Alpha Blending logic here later!)
                self.pixels[dest_idx + 0] = img.pixels[src_idx + 0];
                self.pixels[dest_idx + 1] = img.pixels[src_idx + 1];
                self.pixels[dest_idx + 2] = img.pixels[src_idx + 2];
                self.pixels[dest_idx + 3] = img.pixels[src_idx + 3];
            }
        }
    }

    pub fn translate(self: *Canvas, x: f32, y: f32) void {
        self.tx += x;
        self.ty += y;
    }

    pub fn scale(self: *Canvas, x: f32, y: f32) void {
        self.sx *= x;
        self.sy *= y;
    }

    // Reset to identity (useful for setTransform)
    pub fn resetTransform(self: *Canvas) void {
        self.tx = 0;
        self.ty = 0;
        self.sx = 1;
        self.sy = 1;
    }

    // Helper
    fn applyTransform(self: *Canvas, x: i32, y: i32) struct { x: i32, y: i32 } {
        const fx = @as(f32, @floatFromInt(x));
        const fy = @as(f32, @floatFromInt(y));

        return .{
            .x = @as(i32, @intFromFloat(fx * self.sx + self.tx)),
            .y = @as(i32, @intFromFloat(fy * self.sy + self.ty)),
        };
    }

    pub fn measureText(self: *Canvas, text: []const u8) f32 {
        const font = self.font orelse return 0.0;

        // We only care about the Font Size, NOT the Canvas Scale (sx/sy)
        // measureText tells us how much "cursor space" the text takes.
        const font_scale = font.getFontScale(self.font_size);

        var width: f32 = 0;
        for (text) |char| {
            const advance = font.getGlyphAdvance(char);
            width += @as(f32, @floatFromInt(advance)) * font_scale;
        }
        return width;
    }

    /// [math] Cubic Bezier: B(t) = (1-t)^3 P0 + 3(1-t)^2 t P1 + 3(1-t) t^2 P2 + t^3 P3
    pub fn bezierCurveTo(self: *Canvas, cp1x: f32, cp1y: f32, cp2x: f32, cp2y: f32, x: f32, y: f32) void {
        // P0 is the current pen position (end of last line/move)
        const p0 = if (self.path.items.len > 0)
            self.path.items[self.path.items.len - 1]
        else
            Point{ .x = 0, .y = 0 };

        const segments: usize = 20; // Smoothness resolution
        var i: usize = 1;
        while (i <= segments) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const u = 1.0 - t;

            // Cubic Bezier Coefficients
            const c0 = u * u * u; // (1-t)^3
            const c1 = 3.0 * u * u * t; // 3(1-t)^2 t
            const c2 = 3.0 * u * t * t; // 3(1-t) t^2
            const c3 = t * t * t; // t^3

            const px = c0 * p0.x + c1 * cp1x + c2 * cp2x + c3 * x;
            const py = c0 * p0.y + c1 * cp1y + c2 * cp2y + c3 * y;

            self.lineTo(px, py);
        }
    }

    /// [math] Quadratic Bezier: B(t) = (1-t)^2 P0 + 2(1-t) t P1 + t^2 P2
    pub fn quadraticCurveTo(self: *Canvas, cpx: f32, cpy: f32, x: f32, y: f32) void {
        const p0 = if (self.path.items.len > 0)
            self.path.items[self.path.items.len - 1]
        else
            Point{ .x = 0, .y = 0 };

        const segments: usize = 20;
        var i: usize = 1;
        while (i <= segments) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const u = 1.0 - t;

            // Quadratic Bezier Coefficients
            const px = (u * u * p0.x) + (2.0 * u * t * cpx) + (t * t * x);
            const py = (u * u * p0.y) + (2.0 * u * t * cpy) + (t * t * y);

            self.lineTo(px, py);
        }
    }
};

// === Properties

/// Getter canvas.canvas - self-reference (required by Chart.js: context.canvas === canvas)
fn js_canvas_get_canvas(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return qjs.JS_DupValue(ctx_ptr, this_val);
}

// === DOM compatibility methods (needed by Chart.js DOM platform) ===

/// Canvas.getAttribute(name) - returns attribute as string or null
fn js_canvas_getAttribute(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.NULL;

    if (argc < 1) return zqjs.NULL;

    const name = ctx.toZString(argv[0]) catch return zqjs.NULL;
    defer ctx.freeZString(name);

    // Return canvas dimensions as attribute strings
    if (std.mem.eql(u8, name, "width")) {
        var buf: [16]u8 = undefined;
        const str = std.fmt.bufPrintZ(&buf, "{d}", .{canvas.width}) catch return zqjs.NULL;
        return ctx.newString(str);
    }
    if (std.mem.eql(u8, name, "height")) {
        var buf: [16]u8 = undefined;
        const str = std.fmt.bufPrintZ(&buf, "{d}", .{canvas.height}) catch return zqjs.NULL;
        return ctx.newString(str);
    }

    // Forward to backing DOM element for other attributes
    if (canvas.element) |el| {
        if (z.getAttribute_zc(el, name)) |val| {
            return qjs.JS_NewStringLen(ctx.ptr, val.ptr, val.len);
        }
    }

    return zqjs.NULL;
}

/// Canvas.setAttribute(name, value)
fn js_canvas_setAttribute(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    if (argc < 2) return zqjs.UNDEFINED;

    const name = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(name);
    const value = ctx.toZString(argv[1]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(value);

    // Handle width/height by resizing the canvas
    if (std.mem.eql(u8, name, "width")) {
        if (std.fmt.parseInt(u32, value, 10)) |w| {
            canvas.resize(w, canvas.height) catch {};
        } else |_| {}
        return zqjs.UNDEFINED;
    }
    if (std.mem.eql(u8, name, "height")) {
        if (std.fmt.parseInt(u32, value, 10)) |h| {
            canvas.resize(canvas.width, h) catch {};
        } else |_| {}
        return zqjs.UNDEFINED;
    }

    // Forward to backing element
    if (canvas.element) |el| {
        z.setAttribute(el, name, value) catch {};
    }

    return zqjs.UNDEFINED;
}

/// Canvas.removeAttribute(name)
fn js_canvas_removeAttribute(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    if (argc < 1) return zqjs.UNDEFINED;

    const name = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(name);

    // Forward to backing element
    if (canvas.element) |el| {
        z.removeAttribute(el, name) catch {};
    }

    return zqjs.UNDEFINED;
}

/// Canvas.style getter - returns a cached CSSStyleDeclaration-like object
fn js_canvas_get_style(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    // Try to get cached __style property
    const existing = qjs.JS_GetPropertyStr(ctx.ptr, this_val, "__style");
    if (!qjs.JS_IsUndefined(existing)) {
        return existing; // Already ref-counted by GetProperty
    }

    // Create new style object with empty string defaults
    const style = ctx.newObject();
    _ = qjs.JS_SetPropertyStr(ctx.ptr, style, "display", ctx.newString(""));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, style, "height", ctx.newString(""));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, style, "width", ctx.newString(""));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, style, "boxSizing", ctx.newString(""));
    _ = qjs.JS_SetPropertyStr(ctx.ptr, style, "overflow", ctx.newString(""));

    // Cache it on the canvas object (dup since SetProperty consumes)
    _ = qjs.JS_SetPropertyStr(ctx.ptr, this_val, "__style", qjs.JS_DupValue(ctx.ptr, style));

    return style;
}

/// Canvas.tagName / Canvas.nodeName getter - returns "CANVAS"
fn js_canvas_get_tagName(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    return ctx.newString("CANVAS");
}

/// Canvas.isConnected getter - check if backing element is in the DOM
fn js_canvas_get_isConnected(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.FALSE;

    // Connected if backing element has a parent
    if (canvas.element) |el| {
        if (z.parentNode(z.elementToNode(el))) |_| {
            return zqjs.TRUE;
        }
    }
    return zqjs.FALSE;
}

/// Canvas.parentNode getter - returns parent via backing element
fn js_canvas_get_parentNode(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.NULL;

    if (canvas.element) |el| {
        if (z.parentNode(z.elementToNode(el))) |parent| {
            return DOMBridge.wrapNode(ctx, parent) catch return zqjs.NULL;
        }
    }
    return zqjs.NULL;
}

/// Setter Canvas.width
fn js_canvas_get_width(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    // Return int32
    return qjs.JS_NewInt32(ctx.ptr, @intCast(canvas.width));
}

/// Setter Canvas.width
fn js_canvas_set_width(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    // Safety: Setters are called with 1 argument (the value)
    const args = argv[0..@intCast(argc)];
    if (args.len < 1) return zqjs.EXCEPTION;

    // The value to set is args[0]
    var new_w: u32 = 0;
    if (qjs.JS_ToUint32(ctx.ptr, &new_w, args[0]) != 0) return zqjs.EXCEPTION;

    canvas.resize(new_w, canvas.height) catch return zqjs.EXCEPTION;
    return zqjs.UNDEFINED;
}

/// Getter Canvas.height
fn js_canvas_get_height(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    return qjs.JS_NewInt32(ctx.ptr, @intCast(canvas.height));
}

/// Setter Canvas.height
fn js_canvas_set_height(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    const args = argv[0..@intCast(argc)];
    if (args.len < 1) return zqjs.EXCEPTION;

    // The value to set is args[0]
    var new_h: u32 = 0;
    if (qjs.JS_ToUint32(ctx.ptr, &new_h, args[0]) != 0) return zqjs.EXCEPTION;

    canvas.resize(canvas.width, new_h) catch return zqjs.EXCEPTION;
    return zqjs.UNDEFINED;
}

/// Getter Canvas.fillStyle
fn js_canvas_get_fillStyle(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    // MVP: Just return default string or cache it?
    // Returning "#000000" is fine for now, or store the string in Canvas struct if I want round-trip exactness.
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    return ctx.newString("#000000"); // Simplify for MVP
}

/// Setter Canvas.fillStyle
fn js_canvas_set_fillStyle(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    const args = argv[0..@intCast(argc)];

    if (args.len < 1) return zqjs.EXCEPTION;

    const style_str = ctx.toZString(args[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(style_str);

    canvas.setFillStyle(style_str);

    return zqjs.UNDEFINED;
}

fn js_canvas_get_font(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    // Return current state, e.g. "24.5px Arial"
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrintZ(&buf, "{d}px Arial", .{canvas.font_size}) catch "10px Arial";
    return ctx.newString(str);
}

fn js_canvas_set_font(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    if (argc < 1) return zqjs.UNDEFINED;

    const str = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(str);

    // 1. Find "px"
    var size_str: []const u8 = str;
    if (std.mem.indexOf(u8, str, "px")) |px_idx| {
        // We found "px". Now walk backwards to find the start of the number.
        // Example: "  bold  12.5px  Arial"
        // px_idx points to 'p'

        var start = px_idx;
        while (start > 0) {
            const c = str[start - 1];
            // Allow digits (0-9) and dots (.)
            if (std.ascii.isDigit(c) or c == '.') {
                start -= 1;
            } else {
                break;
            }
        }

        // Safety: If we didn't find any digits, abort
        if (start == px_idx) {
            std.debug.print("⚠️ Canvas: Could not parse font size from '{s}'\n", .{str});
            return zqjs.UNDEFINED;
        }

        size_str = str[start..px_idx];
    } else {
        // Fallback: Try to parse the entire string (e.g. ctx.font = "20")
        // But first, trim whitespace to please parseFloat
        size_str = std.mem.trim(u8, str, " ");
    }

    // 2. Parse Float
    if (std.fmt.parseFloat(f32, size_str)) |size| {
        canvas.font_size = size;
        // std.debug.print("✅ Font size set to: {d}px\n", .{size});
    } else |_| {
        std.debug.print("⚠️ Canvas: Invalid font size number: '{s}'\n", .{size_str});
    }

    return zqjs.UNDEFINED;
}

fn js_canvas_get_strokeStyle(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    return ctx.newString("#000000"); // MVP return
}

fn js_canvas_set_strokeStyle(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    if (argc < 1) return zqjs.EXCEPTION;
    const style_str = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(style_str);

    canvas.setStrokeStyle(style_str);
    return zqjs.UNDEFINED;
}

fn js_canvas_closePath(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    canvas.closePath();
    return zqjs.UNDEFINED;
}

// 2. LineWidth Accessor
fn js_canvas_get_lineWidth(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    return qjs.JS_NewFloat64(ctx.ptr, @floatCast(canvas.line_width));
}

fn js_canvas_set_lineWidth(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    if (argc < 1) return zqjs.EXCEPTION;

    var val: f64 = 1.0;
    if (qjs.JS_ToFloat64(ctx.ptr, &val, argv[0]) == 0) {
        canvas.line_width = @floatCast(val);
    }
    return zqjs.UNDEFINED;
}

// === Methods
fn js_canvas_getContext(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const args = argv[0..@intCast(argc)];

    // Check if 'this' is actually a canvas
    _ = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");

    if (args.len == 0) return zqjs.NULL;

    const context_type = ctx.toZString(args[0]) catch return zqjs.NULL;
    defer ctx.freeZString(context_type);

    if (std.mem.eql(u8, context_type, "2d")) {
        // Return a Context2D object.
        // For MVP, we often return the Canvas itself or a proxy.
        // A simple trick for Level 1: The Canvas IS the context.
        // This allows `canvas.getContext('2d').fillRect(...)` to work if we put methods on Canvas.
        // OR: We return a distinct object. Let's return a "Mock Context" that points to this canvas.

        // MVP: Return 'this' (the canvas) but compliant code expects a separate object.
        // For now, let's return a simple object that has the drawing methods.
        // But implementing a whole new class for Context2D is verbose.
        // HACK: Return 'this' allows direct drawing: canvas.fillRect(...)
        // BETTER: Return a simple object { canvas: this, fillRect: ... }

        // Let's stick to returning 'this' for the "Level 1" simplicity
        // IF we add fillRect to the Canvas prototype.
        return qjs.JS_DupValue(ctx.ptr, this_val);
    }

    return zqjs.NULL;
}

fn js_canvas_drawImage(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");
    const args = argv[0..@intCast(argc)];

    if (args.len < 3) return ctx.throwTypeError("Syntax: drawImage(image, dx, dy, [dw, dh])");

    // 1. Unwrap ImageBitmap
    const img = js_image.unwrapImage(ctx, args[0]) orelse return ctx.throwTypeError("Arg 1 must be ImageBitmap");

    // 2. Parse Coords
    var dx: i32 = 0;
    var dy: i32 = 0;
    var dw: i32 = img.width;
    var dh: i32 = img.height;

    if (args.len > 1) _ = qjs.JS_ToInt32(ctx.ptr, &dx, args[1]);
    if (args.len > 2) _ = qjs.JS_ToInt32(ctx.ptr, &dy, args[2]);
    if (args.len > 3) _ = qjs.JS_ToInt32(ctx.ptr, &dw, args[3]);
    if (args.len > 4) _ = qjs.JS_ToInt32(ctx.ptr, &dh, args[4]);

    canvas.drawImage(img, dx, dy, dw, dh);

    return zqjs.UNDEFINED;
}

/// Canvas.fillRect(x, y, w, h)
fn js_canvas_fillRect(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");
    const args = argv[0..@intCast(argc)];

    var x: i32 = 0;
    var y: i32 = 0;
    var w_val: i32 = 0;
    var h_val: i32 = 0;

    if (args.len > 0) _ = qjs.JS_ToInt32(ctx.ptr, &x, args[0]);
    if (args.len > 1) _ = qjs.JS_ToInt32(ctx.ptr, &y, args[1]);
    if (args.len > 2) _ = qjs.JS_ToInt32(ctx.ptr, &w_val, args[2]);
    if (args.len > 3) _ = qjs.JS_ToInt32(ctx.ptr, &h_val, args[3]);

    canvas.fillRect(x, y, w_val, h_val);

    return zqjs.UNDEFINED;
}

// ctx.arc(x, y, radius, startAngle, endAngle)
fn js_canvas_arc(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    var r: f64 = 0;
    var start: f64 = 0;
    var end: f64 = 0;

    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);
    if (argc > 2) _ = qjs.JS_ToFloat64(ctx.ptr, &r, argv[2]);
    if (argc > 3) _ = qjs.JS_ToFloat64(ctx.ptr, &start, argv[3]);
    if (argc > 4) _ = qjs.JS_ToFloat64(ctx.ptr, &end, argv[4]);

    canvas.arc(@floatCast(x), @floatCast(y), @floatCast(r), @floatCast(start), @floatCast(end));
    return zqjs.UNDEFINED;
}

fn js_canvas_translate(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);

    canvas.translate(@floatCast(x), @floatCast(y));
    return zqjs.UNDEFINED;
}

fn js_canvas_scale(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: f64 = 1;
    var y: f64 = 1;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);

    canvas.scale(@floatCast(x), @floatCast(y));
    return zqjs.UNDEFINED;
}

// Canvas.measureText(text) -> TextMetrics { width: number }
fn js_canvas_measureText(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");
    const args = argv[0..@intCast(argc)];

    if (args.len < 1) return ctx.throwTypeError("Syntax: measureText(text)");

    const text = ctx.toZString(args[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(text);

    if (rc.global_font) |f| {
        canvas.setFont(f, canvas.font_size);
    } else {
        // If no font is loaded, width is definitely 0
        return ctx.throwInternalError("No font loaded");
    }

    // 1. Calculate Width
    const width = canvas.measureText(text);

    // 2. Create TextMetrics Object
    const metrics = ctx.newObject();

    // 3. Set 'width' property
    _ = qjs.JS_SetPropertyStr(ctx.ptr, metrics, "width", qjs.JS_NewFloat64(ctx.ptr, @floatCast(width)));

    return metrics;
}

// === Conversion MEthods

/// reurns a base64 encoded PNG or JPEG
fn js_canvas_toDataURL(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");
    const rc = RuntimeContext.get(ctx);
    const args = argv[0..@intCast(argc)];

    // Defaults
    var mime_type: []const u8 = "image/png";
    var quality: f64 = 0.92;

    // Parse Args
    if (args.len > 0) {
        if (qjs.JS_IsString(args[0])) {
            const str = ctx.toZString(args[0]) catch "image/png";
            // Check for JPEG request
            if (std.mem.eql(u8, str, "image/jpeg") or std.mem.eql(u8, str, "image/jpg")) {
                mime_type = "image/jpeg";
            }
            ctx.freeZString(str);
        }
    }
    if (args.len > 1) {
        _ = qjs.JS_ToFloat64(ctx.ptr, &quality, args[1]);
    }

    // Encode
    var raw_data: []u8 = undefined;
    var prefix: []const u8 = undefined;
    var is_c_memory: bool = false;

    if (std.mem.eql(u8, mime_type, "image/jpeg")) {
        raw_data = canvas.getJpegData(@floatCast(quality)) catch return ctx.throwInternalError("JPEG Encoding failed");
        prefix = "data:image/jpeg;base64,";
    } else {
        var png_len: c_int = 0;
        // data = canvas.getPngData() catch return ctx.throwInternalError("PNG Encoding failed");
        // prefix = "data:image/png;base64,";
        const png_c_ptr = stbi_write_png_to_mem(
            canvas.pixels.ptr,
            0,
            @intCast(canvas.width),
            @intCast(canvas.height),
            4,
            &png_len,
        );
        if (png_c_ptr == null) return ctx.throwInternalError("Encoding failed");
        raw_data = png_c_ptr.?[0..@intCast(png_len)];
        prefix = "data:image/png;base64,";
        is_c_memory = true;
    }

    defer {
        if (is_c_memory) {
            stbiw_free(raw_data.ptr); // Free C memory
        } else {
            canvas.allocator.free(raw_data); // Free Zig memory
        }
    }

    // Base64
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(raw_data.len);
    const total_len = prefix.len + b64_len;

    const temp_buf = rc.allocator.alloc(u8, total_len) catch return zqjs.EXCEPTION;
    defer rc.allocator.free(temp_buf);

    @memcpy(temp_buf[0..prefix.len], prefix);
    _ = encoder.encode(temp_buf[prefix.len..], raw_data);

    return qjs.JS_NewStringLen(ctx.ptr, temp_buf.ptr, temp_buf.len);
}
// fn js_canvas_toDataURL(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
//     const ctx = zqjs.Context{ .ptr = ctx_ptr };
//     const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");

//     const png_data = canvas.getPngData() catch return ctx.throwInternalError("PNG Encoding failed");
//     defer canvas.allocator.free(png_data); // getPngData returns owned slice

//     // Base64 Encode
//     const encoder = std.base64.standard.Encoder;
//     const b64_len = encoder.calcSize(png_data.len);
//     const prefix = "data:image/png;base64,";

//     // Create string buffer
//     // JS_NewStringLen expects a buffer we don't own, it copies.
//     // So we alloc in Zig, encode, create JS string, then free Zig buffer.
//     const rc = RuntimeContext.get(ctx);
//     const total_len = prefix.len + b64_len;
//     const temp_buf = rc.allocator.alloc(u8, total_len) catch return zqjs.EXCEPTION;
//     defer rc.allocator.free(temp_buf);

//     @memcpy(temp_buf[0..prefix.len], prefix);
//     _ = encoder.encode(temp_buf[prefix.len..], png_data);

//     return qjs.JS_NewStringLen(ctx.ptr, temp_buf.ptr, temp_buf.len);
// }

// canvas(callback, type, quality) or canvas.toBlob() -> Promise
/// PNG or JPEG
fn js_canvas_toBlob(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");
    const args = argv[0..@intCast(argc)];

    // --- 1. Detect Argument Mode ---
    // Mode A: toBlob(callback, type, quality)
    // Mode B: await toBlob(type, quality)

    var callback_func: qjs.JSValue = zqjs.UNDEFINED;
    var type_arg_idx: usize = 0;

    if (args.len > 0 and qjs.JS_IsFunction(ctx.ptr, args[0])) {
        callback_func = args[0];
        type_arg_idx = 1; // Type is the 2nd arg
    }

    // --- 2. Parse Type & Quality ---
    var mime_type: []const u8 = "image/png";
    var quality: f64 = 0.92;

    if (args.len > type_arg_idx) {
        if (qjs.JS_IsString(args[type_arg_idx])) {
            const str = ctx.toZString(args[type_arg_idx]) catch "image/png";
            if (std.mem.eql(u8, str, "image/jpeg") or std.mem.eql(u8, str, "image/jpg")) {
                mime_type = "image/jpeg";
            }
            ctx.freeZString(str);
        }
    }
    if (args.len > type_arg_idx + 1) {
        _ = qjs.JS_ToFloat64(ctx.ptr, &quality, args[type_arg_idx + 1]);
    }

    // --- 3. Encode Data ---
    var data: []u8 = undefined;
    if (std.mem.eql(u8, mime_type, "image/jpeg")) {
        data = canvas.getJpegData(@floatCast(quality)) catch return zqjs.NULL;
    } else {
        data = canvas.getPngData() catch return zqjs.NULL;
    }
    defer canvas.allocator.free(data);

    // --- 4. Create Blob Object ---
    const blob_obj = BlobObject.init(rc.allocator, data, mime_type) catch return zqjs.NULL;
    const blob_val = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.blob);
    _ = qjs.JS_SetOpaque(blob_val, blob_obj);

    // --- 5. Return (Callback or Promise) ---
    if (!qjs.JS_IsUndefined(callback_func)) {
        // Callback Mode: Return undefined
        var cb_args = [_]qjs.JSValue{blob_val};
        const ret = qjs.JS_Call(ctx.ptr, callback_func, zqjs.UNDEFINED, 1, &cb_args);
        qjs.JS_FreeValue(ctx.ptr, ret);
        ctx.freeValue(blob_val);
        return zqjs.UNDEFINED;
    } else {
        // Promise Mode: Return Promise<Blob>
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        const promise_ctor = ctx.getPropertyStr(global, "Promise");
        defer ctx.freeValue(promise_ctor);
        const resolve_fn = ctx.getPropertyStr(promise_ctor, "resolve");
        defer ctx.freeValue(resolve_fn);

        var resolve_args = [_]qjs.JSValue{blob_val};
        const result = qjs.JS_Call(ctx.ptr, resolve_fn, promise_ctor, 1, &resolve_args);
        ctx.freeValue(blob_val);
        return result;
    }
}
// fn js_canvas_toBlob(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
//     const ctx = zqjs.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);
//     const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");

//     // Generate the Data (PNG for now, effectively ignoring 'type' and 'quality' args)
//     const png_data = canvas.getPngData() catch return zqjs.NULL;
//     defer canvas.allocator.free(png_data);

//     // Create Blob Object
//     const blob_obj = BlobObject.init(rc.allocator, png_data, "image/png") catch return zqjs.NULL;

//     // Wrap in JS Value
//     const blob_val = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.blob);
//     if (qjs.JS_IsException(blob_val)) {
//         blob_obj.deinit();
//         return zqjs.EXCEPTION;
//     }
//     _ = qjs.JS_SetOpaque(blob_val, blob_obj);

//     // Polymorphism with Web callback-based or zexplorer promised-based

//     const args = argv[0..@intCast(argc)];

//     // Check if the first argument is a Callback Function
//     if (args.len > 0 and qjs.JS_IsFunction(ctx.ptr, args[0])) {
//         // [canvas.toBlob(callback, type, quality)]

//         const callback_func = args[0];
//         var cb_args = [_]qjs.JSValue{blob_val};

//         // Invoke the callback: callback(blob)
//         const ret = qjs.JS_Call(ctx.ptr, callback_func, zqjs.UNDEFINED, 1, &cb_args);
//         ctx.freeValue(ret);
//         // qjs.JS_FreeValue(ctx.ptr, ret); // We don't care what the callback returns

//         // Callback mode returns undefined
//         ctx.freeValue(blob_val); // The callback was passed the value, now we are done with our ref
//         return zqjs.UNDEFINED;
//     } else {
//         // [await canvas.toBlob() -> Promise

//         const global = ctx.getGlobalObject();
//         defer ctx.freeValue(global);
//         const promise_ctor = ctx.getPropertyStr(global, "Promise");
//         defer ctx.freeValue(promise_ctor);
//         const resolve_fn = ctx.getPropertyStr(promise_ctor, "resolve");
//         defer ctx.freeValue(resolve_fn);

//         var resolve_args = [_]qjs.JSValue{blob_val};
//         const result = qjs.JS_Call(
//             ctx.ptr,
//             resolve_fn,
//             promise_ctor,
//             1,
//             &resolve_args,
//         );

//         ctx.freeValue(blob_val);
//         return result;
//     }
// }

fn js_canvas_fillText(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx); // <--- Access Context
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");
    const args = argv[0..@intCast(argc)];

    if (args.len < 3) return ctx.throwTypeError("Syntax: fillText(text, x, y)");

    const text = ctx.toZString(args[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(text);

    var x: f64 = 0;
    var y: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, args[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, args[2]);

    // Use font from RuntimeContext
    if (rc.global_font) |f| {
        // For MVP, we pass the font pointer to the canvas for this draw call
        canvas.setFont(f, canvas.font_size);
        canvas.fillText(text, @floatCast(x), @floatCast(y));
    } else {
        std.debug.print("⚠️ No font registered! Use registerFont(blob)\n", .{});
    }

    return zqjs.UNDEFINED;
}

fn js_registerFont(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx); // <--- Access Context
    const args = argv[0..@intCast(argc)];

    if (args.len < 1) return ctx.throwTypeError("Arg 1 must be Blob");

    const blob_ptr = qjs.JS_GetOpaque(args[0], rc.classes.blob);
    if (blob_ptr == null) return ctx.throwTypeError("Arg 1 must be Blob");
    const blob = @as(*BlobObject, @ptrCast(@alignCast(blob_ptr)));

    // Clean up existing font if present
    if (rc.global_font) |f| {
        f.deinit();
    }

    // Load new font into RuntimeContext
    rc.global_font = Font.init(rc.allocator, blob.data) catch return ctx.throwInternalError("Failed to parse TTF");

    return zqjs.UNDEFINED;
}

fn js_canvas_save(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    canvas.save() catch return ctx.throwInternalError("Stack overflow");
    return zqjs.UNDEFINED;
}

// Canvas.restore()
fn js_canvas_restore(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    canvas.restore();
    return zqjs.UNDEFINED;
}

fn js_canvas_beginPath(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    canvas.beginPath();
    return zqjs.UNDEFINED;
}

fn js_canvas_moveTo(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);

    canvas.moveTo(@floatCast(x), @floatCast(y));
    return zqjs.UNDEFINED;
}

fn js_canvas_lineTo(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);

    canvas.lineTo(@floatCast(x), @floatCast(y));
    return zqjs.UNDEFINED;
}

fn js_canvas_stroke(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    canvas.stroke();
    return zqjs.UNDEFINED;
}

// === Additional Canvas2D context methods (needed by Chart.js) ===

/// ctx.setTransform(a, b, c, d, e, f) - reset transform to matrix
/// Simplified: ignores rotation (b,c), uses a=scaleX, d=scaleY, e=translateX, f=translateY
fn js_canvas_setTransform(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var a: f64 = 1;
    var d: f64 = 1;
    var e: f64 = 0;
    var f: f64 = 0;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &a, argv[0]); // scaleX
    // argv[1] = b (skewY), argv[2] = c (skewX) - ignored for simplicity
    if (argc > 3) _ = qjs.JS_ToFloat64(ctx.ptr, &d, argv[3]); // scaleY
    if (argc > 4) _ = qjs.JS_ToFloat64(ctx.ptr, &e, argv[4]); // translateX
    if (argc > 5) _ = qjs.JS_ToFloat64(ctx.ptr, &f, argv[5]); // translateY

    canvas.sx = @floatCast(a);
    canvas.sy = @floatCast(d);
    canvas.tx = @floatCast(e);
    canvas.ty = @floatCast(f);

    return zqjs.UNDEFINED;
}

/// ctx.clearRect(x, y, w, h) - clear area to transparent black
fn js_canvas_clearRect(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: i32 = 0;
    var y: i32 = 0;
    var w: i32 = 0;
    var h: i32 = 0;
    if (argc > 0) _ = qjs.JS_ToInt32(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToInt32(ctx.ptr, &y, argv[1]);
    if (argc > 2) _ = qjs.JS_ToInt32(ctx.ptr, &w, argv[2]);
    if (argc > 3) _ = qjs.JS_ToInt32(ctx.ptr, &h, argv[3]);

    const cv_w: i32 = @intCast(canvas.width);
    const cv_h: i32 = @intCast(canvas.height);
    const x_start = @max(0, x);
    const y_start = @max(0, y);
    const x_end = @min(cv_w, x + w);
    const y_end = @min(cv_h, y + h);

    if (x_start >= x_end or y_start >= y_end) return zqjs.UNDEFINED;

    var row = y_start;
    while (row < y_end) : (row += 1) {
        var col = x_start;
        while (col < x_end) : (col += 1) {
            const idx: usize = (@as(usize, @intCast(row)) * canvas.width + @as(usize, @intCast(col))) * 4;
            canvas.pixels[idx + 0] = 0;
            canvas.pixels[idx + 1] = 0;
            canvas.pixels[idx + 2] = 0;
            canvas.pixels[idx + 3] = 0;
        }
    }
    return zqjs.UNDEFINED;
}

/// ctx.fill() - fill current path (simplified: fill enclosed polygon)
fn js_canvas_fill(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    // For bars, Chart.js uses fillRect directly. fill() is for path-based shapes.
    // Simplified scanline fill for closed paths
    if (canvas.path.items.len < 3) return zqjs.UNDEFINED;

    const color = canvas.fill_color;
    const points = canvas.path.items;
    const cv_w = canvas.width;
    const cv_h = canvas.height;

    // Find bounding box
    var min_y: f32 = points[0].y;
    var max_y: f32 = points[0].y;
    for (points) |p| {
        if (p.y < min_y) min_y = p.y;
        if (p.y > max_y) max_y = p.y;
    }

    const start_y = @max(0, @as(i32, @intFromFloat(min_y)));
    const end_y = @min(@as(i32, @intCast(cv_h)), @as(i32, @intFromFloat(max_y)) + 1);

    // Scanline fill
    var scan_y = start_y;
    while (scan_y < end_y) : (scan_y += 1) {
        const fy: f32 = @floatFromInt(scan_y);
        // Find intersections with polygon edges
        var x_ints: [64]f32 = undefined;
        var n_ints: usize = 0;

        var i: usize = 0;
        while (i < points.len and n_ints < 63) : (i += 1) {
            const j = if (i + 1 < points.len) i + 1 else 0;
            const p0 = points[i];
            const p1 = points[j];

            if ((p0.y <= fy and p1.y > fy) or (p1.y <= fy and p0.y > fy)) {
                const t = (fy - p0.y) / (p1.y - p0.y);
                x_ints[n_ints] = p0.x + t * (p1.x - p0.x);
                n_ints += 1;
            }
        }

        // Sort intersections
        var s: usize = 0;
        while (s < n_ints) : (s += 1) {
            var k = s + 1;
            while (k < n_ints) : (k += 1) {
                if (x_ints[k] < x_ints[s]) {
                    const tmp = x_ints[s];
                    x_ints[s] = x_ints[k];
                    x_ints[k] = tmp;
                }
            }
        }

        // Fill between pairs
        var p: usize = 0;
        while (p + 1 < n_ints) : (p += 2) {
            const x0 = @max(0, @as(i32, @intFromFloat(x_ints[p])));
            const x1 = @min(@as(i32, @intCast(cv_w)), @as(i32, @intFromFloat(x_ints[p + 1])));
            var col = x0;
            while (col < x1) : (col += 1) {
                const idx: usize = (@as(usize, @intCast(scan_y)) * cv_w + @as(usize, @intCast(col))) * 4;
                canvas.pixels[idx + 0] = color.r;
                canvas.pixels[idx + 1] = color.g;
                canvas.pixels[idx + 2] = color.b;
                canvas.pixels[idx + 3] = color.a;
            }
        }
    }
    return zqjs.UNDEFINED;
}

/// ctx.rect(x, y, w, h) - add rectangle sub-path
fn js_canvas_rect(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);
    if (argc > 2) _ = qjs.JS_ToFloat64(ctx.ptr, &w, argv[2]);
    if (argc > 3) _ = qjs.JS_ToFloat64(ctx.ptr, &h, argv[3]);

    canvas.moveTo(@floatCast(x), @floatCast(y));
    canvas.lineTo(@floatCast(x + w), @floatCast(y));
    canvas.lineTo(@floatCast(x + w), @floatCast(y + h));
    canvas.lineTo(@floatCast(x), @floatCast(y + h));
    canvas.closePath();

    return zqjs.UNDEFINED;
}

/// ctx.strokeRect(x, y, w, h) - stroke a rectangle
fn js_canvas_strokeRect(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    if (argc > 0) _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    if (argc > 1) _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);
    if (argc > 2) _ = qjs.JS_ToFloat64(ctx.ptr, &w, argv[2]);
    if (argc > 3) _ = qjs.JS_ToFloat64(ctx.ptr, &h, argv[3]);

    canvas.beginPath();
    canvas.moveTo(@floatCast(x), @floatCast(y));
    canvas.lineTo(@floatCast(x + w), @floatCast(y));
    canvas.lineTo(@floatCast(x + w), @floatCast(y + h));
    canvas.lineTo(@floatCast(x), @floatCast(y + h));
    canvas.closePath();
    canvas.stroke();

    return zqjs.UNDEFINED;
}

/// ctx.clip() - no-op stub (clipping not implemented)
fn js_canvas_clip(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.UNDEFINED;
}

/// ctx.setLineDash(segments) - no-op stub (dashed lines not implemented)
fn js_canvas_setLineDash(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.UNDEFINED;
}

/// ctx.getLineDash() - returns empty array
fn js_canvas_getLineDash(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    return ctx.newArray();
}

/// ctx.createLinearGradient(x0, y0, x1, y1) - returns a stub gradient object
fn js_canvas_createLinearGradient(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    // Return an object with addColorStop method (no-op)
    const grad = ctx.newObject();
    const add_stop_fn = qjs.JS_NewCFunction(ctx.ptr, js_gradient_addColorStop, "addColorStop", 2);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, grad, "addColorStop", add_stop_fn);
    return grad;
}

/// ctx.createRadialGradient(x0, y0, r0, x1, y1, r1) - returns a stub gradient object
fn js_canvas_createRadialGradient(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const grad = ctx.newObject();
    const add_stop_fn = qjs.JS_NewCFunction(ctx.ptr, js_gradient_addColorStop, "addColorStop", 2);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, grad, "addColorStop", add_stop_fn);
    return grad;
}

/// gradient.addColorStop(offset, color) - no-op
fn js_gradient_addColorStop(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.UNDEFINED;
}

/// ctx.createPattern() - returns null stub
fn js_canvas_createPattern(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.NULL;
}

/// ctx.isPointInPath() - returns false stub
fn js_canvas_isPointInPath(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.FALSE;
}

/// canvas.addEventListener() - no-op for SSR (Chart.js binds mouse/touch events)
fn js_canvas_addEventListener(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.UNDEFINED;
}

/// canvas.removeEventListener() - no-op for SSR
fn js_canvas_removeEventListener(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.UNDEFINED;
}

/// ctx.strokeText(text, x, y) - stub that delegates to fillText for now
fn js_canvas_strokeText(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    // Reuse fillText implementation (stroke text is complex, fill is a decent approximation)
    return js_canvas_fillText(ctx_ptr, this_val, argc, argv);
}

/// ctx.rotate(angle) - stub (rotation not fully supported in pixel engine)
fn js_canvas_rotate(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    // Rotation requires a full affine transform matrix; stub for SSR
    return zqjs.UNDEFINED;
}

/// ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, x, y) - approximate with lineTo
fn js_canvas_bezierCurveTo(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    var cp1x: f64 = 0;
    var cp1y: f64 = 0;
    var cp2x: f64 = 0;
    var cp2y: f64 = 0;
    var x: f64 = 0;
    var y: f64 = 0;

    _ = qjs.JS_ToFloat64(ctx.ptr, &cp1x, argv[0]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &cp1y, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &cp2x, argv[2]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &cp2y, argv[3]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[4]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[5]);

    canvas.bezierCurveTo(@floatCast(cp1x), @floatCast(cp1y), @floatCast(cp2x), @floatCast(cp2y), @floatCast(x), @floatCast(y));

    return zqjs.UNDEFINED;
}

/// ctx.quadraticCurveTo(cpx, cpy, x, y) - approximate with lineTo
fn js_canvas_quadraticCurveTo(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    var cpx: f64 = 0;
    var cpy: f64 = 0;
    var x: f64 = 0;
    var y: f64 = 0;

    _ = qjs.JS_ToFloat64(ctx.ptr, &cpx, argv[0]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &cpy, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[2]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[3]);

    canvas.quadraticCurveTo(@floatCast(cpx), @floatCast(cpy), @floatCast(x), @floatCast(y));

    return zqjs.UNDEFINED;
}

/// ctx.ellipse() - no-op stub
fn js_canvas_ellipse(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return zqjs.UNDEFINED;
}

/// ctx.resetTransform() - reset to identity
fn js_canvas_resetTransformJS(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return zqjs.UNDEFINED;
    canvas.resetTransform();
    return zqjs.UNDEFINED;
}

// --- Cached property getters/setters for Canvas2D string/number properties ---
// These use __propName on the JS object for persistence

fn js_canvas_get_cached_string(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, prop_name: [:0]const u8, default: [:0]const u8) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const existing = qjs.JS_GetPropertyStr(ctx.ptr, this_val, prop_name);
    if (!qjs.JS_IsUndefined(existing)) return existing;
    return ctx.newString(default);
}

fn js_canvas_set_cached_string(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argv: [*c]qjs.JSValue, prop_name: [:0]const u8) qjs.JSValue {
    _ = qjs.JS_SetPropertyStr(ctx_ptr, this_val, prop_name, qjs.JS_DupValue(ctx_ptr, argv[0]));
    return zqjs.UNDEFINED;
}

fn js_canvas_get_textAlign(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_get_cached_string(ctx_ptr, this_val, "__textAlign", "start");
}
fn js_canvas_set_textAlign(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_set_cached_string(ctx_ptr, this_val, argv, "__textAlign");
}

fn js_canvas_get_textBaseline(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_get_cached_string(ctx_ptr, this_val, "__textBaseline", "alphabetic");
}
fn js_canvas_set_textBaseline(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_set_cached_string(ctx_ptr, this_val, argv, "__textBaseline");
}

fn js_canvas_get_globalAlpha(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const existing = qjs.JS_GetPropertyStr(ctx_ptr, this_val, "__globalAlpha");
    if (!qjs.JS_IsUndefined(existing)) return existing;
    return qjs.JS_NewFloat64(ctx_ptr, 1.0);
}
fn js_canvas_set_globalAlpha(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = qjs.JS_SetPropertyStr(ctx_ptr, this_val, "__globalAlpha", qjs.JS_DupValue(ctx_ptr, argv[0]));
    return zqjs.UNDEFINED;
}

fn js_canvas_get_globalCompositeOperation(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_get_cached_string(ctx_ptr, this_val, "__gco", "source-over");
}
fn js_canvas_set_globalCompositeOperation(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_set_cached_string(ctx_ptr, this_val, argv, "__gco");
}

fn js_canvas_get_lineCap(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_get_cached_string(ctx_ptr, this_val, "__lineCap", "butt");
}
fn js_canvas_set_lineCap(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_set_cached_string(ctx_ptr, this_val, argv, "__lineCap");
}

fn js_canvas_get_lineJoin(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_get_cached_string(ctx_ptr, this_val, "__lineJoin", "miter");
}
fn js_canvas_set_lineJoin(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_set_cached_string(ctx_ptr, this_val, argv, "__lineJoin");
}

fn js_canvas_get_shadowColor(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_get_cached_string(ctx_ptr, this_val, "__shadowColor", "rgba(0, 0, 0, 0)");
}
fn js_canvas_set_shadowColor(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_set_cached_string(ctx_ptr, this_val, argv, "__shadowColor");
}

fn js_canvas_get_shadowBlur(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const existing = qjs.JS_GetPropertyStr(ctx_ptr, this_val, "__shadowBlur");
    if (!qjs.JS_IsUndefined(existing)) return existing;
    return qjs.JS_NewFloat64(ctx_ptr, 0.0);
}
fn js_canvas_set_shadowBlur(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = qjs.JS_SetPropertyStr(ctx_ptr, this_val, "__shadowBlur", qjs.JS_DupValue(ctx_ptr, argv[0]));
    return zqjs.UNDEFINED;
}

fn js_canvas_get_shadowOffsetX(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const existing = qjs.JS_GetPropertyStr(ctx_ptr, this_val, "__shadowOffsetX");
    if (!qjs.JS_IsUndefined(existing)) return existing;
    return qjs.JS_NewFloat64(ctx_ptr, 0.0);
}
fn js_canvas_set_shadowOffsetX(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = qjs.JS_SetPropertyStr(ctx_ptr, this_val, "__shadowOffsetX", qjs.JS_DupValue(ctx_ptr, argv[0]));
    return zqjs.UNDEFINED;
}

fn js_canvas_get_shadowOffsetY(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const existing = qjs.JS_GetPropertyStr(ctx_ptr, this_val, "__shadowOffsetY");
    if (!qjs.JS_IsUndefined(existing)) return existing;
    return qjs.JS_NewFloat64(ctx_ptr, 0.0);
}
fn js_canvas_set_shadowOffsetY(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = qjs.JS_SetPropertyStr(ctx_ptr, this_val, "__shadowOffsetY", qjs.JS_DupValue(ctx_ptr, argv[0]));
    return zqjs.UNDEFINED;
}

fn js_canvas_get_direction(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_get_cached_string(ctx_ptr, this_val, "__direction", "ltr");
}
fn js_canvas_set_direction(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    return js_canvas_set_cached_string(ctx_ptr, this_val, argv, "__direction");
}

fn js_canvas_get_lineDashOffset(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const existing = qjs.JS_GetPropertyStr(ctx_ptr, this_val, "__lineDashOffset");
    if (!qjs.JS_IsUndefined(existing)) return existing;
    return qjs.JS_NewFloat64(ctx_ptr, 0.0);
}
fn js_canvas_set_lineDashOffset(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = qjs.JS_SetPropertyStr(ctx_ptr, this_val, "__lineDashOffset", qjs.JS_DupValue(ctx_ptr, argv[0]));
    return zqjs.UNDEFINED;
}

fn js_canvas_get_miterLimit(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const existing = qjs.JS_GetPropertyStr(ctx_ptr, this_val, "__miterLimit");
    if (!qjs.JS_IsUndefined(existing)) return existing;
    return qjs.JS_NewFloat64(ctx_ptr, 10.0);
}
fn js_canvas_set_miterLimit(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = qjs.JS_SetPropertyStr(ctx_ptr, this_val, "__miterLimit", qjs.JS_DupValue(ctx_ptr, argv[0]));
    return zqjs.UNDEFINED;
}

// === Liefcycle

fn js_canvas_constructor(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const args = argv[0..@intCast(argc)];

    // 1. Parse Args (Default 300x150)
    var width: u32 = 300;
    var height: u32 = 150;
    if (args.len > 0) {
        var val: u32 = 0;
        if (qjs.JS_ToUint32(ctx.ptr, &val, args[0]) == 0) width = val;
    }
    if (args.len > 1) {
        var val: u32 = 0;
        if (qjs.JS_ToUint32(ctx.ptr, &val, args[1]) == 0) height = val;
    }

    // 2. Alloc Native Struct
    const canvas = Canvas.init(rc.allocator, width, height) catch return zqjs.EXCEPTION;

    // 3. Create JS Object
    //    Note: We use new_target if we want to support subclassing, but for now strict class match is safer.
    const obj = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.canvas);
    if (qjs.JS_IsException(obj)) {
        canvas.deinit();
        return zqjs.EXCEPTION;
    }

    // 4. Link Opaque Pointer
    _ = qjs.JS_SetOpaque(obj, canvas);

    return obj;
}

fn finalizer(
    _: ?*qjs.JSRuntime,
    val: qjs.JSValue,
) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque2(null, val, obj_class_id);
    if (ptr) |p| {
        const self: *Canvas = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

// === Installer

pub fn install(ctx: zqjs.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    if (rc.classes.canvas == 0) {
        rc.classes.canvas = rt.newClassID();
    }

    try rt.newClass(rc.classes.canvas, .{
        .class_name = "HTMLCanvasElement",
        .finalizer = finalizer,
    });

    // Create prototype - DO NOT defer free, setClassProto takes ownership
    const proto = ctx.newObject();

    // Add methods to proto
    js_utils.defineMethod(ctx, proto, "getContext", js_canvas_getContext, 1);
    js_utils.defineMethod(ctx, proto, "toDataURL", js_canvas_toDataURL, 2);
    js_utils.defineMethod(ctx, proto, "toBlob", js_canvas_toBlob, 3);
    js_utils.defineMethod(ctx, proto, "fillRect", js_canvas_fillRect, 4);
    js_utils.defineMethod(ctx, proto, "drawImage", js_canvas_drawImage, 5);
    js_utils.defineMethod(ctx, proto, "fillText", js_canvas_fillText, 3);
    js_utils.defineMethod(ctx, proto, "scale", js_canvas_scale, 2);
    js_utils.defineMethod(ctx, proto, "translate", js_canvas_translate, 2);
    js_utils.defineMethod(ctx, proto, "measureText", js_canvas_measureText, 1);
    js_utils.defineMethod(ctx, proto, "save", js_canvas_save, 0);
    js_utils.defineMethod(ctx, proto, "restore", js_canvas_restore, 0);
    js_utils.defineMethod(ctx, proto, "arc", js_canvas_arc, 5);
    js_utils.defineMethod(ctx, proto, "closePath", js_canvas_closePath, 0);

    // Add accessors
    js_utils.defineGetter(ctx, proto, "canvas", js_canvas_get_canvas); // self-ref for Chart.js
    js_utils.defineAccessor(ctx, proto, "width", js_canvas_get_width, js_canvas_set_width);
    js_utils.defineAccessor(ctx, proto, "height", js_canvas_get_height, js_canvas_set_height);
    js_utils.defineAccessor(ctx, proto, "fillStyle", js_canvas_get_fillStyle, js_canvas_set_fillStyle);
    js_utils.defineAccessor(ctx, proto, "font", js_canvas_get_font, js_canvas_set_font);
    js_utils.defineMethod(ctx, proto, "beginPath", js_canvas_beginPath, 0);
    js_utils.defineMethod(ctx, proto, "moveTo", js_canvas_moveTo, 2);
    js_utils.defineMethod(ctx, proto, "lineTo", js_canvas_lineTo, 2);
    js_utils.defineMethod(ctx, proto, "stroke", js_canvas_stroke, 0);
    js_utils.defineAccessor(ctx, proto, "strokeStyle", js_canvas_get_strokeStyle, js_canvas_set_strokeStyle);
    js_utils.defineAccessor(ctx, proto, "lineWidth", js_canvas_get_lineWidth, js_canvas_set_lineWidth);

    // DOM compatibility (needed by Chart.js DOM platform)
    js_utils.defineMethod(ctx, proto, "getAttribute", js_canvas_getAttribute, 1);
    js_utils.defineMethod(ctx, proto, "setAttribute", js_canvas_setAttribute, 2);
    js_utils.defineMethod(ctx, proto, "removeAttribute", js_canvas_removeAttribute, 1);
    js_utils.defineGetter(ctx, proto, "style", js_canvas_get_style);
    js_utils.defineGetter(ctx, proto, "tagName", js_canvas_get_tagName);
    js_utils.defineGetter(ctx, proto, "nodeName", js_canvas_get_tagName);
    js_utils.defineGetter(ctx, proto, "isConnected", js_canvas_get_isConnected);
    js_utils.defineGetter(ctx, proto, "parentNode", js_canvas_get_parentNode);
    js_utils.defineMethod(ctx, proto, "addEventListener", js_canvas_addEventListener, 3);
    js_utils.defineMethod(ctx, proto, "removeEventListener", js_canvas_removeEventListener, 3);

    // Canvas2D context methods (needed by Chart.js rendering)
    js_utils.defineMethod(ctx, proto, "setTransform", js_canvas_setTransform, 6);
    js_utils.defineMethod(ctx, proto, "resetTransform", js_canvas_resetTransformJS, 0);
    js_utils.defineMethod(ctx, proto, "clearRect", js_canvas_clearRect, 4);
    js_utils.defineMethod(ctx, proto, "fill", js_canvas_fill, 0);
    js_utils.defineMethod(ctx, proto, "rect", js_canvas_rect, 4);
    js_utils.defineMethod(ctx, proto, "strokeRect", js_canvas_strokeRect, 4);
    js_utils.defineMethod(ctx, proto, "strokeText", js_canvas_strokeText, 3);
    js_utils.defineMethod(ctx, proto, "clip", js_canvas_clip, 0);
    js_utils.defineMethod(ctx, proto, "setLineDash", js_canvas_setLineDash, 1);
    js_utils.defineMethod(ctx, proto, "getLineDash", js_canvas_getLineDash, 0);
    js_utils.defineMethod(ctx, proto, "createLinearGradient", js_canvas_createLinearGradient, 4);
    js_utils.defineMethod(ctx, proto, "createRadialGradient", js_canvas_createRadialGradient, 6);
    js_utils.defineMethod(ctx, proto, "createPattern", js_canvas_createPattern, 2);
    js_utils.defineMethod(ctx, proto, "isPointInPath", js_canvas_isPointInPath, 2);
    js_utils.defineMethod(ctx, proto, "rotate", js_canvas_rotate, 1);
    js_utils.defineMethod(ctx, proto, "bezierCurveTo", js_canvas_bezierCurveTo, 6);
    js_utils.defineMethod(ctx, proto, "quadraticCurveTo", js_canvas_quadraticCurveTo, 4);
    js_utils.defineMethod(ctx, proto, "ellipse", js_canvas_ellipse, 7);

    // Canvas2D context properties (get/set with cached backing)
    js_utils.defineAccessor(ctx, proto, "textAlign", js_canvas_get_textAlign, js_canvas_set_textAlign);
    js_utils.defineAccessor(ctx, proto, "textBaseline", js_canvas_get_textBaseline, js_canvas_set_textBaseline);
    js_utils.defineAccessor(ctx, proto, "globalAlpha", js_canvas_get_globalAlpha, js_canvas_set_globalAlpha);
    js_utils.defineAccessor(ctx, proto, "globalCompositeOperation", js_canvas_get_globalCompositeOperation, js_canvas_set_globalCompositeOperation);
    js_utils.defineAccessor(ctx, proto, "lineCap", js_canvas_get_lineCap, js_canvas_set_lineCap);
    js_utils.defineAccessor(ctx, proto, "lineJoin", js_canvas_get_lineJoin, js_canvas_set_lineJoin);
    js_utils.defineAccessor(ctx, proto, "shadowColor", js_canvas_get_shadowColor, js_canvas_set_shadowColor);
    js_utils.defineAccessor(ctx, proto, "shadowBlur", js_canvas_get_shadowBlur, js_canvas_set_shadowBlur);
    js_utils.defineAccessor(ctx, proto, "shadowOffsetX", js_canvas_get_shadowOffsetX, js_canvas_set_shadowOffsetX);
    js_utils.defineAccessor(ctx, proto, "shadowOffsetY", js_canvas_get_shadowOffsetY, js_canvas_set_shadowOffsetY);
    js_utils.defineAccessor(ctx, proto, "direction", js_canvas_get_direction, js_canvas_set_direction);
    js_utils.defineAccessor(ctx, proto, "lineDashOffset", js_canvas_get_lineDashOffset, js_canvas_set_lineDashOffset);
    js_utils.defineAccessor(ctx, proto, "miterLimit", js_canvas_get_miterLimit, js_canvas_set_miterLimit);
    // Create Constructor
    const ctor_val = qjs.JS_NewCFunction2(ctx.ptr, js_canvas_constructor, "Canvas", 2, qjs.JS_CFUNC_constructor, 0);

    // Link Constructor and Prototype (using wrapper methods for cleaner code)
    try ctx.setPropertyStr(ctor_val, "prototype", ctx.dupValue(proto));
    try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor_val));

    // Set class prototype LAST - this takes ownership of proto
    ctx.setClassProto(rc.classes.canvas, proto);

    // Expose globally
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const reg_font_fn = ctx.newCFunction(js_registerFont, "registerFont", 1);
    try ctx.setPropertyStr(global, "registerFont", reg_font_fn);

    // Duplicate before setting, since setPropertyStr consumes the value
    const ctor_for_alias = ctx.dupValue(ctor_val);
    try ctx.setPropertyStr(global, "Canvas", ctor_val);
    try ctx.setPropertyStr(global, "HTMLCanvasElement", ctor_for_alias);
}

/// Check if data structure is PNG
pub fn verifyPngStructure(bytes: []const u8) !void {
    // Check Magic Bytes
    const magic = "\x89PNG\r\n\x1a\n";
    if (!std.mem.startsWith(u8, bytes, magic)) {
        std.debug.print("❌ Invalid PNG Header\n", .{});
        return error.InvalidPng;
    }

    // Scan for Chunks (IHDR, IDAT, IEND)
    // Chunk structure: Length (4) | Type (4) | Data (Len) | CRC (4)
    var has_ihdr = false;
    var has_idat = false;
    var has_iend = false;

    var pos: usize = 8; // Skip magic
    while (pos < bytes.len) {
        if (pos + 8 > bytes.len) break;

        // Read Length (Big Endian)
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const type_code = bytes[pos + 4 ..][0..4];

        // Check Type
        if (std.mem.eql(u8, type_code, "IHDR")) has_ihdr = true;
        if (std.mem.eql(u8, type_code, "IDAT")) has_idat = true;
        if (std.mem.eql(u8, type_code, "IEND")) has_iend = true;

        // Move to next chunk (Length + 4(Len) + 4(Type) + 4(CRC))
        pos += len + 12;
    }

    if (has_ihdr and has_idat and has_iend) {
        std.debug.print("🟢 Valid PNG: IHDR, IDAT, IEND found.\n", .{});
    } else {
        std.debug.print("⚠️  Corrupt PNG: Missing chunks (IHDR:{}, IDAT:{}, IEND:{})\n", .{ has_ihdr, has_idat, has_iend });
        return error.InvalidPng;
    }
}

// Check if data structure is JPEG
// pub fn verifyJpegStructure(bytes: []const u8) !void {
//     // JPEG must start with SOI (Start of Image) marker
//     if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != 0xD8) {
//         std.debug.print("❌ Invalid JPEG Header (missing SOI marker)\n", .{});
//         return error.InvalidJpeg;
//     }

//     var pos: usize = 0;
//     var has_sof = false; // Start of Frame (baseline DCT, progressive, etc.)
//     var has_sos = false; // Start of Scan
//     var has_dqt = false; // Quantization Table (at least one)
//     var has_dht = false; // Huffman Table (at least one)
//     var has_eoi = false; // End of Image

//     // Scan through markers
//     while (pos < bytes.len) {
//         // Check for marker (starts with 0xFF)
//         if (bytes[pos] != 0xFF) {
//             std.debug.print("❌ Invalid JPEG: Expected marker (0xFF) at position {}\n", .{pos});
//             return error.InvalidJpeg;
//         }

//         const marker = bytes[pos + 1];

//         // Skip padding bytes (0xFF followed by 0x00)
//         if (marker == 0x00) {
//             pos += 2;
//             continue;
//         }

//         // Handle standalone markers (no length field)
//         const standalone_markers = [_]u8{ 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9 };
//         for (standalone_markers) |m| {
//             if (marker == m) {
//                 if (marker == 0xD8) {
//                     // SOI - already checked at start
//                     pos += 2;
//                     continue;
//                 } else if (marker == 0xD9) {
//                     has_eoi = true;
//                     pos += 2;
//                     // Check if EOI is at the end: optional but good practice
//                     if (pos != bytes.len) {
//                         std.debug.print("⚠️  JPEG has data after EOI marker\n", .{});
//                     }
//                     break;
//                 }
//                 pos += 2;
//                 continue;
//             }
//         }

//         // For markers with length field
//         if (pos + 3 >= bytes.len) {
//             std.debug.print("❌ Invalid JPEG: Truncated marker at position {}\n", .{pos});
//             return error.InvalidJpeg;
//         }

//         // Read length (big-endian, includes length field itself)
//         const segment_len = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .big);

//         if (pos + segment_len > bytes.len) {
//             std.debug.print("❌ Invalid JPEG: Segment length exceeds file size\n", .{});
//             return error.InvalidJpeg;
//         }

//         // Check for required markers
//         switch (marker) {
//             0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => {
//                 // SOF (Start of Frame) markers
//                 has_sof = true;

//                 // SOF0 (baseline DCT) is the most common
//                 if (marker == 0xC0) {
//                     std.debug.print("Found Baseline DCT (SOF0)\n", .{});
//                 }
//             },
//             0xDA => { // SOS (Start of Scan)
//                 has_sos = true;

//                 // SOS has variable length depending on components
//                 if (segment_len < 8) {
//                     std.debug.print("❌ Invalid JPEG: SOS segment too short\n", .{});
//                     return error.InvalidJpeg;
//                 }

//                 const num_components = bytes[pos + 4];
//                 if (num_components < 1 or num_components > 4) {
//                     std.debug.print("❌ Invalid JPEG: Invalid number of components in SOS\n", .{});
//                     return error.InvalidJpeg;
//                 }
//             },
//             0xDB => { // DQT (Define Quantization Table)
//                 has_dqt = true;
//             },
//             0xC4 => { // DHT (Define Huffman Table)
//                 has_dht = true;
//             },
//             0xDD => { // DRI (Define Restart Interval)
//                 // Valid marker, but doesn't affect structure validity
//             },
//             0xE0...0xEF => { // APPn markers (application data)
//                 // Valid marker, often contains metadata like JFIF/EXIF
//                 if (marker == 0xE0) {
//                     // Check for JFIF identifier
//                     if (segment_len >= 7 and std.mem.eql(u8, bytes[pos + 4 ..][0..5], "JFIF\0")) {
//                         std.debug.print("Found JFIF marker\n", .{});
//                     }
//                 }
//             },
//             0xFE => { // COM (Comment)
//                 // Valid marker, contains comments
//             },
//             else => {
//                 // Check if marker is reserved or unknown
//                 if (marker >= 0xC0 and marker <= 0xFE) {
//                     // Valid marker in reserved range
//                 } else {
//                     std.debug.print("❌ Invalid JPEG: Unknown marker 0x{X:0>2}\n", .{marker});
//                     return error.InvalidJpeg;
//                 }
//             },
//         }

//         // Move to next marker
//         pos += segment_len;

//         // Skip any entropy-coded data after SOS
//         if (marker == 0xDA) {
//             // Scan for next marker (0xFF not followed by 0x00)
//             while (pos + 1 < bytes.len) {
//                 if (bytes[pos] == 0xFF and bytes[pos + 1] != 0x00) {
//                     break;
//                 }
//                 pos += 1;
//             }
//         }
//     }

//     // Check required markers
//     if (!has_sof) {
//         std.debug.print("❌ Invalid JPEG: Missing Start of Frame (SOF) marker\n", .{});
//         return error.InvalidJpeg;
//     }

//     if (!has_sos) {
//         std.debug.print("❌ Invalid JPEG: Missing Start of Scan (SOS) marker\n", .{});
//         return error.InvalidJpeg;
//     }

//     if (!has_eoi) {
//         std.debug.print("❌ Invalid JPEG: Missing End of Image (EOI) marker\n", .{});
//         return error.InvalidJpeg;
//     }

//     // DQT and DHT are technically required but some JPEGs might have them embedded differently
//     if (!has_dqt) {
//         std.debug.print("⚠️  Warning: No quantization tables (DQT) found\n", .{});
//     }

//     if (!has_dht) {
//         std.debug.print("⚠️  Warning: No Huffman tables (DHT) found\n", .{});
//     }

//     std.debug.print("🟢 Valid JPEG structure\n", .{});
// }

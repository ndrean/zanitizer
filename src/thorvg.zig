const std = @import("std");

// --- Opaque Handles ---
pub const Tvg_Canvas = opaque {};
pub const Tvg_Paint = opaque {};

// --- Enums ---
pub const Tvg_Result = enum(c_int) {
    Success = 0,
    InvalidArguments = 1,
    InsufficientCondition = 2,
    FailedAllocation = 3,
    MemoryCorruption = 4,
    NotSupported = 5,
    Unknown = 6,
};

pub const Tvg_Colorspace = enum(c_uint) {
    ABGR8888 = 0, // Standard RGBA (alpha-premultiplied)
    ARGB8888 = 1,
    ABGR8888S = 2, // Un-premultiplied
    ARGB8888S = 3,
};

// --- Extern C Functions ---
extern "c" fn tvg_engine_init(threads: c_uint) Tvg_Result;
extern "c" fn tvg_engine_term() Tvg_Result;
extern "c" fn tvg_swcanvas_create(op: c_uint) ?*Tvg_Canvas;
extern "c" fn tvg_canvas_destroy(canvas: *Tvg_Canvas) Tvg_Result;
extern "c" fn tvg_swcanvas_set_target(canvas: *Tvg_Canvas, buffer: [*]u32, stride: u32, w: u32, h: u32, cs: c_uint) Tvg_Result;
extern "c" fn tvg_canvas_add(canvas: *Tvg_Canvas, paint: *Tvg_Paint) Tvg_Result;
extern "c" fn tvg_canvas_draw(canvas: *Tvg_Canvas, clear: bool) Tvg_Result;
extern "c" fn tvg_canvas_sync(canvas: *Tvg_Canvas) Tvg_Result;
extern "c" fn tvg_picture_new() ?*Tvg_Paint;
extern "c" fn tvg_picture_load_data(paint: *Tvg_Paint, data: [*]const u8, size: u32, mimetype: [*c]const u8, rpath: [*c]const u8, copy: bool) Tvg_Result;
extern "c" fn tvg_picture_set_size(paint: *Tvg_Paint, w: f32, h: f32) Tvg_Result;
extern "c" fn tvg_font_load_data(name: [*c]const u8, data: [*]const u8, size: u32, mimetype: [*c]const u8, copy: bool) Tvg_Result;

const roboto_regular = @embedFile("fonts/Roboto-Regular.ttf");
const roboto_bold = @embedFile("fonts/Roboto-Bold.ttf");
const roboto_italic = @embedFile("fonts/Roboto-Italic.ttf");

// --- Safe Zig API ---
pub fn rasterizeSVG(allocator: std.mem.Allocator, svg_text: []const u8, width: u32, height: u32) ![]u8 {
    // 1. Initialize Engine (0 threads = auto-detect CPU cores)
    if (tvg_engine_init(0) != .Success) return error.ThorVGInitFailed;
    defer _ = tvg_engine_term();

    // Load embedded fonts for SVG <text> rendering
    try loadEmbeddedFonts();

    // 2. Allocate Pixel Buffer (RGBA = 4 bytes per pixel)
    const pixels = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(pixels);

    // 3. Setup Canvas (0 = TVG_ENGINE_OPTION_NONE)
    const canvas = tvg_swcanvas_create(0) orelse return error.CanvasFailed;
    defer _ = tvg_canvas_destroy(canvas);

    _ = tvg_swcanvas_set_target(canvas, @ptrCast(@alignCast(pixels.ptr)), width, width, height, @intFromEnum(Tvg_Colorspace.ABGR8888));

    // 4. Load SVG into Picture Object
    const picture = tvg_picture_new() orelse return error.PictureFailed;

    if (tvg_picture_load_data(picture, svg_text.ptr, @intCast(svg_text.len), "svg", null, true) != .Success) {
        return error.InvalidSVG;
    }

    _ = tvg_picture_set_size(picture, @floatFromInt(width), @floatFromInt(height));

    // 5. Draw and Rasterize
    _ = tvg_canvas_add(canvas, picture);
    _ = tvg_canvas_draw(canvas, true);
    _ = tvg_canvas_sync(canvas);

    return pixels;
}

/// Load all embedded Roboto font variants into the ThorVG engine.
/// Must be called AFTER tvg_engine_init(). copy=false: data stays in binary.
pub fn loadEmbeddedFonts() !void {
    if (tvg_font_load_data("Roboto", roboto_regular.ptr, @intCast(roboto_regular.len), "ttf", false) != .Success)
        return error.FontLoadFailed;
    if (tvg_font_load_data("Roboto-Bold", roboto_bold.ptr, @intCast(roboto_bold.len), "ttf", false) != .Success)
        return error.FontLoadFailed;
    if (tvg_font_load_data("Roboto-Italic", roboto_italic.ptr, @intCast(roboto_italic.len), "ttf", false) != .Success)
        return error.FontLoadFailed;
}

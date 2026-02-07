const std = @import("std");

// MANUAL EXTERNS (stb_truetype.h)
// We use *anyopaque for stbtt_fontinfo* to keep it generic.
// The actual struct is stored in the 'info_blob' field of our Font struct.

extern fn stbtt_InitFont(
    info: *anyopaque,
    data: [*]const u8,
    offset: c_int,
) c_int;

extern fn stbtt_GetFontVMetrics(
    info: *anyopaque,
    ascent: *c_int,
    descent: *c_int,
    lineGap: *c_int,
) void;

extern fn stbtt_ScaleForPixelHeight(
    info: *anyopaque,
    pixels: f32,
) f32;

extern fn stbtt_GetCodepointHMetrics(
    info: *anyopaque,
    codepoint: c_int,
    advanceWidth: *c_int,
    leftSideBearing: *c_int,
) void;

// Decodes a character into a newly allocated bitmap (1 byte per pixel)
// Returns pointer to pixels. You must free it with free() (or stbtt_FreeBitmap).
extern fn stbtt_GetCodepointBitmap(
    info: *anyopaque,
    scale_x: f32,
    scale_y: f32,
    codepoint: c_int,
    width: *c_int,
    height: *c_int,
    xoff: *c_int,
    yoff: *c_int,
) ?[*]u8;

extern fn stbtt_FreeBitmap(
    bitmap: ?*anyopaque,
    userdata: ?*anyopaque,
) void;

pub const Font = struct {
    // Storage for the opaque C struct (stbtt_fontinfo is < 200 bytes usually)
    info_blob: [256]u8 align(8),

    data: []const u8, // Owned by us (duped)
    allocator: std.mem.Allocator,

    // Metrics
    ascent: i32,
    descent: i32,
    line_gap: i32,

    pub fn init(allocator: std.mem.Allocator, ttf_data: []const u8) !*Font {
        const self = try allocator.create(Font);
        self.allocator = allocator;

        // keep a copy of the TTF data, defaults to @embedFile(Arial.ttf) (STB needs it to stay valid)
        self.data = try allocator.dupe(u8, ttf_data);

        // We pass the pointer to our blob as the 'info' struct
        const info_ptr: *anyopaque = @ptrCast(&self.info_blob);

        if (stbtt_InitFont(info_ptr, self.data.ptr, 0) == 0) {
            allocator.free(self.data);
            allocator.destroy(self);
            return error.InvalidFont;
        }

        // Cache metrics
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        stbtt_GetFontVMetrics(info_ptr, &asc, &desc, &gap);

        self.ascent = asc;
        self.descent = desc;
        self.line_gap = gap;

        return self;
    }

    pub fn deinit(self: *Font) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    pub fn getFontScale(self: *Font, pixels: f32) f32 {
        const info_ptr: *anyopaque = @ptrCast(&self.info_blob);
        return stbtt_ScaleForPixelHeight(info_ptr, pixels);
    }

    pub fn getGlyphAdvance(self: *Font, codepoint: u8) i32 {
        const info_ptr: *anyopaque = @ptrCast(&self.info_blob);
        var adv: c_int = 0;
        var lsb: c_int = 0;
        stbtt_GetCodepointHMetrics(info_ptr, codepoint, &adv, &lsb);
        return adv;
    }

    /// Returns a 1-channel bitmap for the character.
    ///
    /// Caller must free pixels with std.c.free()
    pub fn getGlyphBitmap(self: *Font, codepoint: u8, scale_x: f32, scale_y: f32) ?struct { w: i32, h: i32, xoff: i32, yoff: i32, pixels: [*]u8 } {
        const info_ptr: *anyopaque = @ptrCast(&self.info_blob);
        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;

        // Pass scale_x and scale_y separately to STB
        const pixels = stbtt_GetCodepointBitmap(info_ptr, scale_x, scale_y, codepoint, &w, &h, &xoff, &yoff);

        if (pixels == null) return null;

        return .{ .w = w, .h = h, .xoff = xoff, .yoff = yoff, .pixels = pixels.? };
    }
};

const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const BlobObject = @import("js_blob.zig").BlobObject;
const css_color = @import("css_color.zig");
const js_utils = @import("js_utils.zig");
const js_image = @import("js_image.zig");

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

// pub fn defineAccessor(
//     ctx: zqjs.Context,
//     proto: zqjs.Value,
//     name: [:0]const u8,
//     getter: qjs.JSCFunction,
//     setter: qjs.JSCFunction,
// ) void {
//     const atom = qjs.JS_NewAtom(ctx.ptr, name);
//     defer qjs.JS_FreeAtom(ctx.ptr, atom);

//     const get_val = qjs.JS_NewCFunction(ctx.ptr, getter, name, 0);
//     const set_val = qjs.JS_NewCFunction(ctx.ptr, setter, name, 1);

//     // JS_DefinePropertyGetSet takes ownership of get_val and set_val
//     _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, atom, get_val, set_val, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
// }

// pub fn defineMethod(
//     ctx: zqjs.Context,
//     proto: zqjs.Value,
//     name: [:0]const u8,
//     func: qjs.JSCFunction,
//     len: c_int,
// ) void {
//     const atom = qjs.JS_NewAtom(ctx.ptr, name);
//     defer qjs.JS_FreeAtom(ctx.ptr, atom);

//     const func_val = qjs.JS_NewCFunction(ctx.ptr, func, name, len);

//     // JS_DefinePropertyValue takes ownership of 'func_val'
//     _ = qjs.JS_DefinePropertyValue(ctx.ptr, proto, atom, func_val, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_WRITABLE);
// }

pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA buffer
    fill_color: css_color.Color,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !*Canvas {
        const self = try allocator.create(Canvas);
        self.width = w;
        self.height = h;
        self.allocator = allocator;

        const size = @as(usize, @intCast(w * h * 4)); // RGBA
        self.pixels = try allocator.alloc(u8, size);
        // zeroed allocatoed to default transparent black
        @memset(self.pixels, 0);

        self.fill_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        return self;
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
        self.allocator.destroy(self);
    }

    pub fn fillRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32) void {
        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(self.width, x + w);
        const y1 = @min(self.height, y + h);
        const r = self.fill_color.r;
        const g = self.fill_color.g;
        const b = self.fill_color.b;
        const a = self.fill_color.a;

        if (x0 >= x1 or y0 >= y1) return;

        // PRE-CAST WIDTH TO USIZE FOR INDEXING
        const width_usize = @as(usize, @intCast(self.width));

        var row: usize = @intCast(y0);
        while (row < @as(usize, @intCast(y1))) : (row += 1) {
            var col: usize = @intCast(x0);
            while (col < @as(usize, @intCast(x1))) : (col += 1) {

                // Now (usize * usize + usize) is valid
                const idx = (row * width_usize + col) * 4;

                self.pixels[idx + 0] = r;
                self.pixels[idx + 1] = g;
                self.pixels[idx + 2] = b;
                self.pixels[idx + 3] = a;
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

    /// Encodes the pixel buffer to PNG format (Raw Bytes)
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

        // Copy to Zig memory so we can manage lifecycle properly
        const png_slice = png_ptr[0..@intCast(png_len)];
        return self.allocator.dupe(u8, png_slice);
    }

    /// Returns a Base64 Data URL string: "data:image/png;base64,..."
    pub fn toDataURL(self: *Canvas) ![]u8 {
        var png_len: c_int = 0;

        // 1. Compress to PNG (Heap allocated by STB)
        // stride_in_bytes = width * 4 (RGBA)
        const png_data_c = stbi_write_png_to_mem(
            self.pixels.ptr,
            0, // stride_in_bytes (0 = auto)
            @intCast(self.width),
            @intCast(self.height),
            4, // components (RGBA)
            &png_len,
        );

        const png_data = png_data_c orelse return error.ImageEncodingFailed;

        // Wrap the C pointer in a Zig slice
        const png_bytes = png_data[0..@intCast(png_len)];
        defer stbiw_free(png_data);

        // 2. Base64 Encode
        const encoder = std.base64.standard.Encoder;
        const b64_len = encoder.calcSize(png_bytes.len);
        const prefix = "data:image/png;base64,";

        // Allocate final string (Prefix + B64)
        const result = try self.allocator.alloc(u8, prefix.len + b64_len);

        // Copy prefix
        @memcpy(result[0..prefix.len], prefix);

        // Encode content
        _ = encoder.encode(result[prefix.len..], png_bytes);

        return result;
    }

    pub fn drawImage(self: *Canvas, img: *js_image.Image, dx: i32, dy: i32, dw: i32, dh: i32) void {
        // Quick AABB check
        if (dx >= self.width or
            dy >= self.height or
            dx + dw <= 0 or
            dy + dh <= 0) return;

        // once for all
        const dest_stride = @as(usize, @intCast(self.width));
        const src_stride = @as(usize, @intCast(img.width));

        var row: i32 = 0;
        while (row < dh) : (row += 1) {
            const dest_y = dy + row;
            // clipping
            if (dest_y < 0 or dest_y >= self.height) continue;

            // Nearest Neighbor Y: map dest_row to src_row
            const src_y = @divFloor(row * img.height, dh);

            var col: i32 = 0;
            while (col < dw) : (col += 1) {
                const dest_x = dx + col;
                // clipping
                if (dest_x < 0 or dest_x >= self.width) continue;

                // Nearest Neighbor X
                const src_x = @divFloor(col * img.width, dw);

                // everything to usize
                const d_y = @as(usize, @intCast(dest_y));
                const d_x = @as(usize, @intCast(dest_x));

                const s_y = @as(usize, @intCast(src_y));
                const s_x = @as(usize, @intCast(src_x));
                const dest_idx = (d_y * dest_stride + d_x) * 4;
                const src_idx = (s_y * src_stride + s_x) * 4;

                // 3. Copy Pixel
                self.pixels[dest_idx + 0] = img.pixels[src_idx + 0];
                self.pixels[dest_idx + 1] = img.pixels[src_idx + 1];
                self.pixels[dest_idx + 2] = img.pixels[src_idx + 2];
                self.pixels[dest_idx + 3] = img.pixels[src_idx + 3];
            }
        }
    }
};

// === Properties
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

/// Cunnretly only to PNG
fn js_canvas_toDataURL(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");

    const png_data = canvas.getPngData() catch return ctx.throwInternalError("PNG Encoding failed");
    defer canvas.allocator.free(png_data); // getPngData returns owned slice

    // Base64 Encode
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(png_data.len);
    const prefix = "data:image/png;base64,";

    // Create string buffer
    // JS_NewStringLen expects a buffer we don't own, it copies.
    // So we alloc in Zig, encode, create JS string, then free Zig buffer.
    const rc = RuntimeContext.get(ctx);
    const total_len = prefix.len + b64_len;
    const temp_buf = rc.allocator.alloc(u8, total_len) catch return zqjs.EXCEPTION;
    defer rc.allocator.free(temp_buf);

    @memcpy(temp_buf[0..prefix.len], prefix);
    _ = encoder.encode(temp_buf[prefix.len..], png_data);

    return qjs.JS_NewStringLen(ctx.ptr, temp_buf.ptr, temp_buf.len);
}

// canvas.toBlob(callback, type, quality) -> Promise
/// Cunnretly only to PNG
fn js_canvas_toBlob(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const canvas = unwrapCanvas(ctx, this_val) orelse return ctx.throwTypeError("Not a Canvas");

    // 1. Generate Binary Data
    const png_data = canvas.getPngData() catch return zqjs.NULL;
    defer canvas.allocator.free(png_data);

    //    For now, let's assume we can create the native blob:
    const blob_obj = BlobObject.init(rc.allocator, png_data, "image/png") catch return zqjs.NULL;

    // 3. Wrap in JS Value
    const blob_val = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.blob);
    if (qjs.JS_IsException(blob_val)) {
        blob_obj.deinit();
        return zqjs.EXCEPTION;
    }
    _ = qjs.JS_SetOpaque(blob_val, blob_obj);

    // 4. Return as resolved Promise using JS_Call on Promise.resolve
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const promise_ctor = ctx.getPropertyStr(global, "Promise");
    defer ctx.freeValue(promise_ctor);

    const resolve_fn = ctx.getPropertyStr(promise_ctor, "resolve");
    defer ctx.freeValue(resolve_fn);

    var args = [_]qjs.JSValue{blob_val};
    const result = qjs.JS_Call(ctx.ptr, resolve_fn, promise_ctor, 1, &args);

    // Free our reference to blob_val - Promise.resolve() has taken its own reference
    ctx.freeValue(blob_val);

    return result;
}

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
    js_utils.defineMethod(ctx, proto, "toDataURL", js_canvas_toDataURL, 0);
    js_utils.defineMethod(ctx, proto, "toBlob", js_canvas_toBlob, 0);
    js_utils.defineMethod(ctx, proto, "fillRect", js_canvas_fillRect, 4);
    js_utils.defineMethod(ctx, proto, "drawImage", js_canvas_drawImage, 5);

    // Add accessors
    js_utils.defineAccessor(ctx, proto, "width", js_canvas_get_width, js_canvas_set_width);
    js_utils.defineAccessor(ctx, proto, "height", js_canvas_get_height, js_canvas_set_height);
    js_utils.defineAccessor(ctx, proto, "fillStyle", js_canvas_get_fillStyle, js_canvas_set_fillStyle);

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

    // Duplicate before setting, since setPropertyStr consumes the value
    const ctor_for_alias = ctx.dupValue(ctor_val);
    try ctx.setPropertyStr(global, "Canvas", ctor_val);
    try ctx.setPropertyStr(global, "HTMLCanvasElement", ctor_for_alias);
}

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

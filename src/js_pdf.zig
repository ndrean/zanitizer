const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = z.RuntimeContext;
const js_utils = z.js_utils;
const js_image = z.js_image;
const css_color = @import("css_color.zig");

const hpdf = @cImport({
    @cInclude("hpdf.h");
});

extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

fn stbiw_free(ptr: ?*anyopaque) void {
    if (ptr) |p| std.c.free(p);
}

// Safe Error Handling
export fn pdfErrorHandler(error_no: hpdf.HPDF_STATUS, detail_no: hpdf.HPDF_STATUS, user_data: ?*anyopaque) void {
    _ = user_data;
    std.debug.print("[LibHaru Error] Code: {x}, Detail: {d}\n", .{ error_no, detail_no });
}

pub const PDFDocument = struct {
    doc: hpdf.HPDF_Doc,
    current_page: hpdf.HPDF_Page = null,
    page_height: f32 = 0,
    font: hpdf.HPDF_Font = null,         // Roboto-Regular
    font_bold: hpdf.HPDF_Font = null,    // Roboto-Bold
    font_italic: hpdf.HPDF_Font = null,  // Roboto-Italic
    current_font: hpdf.HPDF_Font = null, // currently selected variant
    allocator: std.mem.Allocator,
    current_font_size: f32 = 12.0,

    pub fn init(allocator: std.mem.Allocator) !*PDFDocument {
        const doc = hpdf.HPDF_New(&pdfErrorHandler, null);
        if (doc == null) return error.PdfInitFailed;

        // Enable UTF-8 for standard web text compatibility
        _ = hpdf.HPDF_UseUTFEncodings(doc);
        _ = hpdf.HPDF_SetCurrentEncoder(doc, "UTF-8");

        const loadFont = struct {
            fn f(d: hpdf.HPDF_Doc, bytes: []const u8) ?hpdf.HPDF_Font {
                const name = hpdf.HPDF_LoadTTFontFromMemory(d, bytes.ptr, @intCast(bytes.len), hpdf.HPDF_TRUE);
                if (name == null) return null;
                return hpdf.HPDF_GetFont(d, name, "UTF-8");
            }
        }.f;

        const font_regular = loadFont(doc, @embedFile("fonts/Roboto-Regular.ttf")) orelse return error.FontLoadFailed;
        const font_bold    = loadFont(doc, @embedFile("fonts/Roboto-Bold.ttf"))    orelse return error.FontLoadFailed;
        const font_italic  = loadFont(doc, @embedFile("fonts/Roboto-Italic.ttf"))  orelse return error.FontLoadFailed;

        const self = try allocator.create(PDFDocument);
        self.* = .{
            .doc = doc,
            .allocator = allocator,
            .font = font_regular,
            .font_bold = font_bold,
            .font_italic = font_italic,
            .current_font = font_regular,
        };
        return self;
    }

    pub fn deinit(self: *PDFDocument) void {
        if (self.doc != null) {
            hpdf.HPDF_Free(self.doc);
        }
        self.allocator.destroy(self);
    }
};

pub fn install(ctx: zqjs.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    if (rc.classes.pdf_document == 0) {
        rc.classes.pdf_document = rt.newClassID();
        try rt.newClass(rc.classes.pdf_document, .{
            .class_name = "PDFDocument",
            .finalizer = pdf_document_finalizer,
            // .gc_mark = pdf_document_gc_mark,
        });

        const proto = ctx.newObject();

        // Add Getters

        js_utils.defineMethod(ctx, proto, "fillText", js_pdf_fillText, 3);
        js_utils.defineMethod(ctx, proto, "save", js_pdf_save, 1);
        js_utils.defineMethod(ctx, proto, "addPage", js_pdf_addPage, 0);
        js_utils.defineMethod(ctx, proto, "moveTo", js_pdf_moveTo, 2);
        js_utils.defineMethod(ctx, proto, "lineTo", js_pdf_lineTo, 2);
        js_utils.defineMethod(ctx, proto, "setDrawColor", js_pdf_setDrawColor, 3);
        js_utils.defineMethod(ctx, proto, "stroke", js_pdf_stroke, 0);
        js_utils.defineMethod(ctx, proto, "strokeRect", js_pdf_strokeRect, 4);
        js_utils.defineMethod(ctx, proto, "drawImage", js_pdf_drawImage, 5);
        js_utils.defineMethod(ctx, proto, "toArrayBuffer", js_pdf_toArrayBuffer, 0);
        js_utils.defineMethod(ctx, proto, "drawImageFromBuffer", js_drawImageFromBuffer, 5);
        js_utils.defineMethod(ctx, proto, "loadFont", js_pdf_loadFont, 2);
        js_utils.defineMethod(ctx, proto, "setFont", js_pdf_setFont, 2);
        js_utils.defineMethod(ctx, proto, "measureText", js_pdf_measureText, 1);
        js_utils.defineMethod(ctx, proto, "fillRect", js_pdf_fillRect, 4);
        js_utils.defineMethod(ctx, proto, "setLineWidth", js_pdf_setLineWidth, 1);
        js_utils.defineAccessor(ctx, proto, "fillStyle", js_pdf_get_fillStyle, js_pdf_set_fillStyle);
        js_utils.defineAccessor(ctx, proto, "strokeStyle", js_pdf_get_strokeStyle, js_pdf_set_strokeStyle);
        js_utils.defineMethod(ctx, proto, "saveGraphicsState", js_pdf_saveGraphicsState, 0);
        js_utils.defineMethod(ctx, proto, "restoreGraphicsState", js_pdf_restoreGraphicsState, 0);
        js_utils.defineMethod(ctx, proto, "arc", js_pdf_arc, 5);
        js_utils.defineMethod(ctx, proto, "clip", js_pdf_clip, 0);

        ctx.setClassProto(rc.classes.pdf_document, proto);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const ctor = qjs.JS_NewCFunction2(ctx.ptr, js_pdf_document_constructor, "PDFDocument", 2, qjs.JS_CFUNC_constructor, 0);
        try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
        try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor));
        try ctx.setPropertyStr(global, "PDFDocument", ctor);
    }
}

// === JavaScript Bindings

fn js_pdf_document_constructor(ctx_ptr: ?*qjs.JSContext, new_target: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = argc;
    _ = argv; // no arguments for `new PDFDocument()`

    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    // Enforce the 'new' keyword
    // If new_target is undefined, the user called `PDFDocument()` instead of `new PDFDocument()`.
    if (qjs.JS_IsUndefined(new_target)) {
        return qjs.JS_ThrowTypeError(ctx.ptr, "Class constructor PDFDocument cannot be invoked without 'new'");
    }

    // Allocate the Zig State
    const self = PDFDocument.init(rc.allocator) catch {
        return qjs.JS_ThrowInternalError(ctx.ptr, "Failed to initialize LibHaru PDF Engine");
    };

    // Create the JS Object with the correct Prototype Chain
    // We extract the prototype from new_target so `obj instanceof PDFDocument` works correctly in JS.
    // const proto = qjs.JS_GetPropertyStr(ctx.ptr, new_target, "prototype");
    const proto = ctx.getPropertyStr(new_target, "prototype");
    defer ctx.freeValue(proto);

    // Create the empty JS object attached to your custom Class ID
    const obj = qjs.JS_NewObjectProtoClass(ctx.ptr, proto, rc.classes.pdf_document);

    if (qjs.JS_IsException(obj)) {
        // MEMORY LEAK GUARD: If JS object creation fails, we must free the LibHaru pointer!
        self.deinit();
        return obj;
    }

    //  Glue the Zig Pointer to the JS Object: hides *PDFDocument pointer inside the JS object's hidden "opaque" field.
    _ = qjs.JS_SetOpaque(obj, self);

    return obj;
}

fn pdf_document_finalizer(_: ?*qjs.JSRuntime, val: zqjs.Value) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque2(null, val, obj_class_id);
    if (ptr) |p| {
        const self: *PDFDocument = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

fn js_pdf_addPage(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = argc;
    _ = argv;
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    // Create page and set default size (A4)
    self.current_page = hpdf.HPDF_AddPage(self.doc);
    _ = hpdf.HPDF_Page_SetSize(self.current_page, hpdf.HPDF_PAGE_SIZE_A4, hpdf.HPDF_PAGE_PORTRAIT);

    // Cache the height so we can invert the Y-Axis!
    self.page_height = hpdf.HPDF_Page_GetHeight(self.current_page);

    // Set default font size so text works immediately
    _ = hpdf.HPDF_Page_SetFontAndSize(self.current_page, self.current_font, self.current_font_size);

    return zqjs.UNDEFINED;
}

// --- CANVAS API MOCKS ---

fn js_pdf_fillText(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 3) return zqjs.UNDEFINED;

    const text = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(text);

    var x: f64 = 0;
    var y: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[2]);

    // LibHaru requires BeginText/EndText blocks
    _ = hpdf.HPDF_Page_BeginText(self.current_page);

    // INVERT Y-AXIS HERE!
    const inverted_y = self.page_height - @as(f32, @floatCast(y));
    _ = hpdf.HPDF_Page_TextOut(self.current_page, @floatCast(x), inverted_y, text.ptr);

    _ = hpdf.HPDF_Page_EndText(self.current_page);

    return zqjs.UNDEFINED;
}

fn js_pdf_save(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (argc < 1) return zqjs.UNDEFINED;

    const path = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(path);

    _ = hpdf.HPDF_SaveToFile(self.doc, path.ptr);

    return zqjs.UNDEFINED;
}

// in Canvas, (0,0) is TopLeft but BottomLeft in PDF => invert Y-Axis
fn js_pdf_moveTo(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 2) return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);

    const inverted_y = self.page_height - @as(f32, @floatCast(y));
    _ = hpdf.HPDF_Page_MoveTo(self.current_page, @floatCast(x), inverted_y);

    return zqjs.UNDEFINED;
}

// in Canvas, (0,0) is TopLeft but BottomLeft in PDF => invert Y-Axis
fn js_pdf_lineTo(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 2) return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);

    const inverted_y = self.page_height - @as(f32, @floatCast(y));
    _ = hpdf.HPDF_Page_LineTo(self.current_page, @floatCast(x), inverted_y);

    return zqjs.UNDEFINED;
}

fn js_pdf_setDrawColor(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 1) return zqjs.UNDEFINED;

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    if (argc >= 3) {
        // Handle setDrawColor(255, 0, 0)
        var r_f64: f64 = 0;
        var g_f64: f64 = 0;
        var b_f64: f64 = 0;

        _ = qjs.JS_ToFloat64(ctx.ptr, &r_f64, argv[0]);
        _ = qjs.JS_ToFloat64(ctx.ptr, &g_f64, argv[1]);
        _ = qjs.JS_ToFloat64(ctx.ptr, &b_f64, argv[2]);

        // LibHaru expects 0.0 to 1.0 floats
        r = @floatCast(r_f64 / 255.0);
        g = @floatCast(g_f64 / 255.0);
        b = @floatCast(b_f64 / 255.0);
    } else {
        // Handle setDrawColor("#FF0000")
        const style_str = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
        defer ctx.freeZString(style_str);

        const rgb = parseHexToRGB(style_str);
        r = rgb.r;
        g = rgb.g;
        b = rgb.b;
    }

    _ = hpdf.HPDF_Page_SetRGBStroke(self.current_page, r, g, b);

    return zqjs.UNDEFINED;
}

// in Canvas, (0,0) is TopLeft but BottomLeft in PDF => invert Y-Axis
fn js_pdf_stroke(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page != null) {
        _ = hpdf.HPDF_Page_Stroke(self.current_page);
    }

    return zqjs.UNDEFINED;
}

// ❗️fake loader. Defaults to Roboto-Regular.ttf
fn js_pdf_loadFont(_: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    // We just smile, nod, and do absolutely nothing.
    return zqjs.UNDEFINED;
}

// pdf.setFont("Roboto-Bold", 24) or pdf.setFont(24)
fn js_pdf_setFont(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (argc < 1) return zqjs.UNDEFINED;

    var size: f64 = 12.0;

    if (argc == 1) {
        // pdf.setFont(24)
        _ = qjs.JS_ToFloat64(ctx.ptr, &size, argv[0]);
    } else {
        // pdf.setFont("Roboto-Bold", 24) — select variant from name
        _ = qjs.JS_ToFloat64(ctx.ptr, &size, argv[1]);
        const name = ctx.toZString(argv[0]) catch null;
        if (name) |n| {
            defer ctx.freeZString(n);
            if (std.mem.indexOf(u8, n, "Bold") != null) {
                self.current_font = self.font_bold;
            } else if (std.mem.indexOf(u8, n, "Italic") != null) {
                self.current_font = self.font_italic;
            } else {
                self.current_font = self.font;
            }
        }
    }

    if (size > 0) self.current_font_size = @floatCast(size);

    if (self.current_page != null) {
        _ = hpdf.HPDF_Page_SetFontAndSize(self.current_page, self.current_font, self.current_font_size);
    }

    return zqjs.UNDEFINED;
}

fn js_pdf_strokeRect(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 4) return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;

    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &w, argv[2]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &h, argv[3]);

    // Canvas Y-axis inversion: PDF origin is bottom-left
    const pdf_y = self.page_height - @as(f32, @floatCast(y)) - @as(f32, @floatCast(h));

    _ = hpdf.HPDF_Page_Rectangle(self.current_page, @floatCast(x), pdf_y, @floatCast(w), @floatCast(h));
    _ = hpdf.HPDF_Page_Stroke(self.current_page);

    return zqjs.UNDEFINED;
}

// --- GRAPHICS STATE ---

fn js_pdf_saveGraphicsState(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page != null) {
        // Pushes the current clipping and styling state to the stack
        _ = hpdf.HPDF_Page_GSave(self.current_page);
    }
    return zqjs.UNDEFINED;
}

fn js_pdf_restoreGraphicsState(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page != null) {
        // Pops the state, returning the PDF to normal drawing mode
        _ = hpdf.HPDF_Page_GRestore(self.current_page);
    }
    return zqjs.UNDEFINED;
}

// --- SHAPES & CLIPPING ---
fn js_pdf_arc(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 5) return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    var radius: f64 = 0;
    var start_angle: f64 = 0;
    var end_angle: f64 = 0;

    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &radius, argv[2]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &start_angle, argv[3]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &end_angle, argv[4]);

    const inverted_y = self.page_height - @as(f32, @floatCast(y));

    const deg_start = @as(f32, @floatCast(start_angle * 180.0 / std.math.pi));
    const deg_end = @as(f32, @floatCast(end_angle * 180.0 / std.math.pi));

    // THE FIX: Intercept 360-degree sweeps and use Circle instead of Arc
    const diff = @abs(deg_end - deg_start);
    if (diff >= 359.9) {
        _ = hpdf.HPDF_Page_Circle(self.current_page, @floatCast(x), inverted_y, @floatCast(radius));
    } else {
        _ = hpdf.HPDF_Page_Arc(self.current_page, @floatCast(x), inverted_y, @floatCast(radius), deg_start, deg_end);
    }

    return zqjs.UNDEFINED;
}
// fn js_pdf_arc(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
//     const ctx = zqjs.Context.from(ctx_ptr);
//     const rc = RuntimeContext.get(ctx);
//     const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

//     if (self.current_page == null or argc < 5) return zqjs.UNDEFINED;

//     var x: f64 = 0;
//     var y: f64 = 0;
//     var radius: f64 = 0;
//     var start_angle: f64 = 0;
//     var end_angle: f64 = 0;

//     _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
//     _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);
//     _ = qjs.JS_ToFloat64(ctx.ptr, &radius, argv[2]);
//     _ = qjs.JS_ToFloat64(ctx.ptr, &start_angle, argv[3]);
//     _ = qjs.JS_ToFloat64(ctx.ptr, &end_angle, argv[4]);

//     const inverted_y = self.page_height - @as(f32, @floatCast(y));

//     // Canvas uses Radians. LibHaru uses Degrees! We must convert them here.
//     const deg_start = @as(f32, @floatCast(start_angle * 180.0 / std.math.pi));
//     const deg_end = @as(f32, @floatCast(end_angle * 180.0 / std.math.pi));

//     // Append the arc to the current path
//     _ = hpdf.HPDF_Page_Arc(self.current_page, @floatCast(x), inverted_y, @floatCast(radius), deg_start, deg_end);

//     return zqjs.UNDEFINED;
// }

fn js_pdf_clip(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page != null) {
        // Set the clipping region
        _ = hpdf.HPDF_Page_Clip(self.current_page);
        // LibHaru requires you to consume/end the path after clipping!
        _ = hpdf.HPDF_Page_EndPath(self.current_page);
    }

    return zqjs.UNDEFINED;
}

fn js_pdf_drawImage(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 5) return zqjs.UNDEFINED;

    // 1. Unwrap the ImageBitmap to get the raw RGBA pixels
    const img = js_image.unwrapImage(ctx, argv[0]) orelse return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[2]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &w, argv[3]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &h, argv[4]);

    // 2. Split RGBA → RGB + Alpha
    const pixel_count: usize = @intCast(img.width * img.height);
    const rgb_buf = self.allocator.alloc(u8, pixel_count * 3) catch return zqjs.UNDEFINED;
    defer self.allocator.free(rgb_buf);

    // Extract RGB and detect if alpha is trivial (all 255 = opaque, e.g. JPEG sources)
    var has_alpha = false;
    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        rgb_buf[i * 3 + 0] = img.pixels[i * 4 + 0];
        rgb_buf[i * 3 + 1] = img.pixels[i * 4 + 1];
        rgb_buf[i * 3 + 2] = img.pixels[i * 4 + 2];
        if (img.pixels[i * 4 + 3] != 255) has_alpha = true;
    }

    // 3. Load the RGB data into LibHaru
    const hpdf_img = hpdf.HPDF_LoadRawImageFromMem(self.doc, rgb_buf.ptr, @intCast(img.width), @intCast(img.height), hpdf.HPDF_CS_DEVICE_RGB, 8);

    // 4. Only create SMask if image has actual transparency (PNG, WebP, SVG with alpha)
    //    JPEG sources have all-255 alpha — skip the mask to reduce PDF size
    if (has_alpha) {
        const alpha_buf = self.allocator.alloc(u8, pixel_count) catch return zqjs.UNDEFINED;
        defer self.allocator.free(alpha_buf);

        i = 0;
        while (i < pixel_count) : (i += 1) {
            alpha_buf[i] = img.pixels[i * 4 + 3];
        }

        const hpdf_mask = hpdf.HPDF_LoadRawImageFromMem(self.doc, alpha_buf.ptr, @intCast(img.width), @intCast(img.height), hpdf.HPDF_CS_DEVICE_GRAY, 8);
        _ = hpdf.HPDF_Image_AddSMask(hpdf_img, hpdf_mask);
    }

    // 5. Draw with Canvas Y-Axis inversion (PDF origin is bottom-left)
    const pdf_y = self.page_height - @as(f32, @floatCast(y)) - @as(f32, @floatCast(h));
    _ = hpdf.HPDF_Page_DrawImage(self.current_page, hpdf_img, @floatCast(x), pdf_y, @floatCast(w), @floatCast(h));

    return zqjs.UNDEFINED;
}

// --- drawImageFromBuffer(arrayBuffer, x, y, w, h) ---
fn js_drawImageFromBuffer(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 5) return zqjs.UNDEFINED;

    // 1. Extract the raw ArrayBuffer from JS
    var buf_len: usize = 0;
    const buf_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &buf_len, argv[0]);
    if (buf_ptr == null) return zqjs.UNDEFINED;

    // 2. Extract Coordinates
    var x: f64 = 0;
    var y: f64 = 0;
    var w_val: f64 = 0;
    var h_val: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[2]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &w_val, argv[3]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &h_val, argv[4]);

    // 3. Decode the PNG/JPEG from memory using stb_image
    var img_w: c_int = 0;
    var img_h: c_int = 0;
    var channels: c_int = 0;

    // Force 3 channels (RGB) because PDFs usually don't need alpha for map tiles
    const pixels = stbi_load_from_memory(buf_ptr, @intCast(buf_len), &img_w, &img_h, &channels, 3);
    if (pixels == null) return zqjs.UNDEFINED; // Silently skip broken tiles
    defer stbiw_free(pixels);

    // 4. Load raw pixels into LibHaru (Bypassing the disabled LibPNG!)
    const pdf_img = hpdf.HPDF_LoadRawImageFromMem(self.doc, pixels, @intCast(img_w), @intCast(img_h), hpdf.HPDF_CS_DEVICE_RGB, 8);

    // 5. Y-axis inversion and draw
    const pdf_y = self.page_height - @as(f32, @floatCast(y)) - @as(f32, @floatCast(h_val));
    _ = hpdf.HPDF_Page_DrawImage(self.current_page, pdf_img, @floatCast(x), pdf_y, @floatCast(w_val), @floatCast(h_val));

    return zqjs.UNDEFINED;
}

fn js_pdf_toArrayBuffer(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    // 1. Tell LibHaru to compile the PDF into its internal memory stream
    if (hpdf.HPDF_SaveToStream(self.doc) != hpdf.HPDF_OK) {
        return qjs.JS_ThrowInternalError(ctx.ptr, "Failed to save PDF to memory stream");
    }

    // 2. Rewind the stream to the beginning before reading.
    //    HPDF_SaveToStream leaves the stream position at the END; without this
    //    HPDF_ReadFromStream reads 0 bytes and produces an empty (invalid) PDF.
    _ = hpdf.HPDF_ResetStream(self.doc);

    // 3. Find out exactly how big the compiled PDF is
    var size = hpdf.HPDF_GetStreamSize(self.doc);
    if (size == 0) return zqjs.UNDEFINED;

    // 4. Allocate a temporary Zig buffer to hold the bytes
    const buf = self.allocator.alloc(u8, size) catch {
        return qjs.JS_ThrowOutOfMemory(ctx.ptr);
    };
    defer self.allocator.free(buf);

    // 5. Read the bytes out of LibHaru
    _ = hpdf.HPDF_ReadFromStream(self.doc, buf.ptr, &size);

    // 5. Hand the bytes to QuickJS as an ArrayBuffer (QuickJS makes its own copy)
    return qjs.JS_NewArrayBufferCopy(ctx.ptr, buf.ptr, size);
}

// --- measureText(text) → { width } ---

fn js_pdf_measureText(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 1) return zqjs.UNDEFINED;

    const text = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(text);

    const width = hpdf.HPDF_Page_TextWidth(self.current_page, text.ptr);

    const result = ctx.newObject();
    ctx.setPropertyStr(result, "width", ctx.newFloat64(@floatCast(width))) catch {};
    return result;
}

// --- fillStyle / strokeStyle property accessors ---

fn parseHexToRGB(str: []const u8) struct { r: f32, g: f32, b: f32 } {
    const color = css_color.parse(str);
    return .{
        .r = @as(f32, @floatFromInt(color.r)) / 255.0,
        .g = @as(f32, @floatFromInt(color.g)) / 255.0,
        .b = @as(f32, @floatFromInt(color.b)) / 255.0,
    };
}

fn js_pdf_get_fillStyle(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const val = ctx.getPropertyStr(this_val, "__fillStyle");
    if (ctx.isUndefined(val)) {
        ctx.freeValue(val);
        return ctx.newString("#000000");
    }
    return val;
}

fn js_pdf_set_fillStyle(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (argc < 1) return zqjs.UNDEFINED;

    const style_str = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(style_str);

    const rgb = parseHexToRGB(style_str);
    if (self.current_page != null) {
        _ = hpdf.HPDF_Page_SetRGBFill(self.current_page, rgb.r, rgb.g, rgb.b);
    }

    // Cache the string for getter round-trip
    ctx.setPropertyStr(this_val, "__fillStyle", ctx.dupValue(argv[0])) catch {};
    return zqjs.UNDEFINED;
}

fn js_pdf_get_strokeStyle(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const val = ctx.getPropertyStr(this_val, "__strokeStyle");
    if (ctx.isUndefined(val)) {
        ctx.freeValue(val);
        return ctx.newString("#000000");
    }
    return val;
}

fn js_pdf_set_strokeStyle(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (argc < 1) return zqjs.UNDEFINED;

    const style_str = ctx.toZString(argv[0]) catch return zqjs.UNDEFINED;
    defer ctx.freeZString(style_str);

    const rgb = parseHexToRGB(style_str);
    if (self.current_page != null) {
        _ = hpdf.HPDF_Page_SetRGBStroke(self.current_page, rgb.r, rgb.g, rgb.b);
    }

    ctx.setPropertyStr(this_val, "__strokeStyle", ctx.dupValue(argv[0])) catch {};
    return zqjs.UNDEFINED;
}

// --- fillRect(x, y, w, h) ---

fn js_pdf_fillRect(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 4) return zqjs.UNDEFINED;

    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &x, argv[0]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &y, argv[1]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &w, argv[2]);
    _ = qjs.JS_ToFloat64(ctx.ptr, &h, argv[3]);

    // Canvas Y-axis inversion: PDF origin is bottom-left
    const pdf_y = self.page_height - @as(f32, @floatCast(y)) - @as(f32, @floatCast(h));
    _ = hpdf.HPDF_Page_Rectangle(self.current_page, @floatCast(x), pdf_y, @floatCast(w), @floatCast(h));
    _ = hpdf.HPDF_Page_Fill(self.current_page);

    return zqjs.UNDEFINED;
}

// --- setLineWidth(w) ---

fn js_pdf_setLineWidth(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(PDFDocument, this_val, rc.classes.pdf_document) orelse return zqjs.UNDEFINED;

    if (self.current_page == null or argc < 1) return zqjs.UNDEFINED;

    var w: f64 = 1.0;
    _ = qjs.JS_ToFloat64(ctx.ptr, &w, argv[0]);
    _ = hpdf.HPDF_Page_SetLineWidth(self.current_page, @floatCast(w));

    return zqjs.UNDEFINED;
}

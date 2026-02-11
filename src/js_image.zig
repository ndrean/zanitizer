const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const EventLoop = @import("event_loop.zig").EventLoop;
const js_blob = @import("js_blob.zig"); // To unwrap input blobs
const js_utils = @import("js_utils.zig");
const js_canvas = @import("js_canvas.zig");
const js_security = @import("js_security.zig");
const curl = @import("curl");

// stb_image_load C bindings - manual declaration

extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;

/// Raw Pixel Data (ImageBitmap)
pub const Image = struct {
    width: i32,
    height: i32,
    channels: i32,
    pixels: [*]u8, // Owned by STB (malloc), must free with stbi_image_free
    allocator: std.mem.Allocator,

    /// Decodes an image from memory (PNG, JPEG, GIF, etc.)
    /// We force 4 channels (RGBA) to match Canvas format.
    pub fn initFromMemory(allocator: std.mem.Allocator, buffer: []const u8) !*Image {
        // Structural validation gate — reject malformed images before C decoder
        if (buffer.len >= 2) {
            if (std.mem.startsWith(u8, buffer, "\x89PNG")) {
                std.debug.print("CHECK\n", .{});
                try js_canvas.verifyPngStructure(buffer);
            } else if (buffer[0] == 0xFF and buffer[1] == 0xD8) {
                try js_canvas.verifyJpegStructure(buffer);
            }
            // Other formats (GIF, BMP, etc.) pass through to stb_image
        }

        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;

        // Force 4 components (Red, Green, Blue, Alpha)
        const pixels = stbi_load_from_memory(buffer.ptr, @intCast(buffer.len), &w, &h, &ch, 4);

        if (pixels == null) return error.DecodeFailed;

        if (w > 8192 or h > 8192) {
            stbi_image_free(pixels);
            return error.ImageTooLarge; // <--- The check you asked for
        }

        const self = try allocator.create(Image); // heap
        self.* = Image{
            .width = w,
            .height = h,
            .channels = 4,
            .pixels = pixels.?,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *Image) void {
        stbi_image_free(self.pixels);
        self.allocator.destroy(self);
    }
};

/// The DOM Wrapper (HTMLImageElement)
/// Represents 'new Image()'
pub const HTMLImageElement = struct {
    allocator: std.mem.Allocator,
    bitmap: ?*Image, // The actual pixel data (null until loaded)
    src: ?[:0]const u8, // The URL string
    natural_width: u32,
    natural_height: u32,
    complete: bool,

    // Callbacks stored as persistent JS Values
    onload: qjs.JSValue,
    onerror: qjs.JSValue,

    pub fn init(allocator: std.mem.Allocator) !*HTMLImageElement {
        const self = try allocator.create(HTMLImageElement);
        self.* = .{
            .allocator = allocator,
            .bitmap = null,
            .src = null,
            .natural_width = 0,
            .natural_height = 0,
            .complete = false,
            .onload = zqjs.UNDEFINED,
            .onerror = zqjs.UNDEFINED,
        };
        return self;
    }

    pub fn deinit(self: *HTMLImageElement, ctx: *qjs.JSContext) void {
        if (self.bitmap) |b| b.deinit();
        if (self.src) |s| self.allocator.free(s);
        qjs.JS_FreeValue(ctx, self.onload);
        qjs.JS_FreeValue(ctx, self.onerror);
        self.allocator.destroy(self);
    }
};

/// Helper: unwraps a JS Value into a Native *Image or *HTMLImageElement
pub fn unwrapImage(ctx: zqjs.Context, val: qjs.JSValue) ?*Image {
    const rc = RuntimeContext.get(ctx);

    // 1. Try ImageBitmap
    if (qjs.JS_GetOpaque(val, rc.classes.image)) |ptr| {
        return @ptrCast(@alignCast(ptr));
    }

    // 2. Try HTMLImageElement
    // (We need to register a separate class ID for this, see install())
    if (qjs.JS_GetOpaque(val, rc.classes.html_image)) |ptr| {
        const el: *HTMLImageElement = @ptrCast(@alignCast(ptr));
        return el.bitmap;
    }

    return null;
}

// === ImageBitmap ----------------------------
/// Helper to create a TypeError object (value) for Promise rejection.
/// We cannot use ctx.throwTypeError() because that throws synchronously
fn makeTypeError(ctx: zqjs.Context, msg: [:0]const u8) zqjs.Value {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    const ctor = ctx.getPropertyStr(global, "TypeError");
    defer ctx.freeValue(ctor);

    const msg_val = ctx.newString(msg);
    defer ctx.freeValue(msg_val);

    var args = [_]qjs.JSValue{msg_val};
    return qjs.JS_CallConstructor(ctx.ptr, ctor, 1, @ptrCast(&args));
}

// ImageBitmap Class properties

/// bitmap.width
fn js_get_width(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const img = unwrapImage(ctx, this_val) orelse return zqjs.UNDEFINED;
    return qjs.JS_NewInt32(ctx.ptr, img.width);
}

/// bitmap.height
fn js_get_height(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const img = unwrapImage(ctx, this_val) orelse return zqjs.UNDEFINED;
    return qjs.JS_NewInt32(ctx.ptr, img.height);
}

/// Global "constructor" function: createImageBitmap(blob)
pub fn js_createImageBitmap(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const args = argv[0..@intCast(argc)];

    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return zqjs.EXCEPTION;

    const resolve = resolvers[0];
    const reject = resolvers[1];

    defer {
        ctx.freeValue(resolve);
        ctx.freeValue(reject);
    }

    if (args.len < 1) {
        const err = makeTypeError(ctx, "Argument 1 must be a Blob");
        _ = ctx.call(reject, zqjs.UNDEFINED, &.{err});
        ctx.freeValue(err);
        return promise;
    }

    const blob_ptr = qjs.JS_GetOpaque(args[0], rc.classes.blob);
    if (blob_ptr == null) {
        const err = makeTypeError(ctx, "Argument 1 must be a Blob");
        _ = ctx.call(reject, zqjs.UNDEFINED, &.{err});
        ctx.freeValue(err);
        return promise;
    }
    const blob_obj: *js_blob.BlobObject = @ptrCast(@alignCast(blob_ptr));

    // Decode Image - blocking -
    // The Image{} is allocated with engine.allcoator so tracks his own pixels (stb)
    const img_ptr = Image.initFromMemory(rc.allocator, blob_obj.data) catch {
        const err = ctx.throwTypeError("Failed to decode image data");
        _ = ctx.call(reject, zqjs.UNDEFINED, &.{err});
        ctx.freeValue(err);
        return promise;
    };

    const obj = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.image);
    if (qjs.JS_IsException(obj)) {
        img_ptr.deinit();
        _ = ctx.call(reject, zqjs.UNDEFINED, &.{obj}); // Pass the exception
        return promise;
    }

    _ = qjs.JS_SetOpaque(obj, img_ptr);

    // resolve
    _ = ctx.call(resolve, zqjs.UNDEFINED, &.{obj});
    ctx.freeValue(obj); // Resolve takes a reference, we free ours

    return promise;
}

// ImageBitmpa Lifecycle
/// Image Bitmap Finalizer
pub fn finalizer(_: ?*qjs.JSRuntime, val: zqjs.Value) callconv(.c) void {
    const class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque2(null, val, class_id);
    if (ptr) |p| {
        const self: *Image = @ptrCast(@alignCast(p));
        // Free the STB pixels and the Image struct itself
        self.deinit();
    }
}

// HTTP Image Fetch (async via worker thread)

const ImageFetchWorkerArgs = struct {
    loop: *EventLoop,
    ctx: zqjs.Context,
    this_val: zqjs.Value, // HTMLImageElement JS handle (duped)
    url: []u8,
    allocator: std.mem.Allocator,
    sandbox: *js_security.Sandbox,
};

const ImageFetchResult = struct {
    body: []const u8,
    ok: bool,
};

const ImageFetchCallbackCtx = struct {
    this_val: zqjs.Value,
    body: []const u8,
    ok: bool,
};

fn imageFetchWorker(args: ImageFetchWorkerArgs) void {
    const allocator = args.allocator;
    const loop = args.loop;

    var body: []const u8 = &.{};
    var ok = false;

    // Perform HTTP GET via curl
    if (std.mem.startsWith(u8, args.url, "http")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const ca_bundle = curl.allocCABundle(arena_alloc) catch {
            enqueueImageResult(loop, args, &.{}, false);
            return;
        };
        defer ca_bundle.deinit();

        var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch {
            enqueueImageResult(loop, args, &.{}, false);
            return;
        };
        defer easy.deinit();

        const url_z = arena_alloc.dupeZ(u8, args.url) catch {
            enqueueImageResult(loop, args, &.{}, false);
            return;
        };
        easy.setUrl(url_z) catch {
            enqueueImageResult(loop, args, &.{}, false);
            return;
        };
        easy.setMethod(.GET) catch {
            enqueueImageResult(loop, args, &.{}, false);
            return;
        };

        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        easy.setWriter(&writer.writer) catch {
            enqueueImageResult(loop, args, &.{}, false);
            return;
        };

        const ret = easy.perform() catch {
            enqueueImageResult(loop, args, &.{}, false);
            return;
        };

        if (ret.status_code >= 200 and ret.status_code < 300) {
            body = writer.toOwnedSlice() catch {
                enqueueImageResult(loop, args, &.{}, false);
                return;
            };
            ok = true;
        }
    }

    enqueueImageResult(loop, args, body, ok);
}

fn enqueueImageResult(loop: *EventLoop, args: ImageFetchWorkerArgs, body: []const u8, ok: bool) void {
    const allocator = args.allocator;

    // pending_background_jobs decremented centrally in enqueueTask
    const cb_ctx = allocator.create(ImageFetchCallbackCtx) catch {
        allocator.free(args.url);
        return;
    };
    cb_ctx.* = .{
        .this_val = args.this_val,
        .body = body,
        .ok = ok,
    };

    loop.enqueueTask(.{
        .ctx = args.ctx,
        .resolve = zqjs.UNDEFINED,
        .reject = zqjs.UNDEFINED,
        .result = .{ .custom = .{
            .data = cb_ctx,
            .callback = finishImageFetch,
            .destroy = destroyImageFetchCtx,
        } },
    });

    allocator.free(args.url);
}

fn finishImageFetch(ctx: zqjs.Context, data: *anyopaque) void {
    const rc = RuntimeContext.get(ctx);
    const cb_ctx: *ImageFetchCallbackCtx = @ptrCast(@alignCast(data));
    const this_val = cb_ctx.this_val;

    defer {
        if (cb_ctx.body.len > 0) rc.allocator.free(cb_ctx.body);
        ctx.freeValue(this_val);
        rc.allocator.destroy(cb_ctx);
    }

    if (!cb_ctx.ok or cb_ctx.body.len == 0) {
        // Fire onerror
        fireImageError(ctx, rc, this_val);
        return;
    }

    // Decode image bytes
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));

    if (self.bitmap) |b| b.deinit();

    if (Image.initFromMemory(self.allocator, cb_ctx.body)) |new_img| {
        self.bitmap = new_img;
        self.natural_width = @intCast(new_img.width);
        self.natural_height = @intCast(new_img.height);
        self.complete = true;

        // Fire onload via enqueued job
        var args = [_]qjs.JSValue{this_val};
        _ = qjs.JS_EnqueueJob(ctx.ptr, js_image_onload_job, 1, &args);
    } else |_| {
        fireImageError(ctx, rc, this_val);
    }
}

fn fireImageError(ctx: zqjs.Context, rc: *RuntimeContext, this_val: zqjs.Value) void {
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));
    if (qjs.JS_IsFunction(ctx.ptr, self.onerror)) {
        const ret = qjs.JS_Call(ctx.ptr, self.onerror, this_val, 0, null);
        qjs.JS_FreeValue(ctx.ptr, ret);
    }
}

fn destroyImageFetchCtx(allocator: std.mem.Allocator, data: *anyopaque) void {
    const cb_ctx: *ImageFetchCallbackCtx = @ptrCast(@alignCast(data));
    if (cb_ctx.body.len > 0) allocator.free(cb_ctx.body);
    // Note: this_val freed by the event loop or caller
    allocator.destroy(cb_ctx);
}

/// the constructor is `createImageBitmap(blob)`
pub fn install(ctx: zqjs.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();

    // 1. Register Class
    if (rc.classes.image == 0) {
        rc.classes.image = rt.newClassID();
        try rt.newClass(rc.classes.image, .{
            .class_name = "ImageBitmap",
            .finalizer = finalizer,
        });

        const proto = ctx.newObject();
        // defer ctx.freeValue(proto);

        // Add Getters
        js_utils.defineGetter(ctx, proto, "width", js_get_width);
        js_utils.defineGetter(ctx, proto, "height", js_get_height);

        ctx.setClassProto(rc.classes.image, proto);
    }

    // 2. HTMLImageElement (New: 'Image')
    if (rc.classes.html_image == 0) {
        rc.classes.html_image = rt.newClassID();
        try rt.newClass(rc.classes.html_image, .{
            .class_name = "HTMLImageElement",
            .finalizer = html_image_finalizer,
            .gc_mark = html_image_gc_mark,
        });

        const proto = ctx.newObject();
        // Properties
        js_utils.defineAccessor(ctx, proto, "src", js_html_image_get_src, js_html_image_set_src);
        js_utils.defineAccessor(ctx, proto, "onload", js_html_image_get_onload, js_html_image_set_onload);
        js_utils.defineAccessor(ctx, proto, "onerror", js_html_image_get_onerror, js_html_image_set_onerror);
        js_utils.defineGetter(ctx, proto, "width", js_html_image_get_width_prop);
        js_utils.defineGetter(ctx, proto, "height", js_html_image_get_height_prop);
        js_utils.defineGetter(ctx, proto, "naturalWidth", js_html_image_get_width_prop);
        js_utils.defineGetter(ctx, proto, "naturalHeight", js_html_image_get_height_prop);
        js_utils.defineGetter(ctx, proto, "complete", js_html_image_get_complete);

        // Note: Add 'width', 'height', 'complete' getters here too for fullness

        ctx.setClassProto(rc.classes.html_image, proto);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const ctor = qjs.JS_NewCFunction2(ctx.ptr, js_html_image_constructor, "Image", 0, qjs.JS_CFUNC_constructor, 0);
        try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
        try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor));

        // Expose as "Image" and "HTMLImageElement"
        try ctx.setPropertyStr(global, "Image", ctx.dupValue(ctor));
        try ctx.setPropertyStr(global, "HTMLImageElement", ctor);
    }

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const func = qjs.JS_NewCFunction(ctx.ptr, js_createImageBitmap, "createImageBitmap", 1);
    try ctx.setPropertyStr(global, "createImageBitmap", func);
}

// === HTMLImageElement Methods (New)

fn html_image_gc_mark(rt: ?*qjs.JSRuntime, val: qjs.JSValue, mark_func: ?*const qjs.JS_MarkFunc) callconv(.c) void {
    const class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque2(null, val, class_id);
    if (ptr) |p| {
        const self: *HTMLImageElement = @ptrCast(@alignCast(p));
        qjs.JS_MarkValue(rt, self.onload, mark_func);
        qjs.JS_MarkValue(rt, self.onerror, mark_func);
    }
}

fn html_image_finalizer(rt: ?*qjs.JSRuntime, val: zqjs.Value) callconv(.c) void {
    const class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque2(null, val, class_id);
    if (ptr) |p| {
        // We need a context to free the JSValues (onload/onerror)
        // Since finalizer only gives Runtime, we technically leak the JSValue refs
        // if we don't manage them carefully.
        // Ideally, we free the native struct.
        // For MVP, simple allocator free is safe for the Zig struct.
        // JS_FreeValue on rt is possible if we cast.
        const self: *HTMLImageElement = @ptrCast(@alignCast(p));
        // Note: We can't safely free JSValues here without a Context but JS_FreeValueRT exists.
        qjs.JS_FreeValueRT(rt, self.onload);
        qjs.JS_FreeValueRT(rt, self.onerror);
        if (self.bitmap) |b| b.deinit();
        if (self.src) |s| self.allocator.free(s);
        self.allocator.destroy(self);
    }
}

fn js_html_image_constructor(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const img = HTMLImageElement.init(rc.allocator) catch return zqjs.EXCEPTION;

    const obj = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.html_image);
    if (qjs.JS_IsException(obj)) {
        if (ctx.ptr) |p| img.deinit(p);
        // img.deinit(ctx.ptr);
        return zqjs.EXCEPTION;
    }
    _ = qjs.JS_SetOpaque(obj, img);
    return obj;
}

/// The Job called by the Event Loop to trigger 'onload'
fn js_image_onload_job(ctx_ptr: ?*qjs.JSContext, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const this_val = argv[0]; // We passed 'this' as the argument
    const rc = RuntimeContext.get(ctx);

    // Unwrap
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image);
    if (ptr) |p| {
        const self: *HTMLImageElement = @ptrCast(@alignCast(p));
        if (qjs.JS_IsFunction(ctx.ptr, self.onload)) {
            // Call onload() with 'this' as context
            const ret = qjs.JS_Call(ctx.ptr, self.onload, this_val, 0, null);
            qjs.JS_FreeValue(ctx.ptr, ret);
        }
    }
    return zqjs.UNDEFINED;
}

fn js_html_image_set_src(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.EXCEPTION;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));

    const src_str = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    // Update internal src
    if (self.src) |s| self.allocator.free(s);
    const c_src_str = rc.allocator.dupeZ(u8, src_str) catch return zqjs.EXCEPTION;
    self.src = c_src_str; // We take ownership of the ZString copy? No, toZString returns copy we must free.
    // Actually, let's duplicate it for long-term storage or just parse it now.
    // For safety, let's keep a copy in the struct if we implemented getter.
    // For now, we process immediately.

    // 1. Check for Data URL
    if (std.mem.startsWith(u8, src_str, "data:")) {
        // "data:image/png;base64,....."
        if (std.mem.indexOf(u8, src_str, "base64,")) |idx| {
            const b64_data = src_str[idx + 7 ..]; // Skip "base64,"

            // Decode
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(b64_data) catch {
                // TODO: Fire onerror
                return zqjs.UNDEFINED;
            };

            const buffer = self.allocator.alloc(u8, size) catch return zqjs.EXCEPTION;
            defer self.allocator.free(buffer);

            decoder.decode(buffer, b64_data) catch return zqjs.UNDEFINED;

            // Load via STB
            if (self.bitmap) |b| b.deinit(); // Free old

            if (Image.initFromMemory(self.allocator, buffer)) |new_img| {
                self.bitmap = new_img;
                self.natural_width = @intCast(new_img.width);
                self.natural_height = @intCast(new_img.height);
                self.complete = true;

                // Enqueue Load Event (Async)
                // We pass 'this' (the image object) to the job
                var args = [_]qjs.JSValue{this_val};
                _ = qjs.JS_EnqueueJob(ctx.ptr, js_image_onload_job, 1, &args);
            } else |_| {
                // Decode failed
                // TODO: Enqueue onerror
            }
        }
    } else if (std.mem.startsWith(u8, src_str, "blob:")) {
        // Look up blob URL in registry
        if (rc.blob_registry.get(src_str)) |blob_val| {
            const blob_ptr = qjs.JS_GetOpaque(blob_val, rc.classes.blob);
            if (blob_ptr) |p| {
                const blob: *js_blob.BlobObject = @ptrCast(@alignCast(p));

                if (self.bitmap) |b| b.deinit();

                if (Image.initFromMemory(self.allocator, blob.data)) |new_img| {
                    self.bitmap = new_img;
                    self.natural_width = @intCast(new_img.width);
                    self.natural_height = @intCast(new_img.height);
                    self.complete = true;

                    var args = [_]qjs.JSValue{this_val};
                    _ = qjs.JS_EnqueueJob(ctx.ptr, js_image_onload_job, 1, &args);
                } else |_| {
                    fireImageError(ctx, rc, this_val);
                }
            }
        } else {
            std.debug.print("⚠️ Image.src: blob URL not found in registry\n", .{});
            fireImageError(ctx, rc, this_val);
        }
    } else if (std.mem.startsWith(u8, src_str, "http://") or std.mem.startsWith(u8, src_str, "https://")) {
        // Async fetch via worker thread
        const loop = rc.loop;
        const url_copy = rc.allocator.dupe(u8, src_str) catch return zqjs.EXCEPTION;

        // Dup this_val so the HTMLImageElement stays alive until the callback
        const this_dup = ctx.dupValue(this_val);

        loop.spawnWorker(imageFetchWorker, ImageFetchWorkerArgs{
            .loop = loop,
            .ctx = ctx,
            .this_val = this_dup,
            .url = url_copy,
            .allocator = rc.allocator,
            .sandbox = rc.sandbox,
        }) catch {
            rc.allocator.free(url_copy);
            ctx.freeValue(this_dup);
            std.debug.print("Failed to spawn image fetch worker\n", .{});
            return zqjs.UNDEFINED;
        };
    } else {
        std.debug.print("⚠️ Image.src: unsupported URL scheme\n", .{});
    }

    return zqjs.UNDEFINED;
}

fn js_html_image_get_src(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.UNDEFINED;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));

    if (self.src) |s| {
        return ctx.newString(s);
    }
    return ctx.newString("");
}

fn js_html_image_set_onload(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.EXCEPTION;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));

    qjs.JS_FreeValue(ctx.ptr, self.onload);
    self.onload = qjs.JS_DupValue(ctx.ptr, argv[0]);
    return zqjs.UNDEFINED;
}

fn js_html_image_get_onload(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.UNDEFINED;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));
    return qjs.JS_DupValue(ctx.ptr, self.onload);
}

fn js_html_image_get_onerror(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.UNDEFINED;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));
    return qjs.JS_DupValue(ctx.ptr, self.onerror);
}

fn js_html_image_set_onerror(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.EXCEPTION;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));

    qjs.JS_FreeValue(ctx.ptr, self.onerror);
    self.onerror = qjs.JS_DupValue(ctx.ptr, argv[0]);
    return zqjs.UNDEFINED;
}

fn js_html_image_get_width_prop(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.UNDEFINED;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));
    return qjs.JS_NewInt32(ctx.ptr, @intCast(self.natural_width));
}

fn js_html_image_get_height_prop(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.UNDEFINED;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));
    return qjs.JS_NewInt32(ctx.ptr, @intCast(self.natural_height));
}

fn js_html_image_get_complete(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.html_image) orelse return zqjs.UNDEFINED;
    const self: *HTMLImageElement = @ptrCast(@alignCast(ptr));
    // return qjs.JS_NewBool(ctx.ptr, self.complete);
    return ctx.newBool(self.complete);
}

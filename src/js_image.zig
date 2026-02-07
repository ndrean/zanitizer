const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_blob = @import("js_blob.zig"); // To unwrap input blobs
const js_utils = @import("js_utils.zig");

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

pub const Image = struct {
    width: i32,
    height: i32,
    channels: i32,
    pixels: [*]u8, // Owned by STB (malloc), must free with stbi_image_free
    allocator: std.mem.Allocator,

    /// Decodes an image from memory (PNG, JPEG, GIF, etc.)
    /// We force 4 channels (RGBA) to match Canvas format.
    pub fn initFromMemory(allocator: std.mem.Allocator, buffer: []const u8) !*Image {
        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;

        // Force 4 components (Red, Green, Blue, Alpha)
        const ptr = stbi_load_from_memory(buffer.ptr, @intCast(buffer.len), &w, &h, &ch, 4);

        if (ptr == null) return error.DecodeFailed;

        const self = try allocator.create(Image); // heap
        self.* = Image{
            .width = w,
            .height = h,
            .channels = 4,
            .pixels = ptr.?,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *Image) void {
        stbi_image_free(self.pixels);
        self.allocator.destroy(self);
    }
};

/// Helper: unwraps a JS Value into a Native *Image
pub fn unwrapImage(ctx: zqjs.Context, val: zqjs.Value) ?*Image {
    const rc = RuntimeContext.get(ctx);
    if (rc.classes.image == 0) return null;
    const ptr = qjs.JS_GetOpaque(val, rc.classes.image);
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

/// Helper to create a TypeError object (value) for Promise rejection.
/// We cannot use ctx.throwTypeError() because that throws synchronously!
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

// === Class properties

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

// === Lifecycle
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

    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const func = qjs.JS_NewCFunction(ctx.ptr, js_createImageBitmap, "createImageBitmap", 1);
    try ctx.setPropertyStr(global, "createImageBitmap", func);
}

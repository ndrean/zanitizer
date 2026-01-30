//! TextEncoder/TextDecoder Web API implementation
//! Uses lexbor encoding for multi-encoding support (via modules/encoding.zig)
//!
//! TextEncoder: Always encodes to UTF-8 (per spec)
//! TextDecoder: Decodes from various encodings to UTF-8

const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// ============================================================================
// TextDecoder Object (stores encoding type)
// ============================================================================

pub const TextDecoderObject = struct {
    allocator: std.mem.Allocator,
    encoding: z.Encoding,
    encoding_data: ?*const z.EncodingData,
    fatal: bool,
    ignore_bom: bool,

    pub fn init(allocator: std.mem.Allocator, label: []const u8, fatal: bool, ignore_bom: bool) !*TextDecoderObject {
        const self = try allocator.create(TextDecoderObject);
        errdefer allocator.destroy(self);

        // Get encoding data by name (lexbor normalizes the name)
        const encoding_data = z.getEncodingDataByName(label);

        self.* = .{
            .allocator = allocator,
            .encoding = if (encoding_data != null) .UTF_8 else .UTF_8, // Default to UTF-8
            .encoding_data = encoding_data orelse z.getEncodingData(.UTF_8),
            .fatal = fatal,
            .ignore_bom = ignore_bom,
        };

        return self;
    }

    pub fn deinit(self: *TextDecoderObject) void {
        self.allocator.destroy(self);
    }

    /// Decode bytes to UTF-8 string using the encoding module
    pub fn decode(self: *TextDecoderObject, allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        return z.decodeToUtf8(allocator, data, self.encoding_data, self.fatal) catch |err| {
            return switch (err) {
                z.DecodeError.DecodingFailed => error.DecodingError,
                z.DecodeError.OutOfMemory => error.OutOfMemory,
                else => error.DecodingError,
            };
        };
    }
};

// ============================================================================
// TextEncoder (always UTF-8)
// ============================================================================

/// TextEncoder.encode(string) -> Uint8Array
fn js_TextEncoder_encode(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };

    if (argc < 1) {
        // Return empty Uint8Array
        return qjs.JS_NewArrayBufferCopy(ctx.ptr, null, 0);
    }

    // Get string as UTF-8 (QuickJS handles the conversion)
    var len: usize = 0;
    const str = qjs.JS_ToCStringLen(ctx.ptr, &len, argv[0]);
    if (str == null) return w.EXCEPTION;
    defer qjs.JS_FreeCString(ctx.ptr, str);

    // Create Uint8Array from the UTF-8 bytes
    const array_buffer = qjs.JS_NewArrayBufferCopy(ctx.ptr, @ptrCast(str), len);
    if (qjs.JS_IsException(array_buffer)) return w.EXCEPTION;

    // Wrap in Uint8Array
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);
    const uint8_ctor = ctx.getPropertyStr(global, "Uint8Array");
    defer ctx.freeValue(uint8_ctor);

    var args = [_]qjs.JSValue{array_buffer};
    const result = qjs.JS_CallConstructor(ctx.ptr, uint8_ctor, 1, &args);
    ctx.freeValue(array_buffer);

    return result;
}

/// TextEncoder.encodeInto(string, uint8array) -> { read, written }
fn js_TextEncoder_encodeInto(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };

    if (argc < 2) return ctx.throwTypeError("encodeInto requires 2 arguments");

    // Get source string
    var str_len: usize = 0;
    const str = qjs.JS_ToCStringLen(ctx.ptr, &str_len, argv[0]);
    if (str == null) return w.EXCEPTION;
    defer qjs.JS_FreeCString(ctx.ptr, str);

    // Get destination TypedArray
    var dest_size: usize = 0;
    const dest_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &dest_size, argv[1]);
    if (dest_ptr == null) {
        // Try getting from TypedArray
        var byte_offset: usize = 0;
        var byte_len: usize = 0;
        var bytes_per_elem: usize = 0;
        const ab = qjs.JS_GetTypedArrayBuffer(ctx.ptr, argv[1], &byte_offset, &byte_len, &bytes_per_elem);
        if (qjs.JS_IsException(ab)) {
            return ctx.throwTypeError("Second argument must be a Uint8Array");
        }
        defer ctx.freeValue(ab);

        var ab_size: usize = 0;
        const ab_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &ab_size, ab);
        if (ab_ptr == null) return ctx.throwTypeError("Could not get ArrayBuffer");

        const actual_ptr = ab_ptr + byte_offset;
        const actual_len = @min(byte_len, str_len);

        @memcpy(actual_ptr[0..actual_len], @as([*]const u8, @ptrCast(str))[0..actual_len]);

        // Return result object
        const result_obj = ctx.newObject();
        ctx.setPropertyStr(result_obj, "read", ctx.newInt32(@intCast(actual_len))) catch return w.EXCEPTION;
        ctx.setPropertyStr(result_obj, "written", ctx.newInt32(@intCast(actual_len))) catch return w.EXCEPTION;
        return result_obj;
    }

    const copy_len = @min(dest_size, str_len);
    @memcpy(dest_ptr[0..copy_len], @as([*]const u8, @ptrCast(str))[0..copy_len]);

    // Return { read, written }
    const result_obj = ctx.newObject();
    ctx.setPropertyStr(result_obj, "read", ctx.newInt32(@intCast(copy_len))) catch return w.EXCEPTION;
    ctx.setPropertyStr(result_obj, "written", ctx.newInt32(@intCast(copy_len))) catch return w.EXCEPTION;
    return result_obj;
}

/// TextEncoder.encoding getter (always "utf-8")
fn js_TextEncoder_get_encoding(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    return ctx.newString("utf-8");
}

/// TextEncoder constructor
fn js_TextEncoder_constructor(
    ctx_ptr: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (qjs.JS_IsUndefined(new_target)) {
        return ctx.throwTypeError("Constructor TextEncoder requires 'new'");
    }

    const proto = ctx.getClassProto(rc.classes.text_encoder);
    defer ctx.freeValue(proto);

    return ctx.newObjectProtoClass(proto, rc.classes.text_encoder);
}

// ============================================================================
// TextDecoder
// ============================================================================

/// TextDecoder constructor
fn js_TextDecoder_constructor(
    ctx_ptr: ?*qjs.JSContext,
    new_target: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (qjs.JS_IsUndefined(new_target)) {
        return ctx.throwTypeError("Constructor TextDecoder requires 'new'");
    }

    // Get encoding label (default: "utf-8")
    var label: []const u8 = "utf-8";
    var label_cstr: [*c]const u8 = null;
    if (argc >= 1 and qjs.JS_IsString(argv[0])) {
        var len: usize = 0;
        label_cstr = qjs.JS_ToCStringLen(ctx.ptr, &len, argv[0]);
        if (label_cstr != null) {
            label = label_cstr[0..len];
        }
    }
    defer if (label_cstr != null) qjs.JS_FreeCString(ctx.ptr, label_cstr);

    // Parse options (second argument)
    var fatal = false;
    var ignore_bom = false;
    if (argc >= 2 and qjs.JS_IsObject(argv[1])) {
        const fatal_val = ctx.getPropertyStr(argv[1], "fatal");
        defer ctx.freeValue(fatal_val);
        if (qjs.JS_IsBool(fatal_val)) {
            fatal = qjs.JS_ToBool(ctx.ptr, fatal_val) != 0;
        }

        const ignore_bom_val = ctx.getPropertyStr(argv[1], "ignoreBOM");
        defer ctx.freeValue(ignore_bom_val);
        if (qjs.JS_IsBool(ignore_bom_val)) {
            ignore_bom = qjs.JS_ToBool(ctx.ptr, ignore_bom_val) != 0;
        }
    }

    // Create decoder object
    const decoder = TextDecoderObject.init(rc.allocator, label, fatal, ignore_bom) catch {
        return ctx.throwOutOfMemory();
    };

    const proto = ctx.getClassProto(rc.classes.text_decoder);
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, rc.classes.text_decoder);
    _ = qjs.JS_SetOpaque(obj, decoder);

    return obj;
}

/// TextDecoder finalizer
fn js_TextDecoder_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr) |p| {
        const decoder: *TextDecoderObject = @ptrCast(@alignCast(p));
        decoder.deinit();
    }
}

/// TextDecoder.decode(buffer) -> string
fn js_TextDecoder_decode(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    // Get decoder object
    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.text_decoder);
    if (ptr == null) return ctx.throwTypeError("Not a TextDecoder");
    const decoder: *TextDecoderObject = @ptrCast(@alignCast(ptr));

    if (argc < 1) {
        return ctx.newString("");
    }

    // Get input buffer (ArrayBuffer or TypedArray)
    var data_ptr: [*]u8 = undefined;
    var data_len: usize = 0;

    // Try ArrayBuffer first
    const ab_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &data_len, argv[0]);
    if (ab_ptr != null) {
        data_ptr = ab_ptr;
    } else {
        // Try TypedArray
        var byte_offset: usize = 0;
        var byte_len: usize = 0;
        var bytes_per_elem: usize = 0;
        const ab = qjs.JS_GetTypedArrayBuffer(ctx.ptr, argv[0], &byte_offset, &byte_len, &bytes_per_elem);
        if (qjs.JS_IsException(ab)) {
            return ctx.throwTypeError("Argument must be ArrayBuffer or TypedArray");
        }
        defer ctx.freeValue(ab);

        var ab_size: usize = 0;
        const typed_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &ab_size, ab);
        if (typed_ptr == null) {
            return ctx.throwTypeError("Could not get ArrayBuffer");
        }
        data_ptr = typed_ptr + byte_offset;
        data_len = byte_len;
    }

    if (data_len == 0) {
        return ctx.newString("");
    }

    // Decode
    const decoded = decoder.decode(rc.allocator, data_ptr[0..data_len]) catch |err| {
        return switch (err) {
            error.DecodingError => ctx.throwTypeError("The encoded data was not valid"),
            else => ctx.throwOutOfMemory(),
        };
    };
    defer rc.allocator.free(decoded);

    return ctx.newString(decoded);
}

/// TextDecoder.encoding getter
fn js_TextDecoder_get_encoding(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.text_decoder);
    if (ptr == null) return ctx.throwTypeError("Not a TextDecoder");

    // For now, always report utf-8 (we can expand this later)
    return ctx.newString("utf-8");
}

/// TextDecoder.fatal getter
fn js_TextDecoder_get_fatal(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.text_decoder);
    if (ptr == null) return ctx.throwTypeError("Not a TextDecoder");
    const decoder: *TextDecoderObject = @ptrCast(@alignCast(ptr));

    return ctx.newBool(decoder.fatal);
}

/// TextDecoder.ignoreBOM getter
fn js_TextDecoder_get_ignoreBOM(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.text_decoder);
    if (ptr == null) return ctx.throwTypeError("Not a TextDecoder");
    const decoder: *TextDecoderObject = @ptrCast(@alignCast(ptr));

    return ctx.newBool(decoder.ignore_bom);
}

// ============================================================================
// Installation
// ============================================================================

pub fn install(ctx: w.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    // --- TextEncoder ---
    if (rc.classes.text_encoder == 0) {
        rc.classes.text_encoder = rt.newClassID();
    }
    try rt.newClass(rc.classes.text_encoder, .{
        .class_name = "TextEncoder",
        .finalizer = null, // No state to clean up
    });

    const encoder_proto = ctx.newObject();
    {
        // Methods
        _ = qjs.JS_SetPropertyStr(ctx.ptr, encoder_proto, "encode", qjs.JS_NewCFunction(ctx.ptr, js_TextEncoder_encode, "encode", 1));
        _ = qjs.JS_SetPropertyStr(ctx.ptr, encoder_proto, "encodeInto", qjs.JS_NewCFunction(ctx.ptr, js_TextEncoder_encodeInto, "encodeInto", 2));

        // encoding property (readonly)
        const atom = qjs.JS_NewAtom(ctx.ptr, "encoding");
        defer qjs.JS_FreeAtom(ctx.ptr, atom);
        const get_fn = qjs.JS_NewCFunction2(ctx.ptr, js_TextEncoder_get_encoding, "get_encoding", 0, qjs.JS_CFUNC_generic, 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, encoder_proto, atom, get_fn, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    }

    const encoder_ctor = qjs.JS_NewCFunction2(ctx.ptr, js_TextEncoder_constructor, "TextEncoder", 0, qjs.JS_CFUNC_constructor, 0);
    _ = ctx.setConstructor(encoder_ctor, encoder_proto);
    _ = qjs.JS_SetClassProto(ctx.ptr, rc.classes.text_encoder, encoder_proto);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "TextEncoder", encoder_ctor);

    // --- TextDecoder ---
    if (rc.classes.text_decoder == 0) {
        rc.classes.text_decoder = rt.newClassID();
    }
    try rt.newClass(rc.classes.text_decoder, .{
        .class_name = "TextDecoder",
        .finalizer = js_TextDecoder_finalizer,
    });

    const decoder_proto = ctx.newObject();
    {
        // Methods
        _ = qjs.JS_SetPropertyStr(ctx.ptr, decoder_proto, "decode", qjs.JS_NewCFunction(ctx.ptr, js_TextDecoder_decode, "decode", 1));

        // encoding property (readonly)
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "encoding");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = qjs.JS_NewCFunction2(ctx.ptr, js_TextDecoder_get_encoding, "get_encoding", 0, qjs.JS_CFUNC_generic, 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, decoder_proto, atom, get_fn, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }

        // fatal property (readonly)
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "fatal");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = qjs.JS_NewCFunction2(ctx.ptr, js_TextDecoder_get_fatal, "get_fatal", 0, qjs.JS_CFUNC_generic, 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, decoder_proto, atom, get_fn, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }

        // ignoreBOM property (readonly)
        {
            const atom = qjs.JS_NewAtom(ctx.ptr, "ignoreBOM");
            defer qjs.JS_FreeAtom(ctx.ptr, atom);
            const get_fn = qjs.JS_NewCFunction2(ctx.ptr, js_TextDecoder_get_ignoreBOM, "get_ignoreBOM", 0, qjs.JS_CFUNC_generic, 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, decoder_proto, atom, get_fn, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
    }

    const decoder_ctor = qjs.JS_NewCFunction2(ctx.ptr, js_TextDecoder_constructor, "TextDecoder", 0, qjs.JS_CFUNC_constructor, 0);
    _ = ctx.setConstructor(decoder_ctor, decoder_proto);
    _ = qjs.JS_SetClassProto(ctx.ptr, rc.classes.text_decoder, decoder_proto);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "TextDecoder", decoder_ctor);
}

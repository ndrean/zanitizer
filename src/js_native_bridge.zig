/// Bridge for passing data between QuickJS and Zig for high-performance processing
/// This demonstrates how to pass arrays, objects, and complex data structures
const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;

/// Retrieve the Zig allocator stored in the JSContext opaque pointer
/// This is used by generated bindings and manual wrappers to get the allocator
/// without requiring it as an explicit JavaScript argument
pub fn getAllocator(ctx: ?*qjs.JSContext) std.mem.Allocator {
    const opaque_ptr = qjs.JS_GetContextOpaque(ctx);
    const allocator_ptr: *std.mem.Allocator = @ptrCast(@alignCast(opaque_ptr));
    return allocator_ptr.*;
}

/// Example 1: Process array of numbers in Zig (native speed)
/// JavaScript: const result = processArray([1, 2, 3, 4, 5]);
pub fn js_processArray(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return z.jsException;

    const array = argv[0];

    // Get array length
    const length_prop = qjs.JS_GetPropertyStr(
        ctx,
        array,
        "length",
    );
    defer qjs.JS_FreeValue(ctx, length_prop);

    var length: u32 = 0;
    _ = qjs.JS_ToUint32(ctx, &length, length_prop);

    // Get the Zig allocator from context (passed during setup)
    const allocator = getAllocator(ctx);

    const data = allocator.alloc(f64, length) catch return z.jsException;
    defer allocator.free(data);

    // Copy JavaScript array to Zig
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        const elem = qjs.JS_GetPropertyUint32(ctx, array, i);
        defer qjs.JS_FreeValue(ctx, elem);

        _ = qjs.JS_ToFloat64(ctx, &data[i], elem);
    }

    // ===== PROCESS IN ZIG AT NATIVE SPEED =====
    const result = processArrayNative(data);
    // ===========================================

    // Return result to JavaScript
    return qjs.JS_NewFloat64(ctx, result);
}

/// Native Zig processing (runs at full speed, no interpreter overhead)
fn processArrayNative(data: []f64) f64 {
    var sum: f64 = 0;
    for (data) |item| {
        // Complex computation that would be slow in QuickJS
        sum += @sqrt(item) * @sin(item) + @cos(item * 2);
    }
    return sum;
}

/// Example 2: Process array and return new array
/// JavaScript: const transformed = transformArray([1, 2, 3]);
pub fn js_transformArray(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return z.jsException;

    const array = argv[0];

    // Get array length
    const length_prop = qjs.JS_GetPropertyStr(ctx, array, "length");
    defer qjs.JS_FreeValue(ctx, length_prop);

    var length: u32 = 0;
    _ = qjs.JS_ToUint32(ctx, &length, length_prop);

    // Get the Zig allocator from context (passed during setup)
    const allocator = getAllocator(ctx);

    const input = allocator.alloc(f64, length) catch return z.jsException;
    defer allocator.free(input);

    const output = allocator.alloc(f64, length) catch return z.jsException;
    defer allocator.free(output);

    // Copy JavaScript array to Zig
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        const elem = qjs.JS_GetPropertyUint32(ctx, array, i);
        defer qjs.JS_FreeValue(ctx, elem);
        _ = qjs.JS_ToFloat64(ctx, &input[i], elem);
    }

    // Process in Zig
    transformArrayNative(input, output);

    // Create JavaScript array from Zig results
    const result_array = qjs.JS_NewArray(ctx);
    i = 0;
    while (i < length) : (i += 1) {
        const val = qjs.JS_NewFloat64(ctx, output[i]);
        _ = qjs.JS_SetPropertyUint32(ctx, result_array, i, val);
    }

    return result_array;
}

fn transformArrayNative(input: []f64, output: []f64) void {
    for (input, 0..) |item, i| {
        // Complex transformation at native speed
        output[i] = @sqrt(item * 3.14) + @log(item + 1);
    }
}

/// Example 3: Process TypedArray (zero-copy for maximum performance)
/// JavaScript: const buffer = new Float64Array([1, 2, 3, 4, 5]);
///             const result = processTypedArray(buffer);
pub fn js_processTypedArray(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return z.jsException;

    const typed_array = argv[0];

    // Get ArrayBuffer from TypedArray
    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    var bytes_per_element: usize = 0;

    const buffer = qjs.JS_GetTypedArrayBuffer(
        ctx,
        typed_array,
        &byte_offset,
        &byte_length,
        &bytes_per_element,
    );
    defer qjs.JS_FreeValue(ctx, buffer);

    // Get raw buffer pointer (ZERO-COPY!)
    var size: usize = 0;
    const data_ptr = qjs.JS_GetArrayBuffer(ctx, &size, buffer);

    if (data_ptr == null) return z.jsException;

    // Cast to f64 array (assuming Float64Array)
    const data: [*]f64 = @ptrCast(@alignCast(data_ptr));
    const length = byte_length / @sizeOf(f64);
    const data_slice = data[0..length];

    // Process at native speed with ZERO copying!
    const result = processArrayNative(data_slice);

    return qjs.JS_NewFloat64(ctx, result);
}

/// Example 4: Process object/struct data
/// JavaScript: const result = processObject({ x: 10, y: 20, values: [1,2,3] });
pub fn js_processObject(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return z.jsException;

    const obj = argv[0];

    // Extract properties
    const x_prop = qjs.JS_GetPropertyStr(ctx, obj, "x");
    defer qjs.JS_FreeValue(ctx, x_prop);

    const y_prop = qjs.JS_GetPropertyStr(ctx, obj, "y");
    defer qjs.JS_FreeValue(ctx, y_prop);

    const values_prop = qjs.JS_GetPropertyStr(ctx, obj, "values");
    defer qjs.JS_FreeValue(ctx, values_prop);

    var x: f64 = 0;
    var y: f64 = 0;
    _ = qjs.JS_ToFloat64(ctx, &x, x_prop);
    _ = qjs.JS_ToFloat64(ctx, &y, y_prop);

    // Get array length
    const length_prop = qjs.JS_GetPropertyStr(ctx, values_prop, "length");
    defer qjs.JS_FreeValue(ctx, length_prop);

    var length: u32 = 0;
    _ = qjs.JS_ToUint32(ctx, &length, length_prop);

    // Get the Zig allocator from context (passed during setup)
    const allocator = getAllocator(ctx);

    const values = allocator.alloc(f64, length) catch return z.jsException;
    defer allocator.free(values);

    var i: u32 = 0;
    while (i < length) : (i += 1) {
        const elem = qjs.JS_GetPropertyUint32(ctx, values_prop, i);
        defer qjs.JS_FreeValue(ctx, elem);
        _ = qjs.JS_ToFloat64(ctx, &values[i], elem);
    }

    // Create Zig struct
    const data = DataStruct{
        .x = x,
        .y = y,
        .values = values,
    };

    // Process in Zig
    const result = processStructNative(data);

    return qjs.JS_NewFloat64(ctx, result);
}

const DataStruct = struct {
    x: f64,
    y: f64,
    values: []f64,
};

fn processStructNative(data: DataStruct) f64 {
    var sum: f64 = data.x + data.y;
    for (data.values) |val| {
        sum += val * @sqrt(data.x) * @sin(data.y);
    }
    return sum;
}

/// Example 5: Pass string data for text processing
/// JavaScript: const cleaned = processText("Hello   World  !");
pub fn js_processText(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    if (argc < 1) return z.jsException;

    const text_c = qjs.JS_ToCString(ctx, argv[0]);
    if (text_c == null) return z.jsException;
    defer qjs.JS_FreeCString(ctx, text_c);

    const text = std.mem.span(text_c);

    // Get the Zig allocator from context (passed during setup)
    const allocator = getAllocator(ctx);

    const result = processTextNative(allocator, text) catch return z.jsException;
    defer allocator.free(result);

    // Return processed string
    return qjs.JS_NewString(ctx, result.ptr);
}

fn processTextNative(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // Example: Remove extra whitespace
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var prev_was_space = false;
    for (text) |c| {
        if (c == ' ') {
            if (!prev_was_space) {
                try result.append(allocator, c);
                prev_was_space = true;
            }
        } else {
            try result.append(allocator, c);
            prev_was_space = false;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Install all native processing functions
/// The allocator pointer is stored in the JSContext opaque data for use by bridge functions
pub fn installNativeBridge(ctx: w.Context, allocator: *std.mem.Allocator) void {
    // const ctx: ?*qjs.JSContext = @ptrCast(@alignCast(ctx_opaque));
    ctx.setAllocator(allocator);

    // Store the Zig allocator in the JSContext opaque pointer
    qjs.JS_SetContextOpaque(ctx, allocator);

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);

    // Create native object
    const native_obj = qjs.JS_NewObject(ctx);

    // Add functions
    const process_array_fn = qjs.JS_NewCFunction2(
        ctx,
        js_processArray,
        "processArray",
        1,
        qjs.JS_CFUNC_generic,
        0,
    );
    _ = qjs.JS_SetPropertyStr(ctx, native_obj, "processArray", process_array_fn);

    const transform_array_fn = qjs.JS_NewCFunction2(
        ctx,
        js_transformArray,
        "transformArray",
        1,
        qjs.JS_CFUNC_generic,
        0,
    );
    _ = qjs.JS_SetPropertyStr(ctx, native_obj, "transformArray", transform_array_fn);

    const process_typed_array_fn = qjs.JS_NewCFunction2(
        ctx,
        js_processTypedArray,
        "processTypedArray",
        1,
        qjs.JS_CFUNC_generic,
        0,
    );
    _ = qjs.JS_SetPropertyStr(ctx, native_obj, "processTypedArray", process_typed_array_fn);

    const process_object_fn = qjs.JS_NewCFunction2(
        ctx,
        js_processObject,
        "processObject",
        1,
        qjs.JS_CFUNC_generic,
        0,
    );
    _ = qjs.JS_SetPropertyStr(ctx, native_obj, "processObject", process_object_fn);

    const process_text_fn = qjs.JS_NewCFunction2(
        ctx,
        js_processText,
        "processText",
        1,
        qjs.JS_CFUNC_generic,
        0,
    );
    _ = qjs.JS_SetPropertyStr(ctx, native_obj, "processText", process_text_fn);

    // Install as global 'Native' object
    _ = qjs.JS_SetPropertyStr(ctx, global, "Native", native_obj);
}

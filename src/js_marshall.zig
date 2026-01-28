const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;

/// Generic function to convert any JS Value into a Native Zig Type
/// - Allocator: Used for strings and slices (arrays)
/// - T: The target Zig type (inferred or explicit)
pub fn jsToZig(allocator: std.mem.Allocator, ctx: w.Context, val: w.Value, comptime T: type) !T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        // --- 1. Integers ---
        .int => {
            if (T == i32) {
                var res: i32 = 0;
                if (qjs.JS_ToInt32(ctx.ptr, &res, val) != 0) return error.JsConversionFailed;
                return res;
            } else if (T == i64) {
                var res: i64 = 0;
                if (qjs.JS_ToInt64(ctx.ptr, &res, val) != 0) return error.JsConversionFailed;
                return res;
            } else if (T == u32) {
                var res: u32 = 0;
                if (qjs.JS_ToUint32(ctx.ptr, &res, val) != 0) return error.JsConversionFailed;
                return res;
            } else {
                // Fallback for other ints (u64, u8, etc) via i64/f64
                var res: i64 = 0;
                if (qjs.JS_ToInt64(ctx.ptr, &res, val) != 0) return error.JsConversionFailed;
                return @intCast(res);
            }
        },

        // --- 2. Floats ---
        .float => {
            var res: f64 = 0;
            if (qjs.JS_ToFloat64(ctx.ptr, &res, val) != 0) return error.JsConversionFailed;
            return @floatCast(res);
        },

        // --- 3. Booleans ---
        .bool => {
            return qjs.JS_ToBool(ctx.ptr, val) != 0;
        },

        // --- 4. Strings ([]const u8) ---
        .pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                // Check if it's a string
                if (!ctx.isString(val)) return error.ExpectedString;

                // We MUST duplicate it because the JS pointer is temporary
                const str = try ctx.toCString(val); // or toZString
                defer ctx.freeCString(str);
                return allocator.dupe(u8, std.mem.span(str));
            }
            // Add Array support here later if needed
            return error.UnsupportedPointerType;
        },

        // --- 5. Structs (The Magic) ---
        .@"struct" => {
            if (!ctx.isObject(val)) return error.ExpectedObject;

            var result: T = undefined;

            // Iterate over every field defined in the Zig struct
            inline for (type_info.Struct.fields) |field| {
                // 1. Get the property from JS using the field name
                // (You could add logic here to convert snake_case to camelCase if needed)
                const prop_val = ctx.getPropertyStr(val, field.name);
                defer ctx.freeValue(prop_val);

                // 2. Handle Optional Fields (?T)
                const field_info = @typeInfo(field.type);
                if (field_info == .Optional) {
                    if (ctx.isUndefined(prop_val) or ctx.isNull(prop_val)) {
                        @field(result, field.name) = null;
                    } else {
                        // Recurse for the child type
                        const ChildT = field_info.Optional.child;
                        @field(result, field.name) = try jsToZig(allocator, ctx, prop_val, ChildT);
                    }
                }
                // 3. Handle Required Fields
                else {
                    if (ctx.isUndefined(prop_val)) {
                        // If field has a default value, use it
                        if (field.default_value) |default_ptr| {
                            const default = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                            @field(result, field.name) = default;
                        } else {
                            // No default and missing in JS -> Error
                            std.debug.print("Missing required field: {s}\n", .{field.name});
                            return error.MissingField;
                        }
                    } else {
                        // Recurse!
                        @field(result, field.name) = try jsToZig(allocator, ctx, prop_val, field.type);
                    }
                }
            }
            return result;
        },

        .optional => |opt| {
            if (ctx.isUndefined(val) or ctx.isNull(val)) return null;
            return try jsToZig(allocator, ctx, val, opt.child);
        },

        else => return error.UnsupportedType,
    }
}

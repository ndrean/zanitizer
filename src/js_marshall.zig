const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;

/// Generic function to convert any JS Value into a Native Zig Type
pub fn jsToZig(allocator: std.mem.Allocator, ctx: w.Context, val: w.Value, comptime T: type) !T {
    const type_info = @typeInfo(T);

    switch (type_info) {
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
                var res: i64 = 0;
                if (qjs.JS_ToInt64(ctx.ptr, &res, val) != 0) return error.JsConversionFailed;
                return @intCast(res);
            }
        },
        .float => {
            var res: f64 = 0;
            if (qjs.JS_ToFloat64(ctx.ptr, &res, val) != 0) return error.JsConversionFailed;
            return @floatCast(res);
        },
        .bool => {
            return qjs.JS_ToBool(ctx.ptr, val) != 0;
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                if (!ctx.isString(val)) return error.ExpectedString;
                const str = try ctx.toCString(val);
                defer ctx.freeCString(str);
                return allocator.dupe(u8, std.mem.span(str));
            }
            return error.UnsupportedPointerType;
        },
        .@"struct" => {
            if (!ctx.isObject(val)) return error.ExpectedObject;
            var result: T = undefined;

            inline for (type_info.@"struct".fields) |field| {
                const prop_val = ctx.getPropertyStr(val, field.name);
                defer ctx.freeValue(prop_val);

                const field_info = @typeInfo(field.type);
                if (field_info == .optional) {
                    if (ctx.isUndefined(prop_val) or ctx.isNull(prop_val)) {
                        @field(result, field.name) = null;
                    } else {
                        const ChildT = field_info.optional.child;
                        @field(result, field.name) = try jsToZig(allocator, ctx, prop_val, ChildT);
                    }
                } else {
                    if (ctx.isUndefined(prop_val)) {
                        // [FIX] Use default_value (pointer) correctly
                        if (field.default_value_ptr) |default_ptr| {
                            const default_val = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                            @field(result, field.name) = default_val;
                        } else {
                            std.debug.print("Missing required field: {s}\n", .{field.name});
                            return error.MissingField;
                        }
                    } else {
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

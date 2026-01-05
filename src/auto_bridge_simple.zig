const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const AsyncBridge = @import("async_bridge.zig");

/// AUTOMATIC async binding generator (Simplified Version)
/// Generates parser function at compile-time by inspecting Payload struct fields
///
/// DESIGN:
/// - JavaScript args[i] maps to Payload.field[i] (order matters!)
/// - String fields are automatically heap-allocated using loop.allocator
/// - Worker function must free owned string fields
///
/// LIMITATIONS:
/// - Field order MUST match JavaScript argument order
/// - No support for optional arguments (all fields required)
/// - No support for complex objects (use manual parser)
///
/// USAGE:
///   const FileTask = struct { path: []const u8 };
///   fn doReadFile(allocator: Allocator, p: FileTask) ![]u8 { ... }
///   pub const readFile = AutoBridge.bindAsyncAuto(FileTask, doReadFile);
///
pub fn bindAsyncAuto(
    comptime Payload: type,
    comptime workFn: fn (allocator: std.mem.Allocator, payload: Payload) anyerror![]u8,
) qjs.JSCFunction {
    // Validate Payload is a struct at compile-time
    const type_info = @typeInfo(Payload);
    if (type_info != .Struct) {
        @compileError("Payload must be a struct, got: " ++ @typeName(Payload));
    }

    // Generate the parser function at compile time
    const AutoParser = struct {
        fn parse(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Payload {
            const fields = std.meta.fields(Payload);

            // 1. Validate Argument Count
            if (args.len < fields.len) {
                const msg = std.fmt.comptimePrint(
                    "Expected {d} arguments, got fewer",
                    .{fields.len},
                );
                _ = ctx.throwTypeError(msg);
                return error.InvalidArgCount;
            }

            var payload: Payload = undefined;

            // 2. Iterate over fields and convert automatically
            inline for (fields, 0..) |field, i| {
                const arg = args[i];
                const T = field.type;

                // A. Handle all common integer types
                if (T == i8 or T == i16 or T == i32 or T == i64 or
                    T == u8 or T == u16 or T == u32 or T == u64 or
                    T == isize or T == usize)
                {
                    if (@bitSizeOf(T) <= 32) {
                        // Use JS_ToInt32 for 32-bit and smaller
                        var val: i32 = 0;
                        if (qjs.JS_ToInt32(ctx.ptr, &val, arg) != 0) {
                            _ = ctx.throwTypeError("Expected number for field '" ++ field.name ++ "'");
                            return error.JSException;
                        }
                        @field(payload, field.name) = @intCast(val);
                    } else {
                        // Use JS_ToInt64 for 64-bit
                        var val: i64 = 0;
                        if (qjs.JS_ToInt64(ctx.ptr, &val, arg) != 0) {
                            _ = ctx.throwTypeError("Expected number for field '" ++ field.name ++ "'");
                            return error.JSException;
                        }
                        @field(payload, field.name) = @intCast(val);
                    }
                }
                // B. Handle Floats
                else if (T == f32 or T == f64) {
                    var val: f64 = 0;
                    if (qjs.JS_ToFloat64(ctx.ptr, &val, arg) != 0) {
                        _ = ctx.throwTypeError("Expected number for field '" ++ field.name ++ "'");
                        return error.JSException;
                    }
                    @field(payload, field.name) = if (T == f32) @floatCast(val) else val;
                }
                // C. Handle Strings (Critical: Stack -> Heap transfer)
                else if (T == []u8 or T == []const u8) {
                    // Get slice from JS (temporary, will be freed)
                    const raw_str = try ctx.toZString(arg);
                    defer ctx.freeZString(raw_str);

                    // Deep copy to heap allocator
                    // This is the critical "memory boundary" crossing!
                    const heap_str = try loop.allocator.dupe(u8, raw_str);
                    @field(payload, field.name) = heap_str;
                }
                // D. Handle Booleans
                else if (T == bool) {
                    const val = qjs.JS_ToBool(ctx.ptr, arg);
                    // JS_ToBool returns: 1 (true), 0 (false), -1 (exception)
                    @field(payload, field.name) = (val == 1);
                } else {
                    // Compile error with helpful message
                    @compileError(std.fmt.comptimePrint(
                        "Unsupported type in Payload field '{s}': {s}\n" ++
                            "Supported types:\n" ++
                            "  - Integers: i8, i16, i32, i64, u8, u16, u32, u64, isize, usize\n" ++
                            "  - Floats: f32, f64\n" ++
                            "  - Strings: []const u8, []u8\n" ++
                            "  - Boolean: bool\n" ++
                            "For complex types, use async_bridge.zig with manual parser.",
                        .{ field.name, @typeName(T) },
                    ));
                }
            }

            return payload;
        }
    };

    // Delegate to async_bridge with our auto-generated parser
    return AsyncBridge.bindAsync(Payload, AutoParser.parse, workFn);
}

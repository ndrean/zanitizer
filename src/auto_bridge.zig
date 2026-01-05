const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const AsyncBridge = @import("async_bridge.zig");

/// AUTOMATIC async binding generator
/// Generates parser function at compile-time by inspecting Payload struct fields
///
/// DESIGN:
/// - Parser is generated based on struct field order and types
/// - JavaScript args[i] maps to Payload.field[i]
/// - String fields are automatically heap-allocated (using loop.allocator)
/// - Worker function must free owned string fields
///
/// ⚠️ CRITICAL MEMORY CONTRACT:
/// AutoBridge allocates memory for ALL string fields in your Payload struct.
/// Your worker function MUST free these fields, or you will leak memory!
///
/// Example:
///   const FileTask = struct {
///       path: []const u8,      // ← AutoBridge allocates this
///       content: []const u8,   // ← AutoBridge allocates this
///   };
///
///   fn doWriteFile(allocator: Allocator, task: FileTask) ![]u8 {
///       defer allocator.free(task.path);     // ← YOU MUST FREE!
///       defer allocator.free(task.content);  // ← YOU MUST FREE!
///       // ... do work ...
///   }
///
/// LIMITATIONS:
/// - Field order MUST match JavaScript argument order
/// - No support for complex objects (use manual parser for those)
/// - No support for optional arguments (all fields required)
/// - No support for variadic arguments
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
    // Validate Payload is a struct
    const type_info = @typeInfo(Payload);
    switch (type_info) {
        .@"struct" => {},
        else => @compileError("Payload must be a struct, got: " ++ @typeName(Payload)),
    }

    // Memory contract is documented in the docstring above
    // See docs/memory_contract.md for full details

    // Generate the parser function at compile-time
    const AutoParser = struct {
        fn parse(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Payload {
            // Detect parsing mode:
            // - If 1 arg and it's an object → Object mode (parse properties)
            // - Otherwise → Positional mode (args map to fields by index)
            if (args.len == 1 and ctx.isObject(args[0])) {
                return try parseFromObject(loop, ctx, args[0]);
            } else {
                return try parseFromPositional(loop, ctx, args);
            }
        }

        /// Parse payload from a single JavaScript object's properties
        fn parseFromObject(loop: *EventLoop, ctx: zqjs.Context, obj: zqjs.Value) !Payload {
            const fields = std.meta.fields(Payload);
            var payload: Payload = undefined;

            inline for (fields) |field| {
                const T = field.type;

                // Get property from JS object
                const prop = ctx.getPropertyStr(obj, field.name ++ "");
                defer ctx.freeValue(prop);

                // Check if property exists
                if (ctx.isUndefined(prop)) {
                    _ = ctx.throwTypeError("Missing required property: " ++ field.name);
                    return error.MissingProperty;
                }

                // Convert based on type
                if (comptime isIntegerType(T)) {
                    @field(payload, field.name) = try parseInteger(T, ctx, prop);
                } else if (comptime isFloatType(T)) {
                    @field(payload, field.name) = try parseFloat(T, ctx, prop);
                } else if (comptime isStringType(T)) {
                    @field(payload, field.name) = try parseString(loop, ctx, prop);
                } else if (T == bool) {
                    @field(payload, field.name) = parseBoolean(ctx, prop);
                } else {
                    @compileError(std.fmt.comptimePrint(
                        "Unsupported type in Payload field '{s}': {s}",
                        .{ field.name, @typeName(T) },
                    ));
                }
            }

            return payload;
        }

        /// Parse payload from positional arguments (original behavior)
        fn parseFromPositional(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !Payload {
            const fields = std.meta.fields(Payload);

            // Validate argument count
            if (args.len < fields.len) {
                _ = ctx.throwTypeError("Not enough arguments");
                return error.InvalidArgCount;
            }

            var payload: Payload = undefined;

            // Iterate over struct fields and convert JS args automatically
            inline for (fields, 0..) |field, i| {
                const arg = args[i];
                const T = field.type;

                // Handle different types automatically
                if (comptime isIntegerType(T)) {
                    @field(payload, field.name) = try parseInteger(T, ctx, arg);
                } else if (comptime isFloatType(T)) {
                    @field(payload, field.name) = try parseFloat(T, ctx, arg);
                } else if (comptime isStringType(T)) {
                    @field(payload, field.name) = try parseString(loop, ctx, arg);
                } else if (T == bool) {
                    @field(payload, field.name) = parseBoolean(ctx, arg);
                } else {
                    @compileError(std.fmt.comptimePrint(
                        "Unsupported type in Payload field '{s}': {s}\n" ++
                            "Supported types: integers (i8-i64, u8-u64, isize, usize), " ++
                            "floats (f32, f64), strings ([]const u8, []u8), bool",
                        .{ field.name, @typeName(T) },
                    ));
                }
            }

            return payload;
        }
    };

    // Delegate to manual async_bridge with our auto-generated parser
    return AsyncBridge.bindAsync(Payload, AutoParser.parse, workFn);
}

// ============================================================================
// Type Checking Helpers (Compile-time)
// ============================================================================

fn isIntegerType(comptime T: type) bool {
    return switch (T) {
        i8, i16, i32, i64, isize, u8, u16, u32, u64, usize => true,
        else => false,
    };
}

fn isFloatType(comptime T: type) bool {
    return T == f32 or T == f64;
}

fn isStringType(comptime T: type) bool {
    return T == []const u8 or T == []u8;
}

// ============================================================================
// Type Converters (Runtime)
// ============================================================================

/// Parse integer from JS value
fn parseInteger(comptime T: type, ctx: zqjs.Context, arg: zqjs.Value) !T {
    // Check if it's actually a number
    if (!ctx.isNumber(arg)) {
        _ = ctx.throwTypeError("Expected number");
        return error.TypeError;
    }

    // Use appropriate QuickJS conversion
    if (@bitSizeOf(T) <= 32) {
        // 32-bit or smaller: use JS_ToInt32
        var val: i32 = 0;
        if (qjs.JS_ToInt32(ctx.ptr, &val, arg) != 0) {
            return error.JSException;
        }
        return @intCast(val);
    } else {
        // 64-bit: use JS_ToInt64
        var val: i64 = 0;
        if (qjs.JS_ToInt64(ctx.ptr, &val, arg) != 0) {
            return error.JSException;
        }
        return @intCast(val);
    }
}

/// Parse float from JS value
fn parseFloat(comptime T: type, ctx: zqjs.Context, arg: zqjs.Value) !T {
    if (!ctx.isNumber(arg)) {
        _ = ctx.throwTypeError("Expected number");
        return error.TypeError;
    }

    var val: f64 = 0;
    if (qjs.JS_ToFloat64(ctx.ptr, &val, arg) != 0) {
        return error.JSException;
    }

    if (T == f32) {
        return @floatCast(val);
    } else {
        return val;
    }
}

/// Parse string from JS value
/// CRITICAL: Allocates heap memory using loop.allocator
/// Worker function MUST free this memory!
fn parseString(loop: *EventLoop, ctx: zqjs.Context, arg: zqjs.Value) ![]const u8 {
    if (!ctx.isString(arg)) {
        _ = ctx.throwTypeError("Expected string");
        return error.TypeError;
    }

    // Get temporary C string from JS
    const temp_str = try ctx.toCString(arg);
    defer ctx.freeCString(temp_str);

    // CRITICAL: Deep copy to heap
    // This crosses the memory boundary: JS temp -> Zig heap
    const heap_str = try loop.allocator.dupe(u8, std.mem.span(temp_str));

    return heap_str;
}

/// Parse boolean from JS value
fn parseBoolean(ctx: zqjs.Context, arg: zqjs.Value) bool {
    // JS_ToBool returns: 1 (true), 0 (false), or -1 (exception)
    const val = qjs.JS_ToBool(ctx.ptr, arg);
    return val == 1;
}

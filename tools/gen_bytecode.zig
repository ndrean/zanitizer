//! Bytecode Generator Tool
//!
//! Compiles JavaScript source files to QuickJS bytecode.
//! Uses the same QuickJS library as zexplorer for compatibility.
//!
//! Usage:
//!   zig build gen-bytecode
//!   ./zig-out/bin/gen-bytecode <input.js> <output.bc>

const std = @import("std");
const qjs = @cImport({
    @cInclude("quickjs.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <input.js> <output.bc>\n", .{args[0]});
        std.debug.print("\nCompiles JavaScript to QuickJS bytecode.\n", .{});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("  {s} vendor/js_cache/preact.mjs vendor/bytecode/preact.bc\n", .{args[0]});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];

    // Read source file
    const source = std.fs.cwd().readFileAlloc(allocator, input_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ input_path, err });
        return;
    };
    defer allocator.free(source);

    std.debug.print("Compiling: {s} ({d} bytes)\n", .{ input_path, source.len });

    // Initialize QuickJS runtime
    const rt = qjs.JS_NewRuntime() orelse {
        std.debug.print("Failed to create QuickJS runtime\n", .{});
        return;
    };
    defer qjs.JS_FreeRuntime(rt);

    const ctx = qjs.JS_NewContext(rt) orelse {
        std.debug.print("Failed to create QuickJS context\n", .{});
        return;
    };
    defer qjs.JS_FreeContext(ctx);

    // Compile to bytecode (module mode, compile only)
    const flags: c_int = qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY;
    const result = qjs.JS_Eval(
        ctx,
        source.ptr,
        source.len,
        input_path.ptr,
        flags,
    );

    if (qjs.JS_IsException(result)) {
        std.debug.print("Compilation error:\n", .{});
        const exception = qjs.JS_GetException(ctx);
        defer qjs.JS_FreeValue(ctx, exception);

        const str = qjs.JS_ToCString(ctx, exception);
        if (str != null) {
            std.debug.print("  {s}\n", .{str});
            qjs.JS_FreeCString(ctx, str);
        }
        return;
    }
    defer qjs.JS_FreeValue(ctx, result);

    // Serialize to bytecode
    var bc_size: usize = undefined;
    const bc_flags: c_int = qjs.JS_WRITE_OBJ_BYTECODE | qjs.JS_WRITE_OBJ_STRIP_SOURCE;
    const bc_ptr = qjs.JS_WriteObject(ctx, &bc_size, result, bc_flags);

    if (bc_ptr == null) {
        std.debug.print("Failed to serialize bytecode\n", .{});
        return;
    }
    defer qjs.js_free(ctx, bc_ptr);

    const bytecode = bc_ptr[0..bc_size];

    // Write bytecode file
    const file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
        std.debug.print("Error creating {s}: {}\n", .{ output_path, err });
        return;
    };
    defer file.close();

    file.writeAll(bytecode) catch |err| {
        std.debug.print("Error writing bytecode: {}\n", .{err});
        return;
    };

    std.debug.print("Output: {s} ({d} bytes)\n", .{ output_path, bytecode.len });
    std.debug.print("Compression: {d:.1}% of source\n", .{
        @as(f64, @floatFromInt(bytecode.len)) / @as(f64, @floatFromInt(source.len)) * 100,
    });
}

const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ScriptEngine = z.ScriptEngine;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    try textEncodingDemo(gpa, sandbox_root);
}

fn textEncodingDemo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== TextEncoder/TextDecoder Demo ===\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js = @embedFile("text_encoding.js");

    const result = engine.eval(js, "text_encoding_demo", .module) catch |err| {
        z.print("Eval error: {}\n", .{err});
        return err;
    };

    if (engine.ctx.isException(result)) {
        const ex = engine.ctx.getException();
        const str = engine.ctx.toCString(ex) catch "unknown error";
        z.print("JS Exception: {s}\n", .{str});
        engine.ctx.freeCString(str);
        engine.ctx.freeValue(ex);
        return;
    }
    defer engine.ctx.freeValue(result);

    engine.run() catch |err| {
        z.print("Run error: {}\n", .{err});
        return err;
    };

    z.print("\nTextEncoder/TextDecoder implementation verified:\n", .{});
    z.print("  - TextEncoder.encode() -> Uint8Array\n", .{});
    z.print("  - TextEncoder.encodeInto()\n", .{});
    z.print("  - TextDecoder.decode() -> string\n", .{});
    z.print("  - encoding, fatal, ignoreBOM properties\n", .{});
}

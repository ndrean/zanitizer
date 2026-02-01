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

    try js_framework_1_bench(gpa, sandbox_root);
}

fn js_framework_1_bench(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== JS-framework-1 --------------------------------\n\n", .{});

    const start = std.time.nanoTimestamp();

    const html = @embedFile("js-bench-2.html");
    try engine.loadHTML(html);

    const js = @embedFile("js-bench-2.js");
    const val1 = try engine.evalModule(js, "<class>");
    engine.ctx.freeValue(val1);

    const clicker = @embedFile("js-bench-2-clicker.js");
    const val2 = try engine.evalModule(clicker, "<clicker.js>");
    defer engine.ctx.freeValue(val2);

    const end = std.time.nanoTimestamp();
    const ms = @divFloor(end - start, 1_000);
    std.debug.print("\n⚡️ Zig Engine Time: {d}ns\n\n", .{ms});
}

const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ScriptEngine = z.ScriptEngine;
const ZxpRuntime = z.ZxpRuntime;

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

    try testRun(gpa, sandbox_root);
}

fn testRun(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var start = std.time.nanoTimestamp();
    var zxp_rt = try ZxpRuntime.init(allocator, sbx);
    defer zxp_rt.deinit();
    var engine = try ScriptEngine.init(allocator, zxp_rt);
    defer engine.deinit();
    var end = std.time.nanoTimestamp();
    var ms = @divFloor(end - start, 1_000);
    std.debug.print("\n⚡️ Zig Engine Boot Time: {d}ns\n\n", .{ms});

    z.print("\n=== JS-framework-Bau -----------------------------\n\n", .{});
    start = std.time.nanoTimestamp();
    const html = @embedFile("js-bench-bau.html");

    try engine.loadHTML(html);
    try engine.executeScripts(allocator, ".");
    try engine.run();

    end = std.time.nanoTimestamp();
    ms = @divFloor(end - start, 1_000);
    std.debug.print("\n⚡️ Zig Engine Execution Time: {d}ns\n\n", .{ms});
}

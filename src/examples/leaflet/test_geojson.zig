const std = @import("std");
const builtin = @import("builtin");
const z = @import("zxp");
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
        _ = .ok == debug_allocator.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    try run_test(gpa, sandbox_root);
}

fn run_test(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var zxp_rt = try ZxpRuntime.init(allocator, sbx);
    defer zxp_rt.deinit();
    var engine = try ScriptEngine.init(allocator, zxp_rt);
    defer engine.deinit();

    const html = @embedFile("test_geojson.html");
    try engine.loadPage(html, .{});
    try engine.run();
}

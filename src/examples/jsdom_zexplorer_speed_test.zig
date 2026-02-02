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

    try bench(gpa, sandbox_root);
}

fn bench(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== JS-simple-bench --------------------------------\n\n", .{});

    const start = std.time.nanoTimestamp();
    // const file = try std.fs.cwd().openFile("src/bench.html", .{});
    // defer file.close();
    // const html = try file.readToEndAlloc(allocator, 1024);
    const html = @embedFile("jsdom_zexplorer_speed_test.html");
    try engine.loadHTML(html);
    try engine.executeScripts(allocator, ".");

    // const js = @embedFile("jsdom_zexplorer_speed_test.js");
    // const val = try engine.evalModule(js, "<bench.js>");
    // defer engine.ctx.freeValue(val);

    const end = std.time.nanoTimestamp();
    const ms = @divFloor(end - start, 1_000_000);
    std.debug.print("\n⚡️ Zexplorer Engine Total Time: {d}ms\n\n", .{ms});
}

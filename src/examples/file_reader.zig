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

    try fileReaderDemo(gpa, sandbox_root);
}

fn fileReaderDemo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== File System API Demo ----------\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const html = @embedFile("file_reader.html");
    try engine.loadHTML(html);
    try engine.executeScripts(allocator, ".");

    try engine.run();
}

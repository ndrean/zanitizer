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

    try run_test(gpa, sandbox_root);
}

fn run_test(gpa: std.mem.Allocator, sandbox_root: []const u8) !void {
    var engine = try ScriptEngine.init(gpa, sandbox_root);
    defer engine.deinit();

    const html = @embedFile("test_react.html");
    try engine.loadHTML(html);
    try engine.executeScripts(gpa, ".");
    engine.run() catch |err| {
        z.print("Run error: {}\n", .{err});
        return err;
    };
    const root = z.getElementById(engine.dom.doc, "root");
    try z.prettyPrint(gpa, z.elementToNode(root.?));
}

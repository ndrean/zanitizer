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

    try runBau(gpa, sandbox_root);
}

fn runBau(gpa: std.mem.Allocator, sbx: []const u8) !void {
    var zxp_rt = try ZxpRuntime.init(gpa, sbx);
    defer zxp_rt.deinit();
    var engine = try ScriptEngine.init(gpa, zxp_rt);
    defer engine.deinit();
    const html = @embedFile("test_bau.html");
    try engine.loadHTML(html);
    try engine.executeScripts(gpa, ".");
    engine.run() catch |err| {
        z.print("Run error: {}\n", .{err});
        return err;
    };
    // engine.processJobs();
    // const root = z.getElementById(engine.dom.doc, "root");
    const app = z.getElementById(engine.dom.doc, "app");
    try z.prettyPrint(gpa, z.elementToNode(app.?));
}

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

    // Create a test file to upload
    const test_file_path = "test_upload.txt";
    const test_content = "This is a test file for disk streaming upload.\nIt demonstrates zero-copy file uploads using curl's MIME API.\nThe file is streamed directly from disk without loading into memory.";

    {
        const file = try std.fs.cwd().createFile(test_file_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(test_file_path) catch {};

    try demoWorker(gpa, sandbox_root);
}

fn demoWorker(allocator: std.mem.Allocator, sbx: []const u8) !void {
    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    z.print("\n=== Worker Thread Demo ------------------------\n\n", .{});

    const source = try std.fs.cwd().readFileAlloc(allocator, "src/examples/test-worker_main-thread.js", 1024 * 1024);
    defer allocator.free(source);

    const val = try engine.evalModule(source, "<main_with_worker.js>");

    engine.ctx.freeValue(val);

    try engine.run();
}

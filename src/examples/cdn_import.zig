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

    try cdnImport(gpa, sandbox_root);
}

fn cdnImport(allocator: std.mem.Allocator, sbx: []const u8) !void {
    // Trigger recompile on HTML change (v4)
    const html = @embedFile("cdn_import.html");

    const engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    try engine.loadHTML(html);
    try engine.loadExternalStylesheets(".");
    try engine.executeScripts(allocator, ".");

    try engine.run();

    const doc = engine.dom.doc;
    const body = z.bodyElement(doc).?;

    // Show body background color from CSS
    const computed_bgc = try z.getComputedStyle(allocator, body, "background-color");
    if (computed_bgc) |bgc| {
        z.print("[Zig] body background-color: {s}\n", .{bgc});
        allocator.free(bgc);
    }

    // Show title element with animate.css classes
    const title = try z.querySelector(allocator, doc, "title") orelse return error.NoTitle;
    const myclassList = z.classList_zc(title);
    z.print("[Zig] title classList: {s}\n", .{myclassList});

    const prop = try z.getComputedStyle(allocator, title, "animation-name") orelse return error.NoClass;
    defer allocator.free(prop);
    z.print("[Zig] title animation-name: {s}\n", .{prop});

    // Show React-rendered content in #root
    z.print("\n[Zig] === React rendered DOM ===\n", .{});
    if (try z.querySelector(allocator, doc, "#root")) |root_el| {
        try z.prettyPrint(allocator, @ptrCast(root_el));
    } else {
        z.print("[Zig] No #root element found\n", .{});
    }

    // Also show full document
    z.print("\n[Zig] === Full document ===\n", .{});
    try z.prettyPrint(allocator, z.documentRoot(doc).?);
}

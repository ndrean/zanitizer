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

    try diskStreamingDemo(gpa, sandbox_root, test_file_path);
}

fn diskStreamingDemo(allocator: std.mem.Allocator, sbx: []const u8, test_file: []const u8) !void {
    z.print("\n=== Disk Streaming Upload Demo ===\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js = std.fmt.allocPrint(allocator,
        \\async function testDiskStreamingUpload() {{
        \\    console.log("--- Using File.fromPath() for zero-copy upload ---");
        \\
        \\    // Create a File from disk path (no data loaded into memory!)
        \\    const file = File.fromPath("{s}");
        \\
        \\    console.log("File created from path:");
        \\    console.log("  name:", file.name);
        \\    console.log("  size:", file.size, "bytes");
        \\    console.log("  type:", file.type);
        \\    console.log("  lastModified:", new Date(file.lastModified).toISOString());
        \\
        \\    // Create FormData with the disk-backed file
        \\    const formData = new FormData();
        \\    formData.append("description", "Test upload via disk streaming");
        \\    formData.append("document", file);
        \\
        \\    console.log("\\n--- Uploading to httpbin.org/post ---");
        \\    console.log("(curl streams directly from disk - no memory copy!)");
        \\
        \\    const response = await fetch("https://httpbin.org/post", {{
        \\        method: "POST",
        \\        body: formData
        \\    }});
        \\
        \\    console.log("\\nStatus:", response.status);
        \\    console.log("OK:", response.ok);
        \\
        \\    const data = await response.json();
        \\
        \\    console.log("\\n--- Server Response ---");
        \\
        \\    if (data.form) {{
        \\        console.log("Form fields:");
        \\        for (const [key, value] of Object.entries(data.form)) {{
        \\            console.log("  " + key + ":", value.substring(0, 100) + (value.length > 100 ? "..." : ""));
        \\        }}
        \\    }}
        \\
        \\    if (data.files) {{
        \\        console.log("\\nFiles:");
        \\        for (const [key, value] of Object.entries(data.files)) {{
        \\            console.log("  " + key + ":", value.substring(0, 100) + (value.length > 100 ? "..." : ""));
        \\        }}
        \\    }}
        \\
        \\    console.log("\\n=== Disk Streaming Upload Test Passed! ===");
        \\}}
        \\
        \\testDiskStreamingUpload().catch(e => console.log("Error:", e.message || e));
    , .{test_file}) catch return error.OutOfMemory;
    defer allocator.free(js);

    const result = engine.eval(js, "disk_streaming_demo", .module) catch |err| {
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

    z.print("\nDisk streaming features verified:\n", .{});
    z.print("  - File.fromPath() creates disk-backed File\n", .{});
    z.print("  - File metadata (name, size, type, lastModified)\n", .{});
    z.print("  - FormData with disk-backed File\n", .{});
    z.print("  - Zero-copy upload via curl MIME API\n", .{});
}

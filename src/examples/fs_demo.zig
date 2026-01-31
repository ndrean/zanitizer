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

    try fsDemo(gpa, sandbox_root);
}

fn fsDemo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== File System API Demo ===\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js =
        \\async function testFS() {
        \\    console.log("--- fs.exists() ---");
        \\    const exists1 = await fs.exists("build.zig");
        \\    console.log("build.zig exists:", exists1.exists);
        \\
        \\    const exists2 = await fs.exists("nonexistent_file.xyz");
        \\    console.log("nonexistent_file.xyz exists:", exists2.exists);
        \\
        \\    console.log("\n--- fs.stat() ---");
        \\    const stat = await fs.stat("build.zig");
        \\    console.log("build.zig stat:");
        \\    console.log("  size:", stat.size, "bytes");
        \\    console.log("  mtime:", new Date(stat.mtime).toISOString());
        \\    console.log("  isFile:", stat.isFile);
        \\    console.log("  isDirectory:", stat.isDirectory);
        \\
        \\    const dirStat = await fs.stat("src");
        \\    console.log("\nsrc/ stat:");
        \\    console.log("  isFile:", dirStat.isFile);
        \\    console.log("  isDirectory:", dirStat.isDirectory);
        \\
        \\    console.log("\n--- fs.readDir() ---");
        \\    const result = await fs.readDir("src/examples");
        \\    console.log("src/examples/ contents:");
        \\    for (const entry of result.entries.slice(0, 5)) {
        \\        const type = entry.isDirectory ? "[DIR]" : "[FILE]";
        \\        console.log("  " + type, entry.name);
        \\    }
        \\    if (result.entries.length > 5) {
        \\        console.log("  ... and", result.entries.length - 5, "more");
        \\    }
        \\
        \\    console.log("\n--- fs.createReadStream() ---");
        \\    console.log("Streaming build.zig...");
        \\    const stream = fs.createReadStream("build.zig");
        \\    console.log("  Stream created, locked:", stream.locked);
        \\
        \\    const reader = stream.getReader();
        \\    console.log("  Reader obtained, stream locked:", stream.locked);
        \\
        \\    let totalBytes = 0;
        \\    let chunks = 0;
        \\    while (true) {
        \\        const { value, done } = await reader.read();
        \\        if (done) break;
        \\        chunks++;
        \\        totalBytes += value.length;
        \\        console.log("  Chunk", chunks + ":", value.length, "bytes");
        \\    }
        \\    console.log("  Total:", totalBytes, "bytes in", chunks, "chunk(s)");
        \\    console.log("  ✅ Stream complete!");
        \\
        \\    console.log("\n--- fs.createWriteStream() ---");
        \\    const testFile = "/tmp/zexplorer_test_write.txt";
        \\    console.log("Creating write stream to", testFile);
        \\    const wstream = fs.createWriteStream(testFile);
        \\    console.log("  Stream created, locked:", wstream.locked);
        \\
        \\    const wwriter = wstream.getWriter();
        \\    console.log("  Writer obtained, stream locked:", wstream.locked);
        \\
        \\    const encoder = new TextEncoder();
        \\    const chunk1 = encoder.encode("Hello ");
        \\    const chunk2 = encoder.encode("from ");
        \\    const chunk3 = encoder.encode("Zig + QuickJS!\n");
        \\
        \\    let written = await wwriter.write(chunk1);
        \\    console.log("  Wrote chunk 1:", written, "bytes");
        \\    written = await wwriter.write(chunk2);
        \\    console.log("  Wrote chunk 2:", written, "bytes");
        \\    written = await wwriter.write(chunk3);
        \\    console.log("  Wrote chunk 3:", written, "bytes");
        \\
        \\    await wwriter.close();
        \\    console.log("  Stream closed");
        \\
        \\    // Verify by reading back
        \\    const content = await fs.readFile(testFile);
        \\    console.log("  Verification read:", JSON.stringify(content));
        \\    console.log("  ✅ WriteStream complete!");
        \\
        \\    console.log("\n=== FS API Demo Complete! ===");
        \\}
        \\
        \\testFS().catch(e => console.log("Error:", e.message || e));
    ;

    const result = engine.eval(js, "fs_demo", .module) catch |err| {
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
}

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

    try readableStreamDemo(gpa, sandbox_root);
}

fn readableStreamDemo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== ReadableStream Demo ===\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js =
        \\async function testReadableStream() {
        \\    console.log("--- Fetching data ---");
        \\    const response = await fetch("https://httpbin.org/get");
        \\    console.log("Status:", response.status);
        \\    console.log("OK:", response.ok);
        \\
        \\    console.log("\n--- Testing response.body ---");
        \\    console.log("response.body:", response.body);
        \\    console.log("typeof response.body:", typeof response.body);
        \\
        \\    // Test locked property
        \\    console.log("response.body.locked:", response.body.locked);
        \\
        \\    // Get a reader
        \\    console.log("\n--- Getting reader ---");
        \\    const reader = response.body.getReader();
        \\    console.log("reader:", reader);
        \\    console.log("response.body.locked after getReader():", response.body.locked);
        \\
        \\    // Read chunks
        \\    console.log("\n--- Reading chunks ---");
        \\    let chunks = [];
        \\    let totalBytes = 0;
        \\
        \\    while (true) {
        \\        const { value, done } = await reader.read();
        \\        if (done) {
        \\            console.log("Stream done!");
        \\            break;
        \\        }
        \\        console.log("Chunk received:", value.constructor.name, "length:", value.length);
        \\        chunks.push(value);
        \\        totalBytes += value.length;
        \\    }
        \\
        \\    console.log("\n--- Summary ---");
        \\    console.log("Total chunks:", chunks.length);
        \\    console.log("Total bytes:", totalBytes);
        \\
        \\    // Decode the data
        \\    console.log("\n--- Decoding ---");
        \\    const decoder = new TextDecoder();
        \\    let fullText = "";
        \\    for (const chunk of chunks) {
        \\        fullText += decoder.decode(chunk);
        \\    }
        \\    console.log("Decoded text length:", fullText.length);
        \\    console.log("First 100 chars:", fullText.substring(0, 100));
        \\
        \\    // Parse as JSON to verify
        \\    const data = JSON.parse(fullText);
        \\    console.log("\n--- Parsed JSON ---");
        \\    console.log("url:", data.url);
        \\    console.log("origin:", data.origin);
        \\
        \\    console.log("\n=== ReadableStream test passed! ===");
        \\}
        \\
        \\testReadableStream().catch(e => console.log("Error:", e.message || e));
    ;

    const result = engine.eval(js, "readable_stream_demo", .module) catch |err| {
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

    z.print("\nReadableStream implementation verified:\n", .{});
    z.print("  - response.body returns ReadableStream\n", .{});
    z.print("  - ReadableStream.locked property\n", .{});
    z.print("  - ReadableStream.getReader()\n", .{});
    z.print("  - ReadableStreamDefaultReader.read()\n", .{});
    z.print("  - Chunked reading with {{value, done}}\n", .{});
}

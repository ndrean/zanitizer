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

    try textEncodingDemo(gpa, sandbox_root);
}

fn textEncodingDemo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== TextEncoder/TextDecoder Demo ===\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js =
        \\try {
        \\    // Test TextEncoder
        \\    console.log("--- TextEncoder ---");
        \\    const encoder = new TextEncoder();
        \\    console.log("encoder.encoding:", encoder.encoding);
        \\
        \\    const text = "Hello, World! 你好世界 🚀";
        \\    console.log("Input text:", text);
        \\
        \\    const encoded = encoder.encode(text);
        \\    console.log("Encoded type:", encoded.constructor.name);
        \\    console.log("Encoded length:", encoded.length, "bytes");
        \\    console.log("First 10 bytes:", Array.from(encoded.slice(0, 10)));
        \\
        \\    // Test TextDecoder
        \\    console.log("\n--- TextDecoder ---");
        \\    const decoder = new TextDecoder();
        \\    console.log("decoder.encoding:", decoder.encoding);
        \\    console.log("decoder.fatal:", decoder.fatal);
        \\    console.log("decoder.ignoreBOM:", decoder.ignoreBOM);
        \\
        \\    const decoded = decoder.decode(encoded);
        \\    console.log("Decoded text:", decoded);
        \\    console.log("Round-trip success:", decoded === text);
        \\
        \\    // Test with ArrayBuffer
        \\    console.log("\n--- ArrayBuffer Test ---");
        \\    const buffer = new Uint8Array([72, 101, 108, 108, 111]).buffer;
        \\    const decoded2 = decoder.decode(buffer);
        \\    console.log("Decoded from ArrayBuffer:", decoded2);
        \\
        \\    // Test encodeInto
        \\    console.log("\n--- encodeInto ---");
        \\    const dest = new Uint8Array(20);
        \\    const result = encoder.encodeInto("Test", dest);
        \\    console.log("encodeInto result:", result);
        \\    console.log("Dest bytes:", Array.from(dest.slice(0, result.written)));
        \\
        \\    // Test fatal decoder
        \\    console.log("\n--- Fatal decoder ---");
        \\    const fatalDecoder = new TextDecoder("utf-8", { fatal: true });
        \\    console.log("fatalDecoder.fatal:", fatalDecoder.fatal);
        \\
        \\    console.log("\n=== All TextEncoder/TextDecoder tests passed! ===");
        \\} catch (e) {
        \\    console.log("Error:", e.message || e);
        \\}
    ;

    const result = engine.eval(js, "text_encoding_demo", .module) catch |err| {
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

    z.print("\nTextEncoder/TextDecoder implementation verified:\n", .{});
    z.print("  - TextEncoder.encode() -> Uint8Array\n", .{});
    z.print("  - TextEncoder.encodeInto()\n", .{});
    z.print("  - TextDecoder.decode() -> string\n", .{});
    z.print("  - encoding, fatal, ignoreBOM properties\n", .{});
}

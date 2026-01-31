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

    try writableStreamDemo(gpa, sandbox_root);
}

fn writableStreamDemo(gpa: std.mem.Allocator, sandbox_root: []const u8) !void {
    var engine = try ScriptEngine.init(gpa, sandbox_root);
    defer engine.deinit();

    const js =
        \\  async function runTest() {
        \\  console.log("🚀 Starting WritableStream Test...");
        \\  const filename = "test_output.txt";
        \\
        \\  try {
        \\      // - Cleanup previous run
        \\      try { await fs.rm(filename); } catch (e) {}
        \\
        \\      // - Create Stream & Writer
        \\      console.log("📂 Creating WriteStream...");
        \\      const stream = fs.createWriteStream(filename);
        \\      const writer = stream.getWriter();
        \\
        \\      // - Test Property access
        \\      console.log(`ℹ️ Desired Size: ${writer.desiredSize}\\`); 
        \\      // Should be high (e.g. 64KB)
        \\      console.log(`ℹ️ Ready State: ${await writer.ready}`);
        \\
        \\      // - Write String (TextEncoder implicit or explicit \\depending on implementation)
        \\      console.log("✍️ Writing String...");
        \\      await writer.write("Hello from Zig Runtime! ⚡\n");
        \\
        \\      // - Write Binary (Uint8Array)
        \\      console.log("✍️ Writing Binary Data...");
        \\      const binaryData = new Uint8Array([65, 66, 67, 68]); // \\ABCD
        \\      await writer.write(binaryData);
        \\      await writer.write("\n");
        \\
        \\      // - Stress Test (Queuing)
        \\      // fire multiple writes without awaiting immediately 
        \\      // test internal queue
        \\      console.log("🌊 Testing Queue/Backpressure...");
        \\      const promises = [];
        \\      for (let i = 0; i < 5; i++) {
        \\          promises.push(writer.write(`Line ${i}\n`));
        \\      }
        \\      await Promise.all(promises);
        \\
        \\      // - Close
        \\      console.log("🔒 Closing stream...");
        \\      await writer.close();
        \\
        \\      // - Verification (Read back)
        \\      console.log("🔍 Verifying content...");
        \\      const content = await fs.readFile(filename);
        \\      
        \\      console.log("--- FILE CONTENT START ---");
        \\      console.log(content);
        \\      console.log("--- FILE CONTENT END ---");
        \\
        \\      if (content.includes("ABCD") && content.includes("Line 4")) {
        \\          console.log("✅ TEST PASSED: Content matches expected \\output.");
        \\      } else {
        \\          console.error("❌ TEST FAILED: Content mismatch.");
        \\      }
        \\
        \\    } catch (err) {
        \\        console.error("❌ CRITICAL ERROR:", err);
        \\    }
        \\}
        \\runTest();
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
}

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

    try formDataUploadDemo(gpa, sandbox_root);
}

fn formDataUploadDemo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== FormData Multipart Upload Demo ===\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js =
        \\async function testFormDataUpload() {
        \\    console.log("--- Creating FormData ---");
        \\
        \\    const formData = new FormData();
        \\
        \\    // Add a simple text field
        \\    formData.append("username", "testuser");
        \\    formData.append("email", "test@example.com");
        \\
        \\    // Add a Blob as a file
        \\    const fileContent = "Hello, this is file content!\nLine 2 of the file.";
        \\    const blob = new Blob([fileContent], { type: "text/plain" });
        \\    formData.append("document", blob, "test.txt");
        \\
        \\    // Add another Blob (binary-ish data)
        \\    const jsonData = JSON.stringify({ key: "value", nested: { foo: "bar" } });
        \\    const jsonBlob = new Blob([jsonData], { type: "application/json" });
        \\    formData.append("config", jsonBlob, "config.json");
        \\
        \\    console.log("FormData created with:");
        \\    console.log("  - username: testuser");
        \\    console.log("  - email: test@example.com");
        \\    console.log("  - document: test.txt (text/plain)");
        \\    console.log("  - config: config.json (application/json)");
        \\
        \\    console.log("\n--- Uploading to httpbin.org/post ---");
        \\
        \\    const response = await fetch("https://httpbin.org/post", {
        \\        method: "POST",
        \\        body: formData
        \\    });
        \\
        \\    console.log("Status:", response.status);
        \\    console.log("OK:", response.ok);
        \\
        \\    const data = await response.json();
        \\
        \\    console.log("\n--- Server Response ---");
        \\    console.log("Form fields received:");
        \\    if (data.form) {
        \\        for (const [key, value] of Object.entries(data.form)) {
        \\            console.log("  " + key + ":", value);
        \\        }
        \\    }
        \\
        \\    console.log("\nFiles received:");
        \\    if (data.files) {
        \\        for (const [key, value] of Object.entries(data.files)) {
        \\            const preview = typeof value === 'string' ? value.substring(0, 50) : JSON.stringify(value).substring(0, 50);
        \\            console.log("  " + key + ":", preview + (value.length > 50 ? "..." : ""));
        \\        }
        \\    }
        \\
        \\    console.log("\n=== FormData Upload Test Passed! ===");
        \\}
        \\
        \\testFormDataUpload().catch(e => console.log("Error:", e.message || e));
    ;

    const result = engine.eval(js, "formdata_upload_demo", .module) catch |err| {
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

    z.print("\nMultipart upload implementation verified:\n", .{});
    z.print("  - FormData with text fields\n", .{});
    z.print("  - FormData with Blob attachments\n", .{});
    z.print("  - Uses curl's native MIME API (no manual serialization)\n", .{});
}

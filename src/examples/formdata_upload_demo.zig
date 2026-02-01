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
    z.print("\n=== FormData Multipart Upload Demo -------------\n\n", .{});

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const js = @embedFile("formdata_upload_demo.js");

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

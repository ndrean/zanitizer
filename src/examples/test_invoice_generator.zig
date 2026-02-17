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

    try run_test(gpa, sandbox_root);
}

fn run_test(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();
    const script = @embedFile("test_invoice_generator.js");

    const val = try engine.eval(script, "<script>", .global);
    defer engine.ctx.freeValue(val);

    const pdf_bytes = try engine.evalAsyncAs(allocator, []const u8, "generateTestInvoice()", "<invoice>");
    defer allocator.free(pdf_bytes);

    try std.fs.cwd().writeFile(.{
        .sub_path = "test_invoice.pdf",
        .data = pdf_bytes,
    });
}

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

    try purifyDemo(gpa, sandbox_root);
}

fn purifyDemo(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== File System API Demo ===\n\n", .{});

    var timer = try std.time.Timer.start();

    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const dirty = @embedFile("dom_purify.html");

    // const result = engine.eval(js, "<purify>", .module) catch |err| {
    //     z.print("Eval error: {}\n", .{err});
    //     return err;
    // };

    // if (engine.ctx.isException(result)) {
    //     const ex = engine.ctx.getException();
    //     const str = engine.ctx.toCString(ex) catch "unknown error";
    //     z.print("JS Exception: {s}\n", .{str});
    //     engine.ctx.freeCString(str);
    //     engine.ctx.freeValue(ex);
    //     return;
    // }
    // defer engine.ctx.freeValue(result);

    const doc = try z.parseHTML(allocator, dirty);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;

    // Initialize CSS sanitizer for <style> tag sanitization
    var css_sanitizer = try z.CssSanitizer.init(allocator, .{});
    defer css_sanitizer.deinit();

    // Use custom mode with CSS sanitization enabled
    const custom_mode = z.SanitizerMode{
        .custom = z.SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = false, // ← Enable CSS sanitization instead of removal
            .sanitize_inline_styles = true,
            .strict_uri_validation = true,
            .allow_custom_elements = false,
            .allow_framework_attrs = true,
            .sanitize_dom_clobbering = true,
        },
    };

    try z.sanitizeWithCss(
        allocator,
        body,
        custom_mode,
        &css_sanitizer,
    );

    const elapsed_ns = timer.read();
    const elapsed_us = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
    const elapsed_ms = elapsed_us / 1000.0;

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);
    // z.print("{s}\n", .{result});

    std.debug.print("\n=== DOMPurify Benchmark -------\n\n", .{});
    std.debug.print("Input size: {} bytes\n", .{dirty.len});
    std.debug.print("Output size: {} bytes\n", .{result.len});
    std.debug.print("Total Engine time: {d:.3} ms\n", .{elapsed_ms});
    std.debug.print("DOMPurify reference: ~11 ms\n", .{});

    engine.run() catch |err| {
        z.print("Run error: {}\n", .{err});
        return err;
    };
}

const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ScriptEngine = z.ScriptEngine;
const ZxpRuntime = z.ZxpRuntime;

var debug_gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_gpa.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };

    defer if (is_debug) {
        _ = .ok == debug_gpa.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    try vercel(gpa, sandbox_root);
}

fn vercel(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var zxp_rt = try z.ZxpRuntime.init(allocator, sbx);
    defer zxp_rt.deinit();

    var engine = try ScriptEngine.init(allocator, zxp_rt);
    defer engine.deinit();

    const script =
        \\async function testVercel() {
        \\  try {
        \\      await zxp.goto("https://demo.vercel.store");
        \\      await zxp.waitForSelector("a[href^='/product/']");
        \\      const links = document.querySelectorAll("a[href^='/product/']");
        \\      const unique = [...new Set(Array.from(links).map(el => el.getAttribute('href')))];
        \\      const items = unique.map(href => {
        \\        const el = document.querySelector(`a[href='${href}']`);
        \\        return el.textContent.trim();
        \\      });
        \\      return items;
        \\  } catch (err) {
        \\      console.error(err);
        \\  }
        \\}
    ;

    const val = try engine.eval(script, "test_vercel.js", .global);
    defer engine.ctx.freeValue(val);

    const items = try engine.evalAsyncAs(
        allocator,
        []const []const u8,
        "testVercel()",
        "<vercel>",
    );
    defer {
        for (items) |item| allocator.free(item);
        allocator.free(items);
    }

    // Join with newlines for file output
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (items) |item| {
        try buf.appendSlice(allocator, item);
        try buf.append(allocator, '\n');
    }

    try std.fs.cwd().writeFile(
        .{
            .sub_path = "src/examples/vercel-demo/data.txt",
            .data = buf.items,
        },
    );
}

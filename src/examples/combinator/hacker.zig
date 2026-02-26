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

    var zxp_rt = try ZxpRuntime.init(gpa, sandbox_root);
    defer zxp_rt.deinit();
    var engine = try ScriptEngine.init(gpa, zxp_rt);
    defer engine.deinit();

    const script =
        \\async function scrape() {
        \\    url = "https://news.ycombinator.com/newest";
        \\    await zxp.goto(url);
        \\    return Array.from(document.querySelectorAll(".titleline a")).map((a) => [a.textContent, a.href]);
        \\}
    ;

    const val = try engine.eval(script, "<hacker>", .global);
    defer engine.ctx.freeValue(val);

    const items = try engine.evalAsyncAs(gpa, []const []const []const u8, "scrape()", "<scrape>");
    defer {
        for (items) |pair| {
            for (pair) |s| gpa.free(s);
            gpa.free(pair);
        }
        gpa.free(items);
    }

    // Join with newlines for file output
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (items) |pair| {
        for (pair, 0..) |s, i| {
            try buf.appendSlice(gpa, s);
            if (i < pair.len - 1) try buf.append(gpa, '\t');
        }
        try buf.append(gpa, '\n');
    }

    try std.fs.cwd().writeFile(
        .{
            .sub_path = "src/examples/combinator/data.txt",
            .data = buf.items,
        },
    );
}

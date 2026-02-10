const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const sbr = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sbr);

    const js = @embedFile("test_image1.js");

    var engine = try z.ScriptEngine.init(allocator, sbr);
    defer engine.deinit();
    // const val = try engine.evalAsyncAs(allocator, []const u8, js, "t.png");

    const val = try engine.eval(js, "t.png", .global);
    defer engine.ctx.freeValue(val);
    try engine.run();
    const state = engine.ctx.promiseState(val);
    std.debug.print("{any}", .{state});

    const promise_result = engine.ctx.promiseResult(val);
    defer engine.ctx.freeValue(promise_result);
    const result = try engine.ctx.toZString(val);
    std.debug.print("{s}", .{result});
    // try std.testing.expectEqualStrings("Success", val);
}

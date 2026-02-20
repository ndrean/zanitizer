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
        _ = .ok == debug_allocator.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    try run_test(gpa, sandbox_root);
}

fn run_test(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);
    defer engine.deinit();

    const html = @embedFile("test_custom-lit-element.html");
    try engine.loadPage(html, .{});

    // 1. Print initial render
    std.debug.print("\n=== INITIAL RENDER ===\n", .{});
    try z.prettyPrint(allocator, z.bodyNode(engine.dom.doc).?);

    // 2. Paint initial state
    const paint_script =
        \\ const body = document.querySelector("body");
        \\ zxp.paintDOM(body, "zxp.png")
    ;
    const render_val1 = try engine.eval(paint_script, "<render-test1>", .global);
    engine.ctx.freeValue(render_val1);

    // 3. Mutate component state and trigger reactive update
    const reactive_script =
        \\ const badge = globalThis.myActiveBadge;
        \\ Object.defineProperty(badge, 'isConnected', { get: () => true });
        \\ badge.status = 'OFFLINE';
        \\ badge.requestUpdate();
        \\ badge.updateComplete.then(() => {
        \\     console.log("[Lit] updateComplete resolved");
        \\ }).catch(err => {
        \\     console.log("[Lit] FATAL:", err.message);
        \\ });
    ;
    const render_val2 = try engine.eval(reactive_script, "<reactivity-test2>", .global);
    engine.ctx.freeValue(render_val2);

    // 4. Flush microtasks and timers
    try engine.run();

    // 5. Paint updated state
    const paint_script2 =
        \\ const body2 = document.querySelector("body");
        \\ zxp.paintDOM(body2, "zxp_after.png")
    ;
    const render_val3 = try engine.eval(paint_script2, "<render-test2>", .global);
    engine.ctx.freeValue(render_val3);

    // 6. Print updated DOM
    std.debug.print("\n=== REACTIVE DOM OUTPUT ===\n", .{});
    try z.prettyPrint(allocator, z.bodyNode(engine.dom.doc).?);
}

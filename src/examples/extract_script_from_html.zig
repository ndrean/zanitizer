const std = @import("std");
const builtin = @import("builtin");
const z = @import("root.zig");
const zqjs = z.wrapper;
const event_loop_mod = @import("event_loop.zig");
const EventLoop = event_loop_mod.EventLoop;
const DOMBridge = z.dom_bridge.DOMBridge;
const RCtx = @import("runtime_context.zig").RuntimeContext;
const utils = @import("utils.zig");
const ScriptEngine = @import("script_engine.zig").ScriptEngine;
const parseCSV = @import("csv_parser.zig");

const AsyncTask = event_loop_mod.AsyncTask;
const AsyncBridge = @import("async_bridge.zig");
// const NativeBridge = @import("js_native_bridge.zig");
const Pt = @import("js_Point.zig");
const Pt2 = @import("Point2.zig");
const JSWorker = @import("js_worker.zig");
const js_consoleLog = @import("utils.zig").js_consoleLog;

fn extractScript(allocator: std.mem.Allocator) !void {
    var engine = try ScriptEngine.init(allocator);
    defer engine.deinit();

    z.print("\n=== Extract Script from HTML --------------------------------\n\n", .{});

    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <h1>Test</h1>
        \\
        \\  <script>
        \\    function greet(name) {
        \\      return `Hello, ${name}!`;
        \\    }
        \\  </script>
        \\
        \\  <script>var a = 10;</script>
        \\
        \\  <div id="ignore"></div>
        \\
        \\  <script src="jquery.js"></script>
        \\
        \\  <script>
        \\      var b = a + 20; 
        \\      console.log("[JS] Result: ", b);
        \\      console.log("[JS] Evaluate 'greet': ", greet('Zig'));
        \\      b;
        \\  </script>
        \\</body>
        \\</html>
    ;
    try engine.loadHTML(html);
    const c_scripts = try engine.getC_Scripts();
    defer {
        for (c_scripts) |code| allocator.free(code);
        allocator.free(c_scripts);
    }

    // try engine.run(); <-- Not needed for this example as no event loop is used.

    z.print("{}\n", .{c_scripts.len});
    for (c_scripts) |code| {
        const val = try engine.eval(code, "inline_script");
        defer engine.ctx.freeValue(val);
        const res = try engine.ctx.toInt32(val);
        z.print("[Zig] Script result: {d}\n\n", .{res});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try extractScript(allocator);
}

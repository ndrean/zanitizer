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

    try bench(gpa, sandbox_root);
}

fn bench(allocator: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== JS-simple-bench ---------------------------\n\n", .{});

    const values = [_]u32{ 100, 1000, 10000, 20000, 50000 };

    for (values) |v| {
        z.print("[Zig]-> Running with NB={d}\n", .{v});
        const start = std.time.nanoTimestamp();
        var engine = try ScriptEngine.init(allocator, sbx);

        const js =
            \\ let start = performance.now();
            \\ console.log(`Starting DOM creation test with {d} elements`);
            \\ const btn = document.createElement("button");
            \\ const form = document.createElement("form");
            \\ form.appendChild(btn);
            \\ document.body.appendChild(form);
            \\ const mylist = document.createElement("ul");
            \\ for (let i = 1; i <= parseInt({d}); i++) {{
            \\   const item = document.createElement("li");
            \\   item.textContent = "Item " + i * 10;
            \\   item.setAttribute("id", i.toString());
            \\   mylist.appendChild(item);
            \\ }}
            \\ document.body.appendChild(mylist);
            \\
            // \\ let time = performance.now() - start;
            \\
            \\ const lis = document.querySelectorAll("li");
            \\ console.log(lis.length);
            \\
            // \\ start = performance.now();
            \\ let clickCount = 0;
            \\ btn.addEventListener("click", () => {{
            \\  clickCount++;
            \\  btn.setTextContentAsText(`Clicked ${{clickCount}}`);
            \\ }});
            \\
            \\ // Simulate clicks
            \\ for (let i = 0; i < parseInt({d}); i++) {{
            \\   btn.dispatchEvent("click");
            \\ }}
            \\
            \\ const time = performance.now() - start;
            \\
            \\ console.log(
            \\   JSON.stringify({{
            \\     time: time.toFixed(2),
            \\     elementCount: lis.length,
            \\     last_li_id: lis[lis.length - 1].getAttribute("id"),
            \\     last_li_text: lis[lis.length - 1].textContent,
            \\     success: clickCount === parseInt({d}),
            \\   }}),
            \\ );
        ;

        const script = try std.fmt.allocPrint(allocator, js, .{ v, v, v, v });
        defer allocator.free(script);
        const body = try std.fmt.allocPrint(allocator, "<body><script>{s}</script></body>", .{script});
        // z.print("{s}\n", .{body});
        defer allocator.free(body);
        try engine.loadHTML(body);

        try engine.executeScripts(allocator, ".");

        const end = std.time.nanoTimestamp();
        const ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        std.debug.print("\n⚡️ Zexplorer Engine Total Time: {d:.2}ms\n\n", .{ms});

        engine.deinit();
    }
}

const std = @import("std");
const z = @import("zexplorer");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();
    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    var engine = try z.ScriptEngine.init(gpa, sandbox_root);
    defer engine.deinit();

    const html =
        \\<body>
        \\  <p>Hello zexplorer</p>
        \\  <script>
        \\    const p = document.querySelector("p");
        \\    console.log('[JS] ',p.textContent);
        \\  </script>
        \\</body>
    ;

    try engine.loadPage(html, .{});

    try z.prettyPrint(gpa, z.documentRoot(engine.dom.doc).?);
}

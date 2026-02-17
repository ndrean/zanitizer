const std = @import("std");
const z = @import("zexplorer");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer {
        _ = .ok == debug_allocator.deinit();
    }
    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);

    var engine = try z.ScriptEngine.init(gpa, sandbox_root);
    defer engine.deinit();

    const script =
        \\ const div = document.createElement("div");
        \\ const p = document.createElement("p");
        \\ p.textContent = "Hello zexplorer";
        \\ div.appendChild(p);
        \\ document.body.appendChild(div);
        \\ const script = document.createElement("script");
        \\ script.textContent = "const hello = document.querySelector('p').textContent; console.log('[JS]', hello);";
        \\ document.head.appendChild(script);
    ;

    const val = try engine.evalModule(script, "<my-script>");
    defer engine.ctx.freeValue(val);

    try engine.executeScripts(gpa, ".");

    try z.prettyPrint(gpa, z.documentRoot(engine.dom.doc).?);
}

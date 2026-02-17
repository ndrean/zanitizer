const std = @import("std");
const z = @import("zexplorer");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const html = "<div><p>Hi there</p></div>";

    {
        const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
        defer gpa.free(sandbox_root);

        var engine = try z.ScriptEngine.init(gpa, sandbox_root);
        defer engine.deinit();

        const script =
            \\const innerText = document.querySelector("p").textContent;
            \\console.log("[JS]", innerText);
        ;

        try engine.loadHTML(html);
        const val = try engine.evalModule(script, "<script>");
        engine.ctx.freeValue(val);
    }

    {
        var parser = try z.DOMParser.init(gpa);
        defer parser.deinit();
        const doc = try parser.parseFromString(html);
        defer z.destroyDocument(doc);

        const p = try z.querySelector(gpa, z.bodyNode(doc).?, "p");
        const inner_text = z.textContent_zc(z.elementToNode(p.?)); // no allocation

        std.debug.print("[Zig] {s}\n", .{inner_text});
    }
}

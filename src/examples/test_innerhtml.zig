const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const sandbox_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(sandbox_root);

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);
    try z.insertHTML(doc, "<html><head></head><body><div></div></body></html>");

    const html_str = "<h2>Vue Counter (Template)</h2><p id=\"count-display\">Count: 0</p><button id=\"increment-btn\">+1</button>";

    // === Test 1: innerHTML on <div> ===
    std.debug.print("=== Test 1: innerHTML on <div> ===\n", .{});
    {
        const div = try z.querySelector(allocator, doc, "div");

        // const div = try z.createElement(doc, "div");
        // const div_node = z.elementToNode(div);
        // z.appendChild(z.bodyNode(doc).?, div_node);

        try z.setInnerHTML(div.?, html_str);

        const html = try z.innerHTML(allocator, div.?);
        defer allocator.free(html);
        std.debug.print("  innerHTML: {s}\n", .{html});

        var i: usize = 0;
        var child = z.firstChild(z.elementToNode(div.?));
        while (child) |c| : (child = z.nextSibling(c)) {
            std.debug.print("  child[{d}]: {s}\n", .{ i, z.nodeName_zc(c) });
            i += 1;
        }
        std.debug.print("  Total children: {d}\n\n", .{i});
    }

    // === Test 2: innerHTML on <template> (what Vue uses) ===
    std.debug.print("=== Test 2: innerHTML on <template> ===\n", .{});
    {
        const tmpl = try z.createTemplate(doc);
        const tmpl_el = z.templateToElement(tmpl);
        z.appendChild(z.bodyNode(doc).?, z.elementToNode(tmpl_el));

        try z.setInnerHTML(tmpl_el, html_str);

        // Check template.content children (this is what Vue walks)
        const content_node = z.templateContent(tmpl);
        std.debug.print("  template.content node type: {}\n", .{z.nodeType(content_node)});

        var i: usize = 0;
        var child = z.firstChild(content_node);
        while (child) |c| : (child = z.nextSibling(c)) {
            std.debug.print("  content child[{d}]: {s}\n", .{ i, z.nodeName_zc(c) });
            if (i == 0) {
                try std.testing.expectEqualStrings("H2", z.nodeName_zc(c));
            } else if (i == 1) {
                try std.testing.expectEqualStrings("P", z.nodeName_zc(c));
            } else {
                try std.testing.expectEqualStrings("BUTTON", z.nodeName_zc(c));
            }

            // Also walk grandchildren to check nesting
            var j: usize = 0;
            var gchild = z.firstChild(c);
            while (gchild) |gc| : (gchild = z.nextSibling(gc)) {
                try std.testing.expectEqualStrings("#text", z.nodeName_zc(gc));
                std.debug.print("    grandchild[{d}]: {s} = \"{s}\"\n", .{
                    j,
                    z.nodeName_zc(gc),
                    z.textContent_zc(gc),
                });
                j += 1;
            }
            i += 1;
        }
        std.debug.print("  Total content children: {d}\n\n", .{i});
    }

    // === Test 3: innerHTML on <template> with wrapping div (like Vue template) ===
    std.debug.print("=== Test 3: innerHTML on <template> with wrapping <div> ===\n", .{});
    {
        const tmpl2 = try z.createTemplate(doc);
        const tmpl2_el = z.templateToElement(tmpl2);
        z.appendChild(z.bodyNode(doc).?, z.elementToNode(tmpl2_el));

        const wrapped = "<div class=\"counter-app\"><h2>Vue Counter (Template)</h2><p id=\"count-display\">Count: 0</p><button id=\"increment-btn\">+1</button></div>";
        try z.setInnerHTML(tmpl2_el, wrapped);
        try z.prettyPrint(allocator, z.elementToNode(tmpl2_el));

        const content_node = z.templateContent(tmpl2);
        var child = z.firstChild(content_node);
        while (child) |c| : (child = z.nextSibling(c)) {
            std.debug.print("  content child: {s}\n", .{z.nodeName_zc(c)});
            var j: usize = 0;
            var gchild = z.firstChild(c);
            while (gchild) |gc| : (gchild = z.nextSibling(gc)) {
                std.debug.print("    child[{d}]: {s}\n", .{ j, z.nodeName_zc(gc) });
                // Check great-grandchildren
                var k: usize = 0;
                var ggchild = z.firstChild(gc);
                while (ggchild) |ggc| : (ggchild = z.nextSibling(ggc)) {
                    std.debug.print("      grandchild[{d}]: {s}\n", .{ k, z.nodeName_zc(ggc) });
                    k += 1;
                }
                j += 1;
            }
        }
    }
    {
        const wrapped = "<div class=\"counter_app\"><h2>Vue Counter (Template)</h2><p id=\"count-display\">Count: 0</p><button id=\"increment-btn\">+1</button></div>";

        const div = try z.querySelector(allocator, doc, "div");
        try z.setInnerHTML(div.?, wrapped);
        try z.prettyPrint(allocator, z.elementToNode(div.?));
        const inner_div = z.firstElementChild(div.?);

        const h2 = z.firstElementChild(z.elementToNode(inner_div.?));
        try std.testing.expectEqualStrings("H2", z.tagName_zc(h2.?));
        const p = z.nextElementSibling(h2.?);
        try std.testing.expectEqualStrings("P", z.tagName_zc(p.?));
        const btn = z.lastElementChild(inner_div.?);
        try std.testing.expectEqualStrings("BUTTON", z.tagName_zc(btn.?));
    }
    {
        const html =
            \\<html>
            \\    <body>
            \\        <div id="test"></div>
            \\        <script>
            \\        const div = document.getElementById("test");
            \\        div.innerHTML = `
            \\        <div class="counter-app">
            \\            <h2>Vue Counter (Template)</h2>
            \\            <p id="count-display">Count: 0</p>
            \\            <button id="increment-btn">+1</button>
            \\        </div>
            \\        `;
            \\        console.log(div.innerHTML);
            \\        </script>
            \\    </body>
            \\</html>
        ;
        var engine = try z.ScriptEngine.init(allocator, sandbox_root);
        defer engine.deinit();

        try engine.loadHTML(html);
        try engine.executeScripts(allocator, ".");
        const div = z.getElementById(engine.dom.doc, "test");
        const inner_html = try z.innerHTML(allocator, div.?);
        defer allocator.free(inner_html);
        std.debug.print("Final innerHTML from script execution:\n{s}\n", .{inner_html});
        const inner_div = try z.querySelector(allocator, engine.dom.doc, "#test .counter-app");
        try std.testing.expect(inner_div != null);
        const h2 = z.firstElementChild(z.elementToNode(inner_div.?));
        try std.testing.expectEqualStrings("H2", z.tagName_zc(h2.?));
        const p = z.nextElementSibling(h2.?);
        try std.testing.expect(p == null);
    }
}

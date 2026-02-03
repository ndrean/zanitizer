const std = @import("std");
const z = @import("zexplorer");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Test closing tags with digits (like </h1>, </h2>, etc.)
    std.debug.print("=== Testing closing tags with digits ===\n", .{});
    const tests = [_][]const u8{
        "<html><body><script>var a = \"</h>\";</script></body></html>",
        "<html><body><script>var a = \"</h1>\";</script></body></html>",
        "<html><body><script>var a = \"</h2>\";</script></body></html>",
        "<html><body><script>var a = \"</h3>\";</script></body></html>",
        "<html><body><script>var a = \"</br>\";</script></body></html>",
        "<html><body><script>var a = \"</div1>\";</script></body></html>",
        "<html><body><script>var a = \"</x9>\";</script></body></html>",
        "<html><body><script>var a = \"</abc123>\";</script></body></html>",
        // Critical: test the exact Vue pattern
        "<html><body><script>var a = \"</h2><p>test</p>\";</script></body></html>",
    };
    for (tests) |test_html| {
        const test_doc = try z.parseHTML(allocator, test_html);
        defer z.destroyDocument(test_doc);
        const s = z.getElementByTag(z.bodyNode(test_doc).?, .script).?;
        const t = z.textContent_zc(z.elementToNode(s));
        std.debug.print("  Input: {s}\n  Result: \"{s}\"\n\n", .{ test_html, t });
    }
}

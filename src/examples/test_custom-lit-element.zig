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

fn dumpSubtree(node: *z.DomNode, depth: u32) void {
    var child = z.firstChild(node);
    while (child) |c| {
        const nt = z.nodeType(c);
        const ind = @min(depth * 2, 30);
        const spc: [30]u8 = .{' '} ** 30;
        switch (nt) {
            .comment => std.debug.print("{s}COMMENT: \"{s}\"\n", .{ spc[0..ind], z.textContent_zc(c) }),
            .text => {
                const txt = std.mem.trim(u8, z.textContent_zc(c), &std.ascii.whitespace);
                if (txt.len > 0) std.debug.print("{s}TEXT: \"{s}\"\n", .{ spc[0..ind], txt });
            },
            .element => {
                const tag = if (z.nodeToElement(c)) |ce| z.tagName_zc(ce) else "?";
                std.debug.print("{s}<{s}>\n", .{ spc[0..ind], tag });
            },
            else => std.debug.print("{s}{s}\n", .{ spc[0..ind], @tagName(nt) }),
        }
        dumpSubtree(c, depth + 1);
        child = z.nextSibling(c);
    }
}

fn run_test(allocator: std.mem.Allocator, sbx: []const u8) !void {
    var engine = try ScriptEngine.init(allocator, sbx);

    defer engine.deinit();

    const html = @embedFile("test_custom-lit-element.html");
    try engine.loadPage(html, .{});
    // try engine.run();

    // Zig-side deep DOM dump to check for comment nodes
    {
        const body = z.bodyNode(engine.dom.doc).?;
        std.debug.print("\n=== ZIG-SIDE DOM DUMP (all node types) ===\n", .{});
        dumpSubtree(body, 0);
    }

    try z.prettyPrint(allocator, z.bodyNode(engine.dom.doc).?);

    std.debug.print("\n=== MUTATING COMPONENT STATE \n", .{});
    // First check Comment nodes in DOM
    const comment_check =
        \\ const badge = globalThis.myActiveBadge;
        \\ function walkNodes(node, depth) {
        \\     const indent = "  ".repeat(depth);
        \\     const type = node.nodeType;
        \\     const name = node.nodeName || "?";
        \\     const parent = node.parentNode ? node.parentNode.nodeName : "NULL";
        \\     if (type === 8) {
        \\         console.log(indent + "COMMENT: <!--" + node.data + "--> parentNode=" + parent);
        \\     } else if (type === 3) {
        \\         const txt = node.data.trim();
        \\         if (txt) console.log(indent + "TEXT: '" + txt.substring(0,40) + "' parentNode=" + parent);
        \\     } else {
        \\         console.log(indent + name + " parentNode=" + parent);
        \\     }
        \\     let child = node.firstChild;
        \\     while (child) {
        \\         walkNodes(child, depth + 1);
        \\         child = child.nextSibling;
        \\     }
        \\ }
        \\ console.log("\n[Tree] DOM tree of badge element:");
        \\ walkNodes(badge, 0);
        \\
        \\ // Direct test: walk DIV's children one by one
        \\ const div = badge.firstChild;
        \\ if (div && div.nodeType === 1) {
        \\     console.log("\n[Direct] Walking DIV children:");
        \\     let n = div.firstChild;
        \\     let i = 0;
        \\     while (n) {
        \\         console.log("[Direct] child[" + i + "] nodeType=" + n.nodeType + " nodeName=" + n.nodeName);
        \\         if (n.nodeType === 8) console.log("[Direct]   COMMENT data: " + n.data);
        \\         n = n.nextSibling;
        \\         i++;
        \\     }
        \\ } else {
        \\     console.log("[Direct] badge.firstChild:", badge.firstChild, "type:", badge.firstChild ? badge.firstChild.nodeType : "null");
        \\ }
        \\
        \\ // Instrument insertBefore/appendChild to trace Lit's DOM ops during reactive update
        \\ const origInsertBefore = Element.prototype.insertBefore;
        \\ Element.prototype.insertBefore = function(newNode, refNode) {
        \\     const nt = newNode ? newNode.nodeType : -1;
        \\     const tag = this.nodeName;
        \\     if (nt === 8) console.log("[TRACE] insertBefore COMMENT('" + newNode.data + "') into " + tag + " before " + (refNode ? refNode.nodeName : "null"));
        \\     else if (nt === 11) console.log("[TRACE] insertBefore FRAGMENT into " + tag);
        \\     const result = origInsertBefore.call(this, newNode, refNode);
        \\     if (nt === 8) console.log("[TRACE]   -> parentNode after:", result.parentNode ? result.parentNode.nodeName : "NULL");
        \\     return result;
        \\ };
        \\ const origAppendChild = Element.prototype.appendChild;
        \\ Element.prototype.appendChild = function(child) {
        \\     const nt = child ? child.nodeType : -1;
        \\     const tag = this.nodeName;
        \\     if (nt === 8) console.log("[TRACE] appendChild COMMENT('" + child.data + "') into " + tag);
        \\     else if (nt === 11) {
        \\         let ccount = 0; let fc = child.firstChild;
        \\         while(fc) { ccount++; fc = fc.nextSibling; }
        \\         console.log("[TRACE] appendChild FRAGMENT(" + ccount + " children) into " + tag);
        \\     }
        \\     const result = origAppendChild.call(this, child);
        \\     if (nt === 8) console.log("[TRACE]   -> parentNode after:", result.parentNode ? result.parentNode.nodeName : "NULL");
        \\     return result;
        \\ };
    ;
    const check_val = try engine.eval(comment_check, "<comment-check>", .global);
    engine.ctx.freeValue(check_val);

    const diagnostic_script =
        \\ console.log("\n[Diag] --- REACTIVITY LIFECYCLE START ---");
        \\ const badge2 = globalThis.myActiveBadge;
        \\
        \\ console.log("[Diag] 1. isConnected (Native):", badge2.isConnected);
        \\
        \\ // Force it to true so Lit CANNOT abort
        \\ Object.defineProperty(badge2, 'isConnected', { get: () => true });
        \\
        \\ // Hook into the final lifecycle method
        \\ badge2.updated = function(changed) {
        \\     console.log("[Diag] 5. SUCCESS! updated() fired!");
        \\ };
        \\
        \\
        \\ console.log("[Diag] 2. Mutating status...");
        \\ badge2.status = 'OFFLINE';
        \\
        \\ badge2.requestUpdate();
        \\
        \\ console.log("[Diag] 3. isUpdatePending?", badge2.isUpdatePending);
        \\
        \\ // Catch silent microtask crashes (like missing text node setters)
        \\ badge2.updateComplete.then(() => {
        \\     console.log("[Diag] 4. updateComplete Promise RESOLVED");
        \\ }).catch(err => {
        \\     console.log("[Diag] 4. FATAL CRASH in performUpdate:", err.message);
        \\ });
    ;

    const val = try engine.eval(diagnostic_script, "<reactivity-test>", .global);
    engine.ctx.freeValue(val);

    // 3. FORCE FLUSH EVERYTHING (Timers AND Microtasks)
    // processJobs() only flushes promises. run() guarantees everything executes.
    try engine.run();

    // 3. Print the updated DOM
    std.debug.print("\n=== REACTIVE DOM OUTPUT ===\n", .{});
    try z.prettyPrint(allocator, z.bodyNode(engine.dom.doc).?);
}

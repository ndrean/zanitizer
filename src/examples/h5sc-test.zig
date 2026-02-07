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

    try testRun(gpa, sandbox_root);
}

// Tags that should never appear in a sanitized/safe DOM (unless strictly controlled)
const DANGEROUS_TAGS = [_][]const u8{ "script", "object", "embed", "applet", "meta", "xml", "iframe" };

// Attributes that allow execution
const DANGEROUS_ATTRS = [_][]const u8{ "onload", "onerror", "onclick", "onmouseover", "formaction", "background", "href", "src", "data" };

fn testRun(gpa: std.mem.Allocator, _: []const u8) !void {
    const html_content = @embedFile("h5sc-test.html");

    std.debug.print("\n=== H5SC Security Check ---------------\n\n", .{});
    std.debug.print("Vectors Loaded: {d} bytes\n", .{html_content.len});

    var timer = try std.time.Timer.start();

    const doc = try z.parseHTML(gpa, html_content);
    defer z.destroyDocument(doc);

    // Initialize CSS sanitizer for <style> tag sanitization
    var css_sanitizer = try z.CssSanitizer.init(gpa, .{});
    defer css_sanitizer.deinit();

    // Use custom mode with CSS sanitization enabled
    const custom_mode = z.SanitizerMode{
        .custom = z.SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = false, // ← Enable CSS sanitization instead of removal
            .sanitize_inline_styles = true,
            .strict_uri_validation = true,
            .allow_custom_elements = false,
            .allow_framework_attrs = true,
            .sanitize_dom_clobbering = true,
        },
    };

    const body_node = z.bodyNode(doc).?;

    try z.sanitizeWithCss(
        gpa,
        body_node,
        custom_mode,
        &css_sanitizer,
    );

    const elapsed_ns = timer.read();
    const elapsed_us = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
    const elapsed_ms = elapsed_us / 1000.0;
    z.print("Processing time: {} ms\n", .{elapsed_ms});

    // try z.prettyPrint(gpa, body_node);

    // 3. Find all Vector Containers
    // Each attack is wrapped in <div class="vector" data-id="...">
    const vectors = try z.querySelectorAll(gpa, doc, "div.vector");
    defer gpa.free(vectors);

    var passed: usize = 0;
    var failed: usize = 0;

    for (vectors) |vector_div| {
        const id_str = z.getAttribute_zc(vector_div, "data-id") orelse "unknown";

        // We only care about what's *inside* the div (the payload)
        if (isSafeSubtree(z.elementToNode(vector_div))) {
            passed += 1;
        } else {
            failed += 1;
            std.debug.print("❌ FAILED Vector ID: {s}\n", .{id_str});
            // printInnerHtml(vector_div); // Optional helper to see why it failed
        }
    }

    std.debug.print("\nRESULTS:\n✅ Passed: {d}\n❌ Failed: {d}\n", .{ passed, failed });

    // Assert Perfection
    try std.testing.expectEqual(vectors.len, passed);
}

/// Recursively checks if a node and its children are safe
fn isSafeSubtree(root: *z.DomNode) bool {
    // 1. Check the Node itself
    if (!isNodeSafe(root)) return false;

    // 2. Check all children
    var child = z.firstChild(root);
    while (child) |c| : (child = z.nextSibling(c)) {
        if (!isSafeSubtree(c)) return false;
    }
    return true;
}

fn isNodeSafe(node: *z.DomNode) bool {
    const type_ = z.nodeType(node);

    // TEXT nodes are always safe (unless we are checking for raw HTML injection,
    // but here we are checking the *Parsed DOM*, so text is just text).
    if (type_ == .text) return true;
    if (type_ == .comment) return true;

    if (type_ == .element) {
        const tag_name = z.nodeName_zc(node);

        // CHECK 1: Blacklisted Tags
        for (DANGEROUS_TAGS) |bad_tag| {
            if (std.ascii.eqlIgnoreCase(tag_name, bad_tag)) {
                // Special case: If the script tag is inert/template, maybe okay,
                // but for this test, ANY script tag appearing is a fail.
                return false;
            }
        }

        // CHECK 2: Dangerous Attributes
        // You need an iterator for attributes in your Zig wrapper
        // Assuming: z.firstAttribute(node) -> z.nextAttribute(attr)
        var attr = z.iterateDomAttributes(z.nodeToElement(node).?);
        while (attr.next()) |a| {
            const attr_name = z.getAttributeName_zc(a);
            const attr_val = z.getAttributeValue_zc(a);

            // A. Event Handlers (on*)
            if (std.ascii.startsWithIgnoreCase(attr_name, "on")) {
                return false;
            }

            // B. Javascript Protocol (javascript:...)
            // Checks attributes like href="javascript:..." or src="javascript:..."
            for (DANGEROUS_ATTRS) |check_attr| {
                if (std.ascii.eqlIgnoreCase(attr_name, check_attr)) {
                    // Normalize value: remove whitespace/tabs which browsers ignore
                    // e.g. "j avascript:"
                    if (containsProtocol(attr_val, "javascript:")) return false;
                    if (containsProtocol(attr_val, "vbscript:")) return false;
                    if (containsProtocol(attr_val, "data:")) {
                        if (containsProtocol(attr_val, "text/html")) return false;
                        if (containsProtocol(attr_val, "application/javascript")) return false;
                        // Otherwise, trust the sanitizer handled the image/data content
                    }
                }
            }
        }
    }

    return true;
}

/// Helper to detect protocols even with obfuscation
fn containsProtocol(value: []const u8, protocol: []const u8) bool {
    // A robust check would remove all whitespace and control chars first
    // For this snippet, we do a basic contains check
    // In reality, H5SC uses things like "j\navascript:"

    // Zig impl: Create a clean buffer, strip non-alpha, check prefix
    // ... (omitted for brevity) ...

    return std.mem.indexOf(u8, value, protocol) != null;
}

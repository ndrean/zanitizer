//! Example: Using Web API-compatible SanitizerConfig
//!
//! This example demonstrates how to use the new SanitizerConfig
//! to configure HTML sanitization at runtime while maintaining
//! h5sc compliance through the static html_spec.zig.

const std = @import("std");
const z = @import("root");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== SanitizerConfig Examples ===\n\n", .{});

    // Example 1: Default configuration (balanced)
    try example1_default(allocator);

    // Example 2: Strict configuration (maximum security)
    try example2_strict(allocator);

    // Example 3: Permissive configuration (trusted content)
    try example3_permissive(allocator);

    // Example 4: Custom framework configuration
    try example4_custom_frameworks(allocator);

    // Example 5: Element and attribute filtering
    try example5_filtering(allocator);
}

fn example1_default(allocator: std.mem.Allocator) !void {
    std.debug.print("Example 1: Default Configuration\n", .{});
    std.debug.print("  - Blocks: script, iframe, object, embed\n", .{});
    std.debug.print("  - Allows: framework attributes (Alpine, Vue, HTMX, Phoenix)\n", .{});
    std.debug.print("  - Blocks: event handlers (x-on:*, @click, etc.)\n\n", .{});

    const config = z.SanitizerConfig.default();

    // Test element filtering
    std.debug.print("  div allowed: {}\n", .{config.isElementAllowed("div")});
    std.debug.print("  script allowed: {}\n", .{config.isElementAllowed("script")});
    std.debug.print("  iframe allowed: {}\n", .{config.isElementAllowed("iframe")});

    // Test framework attributes
    std.debug.print("  x-show allowed: {}\n", .{config.isAttributeAllowed("x-show")});
    std.debug.print("  v-if allowed: {}\n", .{config.isAttributeAllowed("v-if")});
    std.debug.print("  x-on:click allowed: {}\n", .{config.isAttributeAllowed("x-on:click")});
    std.debug.print("  @click allowed: {}\n\n", .{config.isAttributeAllowed("@click")});

    // Create Sanitizer wrapper
    const sanitizer = try z.Sanitizer.initDefault(allocator);
    defer sanitizer.deinit();

    std.debug.print("  Sanitizer created successfully!\n\n", .{});
}

fn example2_strict(allocator: std.mem.Allocator) !void {
    std.debug.print("Example 2: Strict Configuration (Maximum Security)\n", .{});
    std.debug.print("  - Blocks: script, style, iframe, object, embed\n", .{});
    std.debug.print("  - No framework attributes\n", .{});
    std.debug.print("  - Strict URI validation\n", .{});
    std.debug.print("  - DOM clobbering protection\n\n", .{});

    const config = z.SanitizerConfig.strict();

    std.debug.print("  div allowed: {}\n", .{config.isElementAllowed("div")});
    std.debug.print("  script allowed: {}\n", .{config.isElementAllowed("script")});
    std.debug.print("  style allowed: {}\n", .{config.isElementAllowed("style")});

    std.debug.print("  x-show allowed: {}\n", .{config.isAttributeAllowed("x-show")});
    std.debug.print("  data-id allowed: {}\n", .{config.isAttributeAllowed("data-id")});
    std.debug.print("  aria-label allowed: {}\n\n", .{config.isAttributeAllowed("aria-label")});

    const sanitizer = try z.Sanitizer.initStrict(allocator);
    defer sanitizer.deinit();

    std.debug.print("  Strict sanitizer created!\n\n", .{});
}

fn example3_permissive(allocator: std.mem.Allocator) !void {
    std.debug.print("Example 3: Permissive Configuration (Trusted Content)\n", .{});
    std.debug.print("  - Blocks: only script\n", .{});
    std.debug.print("  - Allows: style, iframe (with sandbox)\n", .{});
    std.debug.print("  - Allows: all framework attributes\n", .{});
    std.debug.print("  - Allows: comments\n\n", .{});

    const config = z.SanitizerConfig.permissive();

    std.debug.print("  script allowed: {}\n", .{config.isElementAllowed("script")});
    std.debug.print("  style allowed: {}\n", .{config.isElementAllowed("style")});
    std.debug.print("  iframe allowed: {}\n", .{config.isElementAllowed("iframe")});
    std.debug.print("  comments allowed: {}\n\n", .{config.comments});

    const sanitizer = try z.Sanitizer.initPermissive(allocator);
    defer sanitizer.deinit();

    std.debug.print("  Permissive sanitizer created!\n\n", .{});
}

fn example4_custom_frameworks(allocator: std.mem.Allocator) !void {
    std.debug.print("Example 4: Custom Framework Configuration\n", .{});
    std.debug.print("  - Allow: Alpine.js and HTMX only\n", .{});
    std.debug.print("  - Block: Vue.js, Phoenix, Angular, Svelte\n\n", .{});

    const config = z.SanitizerConfig{
        .frameworks = .{
            .allow_alpine = true,
            .allow_vue = false,
            .allow_htmx = true,
            .allow_phoenix = false,
            .allow_angular = false,
            .allow_svelte = false,
        },
        .removeElements = &[_][]const u8{ "script", "iframe" },
    };

    std.debug.print("  x-show (Alpine) allowed: {}\n", .{config.isAttributeAllowed("x-show")});
    std.debug.print("  v-if (Vue) allowed: {}\n", .{config.isAttributeAllowed("v-if")});
    std.debug.print("  hx-get (HTMX) allowed: {}\n", .{config.isAttributeAllowed("hx-get")});
    std.debug.print("  phx-click (Phoenix) allowed: {}\n\n", .{config.isAttributeAllowed("phx-click")});

    const sanitizer = try z.Sanitizer.init(allocator, config);
    defer sanitizer.deinit();

    std.debug.print("  Custom sanitizer created!\n\n", .{});
}

fn example5_filtering(allocator: std.mem.Allocator) !void {
    std.debug.print("Example 5: Element and Attribute Filtering\n", .{});
    std.debug.print("  - Allowlist: only div, p, span elements\n", .{});
    std.debug.print("  - Allowlist: only class, id, data-* attributes\n\n", .{});

    const config = z.SanitizerConfig{
        .elements = &[_][]const u8{ "div", "p", "span", "a" },
        .attributes = &[_][]const u8{ "class", "id", "href" },
        .dataAttributes = true, // Allow all data-* attributes
    };

    try config.validate();

    std.debug.print("  div allowed: {}\n", .{config.isElementAllowed("div")});
    std.debug.print("  table allowed: {}\n", .{config.isElementAllowed("table")});
    std.debug.print("  a allowed: {}\n", .{config.isElementAllowed("a")});

    std.debug.print("  class allowed: {}\n", .{config.isAttributeAllowed("class")});
    std.debug.print("  title allowed: {}\n", .{config.isAttributeAllowed("title")});
    std.debug.print("  data-id allowed: {}\n\n", .{config.isAttributeAllowed("data-id")});

    const sanitizer = try z.Sanitizer.init(allocator, config);
    defer sanitizer.deinit();

    std.debug.print("  Filtered sanitizer created!\n\n", .{});
}

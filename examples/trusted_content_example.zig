//! Example: Processing YOUR OWN code with event handlers
//!
//! This shows how to use bypassSafety for trusted content that
//! intentionally contains event handlers (onclick, x-on:*, etc.)

const std = @import("std");
const z = @import("root");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Processing Trusted Content with Event Handlers ===\n\n", .{});

    // Example 1: Default config blocks event handlers
    try example1_default_blocks_events(allocator);

    // Example 2: Trusted config allows event handlers
    try example2_trusted_allows_events(allocator);

    // Example 3: Custom config with bypassSafety
    try example3_custom_bypass(allocator);
}

fn example1_default_blocks_events(_: std.mem.Allocator) !void {
    std.debug.print("Example 1: Default Config (Blocks Event Handlers)\n", .{});

    const config = z.SanitizerConfig.default();

    // These are blocked for security
    std.debug.print("  onclick allowed: {}\n", .{config.isAttributeAllowed("onclick")});
    std.debug.print("  x-on:click allowed: {}\n", .{config.isAttributeAllowed("x-on:click")});
    std.debug.print("  @click allowed: {}\n", .{config.isAttributeAllowed("@click")});
    std.debug.print("  phx-click allowed: {}\n\n", .{config.isAttributeAllowed("phx-click")});
}

fn example2_trusted_allows_events(allocator: std.mem.Allocator) !void {
    std.debug.print("Example 2: Trusted Config (Allows Event Handlers)\n", .{});
    std.debug.print("  ⚠️  Use ONLY for YOUR OWN code!\n\n", .{});

    const config = z.SanitizerConfig.trusted();

    // Now event handlers are allowed
    std.debug.print("  onclick allowed: {}\n", .{config.isAttributeAllowed("onclick")});
    std.debug.print("  x-on:click allowed: {}\n", .{config.isAttributeAllowed("x-on:click")});
    std.debug.print("  @click allowed: {}\n", .{config.isAttributeAllowed("@click")});
    std.debug.print("  phx-click allowed: {}\n", .{config.isAttributeAllowed("phx-click")});
    std.debug.print("  onerror allowed: {}\n\n", .{config.isAttributeAllowed("onerror")});

    const sanitizer = try z.Sanitizer.initTrusted(allocator);
    defer sanitizer.deinit();

    std.debug.print("  Trusted sanitizer created!\n", .{});
    std.debug.print("  bypassSafety = {}\n\n", .{sanitizer.config.bypassSafety});
}

fn example3_custom_bypass(allocator: std.mem.Allocator) !void {
    std.debug.print("Example 3: Custom Config with bypassSafety\n", .{});
    std.debug.print("  Allow Alpine.js with event handlers\n\n", .{});

    const config = z.SanitizerConfig{
        .bypassSafety = true, // ⚠️ DANGER: Allows event handlers
        .frameworks = .{
            .allow_alpine = true,
            .allow_vue = false, // Only Alpine, not Vue
            .allow_htmx = false,
        },
        .removeElements = &[_][]const u8{}, // Don't remove any elements
    };

    // Alpine event handlers allowed (bypassSafety)
    std.debug.print("  x-on:click allowed: {}\n", .{config.isAttributeAllowed("x-on:click")});
    std.debug.print("  @click allowed: {}\n", .{config.isAttributeAllowed("@click")});

    // Non-event Alpine allowed (framework enabled)
    std.debug.print("  x-show allowed: {}\n", .{config.isAttributeAllowed("x-show")});

    // Vue blocked (framework disabled, but events still bypass)
    std.debug.print("  v-if allowed: {}\n", .{config.isAttributeAllowed("v-if")});
    std.debug.print("  v-on:click allowed: {}\n\n", .{config.isAttributeAllowed("v-on:click")});

    const sanitizer = try z.Sanitizer.init(allocator, config);
    defer sanitizer.deinit();

    std.debug.print("  Custom bypass sanitizer created!\n\n", .{});
}

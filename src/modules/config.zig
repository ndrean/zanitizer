//! Centralized configuration management for the sanitizer.
//! Parses JSON configuration and applies presets.

const std = @import("std");
const z = @import("../root.zig");

/// JSON-deserialization mirror of SanitizerConfig (all fields optional = patch semantics).
pub const JsonSanitizerConfig = struct {
    elements: ?[]const z.ElementConfig = null,
    removeElements: ?[]const []const u8 = null,
    replaceWithChildrenElements: ?[]const []const u8 = null,
    attributes: ?[]const []const u8 = null,
    removeAttributes: ?[]const []const u8 = null,
    comments: ?bool = null,
    dataAttributes: ?bool = null,
    allowCustomElements: ?bool = null,
    strictUriValidation: ?bool = null,
    sanitizeDomClobbering: ?bool = null,
    sanitizeInlineStyles: ?bool = null,
    bypassSafety: ?bool = null,
    customAttrPrefixes: ?[]const []const u8 = null,
};

/// Patch a SanitizerConfig with non-null values from parsed JSON.
pub fn applyJsonConfig(sc: *z.SanitizerConfig, j: JsonSanitizerConfig) void {
    if (j.elements) |v| sc.elements = v;
    if (j.removeElements) |v| sc.removeElements = v;
    if (j.replaceWithChildrenElements) |v| sc.replaceWithChildrenElements = v;
    if (j.attributes) |v| sc.attributes = v;
    if (j.removeAttributes) |v| sc.removeAttributes = v;
    if (j.comments) |v| sc.comments = v;
    if (j.dataAttributes) |v| sc.dataAttributes = v;
    if (j.allowCustomElements) |v| sc.allowCustomElements = v;
    if (j.strictUriValidation) |v| sc.strictUriValidation = v;
    if (j.sanitizeDomClobbering) |v| sc.sanitizeDomClobbering = v;
    if (j.sanitizeInlineStyles) |v| sc.sanitizeInlineStyles = v;
    if (j.bypassSafety) |v| sc.bypassSafety = v;
    if (j.customAttrPrefixes) |v| sc.customAttrPrefixes = v;
}

/// Build SanitizeOptions from an optional preset + optional JSON patch (JSON wins on overlap).
pub fn resolveOptions(allocator: std.mem.Allocator, preset_name: ?[]const u8, json_src: ?[]const u8) !z.SanitizeOptions {
    var sc: z.SanitizerConfig = if (preset_name) |p| blk: {
        if (std.mem.eql(u8, p, "strict")) break :blk z.SanitizerConfig.strict();
        if (std.mem.eql(u8, p, "permissive")) break :blk z.SanitizerConfig.permissive();
        if (std.mem.eql(u8, p, "trusted")) break :blk z.SanitizerConfig.trusted();
        if (std.mem.eql(u8, p, "default")) break :blk z.SanitizerConfig.default();
        std.debug.print("Unknown preset '{s}', using default.\n", .{p});
        break :blk z.SanitizerConfig.default();
    } else z.SanitizerConfig{};

    if (json_src) |src| {
        // The strings in parsed.value are owned by the caller's arena.
        const parsed = try std.json.parseFromSlice(JsonSanitizerConfig, allocator, src, .{
            .ignore_unknown_fields = true,
        });
        applyJsonConfig(&sc, parsed.value);
    }

    return sc.toSanitizeOptions();
}

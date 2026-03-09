//! Web API-compatible Sanitizer Configuration
//!
//! This module provides a runtime configuration layer on top of the static html_spec.zig.
//! It implements the HTML Sanitizer API (https://wicg.github.io/sanitizer-api/)
//! while adding framework-specific extensions for modern web development.
//!
//! Architecture:
//! - html_spec.zig: Static, compile-time HTML standard (h5sc compliant)
//! - SanitizerConfig: Runtime filter/configuration on top of the static spec
//! - FrameworkConfig: Framework-specific runtime settings

const std = @import("std");
const z = @import("root.zig");

/// Re-export from sanitizer.zig so JSON consumers use the same type.
pub const ElementConfig = z.ElementConfig;

/// Framework-specific configuration (runtime, user-configurable)
/// This is the primary use case for runtime configuration - allowing users
/// to control which framework attributes are permitted in their content.
pub const FrameworkConfig = struct {
    /// Allow Alpine.js attributes (x-data, x-show, etc.)
    /// Event handlers (x-on:*) are always blocked for security
    allow_alpine: bool = true,

    /// Allow Vue.js attributes (v-model, v-if, etc.)
    /// Event handlers (v-on:*, @*) are always blocked for security
    allow_vue: bool = true,

    /// Allow HTMX attributes (hx-get, hx-post, etc.)
    /// Event handlers (hx-on:*) are always blocked for security
    allow_htmx: bool = true,

    /// Allow Phoenix LiveView attributes (phx-click, phx-submit, etc.)
    allow_phoenix: bool = true,

    /// Allow Angular attributes (*ngFor, *ngIf, etc.)
    /// Event handlers ((click)) are always blocked for security
    allow_angular: bool = true,

    /// Allow Svelte attributes (bind:*, use:*)
    /// Event handlers (on:*) are always blocked for security
    allow_svelte: bool = true,

    /// Allow all data-* attributes (HTML5 standard)
    allow_data_attrs: bool = true,

    /// Allow all aria-* attributes (accessibility standard)
    allow_aria_attrs: bool = true,
};

/// Web API-compatible Sanitizer Configuration
/// Based on: https://developer.mozilla.org/en-US/docs/Web/API/SanitizerConfig
///
/// This config filters the static html_spec.zig at runtime without replacing it.
/// The static spec remains the ground truth for what's valid HTML (h5sc compliance).
pub const SanitizerConfig = struct {
    // ============================================================================
    // Web API Standard Properties
    // ============================================================================

    /// Elements to allow (allowlist approach).
    /// Each entry is an ElementConfig with a required `name` and optional
    /// `attributes`/`removeAttributes` for per-element attribute control.
    /// If null, uses html_spec's default safe elements.
    elements: ?[]const ElementConfig = null,

    /// Elements to remove (blocklist approach)
    /// Cannot be used together with `elements`
    /// If provided, these elements are blocked even if in html_spec
    removeElements: ?[]const []const u8 = null,

    /// Global allowed attributes
    /// If null, uses html_spec's default safe attributes
    /// If provided, ONLY these attributes pass (still validated against html_spec)
    attributes: ?[]const []const u8 = null,

    /// Global attributes to remove
    /// Cannot be used together with `attributes`
    /// If provided, these attributes are blocked even if in html_spec
    removeAttributes: ?[]const []const u8 = null,

    /// Elements to replace with their children (unwrap)
    /// Useful for stripping formatting: <b>text</b> → text
    replaceWithChildrenElements: ?[]const []const u8 = null,

    /// Whether to allow HTML comments
    /// Default: false (comments removed)
    comments: bool = false,

    /// Whether to automatically allow all data-* attributes
    /// Default: true (HTML5 standard)
    dataAttributes: bool = true,

    // ============================================================================
    // Extended Properties (beyond Web API - framework support)
    // ============================================================================

    /// Framework-specific attribute configuration
    /// This is where users typically customize behavior
    frameworks: FrameworkConfig = .{},

    /// Whether to allow custom elements (Web Components)
    /// Custom elements must contain a hyphen (e.g., <my-component>)
    /// Default: true
    allowCustomElements: bool = true,

    /// Strict URI validation (block relative paths, data: URIs, etc.)
    /// When true: Only http:, https:, mailto: allowed
    /// When false: Also allows relative paths, data:image/* (except SVG)
    /// Default: false (permissive for general use)
    strictUriValidation: bool = false,

    /// Remove id/name attributes that shadow DOM properties (DOM Clobbering protection)
    /// Example: <img id="location"> can break window.location in JavaScript
    /// Enabled by default like DOMPurify's SANITIZE_DOM
    /// Default: true
    sanitizeDomClobbering: bool = true,

    /// Whether to sanitize inline style attributes when allowed
    /// Removes dangerous CSS like expression(), url(javascript:), etc.
    /// Default: true
    sanitizeInlineStyles: bool = true,

    /// DANGER: Bypass html_spec safety checks (for trusted content only!)
    /// When true, allows event handlers (onclick, x-on:*, @click, etc.)
    /// and other dangerous attributes that are normally blocked.
    ///
    /// ⚠️  WARNING: Only use for YOUR OWN trusted code!
    /// This completely disables XSS protection for attributes.
    ///
    /// Use case: Processing your own templates that use event handlers
    /// Default: false (safety checks enabled)
    bypassSafety: bool = false,

    /// Custom attribute prefixes to allow through with protocol-only value checking.
    /// Example: &[_][]const u8{"wire:", "livewire:", "data-turbo"}
    /// Values are checked only for dangerous protocols (javascript:, vbscript:, data:text/html,
    /// data:text/javascript). JS code pattern scanning is intentionally skipped.
    customAttrPrefixes: ?[]const []const u8 = null,

    // ============================================================================
    // Validation & Helpers
    // ============================================================================

    /// Convert to the canonical SanitizeOptions used by the DOM walker.
    pub fn toSanitizeOptions(self: @This()) z.SanitizeOptions {
        return .{
            .remove_scripts = true, // always enforced
            .remove_styles = false,
            .sanitize_css = self.sanitizeInlineStyles,
            .remove_comments = !self.comments,
            .strict_uri = self.strictUriValidation,
            .sanitize_dom_clobbering = self.sanitizeDomClobbering,
            .allow_custom_elements = self.allowCustomElements,
            .allow_embeds = false,
            .allow_iframes = false,
            .frameworks = .{
                .allow_alpine = self.frameworks.allow_alpine,
                .allow_vue = self.frameworks.allow_vue,
                .allow_htmx = self.frameworks.allow_htmx,
                .allow_phoenix = self.frameworks.allow_phoenix,
                .allow_angular = self.frameworks.allow_angular,
                .allow_svelte = self.frameworks.allow_svelte,
                .allow_data_attrs = self.frameworks.allow_data_attrs and self.dataAttributes,
                .allow_aria_attrs = self.frameworks.allow_aria_attrs,
            },
            .bypass_safety = self.bypassSafety,
            .elements = self.elements,
            .remove_elements = self.removeElements,
            .replace_with_children = self.replaceWithChildrenElements,
            .allowed_attributes = self.attributes,
            .remove_attributes = self.removeAttributes,
            .custom_attr_prefixes = self.customAttrPrefixes,
        };
    }

    /// Validate that the configuration is valid according to Web API rules
    pub fn validate(self: @This()) !void {
        // Cannot have both elements and removeElements
        if (self.elements != null and self.removeElements != null) {
            return error.InvalidConfig;
        }

        // Cannot have both attributes and removeAttributes
        if (self.attributes != null and self.removeAttributes != null) {
            return error.InvalidConfig;
        }

        // No duplicates in arrays (simplified check)
        if (self.elements) |arr| {
            if (arr.len > 1) {
                // In production, check for duplicates
                // Skipping for now as it requires O(n²) or temporary hashmap
            }
        }
    }

    /// Create a default strict configuration (like DOMPurify)
    /// - Blocks scripts, styles, iframes
    /// - Strict URI validation
    /// - DOM clobbering protection
    /// - No framework attributes
    pub fn strict() SanitizerConfig {
        return .{
            .removeElements = &[_][]const u8{ "script", "style", "iframe", "object", "embed" },
            .comments = false,
            .dataAttributes = false,
            .frameworks = .{
                .allow_alpine = false,
                .allow_vue = false,
                .allow_htmx = false,
                .allow_phoenix = false,
                .allow_angular = false,
                .allow_svelte = false,
                .allow_data_attrs = false,
                .allow_aria_attrs = true, // Keep accessibility
            },
            .allowCustomElements = false,
            .strictUriValidation = true,
            .sanitizeDomClobbering = true,
            .sanitizeInlineStyles = true,
        };
    }

    /// Create a permissive configuration for trusted content
    /// - Allows most HTML elements (still validates against html_spec)
    /// - Allows framework attributes
    /// - Removes only obviously dangerous elements (script)
    pub fn permissive() SanitizerConfig {
        return .{
            .removeElements = &[_][]const u8{ "script" },
            .comments = true,
            .dataAttributes = true,
            .frameworks = .{}, // All frameworks enabled by default
            .allowCustomElements = true,
            .strictUriValidation = false,
            .sanitizeDomClobbering = true,
            .sanitizeInlineStyles = true,
        };
    }

    /// Create a default balanced configuration (recommended)
    /// - Blocks scripts, dangerous elements
    /// - Allows framework attributes
    /// - DOM clobbering protection
    pub fn default() SanitizerConfig {
        return .{
            .removeElements = &[_][]const u8{ "script", "iframe", "object", "embed" },
            .comments = false,
            .dataAttributes = true,
            .frameworks = .{}, // All frameworks enabled by default
            .allowCustomElements = true,
            .strictUriValidation = false,
            .sanitizeDomClobbering = true,
            .sanitizeInlineStyles = true,
        };
    }

    /// Create a trusted configuration (for YOUR OWN code only!)
    /// ⚠️  DANGER: Bypasses all safety checks including event handlers
    ///
    /// Use this ONLY for processing your own trusted templates that
    /// contain event handlers (onclick, x-on:*, @click, etc.)
    ///
    /// - Allows: Everything including event handlers, scripts, dangerous elements
    /// - Bypasses: html_spec safety checks
    /// - Use case: Processing your own code/templates
    ///
    /// Example: Your Alpine.js templates with x-on:click handlers
    pub fn trusted() SanitizerConfig {
        return .{
            .comments = true,
            .dataAttributes = true,
            .frameworks = .{}, // All frameworks enabled
            .allowCustomElements = true,
            .strictUriValidation = false,
            .sanitizeDomClobbering = false, // Allow any id/name
            .sanitizeInlineStyles = false, // Allow any CSS
            .bypassSafety = true, // ⚠️ DANGER: Allows event handlers!
        };
    }

    /// Create an empty configuration (no filtering at all)
    /// Equivalent to `.none` mode in the old API
    ///
    /// ⚠️  DANGER: NO sanitization happens - use only for trusted content!
    ///
    /// This is useful when you want to process your own HTML that
    /// intentionally contains scripts, event handlers, etc.
    pub fn none() SanitizerConfig {
        return .{
            .comments = true,
            .dataAttributes = true,
            .frameworks = .{},
            .allowCustomElements = true,
            .strictUriValidation = false,
            .sanitizeDomClobbering = false,
            .sanitizeInlineStyles = false,
            .bypassSafety = true, // ⚠️ DANGER: Allows everything!
        };
    }

    /// Check if an element is allowed by this config
    /// This is a config-level check - still needs html_spec validation
    pub fn isElementAllowed(self: @This(), element_tag: []const u8) bool {
        // Allowlist mode: only listed elements
        if (self.elements) |allowed_list| {
            for (allowed_list) |ec| {
                if (std.mem.eql(u8, ec.name, element_tag)) {
                    return true;
                }
            }
            return false;
        }

        // Blocklist mode: everything except listed elements
        if (self.removeElements) |blocked_list| {
            for (blocked_list) |blocked| {
                if (std.mem.eql(u8, blocked, element_tag)) {
                    return false;
                }
            }
        }

        // No config = allowed (still subject to html_spec validation)
        return true;
    }

    /// Check if an attribute is allowed by this config
    /// This is a config-level check - still needs html_spec validation
    pub fn isAttributeAllowed(self: @This(), attr_name: []const u8) bool {
        // Check framework attributes first
        if (!self.isFrameworkAttributeAllowed(attr_name)) {
            return false;
        }

        // Allowlist mode: only listed attributes
        if (self.attributes) |allowed_list| {
            for (allowed_list) |allowed| {
                if (std.mem.eql(u8, allowed, attr_name)) {
                    return true;
                }
            }
            return false;
        }

        // Blocklist mode: everything except listed attributes
        if (self.removeAttributes) |blocked_list| {
            for (blocked_list) |blocked| {
                if (std.mem.eql(u8, blocked, attr_name)) {
                    return false;
                }
            }
        }

        // No config = allowed (still subject to html_spec validation)
        return true;
    }

    /// Check if a framework attribute is allowed based on framework config
    fn isFrameworkAttributeAllowed(self: @This(), attr_name: []const u8) bool {
        const fw = self.frameworks;

        // First, check if it's unsafe according to html_spec (event handlers, etc.)
        // This catches patterns like @ (Vue events), ( (Angular events), on: (Svelte events)
        // UNLESS bypassSafety is true (for trusted content)
        if (!self.bypassSafety and !z.isFrameworkAttributeSafe(attr_name)) {
            return false;
        }

        // data-* attributes
        if (std.mem.startsWith(u8, attr_name, "data-")) {
            return fw.allow_data_attrs and self.dataAttributes;
        }

        // aria-* attributes
        if (std.mem.startsWith(u8, attr_name, "aria-")) {
            return fw.allow_aria_attrs;
        }

        // Alpine.js: x-*
        if (std.mem.startsWith(u8, attr_name, "x-")) {
            return fw.allow_alpine;
        }

        // Vue.js: v-*, @, :
        if (std.mem.startsWith(u8, attr_name, "v-") or
            std.mem.startsWith(u8, attr_name, "@") or
            std.mem.startsWith(u8, attr_name, ":")) {
            return fw.allow_vue;
        }

        // HTMX: hx-*
        if (std.mem.startsWith(u8, attr_name, "hx-")) {
            return fw.allow_htmx;
        }

        // Phoenix LiveView: phx-*
        if (std.mem.startsWith(u8, attr_name, "phx-")) {
            return fw.allow_phoenix;
        }

        // Angular: *ng*, [, (
        if (std.mem.startsWith(u8, attr_name, "*ng") or
            std.mem.startsWith(u8, attr_name, "[") or
            std.mem.startsWith(u8, attr_name, "(")) {
            return fw.allow_angular;
        }

        // Svelte: bind:, on:, use:
        if (std.mem.startsWith(u8, attr_name, "bind:") or
            std.mem.startsWith(u8, attr_name, "on:") or
            std.mem.startsWith(u8, attr_name, "use:")) {
            return fw.allow_svelte;
        }

        // Not a framework attribute - allow
        return true;
    }
};

/// Sanitizer wrapper (Web API compatible)
/// Wraps a SanitizerConfig and provides validation
pub const Sanitizer = struct {
    config: SanitizerConfig,
    allocator: std.mem.Allocator,

    /// Create a new Sanitizer with the given config
    pub fn init(allocator: std.mem.Allocator, config: SanitizerConfig) !*Sanitizer {
        try config.validate();
        const self = try allocator.create(Sanitizer);
        self.* = .{
            .config = config,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *Sanitizer) void {
        self.allocator.destroy(self);
    }

    /// Create default sanitizer (balanced configuration)
    pub fn initDefault(allocator: std.mem.Allocator) !*Sanitizer {
        return init(allocator, SanitizerConfig.default());
    }

    /// Create strict sanitizer
    pub fn initStrict(allocator: std.mem.Allocator) !*Sanitizer {
        return init(allocator, SanitizerConfig.strict());
    }

    /// Create permissive sanitizer
    pub fn initPermissive(allocator: std.mem.Allocator) !*Sanitizer {
        return init(allocator, SanitizerConfig.permissive());
    }

    /// Create trusted sanitizer (for YOUR OWN code only!)
    /// ⚠️  DANGER: Bypasses safety checks including event handlers
    pub fn initTrusted(allocator: std.mem.Allocator) !*Sanitizer {
        return init(allocator, SanitizerConfig.trusted());
    }

    /// Create no-sanitization sanitizer (for completely trusted content)
    /// ⚠️  DANGER: NO sanitization - equivalent to `.none` mode
    pub fn initNone(allocator: std.mem.Allocator) !*Sanitizer {
        return init(allocator, SanitizerConfig.none());
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "SanitizerConfig validation" {
    // Valid config: allowlist elements (now ElementConfig structs)
    const config1 = SanitizerConfig{
        .elements = &[_]ElementConfig{ .{ .name = "div" }, .{ .name = "p" }, .{ .name = "span" } },
        .comments = true,
    };
    try config1.validate();

    // Valid config: blocklist elements
    const config2 = SanitizerConfig{
        .removeElements = &[_][]const u8{ "script", "iframe" },
    };
    try config2.validate();

    // Invalid config: both allowlist and blocklist
    const config3 = SanitizerConfig{
        .elements = &[_]ElementConfig{.{ .name = "div" }},
        .removeElements = &[_][]const u8{ "script" },
    };
    try testing.expectError(error.InvalidConfig, config3.validate());

    // Invalid config: both attributes lists
    const config4 = SanitizerConfig{
        .attributes = &[_][]const u8{ "class" },
        .removeAttributes = &[_][]const u8{ "onclick" },
    };
    try testing.expectError(error.InvalidConfig, config4.validate());
}

test "SanitizerConfig element filtering" {
    // Allowlist mode
    const config1 = SanitizerConfig{
        .elements = &[_]ElementConfig{ .{ .name = "div" }, .{ .name = "p" }, .{ .name = "span" } },
    };
    try testing.expect(config1.isElementAllowed("div"));
    try testing.expect(config1.isElementAllowed("p"));
    try testing.expect(!config1.isElementAllowed("script"));

    // Blocklist mode
    const config2 = SanitizerConfig{
        .removeElements = &[_][]const u8{ "script", "iframe" },
    };
    try testing.expect(config2.isElementAllowed("div"));
    try testing.expect(!config2.isElementAllowed("script"));
    try testing.expect(!config2.isElementAllowed("iframe"));
}

test "SanitizerConfig framework attributes" {
    // All frameworks enabled
    const config1 = SanitizerConfig.default();
    try testing.expect(config1.isAttributeAllowed("x-show")); // Alpine
    try testing.expect(config1.isAttributeAllowed("v-if")); // Vue
    try testing.expect(config1.isAttributeAllowed("hx-get")); // HTMX
    try testing.expect(config1.isAttributeAllowed("phx-value-id")); // Phoenix (non-event)

    // Event handlers always blocked
    try testing.expect(!config1.isAttributeAllowed("x-on:click"));
    try testing.expect(!config1.isAttributeAllowed("v-on:submit"));
    try testing.expect(!config1.isAttributeAllowed("@click"));
    try testing.expect(!config1.isAttributeAllowed("phx-click")); // Phoenix event handler

    // Strict mode: no frameworks
    const config2 = SanitizerConfig.strict();
    try testing.expect(!config2.isAttributeAllowed("x-show"));
    try testing.expect(!config2.isAttributeAllowed("v-if"));
    try testing.expect(!config2.isAttributeAllowed("hx-get"));

    // Custom framework config
    const config3 = SanitizerConfig{
        .frameworks = .{
            .allow_alpine = true,
            .allow_vue = false,
            .allow_htmx = true,
            .allow_phoenix = false,
        },
    };
    try testing.expect(config3.isAttributeAllowed("x-show")); // Alpine allowed
    try testing.expect(!config3.isAttributeAllowed("v-if")); // Vue blocked
    try testing.expect(config3.isAttributeAllowed("hx-get")); // HTMX allowed
    try testing.expect(!config3.isAttributeAllowed("phx-click")); // Phoenix blocked
}

test "Sanitizer wrapper creation" {
    const allocator = testing.allocator;

    // Default sanitizer
    const san1 = try Sanitizer.initDefault(allocator);
    defer san1.deinit();
    try testing.expect(san1.config.frameworks.allow_alpine);

    // Strict sanitizer
    const san2 = try Sanitizer.initStrict(allocator);
    defer san2.deinit();
    try testing.expect(!san2.config.frameworks.allow_alpine);

    // Permissive sanitizer
    const san3 = try Sanitizer.initPermissive(allocator);
    defer san3.deinit();
    try testing.expect(san3.config.comments);

    // Trusted sanitizer
    const san4 = try Sanitizer.initTrusted(allocator);
    defer san4.deinit();
    try testing.expect(san4.config.bypassSafety);

    // None sanitizer
    const san5 = try Sanitizer.initNone(allocator);
    defer san5.deinit();
    try testing.expect(san5.config.bypassSafety);
}

test "SanitizerConfig bypassSafety for trusted content" {
    // Normal config: event handlers blocked
    const config1 = SanitizerConfig.default();
    try testing.expect(!config1.isAttributeAllowed("onclick"));
    try testing.expect(!config1.isAttributeAllowed("x-on:click"));
    try testing.expect(!config1.isAttributeAllowed("@click"));
    try testing.expect(!config1.isAttributeAllowed("phx-click"));

    // Trusted config: event handlers allowed
    const config2 = SanitizerConfig.trusted();
    try testing.expect(config2.isAttributeAllowed("onclick"));
    try testing.expect(config2.isAttributeAllowed("x-on:click"));
    try testing.expect(config2.isAttributeAllowed("@click"));
    try testing.expect(config2.isAttributeAllowed("phx-click"));

    // None config: everything allowed
    const config3 = SanitizerConfig.none();
    try testing.expect(config3.isAttributeAllowed("onclick"));
    try testing.expect(config3.isAttributeAllowed("onerror"));
    try testing.expect(config3.isAttributeAllowed("x-on:submit"));

    // Custom config with bypassSafety
    const config4 = SanitizerConfig{
        .bypassSafety = true,
        .frameworks = .{
            .allow_alpine = true,
            .allow_vue = false, // Framework filter still applies!
        },
    };
    try testing.expect(config4.isAttributeAllowed("x-on:click")); // Allowed (bypass)
    try testing.expect(!config4.isAttributeAllowed("v-if")); // Blocked (framework disabled)
}

test "SanitizerConfig two-level filtering: bypassSafety + framework config" {
    // This test explicitly demonstrates that bypassSafety and framework config
    // are TWO SEPARATE FILTER LEVELS:
    // 1. bypassSafety allows event handlers through the safety filter
    // 2. Framework-specific settings can still block attributes

    const config = SanitizerConfig{
        .bypassSafety = true, // Bypass safety checks for event handlers
        .frameworks = .{
            .allow_alpine = true, // Allow Alpine.js
            .allow_vue = false, // Block Vue.js
            .allow_htmx = true, // Allow HTMX
            .allow_phoenix = false, // Block Phoenix
        },
    };

    // HTML event handlers: Allowed (bypassSafety=true)
    try testing.expect(config.isAttributeAllowed("onclick"));
    try testing.expect(config.isAttributeAllowed("onerror"));
    try testing.expect(config.isAttributeAllowed("onload"));

    // Alpine.js events: Allowed (bypassSafety=true + allow_alpine=true)
    try testing.expect(config.isAttributeAllowed("x-on:click"));
    try testing.expect(config.isAttributeAllowed("x-on:submit"));

    // Alpine.js non-events: Allowed (allow_alpine=true)
    try testing.expect(config.isAttributeAllowed("x-show"));
    try testing.expect(config.isAttributeAllowed("x-model"));

    // Vue.js events: BLOCKED (allow_vue=false overrides bypassSafety!)
    try testing.expect(!config.isAttributeAllowed("@click"));
    try testing.expect(!config.isAttributeAllowed("v-on:submit"));

    // Vue.js non-events: BLOCKED (allow_vue=false)
    try testing.expect(!config.isAttributeAllowed("v-if"));
    try testing.expect(!config.isAttributeAllowed("v-for"));

    // HTMX events: Allowed (bypassSafety=true + allow_htmx=true)
    try testing.expect(config.isAttributeAllowed("hx-on:click"));

    // HTMX non-events: Allowed (allow_htmx=true)
    try testing.expect(config.isAttributeAllowed("hx-get"));

    // Phoenix events: BLOCKED (allow_phoenix=false overrides bypassSafety!)
    try testing.expect(!config.isAttributeAllowed("phx-click"));

    // Phoenix non-events: BLOCKED (allow_phoenix=false)
    try testing.expect(!config.isAttributeAllowed("phx-value-id"));
}

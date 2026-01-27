//! Unified HTML specification for attributes and elements
//!
//! This module provides a single source of truth for HTML element specifications,
//! including allowed attributes and their valid values. Used by both the sanitizer
//! for security validation and the syntax highlighter for visual styling.

const std = @import("std");
const z = @import("../root.zig");
const Err = z.Err;
const print = std.debug.print;

//=========================================================================================================
// CENTRALIZED FRAMEWORK ATTRIBUTE SYSTEM
//=========================================================================================================

/// Framework specification for modern web frameworks
pub const FrameworkSpec = struct {
    prefix: []const u8,
    name: []const u8,
    safe: bool = true,
    description: []const u8 = "",
};

/// Blacklist of Attributes that are inherently dangerous and should always be blocked unless explicitly handled by framework logic.
/// Using StaticStringMap for O(1) lookup performance (used in hot sanitizer paths)
pub const DANGEROUS_ATTRIBUTES = std.StaticStringMap(void).initComptime(.{
    // Script execution (event handlers)
    .{ "onclick", {} },
    .{ "onload", {} },
    .{ "onerror", {} },
    .{ "onmouseover", {} },
    .{ "onfocus", {} },
    .{ "onblur", {} },
    .{ "onchange", {} },
    .{ "onsubmit", {} },
    .{ "onkeydown", {} },
    .{ "onkeyup", {} },
    .{ "onmouseenter", {} },
    .{ "onmouseleave", {} },
    .{ "onresize", {} },
    .{ "onmessage", {} },
    .{ "onstorage", {} },
    .{ "onunload", {} },
    .{ "onbeforeunload", {} },
    .{ "onhashchange", {} },

    // HTML injection vectors
    .{ "innerHTML", {} },
    .{ "outerHTML", {} },
    .{ "insertAdjacentHTML", {} },

    // Dangerous framework-specifics (if not using the framework safely)
    .{ "x-html", {} },
    .{ "v-html", {} },
    .{ "ng-bind-html", {} },

    // Legacy / Obscure
    .{ "integrity", {} }, // Can be abused to load malicious resources
    .{ "formaction", {} }, // Can hijack form submissions
    .{ "background", {} }, // Legacy background attribute can execute script in IE
});

pub const DANGEROUS_JS_PATTERNS = [_][]const u8{
    "import(",
    "eval(",
    "function(",
    "setTimeout(",
    "setInterval(",
    "new Function(",
    "document.write",
    "document.createElement",
    "window.open",
    "location.href",
    ".innerHTML",
    ".outerHTML",
    "fetch(",
    "XMLHttpRequest",
    "WebSocket(",
    "postMessage(",
    "javascript:",
    "vbscript:",
    "data:",
    "data:text/html",
    "data:text/javascript",
    "data:text/xml",
    "data:image/svg",
};

/// Patterns that indicate the entire CSS should be rejected (not per-property filtering)
/// For example, @import means external CSS loading which is always dangerous
/// Note: Property-level patterns like expression() are handled in DANGEROUS_CSS_VALUES
pub const DANGEROUS_CSS_PATTERNS = [_][]const u8{
    "-moz-binding:", // Firefox XBL binding - always dangerous
    "javascript:",
    "vbscript:",
    "data:text/html",
    "data:text/javascript",
    "data:application/xhtml",
    "@import", // External CSS loading
    "@charset", // Can be used to bypass sanitization
    "@namespace", // Can enable SVG/XLink attacks
};

pub const DANGEROUS_CSS_PROPERTIES = [_][]const u8{
    "behavior",
    "-moz-binding",
    "-webkit-user-modify",
    "-o-link",
    "-o-link-source",
    "filter", // when used with progid:
};

pub const DANGEROUS_CSS_VALUES = [_][]const u8{
    "url(javascript:",
    "url(vbscript:",
    "url(data:text/html",
    "url(data:text/javascript",
    "expression(",
    "eval(",
    "calc(",
    "var(",
};

//=========================================================================================================
// SVG SECURITY: Element and Attribute Allowlists
//=========================================================================================================

/// SVG elements that are safe for rendering (allowlist approach)
/// These are purely visual elements with no scripting or external resource loading capability
pub const SVG_ALLOWED_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    // Container elements
    .{ "svg", {} },
    .{ "g", {} },
    .{ "defs", {} },
    .{ "symbol", {} },
    .{ "clipPath", {} },
    .{ "mask", {} },
    .{ "pattern", {} },
    .{ "marker", {} },

    // Shape elements
    .{ "circle", {} },
    .{ "ellipse", {} },
    .{ "line", {} },
    .{ "path", {} },
    .{ "polygon", {} },
    .{ "polyline", {} },
    .{ "rect", {} },

    // Text elements
    .{ "text", {} },
    .{ "tspan", {} },
    .{ "textPath", {} },

    // Gradient elements
    .{ "linearGradient", {} },
    .{ "radialGradient", {} },
    .{ "stop", {} },

    // Filter elements (visual effects only)
    .{ "filter", {} },
    .{ "feBlend", {} },
    .{ "feColorMatrix", {} },
    .{ "feComponentTransfer", {} },
    .{ "feComposite", {} },
    .{ "feConvolveMatrix", {} },
    .{ "feDiffuseLighting", {} },
    .{ "feDisplacementMap", {} },
    .{ "feFlood", {} },
    .{ "feGaussianBlur", {} },
    .{ "feMerge", {} },
    .{ "feMergeNode", {} },
    .{ "feMorphology", {} },
    .{ "feOffset", {} },
    .{ "feSpecularLighting", {} },
    .{ "feTile", {} },
    .{ "feTurbulence", {} },
    .{ "feDistantLight", {} },
    .{ "fePointLight", {} },
    .{ "feSpotLight", {} },
    .{ "feFuncR", {} },
    .{ "feFuncG", {} },
    .{ "feFuncB", {} },
    .{ "feFuncA", {} },

    // Descriptive elements
    .{ "title", {} },
    .{ "desc", {} },
    .{ "metadata", {} },
});

/// SVG elements that are dangerous and must be blocked
/// These can execute scripts, load external resources, or escape SVG context
pub const SVG_DANGEROUS_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    // Script execution
    .{ "script", {} },

    // External resource loading (SSRF, XSS via external SVG)
    .{ "image", {} }, // Can load external images/SVG via href
    .{ "use", {} }, // Can reference external SVG fragments via href
    .{ "feImage", {} }, // Filter that loads external images

    // HTML embedding (escapes SVG context)
    .{ "foreignObject", {} }, // Embeds arbitrary HTML/XHTML

    // Animation with event handlers (can trigger JS)
    .{ "animate", {} }, // onbegin, onend, onrepeat events
    .{ "animateMotion", {} },
    .{ "animateTransform", {} },
    .{ "set", {} },
    .{ "animateColor", {} }, // Deprecated but still dangerous

    // Links (can contain javascript: URLs)
    .{ "a", {} },

    // Other potentially dangerous
    .{ "switch", {} }, // Can be used for conditional content loading
    .{ "view", {} }, // Can trigger navigation
});

//=========================================================================================================
// MATHML SECURITY: Element and Attribute Allowlists
//=========================================================================================================

/// MathML elements that are dangerous and MUST be removed entirely (blacklist)
/// These can execute JavaScript or load external resources
pub const MATHML_DANGEROUS_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    // Can execute JavaScript
    .{ "maction", {} },        // Has actiontype and xlink:href attributes
    .{ "annotation-xml", {} }, // Can contain HTML/SVG with scripts
    .{ "annotation", {} },     // Can contain text that gets executed
    .{ "semantics", {} },      // Wrapper for dangerous annotations

    // Can load external resources or have style risks
    .{ "mpadded", {} },     // Can have background images
    .{ "mphantom", {} },    // Similar risks
    .{ "maligngroup", {} }, // Style/layout risks
    .{ "malignmark", {} },  // Style/layout risks
});

/// Safe MathML elements (allowlist) - purely for mathematical notation
/// These are token and layout elements with no scripting capability
pub const MATHML_SAFE_ELEMENTS = std.StaticStringMap(void).initComptime(.{
    // The root element
    .{ "math", {} },

    // Basic token elements (text only)
    .{ "mi", {} },    // identifier
    .{ "mo", {} },    // operator
    .{ "mn", {} },    // number
    .{ "ms", {} },    // string literal
    .{ "mtext", {} }, // text

    // Basic layout (structure only)
    .{ "mrow", {} },
    .{ "mfrac", {} },
    .{ "msqrt", {} },
    .{ "mroot", {} },
    .{ "mfenced", {} },

    // Script style (structure)
    .{ "msub", {} },
    .{ "msup", {} },
    .{ "msubsup", {} },
    .{ "munder", {} },
    .{ "mover", {} },
    .{ "munderover", {} },

    // Tables (structure)
    .{ "mtable", {} },
    .{ "mtr", {} },
    .{ "mtd", {} },
    .{ "mlabeledtr", {} },

    // Other safe layout elements
    .{ "mspace", {} },
    .{ "menclose", {} },
    .{ "merror", {} },
    .{ "mstyle", {} },
});

/// Safe attributes for MathML elements
/// Note: href, xlink:href, and other link attributes are NOT safe
pub const MATHML_SAFE_ATTRIBUTES = std.StaticStringMap(void).initComptime(.{
    // Structural attributes
    .{ "dir", {} },
    .{ "mathsize", {} },
    .{ "mathvariant", {} },
    .{ "mathcolor", {} },      // Validated separately for color values
    .{ "mathbackground", {} }, // Validated separately for color values

    // Positioning
    .{ "align", {} },
    .{ "rowalign", {} },
    .{ "columnalign", {} },

    // Safe presentation
    .{ "width", {} },
    .{ "height", {} },
    .{ "depth", {} },
    .{ "lspace", {} },
    .{ "rspace", {} },

    // Display attributes
    .{ "display", {} },
    .{ "displaystyle", {} },
    .{ "scriptlevel", {} },

    // Fence attributes
    .{ "open", {} },
    .{ "close", {} },
    .{ "separators", {} },

    // Table attributes
    .{ "rowspan", {} },
    .{ "columnspan", {} },
    .{ "rowspacing", {} },
    .{ "columnspacing", {} },
    .{ "frame", {} },
    .{ "framespacing", {} },
});

/// Check if a MathML element is dangerous
pub fn isMathMLElementDangerous(tag_name: []const u8) bool {
    return MATHML_DANGEROUS_ELEMENTS.has(tag_name);
}

/// Check if a MathML element is safe
pub fn isMathMLElementSafe(tag_name: []const u8) bool {
    return MATHML_SAFE_ELEMENTS.has(tag_name);
}

/// Check if a MathML attribute is safe
pub fn isMathMLAttributeSafe(attr_name: []const u8) bool {
    return MATHML_SAFE_ATTRIBUTES.has(attr_name);
}

/// Check if an SVG element is in the allowlist
pub fn isSvgElementAllowed(tag_name: []const u8) bool {
    return SVG_ALLOWED_ELEMENTS.has(tag_name);
}

/// Check if an SVG element is explicitly dangerous
pub fn isSvgElementDangerous(tag_name: []const u8) bool {
    return SVG_DANGEROUS_ELEMENTS.has(tag_name);
}

/// DOM Clobbering Protection
/// These are property names that, when used as `id` or `name` attributes,
/// can shadow built-in DOM properties and break JavaScript code.
/// Example: <img id="location"> makes window.location return the img element
pub const DOM_CLOBBERING_NAMES = std.StaticStringMap(void).initComptime(.{
    // Window properties
    .{ "location", {} },
    .{ "document", {} },
    .{ "window", {} },
    .{ "self", {} },
    .{ "top", {} },
    .{ "parent", {} },
    .{ "frames", {} },
    .{ "opener", {} },
    .{ "closed", {} },
    .{ "length", {} },
    .{ "name", {} },
    .{ "navigator", {} },
    .{ "history", {} },
    .{ "screen", {} },
    .{ "localStorage", {} },
    .{ "sessionStorage", {} },
    // Document properties
    .{ "cookie", {} },
    .{ "domain", {} },
    .{ "referrer", {} },
    .{ "body", {} },
    .{ "head", {} },
    .{ "forms", {} },
    .{ "images", {} },
    .{ "links", {} },
    .{ "scripts", {} },
    .{ "anchors", {} },
    .{ "URL", {} },
    .{ "documentElement", {} },
    .{ "defaultView", {} },
    // Common methods that get clobbered
    .{ "createElement", {} },
    .{ "getElementById", {} },
    .{ "getElementsByTagName", {} },
    .{ "getElementsByClassName", {} },
    .{ "querySelector", {} },
    .{ "querySelectorAll", {} },
    .{ "write", {} },
    .{ "writeln", {} },
    .{ "open", {} },
    .{ "close", {} },
    .{ "alert", {} },
    .{ "confirm", {} },
    .{ "prompt", {} },
    .{ "fetch", {} },
    .{ "XMLHttpRequest", {} },
    .{"__proto__"},
    .{"constructor"},
});

/// Check if a value would cause DOM clobbering when used as id or name attribute
pub fn isDomClobberingName(value: []const u8) bool {
    return DOM_CLOBBERING_NAMES.has(value);
}

/// Check if an attribute is in the dangerous blacklist
/// Includes explicit event handlers (onclick, etc.) and dangerous framework attributes
pub fn isDangerousAttribute(attr: []const u8) bool {
    // Check explicit blacklist - O(1) lookup
    if (DANGEROUS_ATTRIBUTES.has(attr)) {
        return true;
    }
    // Also catch any on* event handlers not in the list
    if (std.mem.startsWith(u8, attr, "on") and attr.len > 2) {
        // Check if it looks like an event handler (onX where X is lowercase letter)
        if (attr.len > 2 and std.ascii.isAlphabetic(attr[2])) {
            return true;
        }
    }
    return false;
}

/// Centralized list of supported web frameworks and their attribute prefixes
/// This is the single source of truth for framework attribute validation
///
/// SECURITY NOTE: Event handler attributes (prefixed with @ or containing :on, etc.)
/// are marked as unsafe because they contain executable JavaScript.
/// DOMPurify allows them because browsers don't execute framework-specific handlers,
/// but in environments with a JS runtime (like QuickJS), they become real XSS vectors.
pub const FRAMEWORK_SPECS = [_]FrameworkSpec{
    .{ .prefix = "hx-", .name = "HTMX", .description = "HTMX attributes for server-side interactions" },
    .{ .prefix = "phx-", .name = "Phoenix LiveView", .description = "Phoenix LiveView events and bindings" },
    .{ .prefix = "x-", .name = "Alpine.js", .description = "Alpine.js directives" }, // x-on: checked separately
    .{ .prefix = "v-", .name = "Vue.js", .description = "Vue.js directives" }, // v-on: checked separately
    .{ .prefix = "@", .name = "Vue.js Events", .description = "Vue.js event handlers (@click, etc.)", .safe = false }, // Contains JS!
    .{ .prefix = ":", .name = "Vue.js/Phoenix Directives", .description = "Directive syntax (:if, :for, etc.)" },
    .{ .prefix = "data-", .name = "HTML Data", .description = "Standard HTML data attributes" },
    .{ .prefix = "aria-", .name = "ARIA", .description = "Accessibility attributes" },
    .{ .prefix = "*ng", .name = "Angular", .description = "Angular structural directives (*ngFor, *ngIf)" },
    .{ .prefix = "[", .name = "Angular Property", .description = "Angular property binding" },
    .{ .prefix = "(", .name = "Angular Event", .description = "Angular event binding", .safe = false }, // Contains JS!
    .{ .prefix = "bind:", .name = "Svelte Bind", .description = "Svelte binding directives" },
    .{ .prefix = "on:", .name = "Svelte Event", .description = "Svelte event handlers", .safe = false }, // Contains JS!
    .{ .prefix = "use:", .name = "Svelte Action", .description = "Svelte action directives" },
    .{ .prefix = "slot", .name = "Web Components", .description = "Web Components slots", .safe = false },
    .{ .prefix = ":for", .name = "Framework loops", .description = "Framework loop directive" },
    .{ .prefix = ":if", .name = "Framework conditionals", .description = "Framework conditional directive" },
    .{ .prefix = ":let", .name = "Framework declarations", .description = "Framework declaration" },
};

/// Check if an attribute name matches any supported framework pattern
pub fn isFrameworkAttribute(attr_name: []const u8) bool {
    inline for (FRAMEWORK_SPECS) |spec| {
        if (std.mem.startsWith(u8, attr_name, spec.prefix)) {
            return true;
        }
    }
    return false;
}

/// Get the framework specification for a given attribute name
pub fn getFrameworkSpec(attr_name: []const u8) ?FrameworkSpec {
    inline for (FRAMEWORK_SPECS) |spec| {
        if (std.mem.startsWith(u8, attr_name, spec.prefix)) {
            return spec;
        }
    }
    return null;
}

/// Check if a framework attribute is safe (not dangerous)
pub fn isFrameworkAttributeSafe(attr_name: []const u8) bool {
    // First check if it's a framework event handler (contains executable JS)
    if (isFrameworkEventHandler(attr_name)) {
        return false;
    }

    if (getFrameworkSpec(attr_name)) |spec| {
        return spec.safe;
    }
    return false; // Unknown framework attributes are not safe
}

/// Check if a framework attribute is an event handler (contains executable JavaScript)
/// These are dangerous in environments with a JS runtime (like QuickJS)
pub fn isFrameworkEventHandler(attr_name: []const u8) bool {
    // Alpine.js: x-on:click, x-on:submit, etc.
    if (std.mem.startsWith(u8, attr_name, "x-on:")) return true;
    if (std.mem.startsWith(u8, attr_name, "x-on.")) return true; // x-on.prevent, etc.

    // Vue.js: v-on:click, v-on:submit, etc.
    if (std.mem.startsWith(u8, attr_name, "v-on:")) return true;

    // HTMX: hx-on:click, hx-on::before-request, etc.
    if (std.mem.startsWith(u8, attr_name, "hx-on:")) return true;
    if (std.mem.startsWith(u8, attr_name, "hx-on-")) return true; // Alternative syntax

    // Phoenix LiveView: phx-click, phx-submit, phx-change, etc.
    if (std.mem.startsWith(u8, attr_name, "phx-click")) return true;
    if (std.mem.startsWith(u8, attr_name, "phx-submit")) return true;
    if (std.mem.startsWith(u8, attr_name, "phx-change")) return true;
    if (std.mem.startsWith(u8, attr_name, "phx-blur")) return true;
    if (std.mem.startsWith(u8, attr_name, "phx-focus")) return true;
    if (std.mem.startsWith(u8, attr_name, "phx-keyup")) return true;
    if (std.mem.startsWith(u8, attr_name, "phx-keydown")) return true;
    if (std.mem.startsWith(u8, attr_name, "phx-window-")) return true;

    // Vue.js shorthand already handled by @ prefix being unsafe

    // Angular already handled by ( prefix being unsafe

    // Svelte already handled by on: prefix being unsafe

    return false;
}

/// Signature for attribute value validator functions
pub const AttrValidator = *const fn ([]const u8) bool;

/// Specification for an HTML attribute
pub const AttrSpec = struct {
    name: []const u8,
    /// If null, any value is allowed. If provided, only these values are valid.
    valid_values: ?[]const []const u8 = null,
    validator: ?AttrValidator = null,
    /// Whether this attribute is considered safe for sanitization
    safe: bool = true,
};

/// Specification for an HTML element
pub const ElementSpec = struct {
    tag_enum: z.HtmlTag,
    allowed_attrs: []const AttrSpec,
    /// Whether this element is void (self-closing)
    void_element: bool = false,

    /// Get the string representation of the tag
    pub fn tagName(self: @This()) []const u8 {
        return self.tag_enum.toString();
    }
};

// --- VALIDATORS ---

/// Helper for case-insensitive prefix check
pub fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

/// Validates SVG href/xlink:href attributes
/// SVG URIs are more restricted because they can:
/// - Load external resources (SSRF risk)
/// - Execute code via javascript: URLs
/// - Load malicious SVG via data: URLs
///
/// Validate SVG URI references (for href, xlink:href attributes)
///
/// SECURITY: Only fragment-only references (#id) are allowed.
/// This is stricter than general URI validation because:
/// - "evil.svg#payload" could load external SVG with malicious content
/// - Even same-origin relative paths are dangerous in SVG context
/// - Most SVG XSS CVEs in the last 5 years involved <use> with non-fragment URIs
///
/// Allowed: #icon, #symbol-name, #my-gradient
/// Blocked: evil.svg#payload, ./icons.svg#icon, http://..., javascript:...
///
/// Note: We block <use> entirely (SVG_DANGEROUS_ELEMENTS), but this validator
/// ensures defense-in-depth for any SVG element with href/xlink:href.
pub fn validateSvgUri(value: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const decoded = normalizeUri(&buf, value) catch value;
    const trimmed = trimUnicodeWhitespace(decoded);
    if (trimmed.len == 0) return false;

    // STRICT: Only allow fragment-only references (#id)
    // This is the only safe pattern for SVG URI attributes.
    // Relative paths like "icons.svg#foo" can still load external resources.
    return trimmed[0] == '#';
}

/// Normalize URI value by decoding HTML entities and trimming Unicode whitespace.
/// This prevents bypasses like `&nbsp;javascript:` or `​javascript:` (zero-width space).
/// Returns a slice into the provided buffer.
fn normalizeUri(buf: []u8, value: []const u8) ![]const u8 {
    var len: usize = 0;

    var i: usize = 0;
    while (i < value.len and len < buf.len) {
        if (value[i] == '&') {
            // Decode common HTML entities that could hide whitespace
            if (std.mem.startsWith(u8, value[i..], "&nbsp;")) {
                buf[len] = 0xA0; // Non-breaking space
                len += 1;
                i += 6;
            } else if (std.mem.startsWith(u8, value[i..], "&#xA0;") or std.mem.startsWith(u8, value[i..], "&#160;")) {
                buf[len] = 0xA0;
                len += 1;
                i += if (value[i + 2] == 'x') 6 else 6;
            } else if (std.mem.startsWith(u8, value[i..], "&#x")) {
                // Decode hex entity &#x1680; etc.
                const end = std.mem.indexOfScalar(u8, value[i..], ';') orelse {
                    buf[len] = value[i];
                    len += 1;
                    i += 1;
                    continue;
                };
                const hex_str = value[i + 3 .. i + end];
                if (std.fmt.parseInt(u21, hex_str, 16)) |codepoint| {
                    // Encode as UTF-8
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                        buf[len] = value[i];
                        len += 1;
                        i += 1;
                        continue;
                    };
                    if (len + utf8_len <= buf.len) {
                        @memcpy(buf[len..][0..utf8_len], utf8_buf[0..utf8_len]);
                        len += utf8_len;
                    }
                    i += end + 1;
                } else |_| {
                    buf[len] = value[i];
                    len += 1;
                    i += 1;
                }
            } else if (std.mem.startsWith(u8, value[i..], "&#")) {
                // Decode decimal entity &#8192; etc.
                const end = std.mem.indexOfScalar(u8, value[i..], ';') orelse {
                    buf[len] = value[i];
                    len += 1;
                    i += 1;
                    continue;
                };
                const dec_str = value[i + 2 .. i + end];
                if (std.fmt.parseInt(u21, dec_str, 10)) |codepoint| {
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                        buf[len] = value[i];
                        len += 1;
                        i += 1;
                        continue;
                    };
                    if (len + utf8_len <= buf.len) {
                        @memcpy(buf[len..][0..utf8_len], utf8_buf[0..utf8_len]);
                        len += utf8_len;
                    }
                    i += end + 1;
                } else |_| {
                    buf[len] = value[i];
                    len += 1;
                    i += 1;
                }
            } else {
                buf[len] = value[i];
                len += 1;
                i += 1;
            }
        } else {
            buf[len] = value[i];
            len += 1;
            i += 1;
        }
    }

    return buf[0..len];
}

/// Check if a character is Unicode whitespace (not just ASCII)
fn isUnicodeWhitespace(c: u8, view: []const u8, idx: usize) bool {
    // ASCII whitespace
    if (std.ascii.isWhitespace(c)) return true;

    // Check for multi-byte Unicode whitespace
    if (idx + 2 < view.len) {
        const bytes = view[idx..@min(idx + 3, view.len)];
        // U+00A0 non-breaking space (0xC2 0xA0)
        if (bytes.len >= 2 and bytes[0] == 0xC2 and bytes[1] == 0xA0) return true;
        // U+1680 Ogham space mark (0xE1 0x9A 0x80)
        if (bytes.len >= 3 and bytes[0] == 0xE1 and bytes[1] == 0x9A and bytes[2] == 0x80) return true;
        // U+180E Mongolian vowel separator (0xE1 0xA0 0x8E)
        if (bytes.len >= 3 and bytes[0] == 0xE1 and bytes[1] == 0xA0 and bytes[2] == 0x8E) return true;
        // U+2000-U+200B various spaces (0xE2 0x80 0x80-0x8B)
        if (bytes.len >= 3 and bytes[0] == 0xE2 and bytes[1] == 0x80 and bytes[2] >= 0x80 and bytes[2] <= 0x8B) return true;
        // U+205F medium mathematical space (0xE2 0x81 0x9F)
        if (bytes.len >= 3 and bytes[0] == 0xE2 and bytes[1] == 0x81 and bytes[2] == 0x9F) return true;
        // U+3000 ideographic space (0xE3 0x80 0x80)
        if (bytes.len >= 3 and bytes[0] == 0xE3 and bytes[1] == 0x80 and bytes[2] == 0x80) return true;
    }

    return false;
}

/// Trim Unicode whitespace from both ends
fn trimUnicodeWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;

    // Trim from start
    while (start < end) {
        if (isUnicodeWhitespace(value[start], value, start)) {
            // Skip the whitespace character (could be multi-byte)
            if (start + 1 < end and value[start] >= 0xC0) {
                // Multi-byte UTF-8
                if (value[start] < 0xE0) start += 2
                else if (value[start] < 0xF0) start += 3
                else start += 4;
            } else {
                start += 1;
            }
        } else {
            break;
        }
    }

    // Trim from end
    while (end > start) {
        const idx = end - 1;
        if (isUnicodeWhitespace(value[idx], value, idx)) {
            end = idx;
            // Also need to check if this is part of multi-byte sequence
            while (end > start and (value[end - 1] & 0xC0) == 0x80) {
                end -= 1;
            }
            if (end > start and (value[end - 1] & 0x80) != 0) {
                end -= 1;
            }
        } else {
            break;
        }
    }

    return value[start..end];
}

/// Validates that a URI is safe (no javascript:, vbscript:, data: blocks)
/// Validates that a URI is safe for HTML elements (img src, a href, etc.)
/// Strategy: Allow known-good protocols, Block known-bad protocols.
/// IMPORTANT: Decodes HTML entities and trims Unicode whitespace to prevent bypasses.
pub fn validateUri(value: []const u8) bool {
    // Use a stack buffer for normalization (no allocation)
    var buf: [4096]u8 = undefined;

    // Decode HTML entities that could hide dangerous protocols
    const decoded = normalizeUri(&buf, value) catch value;

    // Trim both ASCII and Unicode whitespace
    const trimmed = trimUnicodeWhitespace(decoded);

    if (startsWithIgnoreCase(trimmed, "javascript:")) return false;
    if (startsWithIgnoreCase(trimmed, "vbscript:")) return false;
    if (startsWithIgnoreCase(trimmed, "file:")) return false;

    // Strict checks on data: URIs
    if (startsWithIgnoreCase(trimmed, "data:")) {
        // Only allow image data URIs
        if (!startsWithIgnoreCase(trimmed, "data:image/")) return false;
        // Block SVG images as they can contain scripts
        if (startsWithIgnoreCase(trimmed, "data:image/svg")) return false;
        if (startsWithIgnoreCase(trimmed, "data:text/javascript")) return false;
        if (startsWithIgnoreCase(trimmed, "data:text/html")) return false;
        if (startsWithIgnoreCase(trimmed, "data:text/xml")) return false;

        return true;
    }

    // default Allow (http, https, relative, mailto, etc.)
    return true;
}

/// Validates style strings to prevent easy XSS vectors (url(), expression())
pub fn validateStyle(value: []const u8) bool {
    // Block CSS expressions (IE legacy vector)
    if (std.mem.indexOf(u8, value, "expression") != null) return false;
    if (std.mem.indexOf(u8, value, "behavior") != null) return false;

    // Block external URLs in styles (prevents data exfiltration / drive-by)
    // NOTE: This is strict. Remove if you want to allow background images.
    if (std.mem.indexOf(u8, value, "url(") != null) return false;

    // Block javascript: in styles (unlikely but possible in some older browsers)
    if (std.mem.indexOf(u8, value, "javascript:") != null) return false;

    return true;
}

fn validateSandbox(value: []const u8) bool {
    // Check for dangerous sandbox values
    if (std.mem.indexOf(u8, value, "allow-scripts") != null) {
        return false;
    }
    // Could also validate other dangerous combinations
    return true;
}

/// Common attributes that are allowed on most elements
const common_attrs = [_]AttrSpec{
    .{ .name = "id" },
    .{ .name = "class" },
    .{ .name = "style", .validator = validateStyle },
    .{ .name = "title" },
    .{ .name = "lang" },
    .{ .name = "width" },
    .{ .name = "height" },
    .{ .name = "dir", .valid_values = &[_][]const u8{ "ltr", "rtl", "auto" } },
    .{ .name = "aria" }, // prefix match for aria-* attributes
    .{ .name = "data" }, // prefix match for data-* attributes
    .{ .name = "hidden", .valid_values = &[_][]const u8{""} }, // boolean attribute
    .{ .name = "role" },
    .{ .name = "tabindex" },
    .{ .name = "contenteditable", .valid_values = &[_][]const u8{ "true", "false", "" } },
    .{ .name = "draggable", .valid_values = &[_][]const u8{ "true", "false", "auto" } },
    .{ .name = "spellcheck", .valid_values = &[_][]const u8{ "true", "false" } },
};

/// Table-specific attributes
const table_attrs = [_]AttrSpec{
    .{ .name = "scope", .valid_values = &[_][]const u8{ "col", "row", "colgroup", "rowgroup" } },
    .{ .name = "colspan" },
    .{ .name = "rowspan" },
} ++ common_attrs;

/// Form-specific attributes
const form_attrs = [_]AttrSpec{
    .{ .name = "action", .validator = validateUri },
    .{ .name = "method", .valid_values = &[_][]const u8{ "get", "post" } },
    .{ .name = "enctype" },
    .{ .name = "target" },
} ++ common_attrs;

/// Input-specific attributes
const input_attrs = [_]AttrSpec{
    .{ .name = "type", .valid_values = &[_][]const u8{ "text", "email", "password", "number", "tel", "url", "search", "submit", "reset", "button", "hidden" } },
    .{ .name = "name" },
    .{ .name = "value" },
    .{ .name = "placeholder" },
    .{ .name = "required", .valid_values = &[_][]const u8{""} }, // boolean attribute
    .{ .name = "minlength" },
    .{ .name = "maxlength" },
    .{ .name = "readonly", .valid_values = &[_][]const u8{""} }, // boolean attribute
} ++ common_attrs;

/// SVG-specific attributes
const svg_attrs = [_]AttrSpec{
    .{ .name = "viewBox" },
    .{ .name = "width" },
    .{ .name = "height" },
    .{ .name = "x" },
    .{ .name = "y" },
    .{ .name = "cx" },
    .{ .name = "cy" },
    .{ .name = "r" },
    .{ .name = "rx" },
    .{ .name = "ry" },
    .{ .name = "d" },
    .{ .name = "fill" },
    .{ .name = "stroke" },
    .{ .name = "stroke-width" },
    .{ .name = "href", .validator = validateSvgUri },
    .{ .name = "xlink:href", .validator = validateSvgUri },
} ++ common_attrs;

/// Image-specific attributes
const img_attrs = [_]AttrSpec{
    .{ .name = "src", .validator = validateUri },
    .{ .name = "alt" },
    .{ .name = "width" },
    .{ .name = "height" },
    .{ .name = "loading", .valid_values = &[_][]const u8{ "lazy", "eager", "auto" } },
    .{ .name = "decoding", .valid_values = &[_][]const u8{ "sync", "async", "auto" } },
    .{ .name = "srcset" },
    .{ .name = "sizes" },
    .{ .name = "crossorigin", .valid_values = &[_][]const u8{ "anonymous", "use-credentials" } },
    .{ .name = "referrerpolicy" },
    .{ .name = "usemap" },
    .{ .name = "ismap", .valid_values = &[_][]const u8{""} }, // boolean
} ++ common_attrs;

const iframe_attrs = [_]AttrSpec{
    .{ .name = "src", .validator = validateUri },
    .{ .name = "sandbox", .validator = validateSandbox },
    .{ .name = "srcdoc" },
    .{ .name = "name" },
    .{ .name = "loading" },
} ++ common_attrs;

/// Anchor-specific attributes
const anchor_attrs = [_]AttrSpec{
    .{ .name = "href", .validator = validateUri },
    .{ .name = "target", .valid_values = &[_][]const u8{ "_blank", "_self", "_parent", "_top" } },
    .{ .name = "rel" },
    .{ .name = "type" },
    .{ .name = "download" },
    .{ .name = "hreflang" },
    .{ .name = "ping" },
    .{ .name = "referrerpolicy" },
} ++ common_attrs;

/// Framework-specific attribute sets (for better organization)
const framework_attrs = [_]AttrSpec{
    // Alpine.js attributes
    .{ .name = "x-data" },
    .{ .name = "x-show" },
    .{ .name = "x-model" },
    .{ .name = "x-on" }, // prefix for x-on:*
    .{ .name = "x-bind" }, // prefix for x-bind:*
    .{ .name = "x-if" },
    .{ .name = "x-for" },
    .{ .name = "x-text" },
    .{ .name = "x-html" },
    .{ .name = "x-ref" },
    .{ .name = "x-cloak" },
    .{ .name = "x-ignore" },
    .{ .name = "x-init" },
    .{ .name = "x-transition" },

    // Phoenix LiveView attributes
    .{ .name = "phx-click" },
    .{ .name = "phx-submit" },
    .{ .name = "phx-change" },
    .{ .name = "phx-focus" },
    .{ .name = "phx-blur" },
    .{ .name = "phx-window-focus" },
    .{ .name = "phx-window-blur" },
    .{ .name = "phx-window-keydown" },
    .{ .name = "phx-window-keyup" },
    .{ .name = "phx-key" },
    .{ .name = "phx-value" }, // prefix for phx-value-*
    .{ .name = "phx-disable-with" },
    .{ .name = "phx-loading" },
    .{ .name = "phx-update" },
    .{ .name = "phx-hook" },
    .{ .name = "phx-debounce" },
    .{ .name = "phx-throttle" },
    .{ .name = "phx-target" },

    // Vue.js attributes
    .{ .name = "v-model" },
    .{ .name = "v-if" },
    .{ .name = "v-for" },
    .{ .name = "v-show" },
    .{ .name = "v-on" }, // prefix for v-on:*
    .{ .name = "v-bind" }, // prefix for v-bind:*
    .{ .name = "v-slot" },

    // Angular attributes
    .{ .name = "ng-model" },
    .{ .name = "ng-if" },
    .{ .name = "ng-for" },
    .{ .name = "ng-click" },
    .{ .name = "ng-submit" },
    .{ .name = "ng-change" },
} ++ common_attrs;

const custom_element_spec = ElementSpec{
    .tag_enum = .custom,
    .allowed_attrs = &([_]AttrSpec{
        .{ .name = "class" },
        .{ .name = "id" },
        .{ .name = "style", .validator = validateStyle },
        .{ .name = "src", .validator = validateUri },
        .{ .name = "href", .validator = validateUri },
        .{ .name = "title" },
        .{ .name = "lang" },
        .{ .name = "dir" },
        .{ .name = "role" },
        .{ .name = "tabindex" },
        .{ .name = "aria" }, // prefix for aria-*
        .{ .name = "data" }, // prefix for data-*
    } ++ framework_attrs),
    .void_element = false,
};

/// HTML element specifications
pub const element_specs = [_]ElementSpec{
    // Text elements (commonly used with frameworks)
    .{ .tag_enum = .body, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .p, .allowed_attrs = &framework_attrs },
    .{ .tag_enum = .span, .allowed_attrs = &framework_attrs },
    .{ .tag_enum = .div, .allowed_attrs = &framework_attrs },
    .{ .tag_enum = .h1, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .h2, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .h3, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .h4, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .h5, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .h6, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .strong, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .em, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .i, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .b, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .code, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .pre, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .blockquote, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .a, .allowed_attrs = &anchor_attrs },

    // Media elements
    .{ .tag_enum = .img, .allowed_attrs = &img_attrs, .void_element = true },
    .{ .tag_enum = .iframe, .allowed_attrs = &iframe_attrs, .void_element = true },

    // Table elements
    .{ .tag_enum = .table, .allowed_attrs = &table_attrs },
    .{ .tag_enum = .thead, .allowed_attrs = &table_attrs },
    .{ .tag_enum = .tbody, .allowed_attrs = &table_attrs },
    .{ .tag_enum = .tfoot, .allowed_attrs = &table_attrs },
    .{ .tag_enum = .tr, .allowed_attrs = &table_attrs },
    .{ .tag_enum = .th, .allowed_attrs = &table_attrs },
    .{ .tag_enum = .td, .allowed_attrs = &table_attrs },
    .{ .tag_enum = .caption, .allowed_attrs = &table_attrs },

    // Form elements
    .{ .tag_enum = .form, .allowed_attrs = &form_attrs },
    .{ .tag_enum = .input, .allowed_attrs = &input_attrs, .void_element = true },
    .{
        .tag_enum = .button,
        .allowed_attrs = &([_]AttrSpec{
            .{ .name = "type", .valid_values = &[_][]const u8{ "button", "submit", "reset" } },
            .{ .name = "disabled", .valid_values = &[_][]const u8{""} }, // boolean attribute
        } ++ common_attrs),
    },
    .{ .tag_enum = .textarea, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "name" },
        .{ .name = "rows" },
        .{ .name = "cols" },
        .{ .name = "placeholder" },
        .{ .name = "disabled", .valid_values = &[_][]const u8{""} },
        .{ .name = "required", .valid_values = &[_][]const u8{""} },
    } ++ common_attrs) },
    .{ .tag_enum = .select, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "name" },
        .{ .name = "multiple", .valid_values = &[_][]const u8{""} },
        .{ .name = "size" },
        .{ .name = "disabled", .valid_values = &[_][]const u8{""} },
        .{ .name = "required", .valid_values = &[_][]const u8{""} },
    } ++ common_attrs) },
    .{ .tag_enum = .option, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "value" },
        .{ .name = "selected", .valid_values = &[_][]const u8{""} },
        .{ .name = "disabled", .valid_values = &[_][]const u8{""} },
    } ++ common_attrs) },
    .{ .tag_enum = .optgroup, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "label" },
        .{ .name = "disabled", .valid_values = &[_][]const u8{""} },
    } ++ common_attrs) },
    .{ .tag_enum = .fieldset, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "disabled", .valid_values = &[_][]const u8{""} },
        .{ .name = "form" },
        .{ .name = "name" },
    } ++ common_attrs) },
    .{ .tag_enum = .legend, .allowed_attrs = &common_attrs },

    // List elements
    .{ .tag_enum = .ul, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .ol, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .li, .allowed_attrs = &common_attrs },

    // Definition list elements
    .{ .tag_enum = .dl, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .dt, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .dd, .allowed_attrs = &common_attrs },

    // Media elements
    .{ .tag_enum = .video, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "src", .validator = validateUri },
        .{ .name = "controls", .valid_values = &[_][]const u8{""} },
        .{ .name = "autoplay", .valid_values = &[_][]const u8{""} },
        .{ .name = "loop", .valid_values = &[_][]const u8{""} },
        .{ .name = "muted", .valid_values = &[_][]const u8{""} },
        .{ .name = "poster", .validator = validateUri },
        .{ .name = "preload", .valid_values = &[_][]const u8{ "none", "metadata", "auto" } },
        .{ .name = "width" },
        .{ .name = "height" },
    } ++ common_attrs) },
    .{ .tag_enum = .audio, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "src", .validator = validateUri },
        .{ .name = "controls", .valid_values = &[_][]const u8{""} },
        .{ .name = "autoplay", .valid_values = &[_][]const u8{""} },
        .{ .name = "loop", .valid_values = &[_][]const u8{""} },
        .{ .name = "muted", .valid_values = &[_][]const u8{""} },
        .{ .name = "preload", .valid_values = &[_][]const u8{ "none", "metadata", "auto" } },
    } ++ common_attrs) },
    .{ .tag_enum = .source, .allowed_attrs = &([_]AttrSpec{ .{ .name = "src", .validator = validateUri }, .{ .name = "type" }, .{ .name = "media" }, .{ .name = "sizes" }, .{ .name = "srcset" }, .{ .name = "" } } ++ common_attrs), .void_element = true },
    .{ .tag_enum = .base, .allowed_attrs = &[_]AttrSpec{
        .{ .name = "href", .validator = validateUri },
        .{ .name = "target", .valid_values = &[_][]const u8{ "_blank", "_self", "_parent", "_top" } },
    } ++ common_attrs, .void_element = true },
    .{ .tag_enum = .track, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "src", .validator = validateUri },
        .{ .name = "kind", .valid_values = &[_][]const u8{ "subtitles", "captions", "descriptions", "chapters", "metadata" } },
        .{ .name = "srclang" },
        .{ .name = "label" },
        .{
            .name = "default",
            .valid_values = &[_][]const u8{""},
        },
    } ++ common_attrs), .void_element = true },

    // Semantic elements
    .{ .tag_enum = .nav, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .header, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .footer, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .main, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .section, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .article, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .aside, .allowed_attrs = &common_attrs },

    // Interactive elements
    .{ .tag_enum = .details, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "open", .valid_values = &[_][]const u8{""} },
    } ++ common_attrs) },
    .{ .tag_enum = .summary, .allowed_attrs = &common_attrs },

    // Figure elements
    .{ .tag_enum = .figure, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .figcaption, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .picture, .allowed_attrs = &common_attrs },

    // Map elements
    .{ .tag_enum = .map, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "name" },
    } ++ common_attrs) },
    .{ .tag_enum = .area, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "alt" },
        .{ .name = "coords" },
        .{ .name = "shape", .valid_values = &[_][]const u8{ "default", "rect", "circle", "poly" } },
        .{ .name = "href" },
        .{ .name = "target", .valid_values = &[_][]const u8{ "_blank", "_self", "_parent", "_top" } },
    } ++ common_attrs), .void_element = true },

    // Document elements
    .{ .tag_enum = .html, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .head, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .title, .allowed_attrs = &common_attrs },
    .{ .tag_enum = .meta, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "charset" },
        .{ .name = "name" },
        .{ .name = "content" },
        .{ .name = "http-equiv" },
        .{ .name = "viewport" },
    } ++ common_attrs), .void_element = true },
    .{ .tag_enum = .link, .allowed_attrs = &([_]AttrSpec{
        .{ .name = "rel" },
        .{ .name = "href", .validator = validateUri },
        .{ .name = "type" },
        .{ .name = "media" },
        .{ .name = "sizes" },
    } ++ common_attrs), .void_element = true },
    .{
        .tag_enum = .embed,
        .allowed_attrs = &([_]AttrSpec{
            .{ .name = "src", .validator = validateUri },
            .{ .name = "type" },
            .{ .name = "width" },
            .{ .name = "height" },
        } ++ common_attrs),
        .void_element = true,
    },
    .{
        .tag_enum = .object,
        .allowed_attrs = &([_]AttrSpec{
            .{ .name = "data", .validator = validateUri },
            .{ .name = "type" },
            .{ .name = "width" },
            .{ .name = "height" },
            .{ .name = "name" },
            .{ .name = "form" },
            .{ .name = "usemap" },
        } ++ common_attrs),
    },

    // Void elements
    .{ .tag_enum = .br, .allowed_attrs = &common_attrs, .void_element = true },
    .{ .tag_enum = .hr, .allowed_attrs = &common_attrs, .void_element = true },

    // Template elements
    .{ .tag_enum = .template, .allowed_attrs = &common_attrs },

    // SVG elements
    .{ .tag_enum = .svg, .allowed_attrs = &svg_attrs },
    .{ .tag_enum = .circle, .allowed_attrs = &svg_attrs },
    .{ .tag_enum = .rect, .allowed_attrs = &svg_attrs },
    .{ .tag_enum = .path, .allowed_attrs = &svg_attrs },
    .{ .tag_enum = .line, .allowed_attrs = &svg_attrs },
    .{ .tag_enum = .text, .allowed_attrs = &svg_attrs },
    custom_element_spec,
};

/// Get the specification for an HTML element by tag name (legacy - prefer getElementSpecFast)
fn getElementSpec(tag: []const u8) ?*const ElementSpec {
    // First try fast enum-based lookup
    if (z.tagFromQualifiedName(tag)) |tag_enum| {
        return getElementSpecByEnum(tag_enum);
    }

    if (z.isCustomElement(tag)) {
        return &custom_element_spec;
    }

    // Fallback: Linear search for custom elements not in enum
    // This should rarely be used in practice
    for (&element_specs) |*spec| {
        if (std.mem.eql(u8, spec.tagName(), tag)) {
            return spec;
        }
    }
    return null;
}

/// Check if an attribute is allowed for a given element
pub fn isAttributeAllowed(element_tag: []const u8, attr_name: []const u8) bool {
    // First check if it's a framework attribute (always allowed if safe)
    if (isFrameworkAttribute(attr_name)) {
        return isFrameworkAttributeSafe(attr_name);
    }

    // Then check element-specific attributes
    const spec = getElementSpec(element_tag) orelse return false;

    for (spec.allowed_attrs) |attr_spec| {
        if (std.mem.eql(u8, attr_spec.name, attr_name)) {
            return attr_spec.safe;
        }
    }
    return false;
}

/// Check if an attribute value is valid for a given element and attribute
pub fn isAttributeValueValid(element_tag: []const u8, attr_name: []const u8, attr_value: []const u8) bool {
    // Framework attributes generally allow any values
    if (isFrameworkAttribute(attr_name)) {
        return isFrameworkAttributeSafe(attr_name);
    }

    // Check element-specific attribute value restrictions
    const spec = getElementSpec(element_tag) orelse return false;

    for (spec.allowed_attrs) |attr_spec| {
        if (std.mem.eql(u8, attr_spec.name, attr_name)) {
            if (attr_spec.valid_values) |valid_values| {
                for (valid_values) |valid_value| {
                    if (std.mem.eql(u8, valid_value, attr_value)) {
                        return true;
                    }
                }
                return false; // Has restrictions but value doesn't match
            }
            return true; // No restrictions on values
        }
    }
    return false; // Attribute not found
}

/// Get all allowed attributes for an element (useful for autocomplete, etc.)
fn getAllowedAttributes(allocator: std.mem.Allocator, element_tag: []const u8) ![][]const u8 {
    const spec = getElementSpec(element_tag) orelse return &[_][]const u8{};

    var attrs: std.ArrayList([]const u8) = .empty;
    for (spec.allowed_attrs) |attr_spec| {
        try attrs.append(allocator, attr_spec.name);
    }
    return attrs.toOwnedSlice(allocator);
}

/// Check if MIME type is safe (similar to DOMPurify's ALLOWED_URI_REGEXP)
pub fn isSafeMimeType(mime: []const u8) bool {
    const dangerous_mimes = [_][]const u8{
        // Executable/plugin content
        "application/x-java-applet",
        "application/x-silverlight",
        "application/x-shockwave-flash",
        // HTML/script content
        "text/html",
        "application/xhtml+xml",
        "text/xml",
        "application/xml",
        "text/xsl",
        "application/xslt+xml",
        // Script content
        "application/javascript",
        "text/javascript",
        "application/ecmascript",
        "text/ecmascript",
        "application/x-ecmascript",
        // ActiveX
        "application/x-msdownload",
        "application/x-ms-install",
    };

    for (dangerous_mimes) |danger| {
        if (std.ascii.eqlIgnoreCase(mime, danger)) {
            return false;
        }
    }

    // Allow common safe types
    const safe_patterns = [_][]const u8{
        "image/",
        "video/",
        "audio/",
        "text/plain",
        "application/pdf",
        "application/json",
        "application/zip",
        "application/x-gzip",
    };

    for (safe_patterns) |pattern| {
        if (std.mem.startsWith(u8, mime, pattern)) {
            return true;
        }
    }

    // Unknown type - be conservative
    return false;
}

// === CSS --------------------------------------------
/// Whitelist of safe CSS properties
pub const SAFE_CSS_PROPERTIES = std.StaticStringMap(void).initComptime(.{
    // Layout
    .{ "display", {} },
    .{ "position", {} },
    .{ "top", {} },
    .{ "right", {} },
    .{ "bottom", {} },
    .{ "left", {} },
    .{ "width", {} },
    .{ "height", {} },
    .{ "min-width", {} },
    .{ "min-height", {} },
    .{ "max-width", {} },
    .{ "max-height", {} },

    // Box model
    .{ "margin", {} },
    .{ "margin-top", {} },
    .{ "margin-right", {} },
    .{ "margin-bottom", {} },
    .{ "margin-left", {} },
    .{ "padding", {} },
    .{ "padding-top", {} },
    .{ "padding-right", {} },
    .{ "padding-bottom", {} },
    .{ "padding-left", {} },
    .{ "border", {} },
    .{ "border-top", {} },
    .{ "border-right", {} },
    .{ "border-bottom", {} },
    .{ "border-left", {} },
    .{ "border-width", {} },
    .{ "border-style", {} },
    .{ "border-color", {} },
    .{ "border-radius", {} },
    .{ "box-sizing", {} },
    .{ "box-shadow", {} },

    // Typography
    .{ "color", {} },
    .{ "font-family", {} },
    .{ "font-size", {} },
    .{ "font-weight", {} },
    .{ "font-style", {} },
    .{ "line-height", {} },
    .{ "text-align", {} },
    .{ "text-decoration", {} },
    .{ "text-transform", {} },
    .{ "letter-spacing", {} },
    .{ "word-spacing", {} },
    .{ "white-space", {} },
    .{ "word-break", {} },
    .{ "word-wrap", {} },

    // Visual
    .{ "background", {} },
    .{ "background-color", {} },
    .{ "background-image", {} },
    .{ "background-position", {} },
    .{ "background-size", {} },
    .{ "background-repeat", {} },
    .{ "background-attachment", {} },
    .{ "opacity", {} },
    .{ "visibility", {} },
    .{ "z-index", {} },
    .{ "overflow", {} },
    .{ "overflow-x", {} },
    .{ "overflow-y", {} },
    .{ "cursor", {} },

    // Flexbox
    .{ "flex", {} },
    .{ "flex-direction", {} },
    .{ "flex-wrap", {} },
    .{ "flex-flow", {} },
    .{ "justify-content", {} },
    .{ "align-items", {} },
    .{ "align-content", {} },
    .{ "align-self", {} },
    .{ "order", {} },

    // Grid
    .{ "grid", {} },
    .{ "grid-template-columns", {} },
    .{ "grid-template-rows", {} },
    .{ "grid-template-areas", {} },
    .{ "grid-column", {} },
    .{ "grid-row", {} },

    // Transforms & transitions
    .{ "transform", {} },
    .{ "transform-origin", {} },
    .{ "transition", {} },
    .{ "transition-property", {} },
    .{ "transition-duration", {} },
    .{ "transition-timing-function", {} },
    .{ "transition-delay", {} },

    // Animations (limited)
    .{ "animation", {} },
    .{ "animation-name", {} },
    .{ "animation-duration", {} },
    .{ "animation-timing-function", {} },
    .{ "animation-delay", {} },
    .{ "animation-iteration-count", {} },
    .{ "animation-direction", {} },
    .{ "animation-fill-mode", {} },

    // Lists
    .{ "list-style", {} },
    .{ "list-style-type", {} },
    .{ "list-style-position", {} },
    .{ "list-style-image", {} },

    // Tables
    .{ "border-collapse", {} },
    .{ "border-spacing", {} },
    .{ "caption-side", {} },
    .{ "empty-cells", {} },
    .{ "table-layout", {} },

    // Miscellaneous
    .{ "content", {} },
    .{ "quotes", {} },
    .{ "counter-reset", {} },
    .{ "counter-increment", {} },
    .{ "resize", {} },
    .{ "user-select", {} },
    .{ "pointer-events", {} },
    .{ "clip", {} },
    .{ "clip-path", {} },
});

// === ENUM-BASED LOOKUPS ===--------------------------

/// Create enum-based hash map for O(1) lookups
pub const ElementSpecMap = std.EnumMap(z.HtmlTag, *const ElementSpec);
const element_spec_map = blk: {
    var map = ElementSpecMap{};
    for (&element_specs) |*spec| {
        map.put(spec.tag_enum, spec);
    }
    break :blk map;
};

/// Fast enum-based element specification lookup (O(1))
pub fn getElementSpecByEnum(tag: z.HtmlTag) ?*const ElementSpec {
    return element_spec_map.get(tag);
}

/// Fast enum-based attribute validation
pub fn isAttributeAllowedEnum(tag: z.HtmlTag, attr_name: []const u8) bool {
    // SECURITY: Block framework event handlers that contain executable JavaScript
    // These are safe in browsers (no framework runtime) but dangerous with QuickJS
    if (isFrameworkEventHandler(attr_name)) {
        return false;
    }

    const spec = getElementSpecByEnum(tag) orelse return false;

    for (spec.allowed_attrs) |attr_spec| {
        if (std.mem.eql(u8, attr_spec.name, attr_name)) {
            return attr_spec.safe;
        }
        // Handle prefix matches for framework and data attributes
        // NOTE: Event handlers (x-on:*, v-on:*) are blocked above
        if ((std.mem.eql(u8, attr_spec.name, "aria") and std.mem.startsWith(u8, attr_name, "aria-")) or
            (std.mem.eql(u8, attr_spec.name, "data") and std.mem.startsWith(u8, attr_name, "data-")) or
            (std.mem.eql(u8, attr_spec.name, "x-bind") and std.mem.startsWith(u8, attr_name, "x-bind:")) or
            (std.mem.eql(u8, attr_spec.name, "phx-value") and std.mem.startsWith(u8, attr_name, "phx-value-")) or
            (std.mem.eql(u8, attr_spec.name, "v-bind") and std.mem.startsWith(u8, attr_name, "v-bind:")))
        {
            return attr_spec.safe;
        }
    }
    return false;
}

/// Fast enum-based void element check
pub fn isVoidElementEnum(tag: z.HtmlTag) bool {
    return switch (tag) {
        .area, .base, .br, .col, .embed, .hr, .img, .input, .link, .meta, .source, .track, .wbr => true,
        else => false,
    };
}

/// Bridge function: Convert string to enum and use fast lookup
pub fn getElementSpecFast(tag_name: []const u8) ?*const ElementSpec {
    if (z.tagFromQualifiedName(tag_name)) |tag| {
        return getElementSpecByEnum(tag);
    }
    // Fallback to string-based lookup for custom elements
    return getElementSpec(tag_name);
}

/// Bridge function: Convert string to enum and use fast validation
pub fn isAttributeAllowedFast(element_tag: []const u8, attr_name: []const u8) bool {
    if (z.tagFromQualifiedName(element_tag)) |tag| {
        return isAttributeAllowedEnum(tag, attr_name);
    }
    // Fallback to string-based validation for custom elements
    return isAttributeAllowed(element_tag, attr_name);
}

// === INTEGRATION BRIDGES ===

/// Get element specification from DOM element (integrates with html_tags.zig)
pub fn getElementSpecFromElement(element: *z.HTMLElement) ?*const ElementSpec {
    if (z.tagFromElement(element)) |tag| {
        return getElementSpecByEnum(tag);
    }
    // Fallback for custom elements
    const tag_name = z.qualifiedName_zc(element);
    return getElementSpec(tag_name);
}

/// Check if element is void using unified specification
pub fn isVoidElementFromSpec(element: *z.HTMLElement) bool {
    if (z.tagFromElement(element)) |tag| {
        return isVoidElementEnum(tag);
    }
    // Fallback for custom elements (they are never void)
    return false;
}

/// Validate element and attribute combination from DOM element
pub fn validateElementAttributeFromElement(element: *z.HTMLElement, attr_name: []const u8) bool {
    if (z.tagFromElement(element)) |tag| {
        return isAttributeAllowedEnum(tag, attr_name);
    }
    // Fallback for custom elements
    const tag_name = z.qualifiedName_zc(element);
    return isAttributeAllowed(tag_name, attr_name);
}

/// Get all allowed attributes for a DOM element
pub fn getAllowedAttributesFromElement(allocator: std.mem.Allocator, element: *z.HTMLElement) ![][]const u8 {
    if (z.tagFromElement(element)) |tag| {
        if (getElementSpecByEnum(tag)) |spec| {
            var attrs: std.ArrayList([]const u8) = .empty;
            for (spec.allowed_attrs) |attr_spec| {
                try attrs.append(allocator, attr_spec.name);
            }
            return attrs.toOwnedSlice(allocator);
        }
    }
    // Fallback for custom elements
    const tag_name = z.qualifiedName_zc(element);
    return getAllowedAttributes(allocator, tag_name);
}

const testing = std.testing;

test "element spec lookup" {
    // Test enum-based lookup (fast path)
    const table_spec = getElementSpec("table");
    try testing.expect(table_spec != null);
    try testing.expectEqualStrings("table", table_spec.?.tagName());

    // Test unknown element
    const unknown_spec = getElementSpec("unknown-element");
    const name = unknown_spec.?.tagName();
    try testing.expectEqualStrings("custom", name);

    // Test that fast path and legacy path return same result for known elements
    const div_spec_legacy = getElementSpec("div");
    const div_spec_fast = getElementSpecFast("div");
    try testing.expect(div_spec_legacy != null);
    try testing.expect(div_spec_fast != null);
    try testing.expect(div_spec_legacy == div_spec_fast); // Same pointer
}

test "attribute validation" {
    // Test allowed attribute
    try testing.expect(isAttributeAllowed("table", "scope"));
    try testing.expect(isAttributeAllowed("th", "scope"));

    // Test disallowed attribute
    try testing.expect(!isAttributeAllowed("table", "onclick"));

    // Test aria attributes
    try testing.expect(isAttributeAllowed("div", "aria-label"));
    try testing.expect(isAttributeAllowed("div", "aria-expanded"));
}

test "attribute value validation" {
    // Test valid scope values
    try testing.expect(isAttributeValueValid("th", "scope", "col"));
    try testing.expect(isAttributeValueValid("th", "scope", "row"));

    // Test invalid scope value
    try testing.expect(!isAttributeValueValid("th", "scope", "invalid"));

    // Test unrestricted attribute (id)
    try testing.expect(isAttributeValueValid("div", "id", "any-value"));

    // Test title attribute on anchor element (should be allowed)
    try testing.expect(isAttributeAllowed("a", "title"));
    try testing.expect(isAttributeValueValid("a", "title", "any title text"));
}

test "enum-based functions" {
    // Test getElementSpecByEnum
    const table_spec = getElementSpecByEnum(.table);
    try testing.expect(table_spec != null);
    try testing.expectEqualStrings("table", table_spec.?.tagName());

    // Test isAttributeAllowedEnum
    try testing.expect(isAttributeAllowedEnum(.table, "scope"));
    try testing.expect(isAttributeAllowedEnum(.th, "scope"));
    try testing.expect(!isAttributeAllowedEnum(.table, "onclick"));

    // Test isVoidElementEnum
    try testing.expect(isVoidElementEnum(.img));
    try testing.expect(isVoidElementEnum(.br));
    try testing.expect(isVoidElementEnum(.input));
    try testing.expect(!isVoidElementEnum(.div));
    try testing.expect(!isVoidElementEnum(.table));
}

test "fast bridge functions" {
    // Test getElementSpecFast (string to enum conversion)
    const table_spec = getElementSpecFast("table");
    try testing.expect(table_spec != null);
    try testing.expectEqualStrings("table", table_spec.?.tagName());

    // Test unknown element
    const unknown_spec = getElementSpecFast("unknown-element");
    const name = unknown_spec.?.tagName();
    try testing.expectEqualStrings("custom", name);

    // Test isAttributeAllowedFast
    try testing.expect(isAttributeAllowedFast("table", "scope"));
    try testing.expect(!isAttributeAllowedFast("table", "onclick"));
    try testing.expect(isAttributeAllowedFast("div", "aria-label"));
}

test "DOM element integration functions" {
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    // Create test elements
    const table_element = try z.createElement(doc, "table");
    const img_element = try z.createElement(doc, "img");
    const div_element = try z.createElement(doc, "div");

    // Test getElementSpecFromElement
    const table_spec = getElementSpecFromElement(table_element);
    try testing.expect(table_spec != null);
    try testing.expectEqualStrings("table", table_spec.?.tagName());

    // Test isVoidElementFromSpec
    try testing.expect(isVoidElementFromSpec(img_element));
    try testing.expect(!isVoidElementFromSpec(table_element));
    try testing.expect(!isVoidElementFromSpec(div_element));

    // Test validateElementAttributeFromElement
    try testing.expect(validateElementAttributeFromElement(table_element, "scope"));
    try testing.expect(!validateElementAttributeFromElement(table_element, "onclick"));
    try testing.expect(validateElementAttributeFromElement(div_element, "class"));

    // Test getAllowedAttributesFromElement
    const attrs = try getAllowedAttributesFromElement(testing.allocator, table_element);
    defer testing.allocator.free(attrs);
    try testing.expect(attrs.len > 0);

    // Check that "scope" is in the allowed attributes for table
    var found_scope = false;
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr, "scope")) {
            found_scope = true;
            break;
        }
    }
    try testing.expect(found_scope);
}

test "framework event handlers are blocked (XSS prevention)" {
    // These framework event handlers contain executable JavaScript
    // They are dangerous in environments with a JS runtime (like QuickJS)

    // Test isFrameworkEventHandler correctly identifies event handlers
    try testing.expect(isFrameworkEventHandler("x-on:click"));
    try testing.expect(isFrameworkEventHandler("x-on:submit"));
    try testing.expect(isFrameworkEventHandler("v-on:click"));
    try testing.expect(isFrameworkEventHandler("hx-on:click"));
    try testing.expect(isFrameworkEventHandler("phx-click")); // Phoenix

    // Non-event framework attributes should pass
    try testing.expect(!isFrameworkEventHandler("x-show"));
    try testing.expect(!isFrameworkEventHandler("x-bind:class"));
    try testing.expect(!isFrameworkEventHandler("v-if"));
    try testing.expect(!isFrameworkEventHandler("hx-get"));
    try testing.expect(!isFrameworkEventHandler("data-id"));

    // Test isFrameworkAttributeSafe blocks event handlers
    // These are blocked via isFrameworkEventHandler check OR via spec.safe = false
    try testing.expect(!isFrameworkAttributeSafe("x-on:click"));
    try testing.expect(!isFrameworkAttributeSafe("@click")); // Vue shorthand (safe = false in spec)
    try testing.expect(!isFrameworkAttributeSafe("(click)")); // Angular (safe = false in spec)
    try testing.expect(!isFrameworkAttributeSafe("on:click")); // Svelte (safe = false in spec)

    // Safe framework attributes should pass
    try testing.expect(isFrameworkAttributeSafe("x-show"));
    try testing.expect(isFrameworkAttributeSafe("data-id"));
    try testing.expect(isFrameworkAttributeSafe("aria-label"));

    // Test isAttributeAllowedEnum blocks event handlers on elements
    try testing.expect(!isAttributeAllowedEnum(.button, "x-on:click"));
    try testing.expect(!isAttributeAllowedEnum(.div, "v-on:submit"));
    try testing.expect(!isAttributeAllowedEnum(.form, "hx-on:htmx:after-request"));
}

test "SVG URI validation - fragment-only" {
    // ONLY fragment identifiers are allowed (defense against CVEs involving <use>)
    try testing.expect(validateSvgUri("#icon"));
    try testing.expect(validateSvgUri("#my-symbol"));
    try testing.expect(validateSvgUri("#gradient-1"));

    // Relative paths are BLOCKED (can load external resources)
    // This is stricter than before - "icons.svg#arrow" could load external SVG
    try testing.expect(!validateSvgUri("icons.svg#arrow"));
    try testing.expect(!validateSvgUri("./sprites.svg#logo"));
    try testing.expect(!validateSvgUri("../images/icon.svg#star"));

    // All protocols are blocked (only # is allowed)
    try testing.expect(!validateSvgUri("javascript:alert(1)"));
    try testing.expect(!validateSvgUri("vbscript:evil"));
    try testing.expect(!validateSvgUri("file:///etc/passwd"));
    try testing.expect(!validateSvgUri("http://evil.com/malware.svg"));
    try testing.expect(!validateSvgUri("https://attacker.com/payload.svg"));
    try testing.expect(!validateSvgUri("//evil.com/script.svg"));
    try testing.expect(!validateSvgUri("data:image/png;base64,abc"));
    try testing.expect(!validateSvgUri("data:image/svg+xml,<svg>"));

    // Empty and whitespace-only are blocked
    try testing.expect(!validateSvgUri(""));
    try testing.expect(!validateSvgUri("   "));

    // Compare with HTML validator - HTML is more permissive
    try testing.expect(validateUri("https://example.com/image.png")); // HTML allows https
    try testing.expect(!validateSvgUri("https://example.com/image.png")); // SVG blocks ALL non-fragment
}

test "SVG element allowlist and blocklist" {
    // Safe SVG elements should be allowed
    try testing.expect(isSvgElementAllowed("svg"));
    try testing.expect(isSvgElementAllowed("circle"));
    try testing.expect(isSvgElementAllowed("rect"));
    try testing.expect(isSvgElementAllowed("path"));
    try testing.expect(isSvgElementAllowed("line"));
    try testing.expect(isSvgElementAllowed("text"));
    try testing.expect(isSvgElementAllowed("g"));
    try testing.expect(isSvgElementAllowed("defs"));
    try testing.expect(isSvgElementAllowed("linearGradient"));
    try testing.expect(isSvgElementAllowed("filter"));
    try testing.expect(isSvgElementAllowed("feGaussianBlur"));

    // Dangerous SVG elements should be blocked
    try testing.expect(isSvgElementDangerous("script"));
    try testing.expect(isSvgElementDangerous("foreignObject"));
    try testing.expect(isSvgElementDangerous("a"));
    try testing.expect(isSvgElementDangerous("use"));
    try testing.expect(isSvgElementDangerous("image"));
    try testing.expect(isSvgElementDangerous("animate"));
    try testing.expect(isSvgElementDangerous("animateMotion"));
    try testing.expect(isSvgElementDangerous("animateTransform"));
    try testing.expect(isSvgElementDangerous("set"));
    try testing.expect(isSvgElementDangerous("feImage"));

    // Unknown elements should not be in either list
    try testing.expect(!isSvgElementAllowed("unknown-element"));
    try testing.expect(!isSvgElementDangerous("unknown-element"));
}

const std = @import("std");
const specs = @import("html_spec.zig");
const z = @import("../root.zig");

const testing = std.testing;

// ============================================================================
// Lexbor CSS Parser Extern Declarations
// ============================================================================

const lxb_status_ok: c_int = 0;

/// Lexbor serialization callback type
const lxb_serialize_cb_f = *const fn (
    data: [*]const u8,
    len: usize,
    ctx: ?*anyopaque,
) callconv(.c) c_int;

/// CSS Memory API
extern "c" fn lxb_css_memory_create() ?*z.CssMemory;
extern "c" fn lxb_css_memory_init(memory: *z.CssMemory, size: usize) c_int;
extern "c" fn lxb_css_memory_destroy(memory: *z.CssMemory, destroy_self: bool) ?*z.CssMemory;

/// CSS Parser API
extern "c" fn lxb_css_parser_create() ?*z.CssStyleParser;
extern "c" fn lxb_css_parser_init(parser: *z.CssStyleParser, tokenizer: ?*anyopaque) c_int;
extern "c" fn lxb_css_parser_destroy(parser: *z.CssStyleParser, self_destroy: bool) ?*z.CssStyleParser;
extern "c" fn lxb_css_parser_clean(parser: *z.CssStyleParser) void;
extern "c" fn lxb_css_parser_memory_set_noi(parser: *z.CssStyleParser, memory: ?*z.CssMemory) void;

/// CSS Declaration Parsing - parses "property: value; property: value" style strings
extern "c" fn lxb_css_declaration_list_parse(
    parser: *z.CssStyleParser,
    data: [*]const u8,
    length: usize,
) ?*z.CssRuleDeclarationList;

/// CSS Rule/Declaration List Management
extern "c" fn lxb_css_rule_declaration_list_destroy(
    list: *z.CssRuleDeclarationList,
    self_destroy: bool,
) ?*z.CssRuleDeclarationList;

/// CSS Serialization
extern "c" fn lxb_css_rule_declaration_serialize(
    decl: *const CssRuleDeclaration,
    cb: lxb_serialize_cb_f,
    ctx: ?*anyopaque,
) c_int;

extern "c" fn lxb_css_rule_declaration_serialize_name(
    decl: *const CssRuleDeclaration,
    cb: lxb_serialize_cb_f,
    ctx: ?*anyopaque,
) c_int;

/// Property lookup by ID to get metadata
extern "c" fn lxb_css_property_by_id(id: usize) ?*const CssEntryData;

// ============================================================================
// Lexbor CSS Type Definitions (matching C structs)
// ============================================================================

/// CSS Rule types
const LXB_CSS_RULE_DECLARATION: u32 = 7;

/// lexbor_str_t - Lexbor's string type
const LexborStr = extern struct {
    data: ?[*]const u8,
    length: usize,
};

/// lxb_css_entry_data_t - CSS property metadata
const CssEntryData = extern struct {
    name: ?[*]const u8,
    length: usize,
    unique: usize,
    state: ?*anyopaque,
    create: ?*anyopaque,
    destroy: ?*anyopaque,
    serialize: ?*anyopaque,
    initial: ?*anyopaque,
};

/// lxb_css_property__undef_t - For unknown/unparseable properties
const CssPropertyUndef = extern struct {
    type_id: u32,
    value: LexborStr,
};

/// lxb_css_property__custom_t - For custom properties (CSS variables)
const CssPropertyCustom = extern struct {
    name: LexborStr,
    value: LexborStr,
};

/// lxb_css_rule_t - Base rule structure
const CssRule = extern struct {
    type: u32,
    next: ?*CssRule,
    prev: ?*CssRule,
    parent: ?*CssRule,
    memory: ?*anyopaque,
    ref_count: usize,
};

/// lxb_css_rule_declaration_offset_t
const CssRuleDeclarationOffset = extern struct {
    name_begin: usize,
    name_end: usize,
    value_begin: usize,
    value_end: usize,
    important_begin: usize,
    important_end: usize,
};

/// lxb_css_rule_declaration_t - A single CSS declaration
const CssRuleDeclaration = extern struct {
    rule: CssRule,
    type_id: usize, // Property type ID (0 = undef, 1 = custom, 2+ = known properties)
    u: extern union {
        undef: ?*CssPropertyUndef,
        custom: ?*CssPropertyCustom,
        user: ?*anyopaque,
    },
    offset: CssRuleDeclarationOffset,
    important: bool,
};

/// lxb_css_rule_declaration_list_t - List of declarations
const CssRuleDeclarationListInternal = extern struct {
    rule: CssRule,
    first: ?*CssRule,
    last: ?*CssRule,
    count: usize,
};

// ============================================================================
// Serialization Helpers
// ============================================================================

/// Context for serialization callback
const SerializeContext = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
};

/// Callback function for lexbor serialization
fn serializeCallback(data: [*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) c_int {
    const context: *SerializeContext = @ptrCast(@alignCast(ctx));
    context.list.appendSlice(context.allocator, data[0..len]) catch return 1;
    return lxb_status_ok;
}

/// [sanitize] CSS-specific sanitization options
pub const CssSanitizerOptions = struct {
    // Control what gets sanitized
    sanitize_inline_styles: bool = true, // Sanitize style="..." attributes
    sanitize_style_elements: bool = true, // Sanitize <style> elements
    sanitize_style_attributes: bool = true, // Sanitize style* attributes

    // Allowed CSS features
    allow_css_urls: bool = false, // Allow url() in CSS
    allow_data_urls: bool = false, // Allow data: URLs in CSS
    allow_imports: bool = false, // Allow @import rules
    allow_keyframes: bool = true, // Allow @keyframes animations
    allow_font_face: bool = false, // Allow @font-face rules

    // Security limits
    max_css_size: usize = 100 * 1024, // 100KB max CSS
    max_data_url_size: usize = 1024, // 1KB max for data URLs
    max_urls_per_rule: usize = 10, // Max URLs per CSS rule

    // Whitelist/blacklist approach
    use_property_whitelist: bool = true, // Use whitelist instead of blacklist
    allow_dangerous_hacks: bool = false, // Allow IE-specific CSS hacks
};

/// CSS Sanitizer module
pub const CssSanitizer = struct {
    allocator: std.mem.Allocator,
    options: CssSanitizerOptions,
    parser: ?*z.CssStyleParser = null, // Lexbor CSS parser handle
    css_memory: ?*z.CssMemory = null, // Lexbor CSS memory pool

    pub fn init(allocator: std.mem.Allocator, options: CssSanitizerOptions) !@This() {
        return @This(){
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.parser) |parser| {
            _ = lxb_css_parser_destroy(parser, true);
            self.parser = null;
        }
        if (self.css_memory) |memory| {
            _ = lxb_css_memory_destroy(memory, true);
            self.css_memory = null;
        }
    }

    /// Ensure parser is initialized (lazy initialization)
    fn ensureParser(self: *@This()) !*z.CssStyleParser {
        if (self.parser) |parser| return parser;

        // Create and initialize CSS memory pool first
        const memory = lxb_css_memory_create() orelse return error.CssMemoryCreateFailed;
        errdefer _ = lxb_css_memory_destroy(memory, true);

        if (lxb_css_memory_init(memory, 128) != lxb_status_ok) {
            return error.CssMemoryInitFailed;
        }

        // Create and initialize parser
        const parser = lxb_css_parser_create() orelse return error.CssParserCreateFailed;
        errdefer _ = lxb_css_parser_destroy(parser, true);

        if (lxb_css_parser_init(parser, null) != lxb_status_ok) {
            return error.CssParserInitFailed;
        }

        // Set memory on parser
        lxb_css_parser_memory_set_noi(parser, memory);

        self.css_memory = memory;
        self.parser = parser;
        return parser;
    }

    /// Sanitize CSS string (for style attributes)
    pub fn sanitizeStyleString(self: *@This(), input: []const u8) ![]const u8 {
        if (input.len == 0) return "";

        // Quick checks before full parsing
        if (!self.isCssSizeValid(input)) return "";

        // Check for dangerous patterns
        if (self.containsDangerousPatterns(input)) return "";

        // If options.sanitize_inline_styles is false, just validate and return
        if (!self.options.sanitize_inline_styles) {
            return if (self.isStyleStringSafe(input)) input else "";
        }

        // Use Lexbor CSS parser for full sanitization
        return try self.sanitizeWithLexbor(input);
    }

    /// Sanitize style attribute value
    pub fn sanitizeStyleAttribute(self: *@This(), element: *z.HTMLElement) !void {
        const style_value = z.getAttribute_zc(element, "style") orelse return;

        const sanitized = try self.sanitizeStyleString(style_value);

        if (sanitized.len == 0) {
            // Remove the style attribute entirely
            try z.removeAttribute(element, "style");
        } else if (!std.mem.eql(u8, sanitized, style_value)) {
            // Update with sanitized value
            try z.setAttribute(element, "style", sanitized);
        }
    }

    /// Check if CSS contains dangerous patterns
    fn containsDangerousPatterns(_: *@This(), css: []const u8) bool {
        for (specs.DANGEROUS_CSS_PATTERNS) |pattern| {
            if (containsCaseInsensitive(css, pattern)) {
                return true;
            }
        }
        return false;
    }

    /// Validate CSS size limits
    fn isCssSizeValid(self: *@This(), css: []const u8) bool {
        return css.len <= self.options.max_css_size;
    }

    /// Simple safety check without full parsing
    fn isStyleStringSafe(self: *@This(), css: []const u8) bool {
        // Check for dangerous patterns
        if (self.containsDangerousPatterns(css)) {
            return false;
        }

        // Check for too many URLs
        if (!self.options.allow_css_urls) {
            const url_count = countSubstring(css, "url(");
            if (url_count > self.options.max_urls_per_rule) {
                return false;
            }
        }

        return true;
    }

    /// Full sanitization using Lexbor CSS parser
    fn sanitizeWithLexbor(self: *@This(), input: []const u8) ![]const u8 {
        // Initialize parser if needed
        const parser = self.ensureParser() catch {
            // Fallback to simple filter if parser fails
            return try self.simpleCssFilter(input);
        };

        // Clean parser state for fresh parsing
        lxb_css_parser_clean(parser);

        // Parse the CSS declaration list (inline style format)
        const decl_list = lxb_css_declaration_list_parse(parser, input.ptr, input.len);
        if (decl_list == null) {
            // Parse failed - fallback to simple filter
            return try self.simpleCssFilter(input);
        }
        defer _ = lxb_css_rule_declaration_list_destroy(decl_list.?, true);

        // Get internal list structure to iterate
        const list_internal: *CssRuleDeclarationListInternal = @ptrCast(@alignCast(decl_list.?));

        // Build result by iterating through declarations and filtering
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var current: ?*CssRule = list_internal.first;
        var first = true;

        while (current) |rule| {
            if (rule.type == LXB_CSS_RULE_DECLARATION) {
                const decl: *const CssRuleDeclaration = @ptrCast(@alignCast(rule));

                // Get property name
                const prop_name = self.getDeclarationPropertyName(decl);
                if (prop_name.len == 0) {
                    current = rule.next;
                    continue;
                }

                // Check if property is allowed
                if (!self.isPropertyAllowed(prop_name)) {
                    current = rule.next;
                    continue;
                }

                // Serialize the declaration to check value safety
                var value_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer value_buf.deinit(self.allocator);
                var serialize_ctx = SerializeContext{ .list = &value_buf, .allocator = self.allocator };

                if (lxb_css_rule_declaration_serialize(decl, serializeCallback, &serialize_ctx) != lxb_status_ok) {
                    current = rule.next;
                    continue;
                }

                // Extract value part after colon
                const serialized = value_buf.items;
                const colon_idx = std.mem.indexOfScalar(u8, serialized, ':') orelse {
                    current = rule.next;
                    continue;
                };
                const value_part = std.mem.trim(u8, serialized[colon_idx + 1 ..], &std.ascii.whitespace);

                // Check if value is safe
                if (!self.isValueSafe(value_part)) {
                    current = rule.next;
                    continue;
                }

                // Add separator if not first
                if (!first) {
                    try result.appendSlice(self.allocator, "; ");
                }
                first = false;

                // Append the serialized declaration
                try result.appendSlice(self.allocator, serialized);
            }

            current = rule.next;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Get property name from a declaration
    fn getDeclarationPropertyName(self: *@This(), decl: *const CssRuleDeclaration) []const u8 {
        _ = self;

        // Type 0 = undef (unknown property), 1 = custom (CSS variable)
        if (decl.type_id == 0) {
            // Unknown property - get name from undef struct
            if (decl.u.undef) |undef| {
                if (undef.value.data) |data| {
                    // For undef, we need to extract property name differently
                    // This is a fallback - usually unknown props are blocked anyway
                    _ = data;
                }
            }
            return "";
        } else if (decl.type_id == 1) {
            // Custom property (CSS variable like --custom-prop)
            if (decl.u.custom) |custom| {
                if (custom.name.data) |data| {
                    return data[0..custom.name.length];
                }
            }
            return "";
        } else {
            // Known property - look up by ID
            if (lxb_css_property_by_id(decl.type_id)) |entry| {
                if (entry.name) |name| {
                    return name[0..entry.length];
                }
            }
            return "";
        }
    }

    /// Parse and sanitize CSS declarations (property: value pairs)
    /// This is the main sanitization logic for inline styles
    fn simpleCssFilter(self: *@This(), css: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Split by semicolons and process each declaration
        var iter = std.mem.splitScalar(u8, css, ';');
        var first = true;

        while (iter.next()) |decl| {
            const trimmed = std.mem.trim(u8, decl, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            // Find the colon separating property from value
            const colon_idx = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;

            const property = std.mem.trim(u8, trimmed[0..colon_idx], &std.ascii.whitespace);
            const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], &std.ascii.whitespace);

            if (property.len == 0 or value.len == 0) continue;

            // Validate property
            if (!self.isPropertyAllowed(property)) continue;

            // Validate value
            if (!self.isValueSafe(value)) continue;

            // Add to result
            if (!first) {
                try result.appendSlice(self.allocator, "; ");
            }
            first = false;
            try result.appendSlice(self.allocator, property);
            try result.appendSlice(self.allocator, ": ");
            try result.appendSlice(self.allocator, value);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Check if a CSS property is allowed
    fn isPropertyAllowed(self: *@This(), property: []const u8) bool {
        // Convert to lowercase for comparison
        var lower_buf: [64]u8 = undefined;
        if (property.len > lower_buf.len) return false;

        for (property, 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        const lower_prop = lower_buf[0..property.len];

        // Check blacklist first (always blocked)
        for (specs.DANGEROUS_CSS_PROPERTIES) |dangerous| {
            if (std.mem.eql(u8, lower_prop, dangerous)) {
                return false;
            }
        }

        // If using whitelist, check against safe properties
        if (self.options.use_property_whitelist) {
            return specs.SAFE_CSS_PROPERTIES.has(lower_prop);
        }

        return true;
    }

    /// Check if a CSS value is safe
    fn isValueSafe(self: *@This(), value: []const u8) bool {
        // Check for dangerous value patterns
        for (specs.DANGEROUS_CSS_VALUES) |pattern| {
            if (containsCaseInsensitive(value, pattern)) {
                return false;
            }
        }

        // Check for url() - handle separately
        if (containsCaseInsensitive(value, "url(")) {
            // Find and validate the URL
            const url_start = std.mem.indexOf(u8, value, "url(") orelse
                std.mem.indexOf(u8, value, "URL(") orelse return false;
            const url_end = findMatchingParen(value, url_start + 4);
            if (url_end) |end| {
                const url_content = value[url_start + 4 .. end - 1];
                if (!self.isCssUrlSafe(url_content)) {
                    return false;
                }
            } else {
                return false; // Malformed url()
            }
        }

        return true;
    }

    /// Validate URL in CSS url() function
    fn isCssUrlSafe(self: *@This(), url_content: []const u8) bool {
        const trimmed = std.mem.trim(u8, url_content, " '\"");

        // Block dangerous protocols
        if (specs.startsWithIgnoreCase(trimmed, "javascript:") or
            specs.startsWithIgnoreCase(trimmed, "vbscript:") or
            specs.startsWithIgnoreCase(trimmed, "data:text/html") or
            specs.startsWithIgnoreCase(trimmed, "data:text/javascript"))
        {
            return false;
        }

        // Handle data URLs
        if (specs.startsWithIgnoreCase(trimmed, "data:")) {
            if (!self.options.allow_data_urls) return false;
            if (trimmed.len > self.options.max_data_url_size) return false;

            // Only allow image data URLs
            if (!specs.startsWithIgnoreCase(trimmed, "data:image/")) return false;
            if (specs.startsWithIgnoreCase(trimmed, "data:image/svg")) return false;

            return true;
        }

        // Allow other URLs if configured
        return self.options.allow_css_urls;
    }
};

/// Helper function: find matching parenthesis
fn findMatchingParen(str: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < str.len) {
        if (str[i] == '(') {
            depth += 1;
        } else if (str[i] == ')') {
            depth -= 1;
            if (depth == 0) {
                return i + 1;
            }
        }
        i += 1;
    }
    return null;
}

/// Helper function: count substring occurrences
fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.startsWith(u8, haystack[i..], needle)) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}

/// Helper function: case-insensitive contains
fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;

    for (0..(haystack.len - needle.len + 1)) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "CSS sanitizer - safe properties" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    // Safe properties should pass through
    const input = "color: red; font-size: 14px; margin: 10px";
    const result = try sanitizer.sanitizeStyleString(input);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "color: red") != null);
    try testing.expect(std.mem.indexOf(u8, result, "font-size: 14px") != null);
    try testing.expect(std.mem.indexOf(u8, result, "margin: 10px") != null);
}

test "CSS sanitizer - dangerous properties blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    // behavior is a dangerous property (IE-specific XSS vector)
    const input = "color: red; behavior: url(xss.htc); font-size: 14px";
    const result = try sanitizer.sanitizeStyleString(input);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "color: red") != null);
    try testing.expect(std.mem.indexOf(u8, result, "behavior") == null);
    try testing.expect(std.mem.indexOf(u8, result, "font-size: 14px") != null);
}

test "CSS sanitizer - dangerous values blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    // expression() is dangerous (IE-specific XSS)
    const input = "width: expression(alert(1)); color: blue";
    const result = try sanitizer.sanitizeStyleString(input);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "expression") == null);
    try testing.expect(std.mem.indexOf(u8, result, "color: blue") != null);
}

test "CSS sanitizer - javascript: in url blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{ .allow_css_urls = true });
    defer sanitizer.deinit();

    const input = "background: url(javascript:alert(1))";
    const result = try sanitizer.sanitizeStyleString(input);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "javascript") == null);
}

test "CSS sanitizer - url() blocked by default" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const input = "background: url(https://example.com/image.png)";
    const result = try sanitizer.sanitizeStyleString(input);
    defer testing.allocator.free(result);

    // url() should be blocked when allow_css_urls is false (default)
    try testing.expect(std.mem.indexOf(u8, result, "url(") == null);
}

test "CSS sanitizer - empty input" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const result = try sanitizer.sanitizeStyleString("");
    try testing.expectEqualStrings("", result);
}

test "CSS sanitizer - @import blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    // @import is in DANGEROUS_CSS_PATTERNS
    const input = "@import url('evil.css'); color: red";
    const result = try sanitizer.sanitizeStyleString(input);
    defer testing.allocator.free(result);

    // Should return empty because containsDangerousPatterns catches @import
    try testing.expectEqualStrings("", result);
}

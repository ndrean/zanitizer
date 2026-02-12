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

/// CSS Serialization (using opaque CssRule pointers - Lexbor handles type casting)
extern "c" fn lxb_css_rule_declaration_serialize(
    decl: *const CssRule,
    cb: lxb_serialize_cb_f,
    ctx: ?*anyopaque,
) c_int;

extern "c" fn lxb_css_rule_declaration_serialize_name(
    decl: *const CssRule,
    cb: lxb_serialize_cb_f,
    ctx: ?*anyopaque,
) c_int;

/// Property lookup by ID to get metadata
extern "c" fn lxb_css_property_by_id(id: usize) ?*const CssEntryData;

// ============================================================================
// Lexbor CSS Stylesheet Parsing (Full AST-based approach)
// ============================================================================

/// Stylesheet parsing
extern "c" fn lxb_css_stylesheet_create(memory: ?*z.CssMemory) ?*CssStylesheet;
extern "c" fn lxb_css_stylesheet_parse(sst: *CssStylesheet, parser: *z.CssStyleParser, data: [*]const u8, length: usize) c_int;
extern "c" fn lxb_css_stylesheet_destroy(sst: *CssStylesheet, self_destroy: bool) ?*CssStylesheet;

/// Rule serialization
extern "c" fn lxb_css_rule_style_serialize(style: *const CssRule, cb: lxb_serialize_cb_f, ctx: ?*anyopaque) c_int;
extern "c" fn lxb_css_rule_declaration_list_serialize(list: *const CssRule, cb: lxb_serialize_cb_f, ctx: ?*anyopaque) c_int;

/// Selector serialization (note: Lexbor uses lxb_css_selector_serialize_list)
extern "c" fn lxb_css_selector_serialize_list(list: *const CssSelectorList, cb: lxb_serialize_cb_f, ctx: ?*anyopaque) c_int;

// ============================================================================
// C Shim Functions for Safe Struct Access
// ============================================================================
// These functions are implemented in css_shim.c and provide safe access to
// Lexbor's internal CSS structures without needing to mirror struct layouts.

/// Get the root rule of a stylesheet
extern "c" fn zexp_css_stylesheet_get_root(sst: *CssStylesheet) ?*CssRule;

/// Get the type of a CSS rule
extern "c" fn zexp_css_rule_get_type(rule: *const CssRule) u32;

/// Get the next sibling rule
extern "c" fn zexp_css_rule_get_next(rule: *const CssRule) ?*CssRule;

/// Get the selector list from a style rule
extern "c" fn zexp_css_rule_style_get_selector(rule: *const CssRule) ?*CssSelectorList;

/// Get the declaration list from a style rule (returns lxb_css_rule_declaration_list_t*)
extern "c" fn zexp_css_rule_style_get_declarations(rule: *const CssRule) ?*CssRuleDeclList;

/// Get the first declaration from a declaration list (takes lxb_css_rule_declaration_list_t*)
extern "c" fn zexp_css_decl_list_get_first(list: *const CssRuleDeclList) ?*CssRule;

/// Get the property type ID from a declaration
extern "c" fn zexp_css_declaration_get_type_id(rule: *const CssRule) usize;

/// Check if a declaration is !important
extern "c" fn zexp_css_declaration_is_important(rule: *const CssRule) bool;

/// Get the first rule from a rule list
extern "c" fn zexp_css_rule_list_get_first(rule: *const CssRule) ?*CssRule;

/// Get the at-rule type
extern "c" fn zexp_css_at_rule_get_type(rule: *const CssRule) u32;

/// Get at-rule prelude position offsets (not strings - use serialization for actual text)
extern "c" fn zexp_css_at_rule_get_prelude_offsets(rule: *const CssRule, prelude_begin: ?*usize, prelude_end: ?*usize) void;

/// At-rule serialization (to get the full at-rule text including prelude)
extern "c" fn lxb_css_rule_at_serialize(at: *const CssRule, cb: lxb_serialize_cb_f, ctx: ?*anyopaque) c_int;

// ============================================================================
// Lexbor CSS Type Definitions
// ============================================================================
// Most types are opaque - we access their fields through the C shim functions.
// This avoids having to mirror Lexbor's internal struct layouts in Zig.

/// CSS Rule types (from lexbor/css/rule.h - enum values in order)
const LXB_CSS_RULE_UNDEF: u32 = 0;
const LXB_CSS_RULE_STYLESHEET: u32 = 1;
const LXB_CSS_RULE_LIST: u32 = 2;
const LXB_CSS_RULE_AT_RULE: u32 = 3;
const LXB_CSS_RULE_STYLE: u32 = 4;
const LXB_CSS_RULE_BAD_STYLE: u32 = 5;
const LXB_CSS_RULE_DECLARATION_LIST: u32 = 6;
const LXB_CSS_RULE_DECLARATION: u32 = 7;

/// lxb_css_at_rule_type_t values
const LXB_CSS_AT_RULE_UNDEF: u32 = 0;
const LXB_CSS_AT_RULE_CUSTOM: u32 = 1;
const LXB_CSS_AT_RULE_MEDIA: u32 = 2;
const LXB_CSS_AT_RULE_NAMESPACE: u32 = 3;
const LXB_CSS_AT_RULE_FONT_FACE: u32 = 4;

/// lxb_css_entry_data_t - CSS property metadata (still need struct for property lookup)
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

/// Opaque types - accessed only through C shim functions
const CssRule = opaque {};
const CssSelectorList = opaque {};
const CssStylesheet = opaque {};
const CssRuleDeclList = opaque {}; // lxb_css_rule_declaration_list_t (different from z.CssRuleDeclarationList)

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

    // Configurable CSS functions (runtime toggles for comptime ruleset's configurable_* entries)
    allow_calc: bool = true, // calc() is standard CSS, safe by default
    allow_css_variables: bool = false, // var() blocked by default (data exfiltration risk)
    allow_env: bool = false, // env() blocked by default
};

// ============================================================================
// CSS Value Scanner — Comptime-generic structural CSS value analysis
// ============================================================================

/// Creates a CSS value scanner parameterized by a compile-time function ruleset.
/// The scanner uses a state machine to distinguish function calls from string
/// literal content, avoiding false positives from patterns inside CSS strings.
pub fn CssValueScanner(comptime ruleset: specs.CssFunctionRuleset) type {
    return struct {
        sanitizer: *CssSanitizer,

        const Self = @This();

        // Build comptime lookup map from ruleset
        const function_map = blk: {
            var entries: [ruleset.functions.len]struct { []const u8, specs.CssFunctionClass } = undefined;
            for (ruleset.functions, 0..) |entry, i| {
                entries[i] = .{ entry[0], entry[1] };
            }
            break :blk std.StaticStringMap(specs.CssFunctionClass).initComptime(entries);
        };

        /// Scan a CSS value string for dangerous function calls.
        /// Returns true if the value is safe, false if it contains blocked functions.
        pub fn isValueSafe(self: Self, value: []const u8) bool {
            const State = enum { normal, in_string };
            var state: State = .normal;
            var quote_char: u8 = 0;
            var i: usize = 0;

            while (i < value.len) {
                switch (state) {
                    .normal => {
                        const ch = value[i];
                        if (ch == '"' or ch == '\'') {
                            state = .in_string;
                            quote_char = ch;
                            i += 1;
                        } else if (ch == '(') {
                            // Extract and classify the function name
                            if (extractFunctionName(value, i)) |func_name| {
                                const class = classifyFunction(func_name);
                                switch (class) {
                                    .blocked => return false,
                                    .url_validate => {
                                        if (!self.validateUrlArgument(value, i + 1)) {
                                            return false;
                                        }
                                    },
                                    .configurable_calc => {
                                        if (!self.sanitizer.options.allow_calc) return false;
                                    },
                                    .configurable_var => {
                                        if (!self.sanitizer.options.allow_css_variables) return false;
                                    },
                                    .configurable_env => {
                                        if (!self.sanitizer.options.allow_env) return false;
                                    },
                                    .allowed => {},
                                }
                            }
                            // No function name before ( means it's a grouping paren, which is fine
                            i += 1;
                        } else {
                            i += 1;
                        }
                    },
                    .in_string => {
                        const ch = value[i];
                        if (ch == '\\' and i + 1 < value.len) {
                            // Skip escaped character
                            i += 2;
                        } else if (ch == quote_char) {
                            state = .normal;
                            i += 1;
                        } else {
                            i += 1;
                        }
                    },
                }
            }
            return true;
        }

        /// Extract function name by scanning backwards from the opening paren.
        fn extractFunctionName(value: []const u8, paren_pos: usize) ?[]const u8 {
            if (paren_pos == 0) return null;
            const end = paren_pos;
            var start = paren_pos;
            while (start > 0) {
                const ch = value[start - 1];
                if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                    start -= 1;
                } else {
                    break;
                }
            }
            if (start == end) return null;
            return value[start..end];
        }

        /// Classify a function name using the comptime ruleset map.
        fn classifyFunction(name: []const u8) specs.CssFunctionClass {
            // Lowercase the function name for case-insensitive lookup
            var lower_buf: [128]u8 = undefined;
            if (name.len > lower_buf.len) return ruleset.unknown_function_policy;
            for (name, 0..) |ch, idx| {
                lower_buf[idx] = std.ascii.toLower(ch);
            }
            const lower = lower_buf[0..name.len];

            if (function_map.get(lower)) |class| {
                return class;
            }
            return ruleset.unknown_function_policy;
        }

        /// Validate the URL argument inside a url() function call.
        fn validateUrlArgument(self: Self, value: []const u8, start: usize) bool {
            // Find matching closing paren
            const end = findMatchingParen(value, start) orelse return false;
            const url_content = value[start .. end - 1];
            return self.sanitizer.isCssUrlSafe(url_content);
        }
    };
}

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

    /// Check if CSS contains dangerous at-rule patterns
    fn containsDangerousPatterns(_: *@This(), css: []const u8) bool {
        for (specs.DANGEROUS_CSS_AT_RULES) |pattern| {
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
            if (comptime @import("builtin").mode == .Debug) {
                std.debug.print("[CSS] Lexbor parser init failed, using string fallback\n", .{});
            }
            return try self.simpleCssFilter(input);
        };

        // Clean parser state for fresh parsing
        lxb_css_parser_clean(parser);

        // Parse the CSS declaration list (inline style format)
        const decl_list = lxb_css_declaration_list_parse(parser, input.ptr, input.len);
        if (decl_list == null) {
            // Parse failed - fallback to simple filter
            if (comptime @import("builtin").mode == .Debug) {
                std.debug.print("[CSS] Lexbor parse failed for: {s}..., using string fallback\n", .{input[0..@min(50, input.len)]});
            }
            return try self.simpleCssFilter(input);
        }
        // Lexbor AST path active
        if (comptime @import("builtin").mode == .Debug) {
            std.debug.print("[CSS] Lexbor AST parsing: {s}...\n", .{input[0..@min(30, input.len)]});
        }
        defer _ = lxb_css_rule_declaration_list_destroy(decl_list.?, true);

        // Get first declaration using C shim (avoids struct layout issues)
        // Note: z.CssRuleDeclarationList and CssRuleDeclList are both lxb_css_rule_declaration_list_t
        var current: ?*CssRule = zexp_css_decl_list_get_first(@ptrCast(decl_list.?));

        // Build result by iterating through declarations and filtering
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var first = true;

        while (current) |rule| {
            const rule_type = zexp_css_rule_get_type(rule);
            if (rule_type == LXB_CSS_RULE_DECLARATION) {
                // Get property name using C shim
                const prop_name = self.getDeclarationPropertyName(rule);
                if (prop_name.len == 0) {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                }

                // Check if property is allowed
                if (!self.isPropertyAllowed(prop_name)) {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                }

                // Serialize the declaration to check value safety
                var value_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer value_buf.deinit(self.allocator);
                var serialize_ctx = SerializeContext{ .list = &value_buf, .allocator = self.allocator };

                if (lxb_css_rule_declaration_serialize(rule, serializeCallback, &serialize_ctx) != lxb_status_ok) {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                }

                // Extract value part after colon
                const serialized = value_buf.items;
                const colon_idx = std.mem.indexOfScalar(u8, serialized, ':') orelse {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                };
                const value_part = std.mem.trim(u8, serialized[colon_idx + 1 ..], &std.ascii.whitespace);

                // Check if value is safe
                if (!self.isValueSafe(value_part)) {
                    current = zexp_css_rule_get_next(rule);
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

            current = zexp_css_rule_get_next(rule);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Get property name from a declaration rule using C shim
    fn getDeclarationPropertyName(self: *@This(), rule: *const CssRule) []const u8 {
        _ = self;

        // Get property type ID using C shim
        const type_id = zexp_css_declaration_get_type_id(rule);

        // Type 0 = undef (unknown property), 1 = custom (CSS variable)
        if (type_id == 0) {
            // Unknown property - block these for safety
            return "";
        } else if (type_id == 1) {
            // Custom property (CSS variable like --custom-prop)
            // For now, block custom properties - they could be used for data exfiltration
            return "";
        } else {
            // Known property - look up by ID
            if (lxb_css_property_by_id(type_id)) |entry| {
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

        // Check blacklist first (always blocked) - O(1) lookup
        if (specs.DANGEROUS_CSS_PROPERTIES.has(lower_prop)) {
            return false;
        }

        // If using whitelist, check against safe properties
        if (self.options.use_property_whitelist) {
            return specs.SAFE_CSS_PROPERTIES.has(lower_prop);
        }

        return true;
    }

    /// Check if a CSS value is safe using the structural CssValueScanner.
    /// The scanner distinguishes function calls from string literal content,
    /// avoiding false positives from patterns inside CSS strings like
    /// `content: "expression() is not dangerous here"`.
    fn isValueSafe(self: *@This(), value: []const u8) bool {
        const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
        const scanner = Scanner{ .sanitizer = self };
        return scanner.isValueSafe(value);
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
    /// Sanitize a full CSS stylesheet (with selectors and at-rules)
    ///
    /// This is for sanitizing <style> element content or external CSS files.
    /// Unlike inline styles, stylesheets contain selectors, at-rules, etc.
    ///
    /// Returns a sanitized stylesheet string. The caller owns the returned memory.
    /// Uses Lexbor AST for robust parsing, falls back to string-based if needed.
    pub fn sanitizeStylesheet(self: *@This(), input: []const u8) anyerror![]const u8 {
        // Try Lexbor AST first (uses its own parser to avoid state issues)
        return self.sanitizeStylesheetLexbor(input) catch {
            // Fallback to string-based parsing
            if (comptime @import("builtin").mode == .Debug) {
                std.debug.print("[CSS] Lexbor stylesheet failed, using string fallback\n", .{});
            }
            return self.sanitizeStylesheetStringBased(input);
        };
    }

    /// String-based stylesheet sanitization (fallback).
    fn sanitizeStylesheetStringBased(self: *@This(), input: []const u8) anyerror![]const u8 {
        if (input.len == 0) return "";

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            // Skip whitespace
            while (i < input.len and std.ascii.isWhitespace(input[i])) {
                try result.append(self.allocator, input[i]);
                i += 1;
            }
            if (i >= input.len) break;

            // Check for at-rules
            if (input[i] == '@') {
                const at_rule_end = self.findAtRuleEnd(input[i..]);
                const at_rule = input[i .. i + at_rule_end];

                if (self.isAtRuleSafe(at_rule)) {
                    // Process the at-rule - for @media/@supports, sanitize the contents
                    if (self.isBlockAtRule(at_rule)) {
                        try self.processBlockAtRule(&result, at_rule);
                    } else {
                        // Simple at-rule like @charset - pass through
                        try result.appendSlice(self.allocator, at_rule);
                    }
                }
                // Dangerous at-rules are completely dropped

                i += at_rule_end;
                continue;
            }

            // Check for comments
            if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '*') {
                const comment_end = std.mem.indexOf(u8, input[i + 2 ..], "*/");
                if (comment_end) |end| {
                    // Skip comment entirely
                    i += end + 4;
                } else {
                    // Unterminated comment - skip rest
                    break;
                }
                continue;
            }

            // Find the next rule block (selector { declarations })
            const block_start = std.mem.indexOfScalar(u8, input[i..], '{');
            if (block_start) |start| {
                const selector = input[i .. i + start];
                i += start + 1;

                // Find matching closing brace
                const block_end = self.findMatchingBrace(input[i..]);
                if (block_end) |end| {
                    const declarations = input[i .. i + end];

                    // Sanitize the selector and declarations
                    if (self.isSelectorSafe(selector)) {
                        try result.appendSlice(self.allocator, std.mem.trim(u8, selector, &std.ascii.whitespace));
                        try result.appendSlice(self.allocator, " { ");

                        // Sanitize declarations using the simple filter
                        // (simpleCssFilter is more reliable for stylesheet content)
                        const sanitized_decls = try self.simpleCssFilter(declarations);
                        defer self.allocator.free(sanitized_decls);
                        try result.appendSlice(self.allocator, sanitized_decls);

                        try result.appendSlice(self.allocator, " }\n");
                    }

                    i += end + 1;
                } else {
                    // Malformed CSS - skip to end
                    break;
                }
            } else {
                // No more blocks
                break;
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Find the end of an at-rule (including its block if any)
    fn findAtRuleEnd(self: *@This(), input: []const u8) usize {
        _ = self;
        var i: usize = 1; // Skip the @

        // Find the at-rule name end
        while (i < input.len and !std.ascii.isWhitespace(input[i]) and input[i] != '{' and input[i] != ';') {
            i += 1;
        }

        // Skip to { or ;
        while (i < input.len and input[i] != '{' and input[i] != ';') {
            i += 1;
        }

        if (i >= input.len) return input.len;

        if (input[i] == ';') {
            return i + 1;
        }

        if (input[i] == '{') {
            // Find matching closing brace
            var depth: usize = 1;
            i += 1;
            while (i < input.len and depth > 0) {
                if (input[i] == '{') depth += 1;
                if (input[i] == '}') depth -= 1;
                i += 1;
            }
            return i;
        }

        return i;
    }

    /// Check if an at-rule is safe
    fn isAtRuleSafe(self: *@This(), at_rule: []const u8) bool {
        _ = self;
        // Extract the at-rule name
        var name_end: usize = 1;
        while (name_end < at_rule.len and !std.ascii.isWhitespace(at_rule[name_end]) and at_rule[name_end] != '{' and at_rule[name_end] != ';') {
            name_end += 1;
        }
        const name = at_rule[1..name_end];

        // Dangerous at-rules
        if (specs.startsWithIgnoreCase(name, "import")) return false;
        if (specs.startsWithIgnoreCase(name, "charset") and name.len > 7) return false; // @charset is ok, but not @charsetX
        if (specs.startsWithIgnoreCase(name, "namespace")) return false;

        return true;
    }

    /// Check if an at-rule contains a block
    fn isBlockAtRule(self: *@This(), at_rule: []const u8) bool {
        _ = self;
        return std.mem.indexOfScalar(u8, at_rule, '{') != null;
    }

    /// Process a block at-rule like @media or @supports
    fn processBlockAtRule(self: *@This(), result: *std.ArrayListUnmanaged(u8), at_rule: []const u8) anyerror!void {
        const block_start = std.mem.indexOfScalar(u8, at_rule, '{') orelse return;
        const prelude = at_rule[0..block_start];

        // Find matching closing brace
        var depth: usize = 1;
        var block_end: usize = block_start + 1;
        while (block_end < at_rule.len and depth > 0) {
            if (at_rule[block_end] == '{') depth += 1;
            if (at_rule[block_end] == '}') depth -= 1;
            block_end += 1;
        }

        const block_content = at_rule[block_start + 1 .. block_end - 1];

        // Write prelude
        try result.appendSlice(self.allocator, std.mem.trim(u8, prelude, &std.ascii.whitespace));
        try result.appendSlice(self.allocator, " {\n");

        // Recursively sanitize block content
        const sanitized_content = try self.sanitizeStylesheet(block_content);
        defer self.allocator.free(sanitized_content);
        try result.appendSlice(self.allocator, sanitized_content);

        try result.appendSlice(self.allocator, "}\n");
    }

    /// Find the matching closing brace
    fn findMatchingBrace(self: *@This(), input: []const u8) ?usize {
        _ = self;
        var depth: usize = 1;
        var i: usize = 0;
        while (i < input.len and depth > 0) {
            if (input[i] == '{') depth += 1;
            if (input[i] == '}') depth -= 1;
            if (depth == 0) return i;
            i += 1;
        }
        return null;
    }

    /// Check if a CSS selector is safe
    fn isSelectorSafe(self: *@This(), selector: []const u8) bool {
        _ = self;
        const trimmed = std.mem.trim(u8, selector, &std.ascii.whitespace);
        if (trimmed.len == 0) return false;

        // Block some dangerous pseudo-selectors
        if (containsCaseInsensitive(trimmed, ":has(")) return false;

        return true;
    }

    // ========================================================================
    // LEXBOR AST-BASED STYLESHEET SANITIZATION
    // ========================================================================
    //
    // This is a more robust approach that uses Lexbor to parse the stylesheet
    // into an AST, then walks the AST validating each rule. This is safer than
    // string-based parsing because Lexbor handles all CSS syntax edge cases.
    //

    /// Sanitize a stylesheet using Lexbor's full CSS parser (AST-based)
    ///
    /// This parses the CSS into a proper AST, walks each rule, validates
    /// selectors and properties against whitelists, and serializes back
    /// only the safe rules. More robust than string-based parsing.
    pub fn sanitizeStylesheetLexbor(self: *@This(), input: []const u8) ![]const u8 {
        if (input.len == 0) return "";

        // Quick check for dangerous patterns first
        if (self.containsDangerousPatterns(input)) {
            // Still parse properly - just to remove the dangerous parts
        }

        // Create dedicated parser for stylesheet (don't share with inline style parser)
        // This avoids state corruption between stylesheet and declaration list parsing
        const parser = lxb_css_parser_create() orelse return error.CssParserCreateFailed;
        defer _ = lxb_css_parser_destroy(parser, true);

        if (lxb_css_parser_init(parser, null) != lxb_status_ok) {
            return error.CssParserInitFailed;
        }

        // Create stylesheet with its own memory
        const sst = lxb_css_stylesheet_create(null) orelse
            return error.LexborStylesheetFailed;

        defer _ = lxb_css_stylesheet_destroy(sst, true);

        if (lxb_css_stylesheet_parse(sst, parser, input.ptr, input.len) != lxb_status_ok) {
            if (comptime @import("builtin").mode == .Debug) {
                std.debug.print("[CSS] Lexbor stylesheet parse failed\n", .{});
            }
            return error.LexborStylesheetFailed;
        }

        // Lexbor AST stylesheet path active
        if (comptime @import("builtin").mode == .Debug) {
            std.debug.print("[CSS] Lexbor AST stylesheet: {d} bytes\n", .{input.len});
        }

        // Build result by walking the AST
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Walk the rule tree using C shim to get root
        const root = zexp_css_stylesheet_get_root(sst);
        try self.walkAndSanitizeRules(&result, root);

        return try result.toOwnedSlice(self.allocator);
    }

    /// Walk the CSS rule tree and sanitize each rule (using C shim functions)
    fn walkAndSanitizeRules(self: *@This(), result: *std.ArrayListUnmanaged(u8), root: ?*CssRule) !void {
        var current = root;

        while (current) |rule| {
            const rule_type = zexp_css_rule_get_type(rule);
            switch (rule_type) {
                LXB_CSS_RULE_STYLE => {
                    // Style rule: selector { declarations }
                    try self.sanitizeStyleRule(result, rule);
                },
                LXB_CSS_RULE_AT_RULE => {
                    // At-rule: @media, @import, etc.
                    try self.sanitizeAtRule(result, rule);
                },
                LXB_CSS_RULE_LIST => {
                    // Rule list - recurse into it
                    const first_rule = zexp_css_rule_list_get_first(rule);
                    try self.walkAndSanitizeRules(result, first_rule);
                },
                else => {
                    // Skip unknown/bad rules
                },
            }

            current = zexp_css_rule_get_next(rule);
        }
    }

    /// Sanitize a style rule (selector + declarations) using C shim
    fn sanitizeStyleRule(self: *@This(), result: *std.ArrayListUnmanaged(u8), rule: *const CssRule) !void {
        // Get selector using C shim
        if (zexp_css_rule_style_get_selector(rule)) |selector| {
            var selector_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer selector_buf.deinit(self.allocator);
            var sel_ctx = SerializeContext{ .list = &selector_buf, .allocator = self.allocator };

            if (lxb_css_selector_serialize_list(selector, serializeCallback, &sel_ctx) != lxb_status_ok) {
                return; // Skip this rule on serialization error
            }

            const selector_str = selector_buf.items;

            // Check if selector is safe
            if (!self.isSelectorSafe(selector_str)) {
                return; // Skip dangerous selector
            }

            // Get declarations using C shim
            if (zexp_css_rule_style_get_declarations(rule)) |decls| {
                const sanitized_decls = try self.sanitizeDeclarationListFromRule(decls);
                defer self.allocator.free(sanitized_decls);

                // Only output if we have declarations left
                if (sanitized_decls.len > 0) {
                    try result.appendSlice(self.allocator, selector_str);
                    try result.appendSlice(self.allocator, " { ");
                    try result.appendSlice(self.allocator, sanitized_decls);
                    try result.appendSlice(self.allocator, " }\n");
                }
            }
        }
    }

    /// Sanitize a declaration list using C shim functions
    fn sanitizeDeclarationListFromRule(self: *@This(), decl_list: *const CssRuleDeclList) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Get first declaration using shim
        var current: ?*CssRule = zexp_css_decl_list_get_first(decl_list);
        var first = true;

        while (current) |rule| {
            const rule_type = zexp_css_rule_get_type(rule);
            if (rule_type == LXB_CSS_RULE_DECLARATION) {
                // Get property name using C shim
                const prop_name = self.getDeclarationPropertyName(rule);
                if (prop_name.len == 0) {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                }

                // Check if property is allowed
                if (!self.isPropertyAllowed(prop_name)) {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                }

                // Serialize the full declaration to check value
                var decl_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer decl_buf.deinit(self.allocator);
                var decl_ctx = SerializeContext{ .list = &decl_buf, .allocator = self.allocator };

                if (lxb_css_rule_declaration_serialize(rule, serializeCallback, &decl_ctx) != lxb_status_ok) {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                }

                // Extract value part and validate
                const serialized = decl_buf.items;
                const colon_idx = std.mem.indexOfScalar(u8, serialized, ':') orelse {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                };
                const value_part = std.mem.trim(u8, serialized[colon_idx + 1 ..], &std.ascii.whitespace);

                if (!self.isValueSafe(value_part)) {
                    current = zexp_css_rule_get_next(rule);
                    continue;
                }

                // This declaration is safe - add it
                if (!first) {
                    try result.appendSlice(self.allocator, "; ");
                }
                first = false;
                try result.appendSlice(self.allocator, serialized);
            }

            current = zexp_css_rule_get_next(rule);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Sanitize an at-rule (@media, @import, etc.) using C shim
    fn sanitizeAtRule(self: *@This(), result: *std.ArrayListUnmanaged(u8), rule: *const CssRule) !void {
        // Get at-rule type using C shim
        const at_type = zexp_css_at_rule_get_type(rule);

        switch (at_type) {
            LXB_CSS_AT_RULE_UNDEF => {
                // Unknown at-rule - serialize it to check for dangerous patterns
                var at_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer at_buf.deinit(self.allocator);
                var at_ctx = SerializeContext{ .list = &at_buf, .allocator = self.allocator };

                if (lxb_css_rule_at_serialize(rule, serializeCallback, &at_ctx) == lxb_status_ok) {
                    const serialized = at_buf.items;
                    // Block @import and @namespace
                    if (containsCaseInsensitive(serialized, "@import") or
                        containsCaseInsensitive(serialized, "@namespace"))
                    {
                        return; // Skip dangerous at-rules
                    }
                    // Allow other unknown at-rules (like @charset)
                    try result.appendSlice(self.allocator, serialized);
                    try result.append(self.allocator, '\n');
                }
            },
            LXB_CSS_AT_RULE_MEDIA => {
                // @media is safe - serialize the whole at-rule
                var at_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer at_buf.deinit(self.allocator);
                var at_ctx = SerializeContext{ .list = &at_buf, .allocator = self.allocator };

                if (lxb_css_rule_at_serialize(rule, serializeCallback, &at_ctx) == lxb_status_ok) {
                    try result.appendSlice(self.allocator, at_buf.items);
                    try result.append(self.allocator, '\n');
                }
            },
            LXB_CSS_AT_RULE_NAMESPACE => {
                // @namespace - block it
                return;
            },
            LXB_CSS_AT_RULE_FONT_FACE => {
                // @font-face - allow if configured
                if (!self.options.allow_font_face) return;

                // Serialize the @font-face rule
                var at_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer at_buf.deinit(self.allocator);
                var at_ctx = SerializeContext{ .list = &at_buf, .allocator = self.allocator };

                if (lxb_css_rule_at_serialize(rule, serializeCallback, &at_ctx) == lxb_status_ok) {
                    try result.appendSlice(self.allocator, at_buf.items);
                    try result.append(self.allocator, '\n');
                }
            },
            else => {
                // Unknown - skip for safety
            },
        }
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

    // @import is in DANGEROUS_CSS_AT_RULES
    const input = "@import url('evil.css'); color: red";
    const result = try sanitizer.sanitizeStyleString(input);
    defer testing.allocator.free(result);

    // Should return empty because containsDangerousPatterns catches @import
    try testing.expectEqualStrings("", result);
}

test "CSS sanitizer - stylesheet with selectors" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const input =
        \\.header { color: red; font-size: 16px; }
        \\.evil { -moz-binding: url('evil.xml'); }
        \\p { margin: 10px; }
    ;
    const result = try sanitizer.sanitizeStylesheet(input);
    defer testing.allocator.free(result);

    // Safe rules should pass through
    try testing.expect(std.mem.indexOf(u8, result, ".header") != null);
    try testing.expect(std.mem.indexOf(u8, result, "color: red") != null);
    try testing.expect(std.mem.indexOf(u8, result, "margin: 10px") != null);

    // Dangerous property should be blocked
    try testing.expect(std.mem.indexOf(u8, result, "-moz-binding") == null);
}

test "CSS sanitizer - stylesheet @import blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const input =
        \\@import url('evil.css');
        \\.header { color: red; }
    ;
    const result = try sanitizer.sanitizeStylesheet(input);
    defer testing.allocator.free(result);

    // @import should be completely removed
    try testing.expect(std.mem.indexOf(u8, result, "@import") == null);

    // Safe rule should remain
    try testing.expect(std.mem.indexOf(u8, result, ".header") != null);
    try testing.expect(std.mem.indexOf(u8, result, "color: red") != null);
}

// test "CSS sanitizer - stylesheet @media preserved" {
//     var sanitizer = try CssSanitizer.init(testing.allocator, .{});
//     defer sanitizer.deinit();

//     const input =
//         \\@media screen and (max-width: 600px) {
//         \\  .header { color: blue; }
//         \\}
//     ;
//     const result = try sanitizer.sanitizeStylesheet(input);
//     defer testing.allocator.free(result);

//     // @media should be preserved
//     try testing.expect(std.mem.indexOf(u8, result, "@media") != null);
//     try testing.expect(std.mem.indexOf(u8, result, "max-width") != null);
//     try testing.expect(std.mem.indexOf(u8, result, ".header") != null);
//     try testing.expect(std.mem.indexOf(u8, result, "color: blue") != null);
// }

// TODO
// test "csrf" {
//     const allocator = testing.allocator;
//     const html =
//         \\<body>
//         \\<form action='http://example.com/record.php?'<textarea><input type="hidden" name="anti_xsrf" value="eW91J3JlIGN1cmlvdXMsIGFyZW4ndCB5b3U/">
//         \\</form>
//         \\<img src='http://example.com/record.php?<input type="hidden" name="anti_xsrf" value="eW91J3JlIGN1cmlvdXMsIGFyZW4ndCB5b3U/">
//         \\</body>
//     ;
//     const doc = try z.parseHTML(allocator, html);

//     try z.prettyPrint(allocator, z.bodyNode(doc).?);
// }

test "CSS sanitizer - Lexbor AST-based stylesheet sanitization" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const input =
        \\.safe { color: green; padding: 10px; }
        \\.dangerous { behavior: url(evil.htc); -moz-binding: url(xss.xml); }
        \\.also-safe { margin: 5px; font-size: 16px; }
    ;

    const lexbor_result = try sanitizer.sanitizeStylesheetLexbor(input);
    defer testing.allocator.free(lexbor_result);

    // Safe selectors and properties should be preserved
    try testing.expect(std.mem.indexOf(u8, lexbor_result, ".safe") != null);
    try testing.expect(std.mem.indexOf(u8, lexbor_result, "color: green") != null);

    // Dangerous properties should be removed
    try testing.expect(std.mem.indexOf(u8, lexbor_result, "behavior") == null);
    try testing.expect(std.mem.indexOf(u8, lexbor_result, "-moz-binding") == null);

    // Second safe selector should be preserved
    try testing.expect(std.mem.indexOf(u8, lexbor_result, ".also-safe") != null);
}

// ============================================================================
// CssValueScanner Tests
// ============================================================================

test "CSS scanner - expression() inside string literal is safe" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    // expression() inside a string is NOT a function call — should be safe
    try testing.expect(scanner.isValueSafe("\"use expression() carefully\""));
    try testing.expect(scanner.isValueSafe("'expression(alert(1))'"));
    try testing.expect(scanner.isValueSafe("\"eval(something)\""));
}

test "CSS scanner - expression() as function call is blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(!scanner.isValueSafe("expression(alert(1))"));
    try testing.expect(!scanner.isValueSafe("Expression(alert(1))"));
    try testing.expect(!scanner.isValueSafe("EXPRESSION(alert(1))"));
}

test "CSS scanner - eval() always blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(!scanner.isValueSafe("eval(something)"));
}

test "CSS scanner - calc() allowed by default" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(scanner.isValueSafe("calc(100% - 20px)"));
    try testing.expect(scanner.isValueSafe("calc(50vh - 2rem)"));
}

test "CSS scanner - var() blocked by default, allowed when configured" {
    // Default: var() blocked
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    var scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(!scanner.isValueSafe("var(--main-color)"));

    // With allow_css_variables=true: var() allowed
    var sanitizer2 = try CssSanitizer.init(testing.allocator, .{ .allow_css_variables = true });
    defer sanitizer2.deinit();

    scanner = Scanner{ .sanitizer = &sanitizer2 };
    try testing.expect(scanner.isValueSafe("var(--main-color)"));
}

test "CSS scanner - standard CSS functions allowed" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(scanner.isValueSafe("rgb(255, 0, 0)"));
    try testing.expect(scanner.isValueSafe("rgba(255, 0, 0, 0.5)"));
    try testing.expect(scanner.isValueSafe("hsl(120, 100%, 50%)"));
    try testing.expect(scanner.isValueSafe("linear-gradient(to right, red, blue)"));
    try testing.expect(scanner.isValueSafe("rotate(45deg)"));
    try testing.expect(scanner.isValueSafe("scale(1.5)"));
    try testing.expect(scanner.isValueSafe("translate(10px, 20px)"));
    try testing.expect(scanner.isValueSafe("blur(5px)"));
    try testing.expect(scanner.isValueSafe("cubic-bezier(0.4, 0, 0.2, 1)"));
    try testing.expect(scanner.isValueSafe("clamp(1rem, 2vw, 3rem)"));
    try testing.expect(scanner.isValueSafe("min(100px, 50%)"));
    try testing.expect(scanner.isValueSafe("max(200px, 30vw)"));
}

test "CSS scanner - url() with javascript: blocked" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{ .allow_css_urls = true });
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(!scanner.isValueSafe("url(javascript:alert(1))"));
    try testing.expect(!scanner.isValueSafe("url(vbscript:alert(1))"));
    try testing.expect(!scanner.isValueSafe("url(data:text/html,<script>alert(1)</script>)"));
}

test "CSS scanner - url() with safe URL allowed when configured" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{ .allow_css_urls = true });
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(scanner.isValueSafe("url(https://example.com/image.png)"));
}

test "CSS scanner - url() blocked when allow_css_urls is false" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(!scanner.isValueSafe("url(https://example.com/image.png)"));
}

test "CSS scanner - unknown function blocked with DEFAULT_RULESET" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(!scanner.isValueSafe("unknownfunc(something)"));
    try testing.expect(!scanner.isValueSafe("malicious(payload)"));
}

test "CSS scanner - unknown function allowed with PERMISSIVE_RULESET" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.PERMISSIVE_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    // Unknown functions are allowed in permissive mode
    try testing.expect(scanner.isValueSafe("somefunc(whatever)"));
    // But expression/eval are still blocked
    try testing.expect(!scanner.isValueSafe("expression(alert(1))"));
    try testing.expect(!scanner.isValueSafe("eval(something)"));
}

test "CSS scanner - nested functions" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(scanner.isValueSafe("calc(min(10px, 5vw))"));
    try testing.expect(scanner.isValueSafe("clamp(1rem, calc(2vw + 1rem), 3rem)"));
}

test "CSS scanner - custom comptime ruleset" {
    const custom_ruleset = specs.CssFunctionRuleset{
        .functions = &[_]specs.CssFunctionEntry{
            .{ "expression", .blocked },
            .{ "rgb", .allowed },
            .{ "url", .url_validate },
        },
        .unknown_function_policy = .allowed, // blocklist approach
    };

    var sanitizer = try CssSanitizer.init(testing.allocator, .{ .allow_css_urls = true });
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(custom_ruleset);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    // Blocked functions still blocked
    try testing.expect(!scanner.isValueSafe("expression(alert(1))"));
    // Known safe
    try testing.expect(scanner.isValueSafe("rgb(255, 0, 0)"));
    // Unknown functions allowed (blocklist approach)
    try testing.expect(scanner.isValueSafe("anything(here)"));
    // URL still validated
    try testing.expect(!scanner.isValueSafe("url(javascript:alert(1))"));
    try testing.expect(scanner.isValueSafe("url(https://example.com/img.png)"));
}

test "CSS scanner - escaped quotes in strings" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    // Escaped quote inside string should not exit string state
    try testing.expect(scanner.isValueSafe("\"expression\\\"(still string)\""));
    try testing.expect(scanner.isValueSafe("'eval\\'(still string)'"));
}

test "CSS scanner - plain values without functions" {
    var sanitizer = try CssSanitizer.init(testing.allocator, .{});
    defer sanitizer.deinit();

    const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
    const scanner = Scanner{ .sanitizer = &sanitizer };

    try testing.expect(scanner.isValueSafe("red"));
    try testing.expect(scanner.isValueSafe("#ff0000"));
    try testing.expect(scanner.isValueSafe("14px"));
    try testing.expect(scanner.isValueSafe("10px 20px 30px"));
    try testing.expect(scanner.isValueSafe("solid 1px black"));
    try testing.expect(scanner.isValueSafe("\"some string\""));
}

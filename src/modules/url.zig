//! URL parsing and manipulation using lexbor's WHATWG URL Standard implementation
//!
//! This module provides Zig wrappers around lexbor's URL API.
//! Based on specification: https://url.spec.whatwg.org/
//!
//! Main components:
//! - URLParser: Parser object for creating URL instances
//! - URL: Parsed URL with properties (scheme, host, path, etc.)
//! - URLSearchParams: Query string parameter management

const std = @import("std");
const z = @import("../root.zig");
const testing = std.testing;

// ============================================================================
// Lexbor C API Bindings
// ============================================================================

pub const lexbor_mraw_t = opaque {};
pub const lxb_url_parser_t = opaque {};
pub const lxb_url_search_params_t = opaque {};
pub const lxb_url_search_entry_t = opaque {};

pub const lxb_url_scheme_type_t = c_uint;
pub const lxb_url_host_type_t = c_uint;

// URL component structures
pub const lxb_url_scheme_t = extern struct {
    name: z.lexbor_str_t,
    @"type": lxb_url_scheme_type_t,
};

pub const lxb_url_host_union_t = extern union {
    ipv6: [8]u16,
    ipv4: u32,
    @"opaque": z.lexbor_str_t,
    domain: z.lexbor_str_t,
};

pub const lxb_url_host_t = extern struct {
    @"type": lxb_url_host_type_t,
    u: lxb_url_host_union_t,
};

pub const lxb_url_path_t = extern struct {
    str: z.lexbor_str_t,
    length: usize,
    @"opaque": bool,
};

// Main URL structure
pub const lxb_url_t = extern struct {
    scheme: lxb_url_scheme_t,
    host: lxb_url_host_t,
    username: z.lexbor_str_t,
    password: z.lexbor_str_t,
    port: u16,
    has_port: bool,
    path: lxb_url_path_t,
    query: z.lexbor_str_t,
    fragment: z.lexbor_str_t,
    mraw: *lexbor_mraw_t,
};

// Serialization callback type
pub const lexbor_serialize_cb_f = ?*const fn (data: [*c]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) z.lxb_status_t;

// Memory management
extern "c" fn lexbor_mraw_create() ?*lexbor_mraw_t;
extern "c" fn lexbor_mraw_init(mraw: *lexbor_mraw_t, chunk_size: usize) z.lxb_status_t;
extern "c" fn lexbor_mraw_destroy(mraw: *lexbor_mraw_t, destroy_self: bool) ?*lexbor_mraw_t;

// Parser functions
extern "c" fn lxb_url_parser_create() ?*lxb_url_parser_t;
extern "c" fn lxb_url_parser_init(parser: *lxb_url_parser_t, mraw: ?*lexbor_mraw_t) z.lxb_status_t;
extern "c" fn lxb_url_parser_clean(parser: *lxb_url_parser_t) void;
extern "c" fn lxb_url_parser_destroy(parser: *lxb_url_parser_t, destroy_self: bool) ?*lxb_url_parser_t;
extern "c" fn lxb_url_parser_memory_destroy(parser: *lxb_url_parser_t) void;

// URL parsing
extern "c" fn lxb_url_parse(
    parser: *lxb_url_parser_t,
    base_url: ?*const lxb_url_t,
    data: [*c]const u8,
    length: usize,
) ?*lxb_url_t;

// URL lifecycle
extern "c" fn lxb_url_erase(url: *lxb_url_t) void;
extern "c" fn lxb_url_destroy(url: *lxb_url_t) ?*lxb_url_t;
extern "c" fn lxb_url_memory_destroy(url: *lxb_url_t) void;

// URL getters - implemented inline in Zig (these are inline functions in C header)
inline fn lxb_url_scheme(url: *const lxb_url_t) *const z.lexbor_str_t {
    return &url.scheme.name;
}
inline fn lxb_url_username(url: *const lxb_url_t) *const z.lexbor_str_t {
    return &url.username;
}
inline fn lxb_url_password(url: *const lxb_url_t) *const z.lexbor_str_t {
    return &url.password;
}
inline fn lxb_url_port(url: *const lxb_url_t) u16 {
    return url.port;
}
inline fn lxb_url_has_port(url: *const lxb_url_t) bool {
    return url.has_port;
}
inline fn lxb_url_path_str(url: *const lxb_url_t) *const z.lexbor_str_t {
    return &url.path.str;
}
inline fn lxb_url_query(url: *const lxb_url_t) *const z.lexbor_str_t {
    return &url.query;
}
inline fn lxb_url_fragment(url: *const lxb_url_t) *const z.lexbor_str_t {
    return &url.fragment;
}

// URL setters
extern "c" fn lxb_url_api_href_set(
    url: *lxb_url_t,
    parser: ?*lxb_url_parser_t,
    href: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_protocol_set(
    url: *lxb_url_t,
    parser: ?*lxb_url_parser_t,
    protocol: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_username_set(
    url: *lxb_url_t,
    username: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_password_set(
    url: *lxb_url_t,
    password: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_hostname_set(
    url: *lxb_url_t,
    parser: ?*lxb_url_parser_t,
    hostname: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_port_set(
    url: *lxb_url_t,
    parser: ?*lxb_url_parser_t,
    port: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_pathname_set(
    url: *lxb_url_t,
    parser: ?*lxb_url_parser_t,
    pathname: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_search_set(
    url: *lxb_url_t,
    parser: ?*lxb_url_parser_t,
    search: [*c]const u8,
    length: usize,
) z.lxb_status_t;

extern "c" fn lxb_url_api_hash_set(
    url: *lxb_url_t,
    parser: ?*lxb_url_parser_t,
    hash: [*c]const u8,
    length: usize,
) z.lxb_status_t;

// URL serialization
extern "c" fn lxb_url_serialize(
    url: *const lxb_url_t,
    cb: lexbor_serialize_cb_f,
    ctx: ?*anyopaque,
    exclude_fragment: bool,
) z.lxb_status_t;

extern "c" fn lxb_url_serialize_host(
    host: *const lxb_url_host_t,
    cb: lexbor_serialize_cb_f,
    ctx: ?*anyopaque,
) z.lxb_status_t;

extern "c" fn lxb_url_serialize_host_ipv4(
    ipv4: u32,
    cb: lexbor_serialize_cb_f,
    ctx: ?*anyopaque,
) z.lxb_status_t;

extern "c" fn lxb_url_serialize_host_ipv6(
    ipv6: [*c]const u16,
    cb: lexbor_serialize_cb_f,
    ctx: ?*anyopaque,
) z.lxb_status_t;

// URLSearchParams functions
extern "c" fn lxb_url_search_params_init(
    mraw: *lexbor_mraw_t,
    params: [*c]const u8,
    length: usize,
) ?*lxb_url_search_params_t;

extern "c" fn lxb_url_search_params_destroy(
    search_params: *lxb_url_search_params_t,
) ?*lxb_url_search_params_t;

extern "c" fn lxb_url_search_params_append(
    search_params: *lxb_url_search_params_t,
    name: [*c]const u8,
    name_length: usize,
    value: [*c]const u8,
    value_length: usize,
) ?*lxb_url_search_entry_t;

extern "c" fn lxb_url_search_params_delete(
    search_params: *lxb_url_search_params_t,
    name: [*c]const u8,
    name_length: usize,
    value: [*c]const u8,
    value_length: usize,
) void;

extern "c" fn lxb_url_search_params_get(
    search_params: *lxb_url_search_params_t,
    name: [*c]const u8,
    length: usize,
) ?*const z.lexbor_str_t;

extern "c" fn lxb_url_search_params_has(
    search_params: *lxb_url_search_params_t,
    name: [*c]const u8,
    name_length: usize,
    value: [*c]const u8,
    value_length: usize,
) bool;

extern "c" fn lxb_url_search_params_set(
    search_params: *lxb_url_search_params_t,
    name: [*c]const u8,
    name_length: usize,
    value: [*c]const u8,
    value_length: usize,
) ?*lxb_url_search_entry_t;

extern "c" fn lxb_url_search_params_sort(
    search_params: *lxb_url_search_params_t,
) void;

extern "c" fn lxb_url_search_params_serialize(
    search_params: *lxb_url_search_params_t,
    cb: lexbor_serialize_cb_f,
    ctx: ?*anyopaque,
) z.lxb_status_t;

// ============================================================================
// Zig API Wrappers
// ============================================================================

/// URL Parser - creates and manages URL objects
pub const URLParser = struct {
    parser: *lxb_url_parser_t,

    /// Create a new URL parser
    pub fn create() !URLParser {
        const parser = lxb_url_parser_create() orelse return z.Err.OutOfMemory;
        const status = lxb_url_parser_init(parser, null);
        if (status != z.LXB_STATUS_OK) {
            _ = lxb_url_parser_destroy(parser, true);
            return z.Err.InitializationFailed;
        }
        return URLParser{ .parser = parser };
    }

    /// Destroy the parser and free resources
    pub fn destroy(self: *URLParser) void {
        _ = lxb_url_parser_destroy(self.parser, true);
    }

    /// Parse a URL string
    pub fn parse(self: *URLParser, url_string: []const u8) !URL {
        const url_ptr = lxb_url_parse(
            self.parser,
            null,
            url_string.ptr,
            url_string.len,
        ) orelse return z.Err.InvalidURL;

        return URL{ .url = url_ptr };
    }

    /// Parse a relative URL with a base URL
    pub fn parseRelative(self: *URLParser, url_string: []const u8, base: *const URL) !URL {
        const url_ptr = lxb_url_parse(
            self.parser,
            base.url,
            url_string.ptr,
            url_string.len,
        ) orelse return z.Err.InvalidURL;

        return URL{ .url = url_ptr };
    }

    /// Clean parser state for reuse
    pub fn clean(self: *URLParser) void {
        lxb_url_parser_clean(self.parser);
    }
};

/// Parsed URL object
pub const URL = struct {
    url: *lxb_url_t,

    /// Destroy the URL and free resources
    pub fn destroy(self: *URL) void {
        _ = lxb_url_destroy(self.url);
    }

    // Getters (zero-copy, return slices into lexbor's internal buffers)

    pub fn scheme(self: *const URL) []const u8 {
        const str = lxb_url_scheme(self.url);
        return if (str.length > 0) str.data[0..str.length] else "";
    }

    pub fn username(self: *const URL) []const u8 {
        const str = lxb_url_username(self.url);
        return if (str.length > 0) str.data[0..str.length] else "";
    }

    pub fn password(self: *const URL) []const u8 {
        const str = lxb_url_password(self.url);
        return if (str.length > 0) str.data[0..str.length] else "";
    }

    pub fn port(self: *const URL) u16 {
        return lxb_url_port(self.url);
    }

    pub fn hasPort(self: *const URL) bool {
        return lxb_url_has_port(self.url);
    }

    pub fn pathname(self: *const URL) []const u8 {
        const str = lxb_url_path_str(self.url);
        return if (str.length > 0) str.data[0..str.length] else "";
    }

    pub fn search(self: *const URL) []const u8 {
        const str = lxb_url_query(self.url);
        return if (str.length > 0) str.data[0..str.length] else "";
    }

    pub fn hash(self: *const URL) []const u8 {
        const str = lxb_url_fragment(self.url);
        return if (str.length > 0) str.data[0..str.length] else "";
    }

    /// Serialize hostname to string (allocates)
    pub fn hostname(self: *const URL, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(allocator);

        var ctx = SerializeContext{
            .allocator = allocator,
            .list = &list,
        };

        const status = lxb_url_serialize_host(
            &self.url.host,
            serializeCallback,
            &ctx,
        );

        if (status != z.LXB_STATUS_OK) return z.Err.SerializationFailed;
        return list.toOwnedSlice(allocator);
    }

    // Setters

    pub fn setProtocol(self: *URL, protocol: []const u8) !void {
        const status = lxb_url_api_protocol_set(
            self.url,
            null,
            protocol.ptr,
            protocol.len,
        );
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    pub fn setUsername(self: *URL, user: []const u8) !void {
        const status = lxb_url_api_username_set(self.url, user.ptr, user.len);
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    pub fn setPassword(self: *URL, pass: []const u8) !void {
        const status = lxb_url_api_password_set(self.url, pass.ptr, pass.len);
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    pub fn setHostname(self: *URL, host: []const u8) !void {
        const status = lxb_url_api_hostname_set(
            self.url,
            null,
            host.ptr,
            host.len,
        );
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    pub fn setPort(self: *URL, port_str: []const u8) !void {
        const status = lxb_url_api_port_set(
            self.url,
            null,
            port_str.ptr,
            port_str.len,
        );
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    pub fn setPathname(self: *URL, path: []const u8) !void {
        const status = lxb_url_api_pathname_set(
            self.url,
            null,
            path.ptr,
            path.len,
        );
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    pub fn setSearch(self: *URL, query: []const u8) !void {
        const status = lxb_url_api_search_set(
            self.url,
            null,
            query.ptr,
            query.len,
        );
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    pub fn setHash(self: *URL, fragment: []const u8) !void {
        const status = lxb_url_api_hash_set(
            self.url,
            null,
            fragment.ptr,
            fragment.len,
        );
        if (status != z.LXB_STATUS_OK) return z.Err.InvalidValue;
    }

    /// Serialize URL to string (allocates)
    pub fn toString(self: *const URL, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(allocator);

        var ctx = SerializeContext{
            .allocator = allocator,
            .list = &list,
        };

        const status = lxb_url_serialize(
            self.url,
            serializeCallback,
            &ctx,
            false, // include fragment
        );

        if (status != z.LXB_STATUS_OK) return z.Err.SerializationFailed;
        return list.toOwnedSlice(allocator);
    }

    /// Serialize URL without fragment (allocates)
    pub fn toStringWithoutFragment(self: *const URL, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(allocator);

        var ctx = SerializeContext{
            .allocator = allocator,
            .list = &list,
        };

        const status = lxb_url_serialize(
            self.url,
            serializeCallback,
            &ctx,
            true, // exclude fragment
        );

        if (status != z.LXB_STATUS_OK) return z.Err.SerializationFailed;
        return list.toOwnedSlice(allocator);
    }
};

/// URL Search Parameters - query string management
pub const URLSearchParams = struct {
    params: *lxb_url_search_params_t,
    mraw: *lexbor_mraw_t,

    /// Create from query string (e.g., "foo=bar&baz=qux")
    pub fn init(allocator: std.mem.Allocator, query: []const u8) !URLSearchParams {
        _ = allocator; // Reserve for potential future use

        const mraw = lexbor_mraw_create() orelse return error.OutOfMemory;
        errdefer _ = lexbor_mraw_destroy(mraw, true);

        // Size the arena based on query length with reasonable bounds
        // Minimum 256 bytes, maximum 4096 bytes
        // Use 2x query length to account for parsing overhead
        const chunk_size = @min(4096, @max(256, query.len * 2));

        const status = lexbor_mraw_init(mraw, chunk_size);
        if (status != z.LXB_STATUS_OK) {
            _ = lexbor_mraw_destroy(mraw, true);
            return error.InitializationFailed;
        }

        const params = lxb_url_search_params_init(
            mraw,
            query.ptr,
            query.len,
        ) orelse {
            _ = lexbor_mraw_destroy(mraw, true);
            return error.InitializationFailed;
        };

        return URLSearchParams{ .params = params, .mraw = mraw };
    }

    /// Create empty
    pub fn initEmpty(allocator: std.mem.Allocator) !URLSearchParams {
        return init(allocator, "");
    }

    /// Destroy and free resources
    pub fn deinit(self: *URLSearchParams) void {
        _ = lxb_url_search_params_destroy(self.params);
        _ = lexbor_mraw_destroy(self.mraw, true);
    }

    /// Append a key-value pair (allows duplicates)
    pub fn append(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
        const entry = lxb_url_search_params_append(
            self.params,
            name.ptr,
            name.len,
            value.ptr,
            value.len,
        );
        if (entry == null) return z.Err.OutOfMemory;
    }

    /// Delete all entries with given name
    pub fn delete(self: *URLSearchParams, name: []const u8) void {
        lxb_url_search_params_delete(self.params, name.ptr, name.len, null, 0);
    }

    /// Get first value for given name
    pub fn get(self: *URLSearchParams, name: []const u8) ?[]const u8 {
        const str = lxb_url_search_params_get(self.params, name.ptr, name.len) orelse return null;
        return if (str.length > 0) str.data[0..str.length] else "";
    }

    /// Check if parameter exists
    pub fn has(self: *URLSearchParams, name: []const u8) bool {
        return lxb_url_search_params_has(self.params, name.ptr, name.len, null, 0);
    }

    /// Set parameter (replaces all existing with same name)
    pub fn set(self: *URLSearchParams, name: []const u8, value: []const u8) !void {
        const entry = lxb_url_search_params_set(
            self.params,
            name.ptr,
            name.len,
            value.ptr,
            value.len,
        );
        if (entry == null) return z.Err.OutOfMemory;
    }

    /// Sort parameters by name
    pub fn sort(self: *URLSearchParams) void {
        lxb_url_search_params_sort(self.params);
    }

    /// Serialize to query string (allocates)
    pub fn toString(self: *URLSearchParams, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(allocator);

        var ctx = SerializeContext{
            .allocator = allocator,
            .list = &list,
        };

        const status = lxb_url_search_params_serialize(
            self.params,
            serializeCallback,
            &ctx,
        );

        if (status != z.LXB_STATUS_OK) return z.Err.SerializationFailed;
        return list.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Internal helpers
// ============================================================================

const SerializeContext = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),
};

fn serializeCallback(data: [*c]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) z.lxb_status_t {
    const context: *SerializeContext = @ptrCast(@alignCast(ctx.?));
    context.list.appendSlice(context.allocator, data[0..len]) catch return z.LXB_STATUS_ERROR_MEMORY_ALLOCATION;
    return z.LXB_STATUS_OK;
}

// ============================================================================
// Tests
// ============================================================================

test "URL parser creation and destruction" {
    var parser = try URLParser.create();
    defer parser.destroy();
}

test "URL parse basic" {
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("https://example.com/path?query=value#fragment");
    defer url.destroy();

    try testing.expectEqualStrings("https", url.scheme());
    try testing.expectEqualStrings("/path", url.pathname());
    try testing.expectEqualStrings("query=value", url.search());
    try testing.expectEqualStrings("fragment", url.hash());
}

test "URL parse with credentials" {
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("https://user:pass@example.com:8080/path");
    defer url.destroy();

    try testing.expectEqualStrings("https", url.scheme());
    try testing.expectEqualStrings("user", url.username());
    try testing.expectEqualStrings("pass", url.password());
    try testing.expect(url.hasPort());
    try testing.expectEqual(@as(u16, 8080), url.port());
    try testing.expectEqualStrings("/path", url.pathname());
}

test "URL parse relative" {
    var parser = try URLParser.create();
    defer parser.destroy();

    var base = try parser.parse("https://example.com/base/path");
    defer base.destroy();

    var relative = try parser.parseRelative("../other", &base);
    defer relative.destroy();

    try testing.expectEqualStrings("https", relative.scheme());
    try testing.expectEqualStrings("/other", relative.pathname());
}

test "URL setters" {
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("https://example.com/path");
    defer url.destroy();

    try url.setProtocol("http");
    try testing.expectEqualStrings("http", url.scheme());

    try url.setHostname("newhost.com");
    try url.setPort("9000");
    try testing.expect(url.hasPort());
    try testing.expectEqual(@as(u16, 9000), url.port());

    try url.setPathname("/newpath");
    try testing.expectEqualStrings("/newpath", url.pathname());

    try url.setSearch("foo=bar");
    try testing.expectEqualStrings("foo=bar", url.search());

    try url.setHash("section");
    try testing.expectEqualStrings("section", url.hash());
}

test "URL toString" {
    const allocator = testing.allocator;
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("https://user:pass@example.com:8080/path?query=value#fragment");
    defer url.destroy();

    const str = try url.toString(allocator);
    defer allocator.free(str);

    try testing.expectEqualStrings("https://user:pass@example.com:8080/path?query=value#fragment", str);
}

test "URL toString without fragment" {
    const allocator = testing.allocator;
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("https://example.com/path?query=value#fragment");
    defer url.destroy();

    const str = try url.toStringWithoutFragment(allocator);
    defer allocator.free(str);

    try testing.expectEqualStrings("https://example.com/path?query=value", str);
}

test "URLSearchParams basic operations" {
    const allocator = testing.allocator;

    var params = try URLSearchParams.init(allocator, "foo=bar&baz=qux");
    defer params.deinit();

    try testing.expect(params.has("foo"));
    try testing.expect(params.has("baz"));
    try testing.expect(!params.has("nothere"));

    const foo_val = params.get("foo");
    try testing.expect(foo_val != null);
    try testing.expectEqualStrings("bar", foo_val.?);
}

test "URLSearchParams append and set" {
    const allocator = testing.allocator;

    var params = try URLSearchParams.initEmpty(allocator);
    defer params.deinit();

    try params.append("key", "value1");
    try params.append("key", "value2");
    try params.append("other", "thing");

    try testing.expect(params.has("key"));
    try testing.expect(params.has("other"));

    // get returns first value
    const val = params.get("key");
    try testing.expect(val != null);
    try testing.expectEqualStrings("value1", val.?);

    // set replaces all
    try params.set("key", "single");
    const new_val = params.get("key");
    try testing.expectEqualStrings("single", new_val.?);
}

test "URLSearchParams delete" {
    const allocator = testing.allocator;

    var params = try URLSearchParams.init(allocator, "foo=bar&baz=qux&foo=duplicate");
    defer params.deinit();

    try testing.expect(params.has("foo"));
    params.delete("foo");
    try testing.expect(!params.has("foo"));
    try testing.expect(params.has("baz"));
}

test "URLSearchParams sort" {
    const allocator = testing.allocator;

    var params = try URLSearchParams.init(allocator, "z=last&a=first&m=middle");
    defer params.deinit();

    params.sort();

    const str = try params.toString(allocator);
    defer allocator.free(str);

    try testing.expectEqualStrings("a=first&m=middle&z=last", str);
}

test "URLSearchParams toString" {
    const allocator = testing.allocator;

    var params = try URLSearchParams.initEmpty(allocator);
    defer params.deinit();

    try params.append("foo", "bar");
    try params.append("baz", "qux");

    const str = try params.toString(allocator);
    defer allocator.free(str);

    try testing.expectEqualStrings("foo=bar&baz=qux", str);
}

test "URL with special characters" {
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("https://example.com/path%20with%20spaces?query=hello%20world");
    defer url.destroy();

    try testing.expectEqualStrings("https", url.scheme());
    try testing.expectEqualStrings("/path%20with%20spaces", url.pathname());
    try testing.expectEqualStrings("query=hello%20world", url.search());
}

test "URL IPv4 address" {
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("http://192.168.1.1:8080/path");
    defer url.destroy();

    try testing.expectEqualStrings("http", url.scheme());
    try testing.expectEqual(@as(u16, 8080), url.port());
    try testing.expectEqualStrings("/path", url.pathname());
}

test "URL file protocol" {
    var parser = try URLParser.create();
    defer parser.destroy();

    var url = try parser.parse("file:///home/user/document.txt");
    defer url.destroy();

    try testing.expectEqualStrings("file", url.scheme());
    try testing.expectEqualStrings("/home/user/document.txt", url.pathname());
}

test "URLSearchParams with special characters" {
    const allocator = testing.allocator;

    var params = try URLSearchParams.init(allocator, "name=John+Doe&email=test%40example.com");
    defer params.deinit();

    try testing.expect(params.has("name"));
    try testing.expect(params.has("email"));
}

test "URL parser reuse" {
    var parser = try URLParser.create();
    defer parser.destroy();

    {
        var url1 = try parser.parse("https://example.com/path1");
        defer url1.destroy();
        try testing.expectEqualStrings("/path1", url1.pathname());
    }

    parser.clean();

    {
        var url2 = try parser.parse("https://example.com/path2");
        defer url2.destroy();
        try testing.expectEqualStrings("/path2", url2.pathname());
    }
}

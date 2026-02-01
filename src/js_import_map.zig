//! Import Map implementation for secure module resolution
//!
//! Supports:
//! - Bare specifier mapping (e.g., "lodash" -> "https://cdn.jsdelivr.net/npm/lodash-es/+esm")
//! - Subresource Integrity (SRI) hash verification
//! - Optional/empty config (no import map = pass-through)
//!
//! Config format (JSON):
//! {
//!   "imports": {
//!     "es-toolkit": "https://cdn.jsdelivr.net/npm/es-toolkit@1.44.0/+esm",
//!     "lodash": "https://cdn.jsdelivr.net/npm/lodash-es@4.17.21/+esm"
//!   },
//!   "integrity": {
//!     "https://cdn.jsdelivr.net/npm/es-toolkit@1.44.0/+esm": "sha384-abc123..."
//!   }
//! }

const std = @import("std");

pub const ImportMap = struct {
    allocator: std.mem.Allocator,
    /// Maps bare specifiers to URLs
    imports: std.StringHashMap([]const u8),
    /// Maps URLs to expected SRI hashes (sha384-<base64>)
    integrity: std.StringHashMap([]const u8),

    /// Initialize an empty ImportMap (pass-through mode)
    pub fn empty(allocator: std.mem.Allocator) ImportMap {
        return .{
            .allocator = allocator,
            .imports = std.StringHashMap([]const u8).init(allocator),
            .integrity = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Initialize from embedded JSON config
    /// Returns empty ImportMap if json is null or empty
    pub fn fromJson(allocator: std.mem.Allocator, json: ?[]const u8) !ImportMap {
        var self = empty(allocator);
        errdefer self.deinit();

        const config = json orelse return self;
        if (config.len == 0) return self;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, config, .{}) catch |err| {
            std.debug.print("[ImportMap] JSON parse error: {}\n", .{err});
            return self; // Return empty on parse error
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return self;

        // Parse "imports" section
        if (root.object.get("imports")) |imports_val| {
            if (imports_val == .object) {
                var it = imports_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        const val = try allocator.dupe(u8, entry.value_ptr.string);
                        try self.imports.put(key, val);
                    }
                }
            }
        }

        // Parse "integrity" section
        if (root.object.get("integrity")) |integrity_val| {
            if (integrity_val == .object) {
                var it = integrity_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        const val = try allocator.dupe(u8, entry.value_ptr.string);
                        try self.integrity.put(key, val);
                    }
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *ImportMap) void {
        // Free all keys and values in imports
        var imports_it = self.imports.iterator();
        while (imports_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.imports.deinit();

        // Free all keys and values in integrity
        var integrity_it = self.integrity.iterator();
        while (integrity_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.integrity.deinit();
    }

    /// Resolve a module specifier. Returns null if not mapped (use original).
    pub fn resolve(self: *const ImportMap, specifier: []const u8) ?[]const u8 {
        return self.imports.get(specifier);
    }

    /// Check if a URL has an integrity requirement
    pub fn getIntegrity(self: *const ImportMap, url: []const u8) ?[]const u8 {
        return self.integrity.get(url);
    }

    /// Verify content against SRI hash
    /// Returns true if no integrity requirement OR hash matches
    pub fn verifyIntegrity(self: *const ImportMap, url: []const u8, content: []const u8) bool {
        const expected = self.getIntegrity(url) orelse return true; // No requirement = pass

        // Parse SRI format: "sha384-<base64>"
        if (std.mem.startsWith(u8, expected, "sha384-")) {
            const expected_b64 = expected[7..];
            return verifySha384(content, expected_b64);
        } else if (std.mem.startsWith(u8, expected, "sha256-")) {
            const expected_b64 = expected[7..];
            return verifySha256(content, expected_b64);
        } else if (std.mem.startsWith(u8, expected, "sha512-")) {
            const expected_b64 = expected[7..];
            return verifySha512(content, expected_b64);
        }

        return false; // Unknown algorithm = fail
    }

    /// Check if the import map is empty (pass-through mode)
    pub fn isEmpty(self: *const ImportMap) bool {
        return self.imports.count() == 0;
    }
};

// =============================================================================
// SRI Hash Verification
// =============================================================================

fn verifySha256(data: []const u8, expected_b64: []const u8) bool {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return compareBase64(&hash, expected_b64);
}

fn verifySha384(data: []const u8, expected_b64: []const u8) bool {
    var hash: [48]u8 = undefined;
    std.crypto.hash.sha2.Sha384.hash(data, &hash, .{});
    return compareBase64(&hash, expected_b64);
}

fn verifySha512(data: []const u8, expected_b64: []const u8) bool {
    var hash: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(data, &hash, .{});
    return compareBase64(&hash, expected_b64);
}

fn compareBase64(hash: []const u8, expected_b64: []const u8) bool {
    // Encode hash to base64 and compare
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(hash.len);

    if (expected_b64.len != encoded_len) return false;

    var encoded_buf: [128]u8 = undefined; // Max for sha512
    if (encoded_len > encoded_buf.len) return false;

    const encoded = encoder.encode(encoded_buf[0..encoded_len], hash);
    return std.mem.eql(u8, encoded, expected_b64);
}

// =============================================================================
// Utility: Generate hash for a URL (for building config)
// =============================================================================

/// Compute SHA-384 hash of content and return as SRI string
/// Caller owns returned memory
pub fn computeSRI(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var hash: [48]u8 = undefined;
    std.crypto.hash.sha2.Sha384.hash(content, &hash, .{});

    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(48);
    const prefix = "sha384-";

    const result = try allocator.alloc(u8, prefix.len + b64_len);
    @memcpy(result[0..prefix.len], prefix);
    _ = encoder.encode(result[prefix.len..], &hash);

    return result;
}

//! Lexbor Encoding Module - Text encoding/decoding utilities
//!
//! Provides Zig wrappers around lexbor's encoding API for:
//! - UTF-8 encoding/decoding
//! - Multi-encoding support (ISO-8859-*, Shift-JIS, etc.)
//!
//! This module uses opaque pointers with C shim wrappers from minimal.c
//! to avoid mirroring lexbor's internal struct layouts.

const std = @import("std");

// ============================================================================
// Lexbor C Types
// ============================================================================

pub const lxb_char_t = u8;
pub const lxb_codepoint_t = u32;
pub const lxb_status_t = c_uint;

pub const LXB_STATUS_OK: lxb_status_t = 0x0000;
pub const LXB_ENCODING_DECODE_ERROR: lxb_codepoint_t = 0x1FFFFF;
pub const LXB_ENCODING_DECODE_CONTINUE: lxb_codepoint_t = 0x2FFFFF;
pub const LXB_ENCODING_REPLACEMENT_CODEPOINT: lxb_codepoint_t = 0xFFFD;

/// Lexbor encoding types
pub const Encoding = enum(c_int) {
    DEFAULT = 0x00,
    AUTO = 0x01,
    UNDEFINED = 0x02,
    BIG5 = 0x03,
    EUC_JP = 0x04,
    EUC_KR = 0x05,
    GBK = 0x06,
    IBM866 = 0x07,
    ISO_2022_JP = 0x08,
    ISO_8859_10 = 0x09,
    ISO_8859_13 = 0x0a,
    ISO_8859_14 = 0x0b,
    ISO_8859_15 = 0x0c,
    ISO_8859_16 = 0x0d,
    ISO_8859_2 = 0x0e,
    ISO_8859_3 = 0x0f,
    ISO_8859_4 = 0x10,
    ISO_8859_5 = 0x11,
    ISO_8859_6 = 0x12,
    ISO_8859_7 = 0x13,
    ISO_8859_8 = 0x14,
    ISO_8859_8_I = 0x15,
    KOI8_R = 0x16,
    KOI8_U = 0x17,
    SHIFT_JIS = 0x18,
    UTF_16BE = 0x19,
    UTF_16LE = 0x1a,
    UTF_8 = 0x1b,
    GB18030 = 0x1c,
    MACINTOSH = 0x1d,
    REPLACEMENT = 0x1e,
    WINDOWS_1250 = 0x1f,
    WINDOWS_1251 = 0x20,
    WINDOWS_1252 = 0x21,
    WINDOWS_1253 = 0x22,
    WINDOWS_1254 = 0x23,
    WINDOWS_1255 = 0x24,
    WINDOWS_1256 = 0x25,
    WINDOWS_1257 = 0x26,
    WINDOWS_1258 = 0x27,
    WINDOWS_874 = 0x28,
    X_MAC_CYRILLIC = 0x29,
    X_USER_DEFINED = 0x2a,
    LAST_ENTRY = 0x2b,
};

/// Opaque encoding data structure from lexbor
pub const EncodingData = opaque {};

/// Opaque decode context - allocated and managed via C shim wrappers
pub const DecodeContext = opaque {};

/// Opaque encode context - allocated and managed via C shim wrappers
pub const EncodeContext = opaque {};

// ============================================================================
// Lexbor C Function Declarations
// ============================================================================

extern "c" fn lxb_encoding_data_noi(encoding: Encoding) ?*const EncodingData;
extern "c" fn lxb_encoding_data_by_pre_name(name: [*]const lxb_char_t, length: usize) ?*const EncodingData;
extern "c" fn lxb_encoding_decode_utf_8_single(decode: *DecodeContext, data: *[*]const lxb_char_t, end: [*]const lxb_char_t) lxb_codepoint_t;

// C shim wrappers from minimal.c - handle opaque struct allocation
extern "c" fn lexbor_encoding_decode_create(encoding_data: ?*const EncodingData) ?*DecodeContext;
extern "c" fn lexbor_encoding_decode_destroy(decode: ?*DecodeContext) void;
extern "c" fn lexbor_encoding_encode_create(encoding_data: ?*const EncodingData) ?*EncodeContext;
extern "c" fn lexbor_encoding_encode_destroy(encode: ?*EncodeContext) void;

// ============================================================================
// High-Level Zig API
// ============================================================================

/// Get encoding data by encoding enum
pub fn getEncodingData(encoding: Encoding) ?*const EncodingData {
    return lxb_encoding_data_noi(encoding);
}

/// Get encoding data by name (normalizes whitespace)
/// Supports names like "utf-8", "UTF-8", "  utf-8  ", "iso-8859-1", etc.
pub fn getEncodingDataByName(name: []const u8) ?*const EncodingData {
    return lxb_encoding_data_by_pre_name(name.ptr, name.len);
}

/// Create a decode context for the given encoding
/// Returns null on allocation or initialization failure
/// Caller must call destroyDecodeContext when done
pub fn createDecodeContext(encoding_data: ?*const EncodingData) ?*DecodeContext {
    return lexbor_encoding_decode_create(encoding_data);
}

/// Free a decode context
pub fn destroyDecodeContext(ctx: ?*DecodeContext) void {
    lexbor_encoding_decode_destroy(ctx);
}

/// Create an encode context for the given encoding
/// Returns null on allocation or initialization failure
/// Caller must call destroyEncodeContext when done
pub fn createEncodeContext(encoding_data: ?*const EncodingData) ?*EncodeContext {
    return lexbor_encoding_encode_create(encoding_data);
}

/// Free an encode context
pub fn destroyEncodeContext(ctx: ?*EncodeContext) void {
    lexbor_encoding_encode_destroy(ctx);
}

/// Decode a single UTF-8 codepoint
/// Returns the codepoint, or LXB_ENCODING_DECODE_CONTINUE/LXB_ENCODING_DECODE_ERROR
pub fn decodeUtf8Single(ctx: *DecodeContext, data: *[*]const u8, end: [*]const u8) lxb_codepoint_t {
    return lxb_encoding_decode_utf_8_single(ctx, data, end);
}

// ============================================================================
// TextDecoder Helper
// ============================================================================

pub const DecodeError = error{
    InvalidEncoding,
    DecodingFailed,
    OutOfMemory,
};

/// Decode bytes to UTF-8 string using lexbor
/// Caller owns the returned slice
pub fn decodeToUtf8(
    allocator: std.mem.Allocator,
    data: []const u8,
    encoding_data: ?*const EncodingData,
    fatal: bool,
) DecodeError![]u8 {
    if (data.len == 0) return allocator.dupe(u8, "") catch return DecodeError.OutOfMemory;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const decode_ctx = createDecodeContext(encoding_data) orelse return DecodeError.OutOfMemory;
    defer destroyDecodeContext(decode_ctx);

    var ptr: [*]const u8 = data.ptr;
    const end: [*]const u8 = data.ptr + data.len;

    while (@intFromPtr(ptr) < @intFromPtr(end)) {
        const cp = decodeUtf8Single(decode_ctx, &ptr, end);

        if (cp == LXB_ENCODING_DECODE_CONTINUE) continue;

        if (cp == LXB_ENCODING_DECODE_ERROR) {
            if (fatal) return DecodeError.DecodingFailed;
            // Use replacement character U+FFFD
            output.appendSlice(allocator, "\xEF\xBF\xBD") catch return DecodeError.OutOfMemory;
            continue;
        }

        // Encode codepoint to UTF-8
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &utf8_buf) catch {
            if (fatal) return DecodeError.DecodingFailed;
            output.appendSlice(allocator, "\xEF\xBF\xBD") catch return DecodeError.OutOfMemory;
            continue;
        };
        output.appendSlice(allocator, utf8_buf[0..len]) catch return DecodeError.OutOfMemory;
    }

    return output.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
}

// ============================================================================
// Tests
// ============================================================================

test "getEncodingData UTF-8" {
    const data = getEncodingData(.UTF_8);
    try std.testing.expect(data != null);
}

test "getEncodingDataByName" {
    const data1 = getEncodingDataByName("utf-8");
    try std.testing.expect(data1 != null);

    const data2 = getEncodingDataByName("UTF-8");
    try std.testing.expect(data2 != null);

    const data3 = getEncodingDataByName("  utf-8  ");
    try std.testing.expect(data3 != null);
}

test "decodeToUtf8 basic" {
    const allocator = std.testing.allocator;
    const encoding_data = getEncodingData(.UTF_8);

    const result = try decodeToUtf8(allocator, "Hello", encoding_data, false);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeToUtf8 empty" {
    const allocator = std.testing.allocator;
    const encoding_data = getEncodingData(.UTF_8);

    const result = try decodeToUtf8(allocator, "", encoding_data, false);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

//! Image magic-byte verification for data: URIs
//!
//! Used by the HTML sanitizer to confirm that a `data:image/<type>;base64,<data>`
//! URI actually contains bytes that match the claimed MIME type.
//!
//! Strategy:
//!   - Reject non-base64 image data URIs outright (PNG/JPEG/WebP/GIF are binary;
//!     embedding them without base64 is never legitimate and signals an attack or
//!     malformed content).
//!   - For base64 URIs, decode only the first ~96 bytes (128 base64 chars) —
//!     enough to read the file header — using a fixed stack buffer. No allocation.
//!   - Check decoded bytes against known magic numbers for the claimed MIME type.
//!   - Unknown image subtypes (avif, bmp, ico, …) pass through: we only block
//!     content that provably does not match its label.

const std = @import("std");

/// Check that `header` bytes match the magic signature for `mime`.
/// `header` is the first decoded bytes of the data URI content (at least 2 bytes).
/// Returns true if the format is unknown (pass-through) or magic matches.
/// Returns false if magic clearly does not match the claimed type.
pub fn verifyImageMagic(mime: []const u8, header: []const u8) bool {
    const eql = std.ascii.eqlIgnoreCase;

    if (eql(mime, "image/png")) {
        // PNG: 8-byte magic  \x89 P N G \r \n \x1a \n
        return header.len >= 8 and
            std.mem.startsWith(u8, header, "\x89PNG\r\n\x1a\n");
    }

    if (eql(mime, "image/jpeg") or eql(mime, "image/jpg")) {
        // JPEG: SOI marker  FF D8
        return header.len >= 2 and
            header[0] == 0xFF and header[1] == 0xD8;
    }

    if (eql(mime, "image/webp")) {
        // WebP: RIFF....WEBP  (bytes 0-3 = "RIFF", bytes 8-11 = "WEBP")
        return header.len >= 12 and
            std.mem.startsWith(u8, header, "RIFF") and
            std.mem.eql(u8, header[8..12], "WEBP");
    }

    if (eql(mime, "image/gif")) {
        // GIF: GIF87a or GIF89a
        return header.len >= 6 and
            (std.mem.startsWith(u8, header, "GIF87a") or
            std.mem.startsWith(u8, header, "GIF89a"));
    }

    // image/avif, image/bmp, image/ico, image/tiff, etc. — no checker, allow through.
    return true;
}

/// Validate a `data:image/...` URI:
///   1. Require `;base64,` — binary image formats are never plain-text data URIs.
///   2. Decode the first 96 bytes from the base64 payload using a stack buffer.
///   3. Verify magic numbers match the claimed MIME type.
///
/// `data_uri` must already start with `data:image/` and must not be `data:image/svg`.
/// Returns false on any malformed input or magic mismatch.
pub fn checkDataUri(data_uri: []const u8) bool {
    // Locate the comma that separates metadata from content.
    const comma_pos = std.mem.indexOfScalar(u8, data_uri, ',') orelse return false;
    const meta = data_uri[0..comma_pos]; // e.g. "data:image/png;base64"
    const content = data_uri[comma_pos + 1 ..]; // the base64 (or plain-text) payload

    // Extract MIME type: between "data:" (5 chars) and ";" or end-of-meta.
    const mime_start = 5;
    if (meta.len <= mime_start) return false;
    const semi_pos = std.mem.indexOfScalar(u8, meta, ';');
    const mime_end = semi_pos orelse meta.len;
    if (mime_end <= mime_start) return false;
    const mime = meta[mime_start..mime_end];

    // Require ;base64 — binary formats are never legitimately plain-text in a data URI.
    // This also serves as an early-exit DoS defence: a huge plain-text payload
    // (data:image/png,<megabytes>) is rejected immediately without touching the content.
    const has_base64 = if (semi_pos) |sp|
        std.ascii.eqlIgnoreCase(meta[sp + 1 ..], "base64")
    else
        false;
    if (!has_base64) return false;

    // Decode the first block of base64 into a stack buffer.
    // 128 base64 chars → at most 96 decoded bytes (≥ all magic numbers we check).
    const take = @min(content.len, 128);
    const aligned = take & ~@as(usize, 3); // round down to multiple of 4
    if (aligned == 0) return false;

    const decoder = std.base64.standard.Decoder;
    var header_buf: [96]u8 = undefined;

    const decoded_len = decoder.calcSizeForSlice(content[0..aligned]) catch return false;
    if (decoded_len > header_buf.len) return false; // safety — should not happen
    decoder.decode(header_buf[0..decoded_len], content[0..aligned]) catch return false;

    return verifyImageMagic(mime, header_buf[0..decoded_len]);
}

// =============================================================================
// Tests
// =============================================================================

test "verifyImageMagic - PNG" {
    const png_magic = "\x89PNG\r\n\x1a\n" ++ "padding_bytes";
    try std.testing.expect(verifyImageMagic("image/png", png_magic));
    try std.testing.expect(verifyImageMagic("image/PNG", png_magic)); // case-insensitive
    try std.testing.expect(!verifyImageMagic("image/png", "\xFF\xD8\xFF")); // JPEG bytes ≠ PNG
    try std.testing.expect(!verifyImageMagic("image/png", "GIF89aXX")); // GIF bytes ≠ PNG
    try std.testing.expect(!verifyImageMagic("image/png", "\x89PNX")); // truncated / wrong
}

test "verifyImageMagic - JPEG" {
    const jpeg_magic = "\xFF\xD8\xFF\xE0some_exif_data";
    try std.testing.expect(verifyImageMagic("image/jpeg", jpeg_magic));
    try std.testing.expect(verifyImageMagic("image/jpg", jpeg_magic));
    try std.testing.expect(!verifyImageMagic("image/jpeg", "\x89PNG\r\n\x1a\n")); // PNG ≠ JPEG
    try std.testing.expect(!verifyImageMagic("image/jpeg", "\xFF")); // too short
}

test "verifyImageMagic - WebP" {
    const webp_magic = "RIFF\x00\x00\x00\x00WEBP";
    try std.testing.expect(verifyImageMagic("image/webp", webp_magic));
    try std.testing.expect(!verifyImageMagic("image/webp", "RIFF\x00\x00\x00\x00JPEG")); // wrong fourcc
    try std.testing.expect(!verifyImageMagic("image/webp", "RIFF\x00\x00")); // too short
}

test "verifyImageMagic - GIF" {
    try std.testing.expect(verifyImageMagic("image/gif", "GIF89aXXX"));
    try std.testing.expect(verifyImageMagic("image/gif", "GIF87aXXX"));
    try std.testing.expect(!verifyImageMagic("image/gif", "GIF90aXXX")); // unknown version
    try std.testing.expect(!verifyImageMagic("image/gif", "GIF8")); // too short
}

test "verifyImageMagic - unknown types pass through" {
    try std.testing.expect(verifyImageMagic("image/avif", "anything"));
    try std.testing.expect(verifyImageMagic("image/bmp", "anything"));
    try std.testing.expect(verifyImageMagic("image/tiff", "garbage"));
}

test "checkDataUri - rejects non-base64 image URIs" {
    // Binary formats without ;base64 are never legitimate
    try std.testing.expect(!checkDataUri("data:image/png,rawbinarydata"));
    try std.testing.expect(!checkDataUri("data:image/jpeg,rawbinarydata"));
    try std.testing.expect(!checkDataUri("data:image/gif,abc"));
    try std.testing.expect(!checkDataUri("data:image/png")); // no comma
}

test "checkDataUri - rejects mislabeled base64 content" {
    // base64("hello world") starts with "aGVs..." — clearly not PNG/JPEG magic
    try std.testing.expect(!checkDataUri("data:image/png;base64,aGVsbG8gd29ybGQ="));
    try std.testing.expect(!checkDataUri("data:image/jpeg;base64,aGVsbG8gd29ybGQ="));
}

test "checkDataUri - accepts valid PNG base64 header" {
    // iVBORw0K... is the canonical base64 prefix of any PNG (\x89PNG\r\n\x1a\n)
    // Using the 1x1 pixel PNG from test_image1.js
    const tiny_png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
    try std.testing.expect(checkDataUri(tiny_png));
}

test "checkDataUri - accepts valid JPEG base64 header" {
    // /9j/ is the canonical base64 prefix of JPEG (FF D8 FF)
    const jpeg_prefix = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/";
    try std.testing.expect(checkDataUri(jpeg_prefix));
}

test "checkDataUri - accepts valid GIF base64 header" {
    // R0lGOD is the canonical base64 prefix of GIF89a
    const gif_prefix = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
    try std.testing.expect(checkDataUri(gif_prefix));
}

test "checkDataUri - unknown subtypes pass through" {
    // image/avif — no magic checker, we allow rather than over-block
    try std.testing.expect(checkDataUri("data:image/avif;base64,AAAAFGZ0eXBhdmlm"));
}

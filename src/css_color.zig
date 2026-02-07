const std = @import("std");

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };

pub fn parse(input: []const u8) Color {
    const s = std.mem.trim(u8, input, " ");

    // Hex (#RGB or #RRGGBB)
    if (std.mem.startsWith(u8, s, "#")) {
        return parseHex(s[1..]);
    }

    // RGB / RGBA
    if (std.mem.startsWith(u8, s, "rgb")) {
        return parseRgb(s);
    }

    // Named Colors (MVP)
    if (std.mem.eql(u8, s, "red")) return .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    if (std.mem.eql(u8, s, "green")) return .{ .r = 0, .g = 128, .b = 0, .a = 255 };
    if (std.mem.eql(u8, s, "blue")) return .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    if (std.mem.eql(u8, s, "black")) return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (std.mem.eql(u8, s, "white")) return .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    // Default to black on error (Standard Canvas behavior)
    return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}

fn parseHex(hex: []const u8) Color {
    if (hex.len == 3) {
        // #RGB -> #RRGGBB
        const r = std.fmt.parseInt(u8, hex[0..1], 16) catch 0;
        const g = std.fmt.parseInt(u8, hex[1..2], 16) catch 0;
        const b = std.fmt.parseInt(u8, hex[2..3], 16) catch 0;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 255 };
    }
    if (hex.len == 6) {
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch 0;
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch 0;
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch 0;
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}

fn parseRgb(s: []const u8) Color {
    // Format: rgb(1, 2, 3) or rgba(1, 2, 3, 0.5)
    const open = std.mem.indexOf(u8, s, "(") orelse return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const close = std.mem.lastIndexOf(u8, s, ")") orelse s.len;

    const content = s[open + 1 .. close];
    var it = std.mem.splitScalar(u8, content, ',');

    const r = parseInt(it.next());
    const g = parseInt(it.next());
    const b = parseInt(it.next());
    // Alpha ignored for MVP rgb()

    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn parseInt(s_opt: ?[]const u8) u8 {
    const s = std.mem.trim(u8, s_opt orelse return 0, " ");
    return std.fmt.parseInt(u8, s, 10) catch 0;
}

const std = @import("std");

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
pub const NamedColor = struct { name: []const u8, color: Color };

pub const NamedColors = std.StaticStringMap(Color).initComptime(.{
    .{ "transparent", Color{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    .{ "aliceblue", Color{ .r = 240, .g = 248, .b = 255, .a = 255 } },
    .{ "antiquewhite", Color{ .r = 250, .g = 235, .b = 215, .a = 255 } },
    .{ "aqua", Color{ .r = 0, .g = 255, .b = 255, .a = 255 } },
    .{ "aquamarine", Color{ .r = 127, .g = 255, .b = 212, .a = 255 } },
    .{ "azure", Color{ .r = 240, .g = 255, .b = 255, .a = 255 } },
    .{ "beige", Color{ .r = 245, .g = 245, .b = 220, .a = 255 } },
    .{ "bisque", Color{ .r = 255, .g = 228, .b = 196, .a = 255 } },
    .{ "black", Color{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    .{ "blanchedalmond", Color{ .r = 255, .g = 235, .b = 205, .a = 255 } },
    .{ "blue", Color{ .r = 0, .g = 0, .b = 255, .a = 255 } },
    .{ "blueviolet", Color{ .r = 138, .g = 43, .b = 226, .a = 255 } },
    .{ "brown", Color{ .r = 165, .g = 42, .b = 42, .a = 255 } },
    .{ "burlywood", Color{ .r = 222, .g = 184, .b = 135, .a = 255 } },
    .{ "cadetblue", Color{ .r = 95, .g = 158, .b = 160, .a = 255 } },
    .{ "chartreuse", Color{ .r = 127, .g = 255, .b = 0, .a = 255 } },
    .{ "chocolate", Color{ .r = 210, .g = 105, .b = 30, .a = 255 } },
    .{ "coral", Color{ .r = 255, .g = 127, .b = 80, .a = 255 } },
    .{ "cornflowerblue", Color{ .r = 100, .g = 149, .b = 237, .a = 255 } },
    .{ "cornsilk", Color{ .r = 255, .g = 248, .b = 220, .a = 255 } },
    .{ "crimson", Color{ .r = 220, .g = 20, .b = 60, .a = 255 } },
    .{ "cyan", Color{ .r = 0, .g = 255, .b = 255, .a = 255 } },
    .{ "darkblue", Color{ .r = 0, .g = 0, .b = 139, .a = 255 } },
    .{ "darkcyan", Color{ .r = 0, .g = 139, .b = 139, .a = 255 } },
    .{ "darkgoldenrod", Color{ .r = 184, .g = 134, .b = 11, .a = 255 } },
    .{ "darkgray", Color{ .r = 169, .g = 169, .b = 169, .a = 255 } },
    .{ "darkgreen", Color{ .r = 0, .g = 100, .b = 0, .a = 255 } },
    .{ "darkgrey", Color{ .r = 169, .g = 169, .b = 169, .a = 255 } },
    .{ "darkkhaki", Color{ .r = 189, .g = 183, .b = 107, .a = 255 } },
    .{ "darkmagenta", Color{ .r = 139, .g = 0, .b = 139, .a = 255 } },
    .{ "darkolivegreen", Color{ .r = 85, .g = 107, .b = 47, .a = 255 } },
    .{ "darkorange", Color{ .r = 255, .g = 140, .b = 0, .a = 255 } },
    .{ "darkorchid", Color{ .r = 153, .g = 50, .b = 204, .a = 255 } },
    .{ "darkred", Color{ .r = 139, .g = 0, .b = 0, .a = 255 } },
    .{ "darksalmon", Color{ .r = 233, .g = 150, .b = 122, .a = 255 } },
    .{ "darkseagreen", Color{ .r = 143, .g = 188, .b = 143, .a = 255 } },
    .{ "darkslateblue", Color{ .r = 72, .g = 61, .b = 139, .a = 255 } },
    .{ "darkslategray", Color{ .r = 47, .g = 79, .b = 79, .a = 255 } },
    .{ "darkslategrey", Color{ .r = 47, .g = 79, .b = 79, .a = 255 } },
    .{ "darkturquoise", Color{ .r = 0, .g = 206, .b = 209, .a = 255 } },
    .{ "darkviolet", Color{ .r = 148, .g = 0, .b = 211, .a = 255 } },
    .{ "deeppink", Color{ .r = 255, .g = 20, .b = 147, .a = 255 } },
    .{ "deepskyblue", Color{ .r = 0, .g = 191, .b = 255, .a = 255 } },
    .{ "dimgray", Color{ .r = 105, .g = 105, .b = 105, .a = 255 } },
    .{ "dimgrey", Color{ .r = 105, .g = 105, .b = 105, .a = 255 } },
    .{ "dodgerblue", Color{ .r = 30, .g = 144, .b = 255, .a = 255 } },
    .{ "firebrick", Color{ .r = 178, .g = 34, .b = 34, .a = 255 } },
    .{ "floralwhite", Color{ .r = 255, .g = 250, .b = 240, .a = 255 } },
    .{ "forestgreen", Color{ .r = 34, .g = 139, .b = 34, .a = 255 } },
    .{ "fuchsia", Color{ .r = 255, .g = 0, .b = 255, .a = 255 } },
    .{ "gainsboro", Color{ .r = 220, .g = 220, .b = 220, .a = 255 } },
    .{ "ghostwhite", Color{ .r = 248, .g = 248, .b = 255, .a = 255 } },
    .{ "gold", Color{ .r = 255, .g = 215, .b = 0, .a = 255 } },
    .{ "goldenrod", Color{ .r = 218, .g = 165, .b = 32, .a = 255 } },
    .{ "gray", Color{ .r = 128, .g = 128, .b = 128, .a = 255 } },
    .{ "green", Color{ .r = 0, .g = 128, .b = 0, .a = 255 } },
    .{ "greenyellow", Color{ .r = 173, .g = 255, .b = 47, .a = 255 } },
    .{ "grey", Color{ .r = 128, .g = 128, .b = 128, .a = 255 } },
    .{ "honeydew", Color{ .r = 240, .g = 255, .b = 240, .a = 255 } },
    .{ "hotpink", Color{ .r = 255, .g = 105, .b = 180, .a = 255 } },
    .{ "indianred", Color{ .r = 205, .g = 92, .b = 92, .a = 255 } },
    .{ "indigo", Color{ .r = 75, .g = 0, .b = 130, .a = 255 } },
    .{ "ivory", Color{ .r = 255, .g = 255, .b = 240, .a = 255 } },
    .{ "khaki", Color{ .r = 240, .g = 230, .b = 140, .a = 255 } },
    .{ "lavender", Color{ .r = 230, .g = 230, .b = 250, .a = 255 } },
    .{ "lavenderblush", Color{ .r = 255, .g = 240, .b = 245, .a = 255 } },
    .{ "lawngreen", Color{ .r = 124, .g = 252, .b = 0, .a = 255 } },
    .{ "lemonchiffon", Color{ .r = 255, .g = 250, .b = 205, .a = 255 } },
    .{ "lightblue", Color{ .r = 173, .g = 216, .b = 230, .a = 255 } },
    .{ "lightcoral", Color{ .r = 240, .g = 128, .b = 128, .a = 255 } },
    .{ "lightcyan", Color{ .r = 224, .g = 255, .b = 255, .a = 255 } },
    .{ "lightgoldenrodyellow", Color{ .r = 250, .g = 250, .b = 210, .a = 255 } },
    .{ "lightgray", Color{ .r = 211, .g = 211, .b = 211, .a = 255 } },
    .{ "lightgreen", Color{ .r = 144, .g = 238, .b = 144, .a = 255 } },
    .{ "lightgrey", Color{ .r = 211, .g = 211, .b = 211, .a = 255 } },
    .{ "lightpink", Color{ .r = 255, .g = 182, .b = 193, .a = 255 } },
    .{ "lightsalmon", Color{ .r = 255, .g = 160, .b = 122, .a = 255 } },
    .{ "lightseagreen", Color{ .r = 32, .g = 178, .b = 170, .a = 255 } },
    .{ "lightskyblue", Color{ .r = 135, .g = 206, .b = 250, .a = 255 } },
    .{ "lightslategray", Color{ .r = 119, .g = 136, .b = 153, .a = 255 } },
    .{ "lightslategrey", Color{ .r = 119, .g = 136, .b = 153, .a = 255 } },
    .{ "lightsteelblue", Color{ .r = 176, .g = 196, .b = 222, .a = 255 } },
    .{ "lightyellow", Color{ .r = 255, .g = 255, .b = 224, .a = 255 } },
    .{ "lime", Color{ .r = 0, .g = 255, .b = 0, .a = 255 } },
    .{ "limegreen", Color{ .r = 50, .g = 205, .b = 50, .a = 255 } },
    .{ "linen", Color{ .r = 250, .g = 240, .b = 230, .a = 255 } },
    .{ "magenta", Color{ .r = 255, .g = 0, .b = 255, .a = 255 } },
    .{ "maroon", Color{ .r = 128, .g = 0, .b = 0, .a = 255 } },
    .{ "mediumaquamarine", Color{ .r = 102, .g = 205, .b = 170, .a = 255 } },
    .{ "mediumblue", Color{ .r = 0, .g = 0, .b = 205, .a = 255 } },
    .{ "mediumorchid", Color{ .r = 186, .g = 85, .b = 211, .a = 255 } },
    .{ "mediumpurple", Color{ .r = 147, .g = 112, .b = 219, .a = 255 } },
    .{ "mediumseagreen", Color{ .r = 60, .g = 179, .b = 113, .a = 255 } },
    .{ "mediumslateblue", Color{ .r = 123, .g = 104, .b = 238, .a = 255 } },
    .{ "mediumspringgreen", Color{ .r = 0, .g = 250, .b = 154, .a = 255 } },
    .{ "mediumturquoise", Color{ .r = 72, .g = 209, .b = 204, .a = 255 } },
    .{ "mediumvioletred", Color{ .r = 199, .g = 21, .b = 133, .a = 255 } },
    .{ "midnightblue", Color{ .r = 25, .g = 25, .b = 112, .a = 255 } },
    .{ "mintcream", Color{ .r = 245, .g = 255, .b = 250, .a = 255 } },
    .{ "mistyrose", Color{ .r = 255, .g = 228, .b = 225, .a = 255 } },
    .{ "moccasin", Color{ .r = 255, .g = 228, .b = 181, .a = 255 } },
    .{ "navajowhite", Color{ .r = 255, .g = 222, .b = 173, .a = 255 } },
    .{ "navy", Color{ .r = 0, .g = 0, .b = 128, .a = 255 } },
    .{ "oldlace", Color{ .r = 253, .g = 245, .b = 230, .a = 255 } },
    .{ "olive", Color{ .r = 128, .g = 128, .b = 0, .a = 255 } },
    .{ "olivedrab", Color{ .r = 107, .g = 142, .b = 35, .a = 255 } },
    .{ "orange", Color{ .r = 255, .g = 165, .b = 0, .a = 255 } },
    .{ "orangered", Color{ .r = 255, .g = 69, .b = 0, .a = 255 } },
    .{ "orchid", Color{ .r = 218, .g = 112, .b = 214, .a = 255 } },
    .{ "palegoldenrod", Color{ .r = 238, .g = 232, .b = 170, .a = 255 } },
    .{ "palegreen", Color{ .r = 152, .g = 251, .b = 152, .a = 255 } },
    .{ "paleturquoise", Color{ .r = 175, .g = 238, .b = 238, .a = 255 } },
    .{ "palevioletred", Color{ .r = 219, .g = 112, .b = 147, .a = 255 } },
    .{ "papayawhip", Color{ .r = 255, .g = 239, .b = 213, .a = 255 } },
    .{ "peachpuff", Color{ .r = 255, .g = 218, .b = 185, .a = 255 } },
    .{ "peru", Color{ .r = 205, .g = 133, .b = 63, .a = 255 } },
    .{ "pink", Color{ .r = 255, .g = 192, .b = 203, .a = 255 } },
    .{ "plum", Color{ .r = 221, .g = 160, .b = 221, .a = 255 } },
    .{ "powderblue", Color{ .r = 176, .g = 224, .b = 230, .a = 255 } },
    .{ "purple", Color{ .r = 128, .g = 0, .b = 128, .a = 255 } },
    .{ "rebeccapurple", Color{ .r = 102, .g = 51, .b = 153, .a = 255 } },
    .{ "red", Color{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    .{ "rosybrown", Color{ .r = 188, .g = 143, .b = 143, .a = 255 } },
    .{ "royalblue", Color{ .r = 65, .g = 105, .b = 225, .a = 255 } },
    .{ "saddlebrown", Color{ .r = 139, .g = 69, .b = 19, .a = 255 } },
    .{ "salmon", Color{ .r = 250, .g = 128, .b = 114, .a = 255 } },
    .{ "sandybrown", Color{ .r = 244, .g = 164, .b = 96, .a = 255 } },
    .{ "seagreen", Color{ .r = 46, .g = 139, .b = 87, .a = 255 } },
    .{ "seashell", Color{ .r = 255, .g = 245, .b = 238, .a = 255 } },
    .{ "sienna", Color{ .r = 160, .g = 82, .b = 45, .a = 255 } },
    .{ "silver", Color{ .r = 192, .g = 192, .b = 192, .a = 255 } },
    .{ "skyblue", Color{ .r = 135, .g = 206, .b = 235, .a = 255 } },
    .{ "slateblue", Color{ .r = 106, .g = 90, .b = 205, .a = 255 } },
    .{ "slategray", Color{ .r = 112, .g = 128, .b = 144, .a = 255 } },
    .{ "slategrey", Color{ .r = 112, .g = 128, .b = 144, .a = 255 } },
    .{ "snow", Color{ .r = 255, .g = 250, .b = 250, .a = 255 } },
    .{ "springgreen", Color{ .r = 0, .g = 255, .b = 127, .a = 255 } },
    .{ "steelblue", Color{ .r = 70, .g = 130, .b = 180, .a = 255 } },
    .{ "tan", Color{ .r = 210, .g = 180, .b = 140, .a = 255 } },
    .{ "teal", Color{ .r = 0, .g = 128, .b = 128, .a = 255 } },
    .{ "thistle", Color{ .r = 216, .g = 191, .b = 216, .a = 255 } },
    .{ "tomato", Color{ .r = 255, .g = 99, .b = 71, .a = 255 } },
    .{ "turquoise", Color{ .r = 64, .g = 224, .b = 208, .a = 255 } },
    .{ "violet", Color{ .r = 238, .g = 130, .b = 238, .a = 255 } },
    .{ "wheat", Color{ .r = 245, .g = 222, .b = 179, .a = 255 } },
    .{ "white", Color{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    .{ "whitesmoke", Color{ .r = 245, .g = 245, .b = 245, .a = 255 } },
    .{ "yellow", Color{ .r = 255, .g = 255, .b = 0, .a = 255 } },
    .{ "yellowgreen", Color{ .r = 154, .g = 205, .b = 50, .a = 255 } },
});

pub fn parse(input: []const u8) Color {
    const s = std.mem.trim(u8, input, &std.ascii.whitespace);

    // Hex (#RGB or #RRGGBB)
    if (std.mem.startsWith(u8, s, "#")) {
        return parseHex(s[1..]);
    }

    // RGB / RGBA
    if (std.mem.startsWith(u8, s, "rgb")) {
        return parseRgb(s);
    }

    // Named colors — lowercase into a stack buffer for case-insensitive lookup.
    // Longest CSS color name is "lightgoldenrodyellow" (20 chars); 32 is plenty.
    if (s.len <= 32) {
        var buf: [32]u8 = undefined;
        const lc = std.ascii.lowerString(buf[0..s.len], s);
        if (NamedColors.get(lc)) |c| return c;
    }

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

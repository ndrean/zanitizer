const std = @import("std");

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
pub const NamedColor = struct { name: []const u8, color: Color };

const NamedColors = std.StaticStringMap(NamedColor).initComptime(.{
    .{ .name = "transparent", .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    .{ "aliceblue", .{ .r = 240, .g = 248, .b = 255, .a = 255 } },
    .{ "antiquewhite", .{ .r = 250, .g = 235, .b = 215, .a = 255 } },
    .{ "aqua", .{ .r = 0, .g = 255, .b = 255, .a = 255 } },
    .{ "aquamarine", .{ .r = 127, .g = 255, .b = 212, .a = 255 } },
    .{ "azure", .{ .r = 240, .g = 255, .b = 255, .a = 255 } },
    .{ "beige", .{ .r = 245, .g = 245, .b = 220, .a = 255 } },
    .{ "bisque", .{ .r = 255, .g = 228, .b = 196, .a = 255 } },
    .{ "black", .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
    .{ "blanchedalmond", .{ .r = 255, .g = 235, .b = 205, .a = 255 } },
    .{ "blue", .{ .r = 0, .g = 0, .b = 255, .a = 255 } },
    .{ "blueviolet", .{ .r = 138, .g = 43, .b = 226, .a = 255 } },
    .{ "brown", .{ .r = 165, .g = 42, .b = 42, .a = 255 } },
    .{ "burlywood", .{ .r = 222, .g = 184, .b = 135, .a = 255 } },
    .{ "cadetblue", .{ .r = 95, .g = 158, .b = 160, .a = 255 } },
    .{ "chartreuse", .{ .r = 127, .g = 255, .b = 0, .a = 255 } },
    .{ "chocolate", .{ .r = 210, .g = 105, .b = 30, .a = 255 } },
    .{ "coral", .{ .r = 255, .g = 127, .b = 80, .a = 255 } },
    .{ "cornflowerblue", .{ .r = 100, .g = 149, .b = 237, .a = 255 } },
    .{ "cornsilk", .{ .r = 255, .g = 248, .b = 220, .a = 255 } },
    .{ "crimson", .{ .r = 220, .g = 20, .b = 60, .a = 255 } },
    .{ "cyan", .{ .r = 0, .g = 255, .b = 255, .a = 255 } },
    .{ "darkblue", .{ .r = 0, .g = 0, .b = 139, .a = 255 } },
    .{ "darkcyan", .{ .r = 0, .g = 139, .b = 139, .a = 255 } },
    .{ "darkgoldenrod", .{ .r = 184, .g = 134, .b = 11, .a = 255 } },
    .{ "darkgray", .{ .r = 169, .g = 169, .b = 169, .a = 255 } },
    .{ "darkgreen", .{ .r = 0, .g = 100, .b = 0, .a = 255 } },
    .{ "darkgrey", .{ .r = 169, .g = 169, .b = 169, .a = 255 } },
    .{ "darkkhaki", .{ .r = 189, .g = 183, .b = 107, .a = 255 } },
    .{ "darkmagenta", .{ .r = 139, .g = 0, .b = 139, .a = 255 } },
    .{ "darkolivegreen", .{ .r = 85, .g = 107, .b = 47, .a = 255 } },
    .{ "darkorange", .{ .r = 255, .g = 140, .b = 0, .a = 255 } },
    .{ "darkorchid", .{ .r = 153, .g = 50, .b = 204, .a = 255 } },
    .{ "darkred", .{ .r = 139, .g = 0, .b = 0, .a = 255 } },
    .{ "darksalmon", .{ .r = 233, .g = 150, .b = 122, .a = 255 } },
    .{ "darkseagreen", .{ .r = 143, .g = 188, .b = 143, .a = 255 } },
    .{ "darkslateblue", .{ .r = 72, .g = 61, .b = 139, .a = 255 } },
    .{ "darkslategray", .{ .r = 47, .g = 79, .b = 79, .a = 255 } },
    .{ "darkslategrey", .{ .r = 47, .g = 79, .b = 79, .a = 255 } },
    .{ "darkturquoise", .{ .r = 0, .g = 206, .b = 209, .a = 255 } },
    .{ "darkviolet", .{ .r = 148, .g = 0, .b = 211, .a = 255 } },
    .{ "deeppink", .{ .r = 255, .g = 20, .b = 147, .a = 255 } },
    .{ "deepskyblue", .{ .r = 0, .g = 191, .b = 255, .a = 255 } },
    .{ "dimgray", .{ .r = 105, .g = 105, .b = 105, .a = 255 } },
    .{ "dimgrey", .{ .r = 105, .g = 105, .b = 105, .a = 255 } },
    .{ "dodgerblue", .{ .r = 30, .g = 144, .b = 255, .a = 255 } },
    .{ "firebrick", .{ .r = 178, .g = 34, .b = 34, .a = 255 } },
    .{ "floralwhite", .{ .r = 255, .g = 250, .b = 240, .a = 255 } },
    .{ "forestgreen", .{ .r = 34, .g = 139, .b = 34, .a = 255 } },
    .{ "fuchsia", .{ .r = 255, .g = 0, .b = 255, .a = 255 } },
    .{ "gainsboro", .{ .r = 220, .g = 220, .b = 220, .a = 255 } },
    .{ "ghostwhite", .{ .r = 248, .g = 248, .b = 255, .a = 255 } },
    .{ "gold", .{ .r = 255, .g = 215, .b = 0, .a = 255 } },
    .{ "goldenrod", .{ .r = 218, .g = 165, .b = 32, .a = 255 } },
    .{ "gray", .{ .r = 128, .g = 128, .b = 128, .a = 255 } },
    .{ "green", .{ .r = 0, .g = 128, .b = 0, .a = 255 } },
    .{ "greenyellow", .{ .r = 173, .g = 255, .b = 47, .a = 255 } },
    .{ "grey", .{ .r = 128, .g = 128, .b = 128, .a = 255 } },
    .{ "honeydew", .{ .r = 240, .g = 255, .b = 240, .a = 255 } },
    .{ "hotpink", .{ .r = 255, .g = 105, .b = 180, .a = 255 } },
    .{ "indianred", .{ .r = 205, .g = 92, .b = 92, .a = 255 } },
    .{ "indigo", .{ .r = 75, .g = 0, .b = 130, .a = 255 } },
    .{ "ivory", .{ .r = 255, .g = 255, .b = 240, .a = 255 } },
    .{ "khaki", .{ .r = 240, .g = 230, .b = 140, .a = 255 } },
    .{ "lavender", .{ .r = 230, .g = 230, .b = 250, .a = 255 } },
    .{ "lavenderblush", .{ .r = 255, .g = 240, .b = 245, .a = 255 } },
    .{ "lawngreen", .{ .r = 124, .g = 252, .b = 0, .a = 255 } },
    .{ "lemonchiffon", .{ .r = 255, .g = 250, .b = 205, .a = 255 } },
    .{ "lightblue", .{ .r = 173, .g = 216, .b = 230, .a = 255 } },
    .{ "lightcoral", .{ .r = 240, .g = 128, .b = 128, .a = 255 } },
    .{ "lightcyan", .{ .r = 224, .g = 255, .b = 255, .a = 255 } },
    .{ "lightgoldenrodyellow", .{ .r = 250, .g = 250, .b = 210, .a = 255 } },
    .{ "lightgray", .{ .r = 211, .g = 211, .b = 211, .a = 255 } },
    .{ "lightgreen", .{ .r = 144, .g = 238, .b = 144, .a = 255 } },
    .{ "lightgrey", .{ .r = 211, .g = 211, .b = 211, .a = 255 } },
    .{ "lightpink", .{ .r = 255, .g = 182, .b = 193, .a = 255 } },
    .{ "lightsalmon", .{ .r = 255, .g = 160, .b = 122, .a = 255 } },
    .{ "lightseagreen", .{ .r = 32, .g = 178, .b = 170, .a = 255 } },
    .{ "lightskyblue", .{ .r = 135, .g = 206, .b = 250, .a = 255 } },
    .{ "lightslategray", .{ .r = 119, .g = 136, .b = 153, .a = 255 } },
    .{ "lightslategrey", .{ .r = 119, .g = 136, .b = 153, .a = 255 } },
    .{ "lightsteelblue", .{ .r = 176, .g = 196, .b = 222, .a = 255 } },
    .{ "lightyellow", .{ .r = 255, .g = 255, .b = 224, .a = 255 } },
    .{ "lime", .{ .r = 0, .g = 255, .b = 0, .a = 255 } },
    .{ "limegreen", .{ .r = 50, .g = 205, .b = 50, .a = 255 } },
    .{ "linen", .{ .r = 250, .g = 240, .b = 230, .a = 255 } },
    .{ "magenta", .{ .r = 255, .g = 0, .b = 255, .a = 255 } },
    .{ "maroon", .{ .r = 128, .g = 0, .b = 0, .a = 255 } },
    .{ "mediumaquamarine", .{ .r = 102, .g = 205, .b = 170, .a = 255 } },
    .{ "mediumblue", .{ .r = 0, .g = 0, .b = 205, .a = 255 } },
    .{ "mediumorchid", .{ .r = 186, .g = 85, .b = 211, .a = 255 } },
    .{ "mediumpurple", .{ .r = 147, .g = 112, .b = 219, .a = 255 } },
    .{ "mediumseagreen", .{ .r = 60, .g = 179, .b = 113, .a = 255 } },
    .{ "mediumslateblue", .{ .r = 123, .g = 104, .b = 238, .a = 255 } },
    .{ "mediumspringgreen", .{ .r = 0, .g = 250, .b = 154, .a = 255 } },
    .{ "mediumturquoise", .{ .r = 72, .g = 209, .b = 204, .a = 255 } },
    .{ "mediumvioletred", .{ .r = 199, .g = 21, .b = 133, .a = 255 } },
    .{ "midnightblue", .{ .r = 25, .g = 25, .b = 112, .a = 255 } },
    .{ "mintcream", .{ .r = 245, .g = 255, .b = 250, .a = 255 } },
    .{ "mistyrose", .{ .r = 255, .g = 228, .b = 225, .a = 255 } },
    .{ "moccasin", .{ .r = 255, .g = 228, .b = 181, .a = 255 } },
    .{ "navajowhite", .{ .r = 255, .g = 222, .b = 173, .a = 255 } },
    .{ "navy", .{ .r = 0, .g = 0, .b = 128, .a = 255 } },
    .{ "oldlace", .{ .r = 253, .g = 245, .b = 230, .a = 255 } },
    .{ "olive", .{ .r = 128, .g = 128, .b = 0, .a = 255 } },
    .{ "olivedrab", .{ .r = 107, .g = 142, .b = 35, .a = 255 } },
    .{ "orange", .{ .r = 255, .g = 165, .b = 0, .a = 255 } },
    .{ "orangered", .{ .r = 255, .g = 69, .b = 0, .a = 255 } },
    .{ "orchid", .{ .r = 218, .g = 112, .b = 214, .a = 255 } },
    .{ "palegoldenrod", .{ .r = 238, .g = 232, .b = 170, .a = 255 } },
    .{ "palegreen", .{ .r = 152, .g = 251, .b = 152, .a = 255 } },
    .{ "paleturquoise", .{ .r = 175, .g = 238, .b = 238, .a = 255 } },
    .{ "palevioletred", .{ .r = 219, .g = 112, .b = 147, .a = 255 } },
    .{ "papayawhip", .{ .r = 255, .g = 239, .b = 213, .a = 255 } },
    .{ "peachpuff", .{ .r = 255, .g = 218, .b = 185, .a = 255 } },
    .{ "peru", .{ .r = 205, .g = 133, .b = 63, .a = 255 } },
    .{ "pink", .{ .r = 255, .g = 192, .b = 203, .a = 255 } },
    .{ "plum", .{ .r = 221, .g = 160, .b = 221, .a = 255 } },
    .{ "powderblue", .{ .r = 176, .g = 224, .b = 230, .a = 255 } },
    .{ "purple", .{ .r = 128, .g = 0, .b = 128, .a = 255 } },
    .{ "rebeccapurple", .{ .r = 102, .g = 51, .b = 153, .a = 255 } },
    .{ "red", .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
    .{ "rosybrown", .{ .r = 188, .g = 143, .b = 143, .a = 255 } },
    .{ "royalblue", .{ .r = 65, .g = 105, .b = 225, .a = 255 } },
    .{ "saddlebrown", .{ .r = 139, .g = 69, .b = 19, .a = 255 } },
    .{ "salmon", .{ .r = 250, .g = 128, .b = 114, .a = 255 } },
    .{ "sandybrown", .{ .r = 244, .g = 164, .b = 96, .a = 255 } },
    .{ "seagreen", .{ .r = 46, .g = 139, .b = 87, .a = 255 } },
    .{ "seashell", .{ .r = 255, .g = 245, .b = 238, .a = 255 } },
    .{ "sienna", .{ .r = 160, .g = 82, .b = 45, .a = 255 } },
    .{ "silver", .{ .r = 192, .g = 192, .b = 192, .a = 255 } },
    .{ "skyblue", .{ .r = 135, .g = 206, .b = 235, .a = 255 } },
    .{ "slateblue", .{ .r = 106, .g = 90, .b = 205, .a = 255 } },
    .{ "slategray", .{ .r = 112, .g = 128, .b = 144, .a = 255 } },
    .{ "slategrey", .{ .r = 112, .g = 128, .b = 144, .a = 255 } },
    .{ "snow", .{ .r = 255, .g = 250, .b = 250, .a = 255 } },
    .{ "springgreen", .{ .r = 0, .g = 255, .b = 127, .a = 255 } },
    .{ "steelblue", .{ .r = 70, .g = 130, .b = 180, .a = 255 } },
    .{ "tan", .{ .r = 210, .g = 180, .b = 140, .a = 255 } },
    .{ "teal", .{ .r = 0, .g = 128, .b = 128, .a = 255 } },
    .{ "thistle", .{ .r = 216, .g = 191, .b = 216, .a = 255 } },
    .{ "tomato", .{ .r = 255, .g = 99, .b = 71, .a = 255 } },
    .{ "turquoise", .{ .r = 64, .g = 224, .b = 208, .a = 255 } },
    .{ "violet", .{ .r = 238, .g = 130, .b = 238, .a = 255 } },
    .{ "wheat", .{ .r = 245, .g = 222, .b = 179, .a = 255 } },
    .{ "white", .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    .{ "whitesmoke", .{ .r = 245, .g = 245, .b = 245, .a = 255 } },
    .{ "yellow", .{ .r = 255, .g = 255, .b = 0, .a = 255 } },
    .{ "yellowgreen", .{ .r = 154, .g = 205, .b = 50, .a = 255 } },
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

    // Named colors TODO
    // const lc: []u8 = undefined;
    // _ = std.ascii.lowerString(lc, s);
    // if (NamedColors.has(lc)) {
    //     const c = NamedColors.get(lc).?;
    //     return .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
    // }

    if (std.ascii.eqlIgnoreCase(s, "transparent")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (std.ascii.eqlIgnoreCase(s, "red")) return .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "green")) return .{ .r = 0, .g = 128, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "blue")) return .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "black")) return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "white")) return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "silver")) return .{ .r = 192, .g = 192, .b = 192, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "gray")) return .{ .r = 128, .g = 128, .b = 128, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "maroon")) return .{ .r = 128, .g = 0, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "olive")) return .{ .r = 128, .g = 128, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "yellow")) return .{ .r = 255, .g = 255, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "lime")) return .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "aqua")) return .{ .r = 0, .g = 255, .b = 255, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "fuchsia")) return .{ .r = 255, .g = 0, .b = 255, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "navy")) return .{ .r = 0, .g = 0, .b = 128, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "purple")) return .{ .r = 128, .g = 0, .b = 128, .a = 255 };
    if (std.ascii.eqlIgnoreCase(s, "teal")) return .{ .r = 0, .g = 128, .b = 128, .a = 255 };

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

// if (std.ascii.eqlIgnoreCase(s, "transparent")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
//     if (std.ascii.eqlIgnoreCase(s, "red")) return .{ .r = 255, .g = 0, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "green")) return .{ .r = 0, .g = 128, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "blue")) return .{ .r = 0, .g = 0, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "black")) return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "white")) return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "silver")) return .{ .r = 192, .g = 192, .b = 192, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "gray")) return .{ .r = 128, .g = 128, .b = 128, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "maroon")) return .{ .r = 128, .g = 0, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "olive")) return .{ .r = 128, .g = 128, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "yellow")) return .{ .r = 255, .g = 255, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lime")) return .{ .r = 0, .g = 255, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "aqua")) return .{ .r = 0, .g = 255, .b = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "fuchsia")) return .{ .r = 255, .g = 0, .b = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "navy")) return .{ .r = 0, .g = 0, .b = 128, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "purple")) return .{ .r = 128, .g = 0, .b = 128, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "teal")) return .{ .r = 0, .g = 128, .b = 128, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "orange")) return .{ .r = 255, .g = 165, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "pink")) return .{ .r = 255, .g = 192, .b = 203, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "brown")) return .{ .r = 165, .g = 42, .b = 42, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "bisque")) return .{ .r = 255, .g = 228, .b = 196, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "aliceblue")) return .{ .r = 240, .g = 248, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "antiquewhite")) return .{ .r = 250, .g = 235, .b = 215, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "aquamarine")) return .{ .r = 127, .g = 255, .b = 212, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "azure")) return .{ .r = 240, .g = 255, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "beige")) return .{ .r = 245, .g = 245, .b = 220, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "blanchedalmond")) return .{ .r = 255, .g = 235, .b = 205, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "blueviolet")) return .{ .r = 138, .g = 43, .b = 226, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "burlywood")) return .{ .r = 222, .g = 184, .b = 135, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "cadetblue")) return .{ .r = 95, .g = 158, .b = 160, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "chartreuse")) return .{ .r = 127, .g = 255, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "chocolate")) return .{ .r = 210, .g = 105, .b = 30, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "coral")) return .{ .r = 255, .g = 127, .b = 80, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "cornflowerblue")) return .{ .r = 100, .g = 149, .b = 237, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "cornsilk")) return .{ .r = 255, .g = 248, .b = 220, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "crimson")) return .{ .r = 220, .g = 20, .b = 60, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "cyan")) return .{ .r = 0, .g = 255, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkblue")) return .{ .r = 0, .g = 0, .b = 139, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkcyan")) return .{ .r = 0, .g = 139, .b = 139, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkgoldenrod")) return .{ .r = 184, .g = 134, .b = 11, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkgray")) return .{ .r = 169, .g = 169, .b = 169, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkgreen")) return .{ .r = 0, .g = 100, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkgrey")) return .{ .r = 169, .g = 169, .b = 169, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkkhaki")) return .{ .r = 189, .g = 183, .b = 107, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkmagenta")) return .{ .r = 139, .g = 0, .b = 139, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkolivegreen")) return .{ .r = 85, .g = 107, .b = 47, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkorange")) return .{ .r = 255, .g = 140, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkorchid")) return .{ .r = 153, .g = 50, .b = 204, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkred")) return .{ .r = 139, .g = 0, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darksalmon")) return .{ .r = 233, .g = 150, .b = 122, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkseagreen")) return .{ .r = 143, .g = 188, .b = 143, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkslateblue")) return .{ .r = 72, .g = 61, .b = 139, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkslategray")) return .{ .r = 47, .g = 79, .b = 79, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkslategrey")) return .{ .r = 47, .g = 79, .b = 79, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkturquoise")) return .{ .r = 0, .g = 206, .b = 209, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "darkviolet")) return .{ .r = 148, .g = 0, .b = 211, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "deeppink")) return .{ .r = 255, .g = 20, .b = 147, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "deepskyblue")) return .{ .r = 0, .g = 191, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "dimgray")) return .{ .r = 105, .g = 105, .b = 105, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "dimgrey")) return .{ .r = 105, .g = 105, .b = 105, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "dodgerblue")) return .{ .r = 30, .g = 144, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "firebrick")) return .{ .r = 178, .g = 34, .b = 34, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "floralwhite")) return .{ .r = 255, .g = 250, .b = 240, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "forestgreen")) return .{ .r = 34, .g = 139, .b = 34, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "gainsboro")) return .{ .r = 220, .g = 220, .b = 220, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "ghostwhite")) return .{ .r = 248, .g = 248, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "gold")) return .{ .r = 255, .g = 215, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "goldenrod")) return .{ .r = 218, .g = 165, .b = 32, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "greenyellow")) return .{ .r = 173, .g = 255, .b = 47, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "grey")) return .{ .r = 128, .g = 128, .b = 128, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "honeydew")) return .{ .r = 240, .g = 255, .b = 240, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "hotpink")) return .{ .r = 255, .g = 105, .b = 180, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "indianred")) return .{ .r = 205, .g = 92, .b = 92, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "indigo")) return .{ .r = 75, .g = 0, .b = 130, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "ivory")) return .{ .r = 255, .g = 255, .b = 240, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "khaki")) return .{ .r = 240, .g = 230, .b = 140, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lavender")) return .{ .r = 230, .g = 230, .b = 250, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lavenderblush")) return .{ .r = 255, .g = 240, .b = 245, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lawngreen")) return .{ .r = 124, .g = 252, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lemonchiffon")) return .{ .r = 255, .g = 250, .b = 205, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightblue")) return .{ .r = 173, .g = 216, .b = 230, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightcoral")) return .{ .r = 240, .g = 128, .b = 128, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightcyan")) return .{ .r = 224, .g = 255, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightgoldenrodyellow")) return .{ .r = 250, .g = 250, .b = 210, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightgray")) return .{ .r = 211, .g = 211, .b = 211, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightgreen")) return .{ .r = 144, .g = 238, .b = 144, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightgrey")) return .{ .r = 211, .g = 211, .b = 211, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightpink")) return .{ .r = 255, .g = 182, .b = 193, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightsalmon")) return .{ .r = 255, .g = 160, .b = 122, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightseagreen")) return .{ .r = 32, .g = 178, .b = 170, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightskyblue")) return .{ .r = 135, .g = 206, .b = 250, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightslategray")) return .{ .r = 119, .g = 136, .b = 153, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightslategrey")) return .{ .r = 119, .g = 136, .b = 153, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightsteelblue")) return .{ .r = 176, .g = 196, .b = 222, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "lightyellow")) return .{ .r = 255, .g = 255, .b = 224, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "limegreen")) return .{ .r = 50, .g = 205, .b = 50, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "linen")) return .{ .r = 250, .g = 240, .b = 230, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "magenta")) return .{ .r = 255, .g = 0, .b = 255, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumaquamarine")) return .{ .r = 102, .g = 205, .b = 170, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumblue")) return .{ .r = 0, .g = 0, .b = 205, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumorchid")) return .{ .r = 186, .g = 85, .b = 211, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumpurple")) return .{ .r = 147, .g = 112, .b = 219, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumseagreen")) return .{ .r = 60, .g = 179, .b = 113, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumslateblue")) return .{ .r = 123, .g = 104, .b = 238, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumspringgreen")) return .{ .r = 0, .g = 250, .b = 154, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumturquoise")) return .{ .r = 72, .g = 209, .b = 204, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mediumvioletred")) return .{ .r = 199, .g = 21, .b = 133, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "midnightblue")) return .{ .r = 25, .g = 25, .b = 112, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mintcream")) return .{ .r = 245, .g = 255, .b = 250, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "mistyrose")) return .{ .r = 255, .g = 228, .b = 225, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "moccasin")) return .{ .r = 255, .g = 228, .b = 181, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "navajowhite")) return .{ .r = 255, .g = 222, .b = 173, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "oldlace")) return .{ .r = 253, .g = 245, .b = 230, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "olivedrab")) return .{ .r = 107, .g = 142, .b = 35, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "orangered")) return .{ .r = 255, .g = 69, .b = 0, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "orchid")) return .{ .r = 218, .g = 112, .b = 214, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "palegoldenrod")) return .{ .r = 238, .g = 232, .b = 170, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "palegreen")) return .{ .r = 152, .g = 251, .b = 152, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "paleturquoise")) return .{ .r = 175, .g = 238, .b = 238, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "palevioletred")) return .{ .r = 219, .g = 112, .b = 147, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "papayawhip")) return .{ .r = 255, .g = 239, .b = 213, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "peachpuff")) return .{ .r = 255, .g = 218, .b = 185, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "peru")) return .{ .r = 205, .g = 133, .b = 63, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "plum")) return .{ .r = 221, .g = 160, .b = 221, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "powderblue")) return .{ .r = 176, .g = 224, .b = 230, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "rosybrown")) return .{ .r = 188, .g = 143, .b = 143, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "royalblue")) return .{ .r = 65, .g = 105, .b = 225, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "saddlebrown")) return .{ .r = 139, .g = 69, .b = 19, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "salmon")) return .{ .r = 250, .g = 128, .b = 114, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "sandybrown")) return .{ .r = 244, .g = 164, .b = 96, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "seagreen")) return .{ .r = 46, .g = 139, .b = 87, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "seashell")) return .{ .r = 255, .g = 245, .b = 238, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "sienna")) return .{ .r = 160, .g = 82, .b = 45, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "skyblue")) return .{ .r = 135, .g = 206, .b = 235, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "slateblue")) return .{ .r = 106, .g = 90, .b = 205, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "slategray")) return .{ .r = 112, .g = 128, .b = 144, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "slategrey")) return .{ .r = 112, .g = 128, .b = 144, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "snow")) return .{ .r = 255, .g = 250, .b = 250, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "springgreen")) return .{ .r = 0, .g = 255, .b = 127, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "steelblue")) return .{ .r = 70, .g = 130, .b = 180, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "tan")) return .{ .r = 210, .g = 180, .b = 140, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "thistle")) return .{ .r = 216, .g = 191, .b = 216, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "tomato")) return .{ .r = 255, .g = 99, .b = 71, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "turquoise")) return .{ .r = 64, .g = 224, .b = 208, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "violet")) return .{ .r = 238, .g = 130, .b = 238, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "wheat")) return .{ .r = 245, .g = 222, .b = 179, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "whitesmoke")) return .{ .r = 245, .g = 245, .b = 245, .a = 255 };
//     if (std.ascii.eqlIgnoreCase(s, "yellowgreen")) return .{ .r = 154, .g = 205, .b = 50, .a = 255 };

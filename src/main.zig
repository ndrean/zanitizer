const std = @import("std");
const z = @import("root.zig");
const builtin = @import("builtin");
const config = @import("modules/config.zig");
const native_os = builtin.os.tag;

const md4c_h = @cImport({
    @cInclude("md4c-html.h");
});

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (native_os == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        std.debug.print("{}\n", .{debug_allocator.deinit()});
    };

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // skip exe name

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var from_markdown: bool = false;
    var fragment: bool = false;
    var config_json: ?[]const u8 = null;
    var config_file: ?[]const u8 = null;
    var preset: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--md")) {
            from_markdown = true;
        } else if (std.mem.eql(u8, arg, "--fragment") or std.mem.eql(u8, arg, "-f")) {
            fragment = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            output_path = args.next();
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_json = args.next();
        } else if (std.mem.eql(u8, arg, "--config-file")) {
            config_file = args.next();
        } else if (std.mem.eql(u8, arg, "--preset")) {
            preset = args.next();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "-") or !std.mem.startsWith(u8, arg, "-")) {
            input_path = arg;
        }
    }

    // JSON config arena — kept alive until after sanitizeHtml() so string slices remain valid.
    var json_arena = std.heap.ArenaAllocator.init(gpa);
    defer json_arena.deinit();

    // Resolve sanitize options from preset + optional JSON patch
    const opts = try resolveCliOptions(json_arena.allocator(), preset, config_json, config_file);

    // Read input (file, stdin, or "-")
    const html_src: []u8 = blk: {
        const raw = try readInput(gpa, input_path);
        if (!from_markdown) break :blk raw;
        defer gpa.free(raw);
        break :blk try markdownToHtml(gpa, raw);
    };
    defer gpa.free(html_src);

    const out = try sanitizeHtml(gpa, html_src, opts, fragment);
    defer gpa.free(out);

    if (output_path) |p| {
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = out });
    } else {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(out);
        try stdout.writeAll("\n");
    }
}

/// Core sanitize function — shared by CLI and WASM entry points.
/// fragment=true returns only the <body> inner content (ready for innerHTML),
/// fragment=false returns the full <html>…</html> document.
pub fn sanitizeHtml(allocator: std.mem.Allocator, html: []const u8, opts: z.SanitizeOptions, fragment: bool) ![]u8 {
    const doc = try z.parseHTML(allocator, html);
    defer z.destroyDocument(doc);

    var san = try z.Sanitizer.init(allocator, opts);
    defer san.deinit();
    try san.sanitize(doc);

    if (fragment) {
        const body = z.bodyElement(doc) orelse return error.NoBody;
        return z.innerHTML(allocator, body);
    }
    const root = z.documentRoot(doc) orelse return error.NoDocumentRoot;
    return z.outerNodeHTML(allocator, root);
}

/// Build SanitizeOptions from an optional preset + optional JSON patch (JSON wins on overlap).
fn resolveCliOptions(allocator: std.mem.Allocator, preset_name: ?[]const u8, json_inline: ?[]const u8, json_file: ?[]const u8) !z.SanitizeOptions {
    // Load JSON source (inline string or file).
    // NOTE: json_file_buf is intentionally NOT freed here — json_arena (caller) owns
    // its lifetime. json_arena.deinit() at end of main() cleans everything up.
    const json_src: ?[]const u8 = if (json_inline) |j|
        j
    else if (json_file) |f| blk: {
        const buf = try std.fs.cwd().readFileAlloc(allocator, f, 512 * 1024);
        break :blk buf;
    } else null;
    return config.resolveOptions(allocator, preset_name, json_src);
}

fn readInput(allocator: std.mem.Allocator, path: ?[]const u8) ![]u8 {
    const p = path orelse "-";
    if (std.mem.eql(u8, p, "-")) {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(allocator);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try std.fs.File.stdin().read(&buf);
            if (n == 0) break;
            try list.appendSlice(allocator, buf[0..n]);
        }
        return list.toOwnedSlice(allocator);
    }
    return std.fs.cwd().readFileAlloc(allocator, p, 10 * 1024 * 1024);
}

// md4c callback context
const MdCtx = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    fn callback(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) callconv(.c) void {
        const ctx: *MdCtx = @ptrCast(@alignCast(userdata.?));
        ctx.list.appendSlice(ctx.allocator, text[0..size]) catch {};
    }
};

fn markdownToHtml(allocator: std.mem.Allocator, md: []const u8) ![]u8 {
    var ctx = MdCtx{ .allocator = allocator };
    errdefer ctx.list.deinit(allocator);
    const rc = md4c_h.md_html(md.ptr, @intCast(md.len), MdCtx.callback, &ctx, md4c_h.MD_DIALECT_GITHUB, 0);
    if (rc != 0) return error.MarkdownConversionFailed;
    return ctx.list.toOwnedSlice(allocator);
}

fn printUsage() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(
        \\Usage: zan [FILE] [OPTIONS]
        \\
        \\  FILE             HTML file to sanitize (default: stdin)
        \\  -                Read from stdin explicitly
        \\
        \\Options:
        \\  --preset NAME    Base preset: default (default), strict, permissive, trusted
        \\  --config JSON    SanitizerConfig as inline JSON (patches preset)
        \\  --config-file F  SanitizerConfig as JSON file (patches preset)
        \\  --md             Treat input as Markdown (convert to HTML first)
        \\  -f, --fragment   Output body content only (no <html>/<head>/<body> wrapper)
        \\  -o FILE          Write output to file (default: stdout)
        \\  -h, --help       Show this help
        \\
        \\JSON config fields (WHATWG SanitizerConfig):
        \\  elements              [{name, attributes?, removeAttributes?}, ...]
        \\  removeElements        ["script", "iframe", ...]
        \\  replaceWithChildrenElements  ["b", "i", ...]
        \\  attributes            ["href", "class", ...]  global allowlist
        \\  removeAttributes      ["onclick", ...]        global blocklist
        \\  comments              bool (default: false)
        \\  dataAttributes        bool (default: true)
        \\  allowCustomElements   bool (default: true)
        \\  strictUriValidation   bool (default: false)
        \\  sanitizeDomClobbering bool (default: true)
        \\  sanitizeInlineStyles  bool (default: true)
        \\  bypassSafety          bool — allow event handlers (default: false)
        \\
        \\Examples:
        \\  echo '<script>alert(1)</script><p>Hello</p>' | zanitize
        \\  zan dirty.html > clean.html
        \\  zan dirty.html --preset strict -o clean.html
        \\  zan dirty.html --config '{"elements":[{"name":"p"},{"name":"a","attributes":["href"]}]}'
        \\  zan dirty.html --config '{"replaceWithChildrenElements":["b","i"]}'
        \\  cat README.md | zanitize --md
        \\
    ) catch {};
}
